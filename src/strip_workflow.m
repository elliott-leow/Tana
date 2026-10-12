/* Included by horizontal.m after hwm_place. It deliberately uses the strip's
 * existing layout and placement primitives instead of maintaining a second
 * ownership model for yabai window nodes. */
#include "strip_workflow.h"
#include "strip_workflow_model.h"

#ifndef HWM_TAB_BAR
#define HWM_TAB_BAR 30.0
#endif

typedef struct {
    uint32_t id;
    pid_t pid;
} HWMWorkflowIdentity;

typedef struct {
    HWMWorkflowIdentity identity;
} HWMUtility;

typedef struct {
    uint64_t column;
    HWMWorkflowIdentity active;
} HWMTabColumn;

typedef struct {
    HWMWorkflowIdentity identity;
    uint64_t column;
    double width, saved_width, weight;
    CGRect floating_frame;
    bool full_width, floating;
    int shelf;
    size_t order;
} HWMUndoWindow;

typedef struct {
    HWMUndoWindow *windows;
    size_t count;
    uint64_t sid;
    double offset;
    HWMTabColumn *tabs;
    size_t tab_count;
    bool valid;
} HWMUndoSnapshot;

static HWMUndoSnapshot hwm_workflow_undo;
static HWMUtility *hwm_workflow_utilities;
static size_t hwm_workflow_utility_count, hwm_workflow_utility_cursor;
static HWMTabColumn *hwm_workflow_tabs;
static size_t hwm_workflow_tab_count;
static HWMWorkflowIdentity hwm_workflow_current, hwm_workflow_previous;
static double hwm_workflow_current_offset, hwm_workflow_previous_offset;
static HWMWorkflowIdentity hwm_workflow_restore_focus;
static bool hwm_workflow_restoring, hwm_workflow_suppress_focus;

static bool hwm_workflow_utility_index(HWMWorkflowIdentity identity, size_t *out);

static bool hwm_workflow_same(HWMWorkflowIdentity a, HWMWorkflowIdentity b)
{
    return a.id != 0U && a.id == b.id && a.pid == b.pid;
}

static HWMWorkflowIdentity hwm_workflow_identity(struct window *window)
{
    HWMWorkflowIdentity identity = {0};
    if (window && window->application) {
        identity.id = window->id;
        identity.pid = window->application->pid;
    }
    return identity;
}

static struct window *hwm_workflow_live(HWMWorkflowIdentity identity)
{
    struct window *window = identity.id ? window_manager_find_window(&g_window_manager, identity.id) : NULL;
    return window && hwm_workflow_same(identity, hwm_workflow_identity(window)) ? window : NULL;
}

static bool hwm_workflow_in_view(struct view *view, struct window *window)
{
    return view && window && window_manager_find_managed_window(&g_window_manager, window) == view;
}

static uint64_t hwm_workflow_column(struct window *window)
{
    return window && window->strip_column ? window->strip_column : (window ? window->id : 0U);
}

static HWMTabColumn *hwm_workflow_tab(uint64_t column)
{
    for (size_t i = 0U; i < hwm_workflow_tab_count; ++i)
        if (hwm_workflow_tabs[i].column == column) return &hwm_workflow_tabs[i];
    return NULL;
}

static bool hwm_workflow_set_tab(uint64_t column, HWMWorkflowIdentity active)
{
    HWMTabColumn *tab = hwm_workflow_tab(column);
    if (tab) { tab->active = active; return true; }
    HWMTabColumn *grown = realloc(hwm_workflow_tabs, (hwm_workflow_tab_count + 1U) * sizeof(*grown));
    if (!grown) return false;
    hwm_workflow_tabs = grown;
    hwm_workflow_tabs[hwm_workflow_tab_count++] = (HWMTabColumn){column, active};
    return true;
}

static void hwm_workflow_clear_tab(uint64_t column)
{
    for (size_t i = 0U; i < hwm_workflow_tab_count; ++i) if (hwm_workflow_tabs[i].column == column) {
        hwm_workflow_tabs[i] = hwm_workflow_tabs[--hwm_workflow_tab_count];
        if (!hwm_workflow_tab_count) { free(hwm_workflow_tabs); hwm_workflow_tabs = NULL; }
        return;
    }
}

