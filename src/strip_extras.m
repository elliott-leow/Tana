/* Stacked strips, marks, jump-or-launch, saved arrangements, fitting,
 * attention and helper recovery. Included by horizontal.m after the workflow
 * layer; everything here runs on the engine's serialized event loop unless it
 * says otherwise. */

/* ---- Stacked strips ---------------------------------------------------- */

static NSArray *hwm_shelf_names;              /* settings.strips; may be shorter than the strips in use */
static uint32_t hwm_shelf_focus[HWM_SHELVES]; /* the window each strip was last left on */
static const double HWMShelfGain=2.2;         /* strips travelled per unit of vertical swipe */
static double hwm_shelf_gesture_origin, hwm_shelf_gesture_velocity, hwm_shelf_gesture_last, hwm_shelf_gesture_time;

static struct window *hwm_tile(uint32_t wid)
{
    struct window *w=window_manager_find_window(&g_window_manager,wid);
    return w && hwm_shelf_of(w)==hwm_shelf ? w : NULL;
}
/* The first leaf at or after `node` that holds a window of the strip in view.
 * Reordering one strip must leave the leaves of the others where they are. */
static struct window_node *hwm_slot(struct window_node *node)
{
    for(;node;node=window_node_find_next_leaf(node)) if(node->window_count && hwm_tile(node->window_list[0])) return node;
    return NULL;
}
static int hwm_shelf_last(struct view *view)
{
    int last=-1;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(w && !w->strip_close_ghost && hwm_shelf_of(w)>last) last=hwm_shelf_of(w);
    }
    return last;
}
/* The lowest strip that can be visited: one empty strip past the last in use,
 * and every strip that has been given a name. */
static int hwm_shelf_limit(struct view *view)
{
    int limit=hwm_shelf_last(view)+1, named=(int)hwm_shelf_names.count-1;
    if(named>limit) limit=named;
    return limit<HWM_SHELVES-1 ? limit : HWM_SHELVES-1;
}
static NSString *hwm_shelf_label(int shelf)
{
    return shelf>=0 && shelf<(int)hwm_shelf_names.count ? hwm_shelf_names[shelf] : [NSString stringWithFormat:@"Strip %d",shelf+1];
}
/* A strip named in a rule: an index, or one of settings.strips. -1 when unknown. */
static int hwm_shelf_named(id strip)
{
    if([strip isKindOfClass:[NSNumber class]]) { int index=[strip intValue]; return index>=0 && index<HWM_SHELVES ? index : -1; }
    if([strip isKindOfClass:[NSString class]]) for(NSUInteger i=0;i<hwm_shelf_names.count && i<HWM_SHELVES;i++)
        if([hwm_shelf_names[i] caseInsensitiveCompare:strip]==NSOrderedSame) return (int)i;
    return -1;
}
/* Move a window to another strip without moving it on screen: its last frame
 * is re-expressed in that strip's coordinates, and it animates from there. */
static void hwm_shelf_assign(struct view *view,struct window *w,int shelf,double now)
{
    if(hwm_shelf_of(w)==shelf) return;
    w->strip_shelf=shelf;
    w->strip_last_offset=hwm_shelf_offset(view,shelf,now);
    w->strip_last_shift=hwm_shelf_shift(view,shelf,now);
}

/* A floating window belongs to the strip it was floated on and leaves with it,
 * unless it is sticky. Its resting place is noted when its strip first moves. */
static bool hwm_shelf_float(struct window *w)
{
    return w->is_root && window_check_flag(w,WINDOW_FLOAT) && !w->strip_sticky && window_is_standard(w) &&
           window_manager_is_window_eligible(w) && !window_check_flag(w,WINDOW_MINIMIZE) && !window_check_flag(w,WINDOW_FULLSCREEN) &&
           !w->application->is_hidden && !window_manager_find_managed_window(&g_window_manager,w);
}
static void hwm_shelf_home_floats(void)
{
    table_for(struct window *w,g_window_manager.window, {
        if(w->strip_float_homed || !hwm_shelf_float(w)) continue;
        CGRect frame=w->strip_float_animating ? w->strip_float_target : CGRectNull;
        if(CGRectIsNull(frame) && SLSGetWindowBounds(g_connection,w->id,&frame)!=kCGErrorSuccess) continue;
        w->strip_float_animating=false;
        w->strip_float_home=frame; w->strip_float_last=frame; w->strip_float_homed=true;
    })
}
static bool hwm_render_shelf_floats(struct view *view,double now)
{
    bool moving=hwm_shelf_moving(now);
    table_for(struct window *w,g_window_manager.window, {
        if(!w->strip_float_homed) continue;
        if(!window_check_flag(w,WINDOW_FLOAT) || w->strip_float_animating) { w->strip_float_homed=false; continue; }
        CGPoint to=CGPointMake(round(w->strip_float_home.origin.x),round(w->strip_float_home.origin.y+(w->strip_sticky ? 0 : hwm_shelf_shift(view,hwm_shelf_of(w),now))));
        if(!CGPointEqualToPoint(to,w->strip_float_last.origin) && scripting_addition_move_window(w->id,to.x,to.y)) w->strip_float_last.origin=to;
        // Back on its own strip and at rest, the window is the user's to move again.
        if(!moving && (w->strip_sticky || hwm_shelf_of(w)==hwm_shelf)) w->strip_float_homed=false;
    })
    return moving;
}

