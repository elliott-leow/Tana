/* Transparent selection surface for WindowServer-owned overview transforms. */

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <math.h>
#include "overview_geometry.h"

@class HorizontalWindowOverview;

@interface HWMOverviewPanel : NSPanel
@end
@implementation HWMOverviewPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface HWMOverviewView : NSView {
@private
    HorizontalWindowOverview *_overview;
    NSTrackingArea *_trackingArea;
    NSRect _outline;
    BOOL _hasOutline;
    CAShapeLayer *_halo;
    CAShapeLayer *_stroke;
}
- (void)setOverview:(HorizontalWindowOverview *)overview;
- (void)setOutline:(NSRect)outline visible:(BOOL)visible;
@end

@interface HorizontalWindowOverview : NSObject {
@private
    HWMOverviewPanel *_panel;
    HWMOverviewView *_view;
    NSArray *_windows;
    CGRect _screenFrame;
    double _progress;
    NSInteger _hovered;
    void (^_selection)(uint32_t wid, pid_t pid);
    void (^_cancellation)(void);
    id _keyMonitor;
    BOOL _visible;
    BOOL _closing;
    BOOL _selectionSent;
    BOOL _cancellationSent;
}
+ (HorizontalWindowOverview *)sharedOverview;
- (void)beginWithWindows:(NSArray *)windows screenFrame:(CGRect)frame
               selection:(void (^)(uint32_t wid, pid_t pid))selection
            cancellation:(void (^)(void))cancel;
- (void)setProgress:(double)progress;
- (void)beginClosing;
- (void)dismissImmediately;
- (BOOL)isVisible;
@end

@interface HorizontalWindowOverview (Input)
- (void)mouseAt:(NSPoint)point;
- (void)clickAt:(NSPoint)point;
- (void)cancelFromOverlay;
@end

static BOOL hwm_overview_valid_screen(CGRect frame)
{
    return isfinite(frame.origin.x) && isfinite(frame.origin.y) &&
           isfinite(frame.size.width) && isfinite(frame.size.height) &&
           frame.size.width > 0.0 && frame.size.height > 0.0;
}

/* SLS input is top-left global; AppKit windows use bottom-left global. */
static NSRect hwm_overview_panel_frame(CGRect topLeftFrame)
{
    NSScreen *screen = [NSScreen mainScreen];
    if (!hwm_overview_valid_screen(topLeftFrame)) return [screen frame];
    return NSMakeRect(topLeftFrame.origin.x,
                      NSMaxY([screen frame]) - topLeftFrame.origin.y - topLeftFrame.size.height,
                      topLeftFrame.size.width, topLeftFrame.size.height);
}

