"""Provider status pages are opt-in: nothing is contacted until the person turns them on.

`status.anthropic.com`, `status.openai.com` and `status.cursor.com` are polled
only while `provider_status_feeds_enabled` is on, and only for a provider whose
source was found on this Mac. Every wait here is on an Event with a timeout and
every clock and fetch is injected; nothing reaches a real network (conftest
refuses a connect off this Mac in any case).
"""

from __future__ import annotations

import threading
from types import SimpleNamespace

import pytest

from jrbar.provider_usage_platform import ProviderSourceState
from jrbar.status_feeds import STATUS_FEED_THREAD_NAME, StatusFeedPoller
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)
from tests.test_incident_lookup_scope import collector_for, service_with

# --- the default is closed, and the setting opens it ------------------------------


def _feed_threads() -> list[threading.Thread]:
    return [
        thread
        for thread in threading.enumerate()
        if thread.name.startswith(STATUS_FEED_THREAD_NAME)
    ]


class _CountingFetch:
    """An injected fetch that counts calls and answers with a fixture incident."""

    def __init__(self, indicator: str = "major") -> None:
        self.calls: list[str] = []
        self.reached = threading.Semaphore(0)
        self._indicator = indicator

    def __call__(self, url, **_kwargs):
        self.calls.append(url)
        self.reached.release()
        return {"status": {"indicator": self._indicator, "description": "Elevated errors"}}

    def forget(self) -> None:
        """Drop the calls so far, so a test can count only what a feed thread asks."""
        self.calls.clear()
        while self.reached.acquire(blocking=False):
            pass


def _primed_poller(fetch: _CountingFetch) -> StatusFeedPoller:
    """A poller that already holds the fixture incident for codex.

    The reading a feed thread stores lands off-thread; storing one here, on
    the test's own thread, keeps the badge tests from waiting on it.
    """
    poller = _real_poller(fetch)
    poller.poll_once(provider_ids=("codex",))
    fetch.forget()
    return poller


def _real_poller(fetch: _CountingFetch) -> StatusFeedPoller:
    # The real poller class with an injected fetch, standing in for the shared
    # one; a short cadence so a second request would show up if one were made.
    return StatusFeedPoller(fetch_json=fetch, clock=lambda: 1000.0, poll_seconds=600.0)


def test_a_service_with_no_settings_wired_starts_no_feed_and_asks_no_vendor(
    tmp_path, monkeypatch
) -> None:
    fetch = _CountingFetch()
    poller = _real_poller(fetch)
    monkeypatch.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)
    service = service_with(
        tmp_path,
        {"codex": collector_for("codex"), "claude": collector_for("claude")},
    )

    result = service.refresh_now(providers=("codex", "claude"), force=True)

    assert fetch.calls == []
    assert not _feed_threads()
    assert result.by_provider("codex").incident is None
    assert result.by_provider("claude").incident is None
    assert poller.stop() == ()


class _Switch:
    """The daemon's live settings object, as far as the lookup reads it."""

    def __init__(self, enabled: bool) -> None:
        self.settings = SimpleNamespace(provider_status_feeds_enabled=enabled)

    def load(self):
        return self.settings

    def turn(self, enabled: bool) -> None:
        self.settings = SimpleNamespace(provider_status_feeds_enabled=enabled)


def test_off_makes_no_request_and_shows_no_incident_badge(tmp_path, monkeypatch) -> None:
    from jrbar.provider_usage_runtime import status_feed_incident_lookup

    fetch = _CountingFetch()
    poller = _real_poller(fetch)
    monkeypatch.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)
    switch = _Switch(False)
    service = service_with(
        tmp_path,
        {"codex": collector_for("codex")},
        incident_lookup=status_feed_incident_lookup(switch.load),
    )

    result = service.refresh_now(providers=("codex",), force=True)

    assert fetch.calls == []
    assert not _feed_threads()
    assert result.by_provider("codex").incident is None


def test_on_starts_feeds_only_for_the_providers_that_were_found(tmp_path, monkeypatch) -> None:
    from jrbar.provider_usage_runtime import status_feed_incident_lookup

    fetch = _CountingFetch()
    poller = _real_poller(fetch)
    monkeypatch.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)
    service = service_with(
        tmp_path,
        {
            "codex": collector_for("codex"),
            "claude": collector_for("claude", state=ProviderSourceState.SOURCE_NOT_FOUND),
            "cursor": collector_for("cursor", state=ProviderSourceState.SOURCE_NOT_FOUND),
        },
        incident_lookup=status_feed_incident_lookup(_Switch(True).load),
    )

    service.refresh_now(providers=("codex", "claude", "cursor"), force=True)
    assert fetch.reached.acquire(timeout=5.0)

    try:
        assert fetch.calls == ["https://status.openai.com/api/v2/status.json"]
        assert [thread.name for thread in _feed_threads()] == [f"{STATUS_FEED_THREAD_NAME}-codex"]
    finally:
        assert poller.stop() == ("codex",)


def test_on_shows_the_incident_badge_for_a_fixture_incident(tmp_path, monkeypatch) -> None:
    from jrbar.provider_usage_runtime import status_feed_incident_lookup

    fetch = _CountingFetch()
    poller = _primed_poller(fetch)
    monkeypatch.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)
    service = service_with(
        tmp_path,
        {"codex": collector_for("codex")},
        incident_lookup=status_feed_incident_lookup(_Switch(True).load),
    )

    try:
        result = service.refresh_now(providers=("codex",), force=True)

        assert result.by_provider("codex").incident == "OpenAI: Elevated errors"
    finally:
        poller.stop()


