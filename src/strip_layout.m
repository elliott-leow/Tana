/* Serialized strip layout; also exercised with a fake WindowServer in tests. */
/* Opacity Tana wants a window to rest at: full for the focused window, the
 * configured dim level for the rest. 1 disables dimming entirely. */
static float hwm_inactive_alpha=1;
static uint32_t hwm_alpha_focus;
static float hwm_window_alpha(struct window *w)
{
    return hwm_inactive_alpha<1 && w->id!=hwm_alpha_focus ? hwm_inactive_alpha : 1;
}
/* World x of the strip's right end. The camera may travel exactly this far:
 * one viewport of empty desktop past the last window, and no farther. */
static double hwm_content_width;
/* One compositor transaction for everything a frame changes. Mutators open
 * the batch only when they have something to submit; while a frame holds it,
 * nothing is presented until the frame has finished, so a window that is moved
 * and re-scaled in the same frame is never shown half-updated. */
static int hwm_batch_depth;
static bool hwm_batch_open, hwm_batch_hold;
static void hwm_batch_begin(void)
{
    if(!hwm_batch_open) { SLSDisableUpdate(g_connection); hwm_batch_open=true; }
    ++hwm_batch_depth;
}
static void hwm_batch_end(void)
{
    if(hwm_batch_depth>0) --hwm_batch_depth;
    if(!hwm_batch_depth && !hwm_batch_hold && hwm_batch_open) { SLSReenableUpdate(g_connection); hwm_batch_open=false; }
}
static void hwm_batch_release(void)
{
    hwm_batch_hold=false;
    if(!hwm_batch_depth && hwm_batch_open) { SLSReenableUpdate(g_connection); hwm_batch_open=false; }
}
/* A column about to leave the strip. Once layout has closed the hole the camera
 * follows by hstrip_close_shift, so the neighbours on both sides converge
 * instead of only the right-hand ones sliding left. */
static struct { uint32_t id; double x, width, time; bool pending; } hwm_hole;
static void hwm_hole_note(struct view *view,struct window *window)
{
    // A window already vacated for an animated close has had its hole closed.
    if(!view || !window || window->strip_close_ghost || !window->strip_initialized || !view_find_window_node(view,window->id)) return;
    uint64_t column=window->strip_column ? window->strip_column : window->id;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *other=window_manager_find_window(&g_window_manager,n->window_list[i]);
        // A row leaving a stack frees height, not strip width.
        if(other && other!=window && !window->strip_full_width && !other->strip_full_width &&
           (other->strip_column ? other->strip_column : other->id)==column) return;
    }
    hwm_hole.id=window->id; hwm_hole.x=window->strip_world_x; hwm_hole.width=window->strip_width+view->window_gap;
    hwm_hole.time=hwm_now(); hwm_hole.pending=true;
}
static bool hwm_hole_apply(struct view *view,double now)
{
    if(!hwm_hole.pending) return false;
    struct window *leaving=window_manager_find_window(&g_window_manager,hwm_hole.id);
    if(view_find_window_node(view,hwm_hole.id) && !(leaving && leaving->strip_close_ghost)) { if(now-hwm_hole.time>1) hwm_hole.pending=false; return false; }
    hwm_hole.pending=false;
    double offset=hwm_offset(view,now);
    double shift=hstrip_close_shift(hwm_hole.x,hwm_hole.width,offset,hwm_bounds(view).size.width);
    if(shift>0) hwm_scroll(view,fmax(0,offset-shift),true);
    return true;
}
/* Damping ratio for tile positions; below 1 overshoots. Sizes never bounce:
 * an overshooting width would ask the application for a size it then undoes. */
static double hwm_window_zeta=1;
/* Sample one spring-driven component. hwm_duration is the settle horizon: the
 * response is within a fraction of a pixel by then, so the snap is invisible. */
