/* Signals out of the strip: trackpad haptics and the event stream. Both are
 * fire-and-forget; nothing in a frame waits on either. */
#include <sys/socket.h>

static bool hwm_haptics=true;
/* 0: a detent (a column or drop zone was crossed). 1: a limit (an end of the strip). */
static void hwm_haptic(int kind)
{
    static double last;
    double now=hwm_now();
    if(!hwm_haptics || now-last<.045) return;
    last=now;
    dispatch_async(dispatch_get_main_queue(),^{
        [[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:kind ? NSHapticFeedbackPatternLevelChange : NSHapticFeedbackPatternAlignment
                                                           performanceTime:NSHapticFeedbackPerformanceTimeNow];
    });
}

/* `tana -m strip subscribe` keeps its connection and is sent one JSON object
 * per line as things happen. Every write is made from the event loop and never
 * blocks: a reader that falls behind is dropped rather than waited for. */
enum { HWM_IPC_MAX=8 };
static int hwm_ipc_fds[HWM_IPC_MAX], hwm_ipc_count;
static void hwm_ipc_send(NSDictionary *event)
{
    if(!hwm_ipc_count || !event) return;
    NSMutableData *line=[[[NSJSONSerialization dataWithJSONObject:event options:0 error:NULL] mutableCopy] autorelease];
    if(!line) return;
    [line appendBytes:"\n" length:1];
    for(int i=0;i<hwm_ipc_count;) {
        ssize_t written=write(hwm_ipc_fds[i],line.bytes,line.length);
        if(written==(ssize_t)line.length) { ++i; continue; }
        close(hwm_ipc_fds[i]);
        hwm_ipc_fds[i]=hwm_ipc_fds[--hwm_ipc_count];
    }
}
static bool hwm_ipc_subscribe(FILE *rsp)
{
    if(hwm_ipc_count==HWM_IPC_MAX) return false;
    // The engine closes its own descriptor after the command; this one keeps the connection.
    int fd=dup(fileno(rsp)), on=1, buffer=1<<18;
    if(fd<0) return false;
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&on,sizeof(on));
    setsockopt(fd,SOL_SOCKET,SO_SNDBUF,&buffer,sizeof(buffer));
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL,0)|O_NONBLOCK);
    hwm_ipc_fds[hwm_ipc_count++]=fd;
    return true;
}
