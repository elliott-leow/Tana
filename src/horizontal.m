/* Tana. MIT license; see LICENSE. */
#include <math.h>
#include <stdatomic.h>
#include "strip_geometry.h"
#include "strip_columns.h"
#include "window_overview.m"
#include "tana_config.m"
#include "strip_workflow.h"

extern struct window_manager g_window_manager;
extern struct space_manager g_space_manager;
extern struct mouse_state g_mouse_state;
extern struct event_loop g_event_loop;
extern volatile bool __pending_gesture;
extern volatile uint64_t __last_gesture_time;

static _Atomic bool hwm_ready, hwm_paused;
static double hwm_screen_stamp=-10; // Usable-screen cache; reset whenever the display, Dock or menu bar reports a change.
static bool hwm_backend_ok = true;
static uint64_t hwm_space;
static CVDisplayLinkRef hwm_display_link;
static dispatch_source_t hwm_fallback_timer;
static _Atomic bool hwm_suspended;
static _Atomic bool hwm_overview_active;
static _Atomic double hwm_overview_progress;
static _Atomic uint64_t hwm_overview_generation;
static _Atomic unsigned hwm_overview_window_count;
static void hwm_overview_tick(void);
static bool hwm_vertical_swiping;
static uint64_t hwm_vertical_swipe_time;
static double hwm_vertical_last_progress;
static void hwm_start_clock(void);
static bool hwm_tick_pending, hwm_active;
static bool hwm_reconcile_pending;
static bool hwm_swiping; // Only accessed by the main-thread event tap.
static uint64_t hwm_swipe_time;
static bool hwm_keys[128];
static bool hwm_tab_click;
static double hwm_duration = 0.36; // Settle horizon of the tile springs.
static double hwm_scroll_omega = 22;
static double hwm_rubber; // Signed overscroll shown while a finger holds the strip past an end.
/* Finger reports and display refreshes are not in step: a frame can follow one
 * report, two, or none, so a steady swipe drawn straight from the latest
 * report advances in uneven steps. Each frame of a held swipe is instead drawn
 * where the fingers are at that frame, carried on from the latest report at
 * the speed they were moving, for no longer than about one report interval. */
static double hwm_held_velocity, hwm_held_time, hwm_held_lead;
static const double HWMHeldLeadMax=.012;
/* The last few reports of the swipe in hand. Reports reach this process
 * bunched and late by varying amounts, so one report and its neighbour are a
 * poor measure of speed; a line through the last twentieth of a second is not. */
enum { HWM_HELD_SAMPLES=6 };
static struct { double time, offset; } hwm_held_samples[HWM_HELD_SAMPLES];
static int hwm_held_count;
static void hwm_held_note(double time,double offset)
{
    if(hwm_held_count==HWM_HELD_SAMPLES) memmove(hwm_held_samples,hwm_held_samples+1,(HWM_HELD_SAMPLES-1)*sizeof(*hwm_held_samples));
    else ++hwm_held_count;
    hwm_held_samples[hwm_held_count-1].time=time; hwm_held_samples[hwm_held_count-1].offset=offset;
}
/* Where the fingers have brought the strip by `time`, less the latest report. */
static double hwm_held_lead_at(double time,double latest)
{
    if(hwm_held_count<2) return 0;
    double newest=hwm_held_samples[hwm_held_count-1].time, st=0, sx=0, stt=0, stx=0; int n=0;
    for(int i=hwm_held_count-1;i>=0 && newest-hwm_held_samples[i].time<=.05;i--) {
        double t=hwm_held_samples[i].time-newest, x=hwm_held_samples[i].offset;
        st+=t; sx+=x; stt+=t*t; stx+=t*x; ++n;
    }
    double spread=n*stt-st*st;
    if(n<2 || !(spread>1e-9)) return 0;
    double speed=(n*stx-st*sx)/spread, at_newest=(sx-speed*st)/n;
    hwm_held_velocity=speed;
    double ahead=fmax(0,fmin(HWMHeldLeadMax,time-newest));
    // Never further from the latest report than the fingers could have travelled since.
    double lead=at_newest+speed*ahead-latest, limit=fabs(speed)*(HWMHeldLeadMax+.004);
    return fmax(-limit,fmin(limit,lead));
}
/* When a trackpad report was made, rather than when this thread got to it. */
static double hwm_event_time(CGEventRef event,double now)
{
    double stamp=(double)CGEventGetTimestamp(event)/1e9;
    return stamp<=now && now-stamp<.05 ? stamp : now;
}
static int hwm_snap = 2; // 0 free, 1 column edges, 2 centre the nearest column
static double hwm_magnet = .1; // Pull toward a centred column while the strip is held.
static double hwm_snap_threshold = .15; // Share of the way to the next column that commits a swipe to it.
static double hwm_swipe_gain = 1; // Strip travel per unit of finger travel.
static double hwm_snap_origin; // Where the strip rested when the current swipe began.
static int hwm_focus_follow = 2; // After the strip is moved: 0 leave focus, 1 focus the window brought to the centre, 2 the one under the pointer.
static void hwm_focus_follow_to(struct view *view,double offset);
static bool hwm_settle_pending; // A wheel pan has no release event; settle when it goes quiet.
static int hwm_new_placement; // 0 centre gap, 1 beside focused, 2 strip end
static uint32_t hwm_nav_window; // Keyboard navigation cursor; leads the reported focus.
static double hwm_nav_time;
static bool hwm_nav_pending;
static void hwm_nav_flush(void);
static void hwm_preview_show(CGRect target,CGRect start,bool animate);
static bool hwm_move_column(struct view *view,struct window *window,int mode);
static bool hwm_place(struct view *view,uint32_t source,uint32_t target,HStripPlacement placement,bool commit,CGRect *preview);
static double hwm_snap_target(struct view *view,double desired,double viewport,bool swipe);
static NSString *hwm_terminal_command, *hwm_browser_command;
static double hwm_config_mtime;
static void hwm_config_poll(void);
static void hwm_alpha_sync(bool restore);
static _Atomic double hwm_motion_scale=1;
static double hwm_scroll_initial_velocity,hwm_scroll_current_velocity;
static bool hwm_release_velocity;
static void hwm_feedback_navigation(bool wall);
static void hwm_feedback_focus(struct window *previous,struct window *next);
static void hwm_feedback_tick(struct view *view,double now);
static void hwm_feedback_hide(void);
static _Atomic bool hwm_pointer_focus=true;
static uint64_t hwm_frames, hwm_slow_frames, hwm_move_failures, hwm_resize_operations;
static _Atomic uint64_t hwm_key_actions;
static double hwm_max_frame_ms;
static double hwm_last_input;
static uint32_t hwm_resize_window;
static uint32_t hwm_drag_window, hwm_drop_target;
static HStripPlacement hwm_drop_placement;
static CGPoint hwm_drag_point;
static double hwm_drag_tick_time;
static bool hwm_drag_cancelled,hwm_drag_shadow;
/* Worst time per tick section since the last `profile-reset`, in ms. */
enum { HWM_PROF_DRAG, HWM_PROF_RENDER, HWM_PROF_EXTRAS, HWM_PROF_PREVIEW, HWM_PROF_FEEDBACK, HWM_PROF_TICK_DRAGGING, HWM_PROF_COUNT };
static double hwm_prof[HWM_PROF_COUNT];
static uint64_t hwm_prof_drag_ticks, hwm_prof_drag_events;
static double hwm_now(void);
static double hwm_prof_mark(int slot,double since) { double t=hwm_now(), ms=(t-since)*1000; if(ms>hwm_prof[slot]) hwm_prof[slot]=ms; return t; }
/* Frame pacing, as opposed to frame cost: how long a tick waited to run after
 * the display asked for it, how often an animating strip missed a refresh, and
 * which other event-loop work held the frame thread up meanwhile. */
static uint64_t hwm_tick_posted;
static uint64_t hwm_tick_late, hwm_frames_dropped, hwm_stalls;
static double hwm_tick_latency_max_ms, hwm_tick_latency_total_ms, hwm_frame_gap_max_ms, hwm_stall_max_ms;
static double hwm_tick_previous; static bool hwm_tick_previous_active;
static double hwm_drawn_time; // When a frame was last actually drawn.
static int hwm_stall_type=-1;
static struct { uint64_t count; double total_ms, max_ms; } hwm_event_prof[64];
static const char *hwm_event_names[] = {
#define EVENT_TYPE_ENTRY(value) #value,
    EVENT_TYPE_LIST
#undef EVENT_TYPE_ENTRY
};
enum { HWM_FRAME_LOG=1024 };
static struct { double time, offset, tick_ms, latency_ms; } hwm_frame_log[HWM_FRAME_LOG];
static struct { double time, offset; } hwm_input_log[HWM_FRAME_LOG];
static uint64_t hwm_frame_log_count, hwm_input_log_count;
static void horizontal_event_timed(int type,double ms)
{
    if(type<0 || type>=64) return;
    if((type>=DISPLAY_ADDED && type<=DISPLAY_CHANGED) || type==SPACE_CHANGED || type==DOCK_DID_RESTART || type==MENU_BAR_HIDDEN_CHANGED ||
       type==DOCK_DID_CHANGE_PREF || type==SYSTEM_WOKE) hwm_screen_stamp=-10;
    ++hwm_event_prof[type].count; hwm_event_prof[type].total_ms+=ms;
    if(ms>hwm_event_prof[type].max_ms) hwm_event_prof[type].max_ms=ms;
    // Anything but a frame that takes this long while the strip is animating delays the next frame.
    if(type!=HORIZONTAL_TICK && ms>2 && hwm_tick_previous_active) {
        ++hwm_stalls;
        if(ms>hwm_stall_max_ms) { hwm_stall_max_ms=ms; hwm_stall_type=type; }
    }
}
static double hwm_tick_note(double now)
{
    uint64_t posted=__atomic_load_n(&hwm_tick_posted,__ATOMIC_RELAXED);
    double latency=posted ? (now-(double)posted/(double)read_os_freq())*1000 : 0;
    if(latency<0 || latency>1000) latency=0;
    hwm_tick_latency_total_ms+=latency;
    if(latency>4) ++hwm_tick_late;
    if(latency>hwm_tick_latency_max_ms) hwm_tick_latency_max_ms=latency;
    if(hwm_tick_previous_active) {
        double gap=(now-hwm_tick_previous)*1000;
        if(gap>25 && gap<1000) ++hwm_frames_dropped;
        if(gap<1000 && gap>hwm_frame_gap_max_ms) hwm_frame_gap_max_ms=gap;
    }
    hwm_tick_previous=now;
    return latency;
}
static CGPoint hwm_drag_move;
static bool hwm_drag_move_pending;
static void hwm_drag_autoscroll(struct view *view,double now);
static void hwm_cancel_drag(void);
static double hwm_focus_guard_time;
static CGPoint hwm_focus_guard_point;
static bool hwm_focus_guard;
static pid_t hwm_hover_pid;
static double hwm_hover_time;
static uint32_t hwm_close_source, hwm_close_target;
static double hwm_close_screen_x, hwm_close_time;
static uint32_t hwm_preserve_focus_window;
static double hwm_preserve_focus_until;
static uint32_t hwm_previous_focus;
static double hwm_previous_focus_time,hwm_previous_focus_offset;
static uint32_t hwm_preview_id;
static CGContextRef hwm_preview_context;
static CGRect hwm_preview_from, hwm_preview_target, hwm_preview_current;
static double hwm_preview_start;
static bool hwm_preview_visible;
static bool hwm_preview_hiding;
static double hwm_preview_alpha, hwm_preview_alpha_from, hwm_preview_alpha_start;
static bool hwm_preview_render(double now);
static void hwm_preview_hide(void);
static void hwm_preview_hide_immediately(void);
static double hwm_last_backend_retry;
static bool hwm_focus_after_scroll;
static volatile sig_atomic_t hwm_stop_requested;
static void hwm_shutdown(void);
static void hwm_save_state(void);
static void hwm_save_state_now(bool wait);
static void hwm_load_state(void);
static bool hwm_state_pending;
static bool hwm_resume_load_state;
static void hwm_hold_focus(void);
static void hwm_undo_capture(void);
static bool hwm_undo_restore(void);
static bool hwm_named_action(const char *name);
static TanaConfig *hwm_config;
static NSArray *hwm_width_presets(void);
static bool hwm_config_reload(bool announce);
static bool hwm_hot_reload=true;
static NSArray *hwm_config_problems;
static double hwm_overview_duration=.34, hwm_overview_dim=.38;
static void hwm_spawn(NSString *command);
static void hwm_apply_app_rule(struct window *window);
static void hwm_apply_app_rule_now(struct window *window);
static void hwm_config_begin(void);
static void hwm_menu_refresh_bindings(void);

enum hwm_action { HWM_EVENT, HWM_LEFT, HWM_RIGHT, HWM_MOVE_LEFT, HWM_MOVE_RIGHT,
                  HWM_FLOAT, HWM_FULL, HWM_CENTER, HWM_HOME, HWM_PAUSE, HWM_REFLOW, HWM_QUIT, HWM_CLOSE, HWM_TERMINAL, HWM_BROWSER,
                  HWM_MOVE_FIRST, HWM_MOVE_LAST, HWM_OVERVIEW_FILTER, HWM_OVERVIEW_DRAG, HWM_OVERVIEW_HIGHLIGHT, HWM_OVERVIEW, HWM_OVERVIEW_GESTURE, HWM_OVERVIEW_CANCEL, HWM_OVERVIEW_POINTER, HWM_OVERVIEW_KEY, HWM_CANCEL_DRAG, HWM_NAMED_ACTION, HWM_APPLY_RULE, HWM_TAB_SELECT };

static double hwm_now(void) { return (double) read_os_timer() / (double) read_os_freq(); }
/* Animations are sampled for the moment the frame will be on screen, not for
 * whenever this thread happened to wake. The display link supplies that
 * moment; sampling at it gives evenly spaced motion however late a tick runs. */
static uint64_t hwm_vsync_host;
static double hwm_presented; // The time the last frame was sampled for.
static double hwm_frame_time(double now)
{
    static mach_timebase_info_data_t base;
    if(!base.denom) mach_timebase_info(&base);
    double target=(double)__atomic_load_n(&hwm_vsync_host,__ATOMIC_RELAXED)*base.numer/base.denom/1e9;
    return target>now && target-now<.05 ? target : now;
}
/* "Now" for anything that restarts an animation: never earlier than the frame
 * already shown, or the restart would step backwards in time. */
static double hwm_clock(void) { double now=hwm_now(); return now>hwm_presented ? now : hwm_presented; }
static double horizontal_ease(double t)
{
    return hstrip_ease(t);
}

static void hwm_wake(void) { __atomic_store_n(&hwm_active, true, __ATOMIC_RELEASE); }
static struct view *hwm_view(void)
{
    if (!hwm_space) return NULL;
    return space_manager_find_view(&g_space_manager, hwm_space);
}
/* The usable screen rectangle takes half a dozen WindowServer and Dock round
 * trips to work out, and it is wanted many times in every frame. It changes
 * only when the Dock, menu bar or display does, so it is remembered briefly. */
