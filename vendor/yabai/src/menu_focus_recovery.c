// Keep the user's FFM preference independent of temporary menu suppression.
// AX references identify menus, so duplicate opens/unmatched closes cannot corrupt
// a counter. Reconcile on pointer movement, at most four times per second.
#include <errno.h>
#include <signal.h>
static CFMutableArrayRef ffm_menus;
static uint64_t ffm_menu_check_time;

static void menu_focus_open(AXUIElementRef menu)
{
    if (!ffm_menus) ffm_menus = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFRange range = CFRangeMake(0, CFArrayGetCount(ffm_menus));
    if (!CFArrayContainsValue(ffm_menus, range, menu)) {
        CFArrayAppendValue(ffm_menus, menu);
        debug("menu-focus-recovery: suppressing (%ld menus)\n", CFArrayGetCount(ffm_menus));
    }
    ffm_menu_check_time = read_os_timer();
}

static void menu_focus_close(AXUIElementRef menu)
{
    if (!ffm_menus) return;
    CFIndex index = CFArrayGetFirstIndexOfValue(ffm_menus, CFRangeMake(0, CFArrayGetCount(ffm_menus)), menu);
    if (index != kCFNotFound) CFArrayRemoveValueAtIndex(ffm_menus, index);
    debug("menu-focus-recovery: close (%ld menus)\n", CFArrayGetCount(ffm_menus));
}

static bool menu_focus_suppressed(void)
{
    if (!ffm_menus || !CFArrayGetCount(ffm_menus)) return false;
    uint64_t now = read_os_timer();
    if ((double)(now - ffm_menu_check_time) / read_os_freq() < 0.25) return true;
    ffm_menu_check_time = now;
    for (CFIndex i = CFArrayGetCount(ffm_menus); i-- > 0;) {
        AXUIElementRef menu = (AXUIElementRef) CFArrayGetValueAtIndex(ffm_menus, i);
        pid_t owner = 0;
        AXError owner_error = AXUIElementGetPid(menu, &owner);
        bool gone = owner_error == kAXErrorInvalidUIElement;
        if (owner_error == kAXErrorSuccess && owner > 0 &&
            kill(owner, 0) == -1 && errno == ESRCH) {
            gone = true;
            debug("menu-focus-recovery: owner exited %d\n", owner);
        }
        uint32_t wid = 0;
        if (!gone) {
            CFTypeRef role = NULL;
            AXError error = AXUIElementCopyAttributeValue(menu, kAXRoleAttribute, &role);
            if (role) CFRelease(role);
            gone = error == kAXErrorInvalidUIElement;
            wid = ax_window_id(menu);
            uint8_t ordered = 1;
            if (wid && SLSWindowIsOrderedIn(g_connection, wid, &ordered) == kCGErrorSuccess && !ordered) gone = true;
        }
        // Transient AX/SkyLight failures are not evidence that a menu closed.
        if (gone) {
            CFArrayRemoveValueAtIndex(ffm_menus, i);
            debug("menu-focus-recovery: cleared stale menu %u (%ld remain)\n", wid, CFArrayGetCount(ffm_menus));
        }
    }
    return CFArrayGetCount(ffm_menus) != 0;
}
