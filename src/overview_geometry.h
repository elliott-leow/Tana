#ifndef TANA_OVERVIEW_GEOMETRY_H
#define TANA_OVERVIEW_GEOMETRY_H

/* Allocation-free, top-left-coordinate grid geometry for the overview. */

#include <stdbool.h>
#include <stddef.h>
#include <math.h>

typedef struct {
    double x;
    double y;
    double width;
    double height;
} HWMOverviewRect;

static inline bool hwm_overview_finite_rect(HWMOverviewRect rect)
{
    return isfinite(rect.x) && isfinite(rect.y) && isfinite(rect.width) && isfinite(rect.height) &&
           rect.width >= 0.0 && rect.height >= 0.0;
}

/* Returns false for malformed geometry or insufficient room for a positive card. */
static inline bool hwm_overview_grid(HWMOverviewRect bounds, size_t count, double inset,
                                    double gap, HWMOverviewRect *out)
{
    size_t columns;
    size_t rows;
    size_t index;
    double usable_width;
    double usable_height;
    double card_width;
    double card_height;
    double aspect;

    if (!out || count == 0U || !hwm_overview_finite_rect(bounds) || !isfinite(inset) || !isfinite(gap) ||
        inset < 0.0 || gap < 0.0) return false;
    usable_width = bounds.width - inset * 2.0;
    usable_height = bounds.height - inset * 2.0;
    if (usable_width <= 0.0 || usable_height <= 0.0) return false;
    aspect = 1.2; /* Balanced cells; each window keeps its own aspect ratio. */
    columns = 1U;
    double best = -1;
    for (size_t candidate=1; candidate<=count; ++candidate) {
        size_t candidate_rows=(count+candidate-1)/candidate;
        double w=(usable_width-gap*(candidate-1))/candidate;
        double h=(usable_height-gap*(candidate_rows-1))/candidate_rows;
        if(w<=0 || h<=0) continue;
        double image_width=fmin(w,h*aspect);
        double score=image_width*image_width - (double)(candidate*candidate_rows-count)*.01;
        if(score>best) { best=score; columns=candidate; }
    }
    rows = (count + columns - 1U) / columns;
    if (columns > 1U) usable_width -= gap * (double)(columns - 1U);
    if (rows > 1U) usable_height -= gap * (double)(rows - 1U);
    if (usable_width <= 0.0 || usable_height <= 0.0) return false;
    card_width = usable_width / (double)columns;
    card_height = usable_height / (double)rows;
    if (!isfinite(card_width) || !isfinite(card_height) || card_width <= 0.0 || card_height <= 0.0) return false;
    for (index = 0U; index < count; ++index) {
        size_t row = index / columns;
        size_t column = index % columns;
        size_t in_row = count-row*columns < columns ? count-row*columns : columns;
        double row_inset = (columns-in_row)*(card_width+gap)*.5;
        out[index].x = bounds.x + inset + row_inset + (card_width + gap) * (double)column;
        out[index].y = bounds.y + inset + (card_height + gap) * (double)row;
        out[index].width = card_width;
        out[index].height = card_height;
    }
    return true;
}

/*
 * Arrange consecutive column groups as vertical overview columns. `groups` is
 * one stable, arbitrary column identifier per item, and items in each group
 * must already be in their desired top-to-bottom order. Group placement follows
 * first appearance; a repeated identifier after another group is malformed and
 * falls back to the ordinary balanced grid.
 */
