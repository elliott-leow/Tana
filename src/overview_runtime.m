/* Real WindowServer transforms. No screenshots, covers, or wallpaper layers. */
#include <stdatomic.h>
typedef struct {
    uint32_t wid;
    pid_t pid;
    CGRect original;
    HWMOverviewRect source, grid, close_from, destination, last;
    HWMOverviewRect grid_from; /* where the card was when the grid last changed */
    double regrid_start;
    double hover, hover_from, hover_target, hover_start;
    float alpha;               /* opacity when the overview opened */
    bool dimmed;               /* faded because the search does not match it */
    bool transformed, has_last;
} HWMNativeOverviewWindow;

static HWMNativeOverviewWindow *hwm_overview_windows;
static size_t hwm_overview_count;
static CGRect hwm_overview_screen;
static double hwm_overview_original_offset, hwm_overview_position;
static bool hwm_overview_closing, hwm_overview_gesture_closing, hwm_overview_animating;
static bool hwm_overview_gesture_active;
static double hwm_overview_gesture_time;
static double hwm_overview_animation_start, hwm_overview_animation_from;
static uint32_t hwm_overview_selected;
static pid_t hwm_overview_selected_pid;
static _Atomic bool hwm_overview_ui_pending;
static uint64_t hwm_overview_frames, hwm_overview_slow_frames;
static double hwm_overview_max_frame_ms;
/* Worst time per part of an overview frame, and the cost of opening, in ms. */
static double hwm_overview_queue_max_ms, hwm_overview_flush_max_ms, hwm_overview_present_max_ms, hwm_overview_begin_ms;
static NSMutableArray *hwm_overview_borders;
static double hwm_overview_border_from;
static double hwm_overview_release_velocity; /* progress per second when the fingers lifted */
static double hwm_overview_gesture_velocity, hwm_overview_gesture_last, hwm_overview_gesture_last_time;
static bool hwm_overview_motion; /* a card is still easing toward a new grid slot or hover size */
static uint32_t hwm_overview_drag_wid, hwm_overview_drop_wid;
static HStripPlacement hwm_overview_drop_placement;
static double hwm_overview_regrid_time;
static bool hwm_overview_drag_moved;
static CGPoint hwm_overview_drag_point, hwm_overview_drag_grab;
static const double HWMOverviewRegrid=.32, HWMOverviewHover=.14;

/* A window id can be reused: only touch one still owned by the process it was recorded for. */
static bool hwm_overview_owned_by(uint32_t wid,pid_t pid)
{
    int owner=0; pid_t actual=0;
    return SLSGetWindowOwner(g_connection,wid,&owner)==kCGErrorSuccess &&
           SLSConnectionGetPID(owner,&actual)==kCGErrorSuccess && actual==pid;
}
static bool hwm_overview_border_owner(uint32_t wid,pid_t pid)
{
    if(!hwm_overview_owned_by(wid,pid)) return false;
    char name[64]={0}; proc_name(pid,name,sizeof(name));
    return strcmp(name,"borders")==0;
}
static HWMNativeOverviewWindow *hwm_overview_item(uint32_t wid);

/* Small windows an application attaches to one of its own (the purple
 * screen-sharing pill in a title bar, for one) are separate windows: they do
 * not shrink with the card, and would be left hanging in mid-air where the
 * full-size window used to be. They are hidden while the overview is open. */
static void hwm_overview_hide_attached(void)
{
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        CFArrayRef attached=SLSCopyAssociatedWindows(g_connection,item->wid);
        if(!attached) continue;
        for(CFIndex k=0;k<CFArrayGetCount(attached);k++) {
            uint32_t wid=0; float alpha=1;
            CFNumberGetValue(CFArrayGetValueAtIndex(attached,k),kCFNumberSInt32Type,&wid);
            // Another card is drawn as a card; a window of some other process is not this one's to hide.
            if(!wid || wid==item->wid || hwm_overview_item(wid) || !hwm_overview_owned_by(wid,item->pid)) continue;
            if(SLSGetWindowAlpha(g_connection,wid,&alpha)!=kCGErrorSuccess || alpha<=0) continue;
            [hwm_overview_borders addObject:[NSMutableDictionary dictionaryWithDictionary:
                @{@"id":@(wid),@"pid":@(item->pid),@"alpha":@(alpha),@"last":@(alpha),@"attached":@YES}]];
        }
        CFRelease(attached);
    }
}

static bool hwm_overview_fade_window(uint32_t wid,float opacity,float duration)
{
    return wid && scripting_addition_set_opacity(wid,opacity,duration);
}