static double hwm_window_sample(double from,double target,double velocity,double elapsed,double zeta,double *out_velocity)
{
    if(elapsed>=hwm_duration || from==target) { *out_velocity=0; if(elapsed>=hwm_duration || velocity==0) return target; }
    return hstrip_spring_damped(from,target,velocity,elapsed,hstrip_spring_omega(hwm_duration,zeta),zeta,out_velocity);
}
static size_t hwm_items(struct view *view, CGRect bounds, HStripColumnItem **out)
{
    size_t count=0;
    for (struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) count+=n->window_count;
    HStripColumnItem *items=calloc(count ? count : 1,sizeof(*items));
    if (!items) { *out=NULL; return 0; }
    size_t i=0;
    for (struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int j=0;j<n->window_count;j++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[j]);
        // A window fading out for a close no longer takes up room in the strip.
        if (!w || w->strip_close_ghost) continue;
        if (!w->strip_column) w->strip_column=w->id;
        if (!(w->strip_weight>0)) w->strip_weight=1;
        if (!(w->strip_width>0)) w->strip_width=fmax(320,bounds.size.width*.58);
        uint64_t column=w->strip_full_width ? ((uint64_t)w->id<<32)|w->id : w->strip_column;
        items[i++]=(HStripColumnItem){w->id,column,w->strip_full_width ? bounds.size.width : fmax(160,w->strip_width),w->strip_weight};
    }
    *out=items; return i;
}
static void hwm_layout(struct view *view, bool animate)
{
    if (!view || view->layout!=VIEW_STRIP || !hwm_ready || hwm_paused) return;
    hwm_state_pending=true;
    CGRect bounds=hwm_bounds(view);
    HStripColumnItem *items; size_t count=hwm_items(view,bounds,&items);
    HStripColumnFrame *frames=calloc(count ? count : 1,sizeof(*frames));
    if (!items || !frames) { free(items); free(frames); return; }
    double now=hwm_now();
    double offset=hwm_offset(view,now);
    hwm_content_width=hstrip_columns_layout(items,count,view->window_gap,bounds.size.height,frames);
    for (size_t i=0;i<count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,(uint32_t)items[i].id);
        HStripColumnFrame f=frames[i];
        hwm_workflow_tab_geometry(view,w,&f.y,&f.height);
        // Retargeting keeps the velocity the window already has, so chained
        // actions bend its path instead of stopping and restarting it.
        double vx=0,vy=0,vw=0,vh=0,elapsed=now-w->strip_start;
        if(animate && w->strip_initialized && elapsed>=0 && elapsed<hwm_duration) {
            hwm_window_sample(w->strip_from_x,w->strip_world_x,w->strip_vel_x,elapsed,hwm_window_zeta,&vx);
            hwm_window_sample(w->strip_from_y,w->strip_world_y,w->strip_vel_y,elapsed,hwm_window_zeta,&vy);
            hwm_window_sample(w->strip_from_width,w->strip_width,w->strip_vel_width,elapsed,1,&vw);
            hwm_window_sample(w->strip_from_height,w->strip_height,w->strip_vel_height,elapsed,1,&vh);
        }
        // Retarget from the last displayed geometry. Width commands change the
        // target before layout, so sampling that target would cause a jump.
        CGRect source=w->strip_last_frame;
        double source_offset=w->strip_last_offset;
        bool restoring_tab=w->strip_tab_parked && !hwm_workflow_tab_hidden(w);
        if(restoring_tab) {
            source=CGRectMake(bounds.origin.x+f.x-offset,bounds.origin.y+f.y,f.width,f.height);
            source_offset=offset;
        }
        if(!w->strip_initialized || CGRectIsNull(source)) {
            if(SLSGetWindowBounds(g_connection,w->id,&source)!=kCGErrorSuccess) source=w->frame;
            source_offset=offset;
        }
        if(animate && !CGRectIsNull(source) && source.size.width>0 && source.size.height>0) {
            w->strip_from_x=source.origin.x-bounds.origin.x+source_offset;
            w->strip_from_y=source.origin.y-bounds.origin.y;
            w->strip_from_width=source.size.width; w->strip_from_height=source.size.height;
        } else {
            w->strip_from_x=f.x; w->strip_from_y=f.y; w->strip_from_width=f.width; w->strip_from_height=f.height;
        }
        if(!w->strip_initialized) {
            w->strip_last_frame=source; w->strip_last_offset=source_offset; w->strip_initialized=true;
            w->layer=LAYER_AUTO; scripting_addition_set_layer(w->id,LAYER_BELOW);
        }
        w->strip_world_x=f.x; w->strip_world_y=f.y; w->strip_width=f.width; w->strip_height=f.height;
        w->strip_start=animate && !restoring_tab?now:now-hwm_duration;
        bool carry=animate && !restoring_tab;
        w->strip_vel_x=carry?vx:0; w->strip_vel_y=carry?vy:0; w->strip_vel_width=carry?vw:0; w->strip_vel_height=carry?vh:0;
        if (!animate) { w->strip_from_x=f.x; w->strip_from_y=f.y; w->strip_from_width=f.width; w->strip_from_height=f.height; }
    }
    if (hwm_close_source && !view_find_window_node(view,hwm_close_source)) {
        struct window *anchor=window_manager_find_window(&g_window_manager,hwm_close_target);
        // Without a recorded hole, hold the focus successor where it was.
        if(!hwm_hole_apply(view,now) && anchor) hwm_scroll(view,anchor->strip_world_x-hwm_close_screen_x,true);
        hwm_close_source=0; hwm_close_time=now;
    } else hwm_hole_apply(view,now);
    free(items); free(frames); view_clear_flag(view,VIEW_IS_DIRTY); hwm_wake();
}