def test_turning_it_off_stops_the_feeds_at_the_next_refresh(tmp_path, monkeypatch) -> None:
    from jrbar.provider_usage_runtime import status_feed_incident_lookup

    fetch = _CountingFetch()
    poller = _primed_poller(fetch)
    monkeypatch.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)
    switch = _Switch(True)
    service = service_with(
        tmp_path,
        {"codex": collector_for("codex")},
        incident_lookup=status_feed_incident_lookup(switch.load),
    )
    on = service.refresh_now(providers=("codex",), force=True)
    assert fetch.reached.acquire(timeout=5.0)
    assert on.by_provider("codex").incident == "OpenAI: Elevated errors"
    threads = _feed_threads()
    assert len(threads) == 1

    switch.turn(False)
    result = service.refresh_now(providers=("codex",), force=True)

    threads[0].join(5.0)
    assert not threads[0].is_alive()
    assert not _feed_threads()
    assert fetch.calls == ["https://status.openai.com/api/v2/status.json"]
    # The badge goes with the feed: the reading from before is not shown.
    assert result.by_provider("codex").incident is None
    assert poller.incident_for("codex", now=1000.0) is None


def test_turning_it_on_again_starts_the_feed_afresh(tmp_path, monkeypatch) -> None:
    from jrbar.provider_usage_runtime import status_feed_incident_lookup

    fetch = _CountingFetch()
    poller = _real_poller(fetch)
    monkeypatch.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)
    switch = _Switch(True)
    service = service_with(
        tmp_path,
        {"codex": collector_for("codex")},
        incident_lookup=status_feed_incident_lookup(switch.load),
    )
    try:
        service.refresh_now(providers=("codex",), force=True)
        assert fetch.reached.acquire(timeout=5.0)
        switch.turn(False)
        service.refresh_now(providers=("codex",), force=True)
        switch.turn(True)
        service.refresh_now(providers=("codex",), force=True)
        assert fetch.reached.acquire(timeout=5.0)

        assert len(fetch.calls) == 2
    finally:
        poller.stop()


def test_a_settings_reader_that_fails_leaves_the_feeds_off(tmp_path, monkeypatch) -> None:
    from jrbar.provider_usage_runtime import status_feed_incident_lookup

    fetch = _CountingFetch()
    poller = _real_poller(fetch)
    monkeypatch.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)

    def unreadable():
        raise RuntimeError("settings are unreadable")

    lookup = status_feed_incident_lookup(unreadable)

    assert lookup("codex", 1000.0) is None
    assert fetch.calls == []
    assert not _feed_threads()


@pytest.mark.parametrize("value", ["yes", 1, None, "true"])
def test_only_a_real_true_turns_the_feeds_on(tmp_path, monkeypatch, value) -> None:
    from jrbar.provider_usage_runtime import status_feed_incident_lookup

    fetch = _CountingFetch()
    poller = _real_poller(fetch)
    monkeypatch.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)
    lookup = status_feed_incident_lookup(
        lambda: SimpleNamespace(provider_status_feeds_enabled=value)
    )

    assert lookup("codex", 1000.0) is None
    assert fetch.calls == []
    assert not _feed_threads()



# --- the daemon's own service follows the daemon's own setting --------------------


def test_a_lookup_over_the_daemons_settings_follows_set_setting(headless, monkeypatch) -> None:  # noqa: F811
    from jrbar.provider_usage_runtime import status_feed_incident_lookup

    fetch = _CountingFetch()
    poller = _primed_poller(fetch)
    monkeypatch.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    # What the production service is given: the controller's live settings.
    lookup = status_feed_incident_lookup(lambda: controller.settings)

    # A fresh install: the key is off, so the primed reading is not shown and
    # no feed thread starts.
    assert controller.settings.provider_status_feeds_enabled is False
    assert lookup("codex", 1000.0) is None
    assert fetch.calls == []
    assert not _feed_threads()

    # The Settings switch goes through set_setting; the very next lookup sees it.
    # (The headless harness swaps threading.Thread for one that never runs, so
    # the feed is started but does not fetch; the primed reading is what shows.)
    controller._core_dispatch("set_setting", {"path": "provider_status_feeds_enabled", "value": True})
    assert lookup("codex", 1000.0) == "OpenAI: Elevated errors"

    # Turned off again, the next lookup stops the feed it started and shows
    # nothing: there is no feed left for stop() to find.
    controller._core_dispatch("set_setting", {"path": "provider_status_feeds_enabled", "value": False})
    assert lookup("codex", 1000.0) is None
    assert poller.stop() == ()
    assert fetch.calls == []


def test_the_production_service_is_wired_to_the_live_settings() -> None:
    """`provider_usage_status_bar` builds the only production service; it must
    hand it a lookup over `self.settings`, not fall back to a default."""
    import ast
    from pathlib import Path

    module = Path(__file__).parents[1] / "src" / "jrbar" / "provider_usage_status_bar.py"
    tree = ast.parse(module.read_text(encoding="utf-8"))
    method = next(
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.FunctionDef) and node.name == "_provider_usage_service"
    )
    constructions = [
        call
        for call in ast.walk(method)
        if isinstance(call, ast.Call)
        and isinstance(call.func, ast.Name)
        and call.func.id == "ProviderUsageService"
    ]
    assert len(constructions) == 1
    lookup = next(
        (keyword.value for keyword in constructions[0].keywords if keyword.arg == "incident_lookup"),
        None,
    )
    assert isinstance(lookup, ast.Call)
    assert isinstance(lookup.func, ast.Name) and lookup.func.id == "status_feed_incident_lookup"
    assert ast.unparse(lookup).replace(" ", "") == (
        "status_feed_incident_lookup(settings_loader=lambda:self.settings)"
    )
