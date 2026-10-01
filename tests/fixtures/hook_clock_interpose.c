/* Test-only: steps the wall clock a hook shim reads, so a test can prove the
 * shim's budgets do not run on it.
 *
 * Loaded with DYLD_INSERT_LIBRARIES into the shim only. It interposes
 * gettimeofday and clock_gettime(CLOCK_REALTIME), the two ways a C program
 * reads the wall clock, and leaves every other clock alone. The first
 * JRBAR_TEST_WALL_STEP_AFTER reads (default 2: the shim's own start and the
 * moment its payload is in hand) are true; every read after that is moved by
 * JRBAR_TEST_WALL_STEP_SECONDS (negative steps it back, as an NTP correction
 * does; positive steps it forward, as a wake from sleep does).
 *
 * A shim that keeps its deadlines on the monotonic clock reads the wall clock
 * once, for the time it stamps on a spooled record, and never meets the step.
 * One that still computes a deadline from the wall clock reads it again and
 * its poll or wait is stretched or cut by the whole step. */
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee \
    }

static long reads = 0;

static long wall_step(void) {
    reads++;
    const char *after = getenv("JRBAR_TEST_WALL_STEP_AFTER");
    long skip = after ? atol(after) : 2;
    if (reads <= skip) return 0;
    const char *step = getenv("JRBAR_TEST_WALL_STEP_SECONDS");
    return step ? atol(step) : 0;
}

static int jrbar_test_gettimeofday(struct timeval *tv, void *tz) {
    int result = gettimeofday(tv, tz);
    if (result == 0 && tv) tv->tv_sec += wall_step();
    return result;
}

static int jrbar_test_clock_gettime(clockid_t clock, struct timespec *ts) {
    int result = clock_gettime(clock, ts);
    if (result == 0 && ts && clock == CLOCK_REALTIME) ts->tv_sec += wall_step();
    return result;
}

DYLD_INTERPOSE(jrbar_test_gettimeofday, gettimeofday);
DYLD_INTERPOSE(jrbar_test_clock_gettime, clock_gettime);
