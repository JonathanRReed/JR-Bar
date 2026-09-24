"""Nothing expensive, blocking or re-entrant runs on a menu-bar timer.

Reported live: "it's super laggy at times." Measured with `sample` on the
running app -- 100.7% CPU sustained, and 65.7% of the main thread inside
``__CFRunLoopDoTimers``. Two callers owned most of it:

  422 -[NSMenuItem accessibilityLabel]
  422   NSAccessibilityGetObjectForAttributeUsingLegacyAPI
  377     -[NSMenu(Accessibility) _openForInspection:]
  377       -[NSMenu _simulateOpening:]
  377         -[NSMenu _sendAndRecordMenuOpeningNotification]   <- menuWillOpen_
   45       -[NSMenu _sendMenuClosedNotification:]              <- menuDidClose_

  636 __NSFireTimer  (is_alcove_running)
   13   -[NSRunningApplication bundleIdentifier]
   10     _LSCopyApplicationInformation
   10       xpc_connection_send_message_with_reply_sync

Reading an accessibility label made AppKit fake-open the whole menu and
run this app's own delegates; that menu is gone with the retired menu bar.
The Alcove probe made one blocking LaunchServices XPC round trip per
running app, on a 2s timer, behind a 3s TTL that did not cover its own
cadence.
"""

from __future__ import annotations

import threading
import time

from jrbar import virtual_device

# --- the LaunchServices probe ----------------------------------------------


class _BlockingProbe:
    """Stands in for one blocking XPC round trip per running app."""

    def __init__(self) -> None:
        self.calls: list[str] = []
        self.release = threading.Event()
        self.started = threading.Event()

    def __call__(self) -> bool:
        self.calls.append(threading.current_thread().name)
        self.started.set()
        self.release.wait(timeout=5.0)
        return True


def test_the_alcove_probe_is_sampled_once_then_never_blocks_again__and_2_more() -> None:
    # --- scenario: the_alcove_probe_is_sampled_once_then_never_blocks_again
    probe = _BlockingProbe()
    probe.release.set()
    presence = virtual_device.AlcovePresenceProbe(probe=probe, ttl_seconds=3.0)

    assert presence.running(now=100.0) is True
    for tick in range(1, 40):
        assert presence.running(now=100.0 + tick * 0.05) is True

    assert len(probe.calls) == 1

    # --- scenario: a_stale_alcove_answer_is_refreshed_off_the_main_thread
    probe = _BlockingProbe()
    probe.release.set()
    presence = virtual_device.AlcovePresenceProbe(probe=probe, ttl_seconds=3.0)
    presence.running(now=100.0)
    main_thread = threading.current_thread().name
    probe.started.clear()

    started = time.monotonic()
    assert presence.running(now=200.0) is True
    elapsed = time.monotonic() - started

    assert probe.started.wait(2.0)

    assert elapsed < 0.05
    assert len(probe.calls) == 2
    assert probe.calls[0] == main_thread
    assert probe.calls[1] != main_thread

    # --- scenario: a_slow_refresh_never_stalls_the_caller_and_is_not_stampeded
    """A 2s timer must not queue a thread per tick behind a slow probe."""
    probe = _BlockingProbe()
    probe.release.set()
    presence = virtual_device.AlcovePresenceProbe(probe=probe, ttl_seconds=3.0)
    presence.running(now=100.0)
    probe.release.clear()

    started = time.monotonic()
    for tick in range(20):
        assert presence.running(now=200.0 + tick) is True
    elapsed = time.monotonic() - started
    probe.release.set()

    assert elapsed < 0.5
    assert len(probe.calls) <= 2


def test_the_probe_answers_not_running_rather_than_raising() -> None:
    def explode() -> bool:
        raise OSError("LaunchServices is having a day")

    presence = virtual_device.AlcovePresenceProbe(probe=explode, ttl_seconds=3.0)

    assert presence.running(now=100.0) is False