static bool hwm_workflow_snapshot_contains(const HWMUndoWindow *windows, size_t count, HWMWorkflowIdentity identity)
{
    for (size_t i = 0U; i < count; ++i)
        if (hwm_workflow_same(windows[i].identity, identity)) return true;
    return false;
}

static bool hwm_workflow_tab_hidden(struct window *window)
{
    HWMTabColumn *tab = hwm_workflow_tab(hwm_workflow_column(window));
    if (!tab) return false;
    struct window *active = hwm_workflow_live(tab->active);
    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    if (!active || !view || !hwm_workflow_in_view(view, active) || hwm_workflow_column(active) != tab->column)
        tab->active = hwm_workflow_identity(window);
    return !hwm_workflow_same(tab->active, hwm_workflow_identity(window));
}

static bool hwm_workflow_tab_geometry(struct view *view, struct window *window, double *world_y, double *height)
{
    if (!view || !window || !world_y || !height || !hwm_workflow_tab(hwm_workflow_column(window))) return false;
    /* Tabbed columns give up a strip at the top for their tab bar. */
    CGRect bounds = hwm_bounds(view);
    *world_y = HWM_TAB_BAR;
    *height = fmax(100.0, bounds.size.height - HWM_TAB_BAR);
    return true;
}

static bool hwm_workflow_focus(struct view *view, struct window *window, double offset)
{
    if (!window) return false;
    if (hwm_workflow_in_view(view, window)) {
        hwm_workflow_suppress_focus = true;
        hwm_scroll(view, offset, true);
    }
    window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
    return true;
}

static void hwm_workflow_note_explicit_focus(struct window *window, struct view *view)
{
    if (!view) view = hwm_view();
    if (!window || !view || view->layout != VIEW_STRIP) return;
    bool managed = hwm_workflow_in_view(view, window);
    if ((!managed && !window_check_flag(window, WINDOW_FLOAT)) || window->strip_sticky) return;
    HWMWorkflowIdentity identity = hwm_workflow_identity(window);
    HWMTabColumn *tab = managed ? hwm_workflow_tab(hwm_workflow_column(window)) : NULL;
    if (tab && !hwm_workflow_same(tab->active, identity)) {
        tab->active = identity;
        hwm_layout(view, true);
    }
    if (hwm_workflow_suppress_focus && hwm_workflow_same(identity, hwm_workflow_current)) {
        hwm_workflow_suppress_focus = false;
        return;
    }
    if (hwm_workflow_same(identity, hwm_workflow_current)) {
        hwm_workflow_current_offset = view->strip_target_offset;
        return;
    }
    hwm_workflow_previous = hwm_workflow_current;
    /* The user may have panned after the earlier focus event. Preserve the
     * viewport that was actually visible immediately before this switch. */
    hwm_workflow_previous_offset = view->strip_target_offset;
    hwm_workflow_current = identity;
    hwm_workflow_current_offset = view->strip_target_offset;
    if (managed && !hwm_workflow_utility_index(identity, NULL)) hwm_workflow_restore_focus = identity;
}

static bool hwm_workflow_utility_index(HWMWorkflowIdentity identity, size_t *out)
{
    for (size_t i = 0U; i < hwm_workflow_utility_count; ++i) {
        if (hwm_workflow_same(hwm_workflow_utilities[i].identity, identity)) {
            if (out) *out = i;
            return true;
        }
    }
    return false;
}

static void hwm_workflow_prune_utilities(void)
{
    for (size_t i = 0U; i < hwm_workflow_utility_count;) {
        if (hwm_workflow_live(hwm_workflow_utilities[i].identity)) { ++i; continue; }
        hwm_workflow_utilities[i] = hwm_workflow_utilities[--hwm_workflow_utility_count];
    }
    if (!hwm_workflow_utility_count) { free(hwm_workflow_utilities); hwm_workflow_utilities = NULL; hwm_workflow_utility_cursor = 0U; }
    else hwm_workflow_utility_cursor %= hwm_workflow_utility_count;
}