static void hwm_shelf_go(int target,bool focus)
{
    struct view *view=hwm_view(); if(!view) return;
    double now=hwm_clock(), camera=hwm_shelf_camera(now);
    bool held=hwm_shelf_holding;
    hwm_shelf_holding=false;
    hwm_feedback_shelf_time=now;
    if(target<0 || target>hwm_shelf_limit(view) || target==hwm_shelf) {
        // A finger let go off-centre: settle back on the strip in view.
        if(held) { hwm_shelf_from=camera; hwm_shelf_start=now; }
        if(target!=hwm_shelf) { hwm_haptic(1); hwm_feedback_navigation(true); }
        hwm_wake(); return;
    }
    hwm_nav_flush();
    hwm_shelf_home_floats();
    struct window *focused=window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
    if(focused && hwm_shelf_of(focused)==hwm_shelf && view_find_window_node(view,focused->id)) hwm_shelf_focus[hwm_shelf]=focused->id;
    hwm_shelf_offsets[hwm_shelf]=hwm_clamp_offset(hwm_offset(view,now));
    hwm_shelf_from=camera; hwm_shelf_start=now;
    hwm_shelf=target;
    view->strip_scrolling=false;
    view->strip_offset=view->strip_target_offset=view->strip_from_offset=hwm_shelf_offsets[target];
    hwm_rubber=0; hwm_scroll_current_velocity=0; hwm_held_lead=0;
    hwm_content_width=hwm_shelf_content[target];
    hwm_nav_window=0; hwm_nav_pending=false; hwm_settle_pending=false;
    hwm_state_pending=true; hwm_hold_focus(); hwm_haptic(0); hwm_wake();
    hwm_ipc_send(@{@"event":@"strip",@"index":@(target+1),@"name":hwm_shelf_label(target)});
    if(!focus) return;
    struct window *next=hwm_tile(hwm_shelf_focus[target]);
    if(next && (!view_find_window_node(view,next->id) || next->strip_close_ghost)) next=NULL;
    if(!next) {
        // Otherwise the window nearest the middle of what the strip is showing.
        double centre=view->strip_offset+hwm_bounds(view).size.width*.5, nearest=INFINITY;
        for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
            struct window *w=hwm_tile(n->window_list[i]);
            if(!w || w->strip_close_ghost || hwm_workflow_tab_hidden(w)) continue;
            double distance=fabs(w->strip_world_x+w->strip_width*.5-centre);
            if(distance<nearest) { nearest=distance; next=w; }
        }
    }
    if(!next) return;
    hwm_preserve_focus_window=next->id; hwm_preserve_focus_until=hwm_now()+.6;
    hwm_feedback_focus(NULL,next);
    window_manager_focus_window_with_raise(&next->application->psn,next->id,next->ref);
}

/* Carry the focused column to another strip and follow it there. */
static bool hwm_shelf_send(struct view *view,struct window *window,int target)
{
    if(!window || !view_find_window_node(view,window->id) || hwm_shelf_of(window)!=hwm_shelf) return false;
    if(target<0 || target>hwm_shelf_limit(view) || target==hwm_shelf) { hwm_haptic(1); hwm_feedback_navigation(true); return false; }
    hwm_undo_capture();
    uint64_t column=hwm_column_of(window);
    enum { LIMIT=32 }; struct window *members[LIMIT]; int count=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=hwm_tile(n->window_list[i]);
        if(w && hwm_column_of(w)==column && count<LIMIT) members[count++]=w;
    }
    hwm_shelf_focus[target]=window->id;
    hwm_shelf_go(target,false);
    if(hwm_shelf!=target) return false;
    // Their frames are still where they were drawn; from here they belong to the new strip.
    for(int i=0;i<count;i++) hwm_shelf_assign(view,members[i],target,hwm_shelf_start);
    hwm_layout(view,true);
    // The same clock as the strips: the carried column holds still while they change.
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=hwm_tile(n->window_list[i]);
        if(w && hwm_column_of(w)==column) w->strip_start=hwm_shelf_start;
    }
    hwm_scroll(view,hwm_center_target(view,window),true);
    return true;
}

