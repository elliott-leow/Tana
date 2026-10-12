/* Display-clock transitions for floating windows, opening, and safe closure. */
static double hwm_pop_duration=.22;
static bool hwm_open_animation=true, hwm_close_shrink=true, hwm_close_fade=true;
static int hwm_open_style;  /* 0 grows in, 1 rises into place, 2 only fades */
static int hwm_close_style; /* 1 sinks as it fades */

static CGRect hwm_mix_frame(CGRect from,CGRect to,double p)
{
    return CGRectMake(round(from.origin.x+(to.origin.x-from.origin.x)*p),
                      round(from.origin.y+(to.origin.y-from.origin.y)*p),
                      round(from.size.width+(to.size.width-from.size.width)*p),
                      round(from.size.height+(to.size.height-from.size.height)*p));
}

/* Uniform WindowServer scale about the window's centre. The helper toggles: a
 * scaled window first returns to its native transform, and identity
 * parameters make that reset harmless when the window was not scaled.
 * The width changes in steps of two points so both margins stay whole numbers;
 * otherwise rounding alternates and the window visibly shivers as it scales. */
static void hwm_scale_center(uint32_t wid,bool *scaled,double scale)
{
    bool apply=scale<.999;
    if(!*scaled && !apply) return;
    CGRect b=CGRectNull;
    hwm_batch_settle();
    if(SLSGetWindowBounds(g_connection,wid,&b)!=kCGErrorSuccess || CGRectIsNull(b) || b.size.width<=0 || b.size.height<=0) { *scaled=false; return; }
    // Reset and rescale belong to one compositor update: no full-size frame between them.
    hwm_batch_begin();
    if(*scaled) {
        scripting_addition_scale_window(wid,b.origin.x-3*b.size.width,b.origin.y,4*b.size.width,b.size.height);
        *scaled=false;
    }
    if(apply) {
        double margin=round(b.size.width*(1-scale)*.5), width=fmax(2,b.size.width-2*margin);
        // The helper derives the height from the width with integer truncation.
        double height=floor(width/(b.size.width/b.size.height));
        double x=b.origin.x+margin, y=b.origin.y+floor((b.size.height-height)*.5);
        if(margin>=1) *scaled=scripting_addition_scale_window(wid,x-3*width,y,4*width,height);
    }
    hwm_batch_end();
}

/* Return every scaled window to its native transform. A frame does this before
 * it moves anything, then re-applies the scales, all inside one batch: a
 * transform carries its own translation, so moving a scaled window in place
 * would otherwise show it at a stale position for a frame. */
static void hwm_scale_reset_all(void)
{
    table_for(struct window *w,g_window_manager.window, {
        if(w->strip_pop_scaled) hwm_scale_center(w->id,&w->strip_pop_scaled,1);
        if(w->strip_close_scaled) hwm_scale_center(w->id,&w->strip_close_scaled,1);
    })
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
        double elapsed=now-w->strip_float_start;
        CGRect f=hwm_mix_frame(w->strip_float_from,w->strip_float_target,hstrip_spring_progress(elapsed,hwm_duration));
        CGRect last=w->strip_float_last;
        if(!CGSizeEqualToSize(f.size,last.size)) {
            ++hwm_resize_operations;
            hwm_resize_submit(w,f,true);
        }
        if(!CGRectEqualToRect(f,last)) {
            if(!scripting_addition_move_window(w->id,f.origin.x,f.origin.y)) {
                ++hwm_move_failures; hwm_backend_ok=false;
            } else { w->strip_float_last=f; }
        }
        w->strip_float_animating=elapsed<hwm_duration || (hwm_resize_busy(w) && elapsed<hwm_duration+1);
        active|=w->strip_float_animating;
    })
    return active;
}

/* A new window is held invisible until the application has taken the size of
 * its slot, then fades in while growing the last few percent. Showing it
 * earlier lets the user watch it snap from the size the app first chose. */
static void hwm_pop_open(struct window *w)
{
    if(!hwm_open_animation || hwm_duration<=.01 || w->strip_pop || w->strip_close_pending) return;
    w->strip_pop=1; w->strip_pop_start=hwm_now();
    scripting_addition_set_opacity(w->id,0,0);
    hwm_wake();
}

static void hwm_pop_finish(struct window *w)
{
    if(!w->strip_pop) return;
    w->strip_pop=0;
    hwm_scale_center(w->id,&w->strip_pop_scaled,1);
    scripting_addition_set_opacity(w->id,hwm_window_alpha(w),0);
}

