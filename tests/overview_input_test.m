/* Exercise overview keyboard handling without real user windows. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdio.h>

#include "../src/window_overview.m"

static NSArray *test_windows(void)
{
    return @[
        @{@"id":@11, @"pid":@101, @"title":@"Project Notes", @"app":@"Safari",
          @"source":[NSValue valueWithRect:NSMakeRect(10,10,300,200)], @"grid":[NSValue valueWithRect:NSMakeRect(20,20,300,200)]},
        @{@"id":@12, @"pid":@102, @"title":@"Layout", @"app":@"Figma",
          @"source":[NSValue valueWithRect:NSMakeRect(320,10,300,200)], @"grid":[NSValue valueWithRect:NSMakeRect(340,20,300,200)]},
        @{@"id":@13, @"pid":@103, @"title":@"Shell", @"app":@"Ghostty",
          @"source":[NSValue valueWithRect:NSMakeRect(630,10,300,200)], @"grid":[NSValue valueWithRect:NSMakeRect(660,20,300,200)]}
    ];
}

static void begin(HorizontalWindowOverview *overview, uint32_t *selected, int *cancelled)
{
    [overview beginWithWindows:test_windows() screenFrame:CGRectMake(0,0,1000,700)
                     selection:^(uint32_t wid, pid_t pid) { assert(pid > 0); *selected=wid; }
                  cancellation:^{ ++*cancelled; }];
}

static void type(HorizontalWindowOverview *overview, NSString *text)
{
    for (NSUInteger index=0U; index<[text length]; ++index) {
        NSString *character=[text substringWithRange:NSMakeRange(index,1U)];
        assert([overview keyCode:0 characters:character modifiers:0]);
    }
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        HorizontalWindowOverview *overview=[HorizontalWindowOverview sharedOverview];
        uint32_t selected=0U;
        int cancelled=0;

        /* Queued progress updates during the opening animation retain selection. */
        begin(overview,&selected,&cancelled);
        assert([overview keyCode:124 characters:nil modifiers:0]);
        [overview setProgress:.8];
        assert([overview keyCode:36 characters:@"\r" modifiers:0]);
        assert(selected==11U && cancelled==0);

        /* Search matches title and app names without regard to case. */
        selected=0U; begin(overview,&selected,&cancelled);
        type(overview,@"pRoJeCt");
        assert([overview keyCode:36 characters:@"\r" modifiers:0]);
        assert(selected==11U);
        selected=0U; begin(overview,&selected,&cancelled);
        type(overview,@"fIgMa");
        assert([overview keyCode:36 characters:@"\r" modifiers:0]);
        assert(selected==12U);

        /* Arrow navigation applies to the filtered order. */
        selected=0U; begin(overview,&selected,&cancelled);
        type(overview,@"a");
        assert([overview keyCode:124 characters:nil modifiers:0]);
        assert([overview keyCode:36 characters:@"\r" modifiers:0]);
        assert(selected==12U);

        /* Escape clears a query first, then a second Escape cancels. */
        selected=0U; begin(overview,&selected,&cancelled);
        type(overview,@"fig");
        assert([overview keyCode:53 characters:@"\033" modifiers:0]);
        assert(cancelled==0);
        assert([overview keyCode:124 characters:nil modifiers:0]);
        assert([overview keyCode:36 characters:@"\r" modifiers:0]);
        assert(selected==11U);
        selected=0U; begin(overview,&selected,&cancelled);
        type(overview,@"fig");
        assert([overview keyCode:53 characters:@"\033" modifiers:0]);
        assert([overview keyCode:53 characters:@"\033" modifiers:0]);
        assert(cancelled==1);

        [overview dismissImmediately];
        puts("overview input tests passed");
    }
    return 0;
}
