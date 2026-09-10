/*
 * jrbar-hook: the compiled hook shim.
 *
 * Agent providers (Claude Code, Codex, ...) run this at every hook event.
 * It reads the payload from stdin, hands it to the JR-Bar daemon over the
 * hook-ingress socket in the existing wire format
 * (src/jrbar/hook_ingress_protocol.py) and exits 0. When the daemon is not
 * listening the payload is appended to <state>/<provider>.pending.jsonl and
 * the daemon drains that file later. Nothing here can block an agent: the
 * whole run is bounded by HARD_BUDGET_MS and every failure path exits 0.
 *
 *   jrbar-hook --provider <id> [--log <path>]
 *
 * For --provider cursor or gemini (or with --emit-empty-json) the shim
 * prints "{}" on stdout, as Cursor's and Gemini CLI's hook
 * contract requires; otherwise it prints nothing.
 */
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_PAYLOAD (1024 * 1024)
#define HARD_BUDGET_MS 250
#define REPLY_TIMEOUT_MS 200
#define MAGIC "JRBARHOOK\x01"

static uint64_t now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000u + (uint64_t)tv.tv_usec / 1000u;
}

/* JSON-escape src into dst (which must hold 6*len+1 bytes). */
static size_t json_escape(char *dst, const char *src, size_t len) {
    static const char hex[] = "0123456789abcdef";
    size_t o = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '"' || c == '\\') { dst[o++] = '\\'; dst[o++] = (char)c; }
        else if (c == '\n') { dst[o++] = '\\'; dst[o++] = 'n'; }
        else if (c == '\r') { dst[o++] = '\\'; dst[o++] = 'r'; }
        else if (c == '\t') { dst[o++] = '\\'; dst[o++] = 't'; }
        else if (c < 0x20) {
            dst[o++] = '\\'; dst[o++] = 'u'; dst[o++] = '0'; dst[o++] = '0';
            dst[o++] = hex[c >> 4]; dst[o++] = hex[c & 15];
        } else dst[o++] = (char)c;
    }
    dst[o] = 0;
    return o;
}

static void state_dir(char *out, size_t cap) {
    const char *explicit = getenv("JRBAR_STATE_DIR");
    const char *xdg = getenv("XDG_STATE_HOME");
    const char *home = getenv("HOME");
    if (explicit && *explicit) snprintf(out, cap, "%s", explicit);
    else if (xdg && *xdg) snprintf(out, cap, "%s/jrbar", xdg);
    else snprintf(out, cap, "%s/.local/state/jrbar", home ? home : "");
}

static double parent_start_time(pid_t ppid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(ppid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) return -1.0;
    return (double)info.pbi_start_tvsec + (double)info.pbi_start_tvusec / 1e6;
}

/* Send the whole frame and wait for the one-line reply; 0 on success,
 * -1 when the socket was unavailable (fallback file), -2 when the send
 * got through but the reply did not (ambiguous: never re-queue). */
static int deliver(const char *dir, const char *frame, size_t frame_len, uint64_t deadline) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if ((size_t)snprintf(addr.sun_path, sizeof addr.sun_path, "%s/hook-ingress.sock", dir) >= sizeof addr.sun_path) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0 && errno != EINPROGRESS) { close(fd); return -1; }
    struct pollfd pfd = { fd, POLLOUT, 0 };
    int64_t left = (int64_t)deadline - (int64_t)now_ms();
    if (left <= 0 || poll(&pfd, 1, (int)left) <= 0) { close(fd); return -1; }
    int err = 0; socklen_t errlen = sizeof err;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errlen) < 0 || err) { close(fd); return -1; }
    size_t sent = 0;
    while (sent < frame_len) {
        ssize_t n = send(fd, frame + sent, frame_len - sent, 0);
        if (n > 0) { sent += (size_t)n; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            left = (int64_t)deadline - (int64_t)now_ms();
            if (left <= 0 || poll(&pfd, 1, (int)left) <= 0) { close(fd); return sent ? -2 : -1; }
            continue;
        }
        close(fd);
        return sent ? -2 : -1;
    }
    shutdown(fd, SHUT_WR);
    pfd.events = POLLIN;
    left = (int64_t)deadline - (int64_t)now_ms();
    if (left > REPLY_TIMEOUT_MS) left = REPLY_TIMEOUT_MS;
    if (left > 0 && poll(&pfd, 1, (int)left) > 0) {
        char reply[80];
        (void)read(fd, reply, sizeof reply);
    }
    close(fd);
    return 0;
}

