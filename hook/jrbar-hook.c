/*
 * jrbar-hook: the compiled hook shim.
 *
 * Agent providers (Claude Code, Codex, ...) run this at every hook event.
 * It reads the payload from stdin, hands it to the JR-Bar daemon over the
 * hook-ingress socket in the existing wire format
 * (src/jrbar/hook_ingress_protocol.py) and exits 0. When the daemon is not
 * listening, or the frame did not get through whole, the payload is
 * appended to <state>/<provider>.pending.jsonl with the time it was queued
 * and the daemon drains that file later (src/jrbar/hook_pending.py). The
 * file rotates to <provider>.overflow.jsonl at MAX_SPOOL_BYTES. Nothing here
 * can block an agent: everything after the payload is read is bounded by
 * HARD_BUDGET_MS -- by DECIDE_WAIT_MS for the verdict wait of --decide,
 * below -- and every failure path exits 0.
 *
 *   jrbar-hook --provider <id> [--log <path>] [--decide]
 *
 * For --provider cursor or gemini (or with --emit-empty-json) the shim
 * prints "{}" on stdout, as Cursor's and Gemini CLI's hook
 * contract requires; otherwise it prints nothing.
 *
 * --decide is the decide lane, installed only on Claude Code's and Codex's
 * PermissionRequest hook. Delivery is unchanged and keeps its budget; the
 * shim then stays on the socket for up to DECIDE_WAIT_MS while the daemon
 * holds the request for an explicit Approve or Deny from any JR-Bar
 * surface, and prints the verdict line the daemon sends: the provider's own
 * {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":...}}.
 * A lapsed hold, a released request, a daemon that is down or a reply that
 * does not look like a verdict all print nothing, which is the documented
 * "no decision" for both agents: their own prompt carries on. The wait is
 * bounded here, not by the daemon, and the installed hook timeout (60 s) is
 * longer, so the agent never has to kill the shim.
 */
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_PAYLOAD (1024 * 1024)
/* The spool is bounded here, not by the daemon: while it is down nothing
 * else trims the file, and a multi-agent session spooled 53 MB at ~23 MB/h
 * (2026-09-22). */
#define MAX_SPOOL_BYTES (16 * 1024 * 1024)
#define HARD_BUDGET_MS 250
#define REPLY_TIMEOUT_MS 200
/* Kept back from delivery for the spool's lock, so a frame the budget cut
 * short can still wait out another shim's append or rotation. */
#define SPOOL_RESERVE_MS 10
/* How long --decide waits for the verdict once the payload is in hand
 * (src/jrbar/hook_ingress_protocol.py HOOK_DECISION_WAIT_MS). */
#define DECIDE_WAIT_MS 50000
/* The disposition line plus the verdict line; a reply that would not fit
 * is not a verdict (MAX_HOOK_DECISION_BYTES). */
#define MAX_REPLY_BYTES (64 + 64 * 1024)
#define DECISION_PREFIX "{\"hookSpecificOutput\":"
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

/* The verdict in a --decide reply, or 0 for "print nothing". The reply is
 * the disposition line, then at most one more line: the whole line must be
 * there, must follow an "accepted" disposition and must open a
 * hookSpecificOutput document. Anything short of that is not a decision,
 * and the agent's own prompt is the safe reading of a bad reply. */
static size_t decide_verdict(const char *reply, size_t len, const char **verdict) {
    const char *newline = memchr(reply, '\n', len);
    if (!newline) return 0;
    size_t head = (size_t)(newline - reply);
    if (head != strlen("accepted") || memcmp(reply, "accepted", head) != 0) return 0;
    const char *line = newline + 1;
    size_t rest = len - head - 1;
    size_t prefix = strlen(DECISION_PREFIX);
    if (rest <= prefix || line[rest - 1] != '\n' || memcmp(line, DECISION_PREFIX, prefix) != 0) return 0;
    if (memchr(line, '\n', rest - 1)) return 0;
    *verdict = line;
    return rest;
}

/* Send the whole frame and wait for the one-line reply. 0 once the whole
 * frame is sent, reply or not: the daemon may have queued it, so it is
 * never re-queued. -1 when the socket was unavailable; -2 when the budget
 * or an error cut the send short. A truncated frame never decodes (the
 * daemon records refused_invalid), so both failures are spooled.
 *
 * With `reply` (--decide) the read runs until the daemon closes the
 * connection, the buffer is full or `decide_deadline` passes, and the bytes
 * read land in `reply`/`*reply_len`. Only the send is held to `deadline`:
 * the frame reaches the daemon inside the hook budget either way, and the
 * wait after it is the decide lane's own bound. */