static void hwm_overview_hide_borders(void)
{
    hwm_overview_scrim_fade=hwm_overview_fade_window;
    hwm_overview_borders=[[NSMutableArray alloc] init];
    // Listing every window in the session is slow, and only worth it when an
    // external border tool is actually running.
    if(!hwm_borders_external) return;
    CFArrayRef list=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
    pid_t border_pid=0, other_pid=0;
    for(NSDictionary *entry in (NSArray *)list) {
        uint32_t wid=[entry[(id)kCGWindowNumber] unsignedIntValue];
        pid_t pid=[entry[(id)kCGWindowOwnerPID] intValue];
        // One name lookup per process rather than two round trips per window.
        if(pid==other_pid) continue;
        if(pid!=border_pid) {
            char name[64]={0}; proc_name(pid,name,sizeof(name));
            if(strcmp(name,"borders")!=0) { other_pid=pid; continue; }
            border_pid=pid;
        }
        if(!hwm_overview_border_owner(wid,pid)) continue;
        float alpha=1;
        if(SLSGetWindowAlpha(g_connection,wid,&alpha)!=kCGErrorSuccess || alpha<=0) continue;
        [hwm_overview_borders addObject:[NSMutableDictionary dictionaryWithDictionary:
            @{@"id":@(wid),@"pid":@(pid),@"alpha":@(alpha),@"last":@(alpha)}]];
    }
    if(list) CFRelease(list);
}

static void hwm_overview_restore_borders(void)
{
    for(NSDictionary *entry in hwm_overview_borders) {
        uint32_t wid=[entry[@"id"] unsignedIntValue];
        if(hwm_overview_owned_by(wid,[entry[@"pid"] intValue]))
            scripting_addition_set_opacity(wid,[entry[@"alpha"] floatValue],0);
    }
    [hwm_overview_borders release]; hwm_overview_borders=nil;
}

static HWMOverviewRect hwm_overview_local(CGRect frame)
{
    return (HWMOverviewRect){frame.origin.x-hwm_overview_screen.origin.x,
                            frame.origin.y-hwm_overview_screen.origin.y,
                            frame.size.width,frame.size.height};
}

static struct window *hwm_overview_find(HWMNativeOverviewWindow *item)
{
    struct window *w=window_manager_find_window(&g_window_manager,item->wid);
    return w && w->application->pid==item->pid ? w : NULL;
}

static void hwm_overview_reset_transform(HWMNativeOverviewWindow *item)
{
    if(!item->transformed) return;
    if(hwm_overview_find(item)) {
        // The existing helper toggles a scaled window back to its exact native
        // transform. Identity parameters also make a redundant reset harmless.
        scripting_addition_scale_window(item->wid,item->original.origin.x-3*item->original.size.width,
            item->original.origin.y,4*item->original.size.width,item->original.size.height);
    }
    item->transformed=false;
    item->has_last=false;
}

static void hwm_overview_transform(HWMNativeOverviewWindow *item,HWMOverviewRect rect)
{
    if(!hwm_overview_find(item)) { item->transformed=false; return; }
    rect.x=round(rect.x); rect.y=round(rect.y);
    rect.width=fmax(ceil(item->original.size.width/item->original.size.height),round(rect.width));
    if(item->has_last && fabs(rect.x-item->last.x)<.5 && fabs(rect.y-item->last.y)<.5 &&
       fabs(rect.width-item->last.width)<.5) return;
    hwm_overview_reset_transform(item);
    double x=rect.x+hwm_overview_screen.origin.x, y=rect.y+hwm_overview_screen.origin.y;
    if(fabs(x-item->original.origin.x)>.5 || fabs(y-item->original.origin.y)>.5 ||
       fabs(rect.width-item->original.size.width)>.5) {
        // The helper's scale operation uses a quarter-width destination anchored
        // at dx+3*width. Convert our desired frame to that existing protocol.
        item->transformed=scripting_addition_scale_window(item->wid,x-3*rect.width,y,4*rect.width,rect.height);
        if(!item->transformed) ++hwm_move_failures;
    }
    item->last=rect; item->has_last=true;
}

static HWMOverviewRect hwm_overview_mix(HWMOverviewRect a,HWMOverviewRect b,double p)
{
    return (HWMOverviewRect){a.x+(b.x-a.x)*p,a.y+(b.y-a.y)*p,
                            a.width+(b.width-a.width)*p,a.height+(b.height-a.height)*p};
}

/* Where a card is drawn right now, before the closing blend. */
static HWMOverviewRect hwm_overview_current(HWMNativeOverviewWindow *item,double p,double now)
{
    HWMOverviewRect grid=item->grid;
    double regrid=now-item->regrid_start;
    if(regrid<HWMOverviewRegrid) { grid=hwm_overview_mix(item->grid_from,item->grid,hstrip_spring_progress(regrid,HWMOverviewRegrid)); hwm_overview_motion=true; }
    HWMOverviewRect frame=hwm_overview_flight(item->source,grid,p,hwm_overview_screen.size.height);
    double hover=now-item->hover_start;
    if(hover<HWMOverviewHover) { item->hover=item->hover_from+(item->hover_target-item->hover_from)*hstrip_spring_progress(hover,HWMOverviewHover); hwm_overview_motion=true; }
    else item->hover=item->hover_target;
    if(item->hover>0) frame=hwm_overview_inflate(frame,1+(HWMOverviewHoverScale-1)*item->hover*p);
    if(item->wid==hwm_overview_drag_wid) {
        // A carried card follows the pointer exactly; it is not eased.
        frame.x=hwm_overview_drag_point.x-hwm_overview_drag_grab.x; frame.y=hwm_overview_drag_point.y-hwm_overview_drag_grab.y;
        hwm_overview_motion=true;
    }
    return frame;
}

