#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../src/strip_workflow_model.h"

static void test_cycles_from_nearest_configured_preset(void)
{
    const double presets[] = {.40, .58, .72};
    assert(fabs(hwm_workflow_next_width(presets, 3, 575, 1000) - 720) < .001);
    assert(fabs(hwm_workflow_next_width(presets, 3, 721, 1000) - 400) < .001);
    assert(hwm_workflow_next_width(NULL, 0, 400, 1000) == 0);
}

static void test_fit_preserves_ratio_and_respects_minima(void)
{
    double first, second;
    assert(hwm_workflow_fit_two(600, 400, 250, 250, 20, 1000, &first, &second));
    assert(fabs(first - 588) < .001 && fabs(second - 392) < .001);
    assert(hwm_workflow_fit_two(100, 900, 300, 250, 20, 1000, &first, &second));
    assert(fabs(first - 300) < .001 && fabs(second - 680) < .001);
    assert(!hwm_workflow_fit_two(1, 1, 600, 500, 20, 1000, &first, &second));
}

static void test_fit_many_shares_the_viewport(void)
{
    double widths[3] = {200, 400, 200}, minima[3] = {0, 0, 0};
    assert(hwm_workflow_fit_many(widths, minima, 3, 1200, false));
    assert(fabs(widths[0] - 300) < .001 && fabs(widths[1] - 600) < .001 && fabs(widths[2] - 300) < .001);
    assert(hwm_workflow_fit_many(widths, minima, 3, 900, true));
    assert(fabs(widths[0] - 300) < .001 && fabs(widths[1] - 300) < .001 && fabs(widths[2] - 300) < .001);
    /* A column held at its minimum takes the difference from the others. */
    double narrow[3] = {100, 450, 450}, floors[3] = {400, 200, 200};
    assert(hwm_workflow_fit_many(narrow, floors, 3, 1000, false));
    assert(fabs(narrow[0] - 400) < .001 && fabs(narrow[1] - 300) < .001 && fabs(narrow[2] - 300) < .001);
    assert(fabs(narrow[0] + narrow[1] + narrow[2] - 1000) < .001);
    double kept[2] = {10, 20}, big[2] = {600, 600};
    assert(!hwm_workflow_fit_many(kept, big, 2, 1000, false) && kept[0] == 10 && kept[1] == 20);
    assert(!hwm_workflow_fit_many(NULL, big, 2, 1000, false) && !hwm_workflow_fit_many(kept, big, 0, 1000, false));
}

int main(void)
{
    test_fit_many_shares_the_viewport();
    test_cycles_from_nearest_configured_preset();
    test_fit_preserves_ratio_and_respects_minima();
    puts("strip workflow model tests passed");
    return 0;
}
