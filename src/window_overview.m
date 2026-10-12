/* Transparent selection surface for WindowServer-owned overview transforms. */

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <math.h>
#include "overview_geometry.h"

@class HorizontalWindowOverview;

/* Written by the runtime before an overview opens; read on the main queue. */
static double hwm_overview_scrim_strength=.38, hwm_overview_fade_duration=.3;
static const double HWMOverviewHoverScale=1.035;

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
    CAShapeLayer *_oldHalo;
    CAShapeLayer *_oldStroke;
    NSString *_search;
    CALayer *_label;
    CALayer *_labelIcon;
    CATextLayer *_labelText;
    CATextLayer *_hint;
}
- (void)showHint:(BOOL)visible;
- (void)setOverview:(HorizontalWindowOverview *)overview;
- (void)setOutline:(NSRect)outline visible:(BOOL)visible;
- (void)setLabel:(NSString *)text icon:(NSImage *)icon card:(NSRect)card visible:(BOOL)visible;
- (void)setSearch:(NSString *)search;
@end

@interface HorizontalWindowOverview : NSObject {
@private
    HWMOverviewPanel *_panel;
    HWMOverviewView *_view;
    NSArray *_windows;
    CGRect _screenFrame;
    double _progress;
    NSInteger _hovered;
    NSInteger _selected;
    NSString *_query;
    void (^_selection)(uint32_t wid, pid_t pid);
    void (^_cancellation)(void);
    id _keyMonitor;
    BOOL _visible;
    BOOL _closing;
    BOOL _selectionSent;
    BOOL _cancellationSent;
    NSPanel *_scrim;
    NSInteger _pressed;
    NSPoint _pressPoint;
    BOOL _dragging;
    uint32_t _dragWid;
    uint64_t _session;
    uint32_t _highlighted;
    NSMutableDictionary *_icons;
    void (^_highlight)(uint32_t wid);
    void (^_filter)(NSArray *dimmed);
    void (^_drag)(uint32_t wid, int phase, NSPoint point);
}
/* Optional observers, kept across sessions. Each is called on the main queue. */
- (void)setHighlightHandler:(void (^)(uint32_t wid))handler;
- (void)setFilterHandler:(void (^)(NSArray *dimmed))handler;
/* phase 0 begins, 1 moves, 2 drops. Points are overlay-local, top-left origin. */
- (void)setDragHandler:(void (^)(uint32_t wid, int phase, NSPoint point))handler;
/* Replace the cards after the strip was rearranged from inside the overview. */
- (void)updateWindows:(NSArray *)windows;
/* A title fetched after the overview opened; search and the label pick it up. */
- (void)setTitle:(NSString *)title forWindow:(uint32_t)wid;
+ (HorizontalWindowOverview *)sharedOverview;
- (void)beginWithWindows:(NSArray *)windows screenFrame:(CGRect)frame
               selection:(void (^)(uint32_t wid, pid_t pid))selection
            cancellation:(void (^)(void))cancel;
- (void)setProgress:(double)progress;
- (void)beginClosing;
- (void)dismissImmediately;
- (BOOL)isVisible;
/* Forward keyboard input here on the main queue when the CG event tap owns it. */
- (BOOL)keyEvent:(NSEvent *)event;
- (BOOL)keyCode:(unsigned short)keyCode characters:(NSString *)characters
       modifiers:(NSEventModifierFlags)modifiers;
@end