static CGRect hwm_screen(struct view *view)
{
    static uint64_t sid; static CGRect frame;
    double now=hwm_now();
    // Never in the middle of a swipe or a glide: the answer cannot change
    // there, and asking costs a frame's worth of round trips.
    bool moving=view->strip_scrolling || __atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED);
    if(view->sid!=sid || (now-hwm_screen_stamp>2 && !(moving && hwm_screen_stamp>0))) {
        sid=view->sid; hwm_screen_stamp=now; frame=display_bounds_constrained(space_display_id(view->sid), false);
    }
    return frame;
}
static CGRect hwm_bounds(struct view *view)
{
    CGRect frame = hwm_screen(view);
    frame.origin.x += view->left_padding;
    frame.origin.y += view->top_padding;
    frame.size.width = fmax(100, frame.size.width-view->left_padding-view->right_padding);
    frame.size.height = fmax(100, frame.size.height-view->top_padding-view->bottom_padding);
    return frame;
}
static double hwm_content_width;
static double hwm_max_offset(void) { return hwm_content_width>0 ? hwm_content_width : INFINITY; }
static double hwm_clamp_offset(double offset)
{
    return fmin(hwm_max_offset(),hstrip_viewport_offset(offset));
}
/* The displayed camera position. It may lie slightly past either end: a finger
 * holding the strip there is resisted, and a fling into an end bounces off it.
 * view->strip_offset is always the clamped, in-bounds value. */
static double hwm_offset(struct view *view, double now)
{
    if (!view->strip_scrolling) {
        if(hwm_held_lead==0 || hwm_rubber || !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) return view->strip_offset+hwm_rubber;
        return fmax(0,fmin(hwm_max_offset(),view->strip_offset+hwm_held_lead));
    }
    double elapsed=now-view->strip_scroll_start;
    double value=hstrip_spring(view->strip_from_offset,view->strip_target_offset,hwm_scroll_initial_velocity,
                              elapsed,hwm_scroll_omega/fmax(.15,hwm_motion_scale),&hwm_scroll_current_velocity);
    view->strip_offset=hwm_clamp_offset(value);
    if(hwm_motion_scale==0 || (fabs(value-view->strip_target_offset)<.25 && fabs(hwm_scroll_current_velocity)<3) || elapsed>1.2) {
        view->strip_offset=view->strip_target_offset; view->strip_scrolling=false; hwm_scroll_current_velocity=0;
        return view->strip_offset;
    }
    return value;
}
static void hwm_scroll(struct view *view, double target, bool animate)
{
    if (!view || !isfinite(target)) return;
    hwm_state_pending = true;
    double now = hwm_clock();
    double release=hwm_scroll_current_velocity;
    view->strip_from_offset = hwm_offset(view, now);
    hwm_rubber=0;
    hwm_scroll_initial_velocity=hwm_release_velocity?release:hwm_scroll_current_velocity;
    hwm_release_velocity=false;
    hwm_feedback_navigation(target<0 || target>hwm_max_offset());
    view->strip_target_offset = hwm_clamp_offset(target);
    view->strip_scroll_start = now;
    view->strip_scrolling = animate && fabs(view->strip_target_offset-view->strip_from_offset) > .25;
    if (!view->strip_scrolling) { view->strip_offset = view->strip_target_offset; hwm_scroll_current_velocity=0; }
    hwm_wake();
}

#include "strip_ax_async.m"
#include "strip_hud.m"
static void hwm_resize_submit(struct window *w,CGRect frame,bool full) { (void)full; hwm_ax_resize(w->id,w->ref,w->application->ref,frame.size); }
static bool hwm_resize_busy(struct window *w) { return hwm_ax_resize_busy(w->id); }
static void hwm_close_submit(struct window *w) { horizontal_removing(w,false); hwm_ax_close(w->ref); }
static bool hwm_window_left_strip(struct window *w) { return hwm_space && window_space(w->id)!=hwm_space; }
#include "strip_layout.m"
static void hwm_column_width(struct view *view,struct window *window,double width)
{
    uint64_t column=window->strip_column;
    table_for(struct window *w,g_window_manager.window, {
        if (w==window || (column && w->strip_column==column && window_manager_find_managed_window(&g_window_manager,w)==view)) {
            w->strip_width=width; w->strip_full_width=false;
        }
    })
}

static bool horizontal_flush_node(struct window_node *node)
{
    struct window_node *root = node;
    while (root && root->parent) root = root->parent;
    table_for (struct view *view, g_space_manager.view, {
        if (view->layout == VIEW_STRIP && view->root == root) {
            hwm_layout(view, true);
            return true;
        }
    })
    return false;
}

static void hwm_drag_started(struct window *window)
{
    if(hwm_drag_window) return;
    hwm_undo_capture(); hwm_drag_shadow=window_check_flag(window,WINDOW_SHADOW);
    scripting_addition_set_shadow(window->id,true);
    hwm_drag_window=window->id;
    SLSGetCurrentCursorLocation(g_connection,&hwm_drag_point);
    hwm_drag_tick_time=hwm_now();
    scripting_addition_set_layer(window->id,LAYER_NORMAL);
}

static uint32_t hwm_edge_window;
#include "strip_feedback.m"
#include "strip_interaction.m"
#include "strip_renderer.m"
#include "window_transitions.m"
static void horizontal_tick(void)
{
    __atomic_store_n(&hwm_tick_pending, false, __ATOMIC_RELEASE);
    if (hwm_stop_requested) { hwm_shutdown(); return; }
    if (!hwm_ready || hwm_paused || hwm_suspended || mission_control_is_active()) return;
    double start = hwm_now(), latency = hwm_tick_note(start);
    if(hwm_overview_active) { hwm_drawn_time=start; hwm_overview_tick(); hwm_tick_previous_active=hwm_active; return; }
    hwm_tick_previous_active=false;
    struct view *view = hwm_view();
    if (!view || !space_is_visible(view->sid)) {
        // Nothing can be drawn (a native fullscreen Space is in front). Returning
        // to the strip wakes the clock again; until then it should not keep ticking.
        __atomic_store_n(&hwm_active,false,__ATOMIC_RELEASE);
        return;
    }
    hwm_drawn_time=start;
    if (!hwm_backend_ok) {
        if (start-hwm_last_backend_retry < 2) return;
        hwm_last_backend_retry = start;
        struct window *w = window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id);
        hwm_backend_ok = w && scripting_addition_set_layer(w->id, window_check_flag(w, WINDOW_FLOAT) ? LAYER_ABOVE : LAYER_BELOW);
        if (!hwm_backend_ok) return;
        hwm_layout(view, false);
    }
    if (__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) && start-view->strip_last_time > .8) {
        __atomic_store_n(&__pending_gesture,false,__ATOMIC_RELEASE);
        hwm_focus_after_scroll = true;
    }
    // Where the fingers are as this frame is drawn; see hwm_held_velocity.
    hwm_held_lead=0;
    if(__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) && !hwm_rubber && hwm_motion_scale>0)
        hwm_held_lead=hwm_held_lead_at(latency<8 ? start-latency/1000 : start,view->strip_offset);
    // Applied once the keys or fingers rest; a swipe still in progress may yet go further.
    if(hwm_nav_pending && start-hwm_nav_time>.07 && !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) hwm_nav_flush();
    // A wheel pan that has been quiet for 90 ms is taken as "this is where I want to be".
    if(hwm_settle_pending && start-hwm_last_input>.09) {
        hwm_settle_pending=false;
        if(!hwm_drag_window && !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) {
            hwm_scroll(view,hwm_snap_target(view,view->strip_offset,hwm_bounds(view).size.width,false),true);
            hwm_focus_follow_to(view,view->strip_target_offset);
        }
    }
    // Content can shrink under a parked camera; glide back inside the strip.
    if(!view->strip_scrolling && !__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) &&
       (view->strip_offset>hwm_max_offset()+.5 || hwm_rubber)) hwm_scroll(view,fmin(view->strip_offset,hwm_max_offset()),true);
    bool dragging=hwm_drag_window!=0;
    double mark=hwm_now(), frame=hwm_frame_time(start);
    hwm_presented=frame;
    // Everything this frame changes is presented together.
    hwm_batch_hold=true;
    hwm_scale_reset_all();
    hwm_drag_autoscroll(view,start);
    struct window *edge=window_manager_find_window(&g_window_manager,hwm_edge_window);
    if(edge) hwm_edge_update(edge,view);
    mark=hwm_prof_mark(HWM_PROF_DRAG,mark);
    bool active = hwm_render(view, frame) || edge!=NULL || hwm_drag_window!=0;
    mark=hwm_prof_mark(HWM_PROF_RENDER,mark);
    active |= hwm_render_floating(frame);
    active |= hwm_render_closing(frame);
    active |= hwm_render_pops(frame);
    mark=hwm_prof_mark(HWM_PROF_EXTRAS,mark);
    active |= hwm_preview_render(frame);
    hwm_batch_release();
    mark=hwm_prof_mark(HWM_PROF_PREVIEW,mark);
    active |= hwm_nav_pending || hwm_settle_pending;
    if(hwm_close_source && start-hwm_close_time>1.0) { hwm_close_source=0; hwm_close_target=0; }
    if (hwm_close_target && !hwm_close_source && start-hwm_close_time>.04) {
        struct window *target=window_manager_find_window(&g_window_manager,hwm_close_target);
        hwm_preserve_focus_window=hwm_close_target; hwm_preserve_focus_until=start+.6;
        hwm_close_target=0;
        hwm_last_input=start;
        if(target) window_manager_focus_window_with_raise(&target->application->psn,target->id,target->ref);
    }
    if(hwm_close_target) active=true;
    if (__atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED)) active = true;
    hwm_feedback_tick(view,start);
    hwm_prof_mark(HWM_PROF_FEEDBACK,mark);
    if(dragging) { ++hwm_prof_drag_ticks; hwm_prof_mark(HWM_PROF_TICK_DRAGGING,start); }
    if (!active && hwm_focus_after_scroll && hwm_backend_ok) {
        hwm_focus_after_scroll = false;
        if(hwm_pointer_focus) { hwm_hold_focus(); }
        CGPoint cursor; SLSGetCurrentCursorLocation(g_connection,&cursor);
        struct window *target = window_manager_find_window_at_point(&g_window_manager,cursor);
        if (!hwm_pointer_focus && !hwm_focus_follow && target && window_manager_is_window_eligible(target)) {
            hwm_last_input = start; // A partially visible hover must not snap the viewport.
            window_manager_focus_window_without_raise(&target->application->psn,target->id);
        }
    }
    if (!active && hwm_state_pending) hwm_save_state();
    double elapsed = (hwm_now()-start)*1000;
    ++hwm_frames;
    if (elapsed > 8.34) ++hwm_slow_frames;
    if (elapsed > hwm_max_frame_ms) hwm_max_frame_ms = elapsed;
    hwm_frame_log[hwm_frame_log_count%HWM_FRAME_LOG].time=start; hwm_frame_log[hwm_frame_log_count%HWM_FRAME_LOG].offset=hwm_rendered_offset;
    hwm_frame_log[hwm_frame_log_count%HWM_FRAME_LOG].tick_ms=elapsed; hwm_frame_log[hwm_frame_log_count++%HWM_FRAME_LOG].latency_ms=latency;
    hwm_tick_previous_active=active;
    __atomic_store_n(&hwm_active, active || !hwm_backend_ok, __ATOMIC_RELEASE);
}

static CVReturn hwm_display_tick(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags inFlags, CVOptionFlags *outFlags, void *context)
{
    (void)link; (void)now; (void)inFlags; (void)outFlags; (void)context;
    if(out) __atomic_store_n(&hwm_vsync_host,out->hostTime,__ATOMIC_RELAXED);
    bool expected = false;
    if ((__atomic_load_n(&hwm_active, __ATOMIC_ACQUIRE) || hwm_stop_requested) &&
        __atomic_compare_exchange_n(&hwm_tick_pending, &expected, true, false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        __atomic_store_n(&hwm_tick_posted, read_os_timer(), __ATOMIC_RELAXED);
        event_loop_post(&g_event_loop, HORIZONTAL_TICK, NULL, 0);
    }
    return kCVReturnSuccess;
}

static void hwm_hold_focus(void)
{
    hwm_focus_guard=true; hwm_focus_guard_time=hwm_now();
    SLSGetCurrentCursorLocation(g_connection,&hwm_focus_guard_point);
    hwm_focus_after_scroll=false;
}
static bool horizontal_hover_allowed(CGPoint point)
{
    if (hwm_overview_active) return false;
    if (!hwm_ready || !hwm_focus_guard) return true;
    if (hwm_now()-hwm_focus_guard_time<.35) return false;
    if (hypot(point.x-hwm_focus_guard_point.x,point.y-hwm_focus_guard_point.y)<6) return false;
    hwm_focus_guard=false; return true;
}
static void horizontal_hover_received(struct window *window)
{
    hwm_hover_pid=window->application->pid; hwm_hover_time=hwm_now();
}
static void horizontal_activated(struct application *application)
{
    if (!hwm_ready) return;
    if(application->pid==hwm_hover_pid && hwm_now()-hwm_hover_time<.3) return;
    struct window *hover=window_manager_find_window(&g_window_manager,g_mouse_state.ffm_window_id);
    if (hover && hover->application==application) return;
    hwm_hold_focus(); hwm_last_input=0;
}
static void horizontal_focused(struct window *window, struct view *view)
{
    if (!hwm_ready || hwm_paused || hwm_overview_active) return;
    hwm_workflow_note_explicit_focus(window,view);
    hwm_hold_focus();
    scripting_addition_set_layer(window->id,window_check_flag(window,WINDOW_FLOAT)?LAYER_ABOVE:LAYER_BELOW);
    // Keyboard navigation has already aimed the camera at its cursor. Focus
    // reports for windows it passed on the way must not pull the camera back.
    if (hwm_nav_window && hwm_now()-hwm_nav_time<.6) return;
    if ((window->id==hwm_preserve_focus_window && hwm_now()<hwm_preserve_focus_until) || !view || view->layout!=VIEW_STRIP || hwm_close_target || hwm_drag_window ||
        __atomic_load_n(&__pending_gesture,__ATOMIC_RELAXED) || hwm_now()-hwm_last_input<.15) return;
    CGRect bounds=hwm_bounds(view);
    double left=window->strip_world_x,right=left+window->strip_width,offset=view->strip_target_offset;
    if(left<offset) hwm_scroll(view,left,true);
    else if(right>offset+bounds.size.width) hwm_scroll(view,right-bounds.size.width,true);
}
static void horizontal_removing(struct window *window, bool whole_app)
{
    if (!hwm_ready || hwm_paused || !window) return;
    if(hwm_drag_window==window->id) { hwm_drag_window=0; hwm_preview_hide(); }
    if(hwm_nav_window==window->id) { hwm_nav_window=0; hwm_nav_pending=false; }
    hwm_hole_note(window_manager_find_managed_window(&g_window_manager,window),window);
    if (whole_app && hwm_close_target) {
        struct window *anchor=window_manager_find_window(&g_window_manager,hwm_close_target);
        if(anchor && anchor->application!=window->application) return;
    }
    if (hwm_close_source==window->id) return;
    bool just_lost_focus=window->id==hwm_previous_focus && hwm_now()-hwm_previous_focus_time<.4;
    if (window->id!=g_window_manager.focused_window_id && !just_lost_focus && !hwm_close_target) return;
    struct view *view=window_manager_find_managed_window(&g_window_manager,window);
    if(!view || view->layout!=VIEW_STRIP) return;
    struct window *best=NULL; double distance=INFINITY;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w==window || w->strip_close_ghost || (whole_app && w->application==window->application)) continue;
        double d=fabs(w->strip_world_x-window->strip_world_x)+fabs(w->strip_world_y-window->strip_world_y)*.1;
        if(d<distance) { best=w; distance=d; }
    }
    if(best) {
        hwm_close_source=window->id; hwm_close_target=best->id; hwm_close_time=hwm_now();
        // The camera is already gliding to its resting place around a vacated window.
        hwm_close_screen_x=best->strip_world_x-(window->strip_close_ghost?view->strip_target_offset:just_lost_focus?hwm_previous_focus_offset:hwm_offset(view,hwm_now()));
        hwm_hold_focus(); hwm_wake();
    }
}

