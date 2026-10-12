#import <Cocoa/Cocoa.h>
@interface Fixture : NSObject
@property(nonatomic,retain) NSMutableArray *windows;
- (void)command:(NSNotification *)notification;
- (void)add;
@end
@implementation Fixture
- (void)add {
    NSUInteger i=self.windows.count;
    NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(160+i*50,180+i*50,500,600) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    w.title=[NSString stringWithFormat:@"Tana Test %lu",(unsigned long)i+1];
    w.minSize=NSMakeSize(240,180); w.releasedWhenClosed=NO;
    NSView *view=w.contentView; view.wantsLayer=YES;
    view.layer.backgroundColor=[[NSColor colorWithHue:i*.23 saturation:.15 brightness:.95 alpha:1] CGColor];
    NSTextField *label=[NSTextField labelWithString:w.title];
    label.font=[NSFont systemFontOfSize:24 weight:NSFontWeightMedium]; label.frame=NSMakeRect(30,50,360,80); [view addSubview:label];
    [self.windows addObject:w]; [w makeKeyAndOrderFront:nil];
}
- (void)command:(NSNotification *)n {
    NSString *command=n.userInfo[@"command"];
    if ([command isEqual:@"new"]) [self add];
    if ([command isEqual:@"close"]) { [self.windows.lastObject close]; [self.windows removeLastObject]; }
    if ([command isEqual:@"minimize"]) [self.windows.lastObject miniaturize:nil];
    if ([command isEqual:@"restore"]) [self.windows.lastObject deminiaturize:nil];
    if ([command isEqual:@"quit"]) [NSApp terminate:nil];
}
@end
int main(int argc,char **argv) { @autoreleasepool {
    if (argc==2) { [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"dev.tana.fixture" object:nil userInfo:@{@"command":@(argv[1])} deliverImmediately:YES]; return 0; }
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    Fixture *fixture=[Fixture new]; fixture.windows=[NSMutableArray array];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:fixture selector:@selector(command:) name:@"dev.tana.fixture" object:nil];
    for(int i=0;i<3;++i) [fixture add];
    [NSApp activateIgnoringOtherApps:YES]; [NSApp run];
} return 0; }
