#ifndef TANA_STRIP_COLUMNS_H
#define TANA_STRIP_COLUMNS_H

/* Pure model for horizontal columns containing vertical rows. */

#include "strip_geometry.h"

#include <float.h>
#include <stdlib.h>

typedef struct {
    uint64_t id;
    uint64_t column; /* zero means this item's id */
    double width;
    double weight;
} HStripColumnItem;

typedef struct {
    uint64_t id;
    uint64_t column;
    double x;
    double y;
    double width;
    double height;
} HStripColumnFrame;

typedef enum {
    HSTRIP_BEFORE_COLUMN,
    HSTRIP_AFTER_COLUMN,
    HSTRIP_ABOVE,
    HSTRIP_BELOW
} HStripPlacement;

static inline uint64_t hstrip_columns_key(const HStripColumnItem *item)
{
    return item->column != 0U ? item->column : item->id;
}

static inline double hstrip_columns_weight(double weight)
{
    return isfinite(weight) && weight > 0.0 ? weight : 1.0;
}

/* IDs are model identities: zero and duplicates are invalid rather than ambiguous. */
static inline bool hstrip_columns_valid(const HStripColumnItem *items, size_t count)
{
    size_t index;
    size_t prior;
    if (count != 0U && items == NULL) return false;
    for (index = 0U; index < count; ++index) {
        if (items[index].id == 0U) return false;
        for (prior = 0U; prior < index; ++prior) {
            if (items[prior].id == items[index].id) return false;
        }
    }
    return true;
}

static inline double hstrip_columns_gap_total(double gap, size_t rows)
{
    if (rows < 2U || gap == 0.0) return 0.0;
    return gap > DBL_MAX / (double)(rows - 1U) ? DBL_MAX : gap * (double)(rows - 1U);
}

/*
 * Checked form of layout. Frames correspond one-for-one with items.  It is
 * allocation-free and returns false without writing frames for invalid models.
 */
static inline bool hstrip_columns_layout_scan_checked(const HStripColumnItem *items, size_t count,
                                                 double gap, double height, HStripColumnFrame *frames,
                                                 double *total_width)
{
    size_t column_start;
    size_t prior;
    size_t columns = 0U;
    double x = 0.0;
    double safe_gap = hstrip_nonnegative(gap);
    double safe_height = hstrip_nonnegative(height);

    if (total_width == NULL || !hstrip_columns_valid(items, count)) return false;
    *total_width = 0.0;
    for (column_start = 0U; column_start < count; ++column_start) {
        uint64_t column = hstrip_columns_key(&items[column_start]);
        size_t row_count = 0U;
        size_t row;
        double column_width = 0.0;
        double maximum_weight = 1.0;
        double scaled_weight_sum = 0.0;
        double row_gap;
        double available_height;
        double y = 0.0;
        bool first = true;

        for (prior = 0U; prior < column_start; ++prior) {
            if (hstrip_columns_key(&items[prior]) == column) {
                first = false;
                break;
            }
        }
        if (!first) continue;
        for (row = 0U; row < count; ++row) {
            if (hstrip_columns_key(&items[row]) == column) {
                double weight = hstrip_columns_weight(items[row].weight);
                ++row_count;
                if (hstrip_nonnegative(items[row].width) > column_width) {
                    column_width = hstrip_nonnegative(items[row].width);
                }
                if (weight > maximum_weight) maximum_weight = weight;
            }
        }
        for (row = 0U; row < count; ++row) {
            if (hstrip_columns_key(&items[row]) == column) {
                scaled_weight_sum += hstrip_columns_weight(items[row].weight) / maximum_weight;
            }
        }
        if (columns != 0U) x = hstrip_add_length(x, safe_gap);
        row_gap = hstrip_columns_gap_total(safe_gap, row_count);
        available_height = safe_height > row_gap ? safe_height - row_gap : 0.0;
        for (row = 0U; row < count; ++row) {
            if (hstrip_columns_key(&items[row]) == column) {
                double scaled = hstrip_columns_weight(items[row].weight) / maximum_weight;
                double row_height = scaled_weight_sum > 0.0 ? available_height * scaled / scaled_weight_sum : 0.0;
                if (frames != NULL) {
                    frames[row].id = items[row].id;
                    frames[row].column = column;
                    frames[row].x = x;
                    frames[row].y = y;
                    frames[row].width = column_width;
                    frames[row].height = row_height;
                }
                y = hstrip_add_length(y, row_height);
                if (--row_count != 0U) y = hstrip_add_length(y, safe_gap);
            }
        }
        x = hstrip_add_length(x, column_width);
        ++columns;
    }
    *total_width = x;
    return true;
}

