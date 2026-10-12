/* Tana. MIT license; see LICENSE. */
#include <math.h>
#include "strip_geometry.h"
#include "strip_columns.h"
#include "window_overview.m"

extern struct window_manager g_window_manager;
extern struct space_manager g_space_manager;
extern struct mouse_state g_mouse_state;
extern struct event_loop g_event_loop;
extern volatile bool __pending_gesture;
extern volatile uint64_t __last_gesture_time;

static _Atomic bool hwm_ready, hwm_paused;
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
static double hwm_duration = 0.24;
static uint64_t hwm_frames, hwm_slow_frames, hwm_move_failures, hwm_resize_operations;
static _Atomic uint64_t hwm_key_actions;
static double hwm_max_frame_ms;
static double hwm_last_input;
static uint32_t hwm_resize_window;
static uint32_t hwm_drag_window, hwm_drop_target;
static HStripPlacement hwm_drop_placement;
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
static void hwm_load_state(void);
static bool hwm_state_pending;
static bool hwm_resume_load_state;

enum hwm_action { HWM_EVENT, HWM_LEFT, HWM_RIGHT, HWM_MOVE_LEFT, HWM_MOVE_RIGHT,
                  HWM_FLOAT, HWM_FULL, HWM_CENTER, HWM_HOME, HWM_PAUSE, HWM_REFLOW, HWM_QUIT, HWM_CLOSE, HWM_TERMINAL, HWM_BROWSER,
                  HWM_OVERVIEW, HWM_OVERVIEW_GESTURE, HWM_OVERVIEW_CANCEL, HWM_OVERVIEW_POINTER };

static double hwm_now(void) { return (double) read_os_timer() / (double) read_os_freq(); }
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
static CGRect hwm_bounds(struct view *view)
{
    CGRect frame = display_bounds_constrained(space_display_id(view->sid), false);
    frame.origin.x += view->left_padding;
    frame.origin.y += view->top_padding;
    frame.size.width = fmax(100, frame.size.width-view->left_padding-view->right_padding);
    frame.size.height = fmax(100, frame.size.height-view->top_padding-view->bottom_padding);
    return frame;
}
static double hwm_offset(struct view *view, double now)
{
    if (!view->strip_scrolling) return view->strip_offset;
    double t = (now - view->strip_scroll_start) / hwm_duration;
    view->strip_offset = view->strip_from_offset + (view->strip_target_offset-view->strip_from_offset)*horizontal_ease(t);
    if (t >= 1) view->strip_scrolling = false;
    return view->strip_offset;
}
static void hwm_scroll(struct view *view, double target, bool animate)
{
    if (!view || !isfinite(target)) return;
    hwm_state_pending = true;
    double now = hwm_now();
    view->strip_from_offset = hwm_offset(view, now);
    view->strip_target_offset = hstrip_viewport_offset(target);
    view->strip_scroll_start = now;
    view->strip_scrolling = animate && fabs(view->strip_target_offset-view->strip_from_offset) > .25;
    if (!view->strip_scrolling) view->strip_offset = view->strip_target_offset;
    hwm_wake();
}

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

#include "strip_renderer.m"
#include "window_transitions.m"
static void horizontal_tick(void)
{
    __atomic_store_n(&hwm_tick_pending, false, __ATOMIC_RELEASE);
    if (hwm_stop_requested) { hwm_shutdown(); return; }
    if (!hwm_ready || hwm_paused || hwm_suspended || mission_control_is_active()) return;
    if(hwm_overview_active) { hwm_overview_tick(); return; }
    double start = hwm_now();
    struct view *view = hwm_view();
    if (!view || !space_is_visible(view->sid)) return;
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
    bool active = hwm_render(view, start);
    active |= hwm_render_floating(start);
    active |= hwm_render_closing(start);
    active |= hwm_preview_render(start);
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
    if (!active && hwm_focus_after_scroll && hwm_backend_ok) {
        hwm_focus_after_scroll = false;
        CGPoint cursor; SLSGetCurrentCursorLocation(g_connection,&cursor);
        struct window *target = window_manager_find_window_at_point(&g_window_manager,cursor);
        if (target && window_manager_is_window_eligible(target)) {
            hwm_last_input = start; // A partially visible hover must not snap the viewport.
            window_manager_focus_window_without_raise(&target->application->psn,target->id);
        }
    }
    if (!active && hwm_state_pending) hwm_save_state();
    double elapsed = (hwm_now()-start)*1000;
    ++hwm_frames;
    if (elapsed > 8.34) ++hwm_slow_frames;
    if (elapsed > hwm_max_frame_ms) hwm_max_frame_ms = elapsed;
    __atomic_store_n(&hwm_active, active || !hwm_backend_ok, __ATOMIC_RELEASE);
}