static struct window_node *hwm_focused_node(struct view *view)
{
    return view ? view_find_window_node(view, g_window_manager.focused_window_id) : NULL;
}
static uint64_t hwm_column_of(struct window *w) { return w->strip_full_width ? ((uint64_t)w->id<<32)|w->id : (w->strip_column ? w->strip_column : w->id); }
/* Camera offset that centres a tile; one wider than the viewport shows its left edge. */
static double hwm_center_target(struct view *view,struct window *w)
{
    double viewport=hwm_bounds(view).size.width;
    return w->strip_width>=viewport ? w->strip_world_x : hstrip_center_offset(w->strip_world_x,w->strip_width,viewport);
}
/* The visible window of the column one step left (-1) or right (+1). */
static struct window *hwm_neighbor_column(struct view *view,struct window *from,int direction)
{
    uint64_t own=hwm_column_of(from), found=0; bool seen=false;
    struct window *result=NULL;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]); if(!w || w->strip_close_ghost) continue;
        uint64_t column=hwm_column_of(w);
        if(column==own) { seen=true; if(direction<0) return result; continue; }
        if(direction<0) {
            // Remember the latest column to the left, preferring its shown tab / top row.
            if(column!=found) { found=column; result=w; }
            else if(hwm_workflow_tab_hidden(result) && !hwm_workflow_tab_hidden(w)) result=w;
        } else if(seen) {
            if(!found) { found=column; result=w; }
            else if(column!=found) return result;
            else if(hwm_workflow_tab_hidden(result) && !hwm_workflow_tab_hidden(w)) result=w;
        }
    }
    return direction>0 ? result : NULL;
}
/* Keyboard navigation aims the camera and the border immediately and applies
 * the real focus once the keys rest. Activating every window passed on the way
 * is what made quick presses stutter. */
static void hwm_nav_flush(void)
{
    if(!hwm_nav_pending) return;
    hwm_nav_pending=false;
    struct window *w=window_manager_find_window(&g_window_manager,hwm_nav_window);
    if(!w) return;
    hwm_preserve_focus_window=w->id; hwm_preserve_focus_until=hwm_now()+.6;
    hwm_workflow_note_explicit_focus(w,hwm_view());
    window_manager_focus_window_with_raise(&w->application->psn,w->id,w->ref);
}
static struct window *hwm_nav_base(struct view *view)
{
    if(!view) return window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
    struct window *w=hwm_nav_window && hwm_now()-hwm_nav_time<.6 ? window_manager_find_window(&g_window_manager,hwm_nav_window) : NULL;
    if(w && view && view_find_window_node(view,w->id)) return w;
    return window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
}
/* The window a command should act on: the navigation cursor while it leads
 * the reported focus, otherwise the focused window. */
static struct window *hwm_action_window(void) { return hwm_nav_base(hwm_view()); }
static void hwm_nav_to(struct view *view,struct window *target)
{
    double now=hwm_now();
    hwm_nav_window=target->id; hwm_nav_time=now; hwm_nav_pending=true; hwm_last_input=now;
    hwm_hold_focus();
    hwm_scroll(view,hwm_center_target(view,target),true);
    hwm_feedback_focus(NULL,target);
}
/* When the strip is moved under a still pointer, the window that ends up
 * beneath it takes focus without the pointer having to move. Which window
 * that will be is known the moment the camera is given its destination
 * `offset`, so focus does not wait for the strip to arrive. (In centre mode
 * the window brought to the middle of the screen is chosen instead.) Empty
 * desktop under the pointer changes nothing. This reuses the navigation
 * cursor: the border leads and activation follows once the gesture is over. */
static void hwm_focus_follow_to(struct view *view,double offset)
{
    if(!hwm_focus_follow || !view || hwm_drag_window || hwm_overview_active) return;
    CGRect bounds=hwm_bounds(view);
    CGPoint pointer=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
    if(hwm_focus_follow==2) {
        if(SLSGetCurrentCursorLocation(g_connection,&pointer)!=kCGErrorSuccess) return;
        // A floating window under the pointer stays in charge: it does not move with the strip.
        bool covered=false;
        table_for(struct window *f,g_window_manager.window, {
            CGRect frame=CGRectNull;
            if(!covered && f->is_root && window_check_flag(f,WINDOW_FLOAT) && !window_check_flag(f,WINDOW_MINIMIZE) && !f->application->is_hidden &&
               window_manager_is_window_eligible(f) && SLSGetWindowBounds(g_connection,f->id,&frame)==kCGErrorSuccess && CGRectContainsPoint(frame,pointer)) covered=true;
        })
        if(covered) return;
    }
    double x=offset+pointer.x-bounds.origin.x, y=pointer.y-bounds.origin.y, gap=view->window_gap*.5;
    struct window *target=NULL;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n && !target;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w->strip_close_ghost || !w->strip_initialized || hwm_workflow_tab_hidden(w)) continue;
        // Half the gap on each side belongs to the nearer window, so the pointer is rarely over nothing.
        if(x<w->strip_world_x-gap || x>w->strip_world_x+w->strip_width+gap) continue;
        if(hwm_focus_follow==2 && (y<w->strip_world_y-gap || y>w->strip_world_y+w->strip_height+gap)) continue;
        target=w; break;
    }
    struct window *current=hwm_action_window();
    if(!target || target==current) return;
    // In centre mode, staying within the focused column keeps the row already in use.
    if(hwm_focus_follow==1 && current && view_find_window_node(view,current->id) && hwm_column_of(current)==hwm_column_of(target)) return;
    hwm_nav_window=target->id; hwm_nav_time=hwm_now(); hwm_nav_pending=true;
    hwm_hold_focus();
    hwm_feedback_focus(NULL,target);
}
static void hwm_commit_order(struct view *view,HStripColumnItem *items,size_t count)
{
    struct window_node *slot=window_node_find_first_leaf(view->root);
    for(size_t i=0;i<count && slot;i++) {
        struct window_node *found=view_find_window_node(view,(uint32_t)items[i].id);
        if(!found) continue;
        if(found!=slot) window_node_swap_window_list(found,slot);
        slot=window_node_find_next_leaf(slot);
    }
}
/* Move the focused window's whole column: -1/+1 swap it with the neighbouring
 * column, -2/+2 send it to the start or end of the strip. Stacks travel intact. */
static bool hwm_move_column(struct view *view,struct window *window,int mode)
{
    CGRect bounds=hwm_bounds(view); HStripColumnItem *items=NULL;
    size_t count=hwm_items(view,bounds,&items); if(!items) return false;
    HStripColumnItem *mine=calloc(count?count:1,sizeof(*mine)),*rest=calloc(count?count:1,sizeof(*rest));
    size_t mine_count=0,rest_count=0,position=0; uint64_t own=hwm_column_of(window); bool ok=mine && rest;
    for(size_t i=0;ok && i<count;i++) {
        if(hstrip_columns_key(&items[i])==own) { if(!mine_count) position=rest_count; mine[mine_count++]=items[i]; }
        else rest[rest_count++]=items[i];
    }
    size_t insert=position;
    if(ok && mine_count) {
        if(mode==-2) insert=0;
        else if(mode==2) insert=rest_count;
        else if(mode<0 && position>0) {
            uint64_t key=hstrip_columns_key(&rest[position-1]); insert=position-1;
            while(insert>0 && hstrip_columns_key(&rest[insert-1])==key) --insert;
        } else if(mode>0 && position<rest_count) {
            uint64_t key=hstrip_columns_key(&rest[position]); insert=position+1;
            while(insert<rest_count && hstrip_columns_key(&rest[insert])==key) ++insert;
        }
    }
    ok=ok && mine_count && insert!=position;
    if(ok) {
        hwm_undo_capture();
        memcpy(items,rest,insert*sizeof(*items));
        memcpy(items+insert,mine,mine_count*sizeof(*items));
        memcpy(items+insert+mine_count,rest+insert,(rest_count-insert)*sizeof(*items));
        hwm_commit_order(view,items,count);
        hwm_layout(view,true);
        // Follow the window: it stays under the user's eyes while the strip rearranges.
        hwm_scroll(view,hwm_center_target(view,window),true);
        hwm_hold_focus();
    }
    free(items); free(mine); free(rest);
    return ok;
}
static void hwm_spawn(NSString *command)
{
    if(!command.length) return;
    hwm_hold_focus();
    NSString *copy=[command copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTask *task=[[[NSTask alloc] init] autorelease]; task.launchPath=@"/bin/sh";
        task.arguments=@[@"-c",copy];
        NSError *error=nil;
        if(![task launchAndReturnError:&error]) { warn("Tana: launch failed: %s\n",error.localizedDescription.UTF8String); hwm_hud([NSString stringWithFormat:@"Could not run: %@",copy]); }
        [copy release];
    });
}
#include "overview_runtime.m"

static void hwm_action(int action)
{
    if(action==HWM_CANCEL_DRAG) { hwm_cancel_drag(); return; }
    if(action==HWM_OVERVIEW) {
        if(hwm_overview_active) horizontal_overview_select(0,0);
        else hwm_overview_begin(true);
        return;
    }
    if(action==HWM_OVERVIEW_CANCEL) { horizontal_overview_select(0,0); return; }
    if (action==HWM_TERMINAL || action==HWM_BROWSER) {
        hwm_spawn(action==HWM_TERMINAL ? (hwm_terminal_command ?: @"open -na Ghostty") : (hwm_browser_command ?: @"open -a Firefox"));
        return;
    }
    if (action == HWM_QUIT) { hwm_shutdown(); return; }
    struct view *view = hwm_view();
    struct window *window = hwm_action_window();
    struct window_node *node = view && window ? view_find_window_node(view, window->id) : NULL;
    if (action == HWM_PAUSE) {
        horizontal_overview_done();
        hwm_cancel_closing();
        hwm_cancel_pops();
        hwm_paused = !hwm_paused;
        hwm_alpha_sync(hwm_paused);
        hwm_hud(hwm_paused ? @"Tana paused" : @"Tana resumed");
        __atomic_store_n(&hwm_active,false,__ATOMIC_RELEASE);
        if (!hwm_paused) {
            table_for (struct window *w, g_window_manager.window, { w->strip_last_frame = CGRectNull; })
            hwm_layout(view,true);
        }
        return;
    }
    if (hwm_paused || !view) return;
    if (action == HWM_HOME) { hwm_scroll(view,0,true); hwm_focus_follow_to(view,0); return; }
    if (action == HWM_REFLOW) {
        table_for (struct window *w, g_window_manager.window, { w->strip_last_frame = CGRectNull; })
        hwm_layout(view,true); return;
    }
    if (!window) return;
    if(action==HWM_CLOSE) {
        if(node && !window->strip_close_pending && !window->strip_close_ghost) {
            // Give up the window's place now: its neighbours close in while it
            // fades, instead of waiting for the application to finish closing.
            hwm_hole_note(view,window);
            window->strip_close_ghost=true; window->strip_ghost_time=hwm_now();
            hwm_layout(view,true);
        }
        hwm_close_animated(window); return;
    }
    if (action == HWM_FLOAT) {
        bool should_float = !window_check_flag(window, WINDOW_FLOAT);
        if (should_float) {
            CGRect bounds = hwm_bounds(view);
            hwm_hole_note(view,window);
            window_manager_make_window_floating(&g_space_manager,&g_window_manager,window,true,true);
            double width = fmin(window->strip_width > 0 ? window->strip_width : 800,bounds.size.width*.8);
            CGRect target=CGRectMake(bounds.origin.x+(bounds.size.width-width)/2,bounds.origin.y+bounds.size.height*.12,width,bounds.size.height*.76);
            // A window that has floated before returns to where it floated.
            CGRect saved=window->strip_float_saved;
            if(saved.size.width>=200 && saved.size.height>=160 && CGRectIntersectsRect(saved,CGRectInset(bounds,40,40))) target=saved;
            hwm_float_to(window,target);
            scripting_addition_set_layer(window->id,LAYER_ABOVE);
        } else {
            CGRect current=window->strip_float_animating ? window->strip_float_target : CGRectNull;
            if(!CGRectIsNull(current) || SLSGetWindowBounds(g_connection,window->id,&current)==kCGErrorSuccess) window->strip_float_saved=current;
            window->strip_float_animating=false; window->strip_float_full=false;
            window_manager_make_window_floating(&g_space_manager,&g_window_manager,window,false,true);
            hwm_layout(view,true);
            horizontal_focused(window,view);
        }
        return;
    }
    if (!node) {
        if (action == HWM_FULL) {
            CGRect bounds = hwm_bounds(view);
            if (!window->strip_float_full) {
                SLSGetWindowBounds(g_connection,window->id,&window->strip_float_restore);
                hwm_float_to(window,bounds);
            } else {
                CGRect f=window->strip_float_restore;
                hwm_float_to(window,f);
            }
            window->strip_float_full=!window->strip_float_full;
        }
        return;
    }
    if (action == HWM_FULL) {
        if (!window->strip_full_width) window->strip_saved_width = window->strip_width;
        window->strip_full_width = !window->strip_full_width;
        if (!window->strip_full_width) window->strip_width = window->strip_saved_width;
        hwm_layout(view,true);
        hwm_scroll(view, window->strip_world_x, true);
    } else if (action == HWM_CENTER) {
        CGRect bounds = hwm_bounds(view);
        hwm_scroll(view,hstrip_center_offset(window->strip_world_x,window->strip_width,bounds.size.width),true);
    } else if (action == HWM_LEFT || action == HWM_RIGHT) {
        struct window *base=hwm_nav_base(view);
        struct window *next=base && view_find_window_node(view,base->id) ? hwm_neighbor_column(view,base,action==HWM_LEFT?-1:1) : NULL;
        if (next) hwm_nav_to(view,next);
        else if (base && view_find_window_node(view,base->id)) { hwm_feedback_navigation(true); hwm_scroll(view,hwm_center_target(view,base),true); }
    } else if (action == HWM_MOVE_LEFT || action == HWM_MOVE_RIGHT || action == HWM_MOVE_FIRST || action == HWM_MOVE_LAST) {
        if(!hwm_move_column(view,window,action==HWM_MOVE_LEFT?-1:action==HWM_MOVE_RIGHT?1:action==HWM_MOVE_FIRST?-2:2)) hwm_feedback_navigation(true);
    }
}

