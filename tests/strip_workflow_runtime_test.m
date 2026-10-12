/* Exercises the real workflow module against a tiny deterministic yabai model. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define VIEW_STRIP 1
#define WINDOW_FLOAT 1
#define WINDOW_MINIMIZE 2
#define LAYER_ABOVE 3
#define HSTRIP_BEFORE_COLUMN 0
#define HSTRIP_AFTER_COLUMN 1
#define HSTRIP_ABOVE 2
#define HSTRIP_BELOW 3
typedef int HStripPlacement;
enum window_op_error { WINDOW_OP_ERROR_SUCCESS, WINDOW_OP_ERROR_CANT_MINIMIZE, WINDOW_OP_ERROR_ALREADY_MINIMIZED, WINDOW_OP_ERROR_NOT_MINIMIZED, WINDOW_OP_ERROR_DEMINIMIZE_FAILED };

struct application { pid_t pid; ProcessSerialNumber psn; };
struct window {
    uint32_t id; struct application *application; AXUIElementRef ref; unsigned flags;
    uint64_t strip_column; double strip_width, strip_saved_width, strip_weight, strip_min_width, strip_world_x;
    bool strip_full_width; CGRect frame; int strip_shelf; bool strip_sticky;
};
struct window_node { uint32_t window_list[8]; int window_count; struct window_node *next; };
struct view { int layout, window_gap; uint64_t sid; double strip_target_offset; struct window_node *root; };
struct window_manager { uint32_t focused_window_id; int window; };
struct space_manager { int unused; };
static struct window_manager g_window_manager;
static struct space_manager g_space_manager;
static struct application app = {.pid = 77};
static struct window windows[4];
static struct window_node nodes[4];
static struct view view;
static int g_connection, layout_calls;

#define table_for(declaration, table, body) for (int slot = 0; slot < 4; ++slot) { declaration = &windows[slot]; body; }
static struct view *hwm_view(void) { return &view; }
static CGRect hwm_bounds(struct view *ignored) { (void)ignored; return CGRectMake(0, 0, 1000, 700); }
static void hwm_scroll(struct view *v, double offset, bool animate) { (void)animate; v->strip_target_offset = offset; }
static void hwm_layout(struct view *v, bool animate) { (void)v; (void)animate; ++layout_calls; }
static uint64_t window_space(uint32_t id) { (void)id; return view.sid; }
static bool window_check_flag(struct window *w, int flag) { return (w->flags & (unsigned)flag) != 0U; }
static struct window *window_manager_find_window(struct window_manager *wm, uint32_t id) { (void)wm; return id > 0 && id <= 4 ? &windows[id - 1] : NULL; }
static struct view *window_manager_find_managed_window(struct window_manager *wm, struct window *w) { (void)wm; return window_check_flag(w, WINDOW_FLOAT) ? NULL : &view; }
static void window_manager_focus_window_with_raise(ProcessSerialNumber *psn, uint32_t id, AXUIElementRef ref) { (void)psn; (void)ref; g_window_manager.focused_window_id = id; }
static void window_manager_make_window_floating(struct space_manager *sm, struct window_manager *wm, struct window *w, bool floating, bool force) { (void)sm; (void)wm; (void)force; if (floating) w->flags |= WINDOW_FLOAT; else w->flags &= ~WINDOW_FLOAT; }
static enum window_op_error window_manager_minimize_window(struct window *w) { if (window_check_flag(w, WINDOW_MINIMIZE)) return WINDOW_OP_ERROR_ALREADY_MINIMIZED; w->flags |= WINDOW_MINIMIZE; return WINDOW_OP_ERROR_SUCCESS; }
static enum window_op_error window_manager_deminimize_window(struct window *w) { if (!window_check_flag(w, WINDOW_MINIMIZE)) return WINDOW_OP_ERROR_NOT_MINIMIZED; w->flags &= ~WINDOW_MINIMIZE; return WINDOW_OP_ERROR_SUCCESS; }
static struct window_node *window_node_find_first_leaf(struct window_node *n) { return n; }
static struct window_node *window_node_find_next_leaf(struct window_node *n) { return n ? n->next : NULL; }
static struct window_node *view_find_window_node(struct view *v, uint32_t id) { for (struct window_node *n = v->root; n; n = n->next) for (int i = 0; i < n->window_count; ++i) if (n->window_list[i] == id) return n; return NULL; }
static void window_node_swap_window_list(struct window_node *a, struct window_node *b) { uint32_t id = a->window_list[0]; a->window_list[0] = b->window_list[0]; b->window_list[0] = id; }
static void hwm_column_width(struct view *v, struct window *w, double width) { (void)v; uint64_t col = w->strip_column; for (int i = 0; i < 4; ++i) if (windows[i].strip_column == col) windows[i].strip_width = width; }
static bool hwm_place(struct view *v, uint32_t source, uint32_t target, HStripPlacement placement, bool commit, CGRect *preview) { (void)v; (void)preview; if (!commit || source == target) return source != target; struct window *from = window_manager_find_window(&g_window_manager, source); struct window *to = window_manager_find_window(&g_window_manager, target); if (!from || !to) return false; from->strip_column = (placement == HSTRIP_BELOW || placement == HSTRIP_ABOVE) ? to->strip_column : from->id; hwm_layout(&view, true); return true; }
static void hwm_float_to(struct window *w, CGRect frame) { w->frame = frame; }
static bool scripting_addition_set_layer(uint32_t id, int layer) { (void)id; (void)layer; return true; }
static CGError workflow_test_bounds(int connection, uint32_t id, CGRect *frame) { (void)connection; *frame = windows[id - 1].frame; return kCGErrorSuccess; }
#define SLSGetWindowBounds workflow_test_bounds
static NSArray *hwm_width_presets(void) { return @[@.40, @.60, @.80]; }

static struct window *hwm_tile(uint32_t id) { return window_manager_find_window(&g_window_manager, id); }
static struct window *hwm_action_window(void) { return window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id); }
#include "../src/strip_workflow.m"

static void reset(void)
{
    free(hwm_workflow_undo.windows); free(hwm_workflow_undo.tabs); hwm_workflow_undo=(HWMUndoSnapshot){0};
    free(hwm_workflow_tabs); hwm_workflow_tabs=NULL; hwm_workflow_tab_count=0;
    free(hwm_workflow_utilities); hwm_workflow_utilities=NULL; hwm_workflow_utility_count=0; hwm_workflow_utility_cursor=0;
    hwm_workflow_current=(HWMWorkflowIdentity){0}; hwm_workflow_previous=(HWMWorkflowIdentity){0}; hwm_workflow_restore_focus=(HWMWorkflowIdentity){0};
    hwm_workflow_current_offset=0; hwm_workflow_previous_offset=0; hwm_workflow_restoring=false; hwm_workflow_suppress_focus=false;
    memset(windows, 0, sizeof(windows)); memset(nodes, 0, sizeof(nodes));
    view = (struct view){.layout = VIEW_STRIP, .window_gap = 20, .sid = 9, .root = nodes};
    layout_calls = 0;
    for (int i = 0; i < 4; ++i) {
        windows[i] = (struct window){.id = (uint32_t)(i + 1), .application = &app, .strip_column = (uint64_t)(i + 1), .strip_width = 400, .strip_weight = 1, .frame = CGRectMake(i * 50, 20, 400, 500)};
        nodes[i].window_list[0] = (uint32_t)(i + 1); nodes[i].window_count = 1; nodes[i].next = i < 3 ? &nodes[i + 1] : NULL;
    }
    g_window_manager.focused_window_id = 1;
}

static void test_arrangement_undo_and_fit(void)
{
    reset(); windows[0].strip_min_width = 470; windows[1].strip_min_width = 220;
    assert(hwm_workflow_action("fit-two"));
    assert(windows[0].strip_width >= 470 && windows[0].strip_width + windows[1].strip_width + 20 == 1000);
    assert(hwm_workflow_action("consume") && windows[1].strip_column == windows[0].strip_column);
    assert(hwm_workflow_action("undo") && windows[1].strip_column == 2);
}

static void test_focus_tabs_and_utilities(void)
{
    reset();
    hwm_workflow_note_explicit_focus(&windows[0], &view); view.strip_target_offset = 175;
    hwm_workflow_note_explicit_focus(&windows[1], &view);
    assert(hwm_workflow_action("previous") && g_window_manager.focused_window_id == 1 && view.strip_target_offset == 175);
    assert(hwm_workflow_action("tabs"));
    windows[1].strip_column = windows[0].strip_column;
    assert(hwm_workflow_tab_hidden(&windows[1]));
    double y = -1, height = -1;
    assert(hwm_workflow_tab_geometry(&view, &windows[0], &y, &height) && y == 30 && height == 670); /* room for the tab bar */
    hwm_workflow_note_explicit_focus(&windows[1], &view);
    assert(!hwm_workflow_tab_hidden(&windows[1]) && layout_calls > 0);
    g_window_manager.focused_window_id = 1;
    assert(hwm_workflow_action("utility-mark") && window_check_flag(&windows[0], WINDOW_FLOAT));
    g_window_manager.focused_window_id = 3;
    assert(hwm_workflow_action("utility") && g_window_manager.focused_window_id == 1);
    assert(hwm_workflow_action("utility") && window_check_flag(&windows[0], WINDOW_MINIMIZE));
    assert(g_window_manager.focused_window_id == 3); /* summon captured the real normal focus */
    g_window_manager.focused_window_id = 1;
    assert(hwm_workflow_action("utility-mark")); /* unmark */
}

