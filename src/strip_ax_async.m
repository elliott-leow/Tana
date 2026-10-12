/* Accessibility requests that must never stall an animation frame.
 *
 * An AX call is a synchronous round trip to the target application: it returns
 * when that app's main thread gets around to answering, which for a busy app
 * is tens or hundreds of milliseconds. The strip's event loop also produces
 * every animation frame, so one slow app used to freeze every window in motion.
 *
 * Everything here runs the AX call on a background queue instead. Requests for
 * the same window are coalesced: while one is in flight only the newest pending
 * size is kept, so a slow app is asked for fewer, later sizes rather than
 * falling ever further behind. Elements are retained for the life of a job, so
 * a window closing mid-request is harmless. */
#include <os/lock.h>

@interface TanaAXJob : NSObject {
@public
    AXUIElementRef window, app;
    CGSize size;
    BOOL pending, running;
}
@end
@implementation TanaAXJob
- (void)dealloc { if(window) CFRelease(window); if(app) CFRelease(app); [super dealloc]; }
@end

static os_unfair_lock hwm_ax_lock=OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary *hwm_ax_jobs;   /* window id -> TanaAXJob */
static NSMutableDictionary *hwm_ax_titles; /* window id -> @[title, @(time), @(fetching)] */
static _Atomic uint64_t hwm_ax_resizes_sent, hwm_ax_resizes_coalesced;
static _Atomic double hwm_ax_resize_max_ms;

static dispatch_queue_t hwm_ax_queue(void)
{
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("tana.accessibility",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT,QOS_CLASS_USER_INTERACTIVE,0)); });
    return queue;
}

static void hwm_ax_run(TanaAXJob *job)
{
    // Electron and friends resize in slow steps while "enhanced UI" is on.
    // It is switched off once for the whole burst rather than around every size.
    bool enhanced=job->app && ax_enhanced_userinterface(job->app);
    if(enhanced) AXUIElementSetAttributeValue(job->app,kAXEnhancedUserInterface,kCFBooleanFalse);
    for(;;) {
        os_unfair_lock_lock(&hwm_ax_lock);
        if(!job->pending) { job->running=NO; os_unfair_lock_unlock(&hwm_ax_lock); break; }
        CGSize size=job->size; job->pending=NO;
        os_unfair_lock_unlock(&hwm_ax_lock);
        uint64_t began=read_os_timer();
        CFTypeRef value=AXValueCreate(kAXValueTypeCGSize,(void *)&size);
        if(value) { AXUIElementSetAttributeValue(job->window,kAXSizeAttribute,value); CFRelease(value); }
        double ms=(double)(read_os_timer()-began)*1000/(double)read_os_freq();
        ++hwm_ax_resizes_sent; if(ms>hwm_ax_resize_max_ms) hwm_ax_resize_max_ms=ms;
    }
    if(enhanced) AXUIElementSetAttributeValue(job->app,kAXEnhancedUserInterface,kCFBooleanTrue);
}

/* Ask a window for a size. Returns at once; position is never set here, because
 * AX placement clamps to the visible screen and the strip lives beyond it. */
static void hwm_ax_resize(uint32_t wid,AXUIElementRef window,AXUIElementRef app,CGSize size)
{
    if(!wid || !window) return;
    os_unfair_lock_lock(&hwm_ax_lock);
    if(!hwm_ax_jobs) hwm_ax_jobs=[NSMutableDictionary new];
    TanaAXJob *job=hwm_ax_jobs[@(wid)];
    if(job && !CFEqual(job->window,window)) { job=nil; } // The id was reused by a new window.
    if(!job) {
        if(hwm_ax_jobs.count>128) {
            for(NSNumber *key in hwm_ax_jobs.allKeys) if(!((TanaAXJob *)hwm_ax_jobs[key])->running) [hwm_ax_jobs removeObjectForKey:key];
        }
        job=[[TanaAXJob new] autorelease];
        job->window=CFRetain(window); job->app=app ? CFRetain(app) : NULL;
        hwm_ax_jobs[@(wid)]=job;
    }
    if(job->pending) ++hwm_ax_resizes_coalesced;
    job->size=size; job->pending=YES;
    bool start=!job->running;
    if(start) { job->running=YES; [job retain]; }
    os_unfair_lock_unlock(&hwm_ax_lock);
    if(start) dispatch_async(hwm_ax_queue(),^{ hwm_ax_run(job); [job release]; });
}

/* True while a size request for this window has not been answered yet. */
static bool hwm_ax_resize_busy(uint32_t wid)
{
    os_unfair_lock_lock(&hwm_ax_lock);
    TanaAXJob *job=hwm_ax_jobs[@(wid)];
    bool busy=job && (job->running || job->pending);
    os_unfair_lock_unlock(&hwm_ax_lock);
    return busy;
}

/* Press a window's close button. AXPress can wait on a save sheet or a busy
 * app for a long time; nothing in the strip waits with it. */
static void hwm_ax_close(AXUIElementRef window)
{
    if(!window) return;
    CFRetain(window);
    dispatch_async(hwm_ax_queue(),^{
        CFTypeRef button=NULL;
        AXUIElementCopyAttributeValue(window,kAXCloseButtonAttribute,&button);
        if(button) { AXUIElementPerformAction(button,kAXPressAction); CFRelease(button); }
        CFRelease(window);
    });
}

/* A window's title without waiting for its app. The first request returns the
 * fallback and starts a fetch; `ready` runs (on the AX queue) when a new title
 * arrives so the caller can redraw. Titles are refreshed at most every 2 s. */
static NSString *hwm_ax_title(uint32_t wid,AXUIElementRef window,NSString *fallback,double now,void (^ready)(uint32_t wid,NSString *title))
{
    NSString *result=fallback ?: @"";
    if(!wid || !window) return result;
    os_unfair_lock_lock(&hwm_ax_lock);
    if(!hwm_ax_titles) hwm_ax_titles=[NSMutableDictionary new];
    NSArray *entry=hwm_ax_titles[@(wid)];
    if(entry && [entry[0] length]) result=[[entry[0] retain] autorelease];
    bool fetch=!entry || (![entry[2] boolValue] && now-[entry[1] doubleValue]>2);
    if(fetch) {
        if(hwm_ax_titles.count>256) [hwm_ax_titles removeAllObjects];
        hwm_ax_titles[@(wid)]=@[entry ? entry[0] : @"",@(now),@YES];
    }
    os_unfair_lock_unlock(&hwm_ax_lock);
    if(fetch) {
        CFRetain(window);
        void (^done)(uint32_t,NSString *)=[ready copy];
        dispatch_async(hwm_ax_queue(),^{
            CFTypeRef value=NULL;
            AXUIElementCopyAttributeValue(window,kAXTitleAttribute,&value);
            NSString *title=value && CFGetTypeID(value)==CFStringGetTypeID() ? [[(NSString *)value copy] autorelease] : @"";
            if(value) CFRelease(value);
            CFRelease(window);
            os_unfair_lock_lock(&hwm_ax_lock);
            NSArray *previous=hwm_ax_titles[@(wid)];
            bool changed=!previous || ![previous[0] isEqual:title];
            hwm_ax_titles[@(wid)]=@[title,@(now),@NO];
            os_unfair_lock_unlock(&hwm_ax_lock);
            if(changed && done) done(wid,title);
            [done release];
        });
    }
    return result;
}
