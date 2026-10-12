/* Passive, click-through feedback. AppKit is confined to the main queue. */
#include <libproc.h>

/* Border settings are written by the config runtime on the event loop and read
 * into each snapshot there; the main queue only ever sees the snapshot. */
static int hwm_border_mode=2; /* 0 off, 1 on, 2 auto: on unless an external border tool runs */
static double hwm_border_width=2, hwm_border_radius=12;
static double hwm_border_active[4]={.40,.72,1,1}, hwm_border_active_end[4]={.71,.55,1,1}, hwm_border_inactive[4]={1,1,1,.14};
static unsigned hwm_border_generation;
static _Atomic bool hwm_borders_external; /* an external border tool is running */
static bool hwm_border_on(void) { return hwm_border_mode==1 || (hwm_border_mode==2 && !hwm_borders_external); }

static bool hwm_external_borders_running(void)
{
    int bytes=proc_listallpids(NULL,0);
    if(bytes<=0) return false;
    pid_t *pids=calloc((size_t)bytes+64,sizeof(pid_t));
    if(!pids) return false;
    int count=proc_listallpids(pids,(int)(((size_t)bytes+64)*sizeof(pid_t)));
    bool found=false;
    for(int i=0;i<count && !found;i++) {
        char name[64]={0};
        if(proc_name(pids[i],name,sizeof(name))>0 && strcmp(name,"borders")==0) found=true;
    }
    free(pids);
    return found;
}

/* Main-thread cost of overlay refreshes, reported by `status`. */
static _Atomic uint64_t hwm_feedback_shows;
static _Atomic double hwm_feedback_show_max_ms;

/* Walking the process table takes tens of milliseconds, far too long for a
 * frame. It is refreshed in the background and frames read the last answer. */
static void hwm_external_borders_refresh(void)
{
    static _Atomic bool scanning;
    bool expected=false;
    if(!atomic_compare_exchange_strong(&scanning,&expected,true)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        bool found=hwm_external_borders_running();
        if(found!=hwm_borders_external) { hwm_borders_external=found; hwm_wake(); }
        scanning=false;
    });
}

static NSColor *hwm_color(NSArray *rgba)
{
    return [NSColor colorWithSRGBRed:[rgba[0] doubleValue] green:[rgba[1] doubleValue] blue:[rgba[2] doubleValue] alpha:[rgba[3] doubleValue]];
}

