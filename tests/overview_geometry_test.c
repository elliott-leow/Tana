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

static void check_grouped_grid(void)
{
    HWMOverviewRect cards[5];
    size_t groups[] = {42U, 42U, 42U, 7U, 7U};
    HWMOverviewRect bounds = {0.0, 0.0, 1000.0, 700.0};
    assert(hwm_overview_grouped_grid(bounds, 5U, groups, 40.0, 12.0, cards));
    assert(cards[0].x == cards[1].x && cards[1].x == cards[2].x);
    assert(cards[0].y < cards[1].y && cards[1].y < cards[2].y);
    assert(cards[3].x > cards[2].x && cards[3].x == cards[4].x);
    assert(cards[3].y < cards[4].y);
    for (size_t index = 0U; index < 5U; ++index) {
        assert(cards[index].x >= bounds.x && cards[index].y >= bounds.y);
        assert(cards[index].x + cards[index].width <= bounds.x + bounds.width);
        assert(cards[index].y + cards[index].height <= bounds.y + bounds.height);
    }
    groups[4] = 42U; /* A noncontiguous repeated group uses the normal grid. */
    assert(hwm_overview_grouped_grid(bounds, 5U, groups, 40.0, 12.0, cards));
    assert(cards[0].x != cards[1].x || cards[0].y != cards[1].y);
}

static void check_neighbors(void)
{
    /* Two rows of three; the bottom row is offset like a centred short row. */
    HWMOverviewRect cards[5]={{0,0,100,80},{120,0,100,80},{240,0,100,80},{60,100,100,80},{180,100,100,80}};
    bool only_last[5]={false,false,false,false,true};
    assert(hwm_overview_neighbor(cards,5,0,1,0,NULL)==1);
    assert(hwm_overview_neighbor(cards,5,1,-1,0,NULL)==0);
    assert(hwm_overview_neighbor(cards,5,2,1,0,NULL)==5);   /* nothing further right */
    assert(hwm_overview_neighbor(cards,5,0,0,1,NULL)==3);   /* down goes down, not to the next index */
    assert(hwm_overview_neighbor(cards,5,2,0,1,NULL)==4);
    assert(hwm_overview_neighbor(cards,5,4,0,-1,NULL)==2 || hwm_overview_neighbor(cards,5,4,0,-1,NULL)==1);
    assert(hwm_overview_neighbor(cards,5,0,1,0,only_last)==4); /* filtered cards are skipped */
    assert(hwm_overview_neighbor(cards,5,9,1,0,NULL)==5 && hwm_overview_neighbor(NULL,5,0,1,0,NULL)==5);
    HWMOverviewRect grown=hwm_overview_inflate(cards[1],1.1);
    assert(fabs(grown.width-110)<1e-9 && fabs(grown.x-115)<1e-9 && fabs(grown.y+4)<1e-9);
}

int main(void)
{
    check_neighbors();
    HWMOverviewRect card;
    check_grid(1U);
    check_grid(7U);
    check_grid(20U);
    check_grid(50U);
    check_grouped_grid();
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