@interface HorizontalWindowOverview (Input)
- (void)mouseAt:(NSPoint)point;
- (void)clickAt:(NSPoint)point;
- (void)pressAt:(NSPoint)point;
- (void)dragAt:(NSPoint)point;
- (void)releaseAt:(NSPoint)point;
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
    /* The flip is about the primary display, which anchors the global
     * coordinate space; mainScreen is merely wherever the key window is. */
    NSScreen *screen = [[NSScreen screens] firstObject] ?: [NSScreen mainScreen];
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
        _oldHalo=[[CAShapeLayer alloc] init]; _oldStroke=[[CAShapeLayer alloc] init];
        for(CAShapeLayer *outline in @[_oldHalo,_oldStroke,_halo,_stroke]) {
            outline.frame=self.bounds; outline.autoresizingMask=kCALayerWidthSizable|kCALayerHeightSizable;
            outline.fillColor=NSColor.clearColor.CGColor; outline.opacity=0;
            [self.layer addSublayer:outline];
        }
        _halo.lineWidth=5; _halo.strokeColor=[NSColor colorWithCalibratedRed:.31 green:.64 blue:1 alpha:.20].CGColor;
        _stroke.lineWidth=1.5; _stroke.strokeColor=[NSColor colorWithCalibratedRed:.40 green:.72 blue:1 alpha:.95].CGColor;
        _oldHalo.lineWidth=_halo.lineWidth; _oldHalo.strokeColor=_halo.strokeColor;
        _oldStroke.lineWidth=_stroke.lineWidth; _oldStroke.strokeColor=_stroke.strokeColor;
        _label=[[CALayer alloc] init]; _labelIcon=[[CALayer alloc] init]; _labelText=[[CATextLayer alloc] init];
        _label.backgroundColor=[NSColor colorWithCalibratedWhite:0 alpha:.66].CGColor; _label.cornerRadius=13; _label.opacity=0;
        _label.borderWidth=1; _label.borderColor=[NSColor colorWithCalibratedWhite:1 alpha:.12].CGColor;
        _labelIcon.contentsGravity=kCAGravityResizeAspect;
        _labelText.fontSize=12.5; _labelText.font=(__bridge CFTypeRef)[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
        _labelText.foregroundColor=NSColor.whiteColor.CGColor; _labelText.truncationMode=kCATruncationEnd;
        _labelText.contentsScale=[[NSScreen mainScreen] backingScaleFactor] ?: 2.0;
        [_label addSublayer:_labelIcon]; [_label addSublayer:_labelText]; [self.layer addSublayer:_label];
        /* One quiet line that says what the overview does, then gets out of the way. */
        _hint=[[CATextLayer alloc] init];
        _hint.string=@"click to go  ·  drag to move  ·  ⇧ ← → to move  ·  type to search  ·  esc";
        _hint.fontSize=12.0; _hint.font=(__bridge CFTypeRef)[NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
        _hint.foregroundColor=[NSColor colorWithCalibratedWhite:1 alpha:.72].CGColor; _hint.alignmentMode=kCAAlignmentCenter;
        _hint.shadowColor=NSColor.blackColor.CGColor; _hint.shadowOpacity=.8; _hint.shadowRadius=4; _hint.shadowOffset=CGSizeZero;
        _hint.contentsScale=[[NSScreen mainScreen] backingScaleFactor] ?: 2.0; _hint.opacity=0;
        [self.layer addSublayer:_hint];
    }
    return self;
}
- (void)setOverview:(HorizontalWindowOverview *)overview { _overview = overview; }
- (void)setOutline:(NSRect)outline visible:(BOOL)visible
{
    if(_hasOutline==visible && (!visible || NSEqualRects(_outline,outline))) return;
    CGPathRef path=visible ? CGPathCreateWithRoundedRect(NSInsetRect(outline,1,1),10,10,NULL) : NULL;
    BOOL reduced=[[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion];
    CFTimeInterval duration=reduced ? 0.0 : .14;
    BOOL switched=visible && _hasOutline && !NSEqualRects(_outline, outline);
    /* Keep the old contour in a separate layer: unrelated cards crossfade. */
    if (switched) {
        for (NSUInteger index=0U; index<2U; ++index) {
            CAShapeLayer *from=@[_halo,_stroke][index];
            CAShapeLayer *old=@[_oldHalo,_oldStroke][index];
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            old.path=from.presentationLayer ? ((CAShapeLayer *)from.presentationLayer).path : from.path;
            old.opacity=1; [CATransaction commit];
            CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue=@1; fade.toValue=@0; fade.duration=duration;
            [old addAnimation:fade forKey:@"outline-old-opacity"];
            old.opacity=0;
        }
    }
    for(CAShapeLayer *shape in @[_halo,_stroke]) {
        CAShapeLayer *presentation=(CAShapeLayer *)shape.presentationLayer;
        CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue=@(switched ? 0 : (presentation ? presentation.opacity : shape.opacity));
        fade.toValue=@(visible?1:0); fade.duration=duration;
        fade.timingFunction=[CAMediaTimingFunction functionWithControlPoints:.22 :1 :.36 :1];
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        if(path) shape.path=path;
        shape.opacity=visible?1:0;
        [CATransaction commit];
        [shape addAnimation:fade forKey:@"outline-opacity"];
    }
    if(path) CGPathRelease(path);
    _outline=outline; _hasOutline=visible;
}
/* The selected card names itself: nothing is captioned until it is chosen. */
- (void)setLabel:(NSString *)text icon:(NSImage *)icon card:(NSRect)card visible:(BOOL)visible
{
    BOOL show=visible && [text length] && card.size.width>=90.0;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    if (show) {
        NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium]};
        CGFloat inset=icon ? 32.0 : 12.0;
        CGFloat width=fmin(card.size.width-16.0, ceil([text sizeWithAttributes:attributes].width)+inset+14.0);
        _label.frame=NSMakeRect(NSMidX(card)-width*.5, NSMaxY(card)-36.0, width, 26.0);
        _labelIcon.frame=NSMakeRect(8.0, 5.0, 16.0, 16.0); _labelIcon.contents=icon; _labelIcon.hidden=icon==nil;
        _labelText.frame=NSMakeRect(inset, 5.0, fmax(0.0, width-inset-10.0), 17.0); _labelText.string=text;
    }
    [CATransaction commit];
    [CATransaction begin]; [CATransaction setAnimationDuration:[[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion] ? 0.0 : .12];
    _label.opacity=show ? 1 : 0;
    [CATransaction commit];
}
- (void)showHint:(BOOL)visible
{
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _hint.frame=NSMakeRect(0.0, NSHeight(self.bounds)-30.0, NSWidth(self.bounds), 18.0);
    [CATransaction commit];
    [CATransaction begin]; [CATransaction setAnimationDuration:[[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion] ? 0.0 : .35];
    _hint.opacity=visible ? 1 : 0;
    [CATransaction commit];
}
- (void)setSearch:(NSString *)search
{
    if ((_search == search) || [_search isEqualToString:search]) return;
    [_search release]; _search=[search copy]; [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor clearColor] setFill];
    NSRectFillUsingOperation(dirtyRect, NSCompositingOperationCopy);
    if ([_search length]) {
        NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:15 weight:NSFontWeightMedium],
                                   NSForegroundColorAttributeName:NSColor.whiteColor};
        NSSize size=[_search sizeWithAttributes:attributes];
        NSRect pill=NSMakeRect((self.bounds.size.width-size.width-42.0)*.5, 24.0, size.width+42.0, size.height+18.0);
        [[NSColor colorWithCalibratedWhite:0 alpha:.70] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:12 yRadius:12] fill];
        [_search drawAtPoint:NSMakePoint(NSMinX(pill)+21.0, NSMinY(pill)+9.0) withAttributes:attributes];
    }
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
- (void)dealloc { [_halo release]; [_stroke release]; [_oldHalo release]; [_oldStroke release]; [_label release]; [_labelIcon release]; [_labelText release]; [_hint release]; [_search release]; [_trackingArea release]; [super dealloc]; }
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
    [self dismissImmediately]; [_panel release]; [_view release]; [_scrim release]; [_icons release];
    [_highlight release]; [_filter release]; [_drag release]; [super dealloc];
}
- (void)setHighlightHandler:(void (^)(uint32_t))handler { [_highlight release]; _highlight=[handler copy]; }
- (void)setFilterHandler:(void (^)(NSArray *))handler { [_filter release]; _filter=[handler copy]; }
- (void)setDragHandler:(void (^)(uint32_t, int, NSPoint))handler { [_drag release]; _drag=[handler copy]; }
- (NSImage *)iconForPID:(NSNumber *)pid
{
    if (!_icons) _icons=[[NSMutableDictionary alloc] init];
    NSImage *icon=[_icons objectForKey:pid];
    if (!icon) {
        icon=[[NSRunningApplication runningApplicationWithProcessIdentifier:[pid intValue]] icon];
        if (icon) { if ([_icons count] > 64U) [_icons removeAllObjects]; [_icons setObject:icon forKey:pid]; }
    }
    return icon;
}
/* A dark, blurred layer between the desktop and the windows. It sits below the
 * tiled level, so the live windows stay crisp and only the wallpaper recedes. */
