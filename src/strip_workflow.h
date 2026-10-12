#ifndef TANA_STRIP_WORKFLOW_H
#define TANA_STRIP_WORKFLOW_H

#include <stdbool.h>

struct view;
struct window;

/* Called by the input/command registry for: preset-width, fit-two, previous,
 * undo, consume, expel, up, down, utility-mark, utility, and tabs. */
static bool hwm_workflow_action(const char *name);

/* Capture before a committed strip rearrangement. Restore is PID-qualified and
 * leaves windows created after the snapshot in place. */
static void hwm_undo_capture(void);
static bool hwm_undo_restore(void);

/* Call only for intentional focus changes, before hover/autofocus handling. */
static void hwm_workflow_note_explicit_focus(struct window *window, struct view *view);

/* Layout applies the geometry override before storing a strip frame. Renderer
 * moves a hidden tab offscreen when hwm_workflow_tab_hidden returns true. */
static bool hwm_workflow_tab_geometry(struct view *view, struct window *window,
                                      double *world_y, double *height);
static bool hwm_workflow_tab_hidden(struct window *window);

#endif
