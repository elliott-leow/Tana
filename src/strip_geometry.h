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

/* Analytic critically damped motion retains position AND velocity on retarget.
 * The caller constrains the hard wall, not the spring's target integration. */
static inline double hstrip_spring(double from,double target,double velocity,
                                   double elapsed,double omega,double *out_velocity)
{
    double t=fmax(0,elapsed), a=from-target, b=velocity+omega*a;
    double decay=exp(-omega*t);
    *out_velocity=(velocity-omega*b*t)*decay;
    return target+(a+b*t)*decay;
}

static inline double hstrip_nonnegative(double value);

/* Spring with a damping ratio. zeta >= 1 is the critically damped form above;
 * 0 < zeta < 1 overshoots ("bounce") and still retains velocity on retarget. */
static inline double hstrip_spring_damped(double from,double target,double velocity,
                                          double elapsed,double omega,double zeta,double *out_velocity)
{
    double unused;
    if(!out_velocity) out_velocity=&unused;
    if(!isfinite(zeta) || zeta>=.999) return hstrip_spring(from,target,velocity,elapsed,omega,out_velocity);
    zeta=fmax(.2,zeta);
    double t=fmax(0,elapsed), a=from-target, wd=omega*sqrt(1-zeta*zeta);
    double b=(velocity+zeta*omega*a)/wd, decay=exp(-zeta*omega*t), c=cos(wd*t), s=sin(wd*t);
    *out_velocity=decay*((b*wd-zeta*omega*a)*c-(a*wd+zeta*omega*b)*s);
    return target+decay*(a*c+b*s);
}

/* Natural frequency whose response is within a fraction of a pixel of rest
 * once `duration` has elapsed, so the final snap to the target is invisible. */
static inline double hstrip_spring_omega(double duration,double zeta)
{
    if(!isfinite(zeta) || zeta>1) zeta=1;
    return 10.5/(fmax(.2,zeta)*fmax(.001,duration));
}

/* Normalized 0..1 spring step: an ease-out whose slope starts at zero error. */
static inline double hstrip_spring_progress(double elapsed,double duration)
{
    if(!isfinite(elapsed) || elapsed<=0) return 0;
    if(elapsed>=duration) return 1;
    double v; return hstrip_spring(0,1,0,elapsed,hstrip_spring_omega(duration,1),&v);
}

/* Resistance past a hard edge: displayed travel approaches `limit` asymptotically. */
static inline double hstrip_rubber_band(double distance,double limit)
{
    if(!isfinite(distance) || distance<=0 || !isfinite(limit) || limit<=0) return 0;
    return (1-1/(distance*.55/limit+1))*limit;
}

/*
 * Pick the resting offset nearest `desired` at which some column is flush with
 * the left or right viewport edge. `lefts`/`widths` describe columns in world
 * coordinates. Snapping farther than `reach` is declined (returns desired).
 */
static inline double hstrip_snap_offset(double desired,double viewport_width,const double *lefts,
                                        const double *widths,size_t count,double reach)
{
    double best=desired, distance=INFINITY;
    if(!isfinite(desired) || !lefts || !widths) return hstrip_nonnegative(desired);
    for(size_t i=0;i<count;i++) {
        double candidates[2]={lefts[i],lefts[i]+widths[i]-viewport_width};
        for(int j=0;j<2;j++) {
            double c=candidates[j]<0?0:candidates[j], d=fabs(c-desired);
            if(isfinite(c) && d<distance) { distance=d; best=c; }
        }
    }
    return distance<=reach ? best : hstrip_nonnegative(desired);
}

/*
 * Resting offset that centres the column whose centred position is nearest
 * `desired`. A column wider than the viewport rests with its left edge showing.
 * With no columns the desired offset is returned unchanged (left-clamped).
 */