@interface TanaFeedback : NSObject
@property(nonatomic,retain) NSPanel *panel;
@property(nonatomic,retain) CAGradientLayer *focus;
@property(nonatomic,retain) CAShapeLayer *focusMask;
@property(nonatomic,retain) CAShapeLayer *inactive;
@property(nonatomic,retain) CALayer *mapBack;
@property(nonatomic,retain) CAShapeLayer *map;
@property(nonatomic,retain) CAShapeLayer *mapFocus;
@property(nonatomic,retain) CAShapeLayer *mapView;
@property(nonatomic,retain) CAShapeLayer *wall;
@property(nonatomic,retain) CALayer *tabs;
@property(nonatomic,retain) CAShapeLayer *drag;
@property(nonatomic) uint64_t generation;
@property(nonatomic,retain) NSArray *tabTargets;
@property(nonatomic,copy) NSString *tabSignature;
@property(nonatomic,retain) NSMutableDictionary *icons;
@property(nonatomic) CGRect screen;
@property(nonatomic) BOOL hasFocus;
- (NSDictionary *)tabAt:(CGPoint)point;
+ (instancetype)shared;
- (void)show:(NSDictionary *)state;
- (void)hide;
@end
@implementation TanaFeedback
+ (instancetype)shared { static TanaFeedback *instance; if(!instance) instance=[TanaFeedback new]; return instance; }
- (void)hide { if(!self.panel.visible && !self.tabTargets) return; [self.panel orderOut:nil]; self.tabTargets=nil; self.generation++; }
- (NSDictionary *)tabAt:(CGPoint)point {
    if(!self.panel.visible) return nil;
    point.x-=self.screen.origin.x; point.y-=self.screen.origin.y;
    for(NSDictionary *tab in self.tabTargets) if(CGRectContainsPoint([tab[@"rect"] rectValue],point)) return tab;
    return nil;
}
- (NSImage *)iconFor:(NSNumber *)pid
{
    if(!self.icons) self.icons=[NSMutableDictionary dictionary];
    NSImage *icon=self.icons[pid];
    if(!icon) {
        icon=[[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue] icon];
        if(icon) { if(self.icons.count>64) [self.icons removeAllObjects]; self.icons[pid]=icon; }
    }
    return icon;
}
- (void)build
{
    self.panel=[[[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO] autorelease];
    self.panel.opaque=NO; self.panel.backgroundColor=NSColor.clearColor; self.panel.hasShadow=NO;
    self.panel.ignoresMouseEvents=YES; self.panel.level=NSFloatingWindowLevel;
    self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary;
    self.panel.contentView.wantsLayer=YES;
    CALayer *root=self.panel.contentView.layer;
    self.inactive=[CAShapeLayer layer]; self.focusMask=[CAShapeLayer layer]; self.focus=[CAGradientLayer layer];
    self.map=[CAShapeLayer layer]; self.mapFocus=[CAShapeLayer layer]; self.mapView=[CAShapeLayer layer]; self.mapBack=[CALayer layer];
    self.wall=[CAShapeLayer layer]; self.tabs=[CALayer layer]; self.drag=[CAShapeLayer layer];
    for(CAShapeLayer *shape in @[self.inactive,self.focusMask,self.mapView,self.drag]) shape.fillColor=NSColor.clearColor.CGColor;
    self.focusMask.strokeColor=NSColor.whiteColor.CGColor;
    self.focus.startPoint=CGPointMake(0,1); self.focus.endPoint=CGPointMake(1,0); self.focus.mask=self.focusMask; self.focus.opacity=0;
    self.mapBack.backgroundColor=[NSColor colorWithCalibratedWhite:0 alpha:.5].CGColor; self.mapBack.cornerRadius=11; self.mapBack.opacity=0;
    self.map.fillColor=[NSColor colorWithCalibratedWhite:1 alpha:.38].CGColor;
    self.mapView.strokeColor=[NSColor colorWithCalibratedWhite:1 alpha:.9].CGColor; self.mapView.lineWidth=1.5;
    self.wall.fillColor=[NSColor colorWithCalibratedRed:.4 green:.72 blue:1 alpha:.9].CGColor; self.wall.opacity=0;
    self.drag.strokeColor=[NSColor colorWithCalibratedWhite:0 alpha:.14].CGColor;
    self.drag.lineWidth=3; self.drag.shadowColor=NSColor.blackColor.CGColor;
    self.drag.shadowOpacity=.3; self.drag.shadowRadius=10; self.drag.shadowOffset=CGSizeMake(0,-3);
    for(CALayer *layer in @[self.drag,self.inactive,self.focus,self.tabs,self.mapBack,self.wall]) [root addSublayer:layer];
    for(CALayer *layer in @[self.map,self.mapFocus,self.mapView]) [self.mapBack addSublayer:layer];
}
/* Top-left screen-local rect to this panel's bottom-left layer coordinates. */
- (CGRect)flip:(CGRect)r { r.origin.y=self.screen.size.height-CGRectGetMaxY(r); return r; }
- (void)layoutTabs:(NSArray *)tabs
{
    NSMutableString *signature=[NSMutableString string];
    for(NSDictionary *tab in tabs) [signature appendFormat:@"%@:%@:%@|",tab[@"id"],tab[@"active"],tab[@"title"]];
    BOOL rebuild=![signature isEqual:self.tabSignature];
    if(rebuild) {
        self.tabSignature=signature;
        self.tabs.sublayers=nil;
        CGFloat scale=self.panel.backingScaleFactor ?: 2;
        for(NSDictionary *tab in tabs) {
            BOOL active=[tab[@"active"] boolValue];
            CALayer *pill=[CALayer layer]; pill.cornerRadius=8;
            pill.backgroundColor=[NSColor colorWithCalibratedWhite:active?.26:.10 alpha:active?.92:.72].CGColor;
            pill.borderWidth=1; pill.borderColor=(active ? [NSColor colorWithSRGBRed:hwm_border_active[0] green:hwm_border_active[1] blue:hwm_border_active[2] alpha:.9] : [NSColor colorWithCalibratedWhite:1 alpha:.10]).CGColor;
            CALayer *icon=[CALayer layer]; icon.frame=CGRectMake(8,4,16,16); icon.contents=[self iconFor:tab[@"pid"]]; icon.contentsGravity=kCAGravityResizeAspect;
            CATextLayer *text=[CATextLayer layer]; text.string=tab[@"title"]; text.fontSize=12; text.font=(__bridge CFTypeRef)[NSFont systemFontOfSize:12 weight:active?NSFontWeightMedium:NSFontWeightRegular];
            text.foregroundColor=[NSColor colorWithCalibratedWhite:1 alpha:active?1:.62].CGColor; text.truncationMode=kCATruncationEnd; text.contentsScale=scale;
            [pill addSublayer:icon]; [pill addSublayer:text]; [self.tabs addSublayer:pill];
        }
    }
    NSUInteger index=0;
    for(NSDictionary *tab in tabs) {
        if(index>=self.tabs.sublayers.count) break;
        CALayer *pill=self.tabs.sublayers[index++];
        CGRect r=[self flip:[tab[@"rect"] rectValue]];
        pill.frame=r;
        ((CALayer *)pill.sublayers[1]).frame=CGRectMake(30,3,fmax(0,r.size.width-38),17);
    }
}
- (void)show:(NSDictionary *)state
{
    CGRect screen=[state[@"screen"] rectValue];
    double began=CACurrentMediaTime();
    if(!self.panel) [self build];
    // This runs on the thread that also carries every pointer event, so it
    // does nothing it does not have to: the frame is only set when it changes.
    if(!CGRectEqualToRect(screen,self.screen)) [self.panel setFrame:hwm_overview_panel_frame(screen) display:NO];
    self.screen=screen; self.tabTargets=state[@"tabs"];
    double height=screen.size.height;
    BOOL reduce=[NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.focus.frame=CGRectMake(0,0,screen.size.width,height); self.focusMask.frame=self.focus.frame;
    self.tabs.frame=self.focus.frame;

    /* Strip map: every column, the focused one accented, and the viewport. */
    NSArray *rects=state[@"columns"];
    double total=fmax([state[@"total"] doubleValue],1), mapWidth=fmin(260,screen.size.width*.3), scale=(mapWidth-16)/total;
    self.mapBack.frame=CGRectMake((screen.size.width-mapWidth)/2,22,mapWidth,22);
    CGMutablePathRef map=CGPathCreateMutable(), mapFocus=CGPathCreateMutable();
    for(NSValue *value in rects) {
        CGRect f=[value rectValue];
        CGPathAddRoundedRect(f.size.height>1 ? mapFocus : map,NULL,CGRectMake(8+f.origin.x*scale,8,fmax(2,f.size.width*scale-1.5),6),1.5,1.5);
    }
    self.map.path=map; self.mapFocus.path=mapFocus; CGPathRelease(map); CGPathRelease(mapFocus);
    self.mapFocus.fillColor=hwm_color(state[@"active"]).CGColor;
    double viewLeft=fmax(0,fmin(total,[state[@"offset"] doubleValue])), viewRight=fmax(viewLeft,fmin(total,[state[@"offset"] doubleValue]+[state[@"viewport"] doubleValue]));
    CGPathRef viewport=CGPathCreateWithRoundedRect(CGRectMake(8+viewLeft*scale-2,4,fmax(6,(viewRight-viewLeft)*scale+4),14),3,3,NULL);
    self.mapView.path=viewport; CGPathRelease(viewport);
    BOOL showMap=[state[@"map"] boolValue];
    CGPathRef edge=CGPathCreateWithRoundedRect([state[@"wallRight"] boolValue] ? CGRectMake(screen.size.width-5,20,3,height-40) : CGRectMake(2,20,3,height-40),1.5,1.5,NULL);
    self.wall.path=edge; CGPathRelease(edge);
    BOOL showWall=[state[@"wall"] boolValue];

    [self layoutTabs:state[@"tabs"]];

    if(state[@"drag"]) {
        CGRect f=[state[@"drag"] rectValue]; f.origin.x-=screen.origin.x; f.origin.y-=screen.origin.y;
        CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset([self flip:f],-1,-1),10,10,NULL);
        self.drag.path=path; CGPathRelease(path); self.drag.opacity=1;
    } else self.drag.opacity=0;

    /* Borders: a quiet outline on every visible tile and a gradient on the focused one. */
    double width=[state[@"borderWidth"] doubleValue], radius=[state[@"borderRadius"] doubleValue];
    CGMutablePathRef others=CGPathCreateMutable();
    for(NSValue *value in state[@"others"]) {
        CGRect f=[value rectValue]; f.origin.x-=screen.origin.x; f.origin.y-=screen.origin.y;
        CGPathAddRoundedRect(others,NULL,CGRectInset([self flip:f],width*.5,width*.5),radius,radius);
    }
    self.inactive.path=others; CGPathRelease(others);
    self.inactive.lineWidth=width; self.inactive.strokeColor=hwm_color(state[@"inactive"]).CGColor;
    self.focus.colors=@[(id)hwm_color(state[@"active"]).CGColor,(id)hwm_color(state[@"activeEnd"]).CGColor];
    BOOL focus=state[@"focus"]!=nil, changed=[state[@"focusChanged"] boolValue] || focus!=self.hasFocus;
    if(focus) {
        CGRect f=[state[@"focus"] rectValue]; f.origin.x-=screen.origin.x; f.origin.y-=screen.origin.y;
        CGPathRef path=CGPathCreateWithRoundedRect(CGRectInset([self flip:f],width*.5,width*.5),radius,radius,NULL);
        self.focusMask.path=path; CGPathRelease(path);
    }
    self.focusMask.lineWidth=width;
    self.focus.opacity=focus?1:0; self.hasFocus=focus;
    [CATransaction commit];

    if(changed && focus && !reduce) {
        /* Focus arrives with a short pulse: the outline starts wide and soft, then tightens. */
        CABasicAnimation *line=[CABasicAnimation animationWithKeyPath:@"lineWidth"];
        line.fromValue=@(width*3); line.toValue=@(width); line.duration=.26;
        line.timingFunction=[CAMediaTimingFunction functionWithControlPoints:.22 :1 :.36 :1];
        [self.focusMask addAnimation:line forKey:@"pulse"];
        CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue=@.15; fade.toValue=@1; fade.duration=.2;
        [self.focus addAnimation:fade forKey:@"arrive"];
    }
    [CATransaction begin]; [CATransaction setAnimationDuration:reduce?0:.16];
    self.mapBack.opacity=showMap?1:0; self.wall.opacity=showWall?1:0;
    [CATransaction commit];
    if(!self.panel.visible || changed) [self.panel orderFrontRegardless];
    uint64_t generation=++self.generation;
    double spent=(CACurrentMediaTime()-began)*1000;
    ++hwm_feedback_shows; if(spent>hwm_feedback_show_max_ms) hwm_feedback_show_max_ms=spent;
    if(showMap || showWall) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.85*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(self.generation!=generation) return;
        [CATransaction begin]; [CATransaction setAnimationDuration:reduce?0:.25];
        self.mapBack.opacity=0; self.wall.opacity=0;
        [CATransaction commit];
    });
}
@end
static double hwm_feedback_nav_time,hwm_feedback_wall_time;
static _Atomic bool hwm_feedback_pending;
static bool hwm_show_map=true;
static uint32_t hwm_feedback_focus_id;
static bool hwm_feedback_focus_changed;
static void hwm_feedback_navigation(bool wall)
{
    hwm_feedback_nav_time=hwm_now();
    if(wall) hwm_feedback_wall_time=hwm_now();
}
static void hwm_feedback_focus(struct window *previous,struct window *next)
{
    (void)previous; if(next && next->id!=hwm_feedback_focus_id) { hwm_feedback_focus_id=next->id; hwm_feedback_focus_changed=true; }
    hwm_wake();
}
static NSDictionary *hwm_feedback_last;
static void hwm_feedback_hide(void)
{
    if(!hwm_feedback_last) return;
    [hwm_feedback_last release]; hwm_feedback_last=nil;
    dispatch_async(dispatch_get_main_queue(),^{ [[TanaFeedback shared] hide]; });
}
/* Titles are shown on tabs only, are never persisted, and are fetched in the
 * background: a tab shows the app name until its title arrives. */
