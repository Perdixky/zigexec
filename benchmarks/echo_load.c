#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/tcp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>

// One outstanding request per connection; validate every byte, including a
// changing sequence number. Nonblocking partial reads AND writes are handled.
// Python orchestrates processes only; the measured load path is native C.
#define HIST_BINS 1000001
typedef struct {
    int fd;
    size_t sent, received;
    uint64_t started, sequence;
    unsigned char *out, *in;
    bool active;
} Connection;

static void fail(const char *message) { perror(message); exit(1); }
static uint64_t now_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) fail("clock_gettime");
    return (uint64_t)t.tv_sec * 1000000000 + (uint64_t)t.tv_nsec;
}
static double cpu_seconds(void) {
    struct rusage r;
    if (getrusage(RUSAGE_SELF, &r)) fail("getrusage");
    return r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6 +
           r.ru_stime.tv_sec + r.ru_stime.tv_usec / 1e6;
}
static void watch(int epoll_fd, Connection *c, uint32_t events) {
    struct epoll_event e = {.events = events, .data.ptr = c};
    if (epoll_ctl(epoll_fd, EPOLL_CTL_MOD, c->fd, &e)) fail("epoll_ctl MOD");
}
static void begin(Connection *c) {
    c->sent = c->received = 0;
    c->sequence++;
    memcpy(c->out, &c->sequence, sizeof(c->sequence));
    c->started = now_ns();
}

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: echo-load PORT CONNECTIONS BYTES\n"); return 1; }
    int port = atoi(argv[1]), count = atoi(argv[2]);
    size_t size = (size_t)strtoul(argv[3], NULL, 10);
    if (port < 1 || port > 65535 || count < 1 || count > 65536 || size < 8 || size > 1048576) return 1;
    Connection *clients = calloc((size_t)count, sizeof(*clients));
    uint64_t *histogram = calloc(HIST_BINS, sizeof(*histogram));
    if (!clients || !histogram) fail("calloc");
    int epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (epoll_fd < 0) fail("epoll_create1");
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
    if (inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) != 1) return 1;
    for (int i = 0; i < count; ++i) {
        Connection *c = &clients[i];
        c->fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (c->fd < 0) fail("socket");
        int one = 1;
        if (setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one))) fail("TCP_NODELAY");
        if (connect(c->fd, (struct sockaddr *)&address, sizeof(address))) fail("connect");
        if (fcntl(c->fd, F_SETFL, O_NONBLOCK)) fail("fcntl");
        c->out = malloc(size);
        c->in = malloc(size);
        if (!c->out || !c->in) fail("malloc");
        for (size_t j = 0; j < size; ++j) c->out[j] = (unsigned char)(i * 37 + j * 13);
        c->active = true;
        struct epoll_event e = {.events = EPOLLIN | EPOLLOUT, .data.ptr = c};
        if (epoll_ctl(epoll_fd, EPOLL_CTL_ADD, c->fd, &e)) fail("epoll_ctl ADD");
    }
    puts("ready");
    fflush(stdout);
    uint64_t start, measure_start, end;
    if (scanf("%" SCNu64 " %" SCNu64 " %" SCNu64, &start, &measure_start, &end) != 3 ||
        start <= now_ns() || measure_start <= start || end <= measure_start) return 1;
    struct timespec ts = {.tv_sec = (time_t)(start / 1000000000), .tv_nsec = (long)(start % 1000000000)};
    int sleep_error;
    while ((sleep_error = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL)) == EINTR) {}
    if (sleep_error) { errno = sleep_error; fail("clock_nanosleep"); }
    for (int i = 0; i < count; ++i) begin(&clients[i]);
    int active = count;
    uint64_t completed = 0, latency_sum = 0, max_latency = 0;
    double cpu_start = 0, cpu_end = 0;
    bool measuring = false, ended = false;
    struct epoll_event events[256];
    while (active) {
        uint64_t current = now_ns();
        if (!measuring && current >= measure_start) { cpu_start = cpu_seconds(); measuring = true; }
        if (!ended && current >= end) { cpu_end = cpu_seconds(); ended = true; }
        if (current > end + 10000000000ULL) { fprintf(stderr, "drain timeout\n"); return 1; }
        int n = epoll_wait(epoll_fd, events, 256, 100);
        if (n < 0) { if (errno == EINTR) continue; fail("epoll_wait"); }
        for (int i = 0; i < n; ++i) {
            Connection *c = events[i].data.ptr;
            if (!c->active) continue;
            if (c->sent < size) {
                while (c->sent < size) {
                    ssize_t written = send(c->fd, c->out + c->sent, size - c->sent, MSG_NOSIGNAL);
                    if (written < 0) {
                        if (errno == EINTR) continue;
                        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                        fail("send");
                    }
                    if (!written) { fprintf(stderr, "zero write\n"); return 1; }
                    c->sent += (size_t)written;
                }
                if (c->sent == size) watch(epoll_fd, c, EPOLLIN);
            }
            // Reading while a large request is still being sent also permits
            // streaming echoes larger than either side's socket buffer.
            while (c->received < size) {
                ssize_t received = recv(c->fd, c->in + c->received, size - c->received, 0);
                if (received < 0) {
                    if (errno == EINTR) continue;
                    if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                    fail("recv");
                }
                if (!received) { fprintf(stderr, "unexpected EOF\n"); return 1; }
                c->received += (size_t)received;
            }
            if (c->received == size) {
                uint64_t finished = now_ns();
                if (c->sent != size || memcmp(c->out, c->in, size)) { fprintf(stderr, "echo mismatch\n"); return 1; }
                if (c->started >= measure_start && finished <= end) {
                    uint64_t latency = finished - c->started;
                    uint64_t bin = (latency + 999) / 1000;
                    histogram[bin < HIST_BINS ? bin : HIST_BINS - 1]++;
                    completed++;
                    latency_sum += latency;
                    if (latency > max_latency) max_latency = latency;
                }
                if (finished >= end) {
                    c->active = false;
                    active--;
                    if (epoll_ctl(epoll_fd, EPOLL_CTL_DEL, c->fd, NULL)) fail("epoll_ctl DEL");
                    close(c->fd);
                } else {
                    begin(c);
                    watch(epoll_fd, c, EPOLLIN | EPOLLOUT);
                }
            }
        }
    }
    if (!ended) cpu_end = cpu_seconds();
    printf("{\"completed\":%" PRIu64 ",\"latency_sum_ns\":%" PRIu64
           ",\"max_latency_ns\":%" PRIu64 ",\"cpu_seconds\":%.9f,\"histogram_us\":[",
           completed, latency_sum, max_latency, cpu_end - cpu_start);
    bool first = true;
    for (int i = 0; i < HIST_BINS; ++i) if (histogram[i]) {
        printf("%s[%d,%" PRIu64 "]", first ? "" : ",", i, histogram[i]);
        first = false;
    }
    puts("]}");
    for (int i = 0; i < count; ++i) { free(clients[i].out); free(clients[i].in); }
    free(clients);
    free(histogram);
    close(epoll_fd);
    return completed ? 0 : 1;
}
