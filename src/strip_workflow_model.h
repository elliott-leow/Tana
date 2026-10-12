#ifndef TANA_STRIP_WORKFLOW_MODEL_H
#define TANA_STRIP_WORKFLOW_MODEL_H

/* Small, platform-independent decisions used by the strip workflow layer. */

#include <stdbool.h>
#include <stddef.h>
#include <math.h>

static inline double hwm_workflow_next_width(const double *proportions, size_t count,
                                             double current_width, double viewport_width)
{
    if (!proportions || count == 0U || !isfinite(viewport_width) || viewport_width <= 0.0)
        return 0.0;

    size_t nearest = count;
    double nearest_distance = INFINITY;
    for (size_t i = 0U; i < count; ++i) {
        double proportion = proportions[i];
        if (!isfinite(proportion) || proportion <= 0.0 || proportion > 1.0) continue;
        double width = proportion * viewport_width;
        double distance = fabs(width - current_width);
        if (distance < nearest_distance) {
            nearest = i;
            nearest_distance = distance;
        }
    }
    if (nearest == count) return 0.0;

    for (size_t step = 1U; step <= count; ++step) {
        double proportion = proportions[(nearest + step) % count];
        if (isfinite(proportion) && proportion > 0.0 && proportion <= 1.0)
            return proportion * viewport_width;
    }
    return 0.0;
}

/* Preserve the visible pair's ratio while respecting each app's accepted
 * minimum width. Returns false when both minima cannot fit in one viewport. */
static inline bool hwm_workflow_fit_two(double first_width, double second_width,
                                        double first_minimum, double second_minimum,
                                        double gap, double viewport_width,
                                        double *first_out, double *second_out)
{
    if (!first_out || !second_out || !isfinite(viewport_width) || viewport_width <= 0.0)
        return false;
    gap = isfinite(gap) && gap > 0.0 ? gap : 0.0;
    first_minimum = isfinite(first_minimum) && first_minimum > 0.0 ? first_minimum : 0.0;
    second_minimum = isfinite(second_minimum) && second_minimum > 0.0 ? second_minimum : 0.0;
    double available = viewport_width - gap;
    if (available < first_minimum + second_minimum) return false;

    first_width = isfinite(first_width) && first_width > 0.0 ? first_width : 1.0;
    second_width = isfinite(second_width) && second_width > 0.0 ? second_width : 1.0;
    double first = available * first_width / (first_width + second_width);
    if (first < first_minimum) first = first_minimum;
    if (available - first < second_minimum) first = available - second_minimum;
    *first_out = first;
    *second_out = available - first;
    return true;
}

/* Share `available` among columns: in their present proportions, or equally.
 * A column held at its minimum takes what it needs from those with room to
 * give. Returns false, leaving widths alone, when the minima do not fit. */
static inline bool hwm_workflow_fit_many(double *widths, const double *minima, size_t count,
                                         double available, bool equal)
{
    if (!widths || !minima || count == 0U || !isfinite(available) || available <= 0.0) return false;
    double total = 0.0, floor_total = 0.0;
    for (size_t i = 0U; i < count; ++i) {
        double minimum = isfinite(minima[i]) && minima[i] > 0.0 ? minima[i] : 0.0;
        floor_total += minimum;
        total += isfinite(widths[i]) && widths[i] > 0.0 ? widths[i] : 1.0;
    }
    if (floor_total > available) return false;
    for (size_t i = 0U; i < count; ++i) {
        double width = isfinite(widths[i]) && widths[i] > 0.0 ? widths[i] : 1.0;
        widths[i] = equal ? available / (double)count : width * available / total;
    }
    for (size_t pass = 0U; pass < count; ++pass) {
        double deficit = 0.0, spare = 0.0;
        for (size_t i = 0U; i < count; ++i) {
            double minimum = isfinite(minima[i]) && minima[i] > 0.0 ? minima[i] : 0.0;
            if (widths[i] < minimum) { deficit += minimum - widths[i]; widths[i] = minimum; }
            else spare += widths[i] - minimum;
        }
        if (deficit <= 1e-9 || spare <= 0.0) break;
        for (size_t i = 0U; i < count; ++i) {
            double minimum = isfinite(minima[i]) && minima[i] > 0.0 ? minima[i] : 0.0;
            if (widths[i] > minimum) widths[i] -= (widths[i] - minimum) * deficit / spare;
        }
    }
    return true;
}

#endif