static struct window *hwm_workflow_normal_restore_target(struct view *view, struct window *except)
{
    struct window *previous = hwm_workflow_live(hwm_workflow_previous);
    if (previous && previous != except && hwm_workflow_in_view(view, previous) &&
        !hwm_workflow_utility_index(hwm_workflow_identity(previous), NULL)) return previous;
    for (struct window_node *node = window_node_find_first_leaf(view->root); node; node = window_node_find_next_leaf(node)) {
        for (int i = 0; i < node->window_count; ++i) {
            struct window *candidate = hwm_tile(node->window_list[i]);
            if (candidate && candidate != except && hwm_workflow_in_view(view, candidate) &&
                !hwm_workflow_utility_index(hwm_workflow_identity(candidate), NULL)) return candidate;
        }
    }
    return NULL;
}

static bool hwm_workflow_mark_utility(struct view *view, struct window *window)
{
    HWMWorkflowIdentity identity = hwm_workflow_identity(window);
    size_t prior;
    if (!identity.id) return false;
    if (hwm_workflow_utility_index(identity, &prior)) {
        hwm_workflow_utilities[prior] = hwm_workflow_utilities[--hwm_workflow_utility_count];
        if (!hwm_workflow_utility_count) { free(hwm_workflow_utilities); hwm_workflow_utilities = NULL; hwm_workflow_utility_cursor = 0U; }
        else hwm_workflow_utility_cursor %= hwm_workflow_utility_count;
        return true;
    }
    struct window *restore = hwm_workflow_normal_restore_target(view, window);
    if (restore) hwm_workflow_restore_focus = hwm_workflow_identity(restore);
    else if (hwm_workflow_same(hwm_workflow_restore_focus, identity)) hwm_workflow_restore_focus = (HWMWorkflowIdentity){0};
    HWMUtility *grown = realloc(hwm_workflow_utilities, (hwm_workflow_utility_count + 1U) * sizeof(*grown));
    if (!grown) return false;
    if (hwm_workflow_in_view(view, window)) {
        hwm_undo_capture();
        CGRect bounds = hwm_bounds(view);
        double width = fmin(fmax(240.0, window->strip_width), bounds.size.width * .72);
        window_manager_make_window_floating(&g_space_manager, &g_window_manager, window, true, true);
        hwm_float_to(window, CGRectMake(bounds.origin.x + (bounds.size.width - width) * .5,
                                        bounds.origin.y + bounds.size.height * .15, width, bounds.size.height * .65));
        scripting_addition_set_layer(window->id, LAYER_ABOVE);
    }
    hwm_workflow_utilities = grown;
    hwm_workflow_utilities[hwm_workflow_utility_count++] = (HWMUtility){identity};
    hwm_workflow_utility_cursor = hwm_workflow_utility_count - 1U;
    return true;
}

