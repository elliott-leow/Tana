/* Serialized rendering and delayed-notification handling. */
static bool hwm_render(struct view *view, double now)
{
    CGRect bounds = hwm_bounds(view);
    double offset = hwm_offset(view, now);
    bool active = view->strip_scrolling;
    bool updates_disabled=false;
    for (struct window_node *node = window_node_find_first_leaf(view->root); node; node = window_node_find_next_leaf(node)) {
        for (int i = 0; i < node->window_count; ++i) {
            struct window *window = window_manager_find_window(&g_window_manager, node->window_list[i]);
            if (!window || !window->strip_initialized || window->id==hwm_drag_window) continue;
            double t = (now-window->strip_start)/hwm_duration;
            double p = horizontal_ease(t);
            double x = window->strip_from_x + (window->strip_world_x-window->strip_from_x)*p;
            double y = window->strip_from_y+(window->strip_world_y-window->strip_from_y)*p;
            double height = window->strip_from_height+(window->strip_height-window->strip_from_height)*p;
            double width = window->strip_from_width + (window->strip_width-window->strip_from_width)*p;
            if (t < 1) active = true;
            CGRect frame = CGRectMake(round(hstrip_project_x(x,offset,bounds.origin.x,1000000)), round(bounds.origin.y+y), round(width), round(height));
            CGRect last = window->strip_last_frame;
            bool resize = CGRectIsNull(last) || fabs(last.size.width-frame.size.width) >= 1 || fabs(last.size.height-frame.size.height) >= 1;
            bool move = resize || CGRectIsNull(last) || !CGPointEqualToPoint(last.origin, frame.origin);
            if (resize) {
                ++hwm_resize_operations;
                // Never hold the compositor while waiting for application AX.
                if(updates_disabled) { SLSReenableUpdate(g_connection); updates_disabled=false; }
                // Put the top edge in its final position before asking AX for
                // height; apps can otherwise constrain size at the old origin.
                scripting_addition_move_window(window->id,frame.origin.x,frame.origin.y);
                // AX changes size; privileged WindowServer movement bypasses the
                // on-screen constraints that otherwise destroy an infinite strip.
                if (CGRectIsNull(last) || fabs(last.size.height-frame.size.height)>=1) {
                    // set_window_frame already performs the enhanced-UI guard.
                    window_manager_set_window_frame(window,frame.origin.x,frame.origin.y,frame.size.width,frame.size.height);
                } else {
                    AX_ENHANCED_UI_WORKAROUND(window->application->ref, {
                        window_manager_resize_window(window, frame.size.width, frame.size.height);
                    });
                }
                window->strip_size_pending = true;
                window->strip_size_sent_at = now;
            }
            if (move) {
                if(!updates_disabled) { SLSDisableUpdate(g_connection); updates_disabled=true; }
                if (!scripting_addition_move_window(window->id, frame.origin.x, frame.origin.y)) {
                    ++hwm_move_failures;
                    hwm_backend_ok = false;
                    // Do not replace this with AX movement: that clamps off-screen
                    // windows and silently turns the strip into an overlapping pile.
                    SLSReenableUpdate(g_connection);
                    return false;
                }
                window->strip_last_frame = frame;
                window->strip_last_offset = offset;
            }
            node->area = (struct area) { frame.origin.x, frame.origin.y, frame.size.width, frame.size.height };
            if (window->strip_size_pending) {
                if (now-window->strip_size_sent_at < .25 || t < 1) {
                    active = true;
                } else {
                    window->strip_size_pending = false;
                    CGRect actual = CGRectNull;
                    bool measured=SLSGetWindowBounds(g_connection,window->id,&actual)==kCGErrorSuccess;
                    if(measured && !CGPointEqualToPoint(actual.origin,frame.origin))
                        scripting_addition_move_window(window->id,frame.origin.x,frame.origin.y);
                    scripting_addition_set_layer(window->id,LAYER_BELOW);
                    if (measured &&
                        isfinite(actual.size.width) && actual.size.width >= 160 &&
                        actual.size.width-window->strip_width > 1) {
                        hwm_column_width(view,window,actual.size.width);
                        window->strip_full_width = false;
                        window->strip_last_frame = actual;
                        if(updates_disabled) { SLSReenableUpdate(g_connection); updates_disabled=false; }
                        hwm_layout(view,true);
                        return true;
                    }
                }
            }
        }
    }
    if(updates_disabled) SLSReenableUpdate(g_connection);
    return active;
}

static bool hwm_view_in_motion(struct view *view,double now)
{
    return view->strip_scrolling || __atomic_load_n(&__pending_gesture,__ATOMIC_ACQUIRE) ||
           now-hwm_last_input<.15;
}

static bool horizontal_window_changed(struct window *window, struct view *view, bool resized)
{
    if (!hwm_ready || !view || view->layout != VIEW_STRIP) return false;
    if (hwm_paused || hwm_overview_active) return true;
    if (hwm_drag_window==window->id) return true;
    if (!resized && g_mouse_state.window==window && !CGRectIsNull(window->strip_last_frame)) {
        CGRect actual=CGRectNull;
        SLSGetWindowBounds(g_connection,window->id,&actual);
        CGPoint point; SLSGetCurrentCursorLocation(g_connection,&point);
        if (hypot(point.x-g_mouse_state.down_location.x,point.y-g_mouse_state.down_location.y)>3 &&
            !CGRectIsNull(actual) && (fabs(actual.origin.x-window->strip_last_frame.origin.x)>2 || fabs(actual.origin.y-window->strip_last_frame.origin.y)>2)) {
            hwm_drag_window=window->id;
            scripting_addition_set_layer(window->id,LAYER_NORMAL);
            return true;
        }
    }
    // Accessibility notifications can arrive behind the display-link renderer.
    // They must not restart an in-progress transition with an obsolete frame.
    double now = hwm_now();
    if (hwm_view_in_motion(view,now) || window->strip_size_pending || now-window->strip_start < hwm_duration+.1) {
        hwm_wake();
        return true;
    }
    CGRect actual = CGRectNull;
    if (SLSGetWindowBounds(g_connection,window->id,&actual) != kCGErrorSuccess) return true;
    if (resized && isfinite(actual.size.width) && actual.size.width >= 160 && fabs(actual.size.width-window->strip_width) > 1) {
        window->strip_width = actual.size.width;
        window->strip_full_width = false;
        window->strip_last_frame = actual;
        window->strip_last_offset=view->strip_offset;
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
    if (!hwm_ready || !view || view->layout != VIEW_STRIP) return false;
    if(hwm_view_in_motion(view,hwm_now())) return true;
    CGRect actual = CGRectNull;
    if (SLSGetWindowBounds(g_connection,window->id,&actual) == kCGErrorSuccess)
        window->frame.origin = actual.origin;
    return horizontal_window_changed(window,view,false);
}