static int deliver(const char *dir, const char *frame, size_t frame_len, uint64_t deadline,
                   char *reply, size_t reply_cap, size_t *reply_len, uint64_t decide_deadline) {
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
    if (reply) {
        size_t got = 0;
        while (got < reply_cap) {
            left = (int64_t)decide_deadline - (int64_t)now_ms();
            if (left <= 0 || poll(&pfd, 1, (int)left) <= 0) break;
            ssize_t n = read(fd, reply + got, reply_cap - got);
            if (n <= 0) break;
            got += (size_t)n;
        }
        *reply_len = got;
        close(fd);
        return 0;
    }
    left = (int64_t)deadline - (int64_t)now_ms();
    if (left > REPLY_TIMEOUT_MS) left = REPLY_TIMEOUT_MS;
    if (left > 0 && poll(&pfd, 1, (int)left) > 0) {
        char ack[80];
        (void)read(fd, ack, sizeof ack);
    }
    close(fd);
    return 0;
}

static int open_spool(const char *path) {
    return open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600);
}

/* Whether `path` still names the file `st` describes. */
static int spool_still_at(const char *path, const struct stat *st) {
    struct stat at;
    return lstat(path, &at) == 0 && at.st_ino == st->st_ino && at.st_dev == st->st_dev;
}

/* Lock the spool without blocking past `deadline`; the first try is made
 * even when the budget is spent. 0 once the lock is held and `path` still
 * names the file, -1 when the file moved (the caller reopens: a lock on it
 * would guard a file nothing appends to any more), -2 when the deadline
 * passed. */
static int lock_spool(int fd, const char *path, const struct stat *st, uint64_t deadline) {
    for (;;) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) return spool_still_at(path, st) ? 0 : -1;
        if (errno != EWOULDBLOCK && errno != EINTR) return -2;
        if (!spool_still_at(path, st)) return -1;
        if (now_ms() >= deadline) return -2;
        usleep(250);
    }
}

/* An fd on the spool with room for `need` more bytes, holding the lock
 * until it is closed. At the cap the file is renamed to `overflow` (one
 * generation kept) and a fresh one opened: the line is always written,
 * because the newest events are the ones the daemon's live state needs.
 * When the rename fails (a read-only state directory, a directory at
 * `overflow`) the line goes on the end of the full file, past the cap:
 * every retry would find the same full file and fail the same way, and a
 * shim that retried spun until the agent's own hook timeout killed it.
 *
 * Every appender holds the lock from its size check through its write, so
 * checking for room, writing and rotating are one step and no line can
 * follow the file into `overflow`, which is never replayed. Only the
 * rotating shim used to lock: one that had found room just before another
 * renamed the file wrote its line after the rename, into the overflow
 * generation. A shared lock for appenders is not enough either: two that
 * both found room overran the cap together, and a shim at the cap ran out
 * its budget waiting for a moment with no appender inside (both measured
 * with 200 concurrent shims around a rotation). Appends take microseconds,
 * so taking turns costs nothing an agent can see.
 *
 * The daemon renames a file before it drains it and then takes the lock
 * on the renamed file, so an append already under way lands before the
 * read, and a shim that locks later finds the file moved and reopens
 * `path`. A file only moves when a drain or a rotation made progress, so
 * the shim reopens until its deadline; past it the line is appended
 * without the lock to the file `path` names, past the cap if need be. Only
 * then can a drain or rotation at that same moment still take it. */
static int open_spool_with_room(const char *path, const char *overflow, size_t need, uint64_t deadline) {
    for (;;) {
        int fd = open_spool(path);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) != 0) return fd;
        int locked = lock_spool(fd, path, &st, deadline);
        if (locked == -2) return fd;
        if (locked == 0) {
            /* The size is read under the lock: every earlier append has landed. */
            if (fstat(fd, &st) != 0 || st.st_size == 0
                || (uint64_t)st.st_size + need <= MAX_SPOOL_BYTES) return fd;
            /* ENOENT is a drain that took the file after the lock was
             * checked; there is a fresh one to open. */
            if (rename(path, overflow) != 0 && errno != ENOENT) return fd;
        }
        /* The file moved or was rotated. Every pass that goes round again
         * comes through here, so the loop ends at the deadline. */
        close(fd);
        if (now_ms() >= deadline) return open_spool(path);
    }
}