static NSString *hwm_feedback_title(struct window *w,double now)
{
    return hwm_ax_title(w->id,w->ref,w->application->name ? @(w->application->name) : @"",now,^(uint32_t wid,NSString *title) { (void)wid; (void)title; hwm_wake(); });
}
static NSArray *hwm_rgba(const double c[4]) { return @[@(c[0]),@(c[1]),@(c[2]),@(c[3])]; }
static void hwm_feedback_tick(struct view *view,double now)
{
    if(hwm_overview_active || hwm_paused || hwm_suspended) { hwm_feedback_hide(); return; }
    static double external_check=-10;
    if(now-external_check>10) { external_check=now; hwm_external_borders_refresh(); }
    bool expected=false;
    if(!atomic_compare_exchange_strong(&hwm_feedback_pending,&expected,true)) return;
    CGRect screen=hwm_screen(view),bounds=hwm_bounds(view);
    NSMutableArray *columns=[NSMutableArray array],*tabs=[NSMutableArray array],*others=[NSMutableArray array];
    NSMutableSet *seen=[NSMutableSet set]; bool borders=hwm_border_on();
    struct window *focus=window_manager_find_window(&g_window_manager,hwm_feedback_focus_id);
    uint64_t focus_column=focus && view_find_window_node(view,focus->id) ? focus->strip_column : 0;
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int j=0;j<n->window_count;j++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[j]); if(!w) continue;
        if(![seen containsObject:@(w->strip_column)]) {
            // Height 2 marks the focused column for the map.
            [columns addObject:[NSValue valueWithRect:CGRectMake(w->strip_world_x,0,w->strip_width,focus_column && w->strip_column==focus_column?2:1)]];
            [seen addObject:@(w->strip_column)];
        }
        CGRect shown=w->strip_last_frame;
        if(borders && w!=focus && !hwm_workflow_tab_hidden(w) && !w->strip_pop && w->id!=hwm_drag_window &&
           !CGRectIsNull(shown) && CGRectIntersectsRect(shown,screen)) [others addObject:[NSValue valueWithRect:shown]];
    }
    // One bar per tabbed column, sitting in the space the layout reserves above it.
    for(struct window_node *n=window_node_find_first_leaf(view->root);n;n=window_node_find_next_leaf(n)) for(int j=0;j<n->window_count;j++) {
        struct window *w=window_manager_find_window(&g_window_manager,n->window_list[j]); if(!w) continue;
        double y=0,height=0;
        if(!hwm_workflow_tab_geometry(view,w,&y,&height) || hwm_workflow_tab_hidden(w) || CGRectIsNull(w->strip_last_frame)) continue;
        CGRect shown=w->strip_last_frame;
        if(!CGRectIntersectsRect(shown,screen)) continue;
        NSMutableArray *members=[NSMutableArray array];
        for(struct window_node *m=window_node_find_first_leaf(view->root);m;m=window_node_find_next_leaf(m)) for(int k=0;k<m->window_count;k++) {
            struct window *other=window_manager_find_window(&g_window_manager,m->window_list[k]);
            if(other && other->strip_column==w->strip_column) [members addObject:[NSValue valueWithPointer:other]];
        }
        double gap=4, width=(shown.size.width-gap*(members.count-1))/fmax(1,members.count), top=shown.origin.y-y;
        for(NSUInteger i=0;i<members.count;i++) {
            struct window *member=[members[i] pointerValue];
            CGRect r=CGRectMake(shown.origin.x-screen.origin.x+i*(width+gap),top-screen.origin.y,width,y-6);
            [tabs addObject:@{@"id":@(member->id),@"pid":@(member->application->pid),@"column":@(member->strip_column),@"rect":[NSValue valueWithRect:r],
                              @"title":hwm_feedback_title(member,now),@"active":@(member==w)}];
        }
    }
    // Only what is actually drawn goes into the snapshot. An unchanged
    // snapshot is not sent at all, so a still strip costs the main thread nothing
    // however long the tick keeps running (during a drag it runs every frame).
    bool map=hwm_show_map && now-hwm_feedback_nav_time<.7, wall=now-hwm_feedback_wall_time<.3;
    double total=fmax(hwm_content_width,view->strip_offset)+bounds.size.width;
    NSMutableDictionary *state=[NSMutableDictionary dictionaryWithDictionary:@{@"screen":[NSValue valueWithRect:screen],
        @"columns":map ? columns : @[],@"total":@(map ? total : 1),@"offset":@(map ? view->strip_offset : 0),@"viewport":@(bounds.size.width),
        @"map":@(map),@"wall":@(wall),@"wallRight":@(wall && view->strip_offset>1),@"tabs":tabs,@"others":others,
        @"borderWidth":@(hwm_border_width),@"borderRadius":@(hwm_border_radius),@"active":hwm_rgba(hwm_border_active),
        @"activeEnd":hwm_rgba(hwm_border_active_end),@"inactive":hwm_rgba(hwm_border_inactive)}];
    // A dragged or edge-resized window is moved by the pointer every event; an
    // outline drawn from here would trail it, so it gets none until it lands.
    if(borders && focus && focus->id!=hwm_drag_window && focus->id!=hwm_edge_window && !focus->strip_pop && !focus->strip_close_pending && window_manager_is_window_eligible(focus) &&
       !window_check_flag(focus,WINDOW_FULLSCREEN) && !window_check_flag(focus,WINDOW_MINIMIZE) && !focus->application->is_hidden &&
       (view_find_window_node(view,focus->id) || window_check_flag(focus,WINDOW_FLOAT))) {
        // A tile's last submitted frame is exact and costs no round trip.
        CGRect f=view_find_window_node(view,focus->id) ? focus->strip_last_frame : CGRectNull;
        if(CGRectIsNull(f) && SLSGetWindowBounds(g_connection,focus->id,&f)!=kCGErrorSuccess) f=CGRectNull;
        if(!CGRectIsNull(f) && CGRectIntersectsRect(f,screen)) state[@"focus"]=[NSValue valueWithRect:f];
    }
    bool focus_changed=hwm_feedback_focus_changed && state[@"focus"]!=nil; hwm_feedback_focus_changed=false;
    if(!focus_changed && hwm_feedback_last && [hwm_feedback_last isEqualToDictionary:state]) { hwm_feedback_pending=false; return; }
    [hwm_feedback_last release]; hwm_feedback_last=[state copy];
    state[@"focusChanged"]=@(focus_changed);
    NSDictionary *snapshot=[state copy];
    dispatch_async(dispatch_get_main_queue(),^{ hwm_feedback_pending=false; [[TanaFeedback shared] show:snapshot]; [snapshot release]; });
}
