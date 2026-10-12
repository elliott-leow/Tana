#include "../src/strip_geometry.h"

#include <assert.h>
#include <float.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

static uint32_t random_state = UINT32_C(0x8c93a5d7);

static uint32_t next_random(void)
{
    random_state = random_state * UINT32_C(1664525) + UINT32_C(1013904223);
    return random_state;
}

static double random_unit(void)
{
    return (double)next_random() / (double)UINT32_MAX;
}

static void expect_close(double actual, double expected)
{
    assert(fabs(actual - expected) < 1e-9);
}

static void assert_known_window(const HStripWindow *window)
{
    switch (window->id) {
    case 10U:
        assert(window->width == 101.0);
        break;
    case 20U:
        assert(window->width == 202.0);
        break;
    case 30U:
        assert(window->width == 303.0);
        break;
    case 40U:
        assert(window->width == 404.0);
        break;
    default:
        assert(false);
    }
}

static void test_easing(void)
{
    size_t index;
    double previous = -1.0;

    expect_close(hstrip_ease(0.0), 0.0);
    expect_close(hstrip_ease(1.0), 1.0);
    expect_close(hstrip_cubic_bezier_ease(0.37, 0.0, 0.0, 1.0, 1.0), 0.37);
    expect_close(hstrip_cubic_bezier_ease(0.37, NAN, 0.0, 1.0, 1.0), 0.37);
    assert(hstrip_ease(NAN) == 0.0);

    for (index = 0U; index <= 20000U; ++index) {
        double input = (double)index / 20000.0;
        double value = hstrip_ease(input);
        assert(fabs(value-hstrip_cubic_bezier_ease(input,.22,1,.36,1))<1e-12);
        assert(isfinite(value));
        assert(value >= previous);
        assert(value >= 0.0 && value <= 1.0);
        previous = value;
    }
    for (index = 0U; index < 10000U; ++index) {
        double input = random_unit();
        double value = hstrip_cubic_bezier_ease(input, 0.22, 1.0, 0.36, 1.0);
        assert(fabs(value-hstrip_ease(input))<1e-12);
        assert(isfinite(value) && value >= 0.0 && value <= 1.0);
    }
}

static void test_layout_and_visibility(void)
{
    HStripWindow windows[] = {{11U, 100.0}, {22U, 50.0}, {33U, 80.0}};
    HStripFrame frames[3];
    HStripWindow invalid[] = {{1U, NAN}, {2U, -8.0}, {3U, INFINITY}};
    HStripWindow huge[4096];
    size_t index;

    expect_close(hstrip_layout(windows, 3U, 10.0, frames), 250.0);
    assert(frames[0].id == 11U && frames[0].x == 0.0 && frames[0].width == 100.0);
    assert(frames[1].id == 22U && frames[1].x == 110.0 && frames[1].width == 50.0);
    assert(frames[2].id == 33U && frames[2].x == 170.0 && frames[2].width == 80.0);
    expect_close(hstrip_layout(invalid, 3U, NAN, frames), 0.0);
    assert(frames[0].width == 0.0 && frames[1].width == 0.0 && frames[2].width == 0.0);
    assert(hstrip_layout(NULL, 1U, 4.0, NULL) == 0.0);

    for (index = 0U; index < sizeof(huge) / sizeof(huge[0]); ++index) {
        huge[index].id = (uint64_t)index;
        huge[index].width = DBL_MAX;
    }
    assert(hstrip_layout(huge, sizeof(huge) / sizeof(huge[0]), DBL_MAX, NULL) == DBL_MAX);

    assert(hstrip_window_visible(100.0, 300.0, 250.0, 25.0));
    assert(!hstrip_window_visible(100.0, 300.0, 400.0, 10.0));
    assert(hstrip_window_fully_visible(100.0, 300.0, 250.0, 25.0));
    assert(!hstrip_window_fully_visible(100.0, 300.0, 390.0, 25.0));
    assert(!hstrip_window_visible(0.0, 300.0, 20.0, 0.0));
}