static inline double hstrip_snap_center(double desired,double viewport_width,const double *lefts,
                                        const double *widths,size_t count)
{
    double best=hstrip_nonnegative(desired), distance=INFINITY;
    if(!isfinite(desired) || !lefts || !widths) return best;
    for(size_t i=0;i<count;i++) {
        double c=widths[i]>=viewport_width ? lefts[i] : lefts[i]+widths[i]*.5-viewport_width*.5;
        if(c<0) c=0;
        double d=fabs(c-desired);
        if(isfinite(c) && d<distance) { distance=d; best=c; }
    }
    return best;
}

/*
 * Resting offset after a swipe that began at `origin` and is heading for
 * `desired`. `rests` are the candidate offsets in ascending order. Travelling
 * more than `threshold` of the way to the neighbouring rest commits to it (or
 * to whichever rest is nearest the destination if that is farther), so a short
 * deliberate swipe changes column and a tiny one returns. Lower thresholds
 * need less movement.
 */
static inline double hstrip_snap_directional(double origin,double desired,const double *rests,
                                             size_t count,double threshold)
{
    if(!rests || !count || !isfinite(origin) || !isfinite(desired)) return hstrip_nonnegative(desired);
    size_t base=0, nearest=0;
    for(size_t i=1;i<count;i++) {
        if(fabs(rests[i]-origin)<fabs(rests[base]-origin)) base=i;
        if(fabs(rests[i]-desired)<fabs(rests[nearest]-desired)) nearest=i;
    }
    double travel=desired-origin;
    if(travel==0) return rests[nearest];
    // The neighbour in the direction of travel, skipping rests at the same offset.
    size_t next=base;
    if(travel>0) { for(size_t i=base+1;i<count;i++) if(rests[i]>rests[base]+.5) { next=i; break; } }
    else { for(size_t i=base;i-->0;) if(rests[i]<rests[base]-.5) { next=i; break; } }
    if(next==base) return rests[nearest]; // Nothing further that way.
    if(!(threshold>0)) threshold=.01;
    double needed=fabs(rests[next]-origin)*threshold;
    if(fabs(travel)<needed) return rests[nearest==next ? base : nearest];
    // Committed: never fall back behind the neighbour.
    if(travel>0) return rests[nearest>next ? nearest : next];
    return rests[nearest<next ? nearest : next];
}

/*
 * A weak magnet for direct manipulation: within `radius` of a resting offset
 * the strip leans toward it by at most `strength` of the remaining distance.
 * The mapping stays strictly increasing for strength <= 0.6, so the strip
 * never moves against the finger; outside the radius it is the identity.
 */
static inline double hstrip_magnet(double raw,double rest,double radius,double strength)
{
    double d=raw-rest, u;
    if(!isfinite(raw) || !isfinite(rest) || !(radius>0) || !(strength>0)) return raw;
    u=fabs(d)/radius;
    if(u>=1) return raw;
    if(strength>.6) strength=.6;
    return raw-d*strength*(1-u)*(1-u);
}

/*
 * Index of the column boundary nearest a world x coordinate: 0 is before the
 * first column, `count` is after the last. `gap` centres the boundary in the
 * space between neighbours.
 */
static inline size_t hstrip_nearest_gap(double world_x,const double *lefts,const double *widths,
                                        size_t count,double gap)
{
    size_t best=count; double distance=INFINITY;
    if(!lefts || !widths || !isfinite(world_x)) return count;
    for(size_t i=0;i<=count;i++) {
        double boundary=i<count ? lefts[i]-gap*.5 : (count ? lefts[count-1]+widths[count-1]+gap*.5 : 0);
        double d=fabs(boundary-world_x);
        if(d<distance) { distance=d; best=i; }
    }
    return best;
}

/*
 * Camera travel after a column of `removed_width` (including its gap) leaves
 * the strip. Columns to its right slide left by that width; moving the camera
 * by half makes both sides converge on the hole. A hole entirely left of the
 * viewport is absorbed completely and one entirely to the right not at all,
 * so windows the user is looking at never jump.
 */
static inline double hstrip_close_shift(double removed_x,double removed_width,
                                        double offset,double viewport_width)
{
    double width=hstrip_nonnegative(removed_width), center=removed_x+width*.5;
    if(center<=offset) return width;
    if(center>=offset+viewport_width) return 0;
    return width*.5;
}

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