static void hwm_overview_render(double p)
{
    double start=hwm_now(), frame=hwm_frame_time(start);
    hwm_overview_motion=false;
    // Publish reset+scale for every window as one compositor update. The display
    // never presents the intermediate unscaled frames; no capture cover exists.
    SLSDisableUpdate(g_connection);
    // Two helper commands per card: handed over together, awaited once.
    scripting_addition_batch_begin();
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        HWMOverviewRect shown=hwm_overview_closing ? hwm_overview_mix(item->close_from,item->destination,p) :
            hwm_overview_current(item,p,frame);
        hwm_overview_transform(item,shown);
    }
    double border_visibility=hwm_overview_closing ? hwm_overview_border_from+(1-hwm_overview_border_from)*p : 1-fmin(1,p*4);
    for(NSMutableDictionary *entry in hwm_overview_borders) {
        // An attached window is gone almost at once and returns only when its window is back in place.
        double visibility=[entry[@"attached"] boolValue] ? (hwm_overview_closing ? 0 : 1-fmin(1,p*12)) : border_visibility;
        float alpha=[entry[@"alpha"] floatValue]*visibility;
        if(fabs(alpha-[entry[@"last"] floatValue])<.001) continue;
        if(scripting_addition_set_opacity([entry[@"id"] unsignedIntValue],alpha,0)) entry[@"last"]=@(alpha);
    }
    double queued=hwm_now();
    if(!scripting_addition_batch_end()) ++hwm_move_failures;
    double flushed=hwm_now();
    SLSReenableUpdate(g_connection);
    double elapsed=(hwm_now()-start)*1000;
    hwm_overview_queue_max_ms=fmax(hwm_overview_queue_max_ms,(queued-start)*1000);
    hwm_overview_flush_max_ms=fmax(hwm_overview_flush_max_ms,(flushed-queued)*1000);
    hwm_overview_present_max_ms=fmax(hwm_overview_present_max_ms,elapsed-(flushed-start)*1000);
    ++hwm_overview_frames;
    if(elapsed>8.34) ++hwm_overview_slow_frames;
    if(elapsed>hwm_overview_max_frame_ms) hwm_overview_max_frame_ms=elapsed;
    if(!hwm_overview_closing) {
        hwm_overview_progress=p;
        bool expected=false;
        if(atomic_compare_exchange_strong(&hwm_overview_ui_pending,&expected,true)) {
            uint64_t generation=hwm_overview_generation;
            dispatch_async(dispatch_get_main_queue(), ^{
                hwm_overview_ui_pending=false;
                if(generation==hwm_overview_generation && hwm_overview_active)
                    [[HorizontalWindowOverview sharedOverview] setProgress:hwm_overview_progress];
            });
        }
    }
}

/* Search dimming is undone before the windows return to the strip. */
static void hwm_overview_undim(float duration)
{
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        if(!item->dimmed) continue;
        item->dimmed=false;
        if(hwm_overview_find(item)) scripting_addition_set_opacity(item->wid,item->alpha,duration);
    }
}

static void horizontal_overview_done(void)
{
    if(!hwm_overview_active) return;
    SLSDisableUpdate(g_connection);
    scripting_addition_batch_begin();
    for(size_t i=0;i<hwm_overview_count;i++) hwm_overview_reset_transform(&hwm_overview_windows[i]);
    hwm_overview_undim(0);
    hwm_overview_drag_wid=0; hwm_overview_drop_wid=0; hwm_preview_hide();
    hwm_overview_restore_borders();
    if(!scripting_addition_batch_end()) ++hwm_move_failures;
    SLSReenableUpdate(g_connection);
    ++hwm_overview_generation;
    hwm_overview_closing=false; hwm_overview_animating=false; hwm_overview_gesture_active=false;
    free(hwm_overview_windows); hwm_overview_windows=NULL; hwm_overview_count=0;
    struct window *selected=window_manager_find_window(&g_window_manager,hwm_overview_selected);
    if(!hwm_suspended && selected && selected->application->pid==hwm_overview_selected_pid)
        window_manager_focus_window_with_raise(&selected->application->psn,selected->id,selected->ref);
    hwm_overview_selected=0;
    hwm_overview_active=false;
    table_for(struct window *w,g_window_manager.window, {
        if(w->strip_float_animating) {
            CGRect target=w->strip_float_target;
            w->strip_float_animating=false;
            hwm_float_to(w,target);
        }
    })
    dispatch_async(dispatch_get_main_queue(), ^{ [[HorizontalWindowOverview sharedOverview] dismissImmediately]; });
    hwm_hold_focus(); hwm_wake();
}