/* The action bound to a key press, if any. */
static NSString *hwm_shortcut_action(CGEventRef event,int code)
{
    CGEventFlags flags=CGEventGetFlags(event);
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    NSString *name=[snapshot actionForKeyCode:(unsigned short)code modifiers:(NSUInteger)flags];
    // macOS tags physical arrow keys with Function even without an Fn chord.
    if(!name && code>=123 && code<=126) name=[snapshot actionForKeyCode:(unsigned short)code modifiers:((NSUInteger)flags&~NSEventModifierFlagFunction)];
    name=[[name retain] autorelease];
    [snapshot release];
    return name;
}
static bool horizontal_event(CGEventType type, CGEventRef event)
{
    if (!hwm_ready) return false;
    // Let the engine's own Space-recovery gesture reach Dock.
    if ((type == 29 || type == 30) && CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID) == getpid()) return false;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        hwm_swiping = false;
        hwm_vertical_swiping=false;
        if(hwm_overview_active) event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,HWM_OVERVIEW_CANCEL);
        __atomic_store_n(&__pending_gesture,false,__ATOMIC_RELEASE);
        return false;
    }
    if (type == kCGEventKeyUp) {
        int code = (int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        if (code >= 0 && code < 128 && hwm_keys[code]) { hwm_keys[code] = false; return true; }
    }
    if (hwm_paused) return false;
    if(hwm_tab_click && type==kCGEventLeftMouseUp) { hwm_tab_click=false; return true; }
    if(!hwm_overview_active && type==kCGEventLeftMouseDown) {
        NSDictionary *tab=[[TanaFeedback shared] tabAt:CGEventGetLocation(event)];
        if(tab) { hwm_tab_click=true; event_loop_post(&g_event_loop,HORIZONTAL_INPUT,[tab retain],HWM_TAB_SELECT); return true; }
    }
    if(hwm_overview_active && (type==kCGEventLeftMouseDown || type==kCGEventMouseMoved ||
       type==kCGEventLeftMouseDragged || type==kCGEventLeftMouseUp)) {
        // Fully transparent AppKit pixels are click-through. Route the global
        // pointer stream to the selector before ordinary app/drag handling.
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_OVERVIEW_POINTER);
        return true;
    }
    if(type==30 && CGEventGetIntegerValueField(event,110)==23 && CGEventGetIntegerValueField(event,123)==2) {
        int phase=(int)CGEventGetIntegerValueField(event,132);
        if(phase==1) hwm_vertical_swiping=true;
        hwm_vertical_swipe_time=read_os_timer();
        if(hwm_vertical_swiping)
            event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_OVERVIEW_GESTURE);
        if(phase==4 || phase==8) hwm_vertical_swiping=false;
        return true;
    }
    if(type==29 && (hwm_overview_active || (hwm_vertical_swiping &&
        (double)(read_os_timer()-hwm_vertical_swipe_time)/read_os_freq()<1))) return true;
    if(hwm_overview_active && type==30 && CGEventGetIntegerValueField(event,110)==23) return true;
    if(hwm_overview_active && type==kCGEventKeyDown) {
        int code=(int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        if(code>=0 && code<128) hwm_keys[code]=true;
        // The shortcuts that open the overview also close it; every other key belongs to the overview itself.
        NSString *bound=hwm_shortcut_action(event,code);
        if([bound hasPrefix:@"overview"]) {
            if(!CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat)) event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup(bound.UTF8String),HWM_NAMED_ACTION);
            return true;
        }
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_OVERVIEW_KEY);
        return true;
    }
    if (type == kCGEventKeyDown) {
        CGEventFlags flags = CGEventGetFlags(event);
        CGEventFlags modifiers=flags&(kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate|kCGEventFlagMaskControl|kCGEventFlagMaskShift);
        int code=(int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        if(code==53 && hwm_drag_window) {
            hwm_keys[code]=true;
            event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,HWM_CANCEL_DRAG); return true;
        }
        (void)modifiers;
        NSString *name=hwm_shortcut_action(event,code);
        // With no overview to close, the key keeps its usual meaning.
        if([name isEqualToString:@"overview-close"]) name=nil;
        if(name) {
            bool repeat=CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat);
            bool allow=[@[@"left",@"right",@"up",@"down",@"move-left",@"move-right",@"swap-left",@"swap-right"] containsObject:name];
            if(!repeat || allow) event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup(name.UTF8String),HWM_NAMED_ACTION);
            ++hwm_key_actions; if(code>=0 && code<128) hwm_keys[code]=true;
            return true;
        }
    }
    if (type == kCGEventScrollWheel && (CGEventGetFlags(event)&kCGEventFlagMaskAlternate)) {
        if (CGEventGetFlags(event)&(kCGEventFlagMaskCommand|kCGEventFlagMaskControl)) return false;
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_EVENT);
        return true;
    }
    if (type == 30 && CGEventGetIntegerValueField(event,110) == 23 && CGEventGetIntegerValueField(event,123) == 1) {
        int phase = (int)CGEventGetIntegerValueField(event,132);
        if (phase == 1) hwm_swiping = true;
        if (!hwm_swiping) return false;
        hwm_swipe_time = read_os_timer();
        event_loop_post(&g_event_loop,HORIZONTAL_INPUT,(void *)CFRetain(event),HWM_EVENT);
        if (phase == 4 || phase == 8) hwm_swiping = false;
        return true;
    }
    // Dock emits a companion gesture stream. Only swallow it during the claimed
    // horizontal gesture, never pinch, rotate, or ordinary two-finger scrolling.
    if (type == 29 && hwm_swiping) {
        if ((double)(read_os_timer()-hwm_swipe_time)/read_os_freq() > 1) hwm_swiping = false;
        return hwm_swiping;
    }
    return false;
}

/* Column extents in strip order; the caller frees both arrays. */
static size_t hwm_columns(struct view *view,double **lefts_out,double **widths_out)
{
    size_t capacity=0,count=0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) capacity+=n->window_count;
    double *lefts=calloc(capacity?capacity:1,sizeof(double)),*widths=calloc(capacity?capacity:1,sizeof(double));
    if(lefts && widths) for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w->strip_close_ghost || !w->strip_initialized || (count && lefts[count-1]==w->strip_world_x)) continue;
        lefts[count]=w->strip_world_x; widths[count++]=w->strip_width;
    }
    *lefts_out=lefts; *widths_out=widths;
    return lefts && widths ? count : 0;
}
/* Where the strip should come to rest near `desired`: a column centred (or
 * flush, in column mode). The decision is made the instant the fingers lift,
 * from where the release velocity was already taking the strip. After a swipe
 * it is directional: going a modest share of the way toward the next column
 * commits to it, so changing window takes a short flick, not a long drag. */
static double hwm_snap_target(struct view *view,double desired,double viewport,bool swipe)
{
    if(!hwm_snap) return desired;
    double *lefts,*widths; size_t count=hwm_columns(view,&lefts,&widths);
    double end=hwm_max_offset(), result=desired;
    if(hwm_snap==2 && count) {
        // Resting offsets in ascending order: each column centred, then the empty end.
        double *rests=calloc(count+1,sizeof(double)); size_t n=0;
        if(rests) {
            for(size_t i=0;i<count;i++) {
                double c=hstrip_snap_center(lefts[i]+widths[i]*.5-viewport*.5,viewport,lefts+i,widths+i,1);
                if(!n || c>rests[n-1]+.5) rests[n++]=c;
            }
            if(isfinite(end) && end>rests[n-1]+.5) rests[n++]=end;
            result=swipe ? hstrip_snap_directional(hwm_snap_origin,desired,rests,n,hwm_snap_threshold)
                         : hstrip_snap_directional(desired,desired,rests,n,hwm_snap_threshold);
            free(rests);
        }
    } else if(count) {
        result=hstrip_snap_offset(desired,viewport,lefts,widths,count,viewport*.5);
        // The empty desktop past the last window is a resting place too.
        if(isfinite(end) && fabs(end-desired)<fabs(result-desired)) result=end;
    }
    free(lefts); free(widths);
    return result;
}
/* While held, the strip leans weakly toward the nearest centred column. */
static double hwm_magnetize(struct view *view,double raw,double viewport)
{
    if(hwm_snap!=2 || !(hwm_magnet>0) || hwm_motion_scale==0) return raw;
    double *lefts,*widths; size_t count=hwm_columns(view,&lefts,&widths);
    double rest=count ? hstrip_snap_center(raw,viewport,lefts,widths,count) : raw;
    free(lefts); free(widths);
    return hstrip_magnet(raw,rest,viewport*.16,hwm_magnet);
}

static void horizontal_input(void *context, int action)
{
    if(action==HWM_TAB_SELECT) {
        NSDictionary *tab=context; struct window *w=window_manager_find_window(&g_window_manager,[tab[@"id"] unsignedIntValue]);
        if(w && w->application->pid==[tab[@"pid"] intValue]) window_manager_focus_window_with_raise(&w->application->psn,w->id,w->ref);
        [tab release]; return;
    }
    if(action==HWM_APPLY_RULE) { hwm_apply_app_rule_now(window_manager_find_window(&g_window_manager,(uint32_t)(uintptr_t)context)); return; }
    if(action==HWM_NAMED_ACTION) { hwm_named_action(context); free(context); return; }
    if(action==HWM_OVERVIEW_KEY) {
        CGEventRef event=context; uint64_t generation=hwm_overview_generation;
        dispatch_async(dispatch_get_main_queue(),^{
            if(hwm_overview_active && generation==hwm_overview_generation)
                [[HorizontalWindowOverview sharedOverview] keyEvent:[NSEvent eventWithCGEvent:event]];
            CFRelease(event);
        }); return;
    }
    if(action==HWM_OVERVIEW_HIGHLIGHT) { hwm_overview_highlight((uint32_t)(uintptr_t)context); return; }
    if(action==HWM_OVERVIEW_FILTER) { NSArray *dimmed=context; hwm_overview_filter(dimmed); [dimmed release]; return; }
    if(action==HWM_OVERVIEW_DRAG) {
        NSArray *drag=context;
        hwm_overview_drag([drag[0] unsignedIntValue],[drag[1] intValue],CGPointMake([drag[2] doubleValue],[drag[3] doubleValue]));
        [drag release]; return;
    }
    if(action==HWM_OVERVIEW_POINTER) {
        CGEventRef event=context;
        CGPoint point=CGEventGetLocation(event);
        CGEventType kind=CGEventGetType(event);
        uint64_t generation=hwm_overview_generation;
        NSPoint local=NSMakePoint(point.x-hwm_overview_screen.origin.x,point.y-hwm_overview_screen.origin.y);
        dispatch_async(dispatch_get_main_queue(), ^{
            if(hwm_overview_active && generation==hwm_overview_generation) {
                HorizontalWindowOverview *overview=[HorizontalWindowOverview sharedOverview];
                if(kind==kCGEventLeftMouseDown) [overview pressAt:local];
                else if(kind==kCGEventLeftMouseDragged) [overview dragAt:local];
                else if(kind==kCGEventLeftMouseUp) [overview releaseAt:local];
                else [overview mouseAt:local];
            }
        });
        CFRelease(event); return;
    }
    if(action==HWM_OVERVIEW_GESTURE) { hwm_overview_gesture((CGEventRef)context); CFRelease(context); return; }
    if (action != HWM_EVENT) { hwm_action(action); return; }
    CGEventRef event = context;
    struct view *view = hwm_view();
    if (!view || hwm_paused) { CFRelease(event); return; }
    double now = hwm_now();
    if (CGEventGetType(event) == kCGEventScrollWheel) {
        double dx = CGEventGetDoubleValueField(event,kCGScrollWheelEventPointDeltaAxis2);
        double dy = CGEventGetDoubleValueField(event,kCGScrollWheelEventPointDeltaAxis1);
        if (CGEventGetFlags(event)&kCGEventFlagMaskShift) {
            hwm_scroll(view,view->strip_offset+(fabs(dx)>fabs(dy)?dx:dy),false);
            hwm_settle_pending=true;
        } else {
            if (now-hwm_last_input > .25 || !hwm_resize_window) { hwm_undo_capture(); hwm_resize_window = g_window_manager.focused_window_id; }
            struct window *window = window_manager_find_window(&g_window_manager,hwm_resize_window);
            if (window && isfinite(dx) && isfinite(dy)) {
                if (window_manager_find_managed_window(&g_window_manager,window)) {
                    window->strip_full_width = false;
                    hwm_column_width(view,window,hstrip_resize_width(window->strip_width,(fabs(dx)>fabs(dy)?dx:-dy)*2,240,hwm_bounds(view).size.width));
                    hwm_layout(view,true);
                } else {
                    CGRect f=window->strip_float_animating ? window->strip_float_target : window->frame;
                    if(!window->strip_float_animating) SLSGetWindowBounds(g_connection,window->id,&f);
                    f.size=CGSizeMake(fmax(200,f.size.width-dx*2),fmax(160,f.size.height-dy*2));
                    hwm_float_to(window,f);
                }
            }
        }
        hwm_last_input = now;
    } else {
        int phase = (int)CGEventGetIntegerValueField(event,132);
        double progress = CGEventGetDoubleValueField(event,124);
        if (!isfinite(progress) || fabs(progress) > 20) { CFRelease(event); return; }
        double width = hwm_bounds(view).size.width;
        // Speeds are measured between the reports themselves; the time each one
        // spent queued behind other work would otherwise read as a change of speed.
        double stamp = hwm_event_time(event,now);
        progress*=hwm_swipe_gain;
        if (phase == 1) {
            hwm_snap_origin = view->strip_target_offset;
            view->strip_gesture_origin = hwm_offset(view,now);
            view->strip_scrolling = false;
            view->strip_velocity = 0;
            view->strip_last_progress = progress;
            view->strip_last_time = stamp;
            hwm_held_velocity=0; hwm_held_lead=0; hwm_held_time=stamp; hwm_held_count=0;
            hwm_wake();
            __atomic_store_n(&__pending_gesture,true,__ATOMIC_RELEASE);
        } else if (phase == 2) {
            double dt = stamp-view->strip_last_time;
            if (dt > .001 && dt < .15) {
                double velocity = (progress-view->strip_last_progress)*width/dt;
                view->strip_velocity = view->strip_velocity*.65+velocity*.35;
            }
            double raw=view->strip_gesture_origin+progress*width, limit=hwm_max_offset();
            hwm_scroll(view,raw<0 || raw>limit ? raw : hwm_magnetize(view,raw,width),false);
            // Past either end the strip keeps following the finger, with growing resistance.
            hwm_rubber=hwm_motion_scale==0 ? 0 : raw<0 ? -hstrip_rubber_band(-raw,width*.3) : raw>limit ? hstrip_rubber_band(raw-limit,width*.3) : 0;
            // A pause or an end of the strip starts the measurement afresh.
            if(hwm_rubber || stamp-hwm_held_time>.1) { hwm_held_count=0; hwm_held_lead=0; }
            if(!hwm_rubber) hwm_held_note(stamp,view->strip_offset);
            hwm_held_time=stamp;
            view->strip_last_progress = progress;
            view->strip_last_time = stamp;
            hwm_input_log[hwm_input_log_count%HWM_FRAME_LOG].time=stamp; hwm_input_log[hwm_input_log_count++%HWM_FRAME_LOG].offset=raw;
        } else if (phase == 4 || phase == 8) {
            double velocity = stamp-view->strip_last_time < .1 && !hwm_rubber ? view->strip_velocity : 0;
            double coast = phase == 8 ? 0 : fmax(-width*.65,fmin(width*.65,velocity/hwm_scroll_omega));
            double target=view->strip_offset+coast;
            if(phase==4) target=hwm_snap_target(view,target,width,true);
            hwm_scroll_current_velocity=phase==8?0:velocity; hwm_release_velocity=true;
            hwm_scroll(view,target,true); // Starts from where the last frame drew the strip.
            hwm_held_velocity=0; hwm_held_lead=0; hwm_held_count=0;
            // Focus goes where the strip is going, decided now rather than when it arrives.
            if(phase==4) hwm_focus_follow_to(view,view->strip_target_offset);
            hwm_focus_after_scroll = true;
            __atomic_store_n(&__pending_gesture,false,__ATOMIC_RELEASE);
            __atomic_store_n(&__last_gesture_time,read_os_timer(),__ATOMIC_RELEASE);
        }
        hwm_last_input = now;
    }
    CFRelease(event);
}

