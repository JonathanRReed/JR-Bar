"""Incident feeds are advisory context: silence on anything unexpected."""

from __future__ import annotations

import threading

from jrbar.status_feeds import (
    STATUS_FEED_THREAD_NAME,
    FeedState,
    StatusFeedPoller,
    incident_row_title,
    incidents_from_documents,
    parse_statuspage_indicator,
)


def test_parse_accepts_statuspage_shape_only__and_2_more() -> None:
    # --- scenario: parse_accepts_statuspage_shape_only
    good = {"status": {"indicator": "major", "description": "Elevated errors"}}
    assert parse_statuspage_indicator(good) == ("major", "Elevated errors")
    assert parse_statuspage_indicator({"status": {}}) is None
    assert parse_statuspage_indicator({"weird": True}) is None
    assert parse_statuspage_indicator("not a dict") is None
    assert (
        parse_statuspage_indicator(
            {"status": {"indicator": "surprising", "description": "unknown"}}
        )
        is None
    )

    # --- scenario: healthy_feeds_produce_no_incident
    documents = {
        "claude": {"status": {"indicator": "none", "description": "All good"}},
        "codex": {"status": {"indicator": "minor", "description": "API errors"}},
        "unknown-provider": {"status": {"indicator": "major", "description": "x"}},
        "cursor": {"broken": True},
    }
    incidents = incidents_from_documents(documents)
    assert set(incidents) == {"codex"}
    assert incidents["codex"].vendor == "OpenAI"
    assert "OpenAI" in incident_row_title(incidents["codex"])
    assert incidents["codex"].page_url.startswith("https://")

    # --- scenario: poller_exposes_only_fresh_confirmed_incidents
    now = {"value": 100.0}
    documents = iter(
        (
            {"status": {"indicator": "major", "description": "API errors"}},
            OSError("offline"),
        )
    )
    calls: list[tuple[str, dict[str, str], float, int]] = []

    def fetch(url, *, headers, timeout, max_bytes):
        calls.append((url, headers, timeout, max_bytes))
        result = next(documents)
        if isinstance(result, Exception):
            raise result
        return result

    poller = StatusFeedPoller(
        feeds={"codex": ("OpenAI", "https://status.example/api", "https://status.example")},
        fetch_json=fetch,
        clock=lambda: now["value"],
        freshness_seconds=60.0,
    )

    poller.poll_once()
    incident = poller.incident_for("codex", now=100.0)
    assert incident is not None
    assert incident.description == "API errors"
    assert incident.source_url == "https://status.example/api"
    assert incident.observed_at == 100.0
    assert poller.feed_state("codex", now=100.0) is FeedState.CONFIRMED_INCIDENT
    assert calls == [
        (
            "https://status.example/api",
            {"Accept": "application/json", "User-Agent": "JR-Bar/status-feed"},
            10.0,
            65_536,
        )
    ]

    now["value"] = 101.0
    poller.poll_once()
    assert poller.incident_for("codex", now=101.0) is None
    assert poller.feed_state("codex", now=101.0) is FeedState.UNAVAILABLE



def test_poller_distinguishes_healthy_and_stale_feeds() -> None:
    now = {"value": 200.0}
    poller = StatusFeedPoller(
        feeds={"claude": ("Anthropic", "https://status.example/api", "https://status.example")},
        fetch_json=lambda *_args, **_kwargs: {
            "status": {"indicator": "none", "description": "All systems operational"}
        },
        clock=lambda: now["value"],
        freshness_seconds=30.0,
    )

    poller.poll_once()
    assert poller.feed_state("claude", now=200.0) is FeedState.NO_INCIDENT
    assert poller.incident_for("claude", now=200.0) is None

    now["value"] = 231.0
    assert poller.feed_state("claude", now=231.0) is FeedState.STALE


def test_status_feed_worker_uses_current_product_identity_and_scoped_start(
    monkeypatch,
) -> None:
    started: list[tuple[str, bool]] = []

    class Thread:
        def __init__(self, *, target, name, daemon):
            del target
            started.append((name, daemon))

        def start(self):
            return None

    monkeypatch.setattr("jrbar.status_feeds.threading.Thread", Thread)

    poller = StatusFeedPoller()
    poller.start(provider_ids=("codex",))
    poller.start(provider_ids=("codex",))

    assert STATUS_FEED_THREAD_NAME == "JR-BarStatusFeeds"
    assert started == [("JR-BarStatusFeeds-codex", True)]


def test_scoped_poll_fetches_only_requested_provider() -> None:
    fetched: list[str] = []
    poller = StatusFeedPoller(
        feeds={
            "codex": ("OpenAI", "https://status.example/codex", "https://status.example"),
            "claude": (
                "Anthropic",
                "https://status.example/claude",
                "https://status.example",
            ),
        },
        fetch_json=lambda url, **_kwargs: (
            fetched.append(url)
            or {"status": {"indicator": "none", "description": "Healthy"}}
        ),
    )

    poller.poll_once(provider_ids=("codex",))

    assert fetched == ["https://status.example/codex"]
    assert poller.feed_state("claude") is FeedState.UNAVAILABLE


# --- stopping a feed ------------------------------------------------------------
#
# Every wait below is on an Event with a timeout, and the poll cadence is
# passed in, so nothing depends on how long a real 10 minutes takes.

_HEALTHY = {"status": {"indicator": "none", "description": "All systems operational"}}
_CODEX_FEED = {"codex": ("OpenAI", "https://status.example/codex", "https://status.example")}


