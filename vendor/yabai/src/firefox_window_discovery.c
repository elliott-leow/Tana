// Firefox tab tear-offs can omit AXCreated. Recover references from AXWindows
// after a left drag, without restarting the daemon or changing window rules.
// All state and AX reads below run on the serialized yabai event thread.
extern struct window_manager g_window_manager;
static pid_t firefox_discovery_pid;
static bool firefox_discovery_dragged;

static bool firefox_discovery_is_application(struct application *application)
{
    return application && strcasecmp(application->name, "Firefox") == 0;
}

static void firefox_discovery_begin(struct application *application, bool left_button)
{
    firefox_discovery_pid = left_button && firefox_discovery_is_application(application) ? application->pid : 0;
    firefox_discovery_dragged = false;
    if (application) debug("firefox-window-discovery: click app=%s pid=%d left=%d armed=%d\n", application->name, application->pid, left_button, firefox_discovery_pid);
}

static void firefox_discovery_drag(void)
{
    if (firefox_discovery_pid) firefox_discovery_dragged = true;
}

static void firefox_discovery_end(void)
{
    pid_t pid = firefox_discovery_pid;
    bool dragged = firefox_discovery_dragged;
    firefox_discovery_pid = 0;
    firefox_discovery_dragged = false;
    if (!pid || !dragged) return;
    debug("firefox-window-discovery: scheduling pid=%d after drag\n", pid);

    // The native drag-end event can precede creation of the accessible window.
    // Retain only the pid across timers: the app may exit before they fire.
    const double delays[] = {0.0, 0.05, 0.1, 0.15, 0.2};
    for (unsigned i = 0; i < sizeof(delays) / sizeof(delays[0]); ++i) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i] * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            event_loop_post(&g_event_loop, FIREFOX_WINDOWS_DISCOVER, (void *)(intptr_t) pid, 0);
        });
    }
}

static void firefox_discovery_rescan(pid_t pid)
{
    struct application *application = window_manager_find_application(&g_window_manager, pid);
    if (!firefox_discovery_is_application(application)) return;

    CFArrayRef windows = application_window_list(application);
    debug("firefox-window-discovery: scan pid=%d AXWindows=%ld\n", pid, windows ? (long) CFArrayGetCount(windows) : -1L);
    if (!windows) return;

    for (CFIndex i = 0; i < CFArrayGetCount(windows); ++i) {
        AXUIElementRef ref = (AXUIElementRef) CFArrayGetValueAtIndex(windows, i);
        uint32_t wid = ax_window_id(ref);
        debug("firefox-window-discovery: AX window %u tracked=%d\n", wid, wid ? window_manager_find_window(&g_window_manager, wid) != NULL : 0);
        if (!wid || window_manager_find_window(&g_window_manager, wid)) continue;

        debug("firefox-window-discovery: recovering %u after drag\n", wid);
        // Reuse normal creation handling for observation, rules, tiling and
        // signals. It also rejects stale refs and deduplicates racing events.
        event_loop_post(&g_event_loop, WINDOW_CREATED, (void *) CFRetain(ref), 0);
    }

    CFRelease(windows);
}