/* Progress carried on from the last finger report to now, as for a held
 * horizontal swipe (see hwm_held_velocity): frames advance evenly however the
 * reports happen to fall between them. */
static double hwm_overview_held_progress(double now)
{
    double p=hwm_overview_position;
    if(!hwm_overview_gesture_active || hwm_overview_animating || hwm_overview_closing || hwm_motion_scale==0) return p;
    double speed=hwm_overview_gesture_velocity*(hwm_overview_gesture_closing?-1:1);
    return fmax(0,fmin(1,p+speed*fmax(0,fmin(HWMHeldLeadMax,now-hwm_overview_gesture_last_time))));
}

static void hwm_overview_tick(void)
{
    if(!hwm_overview_active) return;
    // A cancelled/lost event stream must not leave the input overlay up forever.
    if(hwm_overview_gesture_active && hwm_now()-hwm_overview_gesture_time>.8)
        horizontal_overview_select(0,0);
    double p=hwm_overview_held_progress(hwm_now()), now=hwm_frame_time(hwm_now()), elapsed=now-hwm_overview_animation_start, velocity;
    bool finished=false, settling=hwm_overview_animating;
    if(hwm_overview_animating) {
        // The settle continues at the speed the fingers were moving, so a quick
        // flick opens briskly and a slow lift eases in.
        double from=hwm_overview_closing ? 0 : hwm_overview_animation_from;
        p=hstrip_spring(from,1,hwm_overview_release_velocity,elapsed,hstrip_spring_omega(hwm_overview_duration,1),&velocity);
        p=fmax(0,fmin(1,p));
        finished=elapsed>=hwm_overview_duration;
        if(finished) p=1;
    }
    hwm_overview_render(p);
    // A held gesture's position belongs to the fingers; only a settle writes it back.
    if(!hwm_overview_closing && settling) hwm_overview_position=p;
    if(hwm_overview_animating && finished) {
        hwm_overview_animating=false;
        if(hwm_overview_closing) { horizontal_overview_done(); return; }
    }
    bool preview_active=hwm_preview_render(hwm_now());
    __atomic_store_n(&hwm_active,hwm_overview_animating || hwm_overview_gesture_active || preview_active || hwm_overview_motion,__ATOMIC_RELEASE);
}

static void hwm_overview_set_progress(double progress)
{
    if(!hwm_overview_active || hwm_overview_closing) return;
    hwm_overview_animating=false;
    hwm_overview_position=fmax(0,fmin(1,progress));
    hwm_wake();
}

static void hwm_overview_finish_opening(void)
{
    hwm_overview_gesture_active=false;
    hwm_overview_animation_from=hwm_overview_position;
    hwm_overview_animation_start=hwm_now();
    hwm_overview_release_velocity=fmax(0,fmin(12,hwm_overview_gesture_velocity));
    hwm_overview_gesture_velocity=0;
    hwm_overview_animating=true; hwm_wake();
}

static void hwm_overview_add(NSMutableArray *windows,NSMutableSet *seen,struct window *w)
{
    if(!w || [seen containsObject:@(w->id)] || w->application->pid==getpid() ||
       !window_manager_is_window_eligible(w) || !window_is_standard(w) ||
       window_check_flag(w,WINDOW_MINIMIZE) || window_check_flag(w,WINDOW_FULLSCREEN) ||
       w->application->is_hidden || w->strip_ordered_out) return;
    struct view *view=window_manager_find_managed_window(&g_window_manager,w);
    if((!view || view->layout!=VIEW_STRIP) && !window_check_flag(w,WINDOW_FLOAT)) return;
    uint8_t ordered=0; CGRect frame=CGRectNull;
    if(SLSWindowIsOrderedIn(g_connection,w->id,&ordered)!=kCGErrorSuccess || !ordered ||
       SLSGetWindowBounds(g_connection,w->id,&frame)!=kCGErrorSuccess || frame.size.width<=0 || frame.size.height<=0) return;
    // Titles arrive in the background; opening never waits on an application.
    NSString *title=hwm_ax_title(w->id,w->ref,@"",hwm_now(),^(uint32_t wid,NSString *fetched) {
        dispatch_async(dispatch_get_main_queue(),^{ [[HorizontalWindowOverview sharedOverview] setTitle:fetched forWindow:wid]; });
    });
    [windows addObject:@{@"id":@(w->id),@"pid":@(w->application->pid),@"frame":[NSValue valueWithRect:frame],
        @"title":title ?: @"",@"app":w->application->name ? @(w->application->name) : @"",
        @"column":@(view ? w->strip_column : w->id)}];
    [seen addObject:@(w->id)];
}

