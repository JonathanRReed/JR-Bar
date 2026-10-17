// JR-Bar SD Eject Guard - veto software ejects of cards in the built-in SD reader.
//
// macOS loginwindow dissents the mount and ejects any disk that appears
// while the screen is locked (e.g. the SD slot re-enumerating after a
// hibernate wake). The eject goes through the same DiskArbitration approval
// mechanism, so a registered client can dissent it right back. This tool does
// that, then retries the mount every few seconds; the retries are dissented
// while locked and succeed after unlock. A disk has one retry timer however
// many times it is vetoed, and the retries stop once it mounts, once it
// disappears, or after MOUNT_RETRY_MAX_ATTEMPTS (about twenty minutes).
//
// Build: clang -o "JR-Bar SD Eject Guard" sd_eject_guard.c \
//          -framework DiskArbitration -framework CoreFoundation
// Run:   ./sd_eject_guard --volume-uuid UUID [-n]   (leave running; Ctrl-C to stop)
//        -n / --no-mount: only veto ejects; don't retry mounting.

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MOUNT_RETRY_SECONDS 5.0
#define MOUNT_RETRY_MAX_ATTEMPTS 240
#define MAX_TRACKED_DISKS 8
#define LOG_TRIM_BYTES (10 * 1024 * 1024)

// ---- The retry table: plain C, no DiskArbitration -------------------------
// One slot per BSD name, so a disk that is vetoed again and again (the lock
// screen does it every few seconds) is still retried by a single timer. A
// card that never comes back used to leave one live timer per veto, each
// logging a dissent every five seconds: over a week that was gigabytes of
// log and hours of CPU. The tests compile this section alone, with
// -DJRBAR_GUARD_TEST.

typedef struct {
    char bsd[32];
    int attempts;
    bool used;
    void *handle;  // the caller's timer and disk, kept opaque here
} retry_slot;

static retry_slot g_slots[MAX_TRACKED_DISKS];

static retry_slot *slot_find(const char *bsd) {
    if (!bsd) return NULL;
    for (int i = 0; i < MAX_TRACKED_DISKS; i++)
        if (g_slots[i].used && strcmp(g_slots[i].bsd, bsd) == 0)
            return &g_slots[i];
    return NULL;
}

// The slot already following this disk, else a free one, else NULL: more
// than MAX_TRACKED_DISKS disks at once is not a card slot, so the extras
// go unretried rather than unbounded.
static retry_slot *slot_claim(const char *bsd) {
    if (!bsd || !*bsd) return NULL;
    retry_slot *held = slot_find(bsd);
    if (held) return held;
    for (int i = 0; i < MAX_TRACKED_DISKS; i++) {
        if (!g_slots[i].used) {
            memset(&g_slots[i], 0, sizeof(g_slots[i]));
            strlcpy(g_slots[i].bsd, bsd, sizeof(g_slots[i].bsd));
            g_slots[i].used = true;
            return &g_slots[i];
        }
    }
    return NULL;
}

static void slot_release(retry_slot *slot) {
    if (slot) memset(slot, 0, sizeof(*slot));
}

// Count one more try; false once the disk has had its share.
static bool slot_may_try_again(retry_slot *slot) {
    return slot && ++slot->attempts <= MOUNT_RETRY_MAX_ATTEMPTS;
}

// Keep the session's original daemon identity through unreadable PID-file gaps.
typedef struct {
    long initial_pid;
    bool restart_requested;
} daemon_watch;

static inline long read_daemon_pid(const char *path) {
    FILE *file = fopen(path, "r");
    if (!file) return 0;
    char line[64];
    bool read = fgets(line, sizeof(line), file) != NULL;
    bool complete = fgetc(file) == EOF && !ferror(file);
    fclose(file);
    if (!read || !complete) return 0;
    errno = 0;
    char *end;
    long pid = strtol(line, &end, 10);
    if (errno || end == line || pid <= 0 || pid > INT_MAX) return 0;
    while (isspace((unsigned char)*end)) end++;
    return *end == '\0' ? pid : 0;
}

static inline bool daemon_watch_changed(daemon_watch *watch, long pid) {
    if (watch->restart_requested || pid <= 0 || pid == watch->initial_pid) return false;
    watch->restart_requested = true;
    return true;
}

#ifndef JRBAR_GUARD_TEST

#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>