static void hwm_undo_capture(void)
{
    if (hwm_workflow_restoring) return;
    struct view *view = hwm_view();
    if (!view || view->layout != VIEW_STRIP) return;
    HWMUndoWindow *captured = NULL;
    size_t count = 0U, order = 0U;

    /* The leaf walk is the authoritative strip order; hash-table iteration is
     * intentionally only used afterwards to add floating windows. */
    for (struct window_node *node = window_node_find_first_leaf(view->root); node; node = window_node_find_next_leaf(node)) {
        for (int i = 0; i < node->window_count; ++i) {
            struct window *window = window_manager_find_window(&g_window_manager, node->window_list[i]);
            if (!window || !hwm_workflow_in_view(view, window)) continue;
            HWMUndoWindow *grown = realloc(captured, (count + 1U) * sizeof(*grown));
            if (!grown) { free(captured); return; }
            captured = grown;
            CGRect frame = window->frame; (void)SLSGetWindowBounds(g_connection, window->id, &frame);
            captured[count++] = ((HWMUndoWindow){
                .identity = hwm_workflow_identity(window), .column = window->strip_column,
                .width = window->strip_width, .saved_width = window->strip_saved_width, .weight = window->strip_weight,
                .floating_frame = frame, .full_width = window->strip_full_width, .floating = false, .shelf = window->strip_shelf, .order = order++
            });
        }
    }
    table_for (struct window *window, g_window_manager.window, {
        if (!window_check_flag(window, WINDOW_FLOAT) || window_space(window->id) != view->sid ||
            hwm_workflow_snapshot_contains(captured, count, hwm_workflow_identity(window))) continue;
        HWMUndoWindow *grown = realloc(captured, (count + 1U) * sizeof(*grown));
        if (!grown) { free(captured); return; }
        captured = grown;
        CGRect frame = window->frame; (void)SLSGetWindowBounds(g_connection, window->id, &frame);
        captured[count++] = ((HWMUndoWindow){
            .identity = hwm_workflow_identity(window), .column = window->strip_column,
            .width = window->strip_width, .saved_width = window->strip_saved_width, .weight = window->strip_weight,
            .floating_frame = frame, .full_width = window->strip_full_width, .floating = true, .shelf = window->strip_shelf, .order = SIZE_MAX
        });
    })
    HWMTabColumn *tabs = NULL;
    if (hwm_workflow_tab_count) {
        tabs = calloc(hwm_workflow_tab_count, sizeof(*tabs));
        if (!tabs) { free(captured); return; }
        memcpy(tabs, hwm_workflow_tabs, hwm_workflow_tab_count * sizeof(*tabs));
    }
    free(hwm_workflow_undo.windows);
    free(hwm_workflow_undo.tabs);
    hwm_workflow_undo = (HWMUndoSnapshot){.windows = captured, .count = count, .sid = view->sid,
                                          .offset = view->strip_target_offset, .tabs = tabs,
                                          .tab_count = hwm_workflow_tab_count, .valid = count != 0U};
}

static bool hwm_undo_restore(void)
{
    struct view *view = hwm_view();
    if (!view || view->layout != VIEW_STRIP || !hwm_workflow_undo.valid || hwm_workflow_undo.sid != view->sid) return false;
    bool restored = false;
    hwm_workflow_restoring = true;
    for (size_t i = 0U; i < hwm_workflow_undo.count; ++i) {
        HWMUndoWindow *saved = &hwm_workflow_undo.windows[i];
        struct window *window = hwm_workflow_live(saved->identity);
        if (!window) continue;
        bool floating = window_check_flag(window, WINDOW_FLOAT);
        if (floating != saved->floating)
            window_manager_make_window_floating(&g_space_manager, &g_window_manager, window, saved->floating, true);
        if (saved->floating) {
            if (window_check_flag(window, WINDOW_FLOAT)) hwm_float_to(window, saved->floating_frame);
            restored |= window_check_flag(window, WINDOW_FLOAT);
            continue;
        }
        if (!hwm_workflow_in_view(view, window)) continue;
        window->strip_column = saved->column ? saved->column : window->id;
        window->strip_width = saved->width;
        window->strip_saved_width = saved->saved_width;
        window->strip_weight = saved->weight > 0.0 ? saved->weight : 1.0;
        window->strip_full_width = saved->full_width;
        window->strip_shelf = saved->shelf;
        restored = true;
    }
    /* Use only slots that currently contain a captured window. Dynamic windows
     * stay in their current leaf positions and retain their relative order. */
    struct window_node **slots = NULL;
    size_t slot_count = 0U;
    for (struct window_node *node = window_node_find_first_leaf(view->root); node; node = window_node_find_next_leaf(node)) {
        bool saved_node = false;
        for (int j = 0; j < node->window_count && !saved_node; ++j) {
            struct window *candidate = window_manager_find_window(&g_window_manager, node->window_list[j]);
            saved_node = candidate && hwm_workflow_snapshot_contains(hwm_workflow_undo.windows, hwm_workflow_undo.count, hwm_workflow_identity(candidate));
        }
        if (!saved_node) continue;
        struct window_node **grown = realloc(slots, (slot_count + 1U) * sizeof(*grown));
        if (!grown) { free(slots); slots = NULL; slot_count = 0U; break; }
        slots = grown; slots[slot_count++] = node;
    }
    for (size_t wanted = 0U; wanted < slot_count; ++wanted) {
        for (size_t i = 0U; i < hwm_workflow_undo.count; ++i) {
            HWMUndoWindow *saved = &hwm_workflow_undo.windows[i];
            if (saved->order != wanted) continue;
            struct window *window = hwm_workflow_live(saved->identity);
            struct window_node *found = window && hwm_workflow_in_view(view, window) ? view_find_window_node(view, window->id) : NULL;
            if (found && found != slots[wanted]) window_node_swap_window_list(found, slots[wanted]);
            break;
        }
    }
    free(slots);
    free(hwm_workflow_tabs); hwm_workflow_tabs = NULL; hwm_workflow_tab_count = 0U;
    for (size_t i = 0U; i < hwm_workflow_undo.tab_count; ++i) {
        HWMTabColumn tab = hwm_workflow_undo.tabs[i];
        struct window *active = hwm_workflow_live(tab.active);
        if (active && hwm_workflow_in_view(view, active) && hwm_workflow_column(active) == tab.column)
            (void)hwm_workflow_set_tab(tab.column, tab.active);
    }
    if (restored) { hwm_layout(view, true); hwm_scroll(view, hwm_workflow_undo.offset, true); }
    hwm_workflow_restoring = false;
    return restored;
}