static CVReturn hwm_display_tick(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags inFlags, CVOptionFlags *outFlags, void *context)
{
    (void)link; (void)now; (void)out; (void)inFlags; (void)outFlags; (void)context;
    bool expected = false;
    if ((__atomic_load_n(&hwm_active, __ATOMIC_ACQUIRE) || hwm_stop_requested) &&
        __atomic_compare_exchange_n(&hwm_tick_pending, &expected, true, false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
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
    hwm_hold_focus();
    scripting_addition_set_layer(window->id,window_check_flag(window,WINDOW_FLOAT)?LAYER_ABOVE:LAYER_BELOW);
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
        if(!w || w==window || (whole_app && w->application==window->application)) continue;
        double d=fabs(w->strip_world_x-window->strip_world_x)+fabs(w->strip_world_y-window->strip_world_y)*.1;
        if(d<distance) { best=w; distance=d; }
    }
    if(best) {
        hwm_close_source=window->id; hwm_close_target=best->id; hwm_close_time=hwm_now();
        hwm_close_screen_x=best->strip_world_x-(just_lost_focus?hwm_previous_focus_offset:hwm_offset(view,hwm_now()));
        hwm_hold_focus(); hwm_wake();
    }
}

static struct window_node *hwm_focused_node(struct view *view)
{
    return view ? view_find_window_node(view, g_window_manager.focused_window_id) : NULL;
}
static void hwm_reorder(struct view *view, struct window_node *a, struct window_node *b)
{
    if (!a || !b || a == b) return;
    window_node_swap_window_list(a,b);
    hwm_layout(view,true);
}
#include "overview_runtime.m"

static void hwm_action(int action)
{
    if(action==HWM_OVERVIEW) {
        if(hwm_overview_active) horizontal_overview_select(0,0);
        else hwm_overview_begin(true);
        return;
    }
    if(action==HWM_OVERVIEW_CANCEL) { horizontal_overview_select(0,0); return; }
    if (action==HWM_TERMINAL || action==HWM_BROWSER) {
        hwm_hold_focus();
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTask *task=[[[NSTask alloc] init] autorelease]; task.launchPath=@"/usr/bin/open";
            task.arguments= action==HWM_TERMINAL ? @[@"-na",@"Ghostty"] : @[@"-a",@"Firefox"];
            NSError *error=nil; if(![task launchAndReturnError:&error]) warn("Tana: launch failed: %s\n",error.localizedDescription.UTF8String);
        }); return;
    }
    if (action == HWM_QUIT) { hwm_shutdown(); return; }
    struct view *view = hwm_view();
    struct window *window = window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id);
    struct window_node *node = hwm_focused_node(view);
    if (action == HWM_PAUSE) {
        horizontal_overview_done();
        hwm_cancel_closing();
        hwm_paused = !hwm_paused;
        __atomic_store_n(&hwm_active,false,__ATOMIC_RELEASE);
        if (!hwm_paused) {
            table_for (struct window *w, g_window_manager.window, { w->strip_last_frame = CGRectNull; })
            hwm_layout(view,true);
        }
        return;
    }
    if (hwm_paused || !view) return;
    if (action == HWM_HOME) { hwm_scroll(view,0,true); return; }
    if (action == HWM_REFLOW) {
        table_for (struct window *w, g_window_manager.window, { w->strip_last_frame = CGRectNull; })
        hwm_layout(view,true); return;
    }
    if (!window) return;
    if(action==HWM_CLOSE) {
        hwm_close_animated(window); return;
    }
    if (action == HWM_FLOAT) {
        bool should_float = !window_check_flag(window, WINDOW_FLOAT);
        if (should_float) {
            CGRect bounds = hwm_bounds(view);
            window_manager_make_window_floating(&g_space_manager,&g_window_manager,window,true,true);
            double width = fmin(window->strip_width > 0 ? window->strip_width : 800,bounds.size.width*.8);
            hwm_float_to(window,CGRectMake(bounds.origin.x+(bounds.size.width-width)/2,bounds.origin.y+bounds.size.height*.12,width,bounds.size.height*.76));
            scripting_addition_set_layer(window->id,LAYER_ABOVE);
        } else {
            window->strip_float_animating=false;
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
    } else if (action == HWM_LEFT || action == HWM_RIGHT || action == HWM_MOVE_LEFT || action == HWM_MOVE_RIGHT) {
        bool left = action == HWM_LEFT || action == HWM_MOVE_LEFT;
        struct window_node *next = left ? window_node_find_prev_leaf(node) : window_node_find_next_leaf(node);
        if (!next) return;
        if (action == HWM_MOVE_LEFT || action == HWM_MOVE_RIGHT) hwm_reorder(view,node,next);
        else window = window_manager_find_window(&g_window_manager,next->window_list[0]);
        if (window) {
            hwm_last_input = 0;
            horizontal_focused(window,view);
            window_manager_focus_window_with_raise(&window->application->psn,window->id,window->ref);
        }
    }
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
    if(hwm_overview_active && (type==kCGEventLeftMouseDown || type==kCGEventMouseMoved ||
       type==kCGEventLeftMouseDragged || type==kCGEventLeftMouseUp)) {
        // Fully transparent AppKit pixels are click-through. Route the global
        // pointer stream to the selector before ordinary app/drag handling.
        if(type==kCGEventLeftMouseDown || type==kCGEventMouseMoved)
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
        if(code==53) event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,HWM_OVERVIEW_CANCEL);
        return true;
    }
    if (type == kCGEventKeyDown) {
        CGEventFlags flags = CGEventGetFlags(event);
        CGEventFlags modifiers=flags&(kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate|kCGEventFlagMaskControl|kCGEventFlagMaskShift);
        int code=(int)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        bool shift=(flags&kCGEventFlagMaskShift)!=0;
        int action=-1;
        if(modifiers==kCGEventFlagMaskCommand) {
            if(code==12) action=HWM_CLOSE;
            if(code==36 || code==76) action=HWM_TERMINAL;
            if(code==49) action=HWM_FLOAT;
        } else if(modifiers==(kCGEventFlagMaskCommand|kCGEventFlagMaskShift)) {
            if(code==13) action=HWM_BROWSER;
            if(code==36 || code==76) action=HWM_FULL;
        } else if((modifiers&~kCGEventFlagMaskShift)==(kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate)) {
            if(code==123) action=shift?HWM_MOVE_LEFT:HWM_LEFT;
            if(code==124) action=shift?HWM_MOVE_RIGHT:HWM_RIGHT;
            if(code==49) action=HWM_FLOAT;
            if(code==3) action=HWM_FULL;
            if(code==8) action=HWM_CENTER;
            if(code==29) action=HWM_HOME;
        }
        if (action >= 0) {
            if(CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat) && action!=HWM_LEFT && action!=HWM_RIGHT && action!=HWM_MOVE_LEFT && action!=HWM_MOVE_RIGHT) return true;
            ++hwm_key_actions;
            hwm_keys[code] = true;
            event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,action);
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

