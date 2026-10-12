/* Serialized rendering and delayed-notification handling. */
static bool hwm_view_in_motion(struct view *view,double now);
static double hwm_rendered_offset; // Camera position of the frame last drawn.
static bool hwm_render(struct view *view, double now)
{
    CGRect bounds = hwm_bounds(view);
    double offset = hwm_offset(view, now);
    hwm_rendered_offset = offset;
    bool active = view->strip_scrolling;
    bool batched=false;
    // While the strip is travelling, a window that is off screen before and
    // after a frame does not need that frame: only what can be seen is moved.
    // Everything is brought up to date once the strip rests.
    bool travelling=hwm_view_in_motion(view,now);
    if(hwm_shelf_moving(now)) active=true;
    CGRect visible=CGRectInset(bounds,-120,-120);
    for (struct window_node *node = window_node_find_first_leaf(view->root); node; node = window_node_find_next_leaf(node)) {
        for (int i = 0; i < node->window_count; ++i) {
            struct window *window = window_manager_find_window(&g_window_manager, node->window_list[i]);
            if (!window || !window->strip_initialized || window->id==hwm_drag_window || window->id==hwm_edge_window) continue;
            if(hwm_workflow_tab_hidden(window)) {
                // Parking is movement only. AX resizing at an extreme negative
                // y can make AppKit report CGRectNull and lose the window frame.
                CGRect parked=window->strip_last_frame;
                if(CGRectIsNull(parked) || parked.size.width<=0) parked=window->frame;
                parked.origin=CGPointMake(bounds.origin.x-2*bounds.size.width-fmax(160,parked.size.width),bounds.origin.y);
                CGRect observed=CGRectNull;
                bool measured=window->strip_tab_parked || SLSGetWindowBounds(g_connection,window->id,&observed)==kCGErrorSuccess;
                if(!window->strip_tab_parked || !measured || (!CGRectIsNull(observed) && !CGPointEqualToPoint(parked.origin,observed.origin))) {
                    if(!scripting_addition_move_window(window->id,parked.origin.x,parked.origin.y)) { hwm_backend_ok=false; ++hwm_move_failures; }
                    window->strip_last_frame=parked; window->strip_last_offset=offset; window->strip_last_shift=0;
                }
                window->strip_tab_parked=true; window->strip_size_pending=false;
                if(now-window->strip_start<hwm_duration+.5) active=true;
                continue;
            }
            if(window->strip_tab_parked && hwm_duration>.01) {
                // A tab arrives in place, so it is revealed with a fade rather than a flight.
                scripting_addition_set_opacity(window->id,0,0);
                scripting_addition_set_opacity(window->id,hwm_window_alpha(window),.16);
            }
            window->strip_tab_parked=false;
            double elapsed = now-window->strip_start, t = elapsed/hwm_duration, unused;
            double x = hwm_window_sample(window->strip_from_x,window->strip_world_x,window->strip_vel_x,elapsed,hwm_window_zeta,&unused);
            double y = hwm_window_sample(window->strip_from_y,window->strip_world_y,window->strip_vel_y,elapsed,hwm_window_zeta,&unused);
            double height = hwm_window_sample(window->strip_from_height,window->strip_height,window->strip_vel_height,elapsed,1,&unused);
            double width = hwm_window_sample(window->strip_from_width,window->strip_width,window->strip_vel_width,elapsed,1,&unused);
            if (t < 1) active = true;
            // Each strip is drawn at its own camera position, the strips out of view further down.
            int shelf = hwm_shelf_of(window);
            double own_offset = shelf==hwm_shelf ? offset : hwm_shelf_offsets[shelf], shift = hwm_shelf_shift(view,shelf,now);
            CGRect frame = CGRectMake(round(hstrip_project_x(x,own_offset,bounds.origin.x,1000000)), round(bounds.origin.y+y+shift), round(width), round(height));
            CGRect last = window->strip_last_frame;
            bool resize = CGRectIsNull(last) || fabs(last.size.width-frame.size.width) >= 1 || fabs(last.size.height-frame.size.height) >= 1;
            bool move = resize || CGRectIsNull(last) || !CGPointEqualToPoint(last.origin, frame.origin);
            if (move && travelling && !resize && !window->strip_size_pending && !CGRectIsNull(last) &&
                !CGRectIntersectsRect(last,visible) && !CGRectIntersectsRect(frame,visible)) {
                node->area = (struct area) { frame.origin.x, frame.origin.y, frame.size.width, frame.size.height };
                continue;
            }
            if (move) {
                if(!batched) { hwm_batch_begin(); batched=true; }
                // Position first, through WindowServer: it bypasses the on-screen
                // constraints that would otherwise destroy an infinite strip, and
                // puts the top edge where the new size will be measured from.
                if (!scripting_addition_move_window(window->id, frame.origin.x, frame.origin.y)) {
                    ++hwm_move_failures;
                    hwm_backend_ok = false;
                    // Do not replace this with AX movement: that clamps off-screen
                    // windows and silently turns the strip into an overlapping pile.
                    hwm_batch_end();
                    return false;
                }
                window->strip_last_frame = frame;
                window->strip_last_offset = own_offset;
                window->strip_last_shift = shift;
            }
            if (resize) {
                ++hwm_resize_operations;
                // Size goes through Accessibility, handed off so that this frame
                // never waits for the application to answer.
                hwm_resize_submit(window,frame,CGRectIsNull(last) || fabs(last.size.height-frame.size.height)>=1);
                window->strip_size_pending = true;
                window->strip_size_sent_at = now;
            }
            node->area = (struct area) { frame.origin.x, frame.origin.y, frame.size.width, frame.size.height };
            if (window->strip_size_pending) {
                if (now-window->strip_size_sent_at < .25 || t < 1 || hwm_resize_busy(window)) {
                    active = true;
                } else {
                    window->strip_size_pending = false;
                    CGRect actual = CGRectNull;
                    hwm_batch_settle();
                    bool measured=SLSGetWindowBounds(g_connection,window->id,&actual)==kCGErrorSuccess;
                    if(measured && !CGPointEqualToPoint(actual.origin,frame.origin))
                        scripting_addition_move_window(window->id,frame.origin.x,frame.origin.y);
                    scripting_addition_set_layer(window->id,LAYER_BELOW);
                    if (measured &&
                        isfinite(actual.size.width) && actual.size.width >= 160 &&
                        actual.size.width-window->strip_width > 1) {
                        window->strip_min_width=fmax(window->strip_min_width,actual.size.width);
                        hwm_column_width(view,window,actual.size.width);
                        window->strip_full_width = false;
                        window->strip_last_frame = actual;
                        if(batched) hwm_batch_end();
                        hwm_layout(view,true);
                        return true;
                    }
                }
            }
        }
    }
    if(batched) hwm_batch_end();
    return active;
}