static BOOL hwm_overview_window_rect(NSDictionary *window, NSString *key, HWMOverviewRect *out)
{
    id value = [window objectForKey:key];
    NSRect rect;
    if (![value isKindOfClass:[NSValue class]]) return NO;
    rect = [value rectValue];
    *out = (HWMOverviewRect){rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
    return hwm_overview_finite_rect(*out) && out->width > 0.0 && out->height > 0.0;
}

@implementation HWMOverviewView
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (instancetype)initWithFrame:(NSRect)frame
{
    self=[super initWithFrame:frame];
    if(self) {
        self.wantsLayer=YES;
        _halo=[[CAShapeLayer alloc] init]; _stroke=[[CAShapeLayer alloc] init];
        for(CAShapeLayer *outline in @[_halo,_stroke]) {
            outline.frame=self.bounds; outline.autoresizingMask=kCALayerWidthSizable|kCALayerHeightSizable;
            outline.fillColor=NSColor.clearColor.CGColor; outline.opacity=0;
            [self.layer addSublayer:outline];
        }
        _halo.lineWidth=5; _halo.strokeColor=[NSColor colorWithCalibratedRed:.31 green:.64 blue:1 alpha:.20].CGColor;
        _stroke.lineWidth=1.5; _stroke.strokeColor=[NSColor colorWithCalibratedRed:.40 green:.72 blue:1 alpha:.95].CGColor;
    }
    return self;
}
- (void)setOverview:(HorizontalWindowOverview *)overview { _overview = overview; }
- (void)setOutline:(NSRect)outline visible:(BOOL)visible
{
    if(_hasOutline==visible && (!visible || NSEqualRects(_outline,outline))) return;
    CGPathRef path=visible ? CGPathCreateWithRoundedRect(NSInsetRect(outline,1,1),10,10,NULL) : NULL;
    for(CAShapeLayer *shape in @[_halo,_stroke]) {
        CAShapeLayer *presentation=(CAShapeLayer *)shape.presentationLayer;
        CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue=@(presentation ? presentation.opacity : shape.opacity);
        fade.toValue=@(visible?1:0); fade.duration=.14;
        fade.timingFunction=[CAMediaTimingFunction functionWithControlPoints:.22 :1 :.36 :1];
        CABasicAnimation *move=nil;
        if(visible && _hasOutline && shape.path) {
            move=[CABasicAnimation animationWithKeyPath:@"path"];
            move.fromValue=(id)(presentation.path ?: shape.path); move.toValue=(id)path;
            move.duration=.14; move.timingFunction=fade.timingFunction;
        }
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        if(path) shape.path=path;
        shape.opacity=visible?1:0;
        [CATransaction commit];
        [shape addAnimation:fade forKey:@"outline-opacity"];
        if(move) [shape addAnimation:move forKey:@"outline-path"];
    }
    if(path) CGPathRelease(path);
    _outline=outline; _hasOutline=visible;
}
- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor clearColor] setFill];
    NSRectFillUsingOperation(dirtyRect, NSCompositingOperationCopy);
}
- (void)updateTrackingAreas
{
    if (_trackingArea) { [self removeTrackingArea:_trackingArea]; [_trackingArea release]; }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:[self bounds]
                                                 options:(NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect)
                                                   owner:self userInfo:nil];
    [self addTrackingArea:_trackingArea]; [super updateTrackingAreas];
}
- (void)mouseMoved:(NSEvent *)event { [_overview mouseAt:[self convertPoint:[event locationInWindow] fromView:nil]]; }
- (void)mouseDown:(NSEvent *)event { [_overview clickAt:[self convertPoint:[event locationInWindow] fromView:nil]]; }
- (void)dealloc { [_halo release]; [_stroke release]; [_trackingArea release]; [super dealloc]; }
@end