/* A vertical three-finger swipe, when settings.verticalSwipe gives it to the
 * strips: the strips follow the fingers and settle on the nearest one. */
static void hwm_shelf_gesture(CGEventRef event)
{
    struct view *view=hwm_view(); if(!view || hwm_paused || hwm_drag_window) return;
    int phase=(int)CGEventGetIntegerValueField(event,132);
    double amount=CGEventGetDoubleValueField(event,124), now=hwm_now(), stamp=hwm_event_time(event,now);
    if(!isfinite(amount) || fabs(amount)>20) return;
    hwm_vertical_last_progress=amount;
    if(hwm_vertical_mode==2) amount=-amount;
    if(phase==1) {
        hwm_shelf_home_floats();
        hwm_shelf_gesture_origin=hwm_shelf_camera(hwm_clock());
        hwm_shelf_held=hwm_shelf_gesture_origin; hwm_shelf_holding=true;
        hwm_shelf_gesture_velocity=0; hwm_shelf_gesture_last=amount; hwm_shelf_gesture_time=stamp;
        hwm_feedback_shelf_time=now; hwm_hold_focus(); hwm_wake(); return;
    }
    if(!hwm_shelf_holding) return;
    if(phase==2) {
        double dt=stamp-hwm_shelf_gesture_time, limit=hwm_shelf_limit(view), raw=hwm_shelf_gesture_origin+amount*HWMShelfGain;
        if(dt>.001 && dt<.15) hwm_shelf_gesture_velocity=hwm_shelf_gesture_velocity*.6+(amount-hwm_shelf_gesture_last)*HWMShelfGain/dt*.4;
        // Past the first or last strip the fingers are resisted, as at the ends of a strip.
        hwm_shelf_held=hwm_motion_scale==0 ? fmax(0,fmin(limit,raw)) : raw<0 ? -hstrip_rubber_band(-raw,.3) : raw>limit ? limit+hstrip_rubber_band(raw-limit,.3) : raw;
        hwm_shelf_gesture_last=amount; hwm_shelf_gesture_time=stamp;
        hwm_feedback_shelf_time=now; hwm_wake(); return;
    }
    if(phase!=4 && phase!=8) return;
    double projected=hwm_shelf_held+(phase==4 && stamp-hwm_shelf_gesture_time<.1 ? hwm_shelf_gesture_velocity*.14 : 0);
    int target=phase==8 ? hwm_shelf : (int)lround(fmax(hwm_shelf-1,fmin(hwm_shelf+1,projected)));
    int limit=hwm_shelf_limit(view);
    hwm_shelf_go(target<0 ? 0 : target>limit ? limit : target,true);
}

/* ---- Focus by name ----------------------------------------------------- */

/* Bring any window to the user: its strip comes into view, a tile is centred,
 * a minimized window is restored. */
static void hwm_focus_any(struct window *w)
{
    struct view *view=hwm_view(); if(!w || !view) return;
    if(window_check_flag(w,WINDOW_MINIMIZE)) window_manager_deminimize_window(w);
    bool tile=view_find_window_node(view,w->id)!=NULL;
    if((tile || w->strip_float_homed) && hwm_shelf_of(w)!=hwm_shelf) hwm_shelf_go(hwm_shelf_of(w),false);
    if(tile && !w->strip_close_ghost) { hwm_nav_to(view,w); return; }
    hwm_preserve_focus_window=w->id; hwm_preserve_focus_until=hwm_now()+.6;
    window_manager_focus_window_with_raise(&w->application->psn,w->id,w->ref);
}

static bool hwm_bundle_safe(NSString *bundle)
{
    static NSCharacterSet *unsafe;
    if(!unsafe) unsafe=[[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet] retain];
    return bundle.length && bundle.length<200 && [bundle rangeOfCharacterFromSet:unsafe].location==NSNotFound;
}
/* Focus a window of the application, the next one if one already has focus,
 * or start the application when it has no window. */