static void test_marked_current_restores_other_window_and_previous_reaches_float(void)
{
    reset();
    hwm_workflow_note_explicit_focus(&windows[0], &view);
    assert(hwm_workflow_action("utility-mark") && window_check_flag(&windows[0], WINDOW_FLOAT));
    hwm_workflow_note_explicit_focus(&windows[1], &view);
    assert(hwm_workflow_action("previous") && g_window_manager.focused_window_id == 1); /* floating previous */
    assert(hwm_workflow_action("utility") && window_check_flag(&windows[0], WINDOW_MINIMIZE));
    assert(g_window_manager.focused_window_id == 2); /* never restore the just-hidden utility */
    g_window_manager.focused_window_id = 1;
    assert(hwm_workflow_action("utility-mark"));
}

static void test_workflow_persistence(void)
{
    reset(); assert(hwm_workflow_action("tabs"));
    g_window_manager.focused_window_id=2; assert(hwm_workflow_action("utility-mark"));
    NSDictionary *saved=[hwm_workflow_save() retain];
    hwm_workflow_load(saved);
    assert(hwm_workflow_tab_count==1 && hwm_workflow_utility_count==1);
    hwm_workflow_load(@{@"tabs":@[@{@"id":@1,@"pid":@99999,@"column":@1}],@"utilities":@[@"bad"]});
    assert(hwm_workflow_tab_count==0 && hwm_workflow_utility_count==0);
    [saved release];
}

int main(void)
{
    @autoreleasepool { test_arrangement_undo_and_fit(); test_focus_tabs_and_utilities(); test_workflow_persistence(); test_marked_current_restores_other_window_and_previous_reaches_float(); }
    puts("strip workflow runtime tests passed");
    return 0;
}