static void test_reveal_and_reorder(void)
{
    HStripWindow windows[] = {{10U, 101.0}, {20U, 202.0}, {30U, 303.0}, {40U, 404.0}};
    size_t index;

    assert(hstrip_viewport_offset(-3.0) == 0.0);
    assert(hstrip_viewport_offset(INFINITY) == 0.0);
    expect_close(hstrip_center_offset(600.0, 100.0, 300.0), 500.0);
    expect_close(hstrip_center_offset(20.0, 100.0, 300.0), 0.0);
    expect_close(hstrip_resize_width(300.0, 80.0, 180.0, 350.0), 350.0);
    expect_close(hstrip_resize_width(300.0, -500.0, 180.0, 900.0), 180.0);
    expect_close(hstrip_resize_width(NAN, 40.0, 180.0, -1.0), 180.0);
    expect_close(hstrip_reveal_offset(100.0, 300.0, 150.0, 40.0, 10.0), 100.0);
    expect_close(hstrip_reveal_offset(100.0, 300.0, 600.0, 100.0, 0.0), 400.0);
    expect_close(hstrip_reveal_offset(100.0, 300.0, 1000.0, 100.0, 10.0), 810.0);
    expect_close(hstrip_reveal_offset(0.0, 300.0, 205.0, 100.0, 10.0), 15.0);
    expect_close(hstrip_reveal_offset(100.0, 300.0, 20.0, 100.0, 10.0), 10.0);
    expect_close(hstrip_reveal_offset(10.0, NAN, 1000.0, 100.0, 0.0), 10.0);

    assert(hstrip_reorder(windows, 4U, 1U, 3U));
    assert(windows[0].id == 10U && windows[0].width == 101.0);
    assert(windows[1].id == 30U && windows[1].width == 303.0);
    assert(windows[2].id == 40U && windows[2].width == 404.0);
    assert(windows[3].id == 20U && windows[3].width == 202.0);
    assert(hstrip_reorder(windows, 4U, 3U, 0U));
    assert(windows[0].id == 20U && windows[0].width == 202.0);
    assert(!hstrip_reorder(windows, 4U, 4U, 0U));
    assert(!hstrip_reorder(NULL, 0U, 0U, 0U));

    for (index = 0U; index < 1000U; ++index) {
        size_t from = (size_t)(next_random() % 4U);
        size_t to = (size_t)(next_random() % 4U);
        assert(hstrip_reorder(windows, 4U, from, to));
        assert_known_window(&windows[0]);
        assert_known_window(&windows[1]);
        assert_known_window(&windows[2]);
        assert_known_window(&windows[3]);
    }
}