static void hwm_jump(NSString *bundle,NSString *launch)
{
    struct view *view=hwm_view(); if(!view || !bundle.length) return;
    NSMutableSet *pids=[NSMutableSet set];
    for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle]) [pids addObject:@(app.processIdentifier)];
    enum { LIMIT=64 }; struct window *found[LIMIT]; double keys[LIMIT]; int count=0;
    if(pids.count) table_for(struct window *w,g_window_manager.window, {
        if(count==LIMIT || !w->is_root || ![pids containsObject:@(w->application->pid)] || !window_is_standard(w) ||
           !window_manager_is_window_eligible(w) || w->strip_close_ghost || w->strip_ordered_out) continue;
        // Strip order: the strip in view first, left to right, then the strips below and above.
        int distance=abs(hwm_shelf_of(w)-hwm_shelf);
        double key=distance*1e8+(view_find_window_node(view,w->id) ? w->strip_world_x : 5e7)+w->id*1e-3;
        int at=count++;
        while(at>0 && keys[at-1]>key) { keys[at]=keys[at-1]; found[at]=found[at-1]; --at; }
        keys[at]=key; found[at]=w;
    })
    if(!count) {
        if(launch.length) hwm_spawn(launch);
        else if(hwm_bundle_safe(bundle)) hwm_spawn([NSString stringWithFormat:@"open -b '%@'",bundle]);
        else { hwm_hud(@"Jump: that bundle identifier cannot be launched without a \"launch\" command"); return; }
        return;
    }
    struct window *current=hwm_action_window(), *target=found[0];
    for(int i=0;i<count;i++) if(found[i]==current) { target=found[(i+1)%count]; break; }
    if(target==current) { hwm_scroll(view,hwm_center_target(view,target),true); return; }
    hwm_focus_any(target);
}

/* ---- Marks ------------------------------------------------------------- */

static HWMWorkflowIdentity hwm_marks[128]; /* by key code */
static NSString *hwm_key_name(int code)
{
    for(NSString *name in [[tana_key_codes() allKeys] sortedArrayUsingSelector:@selector(compare:)])
        if([tana_key_codes()[name] intValue]==code && ![name isEqual:@"enter"] && ![name isEqual:@"esc"]) return name.uppercaseString;
    return [NSString stringWithFormat:@"key %d",code];
}
static int hwm_key_code(NSString *name)
{
    NSNumber *code=tana_key_codes()[name.lowercaseString];
    return code ? code.intValue : -1;
}
/* mode 1 sets the mark on the focused window, mode 2 goes to it. */
static bool hwm_mark_apply(int code,int mode)
{
    if(code<0 || code>=128) return false;
    if(mode==1) {
        struct window *w=hwm_action_window();
        if(!w) return false;
        hwm_marks[code]=hwm_workflow_identity(w); hwm_state_pending=true;
        hwm_hud([NSString stringWithFormat:@"Marked  %@",hwm_key_name(code)]);
        return true;
    }
    struct window *w=hwm_workflow_live(hwm_marks[code]);
    if(!w) { hwm_hud([NSString stringWithFormat:@"No window at mark %@",hwm_key_name(code)]); return false; }
    hwm_focus_any(w);
    return true;
}
/* The next key press names the mark; the event tap hands it back. */
static void hwm_mark_begin(int mode)
{
    hwm_key_capture_time=read_os_timer(); hwm_key_capture=mode;
    hwm_hud(mode==1 ? @"Mark window — press a key" : @"Jump to mark — press a key");
}

/* ---- Fitting ----------------------------------------------------------- */

/* Make the columns on screen (at least a quarter of each showing) share the
 * viewport exactly: in their present proportions, or equally. */
static bool hwm_fit_visible(struct view *view,bool equal)
{
    enum { LIMIT=32 };
    struct window *members[LIMIT]; double widths[LIMIT], minima[LIMIT]; size_t count=0; uint64_t last=0;
    double viewport=hwm_bounds(view).size.width, offset=view->strip_target_offset;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=hwm_tile(n->window_list[i]);
        if(!w || w->strip_close_ghost || !w->strip_initialized) continue;
        uint64_t column=hwm_column_of(w);
        double showing=fmin(w->strip_world_x+w->strip_width,offset+viewport)-fmax(w->strip_world_x,offset);
        if(count && column==last) { minima[count-1]=fmax(minima[count-1],hwm_workflow_minimum(w)); continue; }
        if(showing<w->strip_width*.25 || count==LIMIT) continue;
        last=column; members[count]=w; widths[count]=w->strip_width; minima[count++]=hwm_workflow_minimum(w);
    }
    if(!count || !hwm_workflow_fit_many(widths,minima,count,viewport-view->window_gap*(double)(count-1),equal)) return false;
    hwm_undo_capture();
    for(size_t i=0;i<count;i++) hwm_column_width(view,members[i],widths[i]);
    hwm_layout(view,true);
    hwm_scroll(view,members[0]->strip_world_x,true);
    return true;
}

/* ---- Saved arrangements ------------------------------------------------ */

static NSDictionary *hwm_arrangement_pending; /* applied again as its missing applications open */
static double hwm_arrangement_until;
static NSString *hwm_state_path(void);
static NSString *hwm_bundle(struct window *w);