static void queue_pending(const char *dir, const char *provider, pid_t ppid, double ppid_start,
                          const char *payload, size_t payload_len) {
    char path[4096];
    if ((size_t)snprintf(path, sizeof path, "%s/%s.pending.jsonl", dir, provider) >= sizeof path) return;
    mkdir(dir, 0700);
    char *escaped = malloc(payload_len * 6 + 1);
    if (!escaped) return;
    json_escape(escaped, payload, payload_len);
    size_t cap = strlen(escaped) + 256;
    char *line = malloc(cap);
    if (!line) { free(escaped); return; }
    int n = snprintf(line, cap, "{\"provider\":\"%s\",\"ppid\":%d,\"ppid_start\":%.6f,\"payload\":\"%s\"}\n",
                     provider, (int)ppid, ppid_start, escaped);
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600);
    if (fd >= 0 && n > 0) { (void)write(fd, line, (size_t)n); close(fd); }
    free(line);
    free(escaped);
}

int main(int argc, char **argv) {
    uint64_t deadline = now_ms() + HARD_BUDGET_MS;
    const char *provider = NULL, *log = NULL;
    int emit_empty = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--provider") && i + 1 < argc) provider = argv[++i];
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) log = argv[++i];
        else if (!strcmp(argv[i], "--emit-empty-json")) emit_empty = 1;
    }
    if (!provider || !*provider || strlen(provider) > 32) return 0;
    for (const char *c = provider; *c; c++) if (!((*c >= 'a' && *c <= 'z') || *c == '_')) return 0;
    int cursor = emit_empty || !strcmp(provider, "cursor") || !strcmp(provider, "gemini");

    char *payload = malloc(MAX_PAYLOAD + 1);
    size_t len = 0;
    if (payload) {
        while (len <= MAX_PAYLOAD) {
            ssize_t n = read(STDIN_FILENO, payload + len, MAX_PAYLOAD + 1 - len);
            if (n <= 0) break;
            len += (size_t)n;
        }
    }
    if (!payload || len > MAX_PAYLOAD) { if (cursor) puts("{}"); return 0; }

    char dir[2048];
    state_dir(dir, sizeof dir);
    char logbuf[4096];
    if (!log || *log != '/') { snprintf(logbuf, sizeof logbuf, "%s/%s.jsonl", dir, provider); log = logbuf; }

    pid_t ppid = getppid();
    double ppid_start = parent_start_time(ppid);

    char escaped_log[4096 * 6 + 1];
    json_escape(escaped_log, log, strlen(log) > 4096 ? 4096 : strlen(log));
    char header[8192];
    int header_len = ppid_start >= 0
        ? snprintf(header, sizeof header, "{\"version\":1,\"provider\":\"%s\",\"log_path\":\"%s\",\"ppid\":%d,\"ppid_start\":%.6f}",
                   provider, escaped_log, (int)ppid, ppid_start)
        : snprintf(header, sizeof header, "{\"version\":1,\"provider\":\"%s\",\"log_path\":\"%s\",\"ppid\":%d}",
                   provider, escaped_log, (int)ppid);
    if (header_len <= 0 || (size_t)header_len >= sizeof header) { if (cursor) puts("{}"); return 0; }

    size_t prefix = sizeof(MAGIC) - 1 + 8;
    char *frame = malloc(prefix + (size_t)header_len + len);
    if (!frame) { if (cursor) puts("{}"); return 0; }
    memcpy(frame, MAGIC, sizeof(MAGIC) - 1);
    uint32_t h = (uint32_t)header_len, p = (uint32_t)len;
    unsigned char *lengths = (unsigned char *)frame + sizeof(MAGIC) - 1;
    lengths[0] = h >> 24; lengths[1] = h >> 16; lengths[2] = h >> 8; lengths[3] = h;
    lengths[4] = p >> 24; lengths[5] = p >> 16; lengths[6] = p >> 8; lengths[7] = p;
    memcpy(frame + prefix, header, (size_t)header_len);
    memcpy(frame + prefix + header_len, payload, len);

    int result = deliver(dir, frame, prefix + (size_t)header_len + len, deadline);
    if (result == -1) queue_pending(dir, provider, ppid, ppid_start, payload, len);
    if (cursor) puts("{}");
    return 0;
}
