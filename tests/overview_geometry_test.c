#include "../src/overview_geometry.h"

#include <assert.h>
#include <stdio.h>

static void check_grid(size_t count)
{
    HWMOverviewRect cards[50];
    HWMOverviewRect bounds = {0.0, 0.0, 1710.0, 1112.0};
    size_t index;
    size_t other;
    assert(count <= 50U);
    assert(hwm_overview_grid(bounds, count, 44.0, 18.0, cards));
    for (index = 0U; index < count; ++index) {
        assert(hwm_overview_finite_rect(cards[index]));
        assert(cards[index].x >= bounds.x && cards[index].y >= bounds.y);
        assert(cards[index].x + cards[index].width <= bounds.x + bounds.width + 1e-9);
        assert(cards[index].y + cards[index].height <= bounds.y + bounds.height + 1e-9);
        for (other = 0U; other < index; ++other) assert(!hwm_overview_rects_overlap(cards[index], cards[other]));
    }
}

int main(void)
{
    HWMOverviewRect card;
    check_grid(1U);
    check_grid(7U);
    check_grid(20U);
    check_grid(50U);
    HWMOverviewRect portrait = {0,0,500,1000};
    HWMOverviewRect cell = {20,30,400,300};
    HWMOverviewRect fit = hwm_overview_fit(portrait,cell);
    assert(fit.width == 150 && fit.height == 300);
    assert(fit.x == 145 && fit.y == 30);
    HWMOverviewRect start = hwm_overview_flight(portrait,fit,0,1112);
    HWMOverviewRect end = hwm_overview_flight(portrait,fit,1,1112);
    HWMOverviewRect mid = hwm_overview_flight(portrait,fit,.5,1112);
    assert(start.width == portrait.width && start.y == portrait.y);
    assert(end.width == fit.width && end.y == fit.y);
    assert(mid.y < (portrait.y+fit.y)*.5);
    assert(fabs(mid.width/mid.height - .5) < 1e-9);
    assert(!hwm_overview_grid((HWMOverviewRect){0.0, 0.0, 100.0, 100.0}, 0U, 4.0, 2.0, &card));
    assert(!hwm_overview_grid((HWMOverviewRect){0.0, 0.0, 10.0, 10.0}, 1U, 8.0, 2.0, &card));
    puts("overview geometry tests passed");
    return 0;
}