#define DA_PID_CHECK_SECONDS 1.0
#ifndef JRBAR_GUARD_DA_PIDFILE
#define JRBAR_GUARD_DA_PIDFILE "/var/run/diskarbitrationd.pid"
#endif

static DASessionRef g_session;
static daemon_watch g_daemon_watch;

static void check_daemon(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    (void)context;
    long pid = read_daemon_pid(JRBAR_GUARD_DA_PIDFILE);
    if (!daemon_watch_changed(&g_daemon_watch, pid)) return;
    fprintf(stderr, "Disk Arbitration identity changed from %ld to %ld; restarting guard\n",
            g_daemon_watch.initial_pid, pid);
    fflush(stderr);
    // The configured launchd job owns restarting with fresh callbacks.
    exit(0);
}
static bool g_no_mount = false;
static CFStringRef g_selected_volume_uuid = NULL;

// The log is a file launchd owns; keep it from growing without bound.
static void trim_log_if_large(void) {
    fflush(stdout);
    int fd = fileno(stdout);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) return;
    if (st.st_size <= LOG_TRIM_BYTES) return;
    if (ftruncate(fd, 0) == 0) lseek(fd, 0, SEEK_SET);
    clearerr(stdout);
}

static void log_msg(const char *fmt, CFStringRef s) {
    char buf[256] = "?";
    if (s) CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
    printf(fmt, buf);
    fflush(stdout);
}

static bool is_selected_sidepulse_volume(DADiskRef disk) {
    CFDictionaryRef desc = DADiskCopyDescription(disk);
    if (!desc) return false;
    CFUUIDRef uuid = CFDictionaryGetValue(desc, kDADiskDescriptionVolumeUUIDKey);
    CFStringRef name = CFDictionaryGetValue(desc, kDADiskDescriptionVolumeNameKey);
    CFStringRef value = uuid ? CFUUIDCreateString(kCFAllocatorDefault, uuid) : NULL;
    bool match = name && CFStringHasPrefix(name, CFSTR("SidePulse")) &&
        value && g_selected_volume_uuid &&
        CFStringCompare(value, g_selected_volume_uuid, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    if (value) CFRelease(value);
    CFRelease(desc);
    return match;
}

static bool is_mounted(DADiskRef disk) {
    CFDictionaryRef desc = DADiskCopyDescription(disk);
    if (!desc) return false;
    bool mounted = CFDictionaryGetValue(desc, kDADiskDescriptionVolumePathKey) != NULL;
    CFRelease(desc);
    return mounted;
}

typedef struct {
    DADiskRef disk;
    CFRunLoopTimerRef timer;
} retry_handle;

static void mount_done(DADiskRef disk, DADissenterRef dissenter, void *ctx);

static void stop_retries(retry_slot *slot) {
    if (!slot) return;
    retry_handle *handle = (retry_handle *)slot->handle;
    if (handle) {
        if (handle->timer) {
            CFRunLoopTimerInvalidate(handle->timer);
            CFRelease(handle->timer);
        }
        if (handle->disk) CFRelease(handle->disk);
        free(handle);
    }
    slot_release(slot);
}

static void retry_mount(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    retry_slot *slot = (retry_slot *)info;
    retry_handle *handle = (retry_handle *)slot->handle;
    DADiskRef disk = handle->disk;
    if (is_mounted(disk)) {
        trim_log_if_large();
        printf("mounted; stopping retries for %s\n", slot->bsd);
        fflush(stdout);
        stop_retries(slot);
        return;
    }
    if (!slot_may_try_again(slot)) {
        trim_log_if_large();
        printf("giving up on %s after %d tries\n", slot->bsd, MOUNT_RETRY_MAX_ATTEMPTS);
        fflush(stdout);
        stop_retries(slot);
        return;
    }
    DADiskMount(disk, NULL, kDADiskMountOptionDefault, mount_done, NULL);
}

// Only the first dissent and a success are worth a line: while the screen
// is locked every retry is dissented, and saying so every five seconds is
// what filled the log.
static void mount_done(DADiskRef disk, DADissenterRef dissenter, void *ctx) {
    (void)ctx;
    retry_slot *slot = slot_find(DADiskGetBSDName(disk));
    if (dissenter) {
        if (slot && slot->attempts > 1) return;
        trim_log_if_large();
        printf("mount of %s dissented (0x%x), will retry quietly\n",
               DADiskGetBSDName(disk), DADissenterGetStatus(dissenter));
    } else {
        trim_log_if_large();
        printf("mount of %s succeeded\n", DADiskGetBSDName(disk));
    }
    fflush(stdout);
}

static void start_mount_retries(DADiskRef disk) {
    const char *bsd = DADiskGetBSDName(disk);
    if (slot_find(bsd)) return;  // already being retried
    retry_slot *slot = slot_claim(bsd);
    if (!slot) return;
    retry_handle *handle = calloc(1, sizeof(*handle));
    if (!handle) {
        slot_release(slot);
        return;
    }
    handle->disk = (DADiskRef)CFRetain(disk);
    slot->handle = handle;
    CFRunLoopTimerContext tctx = { 0, slot, NULL, NULL, NULL };
    handle->timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + MOUNT_RETRY_SECONDS,
        MOUNT_RETRY_SECONDS, 0, 0, retry_mount, &tctx);
    if (!handle->timer) {
        stop_retries(slot);
        return;
    }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), handle->timer, kCFRunLoopDefaultMode);
}

