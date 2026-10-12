/* Native edge resizing owns the dragged window until mouse-up. Never animate
 * an AX notification back at the application while its resize loop is active. */
static uint32_t hwm_edge_window, hwm_edge_neighbor;
static unsigned hwm_edge_direction;
static CGRect hwm_edge_origin;
static double hwm_edge_offset, hwm_edge_pair_height, hwm_edge_pair_weight;
static bool hwm_edge_changed;

static void horizontal_mouse_down(struct window *w, CGPoint p)
{
    hwm_edge_window=0; hwm_edge_neighbor=0; hwm_edge_changed=false;
    if(!hwm_ready || hwm_paused || hwm_overview_active || !w) return;
    struct view *v=window_manager_find_managed_window(&g_window_manager,w);
    if(!v || v->layout!=VIEW_STRIP || g_mouse_state.current_action==MOUSE_MODE_MOVE) return;
    CGRect f=g_mouse_state.window_frame;
    unsigned direction=0;
    if(g_mouse_state.current_action==MOUSE_MODE_RESIZE) direction=g_mouse_state.direction;
    else {
        if(fabs(p.x-CGRectGetMinX(f))<=9) direction|=HANDLE_LEFT;
        if(fabs(p.x-CGRectGetMaxX(f))<=9) direction|=HANDLE_RIGHT;
        if(fabs(p.y-CGRectGetMinY(f))<=6) direction|=HANDLE_TOP;
        if(fabs(p.y-CGRectGetMaxY(f))<=9) direction|=HANDLE_BOTTOM;
    }
    if(!direction) return;
    hwm_edge_window=w->id; hwm_edge_origin=f; hwm_edge_direction=direction;
    hwm_edge_offset=hwm_offset(v,hwm_now()); v->strip_scrolling=false;
    hwm_edge_pair_height=0; hwm_edge_pair_weight=0;
    double nearest=INFINITY;
    table_for(struct window *other,g_window_manager.window, {
        if(other!=w && other->strip_column==w->strip_column && window_manager_find_managed_window(&g_window_manager,other)==v) {
            double delta=other->strip_world_y-w->strip_world_y;
            if(((direction&HANDLE_TOP && delta<0) || (direction&HANDLE_BOTTOM && delta>0)) && fabs(delta)<nearest) {
                nearest=fabs(delta); hwm_edge_neighbor=other->id;
                hwm_edge_pair_height=w->strip_height+other->strip_height;
                hwm_edge_pair_weight=w->strip_weight+other->strip_weight;
            }
        }
    })
    w->strip_size_pending=false; hwm_hold_focus(); hwm_wake();
}

static bool hwm_edge_update(struct window *w, struct view *v)
{
    if(!w || w->id!=hwm_edge_window) return false;
    CGRect actual=CGRectNull;
    if(SLSGetWindowBounds(g_connection,w->id,&actual)!=kCGErrorSuccess || !isfinite(actual.size.width) || actual.size.width<100) return true;
    if(CGSizeEqualToSize(actual.size,hwm_edge_origin.size) && !hwm_edge_changed) {
        // A title-bar drag can begin in the narrow top-edge hit band. Wait for
        // real geometry evidence rather than treating every such click as a resize.
        if(g_mouse_state.current_action!=MOUSE_MODE_RESIZE &&
           hypot(actual.origin.x-hwm_edge_origin.origin.x,actual.origin.y-hwm_edge_origin.origin.y)>3) {
            hwm_edge_window=0; hwm_edge_neighbor=0; hwm_drag_started(w);
            return false;
        }
        return true;
    }
    if(!hwm_edge_changed) { hwm_undo_capture(); hwm_edge_changed=true; }
    if(fabs(actual.size.width-w->strip_width)>.5) hwm_column_width(v,w,actual.size.width);
    struct window *neighbor=window_manager_find_window(&g_window_manager,hwm_edge_neighbor);
    if(neighbor && hwm_edge_pair_height>0 && hwm_edge_pair_weight>0) {
        double height=fmax(80,fmin(hwm_edge_pair_height-80,actual.size.height));
        w->strip_weight=hwm_edge_pair_weight*height/hwm_edge_pair_height;
        neighbor->strip_weight=hwm_edge_pair_weight-w->strip_weight;
    }
    if(hwm_edge_direction&HANDLE_LEFT)
        hwm_scroll(v,hwm_edge_offset+actual.size.width-hwm_edge_origin.size.width,false);
    w->strip_last_frame=actual; w->strip_last_offset=v->strip_offset;
    w->strip_size_pending=false;
    hwm_layout(v,false);
    return true;
}

static bool hwm_edge_finish(struct window *w,struct view *v)
{
    if(w->id!=hwm_edge_window) return false;
    hwm_edge_update(w,v);
    hwm_edge_window=0; hwm_edge_neighbor=0;
    // Commit the accepted native size once; only constraints such as the hard
    // left wall and full-height outer edges need to settle after release.
    hwm_layout(v,true); hwm_hold_focus(); hwm_wake();
    return true;
}
