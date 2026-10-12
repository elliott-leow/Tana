#include <poll.h>
static unsigned poll_calls;
static int counted_poll(struct pollfd *fds, nfds_t count, int timeout)
{
    ++poll_calls;
    return poll(fds,count,timeout);
}
#define poll counted_poll
#include "../src/sa_transport.h"
#undef poll

#include <assert.h>
#include <dirent.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/types.h>
#include <unistd.h>

enum server_mode { SERVER_EOF, SERVER_ACK, SERVER_STALL };

struct server {
    char path[sizeof(((struct sockaddr_un *) 0)->sun_path)];
    const unsigned char *expected;
    size_t expected_length;
    enum server_mode mode;
    int listener;
    int received_correctly;
    pthread_t thread;
};

struct handshake_server {
    char path[sizeof(((struct sockaddr_un *) 0)->sun_path)];
    const unsigned char *expected;
    size_t expected_length;
    const unsigned char *reply;
    size_t reply_length;
    int stall;
    int received_correctly;
    int listener;
    pthread_t thread;
};

static unsigned int path_counter;

static void *server_main(void *context)
{
    struct server *server = context;
    int client = accept(server->listener, NULL, NULL);
    if (client >= 0) {
        if (server->mode == SERVER_STALL) {
            usleep(250000);
        } else {
            size_t received_total = 0U;
            unsigned char buffer[257];
            while (received_total < server->expected_length) {
                size_t wanted = server->expected_length - received_total;
                ssize_t received;
                if (wanted > sizeof(buffer)) wanted = sizeof(buffer);
                received = recv(client, buffer, wanted, 0);
                if (received <= 0) break;
                if (memcmp(buffer, server->expected + received_total, (size_t) received) != 0) break;
                received_total += (size_t) received;
            }
            server->received_correctly = received_total == server->expected_length;
            if (server->mode == SERVER_ACK && server->received_correctly) {
                assert(send(client, "A", 1U, 0) == 1);
            }
        }
        close(client);
    }
    close(server->listener);
    unlink(server->path);
    return NULL;
}

static void server_start(struct server *server, const unsigned char *expected, size_t expected_length, enum server_mode mode)
{
    struct sockaddr_un address;
    memset(server, 0, sizeof(*server));
    server->expected = expected;
    server->expected_length = expected_length;
    server->mode = mode;
    assert(snprintf(server->path, sizeof(server->path), "/tmp/hwm-sa-%ld-%u.socket", (long) getpid(), ++path_counter) > 0);
    server->listener = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(server->listener >= 0);
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, server->path, strlen(server->path) + 1U);
    assert(bind(server->listener, (const struct sockaddr *) &address, sizeof(address)) == 0);
    assert(listen(server->listener, 1) == 0);
    assert(pthread_create(&server->thread, NULL, server_main, server) == 0);
}

static void server_join(struct server *server)
{
    assert(pthread_join(server->thread, NULL) == 0);
}

static void *handshake_server_main(void *context)
{
    struct handshake_server *server = context;
    int client = accept(server->listener, NULL, NULL);
    if (client >= 0) {
        size_t received_total = 0U;
        unsigned char buffer[16];
        while (received_total < server->expected_length) {
            size_t wanted = server->expected_length - received_total;
            ssize_t received;
            if (wanted > sizeof(buffer)) wanted = sizeof(buffer);
            received = recv(client, buffer, wanted, 0);
            if (received <= 0 || memcmp(buffer, server->expected + received_total, (size_t) received) != 0) break;
            received_total += (size_t) received;
        }
        server->received_correctly = received_total == server->expected_length;
        if (server->received_correctly && server->stall) {
            usleep(250000);
        } else if (server->received_correctly) {
            size_t index;
            for (index = 0U; index < server->reply_length; ++index) {
                assert(send(client, server->reply + index, 1U, 0) == 1);
                usleep(1000);
            }
        }
        close(client);
    }
    close(server->listener);
    unlink(server->path);
    return NULL;
}

static void handshake_server_start(struct handshake_server *server, const unsigned char *expected, size_t expected_length,
                                   const unsigned char *reply, size_t reply_length, int stall)
{
    struct sockaddr_un address;
    memset(server, 0, sizeof(*server));
    server->expected = expected;
    server->expected_length = expected_length;
    server->reply = reply;
    server->reply_length = reply_length;
    server->stall = stall;
    assert(snprintf(server->path, sizeof(server->path), "/tmp/hwm-hs-%ld-%u.socket", (long) getpid(), ++path_counter) > 0);
    server->listener = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(server->listener >= 0);
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, server->path, strlen(server->path) + 1U);
    assert(bind(server->listener, (const struct sockaddr *) &address, sizeof(address)) == 0);
    assert(listen(server->listener, 1) == 0);
    assert(pthread_create(&server->thread, NULL, handshake_server_main, server) == 0);
}

static void handshake_server_join(struct handshake_server *server)
{
    assert(pthread_join(server->thread, NULL) == 0);
}

