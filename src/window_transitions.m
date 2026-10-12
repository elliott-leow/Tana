/* Display-clock transitions for floating windows and safe window closure. */
static CGRect hwm_mix_frame(CGRect from,CGRect to,double p)
{
    return CGRectMake(round(from.origin.x+(to.origin.x-from.origin.x)*p),
                      round(from.origin.y+(to.origin.y-from.origin.y)*p),
                      round(from.size.width+(to.size.width-from.size.width)*p),
                      round(from.size.height+(to.size.height-from.size.height)*p));
}

static void hwm_float_to(struct window *w,CGRect target)
{
    CGRect source=w->strip_float_animating ? w->strip_float_last : CGRectNull;
    if(CGRectIsNull(source) && SLSGetWindowBounds(g_connection,w->id,&source)!=kCGErrorSuccess) source=w->frame;
    w->strip_float_from=source; w->strip_float_last=source;
    w->strip_float_target=target; w->strip_float_start=hwm_now();
    w->strip_float_animating=true; hwm_wake();
}

static bool hwm_render_floating(double now)
{
    bool active=false;
    table_for(struct window *w,g_window_manager.window, {
        if(!w->strip_float_animating) continue;
        if(window_manager_find_managed_window(&g_window_manager,w) ||
           window_check_flag(w,WINDOW_MINIMIZE) || window_check_flag(w,WINDOW_FULLSCREEN) ||
           w->application->is_hidden || g_mouse_state.window==w) {
            w->strip_float_animating=false; continue;
        }
        double t=(now-w->strip_float_start)/hwm_duration;
        CGRect f=hwm_mix_frame(w->strip_float_from,w->strip_float_target,horizontal_ease(t));
        CGRect last=w->strip_float_last;
        if(!CGSizeEqualToSize(f.size,last.size)) {
            ++hwm_resize_operations;
            window_manager_set_window_frame(w,f.origin.x,f.origin.y,f.size.width,f.size.height);
        }
        if(!CGRectEqualToRect(f,last)) {
            if(!scripting_addition_move_window(w->id,f.origin.x,f.origin.y)) {
                ++hwm_move_failures; hwm_backend_ok=false;
            } else { w->strip_float_last=f; }
        }
        w->strip_float_animating=t<1;
        active|=w->strip_float_animating;
    })
    return active;
}

static void hwm_close_animated(struct window *w)
{
    if(w->strip_close_pending) return;
    float alpha=1;
    if(SLSGetWindowAlpha(g_connection,w->id,&alpha)!=kCGErrorSuccess) alpha=1;
    w->strip_close_alpha=alpha; w->strip_close_start=hwm_now();
    w->strip_close_pending=true; hwm_wake();
}

static bool hwm_render_closing(double now)
{
    bool active=false;
    table_for(struct window *w,g_window_manager.window, {
        if(!w->strip_close_pending) continue;
        double t=(now-w->strip_close_start)/.14;
        if(t<1) {
            scripting_addition_set_opacity(w->id,w->strip_close_alpha*(1-horizontal_ease(t)),0);
            active=true;
        } else {
            w->strip_close_pending=false;
            // AXClose preserves normal save prompts. Restore opacity even if
            // the application refuses to close or presents a confirmation.
            window_manager_close_window(w);
            scripting_addition_set_opacity(w->id,w->strip_close_alpha,.14);
        }
    })
    return active;
}

static void hwm_cancel_closing(void)
{
    table_for(struct window *w,g_window_manager.window, {
        if(w->strip_close_pending) {
            w->strip_close_pending=false;
            scripting_addition_set_opacity(w->id,w->strip_close_alpha,0);
        }
    })
}