typedef struct {
    uint64_t id, column;
    size_t rows;
    double width, maximum_weight, scaled_sum, x, y;
    bool positioned;
} HStripColumnBucket;

static inline size_t hstrip_columns_hash(uint64_t key, size_t mask)
{
    key ^= key >> 30; key *= UINT64_C(0xbf58476d1ce4e5b9);
    key ^= key >> 27; key *= UINT64_C(0x94d049bb133111eb);
    key ^= key >> 31;
    return (size_t)key & mask;
}

static inline HStripColumnBucket *hstrip_columns_bucket(HStripColumnBucket *buckets,
                                                       size_t mask, uint64_t column)
{
    size_t slot=hstrip_columns_hash(column,mask);
    while(buckets[slot].column && buckets[slot].column!=column) slot=(slot+1)&mask;
    return &buckets[slot];
}

/* Index large strips once instead of rescanning every row for every column.
 * First-appearance column order and original row order are unchanged. Small
 * strips and allocation failure use the allocation-free implementation. */
static inline bool hstrip_columns_layout_checked(const HStripColumnItem *items, size_t count,
                                                 double gap, double height, HStripColumnFrame *frames,
                                                 double *total_width)
{
    if(!total_width || (count && !items)) return false;
    if(count<16 || count>SIZE_MAX/2)
        return hstrip_columns_layout_scan_checked(items,count,gap,height,frames,total_width);
    size_t capacity=32;
    while(capacity/2<count) {
        if(capacity>SIZE_MAX/2) return hstrip_columns_layout_scan_checked(items,count,gap,height,frames,total_width);
        capacity*=2;
    }
    HStripColumnBucket *buckets=calloc(capacity,sizeof(*buckets));
    if(!buckets) return hstrip_columns_layout_scan_checked(items,count,gap,height,frames,total_width);
    size_t mask=capacity-1;
    // Validate before writing any output, including the total width.
    for(size_t i=0;i<count;i++) {
        uint64_t id=items[i].id;
        if(!id) { free(buckets); return false; }
        size_t slot=hstrip_columns_hash(id,mask);
        while(buckets[slot].id && buckets[slot].id!=id) slot=(slot+1)&mask;
        if(buckets[slot].id) { free(buckets); return false; }
        buckets[slot].id=id;
        uint64_t column=hstrip_columns_key(&items[i]);
        HStripColumnBucket *b=hstrip_columns_bucket(buckets,mask,column);
        b->column=column; ++b->rows;
        b->width=fmax(b->width,hstrip_nonnegative(items[i].width));
        b->maximum_weight=fmax(fmax(b->maximum_weight,1),hstrip_columns_weight(items[i].weight));
    }
    for(size_t i=0;i<count;i++) {
        HStripColumnBucket *b=hstrip_columns_bucket(buckets,mask,hstrip_columns_key(&items[i]));
        b->scaled_sum+=hstrip_columns_weight(items[i].weight)/b->maximum_weight;
    }
    double x=0, safe_gap=hstrip_nonnegative(gap), safe_height=hstrip_nonnegative(height);
    bool first=true;
    for(size_t i=0;i<count;i++) {
        uint64_t column=hstrip_columns_key(&items[i]);
        HStripColumnBucket *b=hstrip_columns_bucket(buckets,mask,column);
        if(!b->positioned) {
            if(!first) x=hstrip_add_length(x,safe_gap);
            b->x=x; x=hstrip_add_length(x,b->width);
            b->positioned=true; first=false;
        }
        double row_gap=hstrip_columns_gap_total(safe_gap,b->rows);
        double available=safe_height>row_gap?safe_height-row_gap:0;
        double scaled=hstrip_columns_weight(items[i].weight)/b->maximum_weight;
        double row_height=b->scaled_sum>0 ? available*scaled/b->scaled_sum : 0;
        if(frames) frames[i]=(HStripColumnFrame){items[i].id,column,b->x,b->y,b->width,row_height};
        b->y=hstrip_add_length(hstrip_add_length(b->y,row_height),safe_gap);
    }
    *total_width=x; free(buckets); return true;
}