static bool hwm_workflow_cycle_width(struct view *view, struct window *window)
{
    NSArray *presets = hwm_width_presets();
    if (!presets || ![presets count]) return false;
    size_t count = (size_t)[presets count];
    double *values = calloc(count, sizeof(*values));
    if (!values) return false;
    for (size_t i = 0U; i < count; ++i) {
        id value = [presets objectAtIndex:i];
        values[i] = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
    }
    double width = hwm_workflow_next_width(values, count, window->strip_width, hwm_bounds(view).size.width);
    free(values);
    if (width <= 0.0) return false;
    hwm_undo_capture();
    hwm_column_width(view, window, width);
    hwm_layout(view, true);
    return true;
}

static struct window *hwm_workflow_adjacent_column(struct view *view, struct window *window)
{
    uint64_t column = hwm_workflow_column(window);
    bool after = false;
    for (struct window_node *node = window_node_find_first_leaf(view->root); node; node = window_node_find_next_leaf(node)) {
        for (int i = 0; i < node->window_count; ++i) {
            struct window *candidate = hwm_tile(node->window_list[i]);
            if (!candidate) continue;
            uint64_t candidate_column = hwm_workflow_column(candidate);
            if (candidate_column == column) { after = true; continue; }
            if (after) return candidate;
        }
    }
    return NULL;
}

static double hwm_workflow_minimum(struct window *window)
{
    /* horizontal.m caches a validated AX minimum here; zero means unknown. */
    return fmax(160.0, isfinite(window->strip_min_width) && window->strip_min_width > 0.0 ? window->strip_min_width : 0.0);
}

static bool hwm_workflow_fit_two_action(struct view *view, struct window *window)
{
    struct window *next = hwm_workflow_adjacent_column(view, window);
    if (!next) return false;
    double first, second;
    if (!hwm_workflow_fit_two(window->strip_width, next->strip_width, hwm_workflow_minimum(window),
                              hwm_workflow_minimum(next), view->window_gap, hwm_bounds(view).size.width,
                              &first, &second)) return false;
    hwm_undo_capture();
    hwm_column_width(view, window, first);
    hwm_column_width(view, next, second);
    hwm_layout(view, true);
    hwm_scroll(view, window->strip_world_x, true);
    return true;
}