static int descriptor_count(void)
{
    DIR *directory = opendir("/dev/fd");
    struct dirent *entry;
    int count = 0;
    assert(directory != NULL);
    while ((entry = readdir(directory)) != NULL) {
        if (entry->d_name[0] != '.') ++count;
    }
    closedir(directory);
    return count;
}

static void test_eof_and_partial_server_reads(void)
{
    unsigned char payload[65537];
    struct server server;
    size_t index;
    for (index = 0U; index < sizeof(payload); ++index) payload[index] = (unsigned char) (index * 31U);
    server_start(&server, payload, sizeof(payload), SERVER_EOF);
    assert(hwm_sa_send(server.path, payload, sizeof(payload), 1000));
    server_join(&server);
    assert(server.received_correctly);
}

static void test_optional_ack(void)
{
    static const unsigned char payload[] = {0, 1, 2, 3, 4, 5};
    struct server server;
    server_start(&server, payload, sizeof(payload), SERVER_ACK);
    assert(hwm_sa_send(server.path, payload, sizeof(payload), 1000));
    server_join(&server);
    assert(server.received_correctly);
}

static void test_failures_are_bounded(void)
{
    static const unsigned char payload[] = {9, 8, 7};
    struct server server;
    long long start;
    assert(!hwm_sa_send("/tmp/hwm-sa-path-that-does-not-exist.socket", payload, sizeof(payload), 50));
    server_start(&server, payload, sizeof(payload), SERVER_STALL);
    start = hwm_sa_monotonic_ms();
    assert(!hwm_sa_send(server.path, payload, sizeof(payload), 50));
    assert(hwm_sa_monotonic_ms() - start < 220);
    server_join(&server);
}

static void test_no_descriptor_leak(void)
{
    static const unsigned char payload[] = {42};
    int baseline = descriptor_count();
    int index;
    for (index = 0; index < 32; ++index) {
        struct server server;
        server_start(&server, payload, sizeof(payload), SERVER_EOF);
        assert(hwm_sa_send(server.path, payload, sizeof(payload), 1000));
        server_join(&server);
    }
    assert(descriptor_count() == baseline);
}

static void test_send_fast_path_and_backpressure(void)
{
    int pair[2];
    assert(socketpair(AF_UNIX,SOCK_STREAM,0,pair)==0);
    assert(fcntl(pair[0],F_SETFL,O_NONBLOCK)==0);
    int size=4096;
    assert(setsockopt(pair[0],SOL_SOCKET,SO_SNDBUF,&size,sizeof(size))==0);
    poll_calls=0;
    assert(hwm_sa_send_all(pair[0],"x",1,hwm_sa_monotonic_ms()+100));
    assert(poll_calls==0); // One send, no readiness syscall for a small command.
    char byte=0;
    assert(read(pair[1],&byte,1)==1 && byte=='x');
    unsigned char *large=calloc(1,1024*1024);
    assert(large);
    long long start=hwm_sa_monotonic_ms();
    assert(!hwm_sa_send_all(pair[0],large,1024*1024,start+40));
    assert(poll_calls>0);
    assert(hwm_sa_monotonic_ms()-start<220);
    free(large); close(pair[0]); close(pair[1]);
}

static void test_fragmented_handshake(void)
{
    static const unsigned char request[] = {1, 0, 12};
    uint32_t expected_attributes = UINT32_C(0xdecafbad);
    unsigned char reply[sizeof("1.2.3") + sizeof(expected_attributes)];
    struct handshake_server server;
    char version[16];
    uint32_t attributes = 0U;
    memcpy(reply, "1.2.3", sizeof("1.2.3"));
    memcpy(reply + sizeof("1.2.3"), &expected_attributes, sizeof(expected_attributes));
    handshake_server_start(&server, request, sizeof(request), reply, sizeof(reply), 0);
    assert(hwm_sa_handshake(server.path, request, sizeof(request), version, sizeof(version), &attributes, 1000));
    handshake_server_join(&server);
    assert(server.received_correctly);
    assert(strcmp(version, "1.2.3") == 0);
    assert(attributes == expected_attributes);
}

static void test_malformed_handshakes_fail(void)
{
    static const unsigned char request[] = {1, 0, 12};
    static const unsigned char truncated[] = {'v', '\0', 1, 2};
    static const unsigned char too_long[] = {'a', 'b', 'c', 'd'};
    struct handshake_server server;
    char version[4];
    uint32_t attributes = 0U;
    long long start;

    handshake_server_start(&server, request, sizeof(request), truncated, sizeof(truncated), 0);
    assert(!hwm_sa_handshake(server.path, request, sizeof(request), version, sizeof(version), &attributes, 1000));
    handshake_server_join(&server);
    assert(server.received_correctly);

    handshake_server_start(&server, request, sizeof(request), too_long, sizeof(too_long), 0);
    assert(!hwm_sa_handshake(server.path, request, sizeof(request), version, sizeof(version), &attributes, 1000));
    handshake_server_join(&server);
    assert(server.received_correctly);

    handshake_server_start(&server, request, sizeof(request), NULL, 0U, 1);
    start = hwm_sa_monotonic_ms();
    assert(!hwm_sa_handshake(server.path, request, sizeof(request), version, sizeof(version), &attributes, 50));
    assert(hwm_sa_monotonic_ms() - start < 220);
    handshake_server_join(&server);
}

