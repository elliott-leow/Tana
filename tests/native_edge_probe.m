/* Optional live test. Only injects drags into a verified disposable fixture. */
#import <Cocoa/Cocoa.h>
#include <unistd.h>
static NSDictionary *info(uint32_t wid) {
    NSArray *list=(NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,wid);
    NSDictionary *entry=[[list firstObject] retain]; [list release]; return [entry autorelease];
}
static CGRect frame(uint32_t wid) {
    CGRect f=CGRectNull; NSDictionary *entry=info(wid);
    if(entry) CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)entry[(id)kCGWindowBounds],&f);
    return f;
}
static void post(CGEventType type,CGPoint p) {
    CGEventRef event=CGEventCreateMouseEvent(NULL,type,p,kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap,event); CFRelease(event);
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=4) return 64;
    uint32_t wid=(uint32_t)strtoul(argv[1],NULL,10);
    NSString *owner=info(wid)[(id)kCGWindowOwnerName];
    if(![owner isEqualToString:@"TanaFixture"]) { fprintf(stderr,"Refusing non-fixture input\n"); return 65; }
    CGRect before=frame(wid); if(CGRectIsNull(before)) return 66;
    NSString *edge=@(argv[2]); double delta=strtod(argv[3],NULL);
    if(!isfinite(delta) || fabs(delta)>240) return 64;
    CGPoint p=CGPointMake(CGRectGetMaxX(before)-1,CGRectGetMidY(before));
    BOOL horizontal=YES;
    if([edge isEqual:@"left"]) p.x=before.origin.x+1;
    else if([edge isEqual:@"bottom"]) { p=CGPointMake(CGRectGetMidX(before),CGRectGetMaxY(before)-1); horizontal=NO; }
    else if([edge isEqual:@"top"]) { p=CGPointMake(CGRectGetMidX(before),before.origin.y+1); horizontal=NO; }
    else if(![edge isEqual:@"right"]) return 64;
    CGEventRef location=CGEventCreate(NULL); CGPoint original=CGEventGetLocation(location); CFRelease(location);
    NSMutableArray *samples=[NSMutableArray array];
    post(kCGEventMouseMoved,p); usleep(100000); post(kCGEventLeftMouseDown,p); usleep(80000);
    for(int i=1;i<=30;i++) {
        CGPoint next=p; if(horizontal) next.x+=delta*i/30; else next.y+=delta*i/30;
        post(kCGEventLeftMouseDragged,next); usleep(25000);
        CGRect f=frame(wid);
        [samples addObject:@{@"x":@(f.origin.x),@"y":@(f.origin.y),@"w":@(f.size.width),@"h":@(f.size.height)}];
    }
    if(horizontal) p.x+=delta; else p.y+=delta;
    post(kCGEventLeftMouseUp,p); usleep(700000); post(kCGEventMouseMoved,original);
    CGRect after=frame(wid);
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"id":@(wid),@"edge":edge,@"delta":@(delta),@"before":@[@(before.origin.x),@(before.origin.y),@(before.size.width),@(before.size.height)],@"after":@[@(after.origin.x),@(after.origin.y),@(after.size.width),@(after.size.height)],@"samples":samples} options:0 error:NULL];
    fwrite(json.bytes,1,json.length,stdout); puts("");
    return 0;
} }