static void hwm_preview_hide(void)
{
    if(!hwm_preview_visible || hwm_preview_hiding) return;
    hwm_preview_alpha_from=hwm_preview_alpha;
    hwm_preview_alpha_start=hwm_now(); hwm_preview_hiding=true; hwm_wake();
}
static void hwm_preview_hide_immediately(void)
{
    hwm_preview_visible=false;
    hwm_preview_hiding=false; hwm_preview_alpha=0;
    if(hwm_preview_id) SLSOrderWindow(g_connection,hwm_preview_id,0,0);
}
static bool hwm_preview_render(double now)
{
    if(!hwm_preview_visible) return false;
    double fade=(now-hwm_preview_alpha_start)/.14;
    hwm_preview_alpha=hwm_preview_alpha_from+((hwm_preview_hiding?0:1)-hwm_preview_alpha_from)*horizontal_ease(fade);
    if(hwm_preview_hiding && fade>=1) { hwm_preview_hide_immediately(); return false; }
    if(hwm_preview_id) SLSSetWindowAlpha(g_connection,hwm_preview_id,hwm_preview_alpha);
    double span=fmax(.001,.18*hwm_motion_scale), t=(now-hwm_preview_start)/span, p=hstrip_spring_progress(now-hwm_preview_start,span);
    CGRect a=hwm_preview_from,b=hwm_preview_target;
    CGRect f=CGRectMake(a.origin.x+(b.origin.x-a.origin.x)*p,a.origin.y+(b.origin.y-a.origin.y)*p,
                       a.size.width+(b.size.width-a.size.width)*p,a.size.height+(b.size.height-a.size.height)*p);
    bool active=t<1 || fade<1;
    // Opacity can continue changing without recreating paths, regions, or the
    // CGContext backing store once the geometry has settled.
    if(hwm_preview_context && CGRectEqualToRect(f,hwm_preview_current)) return active;
    hwm_preview_current=f;
    CFTypeRef region; CGSNewRegionWithRect(&f,&region);
    if(!hwm_preview_id) {
        uint64_t tags=(1ULL<<1)|(1ULL<<9);
        CFTypeRef empty=CGRegionCreateEmptyRegion();
        SLSNewWindowWithOpaqueShapeAndContext(g_connection,2,region,empty,13,&tags,0,0,64,&hwm_preview_id,NULL);
        CFRelease(empty);
        sls_window_disable_shadow(hwm_preview_id);
        SLSSetWindowResolution(g_connection,hwm_preview_id,1);
        SLSSetWindowOpacity(g_connection,hwm_preview_id,0);
        SLSSetWindowAlpha(g_connection,hwm_preview_id,hwm_preview_alpha);
        SLSSetWindowLevel(g_connection,hwm_preview_id,3);
        hwm_preview_context=SLWindowContextCreate(g_connection,hwm_preview_id,0);
    }
    if(!hwm_preview_context) { CFRelease(region); return false; }
    CGRect local=CGRectMake(0,0,f.size.width,f.size.height);
    SLSDisableUpdate(g_connection);
    SLSSetWindowShape(g_connection,hwm_preview_id,0,0,region);
    CGContextClearRect(hwm_preview_context,local);
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset(local,local.size.width<=4?0:2,2),local.size.width<=4?2:12,local.size.width<=4?2:12,NULL);
    CGContextSetRGBFillColor(hwm_preview_context,.22,.55,1,.20);
    CGContextSetRGBStrokeColor(hwm_preview_context,.28,.63,1,.95);
    CGContextSetLineWidth(hwm_preview_context,2);
    CGContextAddPath(hwm_preview_context,path); CGContextDrawPath(hwm_preview_context,kCGPathFillStroke);
    CGContextFlush(hwm_preview_context);
    SLSOrderWindow(g_connection,hwm_preview_id,1,0);
    SLSReenableUpdate(g_connection);
    CGPathRelease(path); CFRelease(region);
    return active;
}
/* `animate` glides to a new drop zone. Without it the box is pinned to a zone
 * that is itself moving (edge autoscroll), which must not restart the glide. */
static void hwm_preview_show(CGRect target,CGRect start,bool animate)
{
    if(hwm_preview_visible && !hwm_preview_hiding && CGRectEqualToRect(target,hwm_preview_target)) return;
    double now=hwm_now();
    if(hwm_preview_visible && !hwm_preview_hiding && !animate) {
        // Carry the remaining glide along with the zone instead of restarting it.
        double dx=target.origin.x-hwm_preview_target.origin.x, dy=target.origin.y-hwm_preview_target.origin.y;
        hwm_preview_from=CGRectOffset(hwm_preview_from,dx,dy);
        hwm_preview_from.size.width+=target.size.width-hwm_preview_target.size.width;
        hwm_preview_from.size.height+=target.size.height-hwm_preview_target.size.height;
        hwm_preview_target=target; hwm_wake(); return;
    }
    if(hwm_preview_visible) hwm_preview_render(now);
    hwm_preview_alpha_from=hwm_preview_visible?hwm_preview_alpha:0;
    hwm_preview_alpha_start=now; hwm_preview_hiding=false;
    hwm_preview_from=hwm_preview_visible?hwm_preview_current:start;
    if(!hwm_preview_visible) hwm_preview_current=CGRectNull;
    hwm_preview_target=target; hwm_preview_start=now; hwm_preview_visible=true; hwm_wake();
}
static void hwm_preview_set(CGRect target,CGRect start) { hwm_preview_show(target,start,true); }
static bool hwm_place(struct view *view,uint32_t source,uint32_t target,HStripPlacement placement,bool commit,CGRect *preview)
{
    if(!view) return false;
    CGRect bounds=hwm_bounds(view);
    HStripColumnItem *items; size_t count=hwm_items(view,bounds,&items),from=count,to=count;
    if(!items) return false;
    for(size_t i=0;i<count;i++) { if(items[i].id==source) from=i; if(items[i].id==target) to=i; }
    bool valid=hstrip_columns_place(items,count,from,to,placement);
    if(valid && preview) {
        HStripColumnFrame *frames=calloc(count,sizeof(*frames));
        if(!frames) { free(items); return false; }
        hstrip_columns_layout(items,count,view->window_gap,bounds.size.height,frames);
        for(size_t i=0;i<count;i++) if(frames[i].id==source)
            *preview=CGRectMake(bounds.origin.x+frames[i].x-view->strip_offset,bounds.origin.y+frames[i].y,frames[i].width,frames[i].height);
        free(frames);
    }
    if(valid && commit) {
        struct window_node *slot=window_node_find_first_leaf(view->root);
        for(size_t i=0;i<count;i++) {
            struct window *w=window_manager_find_window(&g_window_manager,(uint32_t)items[i].id);
            if(!w->strip_full_width || w->id==source || w->id==target) w->strip_column=items[i].column;
            w->strip_weight=items[i].weight;
            w->strip_width=items[i].width;
            if(w->id==source || w->id==target) w->strip_full_width=false;
            struct window_node *found=view_find_window_node(view,w->id);
            if(found && slot) { if(found!=slot) window_node_swap_window_list(found,slot); slot=window_node_find_next_leaf(slot); }
        }
        hwm_layout(view,true);
    }
    free(items); return valid;
}
#include "strip_workflow.m"

/* Choose the drop zone under the pointer and show where the window will land.
 * Neighbours stay where they are until the drop: rearranging live windows
 * mid-drag costs Accessibility resizes and moves the very rectangles the
 * pointer is being tested against, which makes the choice oscillate. */
static void hwm_drag_update(struct view *view,struct window *window,CGPoint point)
{
    CGRect bounds=hwm_bounds(view); double offset=hwm_offset(view,hwm_now());
    struct window *target=NULL; HStripPlacement placement=HSTRIP_AFTER_COLUMN;
    CGRect zone=CGRectNull; double nearest=INFINITY;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w==window || hwm_workflow_tab_hidden(w)) continue;
        CGRect f=CGRectMake(bounds.origin.x+w->strip_world_x-offset,bounds.origin.y+w->strip_world_y,w->strip_width,w->strip_height);
        if(f.size.width<=0 || f.size.height<=0) continue;
        double dx=fmax(f.origin.x-point.x,fmax(0,point.x-CGRectGetMaxX(f)));
        double dy=fmax(f.origin.y-point.y,fmax(0,point.y-CGRectGetMaxY(f)));
        double distance=hypot(dx,dy);
        if(distance>=nearest) continue;
        nearest=distance; target=w; zone=f;
        double rx=(point.x-f.origin.x)/f.size.width;
        if(rx<.2) placement=HSTRIP_BEFORE_COLUMN;
        else if(rx>.8) placement=HSTRIP_AFTER_COLUMN;
        else placement=point.y<CGRectGetMidY(f)?HSTRIP_ABOVE:HSTRIP_BELOW;
        if(w->id==hwm_drop_target) {
            // Hysteresis: a zone, once chosen, is kept slightly past its boundary.
            double ry=(point.y-f.origin.y)/f.size.height;
            if((hwm_drop_placement==HSTRIP_BEFORE_COLUMN && rx<.27) ||
               (hwm_drop_placement==HSTRIP_AFTER_COLUMN && rx>.73) ||
               (hwm_drop_placement==HSTRIP_ABOVE && rx>.13 && rx<.87 && ry<.58) ||
               (hwm_drop_placement==HSTRIP_BELOW && rx>.13 && rx<.87 && ry>.42)) placement=hwm_drop_placement;
        }
    }
    if(!target) { hwm_drop_target=0; hwm_preview_hide(); return; }
    bool changed=hwm_drop_target!=target->id || hwm_drop_placement!=placement;
    // Validity depends only on the pair and the placement, so test it once per zone.
    if(changed && !hwm_place(view,window->id,target->id,placement,false,NULL)) { hwm_drop_target=0; hwm_preview_hide(); return; }
    hwm_drop_target=target->id; hwm_drop_placement=placement;
    double gap=view->window_gap; CGRect preview;
    if(placement==HSTRIP_BEFORE_COLUMN) preview=CGRectMake(zone.origin.x-gap*.5-2,bounds.origin.y,4,bounds.size.height);
    else if(placement==HSTRIP_AFTER_COLUMN) preview=CGRectMake(CGRectGetMaxX(zone)+gap*.5-2,bounds.origin.y,4,bounds.size.height);
    else preview=CGRectMake(zone.origin.x,placement==HSTRIP_ABOVE?zone.origin.y:CGRectGetMidY(zone),zone.size.width,zone.size.height*.5);
    preview=CGRectIntegral(preview);
    hwm_preview_show(preview,CGRectInset(preview,preview.size.width>8?preview.size.width*.08:0,preview.size.height*.08),changed);
}
static bool horizontal_drag(CGEventRef event)
{
    struct window *window=g_mouse_state.window;
    struct view *view=window?window_manager_find_managed_window(&g_window_manager,window):NULL;
    if(!hwm_ready || hwm_paused || !view || view->layout!=VIEW_STRIP) return false;
    CGPoint point=CGEventGetLocation(event);
    if(hwm_drag_cancelled) return true;
    hwm_drag_point=point; ++hwm_prof_drag_events;
    if(hwm_edge_window==window->id) {
        if(g_mouse_state.current_action==MOUSE_MODE_RESIZE) {
            double dx=point.x-g_mouse_state.down_location.x,dy=point.y-g_mouse_state.down_location.y;
            window_manager_resize_window_relative_internal(window,hwm_edge_origin,g_mouse_state.direction,dx,dy,false);
        }
        hwm_edge_update(window,view); return true;
    }
    if(g_mouse_state.current_action==MOUSE_MODE_MOVE) {
        hwm_drag_started(window);
        // Pointer events can far outrun the display. The window is moved once
        // per frame from the tick, to the latest position only.
        hwm_drag_move=CGPointMake(g_mouse_state.window_frame.origin.x+point.x-g_mouse_state.down_location.x,
                                  g_mouse_state.window_frame.origin.y+point.y-g_mouse_state.down_location.y);
        hwm_drag_move_pending=true;
    }
    if(!hwm_drag_window && g_mouse_state.current_action==MOUSE_MODE_NONE) {
        CGRect actual=CGRectNull; SLSGetWindowBounds(g_connection,window->id,&actual);
        if(!CGRectIsNull(actual) && hypot(point.x-g_mouse_state.down_location.x,point.y-g_mouse_state.down_location.y)>3 &&
           hypot(actual.origin.x-g_mouse_state.window_frame.origin.x,actual.origin.y-g_mouse_state.window_frame.origin.y)>2) {
            hwm_drag_started(window);
        }
    }
    if(hwm_drag_window==window->id) hwm_wake();
    return true;
}
static bool horizontal_drop(struct window *window, CGPoint point)
{
    struct view *view=window_manager_find_managed_window(&g_window_manager,window);
    if(!hwm_ready || hwm_paused || !view || view->layout!=VIEW_STRIP) return false;
    if(hwm_drag_cancelled) { hwm_drag_cancelled=false; hwm_layout(view,true); return true; }
    if(hwm_edge_finish(window,view)) return true;
    if(hwm_drag_window==window->id) {
        hwm_drag_point=point;
        if(hwm_drag_move_pending) { hwm_drag_move_pending=false; scripting_addition_move_window(window->id,hwm_drag_move.x,hwm_drag_move.y); }
        hwm_drag_update(view,window,point);
        CGRect actual=window->frame,bounds=hwm_bounds(view);
        SLSGetWindowBounds(g_connection,window->id,&actual);
        // Start the settle animation at the actual release position.
        window->strip_world_x=window->strip_from_x=actual.origin.x-bounds.origin.x+view->strip_offset;
        window->strip_world_y=window->strip_from_y=actual.origin.y-bounds.origin.y;
        window->strip_width=window->strip_from_width=actual.size.width;
        window->strip_height=window->strip_from_height=actual.size.height;
        window->strip_last_frame=actual; window->strip_last_offset=view->strip_offset; window->strip_start=hwm_now();
        hwm_drag_window=0;
        scripting_addition_set_shadow(window->id,hwm_drag_shadow);
        scripting_addition_set_layer(window->id,LAYER_BELOW);
        if(!hwm_drop_target || !hwm_place(view,window->id,hwm_drop_target,hwm_drop_placement,true,NULL)) hwm_layout(view,true);
        hwm_drop_target=0; hwm_preview_hide(); hwm_hold_focus();
    }
    return true;
}