static void hwm_overview_begin(bool finish)
{
    if(hwm_overview_active || hwm_paused || hwm_suspended || hwm_drag_window) return;
    struct view *view=hwm_view(); if(!view) return;
    double began=hwm_now();
    hwm_cancel_closing();
    hwm_feedback_hide();
    hwm_preview_hide();
    NSMutableArray *windows=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n))
        for(int j=0;j<n->window_count;j++) hwm_overview_add(windows,seen,window_manager_find_window(&g_window_manager,n->window_list[j]));
    table_for(struct window *w,g_window_manager.window,{ hwm_overview_add(windows,seen,w); })
    if(!windows.count) return;
    hwm_overview_screen=hwm_screen(view);
    HWMOverviewRect bounds={0,0,hwm_overview_screen.size.width,hwm_overview_screen.size.height};
    HWMOverviewRect *grid=calloc(windows.count,sizeof(*grid));
    hwm_overview_windows=calloc(windows.count,sizeof(*hwm_overview_windows));
    size_t *groups=calloc(windows.count,sizeof(*groups));
    if(groups) for(size_t i=0;i<windows.count;i++) groups[i]=[windows[i][@"column"] unsignedLongLongValue];
    bool grid_ok=grid && hwm_overview_grouped_grid(bounds,windows.count,groups,48,18,grid);
    free(groups);
    if(!grid || !hwm_overview_windows || !grid_ok) {
        free(grid); free(hwm_overview_windows); hwm_overview_windows=NULL; return;
    }
    hwm_overview_count=windows.count;
    hwm_overview_window_count=(unsigned)windows.count;
    hwm_overview_frames=0; hwm_overview_slow_frames=0; hwm_overview_max_frame_ms=0;
    hwm_overview_queue_max_ms=0; hwm_overview_flush_max_ms=0; hwm_overview_present_max_ms=0;
    hwm_hold_focus();
    hwm_overview_original_offset=hwm_offset(view,hwm_now());
    view->strip_scrolling=false; view->strip_target_offset=view->strip_offset;
    __atomic_store_n(&__pending_gesture,false,__ATOMIC_RELEASE);
    hwm_overview_active=true; hwm_overview_closing=false; hwm_overview_animating=false; hwm_overview_gesture_active=false;
    hwm_overview_hide_borders();
    hwm_overview_position=0; hwm_overview_progress=0; hwm_overview_selected=0;
    hwm_overview_drag_wid=0; hwm_overview_drop_wid=0; hwm_overview_gesture_velocity=0; hwm_overview_release_velocity=0;
    hwm_overview_scrim_strength=hwm_motion_scale==0 ? fmin(hwm_overview_dim,.5) : hwm_overview_dim; hwm_overview_fade_duration=hwm_overview_duration;
    ++hwm_overview_generation;
    NSMutableArray *entries=[NSMutableArray arrayWithCapacity:windows.count];
    for(size_t i=0;i<windows.count;i++) {
        NSDictionary *entry=windows[i]; HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        item->wid=[entry[@"id"] unsignedIntValue]; item->pid=[entry[@"pid"] intValue];
        item->original=[entry[@"frame"] rectValue]; item->source=hwm_overview_local(item->original);
        item->grid=hwm_overview_fit(item->source,grid[i]);
        item->grid_from=item->grid; item->regrid_start=-1000; item->hover_start=-1000;
        item->alpha=1; if(SLSGetWindowAlpha(g_connection,item->wid,&item->alpha)!=kCGErrorSuccess || item->alpha<=0) item->alpha=1;
        if(hwm_motion_scale==0) item->source=item->grid;
        if(!hwm_overview_rects_overlap(item->source,bounds)) {
            item->source=item->grid; item->source.y=bounds.height+32;
        }
        [entries addObject:@{@"id":@(item->wid),@"pid":@(item->pid),@"title":entry[@"title"],@"app":entry[@"app"],@"column":entry[@"column"],
            @"focused":@(item->wid==g_window_manager.focused_window_id),
            @"source":[NSValue valueWithRect:NSMakeRect(item->source.x,item->source.y,item->source.width,item->source.height)],
            @"grid":[NSValue valueWithRect:NSMakeRect(item->grid.x,item->grid.y,item->grid.width,item->grid.height)]}];
    }
    free(grid);
    hwm_overview_hide_attached();
    // Not waited for: the cards start moving on this thread's next frame while
    // the main thread raises the overlay. Everything sent to the overlay
    // afterwards goes through the same queue, so it still arrives in order.
    CGRect screen=hwm_overview_screen; uint64_t generation=hwm_overview_generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(generation!=hwm_overview_generation || !hwm_overview_active) return;
        HorizontalWindowOverview *overview=[HorizontalWindowOverview sharedOverview];
        [overview setHighlightHandler:^(uint32_t wid) { event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)(uintptr_t)wid,HWM_OVERVIEW_HIGHLIGHT); }];
        [overview setFilterHandler:^(NSArray *dimmed) { event_loop_post(&g_event_loop,HORIZONTAL_INPUT,[dimmed copy],HWM_OVERVIEW_FILTER); }];
        [overview setDragHandler:^(uint32_t wid,int phase,NSPoint point) {
            event_loop_post(&g_event_loop,HORIZONTAL_INPUT,[@[@(wid),@(phase),@(point.x),@(point.y)] retain],HWM_OVERVIEW_DRAG);
        }];
        [overview beginWithWindows:entries screenFrame:screen
            selection:^(uint32_t wid,pid_t pid) { event_loop_post(&g_event_loop,HORIZONTAL_OVERVIEW_SELECT,(void *)(uintptr_t)wid,(int)pid); }
            cancellation:^{ event_loop_post(&g_event_loop,HORIZONTAL_OVERVIEW_SELECT,NULL,0); }];
    });
    hwm_overview_begin_ms=(hwm_now()-began)*1000;
    if(finish) hwm_overview_finish_opening(); else hwm_wake();
}

