#ifndef TANA_SA_TRANSPORT_H
#define TANA_SA_TRANSPORT_H

/* A bounded, reply-optional Unix-stream transport for the yabai SA socket. */

#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static inline long long hwm_sa_monotonic_ms(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (long long) now.tv_sec * 1000LL + now.tv_nsec / 1000000L;
}

static inline int hwm_sa_remaining_ms(long long deadline)
{
    long long now = hwm_sa_monotonic_ms();
    long long remaining;
    if (now < 0) return -1;
    remaining = deadline - now;
    if (remaining <= 0) return 0;
    return remaining > INT_MAX ? INT_MAX : (int) remaining;
}

static inline bool hwm_sa_wait(int fd, short events, long long deadline)
{
    struct pollfd descriptor;
    int remaining;
    int result;

    descriptor.fd = fd;
    descriptor.events = events;
    descriptor.revents = 0;
    for (;;) {
        remaining = hwm_sa_remaining_ms(deadline);
        if (remaining <= 0) return false;
        result = poll(&descriptor, 1, remaining);
        if (result > 0) return true;
        if (result == 0) return false;
        if (errno != EINTR) return false;
    }
}

static inline int hwm_sa_connect(const char *path, long long deadline)
{
    struct sockaddr_un address;
    int flags;
    int fd = -1;

    if (path == NULL || strlen(path) >= sizeof(address.sun_path)) return -1;
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) goto fail;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) goto fail;
#ifdef SO_NOSIGPIPE
    {
        int enabled = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) goto fail;
    }
#endif
    flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) goto fail;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, strlen(path) + 1U);
    if (connect(fd, (const struct sockaddr *) &address, sizeof(address)) != 0) {
        if (errno != EINPROGRESS || !hwm_sa_wait(fd, POLLOUT, deadline)) goto fail;
        {
            int socket_error = 0;
            socklen_t socket_error_size = sizeof(socket_error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &socket_error_size) != 0 || socket_error != 0) goto fail;
        }
    }
    return fd;

fail:
    if (fd >= 0) close(fd);
    return -1;
}

static inline bool hwm_sa_send_all(int fd, const void *bytes, size_t length, long long deadline)
{
    const unsigned char *cursor = bytes;
    size_t sent = 0U;
    while (sent < length) {
        ssize_t written;
        /* The connected socket is nonblocking. Small movement commands almost
         * always fit immediately; poll only after actual backpressure. */
        if (hwm_sa_remaining_ms(deadline) <= 0) return false;
#ifdef MSG_NOSIGNAL
        written = send(fd, cursor + sent, length - sent, MSG_NOSIGNAL);
#else
        written = send(fd, cursor + sent, length - sent, 0);
#endif
        if (written > 0) {
            sent += (size_t) written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (!hwm_sa_wait(fd, POLLOUT, deadline)) return false;
            continue;
        }
        return false;
    }
    return true;
}

static inline bool hwm_sa_receive_byte(int fd, unsigned char *byte, long long deadline)
{
    for (;;) {
        ssize_t received;
        if (!hwm_sa_wait(fd, POLLIN | POLLHUP, deadline)) return false;
        received = recv(fd, byte, 1U, 0);
        if (received == 1) return true;
        if (received == 0) return false;
        if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) return false;
    }
}

/*
 * Send one complete message to a local SA socket before timeout_ms expires.
 * EOF after the payload is processed is successful; newer servers may instead
 * send a one-byte acknowledgement.  No timeout is restarted during retries.
 */
static inline bool hwm_sa_send(const char *path, const void *bytes, size_t length, int timeout_ms)
{
    long long start;
    long long deadline;
    int fd = -1;
    bool success = false;

    if (path == NULL || (bytes == NULL && length != 0U) || timeout_ms <= 0) {
        return false;
    }
    start = hwm_sa_monotonic_ms();
    if (start < 0 || start > LLONG_MAX - timeout_ms) return false;
    deadline = start + timeout_ms;
    fd = hwm_sa_connect(path, deadline);
    if (fd < 0 || !hwm_sa_send_all(fd, bytes, length, deadline)) goto done;

    for (;;) {
        unsigned char acknowledgement;
        ssize_t received;
        if (!hwm_sa_wait(fd, POLLIN | POLLHUP, deadline)) goto done;
        received = recv(fd, &acknowledgement, sizeof(acknowledgement), 0);
        if (received >= 0) {
            success = true; /* either the optional ack or clean EOF */
            goto done;
        }
        if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) goto done;
    }