static void hwm_drag_autoscroll(struct view *view,double now)
{
    double dt=fmin(.04,fmax(0,now-hwm_drag_tick_time)); hwm_drag_tick_time=now;
    struct window *w=window_manager_find_window(&g_window_manager,hwm_drag_window);
    if(!w || hwm_drag_cancelled) return;
    // Track the live cursor, not the last queued event: the window and the
    // drop zone then follow the pointer however busy the event queue is.
    CGPoint cursor;
    if(SLSGetCurrentCursorLocation(g_connection,&cursor)==kCGErrorSuccess && g_mouse_state.window==w) {
        hwm_drag_point=cursor;
        if(g_mouse_state.current_action==MOUSE_MODE_MOVE) {
            CGPoint to=CGPointMake(round(g_mouse_state.window_frame.origin.x+cursor.x-g_mouse_state.down_location.x),
                                   round(g_mouse_state.window_frame.origin.y+cursor.y-g_mouse_state.down_location.y));
            if(hwm_drag_move_pending || !CGPointEqualToPoint(to,hwm_drag_move)) { hwm_drag_move=to; hwm_drag_move_pending=true; }
        }
    }
    if(hwm_drag_move_pending) { hwm_drag_move_pending=false; scripting_addition_move_window(w->id,hwm_drag_move.x,hwm_drag_move.y); }
    CGRect bounds=hwm_bounds(view); double speed=0;
    if(hwm_drag_point.x<bounds.origin.x+56) speed=-fmin(1,(bounds.origin.x+56-hwm_drag_point.x)/56);
    else if(hwm_drag_point.x>CGRectGetMaxX(bounds)-56) speed=fmin(1,(hwm_drag_point.x-CGRectGetMaxX(bounds)+56)/56);
    // Holding a window against an edge keeps accelerating, so carrying it the
    // length of a long strip takes a moment rather than a slow crawl.
    static double edge_since; static int edge_side;
    int side=speed<0?-1:speed>0?1:0;
    if(side!=edge_side) { edge_side=side; edge_since=now; }
    if(speed) hwm_scroll(view,view->strip_offset+speed*900*(1+fmin(5,(now-edge_since)*2.5))*dt,false);
    hwm_drag_update(view,w,hwm_drag_point);
}
static void hwm_cancel_drag(void)
{
    struct window *w=window_manager_find_window(&g_window_manager,hwm_drag_window);
    if(!w) return;
    hwm_drag_window=0; hwm_drop_target=0; hwm_drag_cancelled=true;
    scripting_addition_set_shadow(w->id,hwm_drag_shadow);
    scripting_addition_set_layer(w->id,LAYER_BELOW);
    hwm_preview_hide(); hwm_undo_restore(); hwm_hold_focus();
}

static uint64_t horizontal_destination(struct window *window, uint64_t sid)
{
    if (!hwm_ready || !hwm_space || !space_is_user(sid) || !space_is_user(hwm_space)) return sid;
    if (sid != hwm_space && !scripting_addition_move_window_to_space(hwm_space,window->id)) return sid;
    return hwm_space;
}
static void horizontal_space_changed(void)
{
    if (!hwm_ready || hwm_paused || !hwm_space) return;
    if (!space_is_user(hwm_space)) hwm_space = space_manager_active_space();
    // Native fullscreen is a temporary OS mode; return to the strip when it exits.
    if (space_is_user(g_space_manager.current_space_id) && g_space_manager.current_space_id != hwm_space)
        space_manager_focus_space(hwm_space);
    hwm_wake();
}

static bool hwm_number(struct token token, double *out)
{
    if (token.length < 1 || token.length > 63) return false;
    char text[64]; memcpy(text,token.text,token.length); text[token.length] = 0;
    char *end = NULL; *out = strtod(text,&end);
    return end && *end == 0 && isfinite(*out);
}
static void horizontal_command(FILE *rsp, char *message)
{
    struct token command = get_token(&message);
    if(command.length>0 && command.length<80) {
        char name[80]; memcpy(name,command.text,command.length); name[command.length]=0;
        if(hwm_named_action(name)) return;
    }
    if(token_equals(command,"config-status")) {
        TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
        NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"path":hwm_config.path,@"motionStrength":@(snapshot.motionStrength),@"effectiveMotionStrength":@(hwm_motion_scale),@"showStripMap":@(snapshot.showStripMap),@"autofocus":hwm_pointer_focus?@"pointer-movement":@"after-scroll",@"shortcutConflicts":snapshot.shortcutConflicts,@"error":hwm_config.lastError ?: @"",@"problems":hwm_config_problems ?: @[],@"hotReload":@(hwm_hot_reload),@"snap":@(hwm_snap),@"border":@(hwm_border_on()),@"inactiveOpacity":@(hwm_inactive_alpha),@"windowDuration":@(hwm_duration)} options:0 error:NULL];
        fwrite(json.bytes,1,json.length,rsp); fputc('\n',rsp); [snapshot release]; return;
    }
    if(token_equals(command,"profile") || token_equals(command,"profile-reset")) {
        fprintf(rsp,"{\"ax_resizes\":%llu,\"ax_resizes_coalesced\":%llu,\"ax_resize_max_ms\":%.3f,\"drag_ms\":%.3f,\"render_ms\":%.3f,\"extras_ms\":%.3f,\"preview_ms\":%.3f,\"feedback_ms\":%.3f,\"tick_while_dragging_ms\":%.3f,\"drag_ticks\":%llu,\"drag_events\":%llu,\"overlay_refreshes\":%llu,\"overlay_refresh_max_ms\":%.3f,\"max_frame_ms\":%.3f}\n",
                (unsigned long long)hwm_ax_resizes_sent,(unsigned long long)hwm_ax_resizes_coalesced,(double)hwm_ax_resize_max_ms,hwm_prof[HWM_PROF_DRAG],hwm_prof[HWM_PROF_RENDER],hwm_prof[HWM_PROF_EXTRAS],hwm_prof[HWM_PROF_PREVIEW],hwm_prof[HWM_PROF_FEEDBACK],hwm_prof[HWM_PROF_TICK_DRAGGING],
                (unsigned long long)hwm_prof_drag_ticks,(unsigned long long)hwm_prof_drag_events,(unsigned long long)hwm_feedback_shows,(double)hwm_feedback_show_max_ms,hwm_max_frame_ms);
        if(token_equals(command,"profile-reset")) { memset(hwm_prof,0,sizeof(hwm_prof)); hwm_prof_drag_ticks=0; hwm_prof_drag_events=0; hwm_feedback_shows=0; hwm_feedback_show_max_ms=0; hwm_ax_resizes_sent=0; hwm_ax_resizes_coalesced=0; hwm_ax_resize_max_ms=0; hwm_max_frame_ms=0; hwm_slow_frames=0; hwm_frames=0; }
        return;
    }
    if(token_equals(command,"pacing") || token_equals(command,"pacing-reset")) {
        fprintf(rsp,"{\"frames\":%llu,\"frames_over_8ms\":%llu,\"max_frame_ms\":%.3f,\"tick_latency_avg_ms\":%.3f,\"tick_latency_max_ms\":%.3f,\"ticks_late_over_4ms\":%llu,\"frames_dropped\":%llu,\"frame_gap_max_ms\":%.3f,\"stalls_over_2ms\":%llu,\"stall_max_ms\":%.3f,\"stall_event\":\"%s\",\"events\":{",
                (unsigned long long)hwm_frames,(unsigned long long)hwm_slow_frames,hwm_max_frame_ms,hwm_event_prof[HORIZONTAL_TICK].count?hwm_tick_latency_total_ms/(double)hwm_event_prof[HORIZONTAL_TICK].count:0,hwm_tick_latency_max_ms,
                (unsigned long long)hwm_tick_late,(unsigned long long)hwm_frames_dropped,hwm_frame_gap_max_ms,(unsigned long long)hwm_stalls,hwm_stall_max_ms,hwm_stall_type>=0?hwm_event_names[hwm_stall_type]:"");
        bool first=true;
        for(int i=0;i<(int)(sizeof(hwm_event_names)/sizeof(*hwm_event_names)) && i<64;i++) if(hwm_event_prof[i].count) {
            fprintf(rsp,"%s\"%s\":{\"count\":%llu,\"avg_ms\":%.3f,\"max_ms\":%.3f}",first?"":",",hwm_event_names[i],(unsigned long long)hwm_event_prof[i].count,hwm_event_prof[i].total_ms/(double)hwm_event_prof[i].count,hwm_event_prof[i].max_ms);
            first=false;
        }
        fprintf(rsp,"}}\n");
        if(token_equals(command,"pacing-reset")) {
            memset(hwm_event_prof,0,sizeof(hwm_event_prof)); hwm_tick_late=0; hwm_frames_dropped=0; hwm_stalls=0; hwm_stall_type=-1;
            hwm_tick_latency_max_ms=0; hwm_tick_latency_total_ms=0; hwm_frame_gap_max_ms=0; hwm_stall_max_ms=0;
            hwm_frames=0; hwm_slow_frames=0; hwm_max_frame_ms=0; hwm_frame_log_count=0; hwm_input_log_count=0;
        }
        return;
    }
    if(token_equals(command,"frame-log")) {
        // The most recent frames and held-swipe samples, oldest first.
        uint64_t frames=hwm_frame_log_count<HWM_FRAME_LOG?hwm_frame_log_count:HWM_FRAME_LOG, inputs=hwm_input_log_count<HWM_FRAME_LOG?hwm_input_log_count:HWM_FRAME_LOG;
        fprintf(rsp,"{\"frames\":[");
        for(uint64_t i=0;i<frames;i++) { uint64_t k=(hwm_frame_log_count-frames+i)%HWM_FRAME_LOG;
            fprintf(rsp,"%s[%.5f,%.2f,%.3f,%.3f]",i?",":"",hwm_frame_log[k].time,hwm_frame_log[k].offset,hwm_frame_log[k].tick_ms,hwm_frame_log[k].latency_ms); }
        fprintf(rsp,"],\"inputs\":[");
        for(uint64_t i=0;i<inputs;i++) { uint64_t k=(hwm_input_log_count-inputs+i)%HWM_FRAME_LOG;
            fprintf(rsp,"%s[%.5f,%.2f]",i?",":"",hwm_input_log[k].time,hwm_input_log[k].offset); }
        fprintf(rsp,"]}\n"); return;
    }
    if(token_equals(command,"overview")) { hwm_action(HWM_OVERVIEW); return; }
    if(token_equals(command,"overview-cancel")) { hwm_action(HWM_OVERVIEW_CANCEL); return; }
    if(token_equals(command,"overview-progress")) {
        double value;
        if(!hwm_number(get_token(&message),&value) || value<0 || value>1) { daemon_fail(rsp,"progress must be between 0 and 1\n"); return; }
        if(!hwm_overview_active) hwm_overview_begin(false);
        hwm_overview_set_progress(value);
        return;
    }
    if (token_equals(command,"close")) { hwm_action(HWM_CLOSE); return; }
    if (token_equals(command,"quit")) { hwm_stop_requested = 1; return; }
    struct view *view = hwm_view();
    if (token_equals(command,"input-status")) {
        CFMachPortRef tap=__atomic_load_n(&g_mouse_state.handle,__ATOMIC_RELAXED);
        fprintf(rsp,"{\"tap_enabled\":%s,\"key_actions\":%llu,\"suspended\":%s,\"overview\":%s,\"overview_renderer\":\"native\",\"overview_windows\":%u,\"overview_frames\":%llu,\"overview_frames_over_8ms\":%llu,\"overview_max_frame_ms\":%.3f,\"overview_queue_max_ms\":%.3f,\"overview_flush_max_ms\":%.3f,\"overview_present_max_ms\":%.3f,\"overview_begin_ms\":%.3f,\"vertical_progress\":%.4f,\"overview_closing\":%s,\"overview_animating\":%s,\"overview_gesture_active\":%s,\"mission_control\":%s}\n",tap&&CGEventTapIsEnabled(tap)?"true":"false",(unsigned long long)hwm_key_actions,hwm_suspended?"true":"false",hwm_overview_active?"true":"false",(unsigned)hwm_overview_window_count,(unsigned long long)hwm_overview_frames,(unsigned long long)hwm_overview_slow_frames,hwm_overview_max_frame_ms,hwm_overview_queue_max_ms,hwm_overview_flush_max_ms,hwm_overview_present_max_ms,hwm_overview_begin_ms,hwm_vertical_last_progress,hwm_overview_closing?"true":"false",hwm_overview_animating?"true":"false",hwm_overview_gesture_active?"true":"false",mission_control_is_active()?"true":"false"); return;
    }
    if (token_equals(command,"status")) {
        fprintf(rsp,"{\"version\":\"0.2.0\",\"ready\":%s,\"paused\":%s,\"backend\":%s,\"space\":%llu,\"offset\":%.3f,\"autofocus\":%s,\"frames\":%llu,\"frames_over_8ms\":%llu,\"max_frame_ms\":%.3f,\"move_failures\":%llu,\"resize_operations\":%llu,\"windows\":[",hwm_ready?"true":"false",hwm_paused?"true":"false",hwm_backend_ok?"true":"false",(unsigned long long)hwm_space,view?view->strip_offset:0,g_window_manager.ffm_mode==FFM_AUTOFOCUS?"true":"false",(unsigned long long)hwm_frames,(unsigned long long)hwm_slow_frames,hwm_max_frame_ms,(unsigned long long)hwm_move_failures,(unsigned long long)hwm_resize_operations);
        bool comma = false;
        if (view) for (struct window_node *n = window_node_find_first_leaf(view->root); n; n = window_node_find_next_leaf(n)) {
            for (int i=0;i<n->window_count;++i) {
                struct window *w = window_manager_find_window(&g_window_manager,n->window_list[i]);
                if (!w) continue;
                fprintf(rsp,"%s{\"id\":%u,\"x\":%.2f,\"width\":%.2f,\"column\":%llu,\"y\":%.2f,\"height\":%.2f,\"full\":%s}",comma?",":"",w->id,w->strip_world_x,w->strip_width,(unsigned long long)w->strip_column,w->strip_world_y,w->strip_height,w->strip_full_width?"true":"false"); comma=true;
            }
        }
        fprintf(rsp,"]}\n"); return;
    }
    if(token_equals(command,"preview-off")) { hwm_preview_hide(); return; }
    if(token_equals(command,"place") || token_equals(command,"preview")) {
        double source,target; struct token position;
        if(!hwm_number(get_token(&message),&source) || !hwm_number(get_token(&message),&target) || source<1 || source>UINT32_MAX || target<1 || target>UINT32_MAX) { daemon_fail(rsp,"expected source and target window IDs\n"); return; }
        position=get_token(&message); int placement=-1;
        if(token_equals(position,"left")) placement=HSTRIP_BEFORE_COLUMN;
        if(token_equals(position,"right")) placement=HSTRIP_AFTER_COLUMN;
        if(token_equals(position,"above")) placement=HSTRIP_ABOVE;
        if(token_equals(position,"below")) placement=HSTRIP_BELOW;
        bool commit=token_equals(command,"place"); CGRect preview=CGRectNull;
        if(commit) hwm_undo_capture();
        if(placement<0 || !hwm_place(view,(uint32_t)source,(uint32_t)target,placement,commit,commit?NULL:&preview)) daemon_fail(rsp,"invalid placement\n");
        else if(!commit) {
            CGRect actual=CGRectNull; SLSGetWindowBounds(g_connection,(uint32_t)source,&actual);
            hwm_preview_set(preview,actual);
        }
        return;
    }
    if (token_equals(command,"scroll") || token_equals(command,"width")) {
        double value;
        if (!hwm_number(get_token(&message),&value)) { daemon_fail(rsp,"expected a finite number\n"); return; }
        if (token_equals(command,"scroll")) { hwm_scroll(view,value,true); hwm_focus_follow_to(view,view->strip_target_offset); }
        else {
            struct window *w = window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
            if (!w || !hwm_focused_node(view)) { daemon_fail(rsp,"focus a tiled window first\n"); return; }
            if (value<240 || value>hwm_bounds(view).size.width) { daemon_fail(rsp,"width must be between 240 and the viewport width\n"); return; }
            hwm_undo_capture(); hwm_column_width(view,w,value); hwm_layout(view,true);
        }
        return;
    }
    char *names[] = {"left","right","move-left","move-right","float","full","center","home","pause","reflow"};
    int actions[] = {HWM_LEFT,HWM_RIGHT,HWM_MOVE_LEFT,HWM_MOVE_RIGHT,HWM_FLOAT,HWM_FULL,HWM_CENTER,HWM_HOME,HWM_PAUSE,HWM_REFLOW};
    for (int i=0;i<10;++i) if (token_equals(command,names[i])) { hwm_action(actions[i]); return; }
    daemon_fail(rsp,"strip commands: status, config-status, left, right, move-left, move-right, move-first, move-last, float, full, center, home, scroll <offset>, width <points>, overview, commands, reload-config, pause, reflow, quit\n");
}

