/* Run optimized, without sanitizers. These are CPU microbenchmarks, not FPS. */
#include "../src/strip_columns.h"
#include <stdio.h>
#include <time.h>

static volatile double sink;
static double seconds(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec+t.tv_nsec/1e9;
}
static double easing(bool fast)
{
    double start=seconds(),sum=0;
    for(size_t i=0;i<300000;i++) {
        double p=(double)(i%10007)/10007;
        sum+=fast?hstrip_ease(p):hstrip_cubic_bezier_ease(p,.22,1,.36,1);
    }
    sink=sum; return seconds()-start;
}
static double columns(size_t count,bool fast)
{
    HStripColumnItem *items=calloc(count,sizeof(*items));
    HStripColumnFrame *frames=calloc(count,sizeof(*frames));
    if(!items || !frames) exit(1);
    for(size_t i=0;i<count;i++) items[i]=(HStripColumnItem){i+1,0,320+(i%7)*40,1};
    size_t runs=200000/count;
    double start=seconds(),sum=0;
    for(size_t i=0;i<runs;i++) {
        double total;
        items[0].width=320+i%31;
        if(fast) hstrip_columns_layout_checked(items,count,12,900,frames,&total);
        else hstrip_columns_layout_scan_checked(items,count,12,900,frames,&total);
        sum+=total+frames[count/2].x;
    }
    sink=sum; double elapsed=seconds()-start;
    free(items); free(frames); return elapsed;
}
static int compare(const void *a,const void *b)
{
    double x=*(const double *)a,y=*(const double *)b;
    return (x>y)-(x<y);
}
int main(void)
{
    puts("Median of 5 runs; reference_ms optimized_ms ratio");
    for(size_t n=0;n<5;n++) {
        size_t count=n ? (size_t)16<<(2*(n-1)) : 0;
        double before[5],after[5];
        for(size_t trial=0;trial<5;trial++) {
            before[trial]=n?columns(count,false):easing(false);
            after[trial]=n?columns(count,true):easing(true);
        }
        qsort(before,5,sizeof(double),compare); qsort(after,5,sizeof(double),compare);
        printf("%s %zu: %.3f %.3f %.2fx\n",n?"columns":"easing",count,
            before[2]*1000,after[2]*1000,before[2]/after[2]);
    }
}