static void horizontal_overview_select(uint32_t wid,pid_t pid)
{
    if(!hwm_overview_active || hwm_overview_closing) return;
    hwm_overview_gesture_active=false;
    hwm_overview_undim(.14f);
    hwm_overview_drag_wid=0; hwm_overview_drop_wid=0; hwm_preview_hide();
    double closing_now=hwm_frame_time(hwm_now());
    for(size_t i=0;i<hwm_overview_count;i++) hwm_overview_windows[i].close_from=hwm_overview_current(&hwm_overview_windows[i],hwm_overview_position,closing_now);
    hwm_overview_closing=true;
    hwm_overview_release_velocity=fmax(0,fmin(12,hwm_overview_gesture_velocity)); hwm_overview_gesture_velocity=0;
    hwm_overview_border_from=1-fmin(1,hwm_overview_position*4);
    dispatch_async(dispatch_get_main_queue(), ^{ [[HorizontalWindowOverview sharedOverview] beginClosing]; });
    struct view *view=hwm_view();
    struct window *chosen=wid ? window_manager_find_window(&g_window_manager,wid) : NULL;
    if(chosen && (chosen->application->pid!=pid || chosen->strip_ordered_out)) chosen=NULL;
    if(chosen) hwm_workflow_note_explicit_focus(chosen,view);
    hwm_overview_selected=chosen ? chosen->id : 0; hwm_overview_selected_pid=pid;
    double target=hwm_overview_original_offset;
    if(chosen && view && window_manager_find_managed_window(&g_window_manager,chosen)==view)
        target=hstrip_center_offset(chosen->strip_world_x,chosen->strip_width,hwm_bounds(view).size.width);
    SLSDisableUpdate(g_connection);
    scripting_addition_batch_begin();
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        hwm_overview_reset_transform(item);
    }
    if(view) { hwm_scroll(view,target,false); hwm_layout(view,false); hwm_render(view,hwm_now()+hwm_duration+1); }
    // The windows' resting places are measured next, so they must have arrived.
    if(!scripting_addition_batch_flush()) ++hwm_move_failures;
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i]; struct window *w=hwm_overview_find(item);
        if(!w) continue;
        CGRect frame=CGRectNull;
        if(SLSGetWindowBounds(g_connection,w->id,&frame)==kCGErrorSuccess) item->original=frame;
        item->destination=hwm_overview_local(item->original);
        hwm_overview_transform(item,item->close_from);
    }
    if(!scripting_addition_batch_end()) ++hwm_move_failures;
    SLSReenableUpdate(g_connection);
    hwm_overview_animation_start=hwm_now(); hwm_overview_animating=true; hwm_wake();
}

static void hwm_overview_gesture(CGEventRef event)
{
    int phase=(int)CGEventGetIntegerValueField(event,132);
    double amount=CGEventGetDoubleValueField(event,124);
    if(!isfinite(amount) || fabs(amount)>20) return;
    hwm_vertical_last_progress=amount;
    // Closing owns the transforms until cleanup. In particular, a new begin
    // must not clear animating and strand an active, input-blocking overview.
    if(hwm_overview_closing) return;
    if(phase==1) {
        hwm_overview_gesture_closing=hwm_overview_active;
        if(!hwm_overview_active) hwm_overview_begin(false);
        if(!hwm_overview_active) return;
        hwm_overview_gesture_active=true;
        hwm_overview_animating=false;
    }
    if(!hwm_overview_active || !hwm_overview_gesture_active) return;
    double gesture_now=hwm_event_time(event,hwm_now());
    hwm_overview_gesture_time=hwm_now();
    double progress=hwm_overview_gesture_closing ? 1-fabs(amount)*3 : fabs(amount)*3;
    progress=fmax(0,fmin(1,progress));
    double dt=gesture_now-hwm_overview_gesture_last_time;
    if(phase==1) hwm_overview_gesture_velocity=0;
    else if(phase==2 && dt>.001 && dt<.15) {
        // Speed in the direction of travel: toward open while opening, toward closed while closing.
        double speed=(progress-hwm_overview_gesture_last)/dt*(hwm_overview_gesture_closing?-1:1);
        hwm_overview_gesture_velocity=hwm_overview_gesture_velocity*.6+speed*.4;
    }
    if(phase==1 || phase==2) { hwm_overview_gesture_last=progress; hwm_overview_gesture_last_time=gesture_now; }
    if((phase==4 || phase==8) && gesture_now-hwm_overview_gesture_last_time>.1) hwm_overview_gesture_velocity=0;
    if(phase==1 || phase==2) hwm_overview_set_progress(progress);
    else if(phase==4 || phase==8) {
        // The settle starts from where the last frame drew the cards.
        hwm_overview_position=hwm_overview_held_progress(hwm_now());
        bool open=hwm_overview_gesture_closing ? (phase==8 || progress>.7) : (phase!=8 && progress>.12);
        if(open) hwm_overview_finish_opening(); else horizontal_overview_select(0,0);
    }
}

