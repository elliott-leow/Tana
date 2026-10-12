#ifndef TANA_STRIP_GEOMETRY_H
#define TANA_STRIP_GEOMETRY_H

/*
 * Small, platform-independent geometry helpers for a horizontally scrolling
 * window strip.  All distances are expressed as doubles in one coordinate
 * system.  Invalid numeric inputs are made harmless: lengths and offsets
 * become zero, and invalid Bezier controls fall back to linear easing.
 */

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t id;
    double width;
} HStripWindow;

typedef struct {
    uint64_t id;
    double x;
    double width;
} HStripFrame;

/* Return a finite, non-negative length. */
static inline double hstrip_nonnegative(double value)
{
    return isfinite(value) && value > 0.0 ? value : 0.0;
}

/* Add non-negative finite lengths without ever returning infinity. */
static inline double hstrip_add_length(double left, double right)
{
    left = hstrip_nonnegative(left);
    right = hstrip_nonnegative(right);
    return left > DBL_MAX - right ? DBL_MAX : left + right;
}

/* A scroll offset has a hard left boundary at zero and intentionally no right boundary. */
static inline double hstrip_viewport_offset(double offset)
{
    return hstrip_nonnegative(offset);
}

/* Map virtual positions to finite WindowServer coordinates. Far-offscreen
 * windows park outside all ordinary displays; the virtual strip stays unbounded.
 * Clamping only the physical projection avoids integer overflow in native IPC. */
static inline double hstrip_project_x(double world_x, double offset,
                                      double screen_origin, double limit)
{
    if (!isfinite(world_x) || !isfinite(offset) || !isfinite(screen_origin) ||
        !isfinite(limit) || limit <= 0) return 0;
    double x = world_x-offset+screen_origin;
    if (x < -limit) return -limit;
    if (x > limit) return limit;
    return x;
}

/*
 * Offset that centers a window in the viewport.  It obeys the same hard left
 * clamp and deliberately has no right/content-boundary clamp.
 */
static inline double hstrip_center_offset(double window_x, double window_width,
                                          double viewport_width)
{
    double center = hstrip_add_length(hstrip_nonnegative(window_x),
                                      hstrip_nonnegative(window_width) * 0.5);
    double half_viewport = hstrip_nonnegative(viewport_width) * 0.5;
    return center > half_viewport ? center - half_viewport : 0.0;
}

/*
 * Resize a width by delta and constrain it to [minimum_width, maximum_width].
 * A non-finite or negative maximum means there is no upper bound.  Invalid
 * widths and deltas are harmless (minimum and zero respectively).
 */
static inline double hstrip_resize_width(double width, double delta,
                                         double minimum_width, double maximum_width)
{
    double result = hstrip_nonnegative(width);
    double minimum = hstrip_nonnegative(minimum_width);

    if (isfinite(delta)) {
        if (delta >= 0.0) {
            result = result > DBL_MAX - delta ? DBL_MAX : result + delta;
        } else if (delta <= -result) {
            result = 0.0;
        } else {
            result += delta;
        }
    }
    if (result < minimum) {
        result = minimum;
    }
    if (isfinite(maximum_width) && maximum_width >= 0.0) {
        double maximum = maximum_width < minimum ? minimum : maximum_width;
        if (result > maximum) {
            result = maximum;
        }
    }
    return result;
}

static inline double hstrip_bezier_component(double t, double p1, double p2)
{
    double inverse = 1.0 - t;
    return 3.0 * inverse * inverse * t * p1 + 3.0 * inverse * t * t * p2 + t * t * t;
}

/*
 * Evaluate a cubic Bezier timing curve at progress.  x is inverted with a
 * bounded bisection, so progress refers to elapsed time rather than Bezier t.
 * x controls must be ordered in [0, 1], which guarantees a monotonic x curve.
 */
static inline double hstrip_cubic_bezier_ease(double progress, double x1, double y1,
                                               double x2, double y2)
{
    unsigned int step;
    double low;
    double high;
    double t;

    if (!isfinite(progress) || progress <= 0.0) {
        return 0.0;
    }
    if (progress >= 1.0) {
        return 1.0;
    }
    if (!isfinite(x1) || !isfinite(y1) || !isfinite(x2) || !isfinite(y2) ||
        x1 < 0.0 || x2 < x1 || x2 > 1.0) {
        return progress;
    }

    low = 0.0;
    high = 1.0;
    t = progress;
    for (step = 0; step < 56U; ++step) {
        t = (low + high) * 0.5;
        if (hstrip_bezier_component(t, x1, x2) < progress) {
            low = t;
        } else {
            high = t;
        }
    }
    t = (low + high) * 0.5;
    {
        double value = hstrip_bezier_component(t, y1, y2);
        return isfinite(value) ? value : progress;
    }
}