static bool hwm_workflow_focus_row(struct view *view, struct window *window, int direction)
{
    uint64_t column = hwm_workflow_column(window);
    struct window *prior = NULL, *candidate = NULL;
    for (struct window_node *node = window_node_find_first_leaf(view->root); node; node = window_node_find_next_leaf(node)) for (int i = 0; i < node->window_count; ++i) {
        struct window *row = hwm_tile(node->window_list[i]);
        if (!row || hwm_workflow_column(row) != column) continue;
        if (direction < 0 && row == window) { candidate = prior; break; }
        if (direction > 0 && prior == window) { candidate = row; break; }
        prior = row;
    }
    if (!candidate) return false;
    HWMTabColumn *tab = hwm_workflow_tab(column);
    if (tab) { tab->active = hwm_workflow_identity(candidate); hwm_layout(view, true); }
    hwm_workflow_previous = hwm_workflow_current;
    hwm_workflow_previous_offset = hwm_workflow_current_offset;
    hwm_workflow_current = hwm_workflow_identity(candidate);
    hwm_workflow_current_offset = view->strip_target_offset;
    return hwm_workflow_focus(view, candidate, view->strip_target_offset);
}

static bool hwm_workflow_utility_toggle(struct view *view, struct window *focused)
{
    hwm_workflow_prune_utilities();
    if (!hwm_workflow_utility_count) return false;
    size_t focused_index;
    if (hwm_workflow_utility_index(hwm_workflow_identity(focused), &focused_index) && !window_check_flag(focused, WINDOW_MINIMIZE)) {
        if (window_manager_minimize_window(focused) != WINDOW_OP_ERROR_SUCCESS) return false;
        struct window *restore = hwm_workflow_live(hwm_workflow_restore_focus);
        if (restore) hwm_workflow_focus(view, restore, view->strip_target_offset);
        hwm_workflow_utility_cursor = focused_index;
        return true;
    }
    if (hwm_workflow_in_view(view, focused) && !hwm_workflow_utility_index(hwm_workflow_identity(focused), NULL))
        hwm_workflow_restore_focus = hwm_workflow_identity(focused);
    struct window *utility = hwm_workflow_live(hwm_workflow_utilities[hwm_workflow_utility_cursor].identity);
    if (!utility) return false;
    if (window_check_flag(utility, WINDOW_MINIMIZE) && window_manager_deminimize_window(utility) != WINDOW_OP_ERROR_SUCCESS) return false;
    hwm_workflow_previous = hwm_workflow_current;
    hwm_workflow_previous_offset = hwm_workflow_current_offset;
    hwm_workflow_current = hwm_workflow_identity(utility);
    hwm_workflow_current_offset = view->strip_target_offset;
    hwm_workflow_utility_cursor = (hwm_workflow_utility_cursor + 1U) % hwm_workflow_utility_count;
    return hwm_workflow_focus(view, utility, view->strip_target_offset);
}

static bool hwm_workflow_action(const char *name)
{
    if (!name) return false;
    if (!strcmp(name, "undo")) return hwm_undo_restore();
    struct view *view = hwm_view();
    struct window *window = hwm_action_window();
    if (!view || view->layout != VIEW_STRIP || !window) return false;
    if (!strcmp(name, "preset-width")) return hwm_workflow_in_view(view, window) && hwm_workflow_cycle_width(view, window);
    if (!strcmp(name, "fit-two")) return hwm_workflow_in_view(view, window) && hwm_workflow_fit_two_action(view, window);
    if (!strcmp(name, "previous")) {
        struct window *previous = hwm_workflow_live(hwm_workflow_previous);
        if (!previous) return false;
        HWMWorkflowIdentity current = hwm_workflow_current;
        double current_offset = hwm_workflow_current_offset;
        hwm_workflow_current = hwm_workflow_previous; hwm_workflow_current_offset = hwm_workflow_previous_offset;
        hwm_workflow_previous = current; hwm_workflow_previous_offset = current_offset;
        return hwm_workflow_focus(view, previous, hwm_workflow_current_offset);
    }
    if (!strcmp(name, "utility-mark")) return hwm_workflow_mark_utility(view, window);
    if (!strcmp(name, "utility")) return hwm_workflow_utility_toggle(view, window);
    if (!hwm_workflow_in_view(view, window)) return false;
    if (!strcmp(name, "consume")) {
        struct window *next = hwm_workflow_adjacent_column(view, window);
        if (!next) return false;
        hwm_undo_capture();
        return hwm_place(view, next->id, window->id, HSTRIP_BELOW, true, NULL);
    }
    if (!strcmp(name, "expel")) {
        struct window *target = NULL;
        uint64_t column = hwm_workflow_column(window);
        for (struct window_node *node = window_node_find_first_leaf(view->root); node && !target; node = window_node_find_next_leaf(node)) for (int i = 0; i < node->window_count; ++i) {
            struct window *candidate = hwm_tile(node->window_list[i]);
            if (candidate && candidate != window && hwm_workflow_column(candidate) == column) { target = candidate; break; }
        }
        if (!target) target = hwm_workflow_adjacent_column(view, window);
        if (!target) return false;
        hwm_undo_capture();
        return hwm_place(view, window->id, target->id, HSTRIP_AFTER_COLUMN, true, NULL);
    }
    if (!strcmp(name, "up")) return hwm_workflow_focus_row(view, window, -1);
    if (!strcmp(name, "down")) return hwm_workflow_focus_row(view, window, 1);
    if (!strcmp(name, "tabs")) {
        uint64_t column = hwm_workflow_column(window);
        hwm_undo_capture();
        if (hwm_workflow_tab(column)) hwm_workflow_clear_tab(column);
        else if (!hwm_workflow_set_tab(column, hwm_workflow_identity(window))) return false;
        hwm_layout(view, true);
        return true;
    }
    return false;
}