static inline bool hwm_overview_grouped_grid(HWMOverviewRect bounds, size_t count,
                                            const size_t *groups, double inset,
                                            double gap, HWMOverviewRect *out)
{
    size_t group_count = 0U;
    if (!groups || count == 0U || !out || !hwm_overview_finite_rect(bounds) ||
        !isfinite(inset) || !isfinite(gap) || inset < 0.0 || gap < 0.0)
        return hwm_overview_grid(bounds, count, inset, gap, out);
    for (size_t index=0; index<count;) {
        size_t end=index+1;
        while(end<count && groups[end]==groups[index]) ++end;
        for(size_t later=end;later<count;later++) if(groups[later]==groups[index])
            return hwm_overview_grid(bounds,count,inset,gap,out);
        ++group_count; index=end;
    }
    // Pack column groups into balanced cells, then expand backward in place.
    // Backward expansion cannot overwrite a group cell still waiting to expand.
    if(!hwm_overview_grid(bounds,group_count,inset,gap,out)) return false;
    size_t end=count;
    for(size_t group=group_count;group>0;group--) {
        size_t start=end-1;
        while(start>0 && groups[start-1]==groups[end-1]) --start;
        HWMOverviewRect cell=out[group-1];
        size_t rows=end-start;
        double row_gap=fmin(gap,cell.height/(rows*3));
        double height=(cell.height-row_gap*(rows-1))/rows;
        for(size_t i=start;i<end;i++) out[i]=(HWMOverviewRect){cell.x,cell.y+(i-start)*(height+row_gap),cell.width,height};
        end=start;
    }
    return true;
}

/* Preserve window proportions, including portrait and very wide windows. */
static inline HWMOverviewRect hwm_overview_fit(HWMOverviewRect source, HWMOverviewRect cell)
{
    if(source.width<=0 || source.height<=0) return cell;
    double scale=fmin(1, fmin(cell.width/source.width, cell.height/source.height));
    double w=source.width*scale, h=source.height*scale;
    return (HWMOverviewRect){cell.x+(cell.width-w)*.5, cell.y+(cell.height-h)*.5,w,h};
}

/* Finger-controlled lift. Endpoints remain exact for a seamless handoff. */
static inline HWMOverviewRect hwm_overview_flight(HWMOverviewRect a, HWMOverviewRect b,
                                                 double progress, double screen_height)
{
    double p=fmax(0,fmin(1,progress));
    double lift=4*p*(1-p)*fmin(100,screen_height*.10);
    return (HWMOverviewRect){a.x+(b.x-a.x)*p, a.y+(b.y-a.y)*p-lift,
                             a.width+(b.width-a.width)*p, a.height+(b.height-a.height)*p};
}

/*
 * Arrow-key navigation over cards as they are laid out on screen. Returns the
 * index of the nearest eligible card whose centre lies in direction (dx, dy),
 * or `count` when there is none. `eligible` may be NULL (all cards).
 */
static inline size_t hwm_overview_neighbor(const HWMOverviewRect *cards, size_t count, size_t current,
                                           int dx, int dy, const bool *eligible)
{
    size_t best=count; double best_score=INFINITY;
    if(!cards || current>=count || (!dx && !dy)) return count;
    double cx=cards[current].x+cards[current].width*.5, cy=cards[current].y+cards[current].height*.5;
    for(size_t i=0;i<count;i++) {
        if(i==current || (eligible && !eligible[i])) continue;
        double x=cards[i].x+cards[i].width*.5-cx, y=cards[i].y+cards[i].height*.5-cy;
        double along=dx ? x*dx : y*dy, across=dx ? fabs(y) : fabs(x);
        if(along<=1.0) continue;
        /* Prefer the same row/column: sideways distance costs double. */
        double score=along+across*2.0;
        if(score<best_score) { best_score=score; best=i; }
    }
    return best;
}

/* Scale a rect about its centre. */
static inline HWMOverviewRect hwm_overview_inflate(HWMOverviewRect r, double scale)
{
    double w=r.width*scale, h=r.height*scale;
    return (HWMOverviewRect){r.x+(r.width-w)*.5, r.y+(r.height-h)*.5, w, h};
}

static inline bool hwm_overview_rects_overlap(HWMOverviewRect a, HWMOverviewRect b)
{
    return a.x < b.x + b.width && b.x < a.x + a.width &&
           a.y < b.y + b.height && b.y < a.y + a.height;
}

#endif