static void queue_pending(const char *dir, const char *provider, pid_t ppid, double ppid_start,
                          uint64_t queued_at_ms, const char *payload, size_t payload_len, uint64_t deadline) {
    char path[4096], overflow[4096];
    if ((size_t)snprintf(path, sizeof path, "%s/%s.pending.jsonl", dir, provider) >= sizeof path) return;
    if ((size_t)snprintf(overflow, sizeof overflow, "%s/%s.overflow.jsonl", dir, provider) >= sizeof overflow) return;
    mkdir(dir, 0700);
    char *escaped = malloc(payload_len * 6 + 1);
    if (!escaped) return;
    json_escape(escaped, payload, payload_len);
    size_t cap = strlen(escaped) + 256;
    char *line = malloc(cap);
    if (!line) { free(escaped); return; }
    int n = snprintf(line, cap,
                     "{\"provider\":\"%s\",\"ppid\":%d,\"ppid_start\":%.6f,\"queued_at_ms\":%llu,\"payload\":\"%s\"}\n",
                     provider, (int)ppid, ppid_start, (unsigned long long)queued_at_ms, escaped);
    if (n > 0 && (size_t)n < cap) {
        int fd = open_spool_with_room(path, overflow, (size_t)n, deadline);
        if (fd >= 0) { (void)write(fd, line, (size_t)n); close(fd); }
    }
    free(line);
    free(escaped);
}

int main(int argc, char **argv) {
    uint64_t started = now_ms();
    const char *provider = NULL, *log = NULL;
    int emit_empty = 0, decide = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--provider") && i + 1 < argc) provider = argv[++i];
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) log = argv[++i];
        else if (!strcmp(argv[i], "--emit-empty-json")) emit_empty = 1;
        else if (!strcmp(argv[i], "--decide")) decide = 1;
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
    /* The budget starts once the payload is in hand. The time an agent
     * takes to write and close stdin is its own; counting it left a shim
     * spawned well before its payload arrived no time to wait out another
     * shim's append (200 shims spawned before any was fed). `started`
     * stays the event's queued time. */
    uint64_t received = now_ms();
    uint64_t deadline = received + HARD_BUDGET_MS;

    char dir[2048];
    state_dir(dir, sizeof dir);
    char logbuf[4096];
    if (!log || *log != '/') { snprintf(logbuf, sizeof logbuf, "%s/%s.jsonl", dir, provider); log = logbuf; }

    pid_t ppid = getppid();
    double ppid_start = parent_start_time(ppid);

    char escaped_log[4096 * 6 + 1];
    json_escape(escaped_log, log, strlen(log) > 4096 ? 4096 : strlen(log));
    char header[8192];
    char decide_field[32] = "";
    if (decide) snprintf(decide_field, sizeof decide_field, ",\"decide_ms\":%d", DECIDE_WAIT_MS);
    int header_len = ppid_start >= 0
        ? snprintf(header, sizeof header, "{\"version\":1,\"provider\":\"%s\",\"log_path\":\"%s\",\"ppid\":%d,\"ppid_start\":%.6f%s}",
                   provider, escaped_log, (int)ppid, ppid_start, decide_field)
        : snprintf(header, sizeof header, "{\"version\":1,\"provider\":\"%s\",\"log_path\":\"%s\",\"ppid\":%d%s}",
                   provider, escaped_log, (int)ppid, decide_field);
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

    char *reply = decide ? malloc(MAX_REPLY_BYTES) : NULL;
    size_t reply_len = 0;
    int result = deliver(dir, frame, prefix + (size_t)header_len + len, deadline - SPOOL_RESERVE_MS,
                         reply, reply ? MAX_REPLY_BYTES : 0, &reply_len, received + DECIDE_WAIT_MS);
    if (result < 0) queue_pending(dir, provider, ppid, ppid_start, started, payload, len, deadline);
    if (reply) {
        const char *verdict = NULL;
        size_t verdict_len = decide_verdict(reply, reply_len, &verdict);
        if (verdict_len) { fwrite(verdict, 1, verdict_len, stdout); fflush(stdout); }
        free(reply);
    }
    if (cursor) puts("{}");
    return 0;
}
