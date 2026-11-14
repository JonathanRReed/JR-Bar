"""A daemon's token-history warm-up ends with the test that started it.

The loop rescans every minute. Left running, it scanned inside whichever
test happened to be on a minute later, and a test that records every
process a provider starts then failed for a scan it never asked for.
"""

from __future__ import annotations

import threading
from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar.core_usage_history import UsageHistoryService
from tests.history_threads import WARM_THREAD, history_threads, history_work_ends_here
from tests.test_core_deck import deck_live  # noqa: F401  (a daemon with real threads)
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)

WAIT_SECONDS = 5.0


def _owner() -> SimpleNamespace:
    return SimpleNamespace(
        settings=SimpleNamespace(token_history_enabled=True, usage_graph_providers=("claude",)),
        last_snapshot=None,
        _core_publish_event=lambda *args, **kwargs: None,
        _core_log=lambda line: None,
    )


def test_a_warm_up_started_inside_is_closed_and_gone_afterwards(monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import token_history_index

    # The warm-up switches the shared index on; put that back afterwards.
    monkeypatch.setattr(token_history_index, "_ENABLED", True)
    monkeypatch.setattr(token_history_index, "_INDEXES", {})
    before = set(history_threads(WARM_THREAD))
    owner = _owner()
    with history_work_ends_here() as services:
        core_runtime._usage_history_warm_later(owner)
        started = [thread for thread in history_threads(WARM_THREAD) if thread not in before]
        assert len(started) == 1 and started[0].is_alive()
        assert services == [owner._core_usage_history_service]
        assert not services[0].stopping.is_set()
    assert services[0].stopping.is_set()
    assert not started[0].is_alive()


def test_a_warm_up_that_ignores_its_stop_flag_is_reported() -> None:
    release = threading.Event()
    running = threading.Event()

    def deaf() -> None:
        running.set()
        release.wait(WAIT_SECONDS * 4)

    try:
        with pytest.MonkeyPatch.context() as mp:
            mp.setattr("tests.history_threads.WARM_JOIN_SECONDS", 0.05)
            with pytest.raises(AssertionError, match="outlived its test"), history_work_ends_here():
                thread = threading.Thread(target=deaf, name=WARM_THREAD, daemon=True)
                thread.start()
                assert running.wait(WAIT_SECONDS)
    finally:
        release.set()
        thread.join(timeout=WAIT_SECONDS)
    assert not thread.is_alive()


def test_a_service_made_before_is_left_alone() -> None:
    kept = UsageHistoryService(lambda provider, days: [])
    with history_work_ends_here() as services:
        made = UsageHistoryService(lambda provider, days: [])
        assert services == [made]
    assert made.stopping.is_set()
    assert not kept.stopping.is_set()
    kept.close()


def test_the_live_daemon_fixture_starts_the_loop_this_guards(deck_live) -> None:  # noqa: F811
    """The fixture that leaked: it boots the daemon on real threads, which
    starts the warm-up. The autouse guard ends it when this test does; the
    next test proves it."""
    assert len(history_threads(WARM_THREAD)) == 1
    assert deck_live._core_usage_history_service is not None


def test_no_warm_up_is_alive_when_a_test_begins() -> None:
    assert history_threads(WARM_THREAD) == []