static NSString *hwm_arrangement_directory(void)
{
    return [[hwm_state_path() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"layouts"];
}
static bool hwm_arrangement_name_ok(NSString *name)
{
    static NSCharacterSet *unsafe;
    if(!unsafe) unsafe=[[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_"] invertedSet] retain];
    return name.length && name.length<=40 && [name rangeOfCharacterFromSet:unsafe].location==NSNotFound && ![name hasPrefix:@" "] && ![name hasSuffix:@" "];
}
static NSArray *hwm_arrangement_names(void)
{
    NSMutableArray *names=[NSMutableArray array];
    for(NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:hwm_arrangement_directory() error:NULL])
        if([file.pathExtension isEqual:@"json"] && hwm_arrangement_name_ok(file.stringByDeletingPathExtension)) [names addObject:file.stringByDeletingPathExtension];
    return [names sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
}
/* Which applications sit where, and how wide: no window ids and no titles, so
 * an arrangement outlives the windows it was taken from. */
static bool hwm_arrangement_save(NSString *name)
{
    struct view *view=hwm_view();
    if(!view || !hwm_arrangement_name_ok(name)) return false;
    double viewport=hwm_bounds(view).size.width;
    NSMutableArray *strips=[NSMutableArray array];
    for(int shelf=0;shelf<=hwm_shelf_last(view);shelf++) {
        NSMutableArray *columns=[NSMutableArray array]; uint64_t last=0; NSMutableArray *rows=nil;
        for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
            struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
            NSString *bundle=w && !w->strip_close_ghost && hwm_shelf_of(w)==shelf ? hwm_bundle(w) : nil;
            if(!bundle.length) continue;
            uint64_t column=hwm_column_of(w);
            if(!rows || column!=last) {
                rows=[NSMutableArray array]; last=column;
                [columns addObject:@{@"width":@(w->strip_full_width ? 1 : fmax(.05,fmin(1,w->strip_width/viewport))),
                                     @"tabbed":hwm_workflow_tab(hwm_workflow_column(w)) ? @YES : @NO,@"windows":rows}];
            }
            [rows addObject:@{@"app":bundle,@"weight":@(w->strip_weight>0 ? w->strip_weight : 1)}];
        }
        [strips addObject:@{@"columns":columns}];
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"strips":strips} options:NSJSONWritingPrettyPrinted error:NULL];
    NSString *directory=hwm_arrangement_directory(), *path=[[directory stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"json"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
    if(!data || ![data writeToFile:path options:NSDataWritingAtomic error:NULL]) return false;
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:NULL];
    return true;
}
/* Put the windows that are open into the saved places, by application. What
 * the arrangement does not mention keeps its order after what it does. Returns
 * the applications that had no window to give. */
static NSArray *hwm_arrangement_apply(NSDictionary *spec)
{
    struct view *view=hwm_view();
    NSArray *strips=[spec[@"strips"] isKindOfClass:[NSArray class]] ? spec[@"strips"] : nil;
    if(!view || !strips) return nil;
    size_t capacity=0, count=0, placed=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) capacity+=n->window_count;
    struct window **tiles=calloc(capacity ? capacity : 1,sizeof(*tiles)); uint32_t *order=calloc(capacity ? capacity : 1,sizeof(*order));
    bool *used=calloc(capacity ? capacity : 1,sizeof(*used));
    NSMutableArray *bundles=[NSMutableArray array], *missing=[NSMutableArray array];
    if(!tiles || !order || !used) { free(tiles); free(order); free(used); return nil; }
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w->strip_close_ghost) continue;
        tiles[count++]=w; [bundles addObject:hwm_bundle(w) ?: @""];
    }
    double viewport=hwm_bounds(view).size.width, now=hwm_now();
    for(NSUInteger shelf=0;shelf<strips.count && shelf<HWM_SHELVES;shelf++) {
        NSArray *columns=[strips[shelf] isKindOfClass:[NSDictionary class]] ? strips[shelf][@"columns"] : nil;
        if(![columns isKindOfClass:[NSArray class]]) continue;
        for(NSDictionary *column in columns) {
            if(![column isKindOfClass:[NSDictionary class]] || ![column[@"windows"] isKindOfClass:[NSArray class]]) continue;
            double fraction=[column[@"width"] isKindOfClass:[NSNumber class]] ? [column[@"width"] doubleValue] : .5;
            struct window *first=NULL;
            for(NSDictionary *row in column[@"windows"]) {
                NSString *app=[row isKindOfClass:[NSDictionary class]] && [row[@"app"] isKindOfClass:[NSString class]] ? row[@"app"] : nil;
                if(!app) continue;
                // A window already on that strip is preferred to one fetched from another.
                size_t pick=count;
                for(int pass=0;pass<2 && pick==count;pass++) for(size_t i=0;i<count;i++)
                    if(!used[i] && [bundles[i] isEqual:app] && (pass || hwm_shelf_of(tiles[i])==(int)shelf)) { pick=i; break; }
                if(pick==count) { [missing addObject:app]; continue; }
                struct window *w=tiles[pick]; used[pick]=true; order[placed++]=w->id;
                if(!first) first=w;
                hwm_shelf_assign(view,w,(int)shelf,now);
                hwm_workflow_clear_tab(hwm_workflow_column(w));
                w->strip_column=first->id; w->strip_full_width=false;
                w->strip_width=fmax(160,fmin(1,fmax(.05,isfinite(fraction) ? fraction : .5))*viewport);
                double weight=[row[@"weight"] isKindOfClass:[NSNumber class]] ? [row[@"weight"] doubleValue] : 1;
                w->strip_weight=isfinite(weight) && weight>0 ? weight : 1;
            }
            if(first && [column[@"tabbed"] isKindOfClass:[NSNumber class]] && [column[@"tabbed"] boolValue]) hwm_workflow_set_tab(first->id,hwm_workflow_identity(first));
        }
    }
    for(size_t i=0;i<count;i++) if(!used[i]) order[placed++]=tiles[i]->id;
    struct window_node *slot=window_node_find_first_leaf(view->root);
    for(size_t i=0;i<placed && slot;i++) {
        struct window_node *found=view_find_window_node(view,order[i]);
        if(!found) continue;
        if(found!=slot) window_node_swap_window_list(found,slot);
        slot=window_node_find_next_leaf(slot);
    }
    free(tiles); free(order); free(used);
    hwm_layout(view,true);
    hwm_scroll(view,0,true);
    for(int shelf=0;shelf<HWM_SHELVES;shelf++) if(shelf!=hwm_shelf) hwm_shelf_offsets[shelf]=0;
    hwm_state_pending=true;
    return missing;
}
static bool hwm_arrangement_load(NSString *name)
{
    if(!hwm_arrangement_name_ok(name)) return false;
    NSData *data=[NSData dataWithContentsOfFile:[[hwm_arrangement_directory() stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"json"]];
    id spec=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if(![spec isKindOfClass:[NSDictionary class]]) return false;
    hwm_undo_capture();
    NSArray *missing=hwm_arrangement_apply(spec);
    if(!missing) return false;
    [hwm_arrangement_pending release]; hwm_arrangement_pending=nil;
    NSMutableSet *started=[NSMutableSet set];
    for(NSString *app in missing) {
        // One launch per application; a second window of it is the application's to open.
        if([started containsObject:app] || !hwm_bundle_safe(app)) continue;
        [started addObject:app];
        if(![NSRunningApplication runningApplicationsWithBundleIdentifier:app].count) hwm_spawn([NSString stringWithFormat:@"open -b '%@'",app]);
    }
    if(missing.count) { hwm_arrangement_pending=[spec retain]; hwm_arrangement_until=hwm_now()+30; }
    hwm_hud(missing.count ? [NSString stringWithFormat:@"Layout “%@” — waiting for %lu window%@",name,(unsigned long)missing.count,missing.count==1 ? @"" : @"s"]
                          : [NSString stringWithFormat:@"Layout “%@”",name]);
    return true;
}
/* A window opened while an arrangement still has empty places. */
static void hwm_arrangement_window_opened(void)
{
    if(!hwm_arrangement_pending) return;
    if(hwm_now()>hwm_arrangement_until) { [hwm_arrangement_pending release]; hwm_arrangement_pending=nil; return; }
    NSArray *missing=hwm_arrangement_apply(hwm_arrangement_pending);
    if(!missing.count) { [hwm_arrangement_pending release]; hwm_arrangement_pending=nil; }
}

/* ---- Attention --------------------------------------------------------- */

static int hwm_attention_mode=1; /* bit 0: Dock badges, bit 1: title changes of windows out of sight */
static void hwm_attention_set(struct window *w,bool on)
{
    if(!w || w->strip_attention==on) return;
    w->strip_attention=on;
    if(on) hwm_ipc_send(@{@"event":@"attention",@"id":@(w->id),@"pid":@(w->application->pid)});
    hwm_wake();
}
/* Looking at any window of an application answers all of its requests. */
static void hwm_attention_seen(struct window *focused)
{
    if(!focused) return;
    table_for(struct window *w,g_window_manager.window, { if(w->strip_attention && w->application==focused->application) hwm_attention_set(w,false); })
}
static void hwm_attention_apps(NSArray *pids)
{
    struct window *focused=window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
    table_for(struct window *w,g_window_manager.window, {
        if(!w->is_root || !window_is_standard(w) || ![pids containsObject:@(w->application->pid)] || (focused && focused->application==w->application)) continue;
        hwm_attention_set(w,true);
    })
}
/* Badge text by application path, read from the Dock. Runs off the event loop. */
static NSDictionary *hwm_dock_badges(void)
{
    NSMutableDictionary *badges=[NSMutableDictionary dictionary];
    NSRunningApplication *dock=[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"].firstObject;
    if(!dock) return badges;
    AXUIElementRef app=AXUIElementCreateApplication(dock.processIdentifier);
    AXUIElementSetMessagingTimeout(app,.5f);
    CFTypeRef lists=NULL;
    if(AXUIElementCopyAttributeValue(app,kAXChildrenAttribute,&lists)==kAXErrorSuccess && lists && CFGetTypeID(lists)==CFArrayGetTypeID()) {
        for(CFIndex i=0;i<CFArrayGetCount(lists);i++) {
            CFTypeRef items=NULL;
            if(AXUIElementCopyAttributeValue(CFArrayGetValueAtIndex(lists,i),kAXChildrenAttribute,&items)!=kAXErrorSuccess || !items) continue;
            if(CFGetTypeID(items)==CFArrayGetTypeID()) for(CFIndex k=0;k<CFArrayGetCount(items);k++) {
                AXUIElementRef item=CFArrayGetValueAtIndex(items,k);
                CFTypeRef label=NULL, url=NULL;
                AXUIElementCopyAttributeValue(item,CFSTR("AXStatusLabel"),&label);
                if(label && CFGetTypeID(label)==CFStringGetTypeID() && CFStringGetLength(label)>0) AXUIElementCopyAttributeValue(item,kAXURLAttribute,&url);
                if(url && CFGetTypeID(url)==CFURLGetTypeID()) {
                    NSString *path=[(NSURL *)url path].stringByStandardizingPath;
                    if(path) badges[path]=[[(NSString *)label copy] autorelease];
                }
                if(label) CFRelease(label);
                if(url) CFRelease(url);
            }
            CFRelease(items);
        }
    }
    if(lists) CFRelease(lists);
    CFRelease(app);
    return badges;
}
/* A badge that appears or changes means the application wants looking at. */
static void hwm_attention_poll(double now)
{
    static double last; static _Atomic bool polling; static NSDictionary *previous;
    if(!(hwm_attention_mode&1) || now-last<3) return;
    last=now;
    bool expected=false;
    if(!atomic_compare_exchange_strong(&polling,&expected,true)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        @autoreleasepool {
            NSDictionary *badges=hwm_dock_badges();
            NSMutableArray *pids=[NSMutableArray array];
            // The first reading only establishes what is already there.
            if(previous) for(NSString *path in badges) {
                if([badges[path] isEqual:previous[path]]) continue;
                for(NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications)
                    if([app.bundleURL.path.stringByStandardizingPath isEqual:path]) [pids addObject:@(app.processIdentifier)];
            }
            [previous release]; previous=[badges copy];
            if(pids.count) event_loop_post(&g_event_loop,HORIZONTAL_INPUT,[pids copy],HWM_ATTENTION);
        }
        polling=false;
    });
}

/* ---- Helper recovery --------------------------------------------------- */

/* The scripting addition lives inside Dock and dies with it. When Dock
 * restarts, or the helper stops answering, the configured loader is run; the
 * frame clock's own retry then finds the helper again. The loader needs
 * whatever standing authorization the user already gave it (a sudoers rule):
 * nothing here can ask for a password. */
static NSString *hwm_helper_command;
static bool hwm_helper_auto=true;
static double hwm_helper_last=-100;
static void hwm_helper_reload(void)
{
    double now=hwm_now();
    if(!hwm_helper_auto || !hwm_helper_command.length || now-hwm_helper_last<8 || hwm_helper_attempts>=4) return;
    hwm_helper_last=now; ++hwm_helper_attempts;
    warn("Tana: window helper is not answering; running the loader (attempt %d).\n",hwm_helper_attempts);
    if(hwm_helper_attempts==1) hwm_hud(@"Reconnecting window helper…");
    NSString *command=[hwm_helper_command copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            NSTask *task=[[[NSTask alloc] init] autorelease];
            task.launchPath=@"/bin/sh"; task.arguments=@[@"-c",command];
            task.standardInput=[NSFileHandle fileHandleWithNullDevice];
            // The loader's exit status says nothing useful (it is 1 on success); the handshake decides.
            if([task launchAndReturnError:NULL]) [task waitUntilExit];
            [command release];
        }
        hwm_wake();
    });
}
static void hwm_helper_tick(double now)
{
    if(hwm_helper_due && now>=hwm_helper_due) { hwm_helper_due=0; hwm_helper_attempts=0; hwm_backend_ok=false; hwm_helper_reload(); hwm_wake(); }
}