done:
    if (fd >= 0) close(fd);
    return success;
}

/*
 * Several messages, one wait. The helper serves one connection at a time and
 * in the order they were made, so a frame's commands can all be handed over
 * before any is acknowledged: the helper works through them back to back
 * instead of the two processes waking each other once per command. Commands
 * are applied in the order they were queued. A queued message is not known to
 * have been applied until hwm_sa_pipeline_flush returns.
 */
#define HWM_SA_PIPELINE_MAX 48 /* stays well inside the helper's listen backlog */
typedef struct {
    int descriptors[HWM_SA_PIPELINE_MAX];
    int count;
    long long deadline;
    bool failed;
} HwmSaPipeline;

/* Wait for every queued message to be acknowledged. False when any message in
 * the batch, including one that could not be queued, did not get through. */
static inline bool hwm_sa_pipeline_flush(HwmSaPipeline *pipeline)
{
    bool success;
    int index;
    for (index = 0; index < pipeline->count; ++index) {
        int fd = pipeline->descriptors[index];
        for (;;) {
            unsigned char acknowledgement;
            ssize_t received;
            if (!hwm_sa_wait(fd, POLLIN | POLLHUP, pipeline->deadline)) { pipeline->failed = true; break; }
            received = recv(fd, &acknowledgement, sizeof(acknowledgement), 0);
            if (received >= 0) break;
            if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) { pipeline->failed = true; break; }
        }
        close(fd);
    }
    success = !pipeline->failed;
    pipeline->count = 0;
    pipeline->failed = false;
    return success;
}

/* Queue one message. The batch shares a single deadline, set by its first message. */
static inline bool hwm_sa_pipeline_send(HwmSaPipeline *pipeline, const char *path, const void *bytes, size_t length, int timeout_ms)
{
    int fd;
    if (path == NULL || (bytes == NULL && length != 0U) || timeout_ms <= 0) { pipeline->failed = true; return false; }
    if (pipeline->count >= HWM_SA_PIPELINE_MAX && !hwm_sa_pipeline_flush(pipeline)) pipeline->failed = true;
    if (pipeline->count == 0) {
        long long start = hwm_sa_monotonic_ms();
        if (start < 0 || start > LLONG_MAX - timeout_ms) { pipeline->failed = true; return false; }
        pipeline->deadline = start + timeout_ms;
    }
    fd = hwm_sa_connect(path, pipeline->deadline);
    if (fd < 0 || !hwm_sa_send_all(fd, bytes, length, pipeline->deadline)) {
        if (fd >= 0) close(fd);
        pipeline->failed = true;
        return false;
    }
    pipeline->descriptors[pipeline->count++] = fd;
    return true;
}

/*
 * Send a caller-supplied handshake request and read the native SA reply:
 * a nonempty NUL-terminated version string followed by a uint32_t attribute
 * field.  Version capacity includes the terminating NUL.
 */
static inline bool hwm_sa_handshake(const char *path, const void *request, size_t request_length,
                                    char *version, size_t version_capacity, uint32_t *attributes,
                                    int timeout_ms)
{
    unsigned char raw_attributes[sizeof(uint32_t)];
    long long start;
    long long deadline;
    size_t version_length = 0U;
    size_t index;
    int fd = -1;
    bool success = false;

    if (path == NULL || (request == NULL && request_length != 0U) || version == NULL ||
        version_capacity < 2U || attributes == NULL || timeout_ms <= 0) {
        return false;
    }
    version[0] = '\0';
    start = hwm_sa_monotonic_ms();
    if (start < 0 || start > LLONG_MAX - timeout_ms) return false;
    deadline = start + timeout_ms;
    fd = hwm_sa_connect(path, deadline);
    if (fd < 0 || !hwm_sa_send_all(fd, request, request_length, deadline)) goto done;

    for (;;) {
        unsigned char byte;
        if (!hwm_sa_receive_byte(fd, &byte, deadline)) goto done;
        if (byte == '\0') {
            if (version_length == 0U) goto done;
            version[version_length] = '\0';
            break;
        }
        if (version_length + 1U >= version_capacity) goto done;
        version[version_length++] = (char) byte;
    }
    for (index = 0U; index < sizeof(raw_attributes); ++index) {
        if (!hwm_sa_receive_byte(fd, &raw_attributes[index], deadline)) goto done;
    }
    memcpy(attributes, raw_attributes, sizeof(raw_attributes));
    success = true;

done:
    if (fd >= 0) close(fd);
    return success;
}

#endif
