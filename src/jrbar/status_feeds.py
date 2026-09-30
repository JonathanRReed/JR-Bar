"""Provider incident feeds: "the provider is down" vs "your fetch broke".

The single biggest false-alarm source for a usage monitor is a provider
incident being read as a local failure. CodexBar's answer, adapted:
poll the public Statuspage summary for each provider that has one, on a
slow cadence, entirely off-main -- and let the usage menu say
"provider incident" next to the provider instead of implying the
user's own setup broke. A feed that cannot be fetched is silence, never
an alarm: the feed is advisory context, not a health source.
"""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener

from .product_identity import PRODUCT_DISPLAY_NAME

POLL_SECONDS = 600.0
#: How long `stop` waits for a feed thread that is mid-request. The thread
#: is a daemon and drops what it reads once stopped, so a slow request never
#: holds the caller for its own 10 s timeout.
STOP_JOIN_SECONDS = 2.0
FETCH_TIMEOUT_SECONDS = 10.0
FETCH_MAX_BYTES = 65_536
FRESHNESS_SECONDS = POLL_SECONDS * 2.0
STATUS_FEED_USER_AGENT = f"{PRODUCT_DISPLAY_NAME}/status-feed"
STATUS_FEED_THREAD_NAME = f"{PRODUCT_DISPLAY_NAME}StatusFeeds"

#: provider_id -> (display name, summary endpoint, human page).
STATUS_FEEDS: dict[str, tuple[str, str, str]] = {
    "claude": (
        "Anthropic",
        "https://status.anthropic.com/api/v2/status.json",
        "https://status.anthropic.com",
    ),
    "codex": (
        "OpenAI",
        "https://status.openai.com/api/v2/status.json",
        "https://status.openai.com",
    ),
    "cursor": (
        "Cursor",
        "https://status.cursor.com/api/v2/status.json",
        "https://status.cursor.com",
    ),
}


@dataclass(frozen=True, slots=True)
class ProviderIncident:
    provider_id: str
    vendor: str
    indicator: str
    description: str
    page_url: str
    source_url: str = ""
    observed_at: float = 0.0


class FeedState(str, Enum):
    UNAVAILABLE = "unavailable"
    STALE = "stale"
    NO_INCIDENT = "no_incident"
    CONFIRMED_INCIDENT = "confirmed_incident"


@dataclass(frozen=True, slots=True)
class _FeedObservation:
    state: FeedState
    observed_at: float
    incident: ProviderIncident | None


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        del req, fp, code, msg, headers, newurl
        return None


def _fetch_status_json(
    url: str,
    *,
    headers: dict[str, str],
    timeout: float,
    max_bytes: int,
) -> object:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("status feed must use https")
    request = Request(url, headers=headers, method="GET")
    opener = build_opener(_NoRedirectHandler(), HTTPSHandler())
    try:
        with opener.open(request, timeout=timeout) as response:
            data = response.read(max_bytes + 1)
            status = int(getattr(response, "status", 200))
    except (HTTPError, URLError, OSError, TimeoutError, ValueError):
        raise OSError("status feed unavailable") from None
    if status < 200 or status >= 300 or len(data) > max_bytes:
        raise OSError("status feed unavailable")
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise OSError("invalid status feed") from None


def parse_statuspage_indicator(payload: object) -> tuple[str, str] | None:
    """(indicator, description) from a Statuspage v2 status document.

    Returns None for anything unexpected -- an unparseable feed is
    silence. "none" is a valid, healthy indicator and IS returned;
    callers decide that healthy means no badge.
    """
    if type(payload) is not dict:
        return None
    status = payload.get("status")
    if type(status) is not dict:
        return None
    indicator = status.get("indicator")
    description = status.get("description")
    if type(indicator) is not str or indicator not in {
        "none",
        "minor",
        "major",
        "critical",
    }:
        return None
    return indicator, str(description or "")