/* One list feeds both the menu and the command palette. */
static NSArray *hwm_command_sections(void)
{
    return @[
      @[@"Navigate",@[@[@"overview",@"Window overview"],@[@"left",@"Focus left"],@[@"right",@"Focus right"],@[@"up",@"Focus row / tab above"],@[@"down",@"Focus row / tab below"],
                      @[@"previous",@"Return to previous window"],@[@"center",@"Center window"],@[@"home",@"Return to left wall"]]],
      @[@"Arrange",@[@[@"move-left",@"Swap with left column"],@[@"move-right",@"Swap with right column"],@[@"move-first",@"Move to start of strip"],@[@"move-last",@"Move to end of strip"],
                     @[@"preset-width",@"Cycle column width"],@[@"fit-two",@"Fit this column and next"],@[@"full",@"Fill screen / restore"],
                     @[@"consume",@"Pull next window into stack"],@[@"expel",@"Push window out of stack"],@[@"tabs",@"Stack / tabs"],@[@"undo",@"Undo arrangement"]]],
      @[@"Window",@[@[@"float",@"Float / tile"],@[@"utility-mark",@"Mark / unmark utility window"],@[@"utility",@"Summon / dismiss utility"],@[@"close",@"Close window"],
                    @[@"terminal",@"New terminal"],@[@"browser",@"Open browser"]]],
      @[@"This app",@[@[@"remember-width",@"Remember current width"],@[@"remember-floating",@"Toggle open floating"],@[@"remember-beside",@"Toggle open beside current"]]],
      @[@"Tana",@[@[@"reload-config",@"Reload config file"],@[@"pause",@"Pause / resume"],@[@"reflow",@"Reflow windows"]]]];
}
static NSArray *hwm_palette_commands(void)
{
    NSMutableArray *commands=[NSMutableArray array];
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    for(NSArray *section in hwm_command_sections()) for(NSArray *entry in section[1])
        [commands addObject:@[entry[0],[NSString stringWithFormat:@"%@: %@",section[0],entry[1]],TanaBindingDescription(snapshot.shortcuts[entry[0]])]];
    [commands addObject:@[@"quit",@"Tana: Quit and restore windows",@""]];
    [snapshot release];
    return commands;
}
/* A menu key equivalent for a binding, or nil when AppKit cannot display it. */
static NSString *hwm_key_equivalent(TanaShortcutBinding *binding)
{
    static NSDictionary *special;
    if(!special) special=[@{@"left":[NSString stringWithFormat:@"%C",(unichar)NSLeftArrowFunctionKey],@"right":[NSString stringWithFormat:@"%C",(unichar)NSRightArrowFunctionKey],
        @"up":[NSString stringWithFormat:@"%C",(unichar)NSUpArrowFunctionKey],@"down":[NSString stringWithFormat:@"%C",(unichar)NSDownArrowFunctionKey],
        @"return":@"\r",@"space":@" ",@"tab":@"\t",@"escape":@"\e",@"delete":@"\b"} retain];
    for(NSString *candidate in [[tana_key_codes() allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if([tana_key_codes()[candidate] unsignedShortValue]!=binding.keyCode || [candidate isEqual:@"enter"] || [candidate isEqual:@"esc"]) continue;
        return special[candidate] ?: candidate;
    }
    return nil;
}
@interface HorizontalMenu : NSObject
@property(nonatomic, retain) NSStatusItem *item;
- (void)named:(NSMenuItem *)sender;
@end
@implementation HorizontalMenu
- (void)named:(NSMenuItem *)sender { event_loop_post(&g_event_loop,HORIZONTAL_INPUT,strdup([sender.representedObject UTF8String]),HWM_NAMED_ACTION); }
@end
static HorizontalMenu *hwm_menu;
static void hwm_menu_refresh_bindings(void)
{
    if(!hwm_menu) return;
    TanaConfigSnapshot *snapshot=[hwm_config copySnapshot];
    for(NSMenuItem *item in hwm_menu.item.menu.itemArray) {
        if(![item.representedObject isKindOfClass:[NSString class]]) continue;
        TanaShortcutBinding *binding=snapshot.shortcuts[item.representedObject];
        NSString *key=binding ? hwm_key_equivalent(binding) : nil;
        // Real key equivalents: AppKit right-aligns them like any other menu.
        item.keyEquivalent=key ?: @"";
        item.keyEquivalentModifierMask=key ? (binding.modifiers&(NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl|NSEventModifierFlagShift)) : 0;
    }
    [snapshot release];
}
static void hwm_menu_begin(void)
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    hwm_menu = [HorizontalMenu new];
    hwm_menu.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *symbol=[NSImage imageWithSystemSymbolName:@"rectangle.split.3x1" accessibilityDescription:@"Tana"];
    if(symbol) { symbol.template=YES; hwm_menu.item.button.image=symbol; } else hwm_menu.item.button.title = @"↔";
    hwm_menu.item.button.toolTip = @"Tana — one continuous window strip";
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Tana"] autorelease];
    NSMenuItem *palette=[[[NSMenuItem alloc] initWithTitle:@"Command Palette…" action:@selector(named:) keyEquivalent:@""] autorelease];
    palette.target=hwm_menu; palette.representedObject=@"commands"; [menu addItem:palette];
    for(NSArray *section in hwm_command_sections()) {
        [menu addItem:[NSMenuItem separatorItem]];
        if(@available(macOS 14.0,*)) [menu addItem:[NSMenuItem sectionHeaderWithTitle:section[0]]];
        for(NSArray *entry in section[1]) {
            NSMenuItem *item=[[[NSMenuItem alloc] initWithTitle:entry[1] action:@selector(named:) keyEquivalent:@""] autorelease];
            item.target=hwm_menu; item.representedObject=entry[0]; [menu addItem:item];
        }
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit=[[[NSMenuItem alloc] initWithTitle:@"Quit Tana" action:@selector(named:) keyEquivalent:@""] autorelease];
    quit.target=hwm_menu; quit.representedObject=@"quit"; [menu addItem:quit];
    hwm_menu.item.menu = menu;
    hwm_menu_refresh_bindings();
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.apple.screenIsLocked" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        (void)n; hwm_suspended=true;
        [[HorizontalWindowOverview sharedOverview] dismissImmediately];
        event_loop_post(&g_event_loop,HORIZONTAL_OVERVIEW_DONE,NULL,0);
    }];
    [[NSWorkspace sharedWorkspace].notificationCenter addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        (void)n; event_loop_post(&g_event_loop,HORIZONTAL_RESUME,NULL,0);
    }];
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        (void)n;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.4*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ event_loop_post(&g_event_loop,HORIZONTAL_RESUME,NULL,0); });
    }];
}

/* Bring every window's opacity in line with the dim setting, or (restore) hand
 * back full opacity to those Tana changed. Untouched windows are left alone. */
static void hwm_alpha_sync(bool restore)
{
    table_for(struct window *w,g_window_manager.window, {
        if(!w->is_root || w->strip_pop || w->strip_close_pending || !window_manager_is_window_eligible(w) || !window_is_standard(w)) continue;
        float current=w->strip_alpha>0 ? w->strip_alpha : 1;
        float target=restore ? 1 : hwm_window_alpha(w);
        if(fabsf(current-target)<.001f) continue;
        scripting_addition_set_opacity(w->id,target,.16f);
        w->strip_alpha=target;
    })
}

