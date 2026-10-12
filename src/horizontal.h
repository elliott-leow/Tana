#ifndef HORIZONTAL_WM_H
#define HORIZONTAL_WM_H
#include <stdatomic.h>
// All model mutations run on yabai's serialized event loop. The event tap and
// display link only enqueue input/ticks; neither performs Accessibility work.
static bool horizontal_flush_node(struct window_node *node);
static void horizontal_tick(void);
static void horizontal_input(void *context, int action);
static bool horizontal_event(CGEventType type, CGEventRef event);
static void horizontal_focused(struct window *window, struct view *view);
static bool horizontal_drop(struct window *window, CGPoint point);
static bool horizontal_drag(CGEventRef event);
static uint64_t horizontal_destination(struct window *window, uint64_t sid);
static void horizontal_space_changed(void);
static void horizontal_command(FILE *rsp, char *message);
static double horizontal_ease(double t);
static void horizontal_begin(void);
static void horizontal_window_added(struct window *window);
static bool horizontal_window_changed(struct window *window, struct view *view, bool resized);
static bool horizontal_window_moved(struct window *window);
#endif

static bool horizontal_hover_allowed(CGPoint point);
static void horizontal_activated(struct application *application);
static void horizontal_removing(struct window *window, bool whole_app);

static void horizontal_resume(void);

static void horizontal_hover_received(struct window *window);

static void horizontal_ordered(uint32_t wid);

static void horizontal_reconcile(void);

static void horizontal_focus_requested(uint32_t wid);

static void horizontal_focus_transition(struct window *previous,struct window *next);
static void horizontal_overview_select(uint32_t wid, pid_t pid);
static void horizontal_overview_done(void);
static void horizontal_event_timed(int type,double ms);
static uint32_t horizontal_expected_focus(struct application *application);

static void horizontal_mouse_down(struct window *window, CGPoint point);
static bool horizontal_resize_event(struct window *window);
/* Set while a pointer event of that kind is queued; newer ones are dropped. */
static _Atomic bool horizontal_moved_queued, horizontal_dragged_queued;