def test_stop_ends_the_feed_thread_and_it_makes_no_further_request() -> None:
    first_fetch = threading.Event()
    fetchers: list[threading.Thread] = []
    fetched: list[str] = []

    def fetch(url, **_kwargs):
        fetched.append(url)
        fetchers.append(threading.current_thread())
        first_fetch.set()
        return _HEALTHY

    poller = StatusFeedPoller(feeds=_CODEX_FEED, fetch_json=fetch)
    poller.start(provider_ids=("codex",))
    assert first_fetch.wait(5.0)

    # The loop is now waiting out its 600 s; stop wakes it instead of sleeping.
    assert poller.stop() == ("codex",)

    assert not fetchers[0].is_alive()
    assert fetched == ["https://status.example/codex"]
    assert poller.stop() == ()


def test_stop_scopes_to_the_providers_it_is_given() -> None:
    both_fetched = threading.Event()
    fetchers: dict[str, threading.Thread] = {}

    def fetch(url, **_kwargs):
        fetchers[url] = threading.current_thread()
        if len(fetchers) == 2:
            both_fetched.set()
        return _HEALTHY

    poller = StatusFeedPoller(
        feeds={
            **_CODEX_FEED,
            "claude": ("Anthropic", "https://status.example/claude", "https://status.example"),
        },
        fetch_json=fetch,
    )
    poller.start()
    assert both_fetched.wait(5.0)

    assert poller.stop(provider_ids=("codex",)) == ("codex",)

    assert not fetchers["https://status.example/codex"].is_alive()
    assert fetchers["https://status.example/claude"].is_alive()
    assert poller.stop() == ("claude",)
    assert not fetchers["https://status.example/claude"].is_alive()


def test_a_stopped_feed_can_be_started_again() -> None:
    fetched = threading.Semaphore(0)
    fetchers: list[threading.Thread] = []

    def fetch(url, **_kwargs):
        fetchers.append(threading.current_thread())
        fetched.release()
        return _HEALTHY

    poller = StatusFeedPoller(feeds=_CODEX_FEED, fetch_json=fetch)
    poller.start(provider_ids=("codex",))
    assert fetched.acquire(timeout=5.0)
    poller.stop()

    poller.start(provider_ids=("codex",))
    assert fetched.acquire(timeout=5.0)

    assert len(fetchers) == 2
    assert fetchers[0] is not fetchers[1]
    assert poller.stop() == ("codex",)
    assert not fetchers[1].is_alive()


def test_a_request_in_flight_when_the_feed_stops_records_nothing() -> None:
    in_flight = threading.Event()
    release = threading.Event()
    fetchers: list[threading.Thread] = []

    def fetch(url, **_kwargs):
        fetchers.append(threading.current_thread())
        in_flight.set()
        assert release.wait(5.0)
        return {"status": {"indicator": "major", "description": "Elevated errors"}}

    poller = StatusFeedPoller(feeds=_CODEX_FEED, fetch_json=fetch, clock=lambda: 100.0)
    poller.start(provider_ids=("codex",))
    assert in_flight.wait(5.0)

    # The join is bounded: a request that is still out does not hold stop().
    assert poller.stop(timeout=0.01) == ("codex",)
    release.set()
    fetchers[0].join(5.0)

    assert not fetchers[0].is_alive()
    assert poller.incident_for("codex", now=100.0) is None
    assert poller.feed_state("codex", now=100.0) is FeedState.UNAVAILABLE


def test_stop_forgets_what_the_feed_last_saw() -> None:
    poller = StatusFeedPoller(
        feeds=_CODEX_FEED,
        fetch_json=lambda *_a, **_k: {
            "status": {"indicator": "major", "description": "Elevated errors"}
        },
        clock=lambda: 100.0,
    )
    poller.poll_once()
    poller.start(provider_ids=("codex",))
    assert poller.incident_for("codex", now=100.0) is not None

    poller.stop()

    # Turning the feeds back on later must not show a reading from before.
    assert poller.incident_for("codex", now=100.0) is None
    assert poller.feed_state("codex", now=100.0) is FeedState.UNAVAILABLE


def test_a_feed_whose_gate_closes_ends_without_asking_again() -> None:
    fetchers: list[threading.Thread] = []
    gate_answers = iter((True, False))
    fetched: list[str] = []
    fetched_once = threading.Event()

    def fetch(url, **_kwargs):
        fetched.append(url)
        fetchers.append(threading.current_thread())
        fetched_once.set()
        return _HEALTHY

    poller = StatusFeedPoller(feeds=_CODEX_FEED, fetch_json=fetch, poll_seconds=0.0)
    poller.start(provider_ids=("codex",), enabled=lambda: next(gate_answers))
    assert fetched_once.wait(5.0)
    fetchers[0].join(5.0)

    assert not fetchers[0].is_alive()
    assert fetched == ["https://status.example/codex"]
    # The thread took itself off the books, so the feed can start again.
    assert poller.stop() == ()



def test_stop_does_not_join_a_thread_that_has_not_started_running(monkeypatch) -> None:
    joined: list[str] = []

    class Thread:
        def __init__(self, *, target, name, daemon):
            del target, daemon
            self.name = name

        def start(self):
            return None

        def is_alive(self):
            return False

        def join(self, timeout=None):
            joined.append(self.name)

    monkeypatch.setattr("jrbar.status_feeds.threading.Thread", Thread)
    poller = StatusFeedPoller(feeds=_CODEX_FEED)
    poller.start(provider_ids=("codex",))

    assert poller.stop() == ("codex",)
    assert joined == []