static void test_motion_helpers(void)
{
    double v=0, lefts[3]={0,412,1024}, widths[3]={400,600,500};
    /* Springs start at the source, keep the given velocity, and settle. */
    assert(hstrip_spring_damped(10,90,0,0,30,1,&v)==10 && v==0);
    assert(fabs(hstrip_spring_damped(10,90,0,5,30,.6,&v)-90)<1e-6 && fabs(v)<1e-6);
    hstrip_spring_damped(0,100,250,0,30,.6,&v); assert(fabs(v-250)<1e-9);
    {
        double peak=0;
        for(int i=0;i<400;i++) peak=fmax(peak,hstrip_spring_damped(0,100,0,i/400.0,30,.5,&v));
        assert(peak>100.5 && peak<125); /* an underdamped spring overshoots, boundedly */
    }
    assert(fabs(hstrip_spring(0,600,0,.38,hstrip_spring_omega(.38,1),&v)-600)<.25);
    assert(hstrip_spring_progress(0,.3)==0 && hstrip_spring_progress(.3,.3)==1);
    assert(hstrip_spring_progress(.1,.3)>.5 && hstrip_spring_progress(.1,.3)<1);
    /* Rubber banding is monotonic and never reaches its limit. */
    assert(hstrip_rubber_band(0,300)==0 && hstrip_rubber_band(-5,300)==0);
    assert(hstrip_rubber_band(100,300)<100 && hstrip_rubber_band(100,300)>0);
    assert(hstrip_rubber_band(1e9,300)<300 && hstrip_rubber_band(200,300)>hstrip_rubber_band(100,300));
    /* Snap chooses the nearest flush edge, respects the wall and the reach. */
    assert(hstrip_snap_offset(390,1000,lefts,widths,3,200)==412);
    assert(hstrip_snap_offset(4,1000,lefts,widths,3,200)==0);
    assert(hstrip_snap_offset(40,1000,lefts,widths,3,200)==12); /* second column flush right */
    assert(hstrip_snap_offset(500,1000,lefts,widths,3,200)==524); /* right edge of the last column */
    assert(hstrip_snap_offset(5000,1000,lefts,widths,3,200)==5000);
    assert(hstrip_snap_offset(-20,1000,NULL,NULL,0,200)==0);
    /* Centre snapping: nearest centred column; the first cannot pass the wall. */
    assert(hstrip_snap_center(150,1000,lefts,widths,3)==212);  /* (412+300)-500 */
    assert(hstrip_snap_center(20,1000,lefts,widths,3)==0);
    assert(hstrip_snap_center(900,1000,lefts,widths,3)==774);  /* (1024+250)-500 */
    {
        double wide_left[1]={300}, wide_width[1]={1600};
        assert(hstrip_snap_center(500,1000,wide_left,wide_width,1)==300); /* too wide to centre */
    }
    assert(hstrip_snap_center(-9,1000,NULL,NULL,0)==0);
    {
        /* Directional snapping: a short committed swipe moves on, a twitch returns. */
        double rests[4]={0,212,774,1524};
        assert(hstrip_snap_directional(212,212+80,rests,4,.2)==212);    /* 80 of 562: under 20% */
        assert(hstrip_snap_directional(212,212+130,rests,4,.2)==774);   /* over 20%: next column */
        assert(hstrip_snap_directional(212,212-50,rests,4,.2)==0);      /* 50 of 212 leftwards */
        assert(hstrip_snap_directional(212,212+1200,rests,4,.2)==1524); /* a long flick goes further */
        assert(hstrip_snap_directional(1524,1524+300,rests,4,.2)==1524);/* nothing beyond the end */
        assert(hstrip_snap_directional(212,212+130,rests,4,.5)==212);   /* a stiffer setting holds */
        assert(hstrip_snap_directional(400,400,rests,4,.2)==212);       /* no travel: nearest */
        assert(hstrip_snap_directional(5,-3,NULL,0,.2)==0);
    }
    /* The magnet leans toward rest, is the identity outside its radius, and is monotonic. */
    assert(hstrip_magnet(500,500,200,.3)==500 && hstrip_magnet(800,500,200,.3)==800);
    assert(hstrip_magnet(540,500,200,.3)<540 && hstrip_magnet(540,500,200,.3)>500);
    assert(hstrip_magnet(460,500,200,.3)>460 && hstrip_magnet(460,500,200,.3)<500);
    for(int i=0;i<800;i++) assert(hstrip_magnet(100+i*.5+.5,300,200,.6)>hstrip_magnet(100+i*.5,300,200,.6));
    /* The nearest boundary to a point, including both ends. */
    assert(hstrip_nearest_gap(-50,lefts,widths,3,12)==0);
    assert(hstrip_nearest_gap(420,lefts,widths,3,12)==1);
    assert(hstrip_nearest_gap(1000,lefts,widths,3,12)==2);
    assert(hstrip_nearest_gap(9000,lefts,widths,3,12)==3);
    assert(hstrip_nearest_gap(100,lefts,widths,0,12)==0);
    /* Closing: converge on a visible hole, absorb one to the left, ignore one to the right. */
    assert(hstrip_close_shift(1200,400,1000,1000)==200);
    assert(hstrip_close_shift(100,400,1000,1000)==400);
    assert(hstrip_close_shift(2600,400,1000,1000)==0);
}

int main(void)
{
    test_motion_helpers();
    assert(hstrip_project_x(2000,1000,12,1000000)==1012);
    assert(hstrip_project_x(0,DBL_MAX,0,1000000)==-1000000);
    assert(hstrip_project_x(DBL_MAX,0,0,1000000)==1000000);
    assert(hstrip_project_x(NAN,0,0,1000000)==0);
    test_easing();
    test_layout_and_visibility();
    test_reveal_and_reorder();
    puts("strip geometry tests passed");
    return 0;
}