static bool hwm_render_pops(double now)
{
    bool active=false;
    table_for(struct window *w,g_window_manager.window, {
        if(!w->strip_pop) continue;
        double elapsed=now-w->strip_pop_start;
        if(window_check_flag(w,WINDOW_MINIMIZE) || window_check_flag(w,WINDOW_FULLSCREEN) ||
           w->application->is_hidden || g_mouse_state.window==w) { hwm_pop_finish(w); continue; }
        if(w->strip_pop==1) {
            // Waiting for the size to land; never longer than a third of a second.
            if((elapsed>.03 && !hwm_resize_busy(w)) || elapsed>.33) {
                w->strip_pop=2; w->strip_pop_start=now; elapsed=0;
                scripting_addition_set_opacity(w->id,hwm_window_alpha(w),hwm_pop_duration);
                if(hwm_open_style==1 && window_manager_find_managed_window(&g_window_manager,w)) {
                    // Rises into its slot on the same spring as any other tile movement.
                    w->strip_from_x=w->strip_world_x; w->strip_from_y=w->strip_world_y+fmin(140,w->strip_height*.14);
                    w->strip_from_width=w->strip_width; w->strip_from_height=w->strip_height;
                    w->strip_vel_x=w->strip_vel_y=w->strip_vel_width=w->strip_vel_height=0; w->strip_start=now;
                }
            } else { active=true; continue; }
        }
        if(elapsed>=hwm_pop_duration) { hwm_pop_finish(w); continue; }
        if(hwm_open_style==0) hwm_scale_center(w->id,&w->strip_pop_scaled,.9+.1*hstrip_spring_progress(elapsed,hwm_pop_duration));
        active=true;
    })
    return active;
}

static void hwm_cancel_pops(void)
{
    table_for(struct window *w,g_window_manager.window, { hwm_pop_finish(w); })
}

static const double HWMCloseDuration=.15;
static void hwm_close_animated(struct window *w)
{
    if(w->strip_close_pending) return;
    hwm_pop_finish(w);
    float alpha=1;
    if(SLSGetWindowAlpha(g_connection,w->id,&alpha)!=kCGErrorSuccess) alpha=1;
    w->strip_close_alpha=alpha; w->strip_close_start=hwm_now();
    w->strip_close_pending=true;
    // One request: the helper fades on its own clock, so the fade stays even
    // whatever else this frame is doing.
    scripting_addition_set_opacity(w->id,0,hwm_duration>.01 && hwm_close_fade ? HWMCloseDuration : 0);
    if(hwm_close_style==1 && hwm_duration>.01 && w->strip_close_ghost) {
        // A ghost has left the layout, so its own spring is free to carry it down.
        double elapsed=hwm_now()-w->strip_start, unused;
        w->strip_from_x=hwm_window_sample(w->strip_from_x,w->strip_world_x,w->strip_vel_x,elapsed,hwm_window_zeta,&unused);
        w->strip_from_y=hwm_window_sample(w->strip_from_y,w->strip_world_y,w->strip_vel_y,elapsed,hwm_window_zeta,&unused);
        w->strip_from_width=w->strip_width; w->strip_from_height=w->strip_height;
        w->strip_world_x=w->strip_from_x; w->strip_world_y=w->strip_from_y+fmin(120,w->strip_height*.12);
        w->strip_vel_x=w->strip_vel_y=w->strip_vel_width=w->strip_vel_height=0; w->strip_start=hwm_now();
    }
    hwm_wake();
}

static bool hwm_render_closing(double now)
{
    bool active=false;
    table_for(struct window *w,g_window_manager.window, {
        if(!w->strip_close_pending) continue;
        double t=(now-w->strip_close_start)/HWMCloseDuration;
        if(t<1) {
            if(hwm_close_shrink && hwm_duration>.01) hwm_scale_center(w->id,&w->strip_close_scaled,1-.08*horizontal_ease(t));
            active=true;
        } else {
            w->strip_close_pending=false;
            // The window is invisible here, so returning it to full size cannot flash.
            hwm_scale_center(w->id,&w->strip_close_scaled,1);
            // AXClose preserves normal save prompts. Restore opacity even if
            // the application refuses to close or presents a confirmation.
            hwm_close_submit(w);
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
            hwm_scale_center(w->id,&w->strip_close_scaled,1);
            scripting_addition_set_opacity(w->id,w->strip_close_alpha,0);
        }
    })
}
