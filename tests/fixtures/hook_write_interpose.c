#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee \
    }

static int interrupted = 0;
static int partial = 0;

static int is_pending_spool(int descriptor) {
    char path[PATH_MAX];
    if (fcntl(descriptor, F_GETPATH, path) != 0) return 0;
    size_t length = strlen(path);
    const char suffix[] = ".pending.jsonl";
    size_t suffix_length = sizeof suffix - 1;
    return length >= suffix_length && strcmp(path + length - suffix_length, suffix) == 0;
}

static ssize_t jrbar_test_write(int descriptor, const void *buffer, size_t length) {
    if (is_pending_spool(descriptor)) {
        const char *mode = getenv("JRBAR_TEST_WRITE_MODE");
        if (mode && strcmp(mode, "always-eintr") == 0) {
            errno = EINTR;
            return -1;
        }
        if (mode && strcmp(mode, "hard-error") == 0) {
            if (!partial) {
                partial = 1;
                if (length > 7) length = 7;
            } else {
                errno = EIO;
                return -1;
            }
            return (ssize_t)syscall(SYS_write, descriptor, buffer, length);
        }
        if (!interrupted) {
            interrupted = 1;
            errno = EINTR;
            return -1;
        }
        if (length > 7) length = 7;
    }
    return (ssize_t)syscall(SYS_write, descriptor, buffer, length);
}

DYLD_INTERPOSE(jrbar_test_write, write);