/* The strip's standard ease-out curve: cubic-bezier(0.22, 1, 0.36, 1). */
static inline double hstrip_ease(double progress)
{
    if (!isfinite(progress) || progress <= 0.0) return 0.0;
    if (progress >= 1.0) return 1.0;
    /* For this fixed curve x'(t) >= 0.626 throughout [0,1]. Newton
     * inversion is well conditioned, unlike arbitrary user control points.
     * Keep the general bisection evaluator above for arbitrary curves. */
    double t = progress;
    for (unsigned step = 0; step < 8; ++step) {
        double error = ((0.58*t-0.24)*t+0.66)*t-progress;
        if (fabs(error) <= 1e-14) break;
        t -= error / ((1.74*t-0.48)*t+0.66);
        t = fmax(0.0, fmin(1.0, t));
    }
    return hstrip_bezier_component(t, 1.0, 1.0);
}

/*
 * Lay out windows left-to-right.  Invalid widths and gaps are treated as zero.
 * frames may be NULL when only the finite total content width is wanted.
 * Returns zero when windows is NULL and count is nonzero.
 */
static inline double hstrip_layout(const HStripWindow *windows, size_t count,
                                   double gap, HStripFrame *frames)
{
    size_t index;
    double x = 0.0;
    double safe_gap = hstrip_nonnegative(gap);

    if (count != 0U && windows == NULL) {
        return 0.0;
    }
    for (index = 0U; index < count; ++index) {
        double width = hstrip_nonnegative(windows[index].width);
        if (frames != NULL) {
            frames[index].id = windows[index].id;
            frames[index].x = x;
            frames[index].width = width;
        }
        x = hstrip_add_length(x, width);
        if (index + 1U < count) {
            x = hstrip_add_length(x, safe_gap);
        }
    }
    return x;
}

/* True when a positive-width item overlaps the viewport by a positive amount. */
static inline bool hstrip_window_visible(double viewport_offset, double viewport_width,
                                         double window_x, double window_width)
{
    double left = hstrip_viewport_offset(viewport_offset);
    double width = hstrip_nonnegative(viewport_width);
    double item_width = hstrip_nonnegative(window_width);
    double item_left = hstrip_nonnegative(window_x);
    double right = hstrip_add_length(left, width);
    double item_right = hstrip_add_length(item_left, item_width);

    return width > 0.0 && item_width > 0.0 && item_right > left && item_left < right;
}

/* True when the entire item fits in the viewport (zero-width items are not visible). */
static inline bool hstrip_window_fully_visible(double viewport_offset, double viewport_width,
                                               double window_x, double window_width)
{
    double left = hstrip_viewport_offset(viewport_offset);
    double width = hstrip_nonnegative(viewport_width);
    double item_width = hstrip_nonnegative(window_width);
    double item_left = hstrip_nonnegative(window_x);
    double right = hstrip_add_length(left, width);
    double item_right = hstrip_add_length(item_left, item_width);

    return width > 0.0 && item_width > 0.0 && item_left >= left && item_right <= right;
}

/*
 * Return the nearest left-clamped offset that reveals an item with padding.
 * There is deliberately no content-width argument and therefore no artificial
 * right clamp: callers can scroll far enough to reveal the final window.
 */
static inline double hstrip_reveal_offset(double current_offset, double viewport_width,
                                          double window_x, double window_width,
                                          double padding)
{
    double current = hstrip_viewport_offset(current_offset);
    double viewport = hstrip_nonnegative(viewport_width);
    double item_left = hstrip_nonnegative(window_x);
    double item_width = hstrip_nonnegative(window_width);
    double inset = hstrip_nonnegative(padding);
    double item_right = hstrip_add_length(item_left, item_width);
    double visible_left;
    double visible_right;

    if (viewport <= 0.0 || item_width <= 0.0) {
        return current;
    }
    visible_left = hstrip_add_length(current, inset);
    if (item_left < visible_left) {
        return item_left > inset ? item_left - inset : 0.0;
    }
    visible_right = hstrip_add_length(current, viewport);
    visible_right = visible_right > inset ? visible_right - inset : 0.0;
    if (item_right > visible_right) {
        double target = item_right > viewport ? item_right - viewport : 0.0;
        return hstrip_add_length(target, inset);
    }
    return current;
}

/* Move one complete window record to its final array index, preserving IDs and widths. */
static inline bool hstrip_reorder(HStripWindow *windows, size_t count, size_t from, size_t to)
{
    HStripWindow moved;
    size_t index;

    if (windows == NULL || from >= count || to >= count) {
        return false;
    }
    if (from == to) {
        return true;
    }
    moved = windows[from];
    if (from < to) {
        for (index = from; index < to; ++index) {
            windows[index] = windows[index + 1U];
        }
    } else {
        for (index = from; index > to; --index) {
            windows[index] = windows[index - 1U];
        }
    }
    windows[to] = moved;
    return true;
}

#endif
