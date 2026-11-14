"""Token-history work started by a test ends with that test.

The daemon warms its transcript caches eight seconds after it is ready and
then again every minute, for as long as its history service lives. A test
that starts a daemon with real threads and walks away leaves that loop
running for the rest of the run. A minute later it scans in the middle of
some other test, which then sees a process, a file read or a log line that
is not its own.

``history_work_ends_here`` closes every history service made inside it and
waits for the warm-up loops those services were feeding.
"""

from __future__ import annotations

import contextlib
import threading
from collections.abc import Iterator

import pytest

#: The daemon's names for its history threads (core_runtime, core_usage_history).
WARM_THREAD = "JRBarUsageWarm"
SCAN_THREAD = "JRBarUsageScan"

#: A closed warm-up loop is parked on the service's stop flag, so it ends at once.
WARM_JOIN_SECONDS = 5.0
#: A scan cannot be interrupted. One already reading gets a moment to finish.
SCAN_JOIN_SECONDS = 2.0


def history_threads(prefix: str) -> list[threading.Thread]:
    return [thread for thread in threading.enumerate() if thread.name.startswith(prefix)]


@contextlib.contextmanager
def history_work_ends_here() -> Iterator[list]:
    """Close each ``UsageHistoryService`` made inside, then see its threads out.

    Yields the services made so far. Raises when a warm-up loop started
    inside is still alive afterwards: that loop would outlive its test.
    """
    from jrbar.core_usage_history import UsageHistoryService

    before = set(threading.enumerate())
    services: list = []
    original_init = UsageHistoryService.__init__

    def tracked_init(service, *args, **kwargs):
        original_init(service, *args, **kwargs)
        services.append(service)

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(UsageHistoryService, "__init__", tracked_init)
        try:
            yield services
        finally:
            for service in services:
                service.close()
            warm = [thread for thread in history_threads(WARM_THREAD) if thread not in before]
            scans = [thread for thread in history_threads(SCAN_THREAD) if thread not in before]
            for thread in warm:
                thread.join(timeout=WARM_JOIN_SECONDS)
            for thread in scans:
                thread.join(timeout=SCAN_JOIN_SECONDS)
    left = [thread.name for thread in warm if thread.is_alive()]
    if left:
        raise AssertionError(f"history warm-up outlived its test: {left}")
