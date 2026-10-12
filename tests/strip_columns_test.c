#include "../src/strip_columns.h"

#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void close_to(double actual, double expected)
{
    assert(fabs(actual - expected) < 1e-8);
}

static void assert_ids(const HStripColumnItem *items, size_t count, const uint64_t *ids)
{
    size_t index;
    for (index = 0U; index < count; ++index) assert(items[index].id == ids[index]);
}

static void test_side_to_stack_and_back(void)
{
    HStripColumnItem items[] = {{1U, 1U, 100.0, 1.0}, {2U, 2U, 200.0, 1.0}};
    HStripColumnFrame frames[2];
    uint64_t expected[] = {1U, 2U};
    assert(hstrip_columns_place(items, 2U, 0U, 1U, HSTRIP_ABOVE));
    assert_ids(items, 2U, expected);
    assert(hstrip_columns_key(&items[0]) == 2U && hstrip_columns_key(&items[1]) == 2U);
    close_to(items[0].width, 200.0);
    close_to(items[0].weight, 0.5);
    close_to(items[1].weight, 0.5);
    close_to(hstrip_columns_layout(items, 2U, 10.0, 300.0, frames), 200.0);
    close_to(frames[0].height, 145.0);
    close_to(frames[1].y, 155.0);
    assert(hstrip_columns_place(items, 2U, 0U, 1U, HSTRIP_BEFORE_COLUMN));
    assert(hstrip_columns_key(&items[0]) == 1U && hstrip_columns_key(&items[1]) == 2U);
    close_to(items[0].weight, 1.0);
}

static void test_side_to_bottom_stack(void)
{
    HStripColumnItem items[] = {{1U, 1U, 100.0, 1.0}, {2U, 2U, 200.0, 1.0}};
    HStripColumnFrame frames[2];
    uint64_t expected[] = {2U, 1U};
    assert(hstrip_columns_place(items, 2U, 0U, 1U, HSTRIP_BELOW));
    assert_ids(items, 2U, expected);
    assert(hstrip_columns_key(&items[0]) == 2U && hstrip_columns_key(&items[1]) == 2U);
    close_to(hstrip_columns_layout(items, 2U, 10.0, 300.0, frames), 200.0);
    close_to(frames[0].y, 0.0);
    close_to(frames[1].y, 155.0);
}

static void test_within_column_reorder(void)
{
    HStripColumnItem items[] = {{1U, 9U, 100.0, 2.0}, {2U, 9U, 100.0, 3.0}, {3U, 9U, 100.0, 4.0}};
    HStripColumnItem below_items[] = {{1U, 9U, 100.0, 2.0}, {2U, 9U, 100.0, 3.0}, {3U, 9U, 100.0, 4.0}};
    uint64_t expected[] = {3U, 1U, 2U};
    uint64_t below_expected[] = {2U, 1U, 3U};
    assert(hstrip_columns_place(items, 3U, 2U, 0U, HSTRIP_ABOVE));
    assert_ids(items, 3U, expected);
    close_to(items[0].weight, 4.0);
    close_to(items[1].weight, 2.0);
    close_to(items[2].weight, 3.0);
    assert(hstrip_columns_place(below_items, 3U, 0U, 1U, HSTRIP_BELOW));
    assert_ids(below_items, 3U, below_expected);
    close_to(below_items[0].weight, 3.0);
    close_to(below_items[1].weight, 2.0);
    close_to(below_items[2].weight, 4.0);
}

static void test_weighted_rows(void)
{
    HStripColumnItem items[] = {{1U, 7U, 100.0, 1.0}, {2U, 7U, 50.0, 2.0}, {3U, 7U, 20.0, 1.0}};
    HStripColumnFrame frames[3];
    close_to(hstrip_columns_layout(items, 3U, 10.0, 300.0, frames), 100.0);
    close_to(frames[0].height, 70.0);
    close_to(frames[1].y, 80.0);
    close_to(frames[1].height, 140.0);
    close_to(frames[2].y, 230.0);
    close_to(frames[2].height, 70.0);
}

static void test_stack_to_other_column(void)
{
    HStripColumnItem items[] = {{1U, 10U, 100.0, 1.0}, {2U, 10U, 100.0, 1.0}, {3U, 20U, 300.0, 2.0}};
    uint64_t expected[] = {1U, 3U, 2U};
    assert(hstrip_columns_place(items, 3U, 1U, 2U, HSTRIP_BELOW));
    assert_ids(items, 3U, expected);
    assert(hstrip_columns_key(&items[1]) == 20U && hstrip_columns_key(&items[2]) == 20U);
    close_to(items[2].width, 300.0);
    close_to(items[1].weight, 1.0);
    close_to(items[2].weight, 1.0);
}

static void test_side_drop_detaches_anchor_from_old_stack(void)
{
    HStripColumnItem items[] = {{1U, 0U, 100.0, 1.0}, {2U, 1U, 100.0, 1.0}, {3U, 3U, 200.0, 1.0}};
    HStripColumnFrame frames[3];
    uint64_t expected[] = {2U, 1U, 3U};
    assert(hstrip_columns_key(&items[0]) == 1U && hstrip_columns_key(&items[1]) == 1U);
    assert(hstrip_columns_place(items, 3U, 0U, 2U, HSTRIP_BEFORE_COLUMN));
    assert_ids(items, 3U, expected);
    assert(hstrip_columns_key(&items[0]) == 2U);
    assert(hstrip_columns_key(&items[1]) == 1U);
    assert(hstrip_columns_key(&items[2]) == 3U);
    close_to(hstrip_columns_layout(items, 3U, 10.0, 100.0, frames), 420.0);
    close_to(frames[0].x, 0.0);
    close_to(frames[1].x, 110.0);
    close_to(frames[2].x, 220.0);
}