- (void)buildScrimForScreenFrame:(CGRect)frame
{
    if (!_scrim) {
        _scrim=[[NSPanel alloc] initWithContentRect:hwm_overview_panel_frame(frame)
                                          styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                                            backing:NSBackingStoreBuffered defer:NO];
        [_scrim setOpaque:NO]; [_scrim setBackgroundColor:[NSColor clearColor]]; [_scrim setHasShadow:NO];
        [_scrim setIgnoresMouseEvents:YES]; [_scrim setLevel:CGWindowLevelForKey(kCGBackstopMenuLevelKey)-1];
        [_scrim setCollectionBehavior:(NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle)];
        NSVisualEffectView *blur=[[[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)] autorelease];
        blur.material=NSVisualEffectMaterialFullScreenUI; blur.blendingMode=NSVisualEffectBlendingModeBehindWindow; blur.state=NSVisualEffectStateActive;
        blur.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        NSView *tint=[[[NSView alloc] initWithFrame:blur.bounds] autorelease];
        tint.wantsLayer=YES; tint.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        [blur addSubview:tint]; [_scrim setContentView:blur];
    }
    [_scrim setFrame:hwm_overview_panel_frame(frame) display:NO];
    NSView *tint=[[[_scrim contentView] subviews] firstObject];
    tint.layer.backgroundColor=[[NSColor colorWithCalibratedWhite:0 alpha:fmax(0.0, fmin(.85, hwm_overview_scrim_strength))] CGColor];
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
- (void)installKeyMonitor
{
    __block HorizontalWindowOverview *overview = self;
    if (_keyMonitor) return;
    _keyMonitor = [[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if ([overview isVisible] && [overview keyEvent:event]) return nil;
        return event;
    }] retain];
}
- (void)removeKeyMonitor
{
    if (!_keyMonitor) return;
    [NSEvent removeMonitor:_keyMonitor]; [_keyMonitor release]; _keyMonitor = nil;
}
- (void)clearSession
{
    [_windows release]; _windows = nil; [_selection release]; _selection = nil;
    [_cancellation release]; _cancellation = nil; [_query release]; _query=nil; _hovered = -1; _selected = -1; _progress = 0.0;
    _closing = NO; _selectionSent = NO; _cancellationSent = NO; _pressed = -1; _dragging = NO; _highlighted = 0U;
    [_view setOutline:NSZeroRect visible:NO]; [_view setLabel:nil icon:nil card:NSZeroRect visible:NO];
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
    _progress = 0.0; _hovered = -1; _selected = -1; _pressed = -1; _dragging = NO; _highlighted = 0U; _visible = YES;
    [_view setOutline:NSZeroRect visible:NO]; [_view setSearch:nil]; [self installKeyMonitor];
    if (hwm_overview_scrim_strength > 0.0) { [self buildScrimForScreenFrame:frame]; [_scrim setAlphaValue:0.0]; [_scrim orderFront:nil]; }
    [_panel orderFront:nil]; [_panel makeKeyWindow];
    /* Start on the window in use, so Return and the arrows begin from it. */
    for (NSUInteger index=0U; index<[_windows count]; ++index)
        if ([[[_windows objectAtIndex:index] objectForKey:@"focused"] boolValue]) _selected=(NSInteger)index;
    uint64_t session=++_session;
    [_view showHint:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if (_session==session) [_view showHint:NO];
    });
}
- (void)setProgress:(double)progress
{
    if (!_visible || _closing) return;
    _progress = isfinite(progress) ? fmax(0.0, fmin(1.0, progress)) : 0.0;
    [_scrim setAlphaValue:_progress];
    if (_selected >= 0) [self updateOutline];
}
- (NSInteger)hitWindowAt:(NSPoint)point frame:(HWMOverviewRect *)frameOut
{
    /* The nearest card within a small margin counts: a click that lands in the
     * gap beside a card means that card, not "cancel". */
    NSUInteger index; NSInteger best=-1; double nearest=28.0;
    for (index = 0U; index < [_windows count]; ++index) {
        NSDictionary *window = [_windows objectAtIndex:index];
        HWMOverviewRect source, grid, current;
        if (![self matchesQueryAtIndex:index] || ![window isKindOfClass:[NSDictionary class]] || !hwm_overview_window_rect(window, @"source", &source) ||
            !hwm_overview_window_rect(window, @"grid", &grid)) continue;
        current = hwm_overview_flight(source, grid, _progress, _screenFrame.size.height);
        double dx=fmax(current.x-point.x, fmax(0.0, point.x-(current.x+current.width)));
        double dy=fmax(current.y-point.y, fmax(0.0, point.y-(current.y+current.height)));
        double distance=hypot(dx,dy);
        if (distance < nearest) { nearest=distance; best=(NSInteger)index; if (frameOut) *frameOut = current; }
        if (distance == 0.0) break;
    }
    return best;
}
- (BOOL)matchesQueryAtIndex:(NSUInteger)index
{
    NSDictionary *window=[_windows objectAtIndex:index];
    if (![_query length]) return YES;
    NSString *title=[window objectForKey:@"title"];
    NSString *app=[window objectForKey:@"app"];
    return ([title isKindOfClass:[NSString class]] && [title rangeOfString:_query options:NSCaseInsensitiveSearch].location != NSNotFound) ||
           ([app isKindOfClass:[NSString class]] && [app rangeOfString:_query options:NSCaseInsensitiveSearch].location != NSNotFound);
}
- (void)updateOutline
{
    HWMOverviewRect frame; uint32_t wid=0U;
    if (!_dragging && _selected >= 0 && (NSUInteger)_selected < [_windows count] && [self matchesQueryAtIndex:(NSUInteger)_selected] &&
        [self frameForWindowAtIndex:(NSUInteger)_selected frame:&frame]) {
        NSDictionary *window=[_windows objectAtIndex:(NSUInteger)_selected];
        /* The chosen card lifts slightly; the outline is drawn where it lands. */
        frame=hwm_overview_inflate(frame, 1.0+(HWMOverviewHoverScale-1.0)*_progress);
        NSRect card=NSMakeRect(frame.x,frame.y,frame.width,frame.height);
        NSString *title=[window objectForKey:@"title"], *app=[window objectForKey:@"app"];
        NSString *text=[title isKindOfClass:[NSString class]] && [title length] ? title : ([app isKindOfClass:[NSString class]] ? app : @"");
        [_view setOutline:card visible:YES];
        [_view setLabel:text icon:[self iconForPID:[window objectForKey:@"pid"]] card:card visible:_progress > .6];
        wid=(uint32_t)[[window objectForKey:@"id"] unsignedIntValue];
    } else {
        [_view setOutline:NSZeroRect visible:NO]; [_view setLabel:nil icon:nil card:NSZeroRect visible:NO];
    }
    if (wid != _highlighted) { _highlighted=wid; if (_highlight) _highlight(wid); }
}
/* Tell the runtime which cards the search no longer matches, so it can dim them. */
- (void)publishFilter
{
    if (!_filter) return;
    NSMutableArray *dimmed=[NSMutableArray array];
    for (NSUInteger index=0U; index<[_windows count]; ++index)
        if (![self matchesQueryAtIndex:index]) [dimmed addObject:[[_windows objectAtIndex:index] objectForKey:@"id"] ?: @0];
    _filter(dimmed);
}
- (void)setTitle:(NSString *)title forWindow:(uint32_t)wid
{
    if (!_visible || _closing || ![title length]) return;
    NSMutableArray *windows=[NSMutableArray arrayWithArray:_windows];
    for (NSUInteger index=0U; index<[windows count]; ++index) {
        NSDictionary *window=[windows objectAtIndex:index];
        if ([[window objectForKey:@"id"] unsignedIntValue] != wid) continue;
        NSMutableDictionary *updated=[NSMutableDictionary dictionaryWithDictionary:window];
        [updated setObject:title forKey:@"title"]; [windows replaceObjectAtIndex:index withObject:updated];
        [_windows release]; _windows=[windows copy];
        if ([_query length]) [self publishFilter];
        if ((NSInteger)index == _selected) [self updateOutline];
        return;
    }
}
- (void)updateWindows:(NSArray *)windows
{
    if (!_visible || _closing) return;
    uint32_t selected=_highlighted;
    [_windows release]; _windows=[windows copy]; _selected=-1; _hovered=-1;
    for (NSUInteger index=0U; selected && index<[_windows count]; ++index)
        if ([[[_windows objectAtIndex:index] objectForKey:@"id"] unsignedIntValue]==selected) _selected=(NSInteger)index;
    _highlighted=0U; /* Report the selection again: the runtime's cards were rebuilt too. */
    [self updateOutline];
}
- (BOOL)frameForWindowAtIndex:(NSUInteger)index frame:(HWMOverviewRect *)frameOut
{
    NSDictionary *window; HWMOverviewRect source, grid;
    if (index >= [_windows count]) return NO;
    window=[_windows objectAtIndex:index];
    if (![window isKindOfClass:[NSDictionary class]] || !hwm_overview_window_rect(window,@"source",&source) ||
        !hwm_overview_window_rect(window,@"grid",&grid)) return NO;
    if (frameOut) *frameOut=hwm_overview_flight(source,grid,_progress,_screenFrame.size.height);
    return YES;
}
- (void)mouseAt:(NSPoint)point
{
    NSInteger hit;
    if (!_visible || _closing || _dragging) return;
    hit = [self hitWindowAt:point frame:NULL];
    if (hit == _hovered) return;
    _hovered = hit; _selected = hit;
    [self updateOutline];
}
- (void)chooseIndex:(NSInteger)hit
{
    NSDictionary *window; uint32_t wid; pid_t pid; void (^selection)(uint32_t, pid_t);
    if (hit < 0) { [self cancelFromOverlay]; return; }
    _selected = hit;
    window = [_windows objectAtIndex:(NSUInteger)hit];
    wid = (uint32_t)[[window objectForKey:@"id"] unsignedIntValue]; pid = (pid_t)[[window objectForKey:@"pid"] intValue];
    if (wid == 0U || pid <= 0) { [self cancelFromOverlay]; return; }
    _selectionSent = YES; selection = [_selection copy];
    if (selection) { selection(wid, pid); [selection release]; }
}
- (void)clickAt:(NSPoint)point
{
    if (!_visible || _closing || _selectionSent || _cancellationSent) return;
    [self chooseIndex:[self hitWindowAt:point frame:NULL]];
}
/* A press that travels becomes a drag to rearrange; one that does not is a click. */
- (void)pressAt:(NSPoint)point
{
    if (!_visible || _closing || _selectionSent || _cancellationSent) return;
    _pressed=[self hitWindowAt:point frame:NULL]; _pressPoint=point; _dragging=NO;
    if (_pressed < 0) [self cancelFromOverlay];
}
- (void)dragAt:(NSPoint)point
{
    if (!_visible || _closing || _selectionSent || _cancellationSent || _pressed < 0 || (NSUInteger)_pressed >= [_windows count]) return;
    /* Cards are re-ordered under a drag, so the carried one is known by id. */
    uint32_t wid=_dragging ? _dragWid : (uint32_t)[[[_windows objectAtIndex:(NSUInteger)_pressed] objectForKey:@"id"] unsignedIntValue];
    if (!_dragging) {
        if (!_drag || _progress < .9 || hypot(point.x-_pressPoint.x, point.y-_pressPoint.y) < 5.0) return;
        _dragging=YES; _dragWid=wid; _selected=_pressed; _hovered=-1; [_view showHint:NO];
        [self updateOutline]; /* hides the outline and label while the card is carried */
        _drag(wid, 0, _pressPoint);
    }
    _drag(wid, 1, point);
}
- (void)releaseAt:(NSPoint)point
{
    if (!_visible || _closing || _selectionSent || _cancellationSent) { _pressed=-1; _dragging=NO; return; }
    NSInteger pressed=_pressed; _pressed=-1;
    if (_dragging) {
        _dragging=NO; _highlighted=_dragWid;
        if (_drag) _drag(_dragWid, 2, point);
        return;
    }
    if (pressed >= 0 && [self hitWindowAt:point frame:NULL] == pressed) [self chooseIndex:pressed];
}
- (void)selectRelativeToCurrent:(NSInteger)direction
{
    NSInteger count=(NSInteger)[_windows count];
    NSInteger candidate=_selected;
    if (count <= 0) return;
    for (NSInteger attempts=0; attempts<count; ++attempts) {
        candidate=(candidate < 0) ? (direction > 0 ? 0 : count-1) : (candidate + direction + count) % count;
        if ([self matchesQueryAtIndex:(NSUInteger)candidate]) { _selected=candidate; _hovered=-1; [self updateOutline]; return; }
    }
    _selected=-1; [self updateOutline];
}
- (void)activateSelection
{
    NSDictionary *window; uint32_t wid; pid_t pid; void (^selection)(uint32_t,pid_t);
    if (_selected < 0 || (NSUInteger)_selected >= [_windows count]) return;
    window=[_windows objectAtIndex:(NSUInteger)_selected];
    wid=(uint32_t)[[window objectForKey:@"id"] unsignedIntValue]; pid=(pid_t)[[window objectForKey:@"pid"] intValue];
    if (!wid || pid <= 0 || _selectionSent || _cancellationSent) return;
    _selectionSent=YES; selection=[_selection copy];
    if (selection) { selection(wid,pid); [selection release]; }
}
/* Arrow keys follow the cards as laid out: down goes down a row. */
- (void)selectDirectionX:(int)dx y:(int)dy
{
    NSUInteger count=[_windows count];
    if (!count) return;
    if (_selected < 0 || (NSUInteger)_selected >= count || ![self matchesQueryAtIndex:(NSUInteger)_selected]) {
        [self selectRelativeToCurrent:(dx+dy > 0 ? 1 : -1)]; return;
    }
    HWMOverviewRect *cards=calloc(count, sizeof(*cards)); bool *eligible=calloc(count, sizeof(*eligible));
    if (cards && eligible) {
        for (NSUInteger index=0U; index<count; ++index) {
            HWMOverviewRect grid;
            eligible[index]=[self matchesQueryAtIndex:index] && hwm_overview_window_rect([_windows objectAtIndex:index], @"grid", &grid);
            if (eligible[index]) cards[index]=grid;
        }
        size_t next=eligible[_selected] ? hwm_overview_neighbor(cards, count, (size_t)_selected, dx, dy, eligible) : count;
        if (next < count) { _selected=(NSInteger)next; _hovered=-1; [self updateOutline]; }
    }
    free(cards); free(eligible);
}
- (BOOL)keyEvent:(NSEvent *)event
{
    if (!event || [event type] != NSEventTypeKeyDown) return NO;
    return [self keyCode:[event keyCode] characters:[event characters] modifiers:[event modifierFlags]];
}
- (BOOL)keyCode:(unsigned short)keyCode characters:(NSString *)characters modifiers:(NSEventModifierFlags)modifiers
{
    unichar character=([characters length] ? [characters characterAtIndex:0] : 0);
    if (!_visible || _closing || _selectionSent || _cancellationSent) return NO;
    if ((keyCode == 53 || character == 0x1b) && _dragging) {
        /* Escape while carrying a card puts the strip back; the overview stays. */
        _dragging=NO; _pressed=-1; _highlighted=_dragWid;
        if (_drag) _drag(_dragWid, 5, NSZeroPoint);
        return YES;
    }
    if ((modifiers & NSEventModifierFlagShift) && (keyCode == 123 || keyCode == 124) && !_dragging) {
        /* Shift with an arrow moves the chosen window instead of the selection. */
        if (_drag && _selected >= 0 && (NSUInteger)_selected < [_windows count])
            _drag((uint32_t)[[[_windows objectAtIndex:(NSUInteger)_selected] objectForKey:@"id"] unsignedIntValue], keyCode == 123 ? 3 : 4, NSZeroPoint);
        [_view showHint:NO];
        return YES;
    }
    if (keyCode == 53 || character == 0x1b) {
        if ([_query length]) { [_query release]; _query=nil; [_view setSearch:nil]; _selected=-1; [self updateOutline]; [self publishFilter]; }
        else [self cancelFromOverlay];
        return YES;
    }
    if (keyCode == 36 || keyCode == 76 || character == '\r' || character == '\n') { [self activateSelection]; return YES; }
    if (_dragging) return YES;
    if (keyCode == 123) { [self selectDirectionX:-1 y:0]; return YES; }
    if (keyCode == 124) { [self selectDirectionX:1 y:0]; return YES; }
    if (keyCode == 126) { [self selectDirectionX:0 y:-1]; return YES; }
    if (keyCode == 125) { [self selectDirectionX:0 y:1]; return YES; }
    if ((modifiers & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption)) == 0 &&
        [characters length] && character >= 0x20 && character != 0x7f) {
        NSString *next=[(_query ?: @"") stringByAppendingString:characters];
        [_query release]; _query=[next copy]; [_view setSearch:_query]; _selected=-1; [self selectRelativeToCurrent:1]; [self publishFilter];
        return YES;
    }
    if (keyCode == 51 || character == 0x08 || character == 0x7f) {
        if ([_query length]) {
            NSString *next=[_query substringToIndex:[_query length]-1U];
            [_query release]; _query=[next copy]; [_view setSearch:_query]; _selected=-1; [self selectRelativeToCurrent:1]; [self publishFilter];
        }
        return YES;
    }
    return NO;
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
    _closing = YES; _hovered = -1; _selected = -1; _dragging = NO; _pressed = -1; ++_session; [_view showHint:NO];
    [_view setOutline:NSZeroRect visible:NO]; [_view setLabel:nil icon:nil card:NSZeroRect visible:NO]; [_view setSearch:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration=[[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion] ? 0.0 : hwm_overview_fade_duration;
        [[_scrim animator] setAlphaValue:0.0];
    } completionHandler:nil];
}
- (void)dismissImmediately
{
    NSAssert([NSThread isMainThread], @"Overview must dismiss on the main thread");
    if (!_visible) return;
    _visible = NO; [self removeKeyMonitor]; [_panel orderOut:nil]; [_scrim orderOut:nil]; [self clearSession];
}
- (BOOL)isVisible { return _visible; }
@end