/* A helper that serves one connection at a time, in the order they were made,
 * like the real one: read a one-byte message, record it, close. */
struct pipeline_server {
    pthread_t thread;
    int listener;
    char path[104];
    int expected;
    int stall_after; /* stop answering after this many messages; -1 never */
    unsigned char order[160];
    int served;
};

static void *pipeline_server_main(void *context)
{
    struct pipeline_server *server = context;
    int held[160]; int held_count = 0;
    while (server->served < server->expected) {
        unsigned char byte;
        int client = accept(server->listener, NULL, NULL);
        if (client < 0) break;
        if (recv(client, &byte, 1U, MSG_WAITALL) == 1) server->order[server->served] = byte;
        ++server->served;
        if (server->stall_after >= 0 && server->served > server->stall_after) { held[held_count++] = client; continue; }
        close(client);
    }
    if (held_count) usleep(150000);
    while (held_count) close(held[--held_count]);
    close(server->listener);
    unlink(server->path);
    return NULL;
}

static void pipeline_server_start(struct pipeline_server *server, int expected, int stall_after)
{
    struct sockaddr_un address;
    memset(server, 0, sizeof(*server));
    server->expected = expected; server->stall_after = stall_after;
    assert(snprintf(server->path, sizeof(server->path), "/tmp/hwm-sa-%ld-%u.socket", (long) getpid(), ++path_counter) > 0);
    server->listener = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(server->listener >= 0);
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, server->path, strlen(server->path) + 1U);
    assert(bind(server->listener, (const struct sockaddr *) &address, sizeof(address)) == 0);
    assert(listen(server->listener, 128) == 0);
    assert(pthread_create(&server->thread, NULL, pipeline_server_main, server) == 0);
}

static void test_pipeline_orders_and_awaits_every_message(void)
{
    struct pipeline_server server;
    HwmSaPipeline pipeline;
    int baseline = descriptor_count();
    int count = HWM_SA_PIPELINE_MAX * 2 + 7; /* crosses the queue limit twice */
    int index;
    memset(&pipeline, 0, sizeof(pipeline));
    pipeline_server_start(&server, count, -1);
    for (index = 0; index < count; ++index) {
        unsigned char byte = (unsigned char) index;
        assert(hwm_sa_pipeline_send(&pipeline, server.path, &byte, 1U, 2000));
        assert(pipeline.count <= HWM_SA_PIPELINE_MAX);
    }
    assert(hwm_sa_pipeline_flush(&pipeline));
    assert(pipeline.count == 0 && !pipeline.failed);
    assert(pthread_join(server.thread, NULL) == 0);
    assert(server.served == count);
    for (index = 0; index < count; ++index) assert(server.order[index] == (unsigned char) index);
    /* An empty flush is a successful no-op. */
    assert(hwm_sa_pipeline_flush(&pipeline));
    assert(descriptor_count() == baseline);
}

static void test_pipeline_reports_unanswered_and_unsendable(void)
{
    struct pipeline_server server;
    HwmSaPipeline pipeline;
    int baseline = descriptor_count();
    unsigned char byte = 1;
    long long start;
    memset(&pipeline, 0, sizeof(pipeline));
    /* The second and third messages are read but never acknowledged in time. */
    pipeline_server_start(&server, 3, 1);
    assert(hwm_sa_pipeline_send(&pipeline, server.path, &byte, 1U, 60));
    assert(hwm_sa_pipeline_send(&pipeline, server.path, &byte, 1U, 60));
    assert(hwm_sa_pipeline_send(&pipeline, server.path, &byte, 1U, 60));
    start = hwm_sa_monotonic_ms();
    assert(!hwm_sa_pipeline_flush(&pipeline));
    assert(hwm_sa_monotonic_ms() - start < 120); /* one shared deadline, not one per message */
    assert(pipeline.count == 0 && !pipeline.failed);
    assert(pthread_join(server.thread, NULL) == 0);
    /* Nothing is listening: the send fails, and so does the batch it belonged to. */
    assert(!hwm_sa_pipeline_send(&pipeline, "/tmp/hwm-sa-does-not-exist.socket", &byte, 1U, 60));
    assert(!hwm_sa_pipeline_flush(&pipeline));
    assert(hwm_sa_pipeline_flush(&pipeline)); /* the failure does not outlive its batch */
    assert(descriptor_count() == baseline);
}

int main(void)
{
    test_pipeline_orders_and_awaits_every_message();
    test_pipeline_reports_unanswered_and_unsendable();
    test_send_fast_path_and_backpressure();
    test_eof_and_partial_server_reads();
    test_optional_ack();
    test_failures_are_bounded();
    test_no_descriptor_leak();
    test_fragmented_handshake();
    test_malformed_handshakes_fail();
    puts("sa transport tests passed");
    return 0;
}