def incidents_from_documents(
    documents: dict[str, object],
) -> dict[str, ProviderIncident]:
    """Active incidents only: healthy feeds produce no entry."""
    incidents: dict[str, ProviderIncident] = {}
    for provider_id, payload in documents.items():
        feed = STATUS_FEEDS.get(provider_id)
        if feed is None:
            continue
        parsed = parse_statuspage_indicator(payload)
        if parsed is None:
            continue
        indicator, description = parsed
        if indicator == "none":
            continue
        incidents[provider_id] = ProviderIncident(
            provider_id=provider_id,
            vendor=feed[0],
            indicator=indicator,
            description=description or indicator.replace("_", " "),
            page_url=feed[2],
        )
    return incidents


def incident_row_title(incident: ProviderIncident) -> str:
    return f"⚠ {incident.vendor}: {incident.description} — status page…"


@dataclass(frozen=True, slots=True)
class _FeedWorker:
    thread: threading.Thread
    stop: threading.Event


class StatusFeedPoller:
    """Slow background poll of every feed; readers only touch a dict.

    A feed runs from `start` until `stop` (or until the `enabled` gate it was
    started with closes). Nothing here starts itself: the caller decides
    whether the person has allowed the requests at all.
    """

    def __init__(
        self,
        *,
        feeds: dict[str, tuple[str, str, str]] | None = None,
        fetch_json: Callable[..., object] = _fetch_status_json,
        clock: Callable[[], float] = time.time,
        freshness_seconds: float = FRESHNESS_SECONDS,
        poll_seconds: float = POLL_SECONDS,
    ) -> None:
        self._feeds = dict(STATUS_FEEDS if feeds is None else feeds)
        self._fetch_json = fetch_json
        self._clock = clock
        self._freshness_seconds = float(freshness_seconds)
        self._poll_seconds = float(poll_seconds)
        self._observations: dict[str, _FeedObservation] = {}
        self._lock = threading.Lock()
        self._workers: dict[str, _FeedWorker] = {}

    def start(
        self,
        *,
        provider_ids: tuple[str, ...] | None = None,
        enabled: Callable[[], bool] | None = None,
    ) -> None:
        """Start a feed thread per provider that has none yet.

        `enabled`, when given, is asked before every request: a feed whose
        gate answers False ends instead of asking the vendor again.
        """
        selected = tuple(self._feeds) if provider_ids is None else provider_ids
        to_start: list[threading.Thread] = []
        with self._lock:
            for provider_id in selected:
                if provider_id in self._feeds and provider_id not in self._workers:
                    stop = threading.Event()
                    thread = threading.Thread(
                        target=lambda selected_id=provider_id, selected_stop=stop: (
                            self._loop(selected_id, selected_stop, enabled)
                        ),
                        name=f"{STATUS_FEED_THREAD_NAME}-{provider_id}",
                        daemon=True,
                    )
                    self._workers[provider_id] = _FeedWorker(thread, stop)
                    to_start.append(thread)
        for thread in to_start:
            thread.start()

    def stop(
        self,
        *,
        provider_ids: tuple[str, ...] | None = None,
        timeout: float = STOP_JOIN_SECONDS,
    ) -> tuple[str, ...]:
        """End the feed threads and forget what they last saw.

        Each thread wakes from its wait at once and makes no further
        request. The join is bounded by `timeout` in total; a request still
        out when it runs out is dropped when it lands. Returns the providers
        that were running, and a stopped feed can be started again.
        """
        with self._lock:
            selected = tuple(
                provider_id
                for provider_id in (
                    tuple(self._workers) if provider_ids is None else provider_ids
                )
                if provider_id in self._workers
            )
            workers = [self._workers.pop(provider_id) for provider_id in selected]
            for provider_id, worker in zip(selected, workers, strict=True):
                worker.stop.set()
                self._observations.pop(provider_id, None)
        deadline = time.monotonic() + max(0.0, float(timeout))
        for worker in workers:
            # A thread not yet running finds its stop set and ends at once.
            if worker.thread is not threading.current_thread() and worker.thread.is_alive():
                worker.thread.join(max(0.0, deadline - time.monotonic()))
        return selected

    def current(self) -> dict[str, ProviderIncident]:
        with self._lock:
            provider_ids = tuple(self._observations)
        now = float(self._clock())
        return {
            provider_id: incident
            for provider_id in provider_ids
            if (incident := self.incident_for(provider_id, now=now)) is not None
        }

    def feed_state(self, provider_id: str, *, now: float | None = None) -> FeedState:
        checked_at = float(self._clock()) if now is None else float(now)
        with self._lock:
            observation = self._observations.get(provider_id)
        if observation is None:
            return FeedState.UNAVAILABLE
        if checked_at - observation.observed_at > self._freshness_seconds:
            return FeedState.STALE
        return observation.state

    def incident_for(
        self, provider_id: str, *, now: float | None = None
    ) -> ProviderIncident | None:
        if self.feed_state(provider_id, now=now) is not FeedState.CONFIRMED_INCIDENT:
            return None
        with self._lock:
            observation = self._observations.get(provider_id)
        return None if observation is None else observation.incident

    def poll_once(
        self,
        *,
        provider_ids: tuple[str, ...] | None = None,
        cancelled: threading.Event | None = None,
    ) -> None:
        selected = set(self._feeds) if provider_ids is None else set(provider_ids)
        for provider_id, (vendor, endpoint, page_url) in self._feeds.items():
            if provider_id not in selected:
                continue
            observed_at = float(self._clock())
            try:
                payload = self._fetch_json(
                    endpoint,
                    headers={"Accept": "application/json", "User-Agent": STATUS_FEED_USER_AGENT},
                    timeout=FETCH_TIMEOUT_SECONDS,
                    max_bytes=FETCH_MAX_BYTES,
                )
                parsed = parse_statuspage_indicator(payload)
            except Exception:
                parsed = None
            if parsed is None:
                observation = _FeedObservation(
                    FeedState.UNAVAILABLE, observed_at, None
                )
            else:
                indicator, description = parsed
                incident = None
                state = FeedState.NO_INCIDENT
                if indicator != "none":
                    state = FeedState.CONFIRMED_INCIDENT
                    incident = ProviderIncident(
                        provider_id=provider_id,
                        vendor=vendor,
                        indicator=indicator,
                        description=description or indicator.replace("_", " "),
                        page_url=page_url,
                        source_url=endpoint,
                        observed_at=observed_at,
                    )
                observation = _FeedObservation(state, observed_at, incident)
            with self._lock:
                # A feed stopped while its request was out keeps nothing.
                if cancelled is None or not cancelled.is_set():
                    self._observations[provider_id] = observation

    def _loop(
        self,
        provider_id: str,
        stop: threading.Event,
        enabled: Callable[[], bool] | None,
    ) -> None:
        while not stop.is_set():
            if enabled is not None and not enabled():
                self._retire(provider_id, stop)
                return
            self.poll_once(provider_ids=(provider_id,), cancelled=stop)
            if stop.wait(self._poll_seconds):
                return

    def _retire(self, provider_id: str, stop: threading.Event) -> None:
        """A feed whose gate closed takes itself off the books."""
        with self._lock:
            worker = self._workers.get(provider_id)
            if worker is not None and worker.stop is stop:
                del self._workers[provider_id]
                self._observations.pop(provider_id, None)


_shared_poller: StatusFeedPoller | None = None
_shared_lock = threading.Lock()


def shared_status_feed_poller() -> StatusFeedPoller:
    global _shared_poller
    with _shared_lock:
        if _shared_poller is None:
            _shared_poller = StatusFeedPoller()
        return _shared_poller


__all__ = [
    "STATUS_FEEDS",
    "STATUS_FEED_THREAD_NAME",
    "STATUS_FEED_USER_AGENT",
    "FeedState",
    "ProviderIncident",
    "StatusFeedPoller",
    "incident_row_title",
    "incidents_from_documents",
    "parse_statuspage_indicator",
    "shared_status_feed_poller",
]