static NSString *hwm_state_path(void)
{
    NSString *base=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *current=[base stringByAppendingPathComponent:@"Tana"];
    NSString *legacy=[base stringByAppendingPathComponent:@"HorizontalWM"];
    NSFileManager *files=[NSFileManager defaultManager];
    NSString *directory=![files fileExistsAtPath:[current stringByAppendingPathComponent:@"layout.json"]] && [files fileExistsAtPath:[legacy stringByAppendingPathComponent:@"layout.json"]] ? legacy : current;
    return [directory stringByAppendingPathComponent:@"layout.json"];
}
static long long hwm_boot_time(void)
{
    struct timeval boot = {0}; size_t length = sizeof(boot);
    sysctlbyname("kern.boottime",&boot,&length,NULL,0);
    return boot.tv_sec;
}
static void hwm_save_state_now(bool wait)
{
    struct view *view = hwm_view(); if (!view || hwm_resume_load_state) return;
    NSMutableArray *order = [NSMutableArray array];
    for (struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n))
        for (int i=0;i<n->window_count;++i) [order addObject:@(n->window_list[i])];
    NSMutableArray *windows = [NSMutableArray array];
    table_for (struct window *w,g_window_manager.window, {
        if (!window_manager_is_window_eligible(w) || !window_is_standard(w)) continue;
        [windows addObject:(@{@"id":@(w->id),@"pid":@(w->application->pid),@"width":@(w->strip_width),@"restore_width":@(w->strip_saved_width),@"full":@(w->strip_full_width),@"floating":@(window_check_flag(w,WINDOW_FLOAT)),@"column":@(w->strip_column),@"weight":@(w->strip_weight)})];
    })
    NSDictionary *state=@{@"version":@1,@"boot":@(hwm_boot_time()),@"offset":@(view->strip_target_offset),@"order":order,@"windows":windows,@"workflow":hwm_workflow_save()};
    NSString *path=hwm_state_path();
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
    if(!data) { warn("Tana: layout could not be saved.\n"); return; }
    hwm_state_pending=false;
    // The snapshot is taken here; the disk is touched on its own queue, in
    // order, so a save after every settled animation never costs a frame.
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("tana.state",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0)); });
    void (^write)(void)=^{
        NSError *error=nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
        if ([data writeToFile:path options:NSDataWritingAtomic error:&error])
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
        else warn("Tana: layout could not be saved: %s\n",error.localizedDescription.UTF8String);
    };
    if(wait) dispatch_sync(queue,write); else dispatch_async(queue,write);
}
static void hwm_save_state(void) { hwm_save_state_now(false); }
static void hwm_load_state(void)
{
    NSData *data=[NSData dataWithContentsOfFile:hwm_state_path()];
    if (!data) return;
    id state=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![state isKindOfClass:[NSDictionary class]] || ![state[@"version"] isKindOfClass:[NSNumber class]] || ![state[@"boot"] isKindOfClass:[NSNumber class]] || [state[@"version"] intValue]!=1 || [state[@"boot"] longLongValue]!=hwm_boot_time()) return;
    if (![state[@"windows"] isKindOfClass:[NSArray class]] || ![state[@"order"] isKindOfClass:[NSArray class]]) return;
    NSMutableSet *matched=[NSMutableSet set];
    for (id entry in state[@"windows"]) {
        if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"id"] isKindOfClass:[NSNumber class]] || ![entry[@"pid"] isKindOfClass:[NSNumber class]]) continue;
        struct window *w=window_manager_find_window(&g_window_manager,[entry[@"id"] unsignedIntValue]);
        if (!w || w->application->pid != [entry[@"pid"] intValue] || !window_is_standard(w)) continue;
        double width=[entry[@"width"] isKindOfClass:[NSNumber class]] ? [entry[@"width"] doubleValue] : 0;
        if (isfinite(width) && width>=240 && width<=20000) w->strip_width=width;
        double saved=[entry[@"restore_width"] isKindOfClass:[NSNumber class]] ? [entry[@"restore_width"] doubleValue] : 0;
        if([entry[@"column"] isKindOfClass:[NSNumber class]]) w->strip_column=[entry[@"column"] unsignedLongLongValue];
        double weight=[entry[@"weight"] isKindOfClass:[NSNumber class]]?[entry[@"weight"] doubleValue]:1;
        w->strip_weight=isfinite(weight)&&weight>0?weight:1;
        w->strip_saved_width=isfinite(saved) && saved>=240 && saved<=20000 ? saved : 800;
        w->strip_full_width=[entry[@"full"] isKindOfClass:[NSNumber class]] && [entry[@"full"] boolValue];
        if ([entry[@"floating"] isKindOfClass:[NSNumber class]])
            window_manager_make_window_floating(&g_space_manager,&g_window_manager,w,[entry[@"floating"] boolValue],true);
        [matched addObject:entry[@"id"]];
    }
    struct view *view=hwm_view();
    struct window_node *slot=window_node_find_first_leaf(view->root);
    for (id identifier in state[@"order"]) {
        if (![identifier isKindOfClass:[NSNumber class]] || ![matched containsObject:identifier] || !slot) continue;
        struct window_node *found=view_find_window_node(view,[identifier unsignedIntValue]);
        if (!found) continue;
        // Bubble instead of swap to preserve the order of newly created windows.
        while (found != slot) {
            struct window_node *previous=window_node_find_prev_leaf(found);
            if (!previous) break;
            window_node_swap_window_list(previous,found); found=previous;
        }
        [matched removeObject:identifier];
        slot=window_node_find_next_leaf(slot);
    }
    hwm_workflow_load(state[@"workflow"]);
    if ([state[@"offset"] isKindOfClass:[NSNumber class]]) hwm_scroll(view,[state[@"offset"] doubleValue],false);
}
static void hwm_signal_stop(int signal_number) { (void)signal_number; hwm_stop_requested = 1; }
static void hwm_remember(struct window *window)
{
    if (window->strip_remembered) return;
    window->strip_remembered = true;
    window->strip_original_frame = window->frame;
    window->strip_original_space = window_space(window->id);
    int raw_layer = window_sub_level(window->id);
    window->strip_original_layer = LAYER_NORMAL;
    for (int key=0;key<kCGNumberOfWindowLevelKeys;++key) {
        if (CGWindowLevelForKey((CGWindowLevelKey)key)==raw_layer) {
            window->strip_original_layer=key; break;
        }
    }
}
static void horizontal_window_added(struct window *window)
{
    if (!window->is_root || !window_manager_is_window_eligible(window)) return;
    hwm_remember(window);
    if (!hwm_ready) return;
    horizontal_destination(window,window_space(window->id));
    hwm_apply_app_rule(window);
    if (window_check_flag(window,WINDOW_FLOAT)) scripting_addition_set_layer(window->id,LAYER_ABOVE);
}
static void hwm_shutdown(void)
{
    if (!hwm_ready) return;
    horizontal_overview_done();
    hwm_preview_hide_immediately();
    hwm_feedback_hide();
    hwm_cancel_closing();
    hwm_cancel_pops();
    hwm_alpha_sync(true);
    hwm_save_state_now(true); // On disk before the process goes away.
    hwm_ready = false;
    __atomic_store_n(&hwm_active,false,__ATOMIC_RELEASE);
    if(hwm_display_link) CVDisplayLinkStop(hwm_display_link);
    if(hwm_fallback_timer) dispatch_source_cancel(hwm_fallback_timer);
    // Restore geometry before releasing the lock. No window remains stranded
    // offscreen when the app quits normally or receives SIGTERM/SIGINT.
    table_for (struct window *window, g_window_manager.window, {
        if (!window->strip_remembered || !window_manager_is_window_eligible(window) || window_check_flag(window,WINDOW_FULLSCREEN) || !space_is_user(window->strip_original_space)) continue;
        CGRect f = window->strip_original_frame;
        if (space_is_user(window->strip_original_space))
            scripting_addition_move_window_to_space(window->strip_original_space,window->id);
        window_manager_set_window_frame(window,f.origin.x,f.origin.y,f.size.width,f.size.height);
        scripting_addition_move_window(window->id,f.origin.x,f.origin.y);
        // The helper accepts CGWindowLevelKey, not a raw WindowServer sublevel.
        scripting_addition_set_layer(window->id,window->strip_original_layer);
    })
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
static void horizontal_begin(void)
{
    hwm_space = space_manager_active_space();
    if (!space_is_user(hwm_space)) error("Tana: start from a normal desktop, not native fullscreen.\n");
    char helper_version[256] = {0}; uint32_t helper_attributes = 0;
    // Direct WindowServer placement does not depend on Dock's optional
    // set-front-window signature. AX supplies window activation separately.
    hwm_backend_ok = scripting_addition_request_handshake(helper_version,sizeof(helper_version),&helper_attributes);
    if (!hwm_backend_ok) error("Tana: yabai scripting addition is unavailable; no windows were moved. Load the existing helper before starting.\n");
    hwm_config_begin();
    hwm_ready = true;
    signal(SIGTERM, hwm_signal_stop);
    signal(SIGINT, hwm_signal_stop);
    // New windows always join this one strip, independent of their app's saved Space.
    table_for (struct window *window, g_window_manager.window, {
        hwm_remember(window);
        if (window->is_root && window_manager_is_window_eligible(window) && space_is_user(window_space(window->id))) {
            if (window_space(window->id) != hwm_space) window_manager_send_window_to_space(&g_space_manager,&g_window_manager,window,hwm_space,false);
            if (window_check_flag(window,WINDOW_FLOAT)) scripting_addition_set_layer(window->id,LAYER_ABOVE);
            uint8_t ordered=0; SLSWindowIsOrderedIn(g_connection,window->id,&ordered);
            if (ordered && window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager,window)) {
                struct view *view = space_manager_tile_window_on_space(&g_space_manager,window,hwm_space);
                window_manager_add_managed_window(&g_window_manager,window,view);
            }
        }
    })
    update_window_notifications();
    table_for(struct window *w,g_window_manager.window,{ horizontal_ordered(w->id); })
    window_manager_set_focus_follows_mouse(&g_window_manager,FFM_AUTOFOCUS);
    CFDictionaryRef session=CGSessionCopyCurrentDictionary();
    if(session) { hwm_suspended=[((__bridge NSDictionary *)session)[@"CGSSessionScreenIsLocked"] boolValue]; CFRelease(session); }
    hwm_start_clock();
    int observed=0;
    table_for(struct application *a,g_window_manager.application,{ (void)a; ++observed; })
    hwm_resume_load_state=observed==0;
    if(!hwm_resume_load_state) hwm_load_state();
    hwm_layout(hwm_view(),true);
    hwm_external_borders_refresh();
    hwm_alpha_focus=hwm_feedback_focus_id=g_window_manager.focused_window_id;
    hwm_alpha_sync(false);
    dispatch_async(dispatch_get_main_queue(), ^{
        // An agent with no windows of its own is a candidate for App Nap,
        // which throttles exactly the timers and threads that draw frames.
        static id activity;
        if(!activity) activity=[[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Window management must respond to input without delay"] retain];
        hwm_menu_begin();
        [[HorizontalWindowOverview sharedOverview] prepareForScreenFrame:CGDisplayBounds(CGMainDisplayID())];
    });
}

static void horizontal_resume(void)
{
    if(!hwm_ready) return;
    hwm_cancel_closing();
    hwm_suspended=false;
    hwm_start_clock();
    table_for(struct process *process,g_process_manager.process, {
        if (!window_manager_find_application(&g_window_manager,process->pid) && workspace_application_is_observable(process))
            EVENT_HANDLER_APPLICATION_LAUNCHED(process,0);
    })
    space_manager_refresh_application_windows(&g_space_manager);
    table_for(struct window *w,g_window_manager.window, {
        if(w->is_root && window_manager_is_window_eligible(w) && space_is_user(window_space(w->id))) {
            horizontal_destination(w,window_space(w->id));
            if(window_manager_should_manage_window(w) && !window_manager_find_managed_window(&g_window_manager,w)) {
                struct view *view=space_manager_tile_window_on_space(&g_space_manager,w,hwm_space);
                window_manager_add_managed_window(&g_window_manager,w,view);
            }
            w->strip_last_frame=CGRectNull;
        }
    })
    if(hwm_resume_load_state) { hwm_resume_load_state=false; hwm_load_state(); }
    hwm_layout(hwm_view(),true);
    struct window *focus=window_manager_focused_window(&g_window_manager);
    if(focus) horizontal_focused(focus,window_manager_find_managed_window(&g_window_manager,focus));
}

static void hwm_start_clock(void)
{
    if(!hwm_fallback_timer) {
        hwm_fallback_timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
        dispatch_source_set_timer(hwm_fallback_timer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/10,10*NSEC_PER_MSEC);
        __block double last_reconcile=0; __block bool fast=false;
        dispatch_source_set_event_handler(hwm_fallback_timer,^{
            double now=hwm_now(); bool expected=false;
            if(now-last_reconcile>.095 && __atomic_compare_exchange_n(&hwm_reconcile_pending,&expected,true,false,__ATOMIC_ACQ_REL,__ATOMIC_RELAXED)) {
                last_reconcile=now; event_loop_post(&g_event_loop,HORIZONTAL_RECONCILE,NULL,0);
            }
            // With the display clock running this timer only paces the
            // housekeeping sweep. It becomes the frame clock, at frame rate,
            // only for as long as the display clock is not running.
            bool stand_in=hwm_stop_requested || !hwm_display_link || !CVDisplayLinkIsRunning(hwm_display_link);
            if(stand_in!=fast) {
                fast=stand_in;
                dispatch_source_set_timer(hwm_fallback_timer,dispatch_time(DISPATCH_TIME_NOW,0),fast?NSEC_PER_SEC/60:NSEC_PER_SEC/10,(fast?1:10)*NSEC_PER_MSEC);
            }
            if(stand_in) hwm_display_tick(NULL,NULL,NULL,0,NULL,NULL);
        });
        dispatch_resume(hwm_fallback_timer);
    }
    if(hwm_display_link && CVDisplayLinkIsRunning(hwm_display_link)) return;
    if(hwm_display_link) { CVDisplayLinkRelease(hwm_display_link); hwm_display_link=NULL; }
    CVReturn result=CVDisplayLinkCreateWithActiveCGDisplays(&hwm_display_link);
    if(result==kCVReturnSuccess) result=CVDisplayLinkSetOutputCallback(hwm_display_link,hwm_display_tick,NULL);
    if(result==kCVReturnSuccess) result=CVDisplayLinkStart(hwm_display_link);
    if(result!=kCVReturnSuccess) warn("Tana: display clock unavailable; waiting for display wake.\n");
}

static void horizontal_ordered(uint32_t wid)
{
    if(!hwm_ready || hwm_suspended) return;
    struct window *w=window_manager_find_window(&g_window_manager,wid);
    if(!w || window_check_flag(w,WINDOW_FULLSCREEN)) return;
    uint8_t ordered=0;
    if(SLSWindowIsOrderedIn(g_connection,wid,&ordered)!=kCGErrorSuccess) return;
    struct view *view=window_manager_find_managed_window(&g_window_manager,w);
    if(!ordered && view && view->layout==VIEW_STRIP) {
        horizontal_removing(w,false);
        w->strip_ordered_out=true;
        space_manager_untile_window(view,w);
        window_manager_remove_managed_window(&g_window_manager,wid);
    } else if(ordered && w->strip_ordered_out) {
        w->strip_ordered_out=false;
        if(window_manager_should_manage_window(w) && !view) {
            view=space_manager_tile_window_on_space(&g_space_manager,w,hwm_space);
            window_manager_add_managed_window(&g_window_manager,w,view);
        }
    }
}

static void horizontal_reconcile(void)
{
    __atomic_store_n(&hwm_reconcile_pending,false,__ATOMIC_RELEASE);
    if(hwm_ready && !hwm_suspended) hwm_config_poll();
    if(!hwm_ready || hwm_suspended || hwm_paused || hwm_overview_active || mission_control_is_active()) return;
    double now=hwm_now();
    // This sweep asks WindowServer about every window. It waits while frames
    // are being drawn: the round trips come out of the same thread's time, and
    // WindowServer reports ordering changes as they happen in any case.
    if(now-hwm_drawn_time<.2) return;
    // Promptly for a second after anything moved, which is when a correction
    // can be needed; twice a second while the desktop is at rest.
    static double last_sweep;
    if(now-hwm_drawn_time>1 && now-last_sweep<.5) return;
    last_sweep=now;
    // Retained Cocoa windows can close without an AX destruction notification.
    // WindowServer ordering catches that case without polling Accessibility.
    table_for(struct window *w,g_window_manager.window, {
        if(w->strip_close_ghost && !w->strip_close_pending && now-w->strip_ghost_time>1.0) {
            // The application kept the window (a save prompt, say): give it its place back.
            w->strip_close_ghost=false;
            struct view *home=window_manager_find_managed_window(&g_window_manager,w);
            if(home && home->layout==VIEW_STRIP) hwm_layout(home,true);
        }
        if(w->strip_initialized || w->strip_ordered_out) horizontal_ordered(w->id);
        struct view *view=window_manager_find_managed_window(&g_window_manager,w);
        if(view && view->layout==VIEW_STRIP && w->strip_initialized &&
           !w->strip_ordered_out && !hwm_workflow_tab_hidden(w) && w->id!=hwm_drag_window && g_mouse_state.window!=w &&
           !hwm_view_in_motion(view,now) && !w->strip_size_pending &&
           now-w->strip_start>hwm_duration+.1 && !CGRectIsNull(w->strip_last_frame)) {
            // AppKit can constrain an off-screen window after our final move.
            // A delayed notification may have been suppressed during animation;
            // compare settled WindowServer positions instead of trusting the cache.
            CGRect actual=CGRectNull;
            if(SLSGetWindowBounds(g_connection,w->id,&actual)==kCGErrorSuccess &&
               (fabs(actual.origin.x-w->strip_last_frame.origin.x)>.5 ||
                fabs(actual.origin.y-w->strip_last_frame.origin.y)>.5)) {
                // Keep the size cache: correcting a position must not trigger AX
                // resizing, which can cause another on-screen constraint.
                w->strip_last_frame.origin=actual.origin;
                hwm_wake();
            }
        }
    })
}

/* Tana named the window when it asked for an activation, so the report that
 * the application came forward need not ask the application which window it
 * focused. That question is a blocking Accessibility round trip to an
 * application busy activating, on the thread drawing the settle animation.
 * The application's own focus notification still follows and corrects this
 * should it have chosen otherwise. */
static uint32_t hwm_requested_focus; static double hwm_requested_focus_time;
static uint32_t horizontal_expected_focus(struct application *application)
{
    if(!hwm_ready || !hwm_requested_focus || hwm_now()-hwm_requested_focus_time>.5) return 0;
    struct window *window=window_manager_find_window(&g_window_manager,hwm_requested_focus);
    return window && window->application==application && !window_check_flag(window,WINDOW_MINIMIZE) ? window->id : 0;
}

static void horizontal_focus_requested(uint32_t wid)
{
    hwm_requested_focus=wid; hwm_requested_focus_time=hwm_now();
    struct window *window=window_manager_find_window(&g_window_manager,wid);
    if(window) horizontal_focused(window,window_manager_find_managed_window(&g_window_manager,window));
}

static void horizontal_focus_transition(struct window *previous,struct window *next)
{
    if(!hwm_ready || !previous || previous==next) return;
    hwm_feedback_focus(previous,next);
    if(next) { hwm_alpha_focus=next->id; if(hwm_inactive_alpha<1 && !hwm_paused) hwm_alpha_sync(false); }
    hwm_previous_focus=previous->id; hwm_previous_focus_time=hwm_now();
    struct view *view=hwm_view();
    hwm_previous_focus_offset=view?hwm_offset(view,hwm_now()):0;
    horizontal_ordered(previous->id);
}

#include "strip_config_runtime.m"
