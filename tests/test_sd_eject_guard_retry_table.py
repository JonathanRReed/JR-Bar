"""The eject guard keeps one mount-retry timer per disk, not one per veto.

inteliwear/sidepulse#42 reported the guard leaking a live timer on every
vetoed eject (526 vetoes of one disk left 526 timers and a 1.7 GB log). The
fix lives in the guard's plain-C retry table, which this test compiles on its
own (``-DJRBAR_GUARD_TEST``) with the system compiler and drives directly.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

GUARD_SOURCE = Path(__file__).resolve().parents[1] / "src" / "jrbar" / "resources" / "sd_eject_guard.c"
CLANG = shutil.which("clang")

HARNESS = r"""
#define JRBAR_GUARD_TEST 1
#include "%s"
#include <assert.h>

int main(void) {
    // 526 vetoes of one disk still claim one slot.
    retry_slot *first = slot_claim("disk12");
    assert(first != NULL);
    int distinct = 0;
    for (int i = 0; i < 526; i++) {
        retry_slot *again = slot_claim("disk12");
        assert(again == first);
    }
    for (int i = 0; i < MAX_TRACKED_DISKS; i++) if (g_slots[i].used) distinct++;
    assert(distinct == 1);

    // A disappeared disk frees its slot, and the name can be claimed again.
    slot_release(slot_find("disk12"));
    assert(slot_find("disk12") == NULL);
    assert(slot_claim("disk12") != NULL);
    slot_release(slot_find("disk12"));

    // Distinct disks are capped; extras are refused, not queued.
    char name[16];
    for (int i = 0; i < MAX_TRACKED_DISKS; i++) {
        snprintf(name, sizeof(name), "disk%%d", 20 + i);
        assert(slot_claim(name) != NULL);
    }
    assert(slot_claim("disk99") == NULL);
    assert(slot_claim("") == NULL);
    assert(slot_claim(NULL) == NULL);
    for (int i = 0; i < MAX_TRACKED_DISKS; i++) {
        snprintf(name, sizeof(name), "disk%%d", 20 + i);
        slot_release(slot_find(name));
    }

    // A disk is retried MOUNT_RETRY_MAX_ATTEMPTS times and then given up on.
    retry_slot *stubborn = slot_claim("disk7");
    int tries = 0;
    while (slot_may_try_again(stubborn)) tries++;
    assert(tries == MOUNT_RETRY_MAX_ATTEMPTS);
    assert(!slot_may_try_again(stubborn));
    assert(!slot_may_try_again(NULL));
    printf("ok\n");
    return 0;
}
"""


@pytest.mark.skipif(CLANG is None, reason="needs the system C compiler")
def test_a_repeatedly_vetoed_disk_has_one_retry_slot_and_a_bounded_number_of_tries(tmp_path: Path) -> None:
    harness = tmp_path / "harness.c"
    harness.write_text(HARNESS % GUARD_SOURCE)
    binary = tmp_path / "harness"
    build = subprocess.run(
        [CLANG, "-Wall", "-Werror", "-o", str(binary), str(harness)],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert build.returncode == 0, build.stderr
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30, check=False)
    assert run.returncode == 0, run.stdout + run.stderr
    assert run.stdout.strip() == "ok"


@pytest.mark.skipif(CLANG is None, reason="needs the system C compiler")
def test_the_whole_guard_still_builds_against_diskarbitration(tmp_path: Path) -> None:
    build = subprocess.run(
        [
            CLANG,
            "-Wall",
            "-Werror",
            "-o",
            str(tmp_path / "guard"),
            str(GUARD_SOURCE),
            "-framework",
            "DiskArbitration",
            "-framework",
            "CoreFoundation",
        ],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert build.returncode == 0, build.stderr