static void test_cross_column_anchor_then_side_drop_does_not_rejoin_old_group(void)
{
    HStripColumnItem items[] = {{1U, 1U, 100.0, 1.0}, {2U, 2U, 200.0, 1.0}, {3U, 1U, 100.0, 1.0}};
    HStripColumnFrame frames[3];
    uint64_t expected[] = {1U, 2U, 3U};

    /* ID 1 moves into column 2 while ID 3 keeps the old effective column 1. */
    assert(hstrip_columns_place(items, 3U, 0U, 1U, HSTRIP_ABOVE));
    assert_ids(items, 3U, expected);
    assert(hstrip_columns_key(&items[0]) == 2U);
    assert(hstrip_columns_key(&items[2]) == 1U);

    /* Taking ID 1 back out must not make it rejoin ID 3's old column. */
    assert(hstrip_columns_place(items, 3U, 0U, 1U, HSTRIP_BEFORE_COLUMN));
    assert_ids(items, 3U, expected);
    assert(hstrip_columns_key(&items[0]) == 1U);
    assert(hstrip_columns_key(&items[1]) == 2U);
    assert(hstrip_columns_key(&items[2]) == 3U);
    close_to(hstrip_columns_layout(items, 3U, 10.0, 100.0, frames), 520.0);
    close_to(frames[0].x, 0.0);
    close_to(frames[1].x, 210.0);
    close_to(frames[2].x, 420.0);
}

static void test_first_appearance_columns_and_identity(void)
{
    HStripColumnItem items[] = {{10U, 100U, 80.0, 1.0}, {20U, 200U, 50.0, 1.0}, {30U, 100U, 120.0, 1.0}};
    HStripColumnFrame frames[3];
    close_to(hstrip_columns_layout(items, 3U, 10.0, 100.0, frames), 180.0);
    close_to(frames[0].x, 0.0);
    close_to(frames[2].x, 0.0);
    close_to(frames[1].x, 130.0);
    assert(frames[0].column == 100U && frames[1].column == 200U);
    assert(hstrip_columns_valid(items, 3U));
}

static void test_malformed_and_finite_guards(void)
{
    HStripColumnItem malformed[] = {{1U, 0U, NAN, NAN}, {1U, 0U, INFINITY, -1.0}};
    HStripColumnItem guarded[] = {{1U, 0U, NAN, NAN}, {2U, 0U, DBL_MAX, -1.0}};
    HStripColumnFrame frames[2];
    double total = 99.0;
    HStripColumnItem before[2];
    assert(!hstrip_columns_layout_checked(NULL, 1U, 1.0, 1.0, NULL, &total));
    assert(!hstrip_columns_layout_checked(malformed, 2U, 1.0, 1.0, frames, &total));
    memcpy(before, malformed, sizeof(before));
    assert(!hstrip_columns_place(malformed, 2U, 0U, 1U, HSTRIP_ABOVE));
    assert(memcmp(before, malformed, sizeof(before)) == 0);
    total = hstrip_columns_layout(guarded, 2U, NAN, INFINITY, frames);
    assert(isfinite(total) && total == DBL_MAX);
    assert(isfinite(frames[0].x) && isfinite(frames[0].height));
}

static void test_indexed_layout_equivalence(void)
{
    HStripColumnItem items[257];
    HStripColumnFrame expected[257],actual[257];
    uint64_t seed=19;
    for(size_t trial=0;trial<500;trial++) {
        size_t count=16+trial%242;
        for(size_t i=0;i<count;i++) {
            seed=seed*UINT64_C(6364136223846793005)+1;
            items[i]=(HStripColumnItem){UINT64_MAX-i,trial%3==0 ? 0 : (seed%17)+1,
                (double)(seed%1000), (double)(seed%23)/3};
            if(trial%7==0) items[i].weight=i%2 ? DBL_MAX : NAN;
            if(trial%11==0) items[i].width=i%2 ? DBL_MAX : INFINITY;
        }
        double gap=trial%5==0 ? DBL_MAX : 12, height=trial%9==0 ? INFINITY : 900;
        double a=-1,b=-1;
        assert(hstrip_columns_layout_scan_checked(items,count,gap,height,expected,&a));
        assert(hstrip_columns_layout_checked(items,count,gap,height,actual,&b));
        assert(a==b);
        for(size_t i=0;i<count;i++) {
            assert(expected[i].id==actual[i].id && expected[i].column==actual[i].column);
            assert(expected[i].x==actual[i].x && expected[i].y==actual[i].y);
            assert(expected[i].width==actual[i].width && expected[i].height==actual[i].height);
        }
        double width_only=-1;
        assert(hstrip_columns_layout_checked(items,count,gap,height,NULL,&width_only));
        assert(width_only==a);
        items[count-1].id=items[0].id;
        memset(actual,0x5a,sizeof(actual)); memcpy(expected,actual,sizeof(actual));
        b=-1;
        assert(!hstrip_columns_layout_checked(items,count,gap,height,actual,&b));
        assert(b==-1 && memcmp(actual,expected,sizeof(actual))==0);
        items[count-1].id=0;
        assert(!hstrip_columns_layout_checked(items,count,gap,height,actual,&b));
    }
}

int main(void)
{
    test_indexed_layout_equivalence();
    test_side_to_stack_and_back();
    test_side_to_bottom_stack();
    test_within_column_reorder();
    test_weighted_rows();
    test_stack_to_other_column();
    test_side_drop_detaches_anchor_from_old_stack();
    test_cross_column_anchor_then_side_drop_does_not_rejoin_old_group();
    test_first_appearance_columns_and_identity();
    test_malformed_and_finite_guards();
    puts("strip columns tests passed");
    return 0;
}
