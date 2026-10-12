/* Real WindowServer transforms. No screenshots, covers, or wallpaper layers. */
#include <stdatomic.h>
typedef struct {
    uint32_t wid;
    pid_t pid;
    CGRect original;
    HWMOverviewRect source, grid, close_from, destination, last;
    bool transformed, has_last;
} HWMNativeOverviewWindow;

static HWMNativeOverviewWindow *hwm_overview_windows;
static size_t hwm_overview_count;
static CGRect hwm_overview_screen;
static double hwm_overview_original_offset, hwm_overview_position;
static bool hwm_overview_closing, hwm_overview_gesture_closing, hwm_overview_animating;
static double hwm_overview_animation_start, hwm_overview_animation_from;
static uint32_t hwm_overview_selected;
static pid_t hwm_overview_selected_pid;
static _Atomic bool hwm_overview_ui_pending;
static uint64_t hwm_overview_frames, hwm_overview_slow_frames;
static double hwm_overview_max_frame_ms;
static NSMutableArray *hwm_overview_borders;
static double hwm_overview_border_from;

static bool hwm_overview_border_owner(uint32_t wid,pid_t pid)
{
    int owner=0; pid_t actual=0;
    if(SLSGetWindowOwner(g_connection,wid,&owner)!=kCGErrorSuccess ||
       SLSConnectionGetPID(owner,&actual)!=kCGErrorSuccess || actual!=pid) return false;
    char name[64]={0}; proc_name(pid,name,sizeof(name));
    return strcmp(name,"borders")==0;
}

static void hwm_overview_hide_borders(void)
{
    hwm_overview_borders=[[NSMutableArray alloc] init];
    CFArrayRef list=CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID);
    for(NSDictionary *entry in (NSArray *)list) {
        uint32_t wid=[entry[(id)kCGWindowNumber] unsignedIntValue];
        pid_t pid=[entry[(id)kCGWindowOwnerPID] intValue];
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
        if(hwm_overview_border_owner(wid,[entry[@"pid"] intValue]))
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

static void hwm_overview_render(double p)
{
    double start=hwm_now();
    // Publish reset+scale for every window as one compositor update. The display
    // never presents the intermediate unscaled frames; no capture cover exists.
    SLSDisableUpdate(g_connection);
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        HWMOverviewRect frame=hwm_overview_closing ? hwm_overview_mix(item->close_from,item->destination,p) :
            hwm_overview_flight(item->source,item->grid,p,hwm_overview_screen.size.height);
        hwm_overview_transform(item,frame);
    }
    double border_visibility=hwm_overview_closing ? hwm_overview_border_from+(1-hwm_overview_border_from)*p : 1-fmin(1,p*4);
    for(NSMutableDictionary *entry in hwm_overview_borders) {
        float alpha=[entry[@"alpha"] floatValue]*border_visibility;
        if(fabs(alpha-[entry[@"last"] floatValue])<.001) continue;
        if(scripting_addition_set_opacity([entry[@"id"] unsignedIntValue],alpha,0)) entry[@"last"]=@(alpha);
    }
    SLSReenableUpdate(g_connection);
    double elapsed=(hwm_now()-start)*1000;
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

static void horizontal_overview_done(void)
{
    if(!hwm_overview_active) return;
    SLSDisableUpdate(g_connection);
    for(size_t i=0;i<hwm_overview_count;i++) hwm_overview_reset_transform(&hwm_overview_windows[i]);
    hwm_overview_restore_borders();
    SLSReenableUpdate(g_connection);
    ++hwm_overview_generation;
    hwm_overview_closing=false; hwm_overview_animating=false;
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

static void hwm_overview_tick(void)
{
    if(!hwm_overview_active) return;
    double p=hwm_overview_position;
    double t=hwm_overview_animating ? fmin(1,(hwm_now()-hwm_overview_animation_start)/.28) : 0;
    if(hwm_overview_animating) {
        double eased=horizontal_ease(t);
        p=hwm_overview_closing ? eased : hwm_overview_animation_from+(1-hwm_overview_animation_from)*eased;
    }
    hwm_overview_render(p);
    if(!hwm_overview_closing) hwm_overview_position=p;
    if(hwm_overview_animating && t>=1) {
        hwm_overview_animating=false;
        if(hwm_overview_closing) { horizontal_overview_done(); return; }
    }
    bool preview_active=hwm_preview_render(hwm_now());
    __atomic_store_n(&hwm_active,hwm_overview_animating || preview_active,__ATOMIC_RELEASE);
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
    hwm_overview_animation_from=hwm_overview_position;
    hwm_overview_animation_start=hwm_now();
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
    [windows addObject:@{@"id":@(w->id),@"pid":@(w->application->pid),@"frame":[NSValue valueWithRect:frame]}];
    [seen addObject:@(w->id)];
}

static void hwm_overview_begin(bool finish)
{
    if(hwm_overview_active || hwm_paused || hwm_suspended || hwm_drag_window) return;
    struct view *view=hwm_view(); if(!view) return;
    hwm_cancel_closing();
    hwm_preview_hide();
    NSMutableArray *windows=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n))
        for(int j=0;j<n->window_count;j++) hwm_overview_add(windows,seen,window_manager_find_window(&g_window_manager,n->window_list[j]));
    table_for(struct window *w,g_window_manager.window,{ hwm_overview_add(windows,seen,w); })
    if(!windows.count) return;
    hwm_overview_screen=display_bounds_constrained(space_display_id(view->sid),false);
    HWMOverviewRect bounds={0,0,hwm_overview_screen.size.width,hwm_overview_screen.size.height};
    HWMOverviewRect *grid=calloc(windows.count,sizeof(*grid));
    hwm_overview_windows=calloc(windows.count,sizeof(*hwm_overview_windows));
    if(!grid || !hwm_overview_windows || !hwm_overview_grid(bounds,windows.count,48,18,grid)) {
        free(grid); free(hwm_overview_windows); hwm_overview_windows=NULL; return;
    }
    hwm_overview_count=windows.count;
    hwm_overview_window_count=(unsigned)windows.count;
    hwm_overview_frames=0; hwm_overview_slow_frames=0; hwm_overview_max_frame_ms=0;
    hwm_hold_focus();
    hwm_overview_original_offset=hwm_offset(view,hwm_now());
    view->strip_scrolling=false; view->strip_target_offset=view->strip_offset;
    __atomic_store_n(&__pending_gesture,false,__ATOMIC_RELEASE);
    hwm_overview_active=true; hwm_overview_closing=false; hwm_overview_animating=false;
    hwm_overview_hide_borders();
    hwm_overview_position=0; hwm_overview_progress=0; hwm_overview_selected=0;
    ++hwm_overview_generation;
    NSMutableArray *entries=[NSMutableArray arrayWithCapacity:windows.count];
    for(size_t i=0;i<windows.count;i++) {
        NSDictionary *entry=windows[i]; HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        item->wid=[entry[@"id"] unsignedIntValue]; item->pid=[entry[@"pid"] intValue];
        item->original=[entry[@"frame"] rectValue]; item->source=hwm_overview_local(item->original);
        item->grid=hwm_overview_fit(item->source,grid[i]);
        if(!hwm_overview_rects_overlap(item->source,bounds)) {
            item->source=item->grid; item->source.y=bounds.height+32;
        }
        [entries addObject:@{@"id":@(item->wid),@"pid":@(item->pid),
            @"source":[NSValue valueWithRect:NSMakeRect(item->source.x,item->source.y,item->source.width,item->source.height)],
            @"grid":[NSValue valueWithRect:NSMakeRect(item->grid.x,item->grid.y,item->grid.width,item->grid.height)]}];
    }
    free(grid);
    dispatch_sync(dispatch_get_main_queue(), ^{
        [[HorizontalWindowOverview sharedOverview] beginWithWindows:entries screenFrame:hwm_overview_screen
            selection:^(uint32_t wid,pid_t pid) { event_loop_post(&g_event_loop,HORIZONTAL_OVERVIEW_SELECT,(void *)(uintptr_t)wid,(int)pid); }
            cancellation:^{ event_loop_post(&g_event_loop,HORIZONTAL_OVERVIEW_SELECT,NULL,0); }];
    });
    if(finish) hwm_overview_finish_opening(); else hwm_wake();
}