static void disk_disappeared(DADiskRef disk, void *ctx) {
    (void)ctx;
    stop_retries(slot_find(DADiskGetBSDName(disk)));
}

static DADissenterRef eject_approval(DADiskRef disk, void *ctx) {
    if (!is_selected_sidepulse_volume(disk))
        return NULL;  // not ours, allow
    CFDictionaryRef desc = DADiskCopyDescription(disk);
    CFStringRef vol = desc ? CFDictionaryGetValue(desc, kDADiskDescriptionVolumeNameKey) : NULL;
    trim_log_if_large();
    printf("vetoing eject of %s", DADiskGetBSDName(disk));
    log_msg(" (volume: %s)\n", vol);
    if (desc) CFRelease(desc);
    if (!g_no_mount)
        start_mount_retries(disk);
    return DADissenterCreate(kCFAllocatorDefault, kDAReturnNotPermitted,
                             CFSTR("JR-Bar SD Eject Guard: keeping SD card attached"));
}

static void disk_appeared(DADiskRef disk, void *ctx) {
    if (!is_selected_sidepulse_volume(disk)) return;
    printf("SD disk appeared: %s\n", DADiskGetBSDName(disk));
    fflush(stdout);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-n") || !strcmp(argv[i], "--no-mount")) {
            g_no_mount = true;
        } else if (!strcmp(argv[i], "--volume-uuid") && i + 1 < argc) {
            g_selected_volume_uuid = CFStringCreateWithCString(
                kCFAllocatorDefault, argv[++i], kCFStringEncodingUTF8);
        } else {
            fprintf(stderr, "usage: %s --volume-uuid UUID [-n | --no-mount]\n", argv[0]);
            return 2;
        }
    }
    if (!g_selected_volume_uuid) {
        fprintf(stderr, "refusing to guard SD media without an explicit --volume-uuid\n");
        return 2;
    }
    g_daemon_watch.initial_pid = read_daemon_pid(JRBAR_GUARD_DA_PIDFILE);
    g_session = DASessionCreate(kCFAllocatorDefault);
    if (!g_session) {
        fprintf(stderr, "DASessionCreate failed\n");
        return 1;
    }
    DARegisterDiskEjectApprovalCallback(g_session, NULL, eject_approval, NULL);
    DARegisterDiskAppearedCallback(g_session, NULL, disk_appeared, NULL);
    DARegisterDiskDisappearedCallback(g_session, NULL, disk_disappeared, NULL);
    DASessionScheduleWithRunLoop(g_session, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    // Catch a restart between reading the identity and registering callbacks.
    check_daemon(NULL, NULL);
    CFRunLoopTimerRef daemon_timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + DA_PID_CHECK_SECONDS,
        DA_PID_CHECK_SECONDS, 0, 0, check_daemon, NULL);
    if (!daemon_timer) {
        fprintf(stderr, "could not schedule Disk Arbitration recovery check\n");
        return 1;
    }
    CFRunLoopTimerSetTolerance(daemon_timer, 0.25);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), daemon_timer, kCFRunLoopDefaultMode);
    CFRelease(daemon_timer);
    printf("JR-Bar SD Eject Guard: watching one selected volume UUID%s...\n",
           g_no_mount ? " (mount retries disabled)" : "");
    fflush(stdout);
    CFRunLoopRun();
    return 0;
}

#endif  // JRBAR_GUARD_TEST
