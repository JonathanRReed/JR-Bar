"""A desk with no other agent machine stops asking about one every minute."""

from __future__ import annotations

from dataclasses import replace

from jrbar.remote_peers import (
    LONG_QUIET_TICKS_TO_SKIP,
    QUIET_ROUNDS_BEFORE_BACKOFF,
    QUIET_ROUNDS_BEFORE_LONG_BACKOFF,
    QUIET_TICKS_TO_SKIP,
    PeerHealth,
    PeerRefreshResult,
    quiet_ticks_to_skip,
)
from tests.test_core_runtime import headless  # noqa: F401  (the fixture)


def test_the_skip_ladder_asks_every_minute_at_first_then_every_third_then_every_fifth() -> None:
    assert quiet_ticks_to_skip(0) == 0
    assert quiet_ticks_to_skip(QUIET_ROUNDS_BEFORE_BACKOFF - 1) == 0
    assert quiet_ticks_to_skip(QUIET_ROUNDS_BEFORE_BACKOFF) == QUIET_TICKS_TO_SKIP
    assert quiet_ticks_to_skip(QUIET_ROUNDS_BEFORE_LONG_BACKOFF - 1) == QUIET_TICKS_TO_SKIP
    assert quiet_ticks_to_skip(QUIET_ROUNDS_BEFORE_LONG_BACKOFF) == LONG_QUIET_TICKS_TO_SKIP
    assert quiet_ticks_to_skip(10_000) == LONG_QUIET_TICKS_TO_SKIP


def _minutes_that_ask(controller, minutes: int, answer: PeerRefreshResult | None = None, *, start: int = 1) -> list[int]:
    """Which minute ticks start a round, each round answered with ``answer``
    (no machines unless said) the way the worker thread would deliver it."""
    reply = PeerRefreshResult() if answer is None else answer
    controller.start_remote_peer_refresh.reset_mock()
    asked: list[int] = []
    for minute in range(start, start + minutes):
        before = controller.start_remote_peer_refresh.call_count
        controller.refreshRemotePeers_(None)
        if controller.start_remote_peer_refresh.call_count > before:
            asked.append(minute)
            controller.applyRemotePeerRefresh_(reply)
    return asked


def test_empty_rounds_widen_the_minute_timer_and_a_machine_starts_it_over(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    controller.settings = controller.settings.with_remote_peers(
        replace(controller.settings.remote_peers, enabled=True)
    )

    asked = _minutes_that_ask(controller, 45)
    assert asked[:5] == [1, 2, 3, 4, 5], "the first empty rounds still ask every minute"
    assert asked[5:11] == [8, 11, 14, 17, 20, 23], "then every third minute"
    assert asked[-3:] == [35, 40, 45], "after fifteen empty rounds, every fifth"

    found = PeerRefreshResult(health=(PeerHealth(machine="workstation", host="workstation.ts", reachable=True),))
    controller.applyRemotePeerRefresh_(found)
    assert _minutes_that_ask(controller, 4, found, start=46) == [46, 47, 48, 49], (
        "a machine on the network brings the minute pace back"
    )