static void horizontal_overview_select(uint32_t wid,pid_t pid)
{
    if(!hwm_overview_active || hwm_overview_closing) return;
    hwm_overview_closing=true;
    hwm_overview_border_from=1-fmin(1,hwm_overview_position*4);
    dispatch_async(dispatch_get_main_queue(), ^{ [[HorizontalWindowOverview sharedOverview] beginClosing]; });
    struct view *view=hwm_view();
    struct window *chosen=wid ? window_manager_find_window(&g_window_manager,wid) : NULL;
    if(chosen && (chosen->application->pid!=pid || chosen->strip_ordered_out)) chosen=NULL;
    hwm_overview_selected=chosen ? chosen->id : 0; hwm_overview_selected_pid=pid;
    double target=hwm_overview_original_offset;
    if(chosen && view && window_manager_find_managed_window(&g_window_manager,chosen)==view)
        target=hstrip_center_offset(chosen->strip_world_x,chosen->strip_width,hwm_bounds(view).size.width);
    SLSDisableUpdate(g_connection);
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i];
        item->close_from=hwm_overview_flight(item->source,item->grid,hwm_overview_position,hwm_overview_screen.size.height);
        hwm_overview_reset_transform(item);
    }
    if(view) { hwm_scroll(view,target,false); hwm_layout(view,false); hwm_render(view,hwm_now()+hwm_duration+1); }
    for(size_t i=0;i<hwm_overview_count;i++) {
        HWMNativeOverviewWindow *item=&hwm_overview_windows[i]; struct window *w=hwm_overview_find(item);
        if(!w) continue;
        CGRect frame=CGRectNull;
        if(SLSGetWindowBounds(g_connection,w->id,&frame)==kCGErrorSuccess) item->original=frame;
        item->destination=hwm_overview_local(item->original);
        hwm_overview_transform(item,item->close_from);
    }
    SLSReenableUpdate(g_connection);
    hwm_overview_animation_start=hwm_now(); hwm_overview_animating=true; hwm_wake();
}

static void hwm_overview_gesture(CGEventRef event)
{
    int phase=(int)CGEventGetIntegerValueField(event,132);
    double amount=CGEventGetDoubleValueField(event,124);
    if(!isfinite(amount) || fabs(amount)>20) return;
    hwm_vertical_last_progress=amount;
    if(phase==1) {
        hwm_overview_gesture_closing=hwm_overview_active;
        if(!hwm_overview_active) hwm_overview_begin(false);
        hwm_overview_animating=false;
    }
    if(!hwm_overview_active || hwm_overview_closing) return;
    double progress=hwm_overview_gesture_closing ? 1-fabs(amount)*3 : fabs(amount)*3;
    progress=fmax(0,fmin(1,progress));
    if(phase==1 || phase==2) hwm_overview_set_progress(progress);
    else if(phase==4 || phase==8) {
        bool open=hwm_overview_gesture_closing ? (phase==8 || progress>.7) : (phase!=8 && progress>.12);
        if(open) hwm_overview_finish_opening(); else horizontal_overview_select(0,0);
    }
}