@implementation HorizontalWindowOverview
+ (HorizontalWindowOverview *)sharedOverview
{
    static HorizontalWindowOverview *overview;
    if (!overview) overview = [[self alloc] init];
    return overview;
}
- (void)dealloc
{
    [self dismissImmediately]; [_panel release]; [_view release]; [super dealloc];
}
- (void)buildPanelForScreenFrame:(CGRect)frame
{
    if (_panel) {
        [_panel setFrame:hwm_overview_panel_frame(frame) display:NO];
        [_view setFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];
        return;
    }
    _panel = [[HWMOverviewPanel alloc] initWithContentRect:hwm_overview_panel_frame(frame)
                                                  styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                                                    backing:NSBackingStoreBuffered defer:NO];
    [_panel setOpaque:NO]; [_panel setBackgroundColor:[NSColor clearColor]];
    [_panel setHasShadow:NO]; [_panel setFloatingPanel:YES]; [_panel setLevel:NSStatusWindowLevel + 3];
    [_panel setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary |
                                   NSWindowCollectionBehaviorIgnoresCycle)];
    [_panel setAccessibilityLabel:@"Window overview selection"];
    _view = [[HWMOverviewView alloc] initWithFrame:NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height)];
    [_view setWantsLayer:YES]; [[_view layer] setBackgroundColor:[[NSColor clearColor] CGColor]];
    [_view setOverview:self]; [_panel setContentView:_view];
}
- (void)installEscapeMonitor
{
    __block HorizontalWindowOverview *overview = self;
    if (_keyMonitor) return;
    _keyMonitor = [[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        NSString *characters = [event charactersIgnoringModifiers];
        if ([overview isVisible] && [characters length] && [characters characterAtIndex:0] == 0x1b) {
            [overview cancelFromOverlay]; return nil;
        }
        return event;
    }] retain];
}
- (void)removeEscapeMonitor
{
    if (!_keyMonitor) return;
    [NSEvent removeMonitor:_keyMonitor]; [_keyMonitor release]; _keyMonitor = nil;
}
- (void)clearSession
{
    [_windows release]; _windows = nil; [_selection release]; _selection = nil;
    [_cancellation release]; _cancellation = nil; _hovered = -1; _progress = 0.0;
    _closing = NO; _selectionSent = NO; _cancellationSent = NO;
    [_view setOutline:NSZeroRect visible:NO];
}
- (void)beginWithWindows:(NSArray *)windows screenFrame:(CGRect)frame
               selection:(void (^)(uint32_t wid, pid_t pid))selection
            cancellation:(void (^)(void))cancel
{
    NSAssert([NSThread isMainThread], @"Overview must begin on the main thread");
    [self dismissImmediately];
    if (!hwm_overview_valid_screen(frame)) return;
    _screenFrame = frame; [self buildPanelForScreenFrame:frame];
    _windows = [windows copy]; _selection = [selection copy]; _cancellation = [cancel copy];
    _progress = 0.0; _hovered = -1; _visible = YES;
    [_view setOutline:NSZeroRect visible:NO]; [self installEscapeMonitor];
    [_panel orderFront:nil]; [_panel makeKeyWindow];
}
- (void)setProgress:(double)progress
{
    if (!_visible || _closing) return;
    _progress = isfinite(progress) ? fmax(0.0, fmin(1.0, progress)) : 0.0;
    if (_hovered >= 0) [_view setOutline:NSZeroRect visible:NO];
    _hovered = -1;
}
- (NSInteger)hitWindowAt:(NSPoint)point frame:(HWMOverviewRect *)frameOut
{
    NSUInteger index;
    for (index = 0U; index < [_windows count]; ++index) {
        NSDictionary *window = [_windows objectAtIndex:index];
        HWMOverviewRect source, grid, current;
        if (![window isKindOfClass:[NSDictionary class]] || !hwm_overview_window_rect(window, @"source", &source) ||
            !hwm_overview_window_rect(window, @"grid", &grid)) continue;
        current = hwm_overview_flight(source, grid, _progress, _screenFrame.size.height);
        if (point.x >= current.x && point.x <= current.x + current.width && point.y >= current.y && point.y <= current.y + current.height) {
            if (frameOut) *frameOut = current;
            return (NSInteger)index;
        }
    }
    return -1;
}
- (void)mouseAt:(NSPoint)point
{
    HWMOverviewRect frame;
    NSInteger hit;
    if (!_visible || _closing) return;
    hit = [self hitWindowAt:point frame:&frame];
    if (hit == _hovered) return;
    _hovered = hit;
    if (hit >= 0) [_view setOutline:NSMakeRect(frame.x, frame.y, frame.width, frame.height) visible:YES];
    else [_view setOutline:NSZeroRect visible:NO];
}
- (void)clickAt:(NSPoint)point
{
    NSInteger hit; NSDictionary *window; uint32_t wid; pid_t pid; void (^selection)(uint32_t, pid_t);
    if (!_visible || _closing || _selectionSent || _cancellationSent) return;
    hit = [self hitWindowAt:point frame:NULL];
    if (hit < 0) { [self cancelFromOverlay]; return; }
    window = [_windows objectAtIndex:(NSUInteger)hit];
    wid = (uint32_t)[[window objectForKey:@"id"] unsignedIntValue]; pid = (pid_t)[[window objectForKey:@"pid"] intValue];
    if (wid == 0U || pid <= 0) { [self cancelFromOverlay]; return; }
    _selectionSent = YES; selection = [_selection copy];
    if (selection) { selection(wid, pid); [selection release]; }
}
- (void)cancelFromOverlay
{
    void (^cancellation)(void);
    if (!_visible || _closing || _selectionSent || _cancellationSent) return;
    _cancellationSent = YES; cancellation = [_cancellation copy];
    if (cancellation) { cancellation(); [cancellation release]; }
}
- (void)beginClosing
{
    if (!_visible || _closing) return;
    _closing = YES; _hovered = -1; [_view setOutline:NSZeroRect visible:NO];
}
- (void)dismissImmediately
{
    NSAssert([NSThread isMainThread], @"Overview must dismiss on the main thread");
    if (!_visible) return;
    _visible = NO; [self removeEscapeMonitor]; [_panel orderOut:nil]; [self clearSession];
}
- (BOOL)isVisible { return _visible; }
@end