/* Convenience form; invalid input has the finite total width zero. */
static inline double hstrip_columns_layout(const HStripColumnItem *items, size_t count,
                                           double gap, double height, HStripColumnFrame *frames)
{
    double total_width = 0.0;
    (void)hstrip_columns_layout_checked(items, count, gap, height, frames, &total_width);
    return total_width;
}

static inline void hstrip_columns_move(HStripColumnItem *items, size_t from, size_t destination)
{
    HStripColumnItem moved = items[from];
    size_t index;
    if (from < destination) {
        for (index = from; index + 1U < destination; ++index) items[index] = items[index + 1U];
        items[destination - 1U] = moved;
    } else if (from > destination) {
        for (index = from; index > destination; --index) items[index] = items[index - 1U];
        items[destination] = moved;
    }
}

/*
 * Apply one drop. `from` and `target` are original indices. Side drops create
 * a single-member column; vertical drops join the target column and split its
 * row weight when crossing columns.
 */
static inline bool hstrip_columns_place(HStripColumnItem *items, size_t count, size_t from,
                                        size_t target, HStripPlacement placement)
{
    HStripColumnItem source;
    uint64_t source_column;
    uint64_t target_column;
    size_t destination;

    if (!hstrip_columns_valid(items, count) || from >= count || target >= count || from == target ||
        placement < HSTRIP_BEFORE_COLUMN || placement > HSTRIP_BELOW) {
        return false;
    }
    source = items[from];
    source_column = hstrip_columns_key(&source);
    target_column = hstrip_columns_key(&items[target]);
    if (placement == HSTRIP_ABOVE || placement == HSTRIP_BELOW) {
        if (source_column != target_column) {
            double target_weight = hstrip_columns_weight(items[target].weight);
            items[target].weight = target_weight * 0.5;
            source.weight = target_weight - items[target].weight;
            source.column = target_column;
            source.width = items[target].width;
        }
        items[from] = source;
        destination = placement == HSTRIP_ABOVE ? target : target + 1U;
    } else {
        size_t index;
        uint64_t replacement_column = 0U;
        destination = placement == HSTRIP_BEFORE_COLUMN ? count : 0U;
        /*
         * The source's identity becomes its new column key.  Its old column
         * can still have surviving rows keyed by that identity (including
         * after the source first moved vertically to another column), so
         * give every such remaining row a distinct stable key first.
         */
        {
            for (index = 0U; index < count; ++index) {
                if (index != from && hstrip_columns_key(&items[index]) == source.id) {
                    replacement_column = items[index].id;
                    break;
                }
            }
            if (replacement_column != 0U) {
                for (index = 0U; index < count; ++index) {
                    if (index != from && hstrip_columns_key(&items[index]) == source.id) {
                        items[index].column = replacement_column;
                    }
                }
                if (target_column == source.id) target_column = replacement_column;
            }
        }
        for (index = 0U; index < count; ++index) {
            if (hstrip_columns_key(&items[index]) == target_column) {
                if (placement == HSTRIP_BEFORE_COLUMN) {
                    destination = index;
                    break;
                }
                destination = index + 1U;
            }
        }
        source.column = source.id;
        source.weight = 1.0;
        items[from] = source;
    }
    hstrip_columns_move(items, from, destination);
    return true;
}

#endif