static void horizontal_input(void *context, int action)
{
    if(action==HWM_OVERVIEW_POINTER) {
        CGEventRef event=context;
        CGPoint point=CGEventGetLocation(event);
        bool click=CGEventGetType(event)==kCGEventLeftMouseDown;
        uint64_t generation=hwm_overview_generation;
        NSPoint local=NSMakePoint(point.x-hwm_overview_screen.origin.x,point.y-hwm_overview_screen.origin.y);
        dispatch_async(dispatch_get_main_queue(), ^{
            if(hwm_overview_active && generation==hwm_overview_generation) {
                if(click) [[HorizontalWindowOverview sharedOverview] clickAt:local];
                else [[HorizontalWindowOverview sharedOverview] mouseAt:local];
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
        } else {
            if (now-hwm_last_input > .25 || !hwm_resize_window) hwm_resize_window = g_window_manager.focused_window_id;
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
        if (phase == 1) {
            view->strip_gesture_origin = hwm_offset(view,now);
            view->strip_scrolling = false;
            view->strip_velocity = 0;
            view->strip_last_progress = progress;
            view->strip_last_time = now;
            hwm_wake();
            __atomic_store_n(&__pending_gesture,true,__ATOMIC_RELEASE);
        } else if (phase == 2) {
            double dt = now-view->strip_last_time;
            if (dt > .001 && dt < .15) {
                double velocity = (progress-view->strip_last_progress)*width/dt;
                view->strip_velocity = view->strip_velocity*.65+velocity*.35;
            }
            hwm_scroll(view,view->strip_gesture_origin+progress*width,false);
            view->strip_last_progress = progress;
            view->strip_last_time = now;
        } else if (phase == 4 || phase == 8) {
            double velocity = now-view->strip_last_time < .1 ? view->strip_velocity : 0;
            double coast = phase == 8 ? 0 : fmax(-width*.65,fmin(width*.65,velocity*.16));
            hwm_scroll(view,view->strip_offset+coast,true);
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
    double t=(now-hwm_preview_start)/hwm_duration,p=horizontal_ease(t);
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
    CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset(local,2,2),12,12,NULL);
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
static void hwm_preview_set(CGRect target,CGRect start)
{
    if(hwm_preview_visible && !hwm_preview_hiding && CGRectEqualToRect(target,hwm_preview_target)) return;
    double now=hwm_now();
    if(hwm_preview_visible) hwm_preview_render(now);
    hwm_preview_alpha_from=hwm_preview_visible?hwm_preview_alpha:0;
    hwm_preview_alpha_start=now; hwm_preview_hiding=false;
    hwm_preview_from=hwm_preview_visible?hwm_preview_current:start;
    if(!hwm_preview_visible) hwm_preview_current=CGRectNull;
    hwm_preview_target=target; hwm_preview_start=now; hwm_preview_visible=true; hwm_wake();
}
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
static void hwm_drag_update(struct view *view,struct window *window,CGPoint point)
{
    CGRect bounds=hwm_bounds(view),actual=window->frame;
    SLSGetWindowBounds(g_connection,window->id,&actual);
    struct window *target=NULL; HStripPlacement placement=HSTRIP_AFTER_COLUMN;
    double nearest=INFINITY;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int i=0;i<n->window_count;i++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[i]);
        if(!w || w==window) continue;
        CGRect f=CGRectMake(bounds.origin.x+w->strip_world_x-view->strip_offset,bounds.origin.y+w->strip_world_y,w->strip_width,w->strip_height);
        double dx=fmax(f.origin.x-point.x,fmax(0,point.x-CGRectGetMaxX(f)));
        double dy=fmax(f.origin.y-point.y,fmax(0,point.y-CGRectGetMaxY(f)));
        double distance=hypot(dx,dy);
        if(distance>=nearest) continue;
        nearest=distance; target=w;
        double rx=(point.x-f.origin.x)/f.size.width;
        if(rx<.2) placement=HSTRIP_BEFORE_COLUMN;
        else if(rx>.8) placement=HSTRIP_AFTER_COLUMN;
        else placement=point.y<CGRectGetMidY(f)?HSTRIP_ABOVE:HSTRIP_BELOW;
    }
    CGRect preview=CGRectNull;
    if(target && hwm_place(view,window->id,target->id,placement,false,&preview)) {
        hwm_drop_target=target->id; hwm_drop_placement=placement;
        hwm_preview_set(preview,actual);
    } else { hwm_drop_target=0; hwm_preview_hide(); }
}
static bool horizontal_drag(CGEventRef event)
{
    struct window *window=g_mouse_state.window;
    struct view *view=window?window_manager_find_managed_window(&g_window_manager,window):NULL;
    if(!hwm_ready || hwm_paused || !view || view->layout!=VIEW_STRIP) return false;
    CGPoint point=CGEventGetLocation(event);
    if(g_mouse_state.current_action==MOUSE_MODE_MOVE) {
        hwm_drag_window=window->id;
        scripting_addition_set_layer(window->id,LAYER_NORMAL);
        scripting_addition_move_window(window->id,g_mouse_state.window_frame.origin.x+point.x-g_mouse_state.down_location.x,
                                       g_mouse_state.window_frame.origin.y+point.y-g_mouse_state.down_location.y);
    }
    if(!hwm_drag_window && g_mouse_state.current_action==MOUSE_MODE_NONE) {
        CGRect actual=CGRectNull; SLSGetWindowBounds(g_connection,window->id,&actual);
        if(!CGRectIsNull(actual) && hypot(point.x-g_mouse_state.down_location.x,point.y-g_mouse_state.down_location.y)>3 &&
           hypot(actual.origin.x-g_mouse_state.window_frame.origin.x,actual.origin.y-g_mouse_state.window_frame.origin.y)>2) {
            hwm_drag_window=window->id; scripting_addition_set_layer(window->id,LAYER_NORMAL);
        }
    }
    if(hwm_drag_window==window->id) hwm_drag_update(view,window,point);
    return true;
}
static bool horizontal_drop(struct window *window, CGPoint point)
{
    struct view *view=window_manager_find_managed_window(&g_window_manager,window);
    if(!hwm_ready || hwm_paused || !view || view->layout!=VIEW_STRIP) return false;
    if(hwm_drag_window==window->id) {
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
        scripting_addition_set_layer(window->id,LAYER_BELOW);
        if(!hwm_drop_target || !hwm_place(view,window->id,hwm_drop_target,hwm_drop_placement,true,NULL)) hwm_layout(view,true);
        hwm_drop_target=0; hwm_preview_hide(); hwm_hold_focus();
    }
    return true;
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
        fprintf(rsp,"{\"tap_enabled\":%s,\"key_actions\":%llu,\"suspended\":%s,\"overview\":%s,\"overview_renderer\":\"native\",\"overview_windows\":%u,\"overview_frames\":%llu,\"overview_frames_over_8ms\":%llu,\"overview_max_frame_ms\":%.3f,\"vertical_progress\":%.4f}\n",tap&&CGEventTapIsEnabled(tap)?"true":"false",(unsigned long long)hwm_key_actions,hwm_suspended?"true":"false",hwm_overview_active?"true":"false",(unsigned)hwm_overview_window_count,(unsigned long long)hwm_overview_frames,(unsigned long long)hwm_overview_slow_frames,hwm_overview_max_frame_ms,hwm_vertical_last_progress); return;
    }
    if (token_equals(command,"status")) {
        fprintf(rsp,"{\"version\":\"0.1.0\",\"ready\":%s,\"paused\":%s,\"backend\":%s,\"space\":%llu,\"offset\":%.3f,\"autofocus\":%s,\"frames\":%llu,\"frames_over_8ms\":%llu,\"max_frame_ms\":%.3f,\"move_failures\":%llu,\"resize_operations\":%llu,\"windows\":[",hwm_ready?"true":"false",hwm_paused?"true":"false",hwm_backend_ok?"true":"false",(unsigned long long)hwm_space,view?view->strip_offset:0,g_window_manager.ffm_mode==FFM_AUTOFOCUS?"true":"false",(unsigned long long)hwm_frames,(unsigned long long)hwm_slow_frames,hwm_max_frame_ms,(unsigned long long)hwm_move_failures,(unsigned long long)hwm_resize_operations);
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
        if (token_equals(command,"scroll")) hwm_scroll(view,value,true);
        else {
            struct window *w = window_manager_find_window(&g_window_manager,g_window_manager.focused_window_id);
            if (!w || !hwm_focused_node(view)) { daemon_fail(rsp,"focus a tiled window first\n"); return; }
            if (value<240 || value>hwm_bounds(view).size.width) { daemon_fail(rsp,"width must be between 240 and the viewport width\n"); return; }
            hwm_column_width(view,w,value); hwm_layout(view,true);
        }
        return;
    }
    char *names[] = {"left","right","move-left","move-right","float","full","center","home","pause","reflow"};
    int actions[] = {HWM_LEFT,HWM_RIGHT,HWM_MOVE_LEFT,HWM_MOVE_RIGHT,HWM_FLOAT,HWM_FULL,HWM_CENTER,HWM_HOME,HWM_PAUSE,HWM_REFLOW};
    for (int i=0;i<10;++i) if (token_equals(command,names[i])) { hwm_action(actions[i]); return; }
    daemon_fail(rsp,"strip commands: status, left, right, move-left, move-right, float, full, center, home, scroll <offset>, width <points>, pause, reflow\n");
}

@interface HorizontalMenu : NSObject
@property(nonatomic, retain) NSStatusItem *item;
- (void)action:(NSMenuItem *)sender;
- (void)quit:(id)sender;
@end
@implementation HorizontalMenu
- (void)action:(NSMenuItem *)sender { event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,(int)sender.tag); }
- (void)quit:(id)sender { (void)sender; event_loop_post(&g_event_loop,HORIZONTAL_INPUT,NULL,HWM_QUIT); }
@end
static HorizontalMenu *hwm_menu;
static void hwm_menu_begin(void)
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    hwm_menu = [HorizontalMenu new];
    hwm_menu.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    hwm_menu.item.button.title = @"↔";
    hwm_menu.item.button.toolTip = @"Tana — one continuous window strip";
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Tana"] autorelease];
    NSMenuItem *overview=[[[NSMenuItem alloc] initWithTitle:@"Window overview — three-finger swipe up" action:@selector(action:) keyEquivalent:@""] autorelease];
    overview.target=hwm_menu; overview.tag=HWM_OVERVIEW; [menu addItem:overview];
    [menu addItem:[NSMenuItem separatorItem]];
    NSArray *labels = @[@"Focus previous                 ⌥⌘←",@"Focus next                       ⌥⌘→",@"Move left                       ⇧⌥⌘←",@"Move right                     ⇧⌥⌘→",@"Float / tile                         ⌘Space",@"Fill screen / restore            ⇧⌘Return",@"Center window                   ⌥⌘C",@"Return to left wall               ⌥⌘0",@"Pause / resume",@"Reflow windows",@"Close window                       ⌘Q",@"New terminal                       ⌘Return",@"Open Firefox                       ⇧⌘W"];
    int actions[] = {HWM_LEFT,HWM_RIGHT,HWM_MOVE_LEFT,HWM_MOVE_RIGHT,HWM_FLOAT,HWM_FULL,HWM_CENTER,HWM_HOME,HWM_PAUSE,HWM_REFLOW,HWM_CLOSE,HWM_TERMINAL,HWM_BROWSER};
    for (int i=0;i<(int)labels.count;++i) {
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:labels[i] action:@selector(action:) keyEquivalent:@""] autorelease];
        item.target = hwm_menu; item.tag = actions[i]; [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    for (NSString *label in @[@"Three-finger swipe: navigate",@"Option + two-finger scroll: resize",@"Drag onto a window: stack above / below",@"Option + Shift + scroll: navigate"]) {
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:label action:nil keyEquivalent:@""] autorelease]; [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[[NSMenuItem alloc] initWithTitle:@"Quit Tana" action:@selector(quit:) keyEquivalent:@""] autorelease]; quit.target = hwm_menu; [menu addItem:quit];
    hwm_menu.item.menu = menu;
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
static NSString *hwm_state_path(void)
{
    NSString *base=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *current=[base stringByAppendingPathComponent:@"Tana"];
    NSString *legacy=[base stringByAppendingPathComponent:@"HorizontalWM"];
    NSFileManager *files=[NSFileManager defaultManager];
    NSString *directory=![files fileExistsAtPath:current] && [files fileExistsAtPath:legacy] ? legacy : current;
    return [directory stringByAppendingPathComponent:@"layout.json"];
}
static long long hwm_boot_time(void)
{
    struct timeval boot = {0}; size_t length = sizeof(boot);
    sysctlbyname("kern.boottime",&boot,&length,NULL,0);
    return boot.tv_sec;
}
static void hwm_save_state(void)
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
    NSDictionary *state=@{@"version":@1,@"boot":@(hwm_boot_time()),@"offset":@(view->strip_target_offset),@"order":order,@"windows":windows};
    NSString *path=hwm_state_path();
    NSError *error=nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:&error];
    if (data && [data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
        hwm_state_pending=false;
    } else warn("Tana: layout could not be saved: %s\n",error.localizedDescription.UTF8String);
}
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
    if (window_check_flag(window,WINDOW_FLOAT)) scripting_addition_set_layer(window->id,LAYER_ABOVE);
}
static void hwm_shutdown(void)
{
    if (!hwm_ready) return;
    horizontal_overview_done();
    hwm_preview_hide_immediately();
    hwm_cancel_closing();
    hwm_save_state();
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
    dispatch_async(dispatch_get_main_queue(), ^{ hwm_menu_begin(); });
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
        dispatch_source_set_timer(hwm_fallback_timer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/60,NSEC_PER_MSEC);
        __block double last_reconcile=0;
        dispatch_source_set_event_handler(hwm_fallback_timer,^{
            double now=hwm_now(); bool expected=false;
            if(now-last_reconcile>.1 && __atomic_compare_exchange_n(&hwm_reconcile_pending,&expected,true,false,__ATOMIC_ACQ_REL,__ATOMIC_RELAXED)) {
                last_reconcile=now; event_loop_post(&g_event_loop,HORIZONTAL_RECONCILE,NULL,0);
            }
            if(hwm_stop_requested || !hwm_display_link || !CVDisplayLinkIsRunning(hwm_display_link))
                hwm_display_tick(NULL,NULL,NULL,0,NULL,NULL);
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
    if(!hwm_ready || hwm_suspended || hwm_paused || hwm_overview_active || mission_control_is_active()) return;
    double now=hwm_now();
    // Retained Cocoa windows can close without an AX destruction notification.
    // WindowServer ordering catches that case without polling Accessibility.
    table_for(struct window *w,g_window_manager.window, {
        if(w->strip_initialized || w->strip_ordered_out) horizontal_ordered(w->id);
        struct view *view=window_manager_find_managed_window(&g_window_manager,w);
        if(view && view->layout==VIEW_STRIP && w->strip_initialized &&
           !w->strip_ordered_out && w->id!=hwm_drag_window && g_mouse_state.window!=w &&
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

static void horizontal_focus_requested(uint32_t wid)
{
    struct window *window=window_manager_find_window(&g_window_manager,wid);
    if(window) horizontal_focused(window,window_manager_find_managed_window(&g_window_manager,window));
}

static void horizontal_focus_transition(struct window *previous,struct window *next)
{
    if(!hwm_ready || !previous || previous==next) return;
    hwm_previous_focus=previous->id; hwm_previous_focus_time=hwm_now();
    struct view *view=hwm_view();
    hwm_previous_focus_offset=view?hwm_offset(view,hwm_now()):0;
    horizontal_ordered(previous->id);
}