static HWMNativeOverviewWindow *hwm_overview_item(uint32_t wid)
{
    for(size_t i=0;i<hwm_overview_count;i++) if(hwm_overview_windows[i].wid==wid) return &hwm_overview_windows[i];
    return NULL;
}

/* The overlay reports which card is chosen; that card lifts slightly. */
static void hwm_overview_highlight(uint32_t wid)
{
    if(!hwm_overview_active || hwm_overview_closing) return;
    double now=hwm_now();
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        double target=item->wid==wid && hwm_motion_scale>0 ? 1 : 0;
        if(target==item->hover_target) continue;
        item->hover_from=item->hover; item->hover_target=target; item->hover_start=now;
    }
    hwm_wake();
}

/* Cards the search does not match fade back so the matches stand out. */
static void hwm_overview_filter(NSArray *dimmed)
{
    if(!hwm_overview_active || hwm_overview_closing) return;
    NSSet *ids=[NSSet setWithArray:dimmed];
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        bool dim=[ids containsObject:@(item->wid)];
        if(dim==item->dimmed || !hwm_overview_find(item)) continue;
        item->dimmed=dim;
        scripting_addition_set_opacity(item->wid,dim ? item->alpha*.2f : item->alpha,.14f);
    }
}

/* Recompute the grid from the strip's current order and ease every card to its
 * new cell. Called after a card was dropped somewhere else in the overview. */
static void hwm_overview_regrid(struct view *view)
{
    size_t count=hwm_overview_count; if(!count) return;
    HWMNativeOverviewWindow *ordered=calloc(count,sizeof(*ordered));
    HWMOverviewRect *grid=calloc(count,sizeof(*grid)); size_t *groups=calloc(count,sizeof(*groups));
    bool *taken=calloc(count,sizeof(*taken));
    if(!ordered || !grid || !groups || !taken) { free(ordered); free(grid); free(groups); free(taken); return; }
    double now=hwm_now(); size_t n=0;
    hwm_overview_regrid_time=now;
    // Strip order first, then everything else (floating windows) as before.
    for(struct window_node *node=window_node_find_first_leaf(view->root);node;node=window_node_find_next_leaf(node)) for(int j=0;j<node->window_count;j++) {
        for(size_t i=0;i<count;i++) if(!taken[i] && hwm_overview_windows[i].wid==node->window_list[j]) {
            struct window *w=hwm_overview_find(&hwm_overview_windows[i]);
            taken[i]=true; groups[n]=w ? (size_t)w->strip_column : hwm_overview_windows[i].wid; ordered[n++]=hwm_overview_windows[i];
        }
    }
    for(size_t i=0;i<count;i++) if(!taken[i]) { groups[n]=hwm_overview_windows[i].wid; ordered[n++]=hwm_overview_windows[i]; }
    HWMOverviewRect bounds={0,0,hwm_overview_screen.size.width,hwm_overview_screen.size.height};
    if(hwm_overview_grouped_grid(bounds,count,groups,48,18,grid)) {
        NSMutableArray *entries=[NSMutableArray arrayWithCapacity:count];
        for(size_t i=0;i<count;i++) {
            HWMNativeOverviewWindow *item=&ordered[i];
            // Start from where the card is drawn now, including one just let go of.
            HWMOverviewRect from=item->has_last ? item->last : item->grid;
            from.height=from.width*item->original.size.height/fmax(1,item->original.size.width);
            item->grid_from=from; item->grid=hwm_overview_fit(hwm_overview_local(item->original),grid[i]);
            item->regrid_start=hwm_motion_scale>0 ? now : -1000;
            struct window *w=hwm_overview_find(item);
            NSString *title=w ? hwm_ax_title(w->id,w->ref,@"",now,nil) : nil;
            [entries addObject:@{@"id":@(item->wid),@"pid":@(item->pid),@"title":title ?: @"",@"app":w && w->application->name ? @(w->application->name) : @"",
                @"column":@(groups[i]),
                @"source":[NSValue valueWithRect:NSMakeRect(item->source.x,item->source.y,item->source.width,item->source.height)],
                @"grid":[NSValue valueWithRect:NSMakeRect(item->grid.x,item->grid.y,item->grid.width,item->grid.height)]}];
        }
        memcpy(hwm_overview_windows,ordered,count*sizeof(*ordered));
        uint64_t generation=hwm_overview_generation;
        dispatch_async(dispatch_get_main_queue(), ^{
            if(generation==hwm_overview_generation && hwm_overview_active) [[HorizontalWindowOverview sharedOverview] updateWindows:entries];
        });
    }
    free(ordered); free(grid); free(groups); free(taken);
}

