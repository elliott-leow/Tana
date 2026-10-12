/* Disposable-fixture-only SA backend probe.  It rejects every other app. */
#import <Cocoa/Cocoa.h>

#include "../src/sa_transport.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/un.h>
#include <unistd.h>

extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern int SLSGetWindowSubLevel(int cid, uint32_t wid);

enum { OP_WINDOW_MOVE = 0x06, OP_WINDOW_LAYER = 0x09 };

static const uint32_t fixture_ids[] = {9883U, 9884U, 9885U};

static bool is_fixture(uint32_t wid)
{
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid);
    bool result = false;
    if (list && CFArrayGetCount(list) == 1) {
        NSDictionary *info = (NSDictionary *)CFArrayGetValueAtIndex(list, 0);
        NSString *owner = info[(id)kCGWindowOwnerName];
        NSNumber *number = info[(id)kCGWindowNumber];
        result = [owner isEqualToString:@"TanaFixture"] && number.unsignedIntValue == wid;
    }
    if (list) CFRelease(list);
    return result;
}

static void report(uint32_t wid, const char *label)
{
    CGRect frame = CGRectNull;
    CGError error = SLSGetWindowBounds(SLSMainConnectionID(), wid, &frame);
    printf("%s id=%u sls_error=%d bounds=(%.0f,%.0f %.0fx%.0f) sublevel=%d\n", label, wid, (int)error,
           frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, SLSGetWindowSubLevel(SLSMainConnectionID(), wid));
}

static bool send_move(const char *socket_path, uint32_t wid, int x, int y)
{
    unsigned char message[2 + 1 + sizeof(wid) + sizeof(x) + sizeof(y)];
    int16_t payload_length = (int16_t)(sizeof(message) - sizeof(payload_length));
    memcpy(message, &payload_length, sizeof(payload_length));
    message[sizeof(payload_length)] = OP_WINDOW_MOVE;
    memcpy(message + 3, &wid, sizeof(wid));
    memcpy(message + 3 + sizeof(wid), &x, sizeof(x));
    memcpy(message + 3 + sizeof(wid) + sizeof(x), &y, sizeof(y));
    return hwm_sa_send(socket_path, message, sizeof(message), 100);
}

static bool send_layer(const char *socket_path, uint32_t wid, int layer)
{
    unsigned char message[2 + 1 + sizeof(wid) + sizeof(layer)];
    int16_t payload_length = (int16_t)(sizeof(message) - sizeof(payload_length));
    memcpy(message, &payload_length, sizeof(payload_length));
    message[sizeof(payload_length)] = OP_WINDOW_LAYER;
    memcpy(message + 3, &wid, sizeof(wid));
    memcpy(message + 3 + sizeof(wid), &layer, sizeof(layer));
    return hwm_sa_send(socket_path, message, sizeof(message), 100);
}

int main(int argc, const char *argv[])
{
    char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    CGRect original = CGRectNull;
    int original_sublevel;
    int original_layer_key;
    uint32_t target = fixture_ids[0];
    bool mutate = argc == 2 && strcmp(argv[1], "--mutate-fixtures") == 0;
    size_t index;

    if (argc != 1 && !mutate) {
        fprintf(stderr, "usage: %s [--mutate-fixtures]\n", argv[0]);
        return 64;
    }
    for (index = 0U; index < sizeof(fixture_ids) / sizeof(fixture_ids[0]); ++index) {
        if (!is_fixture(fixture_ids[index])) {
            fprintf(stderr, "refusing: %u is not currently TanaFixture\n", fixture_ids[index]);
            return 1;
        }
        report(fixture_ids[index], "before");
    }
    if (!mutate) return 0;

    if (SLSGetWindowBounds(SLSMainConnectionID(), target, &original) != kCGErrorSuccess) return 1;
    original_sublevel = SLSGetWindowSubLevel(SLSMainConnectionID(), target);
    original_layer_key = original_sublevel == CGWindowLevelForKey(kCGBackstopMenuLevelKey)
                       ? kCGBackstopMenuLevelKey : kCGNormalWindowLevelKey;
    snprintf(socket_path, sizeof(socket_path), "/tmp/yabai-sa_%s.socket", getenv("USER") ?: "");
    printf("move_ok=%d\n", send_move(socket_path, target, 4000, 100));
    usleep(20000);
    report(target, "after_move");
    printf("layer_ok=%d\n", send_layer(socket_path, target, kCGFloatingWindowLevelKey));
    usleep(20000);
    report(target, "after_layer");
    printf("restore_move_ok=%d restore_layer_ok=%d\n",
           send_move(socket_path, target, (int)lround(original.origin.x), (int)lround(original.origin.y)),
           send_layer(socket_path, target, original_layer_key));
    return 0;
}