/* Same-boot, PID-qualified state only; never store window titles. */
static NSDictionary *hwm_workflow_save(void)
{
    NSMutableArray *tabs=[NSMutableArray array],*utilities=[NSMutableArray array];
    for(size_t i=0;i<hwm_workflow_tab_count;i++) {
        HWMTabColumn entry=hwm_workflow_tabs[i];
        if(hwm_workflow_live(entry.active)) [tabs addObject:@{@"column":@(entry.column),@"id":@(entry.active.id),@"pid":@(entry.active.pid)}];
    }
    hwm_workflow_prune_utilities();
    for(size_t i=0;i<hwm_workflow_utility_count;i++) {
        HWMWorkflowIdentity identity=hwm_workflow_utilities[i].identity;
        [utilities addObject:@{@"id":@(identity.id),@"pid":@(identity.pid)}];
    }
    return @{@"tabs":tabs,@"utilities":utilities};
}
static void hwm_workflow_load(id state)
{
    if(![state isKindOfClass:[NSDictionary class]]) return;
    free(hwm_workflow_tabs); hwm_workflow_tabs=NULL; hwm_workflow_tab_count=0;
    free(hwm_workflow_utilities); hwm_workflow_utilities=NULL; hwm_workflow_utility_count=0; hwm_workflow_utility_cursor=0;
    for(NSString *key in @[@"tabs",@"utilities"]) {
        id entries=state[key]; if(![entries isKindOfClass:[NSArray class]]) continue;
        for(id entry in entries) {
            if(![entry isKindOfClass:[NSDictionary class]] || ![entry[@"id"] isKindOfClass:[NSNumber class]] || ![entry[@"pid"] isKindOfClass:[NSNumber class]]) continue;
            HWMWorkflowIdentity identity={[entry[@"id"] unsignedIntValue],[entry[@"pid"] intValue]};
            struct window *w=hwm_workflow_live(identity); if(!w) continue;
            if([key isEqual:@"tabs"]) {
                if(![entry[@"column"] isKindOfClass:[NSNumber class]]) continue;
                uint64_t column=[entry[@"column"] unsignedLongLongValue];
                if(hwm_workflow_column(w)==column && hwm_workflow_in_view(hwm_view(),w)) hwm_workflow_set_tab(column,identity);
            } else if(window_check_flag(w,WINDOW_FLOAT) && !hwm_workflow_utility_index(identity,NULL)) {
                HWMUtility *grown=realloc(hwm_workflow_utilities,(hwm_workflow_utility_count+1)*sizeof(*grown));
                if(grown) { hwm_workflow_utilities=grown; hwm_workflow_utilities[hwm_workflow_utility_count++]=(HWMUtility){identity}; }
            }
        }
    }
}