/* ---- Event stream ------------------------------------------------------ */

static void hwm_ipc_layout(struct view *view)
{
    if(!hwm_ipc_count || !view) return;
    NSMutableArray *windows=[NSMutableArray array];
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w->strip_close_ghost) continue;
        [windows addObject:@{@"id":@(w->id),@"pid":@(w->application->pid),@"app":w->application->name ? @(w->application->name) : @"",
            @"strip":@(hwm_shelf_of(w)+1),@"column":@(w->strip_column),@"x":@(w->strip_world_x),@"y":@(w->strip_world_y),
            @"width":@(w->strip_width),@"height":@(w->strip_height),@"attention":@(w->strip_attention)}];
    }
    hwm_ipc_send(@{@"event":@"layout",@"strip":@(hwm_shelf+1),@"name":hwm_shelf_label(hwm_shelf),@"offset":@(view->strip_target_offset),
                   @"focused":@(g_window_manager.focused_window_id),@"windows":windows});
}

/* ---- Commands ---------------------------------------------------------- */

static void hwm_sticky_toggle(struct view *view,struct window *w)
{
    if(!w) return;
    bool sticky=!w->strip_sticky;
    if(sticky && !window_check_flag(w,WINDOW_FLOAT)) hwm_action(HWM_FLOAT);
    if(!window_check_flag(w,WINDOW_FLOAT)) return;
    w->strip_sticky=sticky;
    // Unpinned, it belongs to the strip it is now seen on.
    if(!sticky) w->strip_shelf=hwm_shelf;
    (void)view; hwm_state_pending=true;
    hwm_hud(sticky ? @"Pinned: stays on every strip" : @"Unpinned");
}

