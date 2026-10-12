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

int main(void)
{
    test_cycles_from_nearest_configured_preset();
    test_fit_preserves_ratio_and_respects_minima();
    puts("strip workflow model tests passed");
    return 0;
}