/* A cheap fingerprint of the strip's order and column membership. */
static uint64_t hwm_overview_order(struct view *view)
{
    uint64_t hash=1469598103934665603ULL;
    for(struct window_node *node=window_node_find_first_leaf(view->root);node;node=window_node_find_next_leaf(node)) for(int j=0;j<node->window_count;j++) {
        struct window *w=window_manager_find_window(&g_window_manager,node->window_list[j]);
        hash=(hash^node->window_list[j])*1099511628211ULL;
        hash=(hash^(w ? w->strip_column : 0))*1099511628211ULL;
    }
    return hash;
}

/* Rearranging from the overview. A carried card follows the pointer and the
 * other cards make room for it as it passes over them, so what is on screen is
 * always where the window will land; there is nothing to aim at. Releasing
 * leaves it there, Escape puts everything back.
 *   phase 0 pick up, 1 carry, 2 release, 3/4 nudge left/right from the
 *   keyboard, 5 cancel. */
static void hwm_overview_drag(uint32_t wid,int phase,CGPoint point)
{
    if(!hwm_overview_active || hwm_overview_closing) return;
    struct view *view=hwm_view();
    HWMNativeOverviewWindow *item=hwm_overview_item(wid);
    if(!view || !item) { hwm_overview_drag_wid=0; return; }
    struct window *window=hwm_overview_find(item);
    // Only tiles have a place in the strip; a floating window is not reordered.
    bool tile=window && view_find_window_node(view,wid);
    if(phase==3 || phase==4) {
        if(tile && hwm_move_column(view,window,phase==3?-1:1)) { hwm_state_pending=true; hwm_overview_regrid(view); hwm_wake(); }
        return;
    }
    if(phase==0) {
        if(!tile) return;
        HWMOverviewRect shown=item->has_last ? item->last : item->grid;
        hwm_undo_capture();
        hwm_overview_drag_wid=wid; hwm_overview_drop_wid=0; hwm_overview_drag_moved=false;
        hwm_overview_drag_grab=CGPointMake(point.x-shown.x,point.y-shown.y); hwm_overview_drag_point=point;
        scripting_addition_order_window(wid,1,0);
        hwm_wake(); return;
    }
    if(hwm_overview_drag_wid!=wid) return;
    if(phase==5) {
        hwm_overview_drag_wid=0; hwm_overview_drop_wid=0;
        if(hwm_overview_drag_moved) hwm_undo_restore();
        hwm_overview_regrid(view); hwm_wake(); return;
    }
    hwm_overview_drag_point=point;
    if(phase==2) {
        // Already in place: the card only has to settle from the pointer into its cell.
        hwm_overview_drag_wid=0; hwm_overview_drop_wid=0;
        hwm_overview_regrid(view); hwm_wake(); return;
    }
    hwm_wake();
    // Let the cards finish making room before judging the pointer against them again.
    if(hwm_now()-hwm_overview_regrid_time<.16) return;
    HWMNativeOverviewWindow *target=NULL;
    for(size_t i=0;i<hwm_overview_count && !target;i++) {
        HWMNativeOverviewWindow *other=&hwm_overview_windows[i];
        if(other->wid==wid || !view_find_window_node(view,other->wid)) continue;
        HWMOverviewRect cell=hwm_overview_inflate(other->grid,1); cell.x-=9; cell.width+=18; cell.y-=9; cell.height+=18;
        if(point.x>=cell.x && point.x<=cell.x+cell.width && point.y>=cell.y && point.y<=cell.y+cell.height) target=other;
    }
    if(!target) return;
    HStripPlacement placement=point.x<target->grid.x+target->grid.width*.5 ? HSTRIP_BEFORE_COLUMN : HSTRIP_AFTER_COLUMN;
    if(hwm_overview_drop_wid==target->wid && hwm_overview_drop_placement==placement) return;
    hwm_overview_drop_wid=target->wid; hwm_overview_drop_placement=placement;
    uint64_t before=hwm_overview_order(view);
    if(hwm_place(view,wid,target->wid,placement,true,NULL) && hwm_overview_order(view)!=before) {
        hwm_overview_drag_moved=true; hwm_state_pending=true;
        hwm_overview_regrid(view);
    }
}