/* Actions added by this layer. Returns false for a name it does not own. */
static bool hwm_extras_action(const char *name)
{
    struct view *view=hwm_view();
    if(!strncmp(name,"jump:",5)) {
        NSArray *parts=[@(name+5) componentsSeparatedByString:@"\t"];
        hwm_jump(parts[0],parts.count>1 ? parts[1] : nil); return true;
    }
    if(!strncmp(name,"layout-load:",12)) { if(!hwm_arrangement_load(@(name+12))) hwm_hud(@"No such layout"); return true; }
    if(!strncmp(name,"layout-save:",12)) {
        NSString *label=[@(name+12) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        hwm_hud(hwm_arrangement_save(label) ? [NSString stringWithFormat:@"Layout saved as “%@”",label] : @"Layout names use letters, digits, spaces, - and _");
        return true;
    }
    if(hwm_paused || hwm_overview_active || hwm_suspended || !view) return false;
    if(!strcmp(name,"strip-up")) { hwm_shelf_go(hwm_shelf-1,true); return true; }
    if(!strcmp(name,"strip-down")) { hwm_shelf_go(hwm_shelf+1,true); return true; }
    if(!strncmp(name,"strip-",6) && name[6]>='1' && name[6]<='9' && !name[7]) {
        int target=name[6]-'1', limit=hwm_shelf_limit(view);
        hwm_shelf_go(target>limit ? limit : target,true); return true;
    }
    if(!strcmp(name,"send-strip-up")) { hwm_shelf_send(view,hwm_action_window(),hwm_shelf-1); return true; }
    if(!strcmp(name,"send-strip-down")) { hwm_shelf_send(view,hwm_action_window(),hwm_shelf+1); return true; }
    if(!strncmp(name,"send-strip-",11) && name[11]>='1' && name[11]<='9' && !name[12]) {
        int target=name[11]-'1', limit=hwm_shelf_limit(view);
        hwm_shelf_send(view,hwm_action_window(),target>limit ? limit : target); return true;
    }
    if(!strcmp(name,"mark")) { hwm_mark_begin(1); return true; }
    if(!strcmp(name,"jump-mark")) { hwm_mark_begin(2); return true; }
    if(!strcmp(name,"sticky")) { hwm_sticky_toggle(view,hwm_action_window()); return true; }
    if(!strcmp(name,"fit-visible") || !strcmp(name,"equalize")) {
        if(!hwm_fit_visible(view,name[0]=='e')) hwm_feedback_navigation(true);
        else { hwm_state_pending=true; hwm_hud(name[0]=='e' ? @"Columns equalized" : @"Columns fitted to screen"); }
        return true;
    }
    return false;
}