static bool hwm_view_in_motion(struct view *view,double now)
{
    return view->strip_scrolling || __atomic_load_n(&__pending_gesture,__ATOMIC_ACQUIRE) ||
           now-hwm_last_input<.15 || hwm_shelf_moving(now);
}

static bool horizontal_window_changed(struct window *window, struct view *view, bool resized)
{
    if (!hwm_ready || !view || view->layout != VIEW_STRIP) return false;
    if (hwm_paused || hwm_overview_active) return true;
    if(hwm_workflow_tab_hidden(window)) { hwm_wake(); return true; }
    if (hwm_edge_update(window,view)) return true;
    if (hwm_drag_window==window->id) return true;
    if (!resized && g_mouse_state.window==window && !CGRectIsNull(window->strip_last_frame)) {
        CGRect actual=CGRectNull;
        SLSGetWindowBounds(g_connection,window->id,&actual);
        CGPoint point; SLSGetCurrentCursorLocation(g_connection,&point);
        if (hypot(point.x-g_mouse_state.down_location.x,point.y-g_mouse_state.down_location.y)>3 &&
            !CGRectIsNull(actual) && (fabs(actual.origin.x-window->strip_last_frame.origin.x)>2 || fabs(actual.origin.y-window->strip_last_frame.origin.y)>2)) {
            hwm_drag_started(window);
            return true;
        }
    }
    // Accessibility notifications can arrive behind the display-link renderer.
    // They must not restart an in-progress transition with an obsolete frame.
    double now = hwm_now();
    if (hwm_view_in_motion(view,now) || window->strip_size_pending || now-window->strip_start < hwm_duration+.1 || hwm_resize_busy(window)) {
        hwm_wake();
        return true;
    }
    CGRect actual = CGRectNull;
    if (SLSGetWindowBounds(g_connection,window->id,&actual) != kCGErrorSuccess) return true;
    if (resized && isfinite(actual.size.width) && actual.size.width >= 160 && fabs(actual.size.width-window->strip_width) > 1) {
        hwm_column_width(view,window,actual.size.width);
        window->strip_full_width = false;
        window->strip_last_frame = actual;
        window->strip_last_offset=hwm_shelf_offset(view,hwm_shelf_of(window),now);
        hwm_layout(view,true);
    } else if (!CGRectIsNull(window->strip_last_frame) && !CGPointEqualToPoint(actual.origin,window->strip_last_frame.origin)) {
        // A delayed move notification must never invalidate the size cache.
        // Doing so turns a pan into AX resize calls, which can clamp offscreen
        // windows back onto the display and fight the next gesture frame.
        window->strip_last_frame.origin = actual.origin;
        hwm_wake();
    }
    return true;
}

static bool horizontal_window_moved(struct window *window)
{
    struct view *view = window_manager_find_managed_window(&g_window_manager,window);
    // A floating window is moved by its application; one tick re-seats its border.
    if (hwm_ready && !view && window->id==hwm_feedback_focus_id) hwm_wake();
    if (!hwm_ready || !view || view->layout != VIEW_STRIP) return false;
    if(hwm_view_in_motion(view,hwm_now())) return true;
    CGRect actual = CGRectNull;
    if (SLSGetWindowBounds(g_connection,window->id,&actual) == kCGErrorSuccess)
        window->frame.origin = actual.origin;
    return horizontal_window_changed(window,view,false);
}

/* Called for every Accessibility resize notification, before the engine asks
 * the application anything. While the strip owns a window's geometry those
 * notifications are echoes of its own requests; answering each with further
 * blocking Accessibility queries is what made resizing stutter. Returns true
 * when the notification needs no further handling. */
static bool horizontal_resize_event(struct window *window)
{
    struct view *view = window_manager_find_managed_window(&g_window_manager,window);
    if (!hwm_ready || hwm_paused || !view || view->layout != VIEW_STRIP) return false;
    if (hwm_overview_active) return true;
    if (window->id==hwm_edge_window) { hwm_edge_update(window,view); hwm_wake(); return true; }
    // Entering native fullscreen is a resize too, and the engine must see it:
    // such a window has already left the strip's Space.
    if (hwm_window_left_strip(window)) return false;
    double now = hwm_now();
    if (hwm_drag_window==window->id || hwm_workflow_tab_hidden(window) || hwm_view_in_motion(view,now) ||
        window->strip_size_pending || now-window->strip_start < hwm_duration+.1 || hwm_resize_busy(window)) {
        hwm_wake();
        return true;
    }
    return false;
}
