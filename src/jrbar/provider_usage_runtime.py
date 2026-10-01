"""Latest-wins background runtime for native provider accounting."""

from __future__ import annotations

import math
import queue
import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path

from .adaptive_refresh import (
    AdaptiveRefreshPlan,
    plan_adaptive_refresh_cadence,
)
from .provider_feature_settings import (
    ProviderCollectionFeature,
    ProviderPresentationSettings,
    project_collection_settings,
)
from .provider_instances import ProviderInstanceKey
from .provider_reconnect import (
    FailureGate,
    codex_app_server_probe,
    credential_fingerprint,
    note_failure,
    repair_grok_credential,
    should_collect,
)
from .provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    provider_descriptor,
    select_authoritative_snapshot,
)
from .provider_usage_settings import ProviderUsageSettings

ProviderRefreshScope = str | tuple[str, str]

#: States that arm a failure gate. NEEDS_SIGN_IN is terminal (only a
#: fresh credential can fix it); the rest are transient and ride the
#: exponential ladder. RATE_LIMITED matters most in practice: the Claude
#: usage endpoint 429s, and before this gate existed the service kept
#: re-asking every 120 s, which is exactly how one STAYS rate limited.
_TERMINAL_FAILURE_STATES = frozenset({ProviderSourceState.NEEDS_SIGN_IN})
_TRANSIENT_FAILURE_STATES = frozenset(
    {
        ProviderSourceState.RATE_LIMITED,
        ProviderSourceState.UNAVAILABLE,
        ProviderSourceState.ERROR,
    }
)

Collector = Callable[[object, Path, float, object], ProviderUsageSnapshot]
IncidentLookup = Callable[[str, float], str | None]

#: How many providers a refresh asks at the same moment. Nearly all of a
#: collector's time is spent waiting on a server or a child process, so a
#: few at once is enough to keep one slow provider from holding up the rest,
#: without opening a burst of connections together.
DEFAULT_MAX_CONCURRENT_COLLECTORS = 4

#: The longest one provider may take in one refresh. Past it the provider
#: counts as a transient failure for this refresh only: it keeps its last good
#: reading, marked stale, and the others are unaffected. It sits above the
#: slowest source that normally succeeds (a Cursor or Gemini sign-in plus
#: usage request, each bounded at 20 s) and well under the sum of every
#: provider's worst case, which is what a refresh used to cost.
DEFAULT_COLLECTOR_DEADLINE_SECONDS = 45.0

#: How long a refresh waits before it shows the providers that have already
#: answered while others are still being asked. A refresh that finishes
#: sooner publishes once, as it always did; a slower one shows the quick
#: readings after this, and each slower one as it lands.
DEFAULT_PARTIAL_PUBLISH_AFTER_SECONDS = 1.5


def _default_incident_lookup(provider_id: str, observed_at: float) -> str | None:
    """A service with no settings wired asks no status page.

    The provider status pages are a request that leaves the Mac, so they are
    off unless a caller hands the service `status_feed_incident_lookup` over
    the person's settings. The `usage refresh` command, which has no daemon
    behind it, never contacts them.
    """
    del provider_id, observed_at
    return None


def status_feed_incident_lookup(settings_loader: Callable[[], object]) -> IncidentLookup:
    """The incident lookup that reads provider status pages, while the person allows it.

    `settings_loader` returns the live settings on every call. While
    `provider_status_feeds_enabled` is exactly True, the lookup starts a feed
    for the provider it is asked about and answers from what that feed last
    saw. While it is anything else, or the settings cannot be read, it starts
    nothing, stops any feed still running and answers "no incident". A feed
    also checks the setting before each of its own requests.
    """

    def enabled() -> bool:
        try:
            return getattr(settings_loader(), "provider_status_feeds_enabled", False) is True
        except Exception:
            return False

    def lookup(provider_id: str, observed_at: float) -> str | None:
        from .status_feeds import shared_status_feed_poller

        poller = shared_status_feed_poller()
        if not enabled():
            poller.stop()
            return None
        poller.start(provider_ids=(provider_id,), enabled=enabled)
        incident = poller.incident_for(provider_id, now=observed_at)
        if incident is None:
            return None
        return f"{incident.vendor}: {incident.description}"

    return lookup


@dataclass(frozen=True, slots=True)
class _UnavailableCredentialRead:
    available: bool = False
    secret: None = None
    reason: str = "instance_credential_unavailable"


class _InstanceCredentialView:
    """Collector-facing credential lookup fixed to one provider instance."""

    __slots__ = ("_key", "_store")

    def __init__(self, store: object, key: ProviderInstanceKey) -> None:
        self._store = store
        self._key = key

    def get(self, provider_id: str, account: str):
        expected_provider, source_instance_id = self._key.value
        if provider_id != expected_provider:
            return _UnavailableCredentialRead(reason="provider_identity_mismatch")
        exact = getattr(self._store, "get_for_instance", None)
        if callable(exact):
            return exact(self._key, account)
        if source_instance_id == "default":
            legacy = getattr(self._store, "get", None)
            if callable(legacy):
                return legacy(provider_id, account)
        return _UnavailableCredentialRead()

    def set(self, provider_id: str, account: str, secret: str) -> None:
        """Keep repair helpers instance-scoped when they receive this view."""
        expected_provider, source_instance_id = self._key.value
        if provider_id != expected_provider:
            raise ValueError("provider identity mismatch")
        if source_instance_id == "default":
            setter = getattr(self._store, "set", None)
            if callable(setter):
                setter(provider_id, account, secret)
                return
        setter = getattr(self._store, "set_for_instance", None)
        if not callable(setter):
            raise ValueError("instance credential storage unavailable")
        setter(self._key, account, secret)


class RefreshPublicationOutcome(str, Enum):
    ACCEPTED = "accepted"
    SUPERSEDED = "superseded"
    REFUSED = "refused"
    FAILED = "failed"


@dataclass(frozen=True, slots=True)
class RefreshPublicationReceipt:
    sequence: int
    settings_revision: int
    outcome: RefreshPublicationOutcome
    error_code: str | None = None

    def __post_init__(self) -> None:
        if type(self.sequence) is not int or self.sequence <= 0:
            raise ValueError("invalid refresh receipt sequence")
        if type(self.settings_revision) is not int or self.settings_revision < 0:
            raise ValueError("invalid refresh receipt revision")
        if type(self.outcome) is not RefreshPublicationOutcome:
            raise ValueError("invalid refresh receipt outcome")
        if self.outcome is RefreshPublicationOutcome.FAILED:
            if self.error_code != "state_persistence_failed":
                raise ValueError("invalid refresh failure code")
        elif self.error_code is not None:
            raise ValueError("unexpected refresh receipt error code")


@dataclass(frozen=True, slots=True)
class ProviderUsageState:
    snapshots: tuple[ProviderUsageSnapshot, ...]
    refreshed_at: float | None
    next_refresh_at: float | None
    refreshing: bool

    def by_provider(self, provider_id: str) -> ProviderUsageSnapshot:
        matches = tuple(
            snapshot for snapshot in self.snapshots if snapshot.provider_id == provider_id
        )
        if len(matches) > 1:
            raise ValueError("provider usage lookup is ambiguous; choose a source instance")
        if not matches:
            raise KeyError(provider_id)
        return matches[0]

    def by_instance(
        self,
        provider_id: str,
        source_instance_id: str = "default",
    ) -> ProviderUsageSnapshot:
        try:
            return next(
                snapshot
                for snapshot in self.snapshots
                if snapshot.identity == (provider_id, source_instance_id)
            )
        except StopIteration as exc:
            raise KeyError((provider_id, source_instance_id)) from exc


@dataclass(frozen=True, slots=True)
class ProviderUsageApply:
    state: ProviderUsageState
    settings: ProviderPresentationSettings
    #: The durable document used by collection and Settings checkboxes. Keep
    #: this beside, rather than inside, the presentation projection so a
    #: worker apply cannot erase the identity-bearing source of truth.
    usage_settings: ProviderUsageSettings | None = None

    def __post_init__(self) -> None:
        if type(self.state) is not ProviderUsageState:
            raise ValueError("invalid provider usage state")
        if type(self.settings) is not ProviderPresentationSettings:
            raise ValueError("invalid provider usage settings")
        if self.usage_settings is not None and type(self.usage_settings) is not ProviderUsageSettings:
            raise ValueError("invalid durable provider usage settings")


def _empty_snapshot(
    provider_id: str,
    *,
    observed_at: float,
    state: ProviderSourceState,
    reason: str | None = None,
    action: str | None = None,
    source_instance_id: str = "default",
) -> ProviderUsageSnapshot:
    return ProviderUsageSnapshot(
        provider_id=provider_id,
        account_label=None,
        observed_at=observed_at,
        state=state,
        reason_code=reason,
        action_label=action,
        lanes=(),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
        source_instance_id=source_instance_id,
    )


def _default_collectors() -> dict[str, Collector]:
    from .provider_usage_codex_claude import collect_claude, collect_codex
    from .provider_usage_collectors import (
        collect_antigravity,
        collect_cursor,
        collect_devin,
        collect_gemini,
        collect_grok,
        collect_openai_api,
        collect_opencode,
    )

    return {
        "codex": lambda preference, home, observed, credentials: collect_codex(
            preference,
            home=home,
            observed_at=observed,
            live_probe=codex_app_server_probe,
        ),
        "claude": lambda preference, home, observed, credentials: collect_claude(
            preference,
            home=home,
            observed_at=observed,
            credentials=credentials,
        ),
        "cursor": lambda preference, home, observed, credentials: collect_cursor(
            preference,
            home=home,
            observed_at=observed,
            credentials=credentials,
        ),
        "devin": lambda preference, home, observed, credentials: collect_devin(
            preference,
            observed_at=observed,
            credentials=credentials,
        ),
        "grok": lambda preference, home, observed, credentials: collect_grok(
            preference,
            home=home,
            observed_at=observed,
            credentials=credentials,
        ),
        "gemini": lambda preference, home, observed, credentials: collect_gemini(
            preference,
            home=home,
            observed_at=observed,
            credentials=credentials,
        ),
        "antigravity": lambda preference, home, observed, credentials: collect_antigravity(
            preference,
            observed_at=observed,
            home=home,
        ),
        "opencode": lambda preference, home, observed, credentials: collect_opencode(
            preference,
            observed_at=observed,
            home=home,
        ),
        "openai-api": lambda preference, home, observed, credentials: collect_openai_api(
            preference,
            observed_at=observed,
            credentials=credentials,
        ),
    }


def _interval_for(
    snapshots: tuple[ProviderUsageSnapshot, ...],
    observed_at: float,
    *,
    menu_last_opened_at: float | None = None,
    constrained: bool = False,
    ambient_usage_visible: bool = False,
) -> float:
    """Compatibility projection of the observable adaptive cadence plan."""
    return plan_adaptive_refresh_cadence(
        snapshots,
        observed_at=observed_at,
        menu_last_opened_at=menu_last_opened_at,
        constrained=constrained,
        ambient_usage_visible=ambient_usage_visible,
    ).interval_seconds


def _machine_is_constrained() -> bool:
    """Low Power Mode or serious thermal pressure, best effort."""
    try:
        from Foundation import NSProcessInfo

        info = NSProcessInfo.processInfo()
        if bool(info.isLowPowerModeEnabled()):
            return True
        # NSProcessInfoThermalStateSerious == 2
        return int(info.thermalState()) >= 2
    except Exception:
        return False


@dataclass(frozen=True, slots=True)
class _CollectJob:
    """One provider instance a refresh has decided to ask."""

    #: Where the answer goes among the refresh's snapshots (settings order).
    slot: int
    preference: ProviderCollectionFeature
    collector: Collector
    #: Nothing in these two is read once the job runs; they are what the
    #: refresh decided on before it asked, kept for the failure gate.
    gate: FailureGate
    fingerprint: tuple | None
    #: The person just ran `grok login`: clear a wedged stored-token copy
    #: before the collector reads, so the fresh file wins at once.
    #: Background-safe: file reads only, never a prompt.
    repair_grok: bool

    @property
    def identity(self) -> tuple[str, str]:
        return self.preference.identity

    @property
    def provider_id(self) -> str:
        return self.preference.provider_id


class _RefreshBooks:
    """What one refresh carries from provider to provider.

    Every entry is keyed by provider instance, so the answers can be settled
    in whatever order they arrive and the books come out the same. Only the
    refresh's own thread touches them; collectors never do.
    """

    __slots__ = (
        "collector_incidents",
        "failure_gates",
        "found_provider_ids",
        "incident_decisions",
        "last_known_good",
        "refreshed_provider_ids",
    )

    def __init__(
        self,
        failure_gates: dict[tuple[str, str], FailureGate],
        last_known_good: dict[tuple[str, str, str], ProviderUsageSnapshot],
    ) -> None:
        self.failure_gates = failure_gates
        self.last_known_good = last_known_good
        self.refreshed_provider_ids: set[str] = set()
        #: Providers with at least one source found on this Mac. Only these
        #: are asked about an incident: a status page is never contacted for
        #: a provider that is not installed.
        self.found_provider_ids: set[str] = set()
        self.collector_incidents: dict[tuple[str, str], str] = {}
        self.incident_decisions: dict[str, str | None] = {}


class _CollectionRound:
    """Asks a refresh's providers a few at a time, each under a deadline.

    Every collector runs on its own short-lived thread and reports through
    one queue; the thread that drives the round is the only one that reads
    that queue, so the refresh's bookkeeping stays single-threaded. Jobs
    start in the order given (settings order). Two jobs for the same provider
    never run together: several collectors keep small caches of their own,
    and an account's second instance should not race its first.

    A collector that is still running when its deadline passes is given up
    on: the round reports a failure for it and moves on. Python cannot stop
    a thread, so the late answer, if it ever comes, is dropped. A thread
    that never returns is a daemon and costs one idle thread, where before
    it would have held every later refresh behind it for good.
    """

    def __init__(
        self,
        jobs: list[_CollectJob],
        *,
        run: Callable[[_CollectJob], ProviderUsageSnapshot],
        unanswered: Callable[[_CollectJob, str], ProviderUsageSnapshot],
        max_concurrent: int,
        deadline_seconds: float,
        monotonic: Callable[[], float],
    ) -> None:
        self._pending: deque[_CollectJob] = deque(jobs)
        #: slot -> (job, monotonic time its deadline passes)
        self._running: dict[int, tuple[_CollectJob, float]] = {}
        self._results: queue.SimpleQueue[tuple[int, ProviderUsageSnapshot]] = (
            queue.SimpleQueue()
        )
        self._run = run
        self._unanswered = unanswered
        self._max_concurrent = max_concurrent
        self._deadline_seconds = deadline_seconds
        self._monotonic = monotonic

    @property
    def finished(self) -> bool:
        return not self._pending and not self._running

    @property
    def in_flight(self) -> int:
        """How many collectors are running and not yet given up on."""
        return len(self._running)

    def stop_starting(self) -> None:
        """Let what is running finish, but ask no one else."""
        self._pending.clear()

    def settled_all(self, provider_id: str) -> bool:
        """True when no job for ``provider_id`` is waiting or running."""
        return not any(
            job.provider_id == provider_id
            for job in (*self._pending, *(job for job, _ in self._running.values()))
        )

    def advance(
        self,
        *,
        wake_at: float | None = None,
    ) -> list[tuple[_CollectJob, ProviderUsageSnapshot]]:
        """Start what can start, then wait for the next thing to happen.

        Returns the jobs that finished or ran out of time, possibly none when
        ``wake_at`` (a ``monotonic`` time) arrives first. A job that finishes
        in the same moment its deadline passes counts as finished.
        """
        self._start_eligible()
        if not self._running:
            return []
        wake = min(deadline for _job, deadline in self._running.values())
        if wake_at is not None:
            wake = min(wake, wake_at)
        outcomes: list[tuple[int, ProviderUsageSnapshot]] = []
        try:
            outcomes.append(
                self._results.get(timeout=max(0.0, wake - self._monotonic()))
            )
        except queue.Empty:
            pass
        while True:
            try:
                outcomes.append(self._results.get_nowait())
            except queue.Empty:
                break
        finished: list[tuple[_CollectJob, ProviderUsageSnapshot]] = []
        for slot, candidate in outcomes:
            entry = self._running.pop(slot, None)
            if entry is not None:
                finished.append((entry[0], candidate))
        now = self._monotonic()
        for slot, (job, deadline) in tuple(self._running.items()):
            if deadline <= now:
                del self._running[slot]
                finished.append((job, self._unanswered(job, "collector_timeout")))
        self._start_eligible()
        return finished

    def _start_eligible(self) -> None:
        while self._pending and len(self._running) < self._max_concurrent:
            busy = {job.provider_id for job, _deadline in self._running.values()}
            chosen = next(
                (job for job in self._pending if job.provider_id not in busy),
                None,
            )
            if chosen is None:
                return
            self._pending.remove(chosen)
            self._running[chosen.slot] = (
                chosen,
                self._monotonic() + self._deadline_seconds,
            )
            try:
                threading.Thread(
                    target=self._collect,
                    args=(chosen,),
                    name=f"JRBarProviderCollect-{chosen.provider_id}",
                    daemon=True,
                ).start()
            except Exception:
                # No thread to run it on: a failure for this provider now,
                # not a wait for a deadline that nothing is counting down to.
                self._results.put(
                    (chosen.slot, self._unanswered(chosen, "collector_failed"))
                )

    def _collect(self, job: _CollectJob) -> None:
        try:
            candidate = self._run(job)
        except BaseException:
            # `run` answers its own failures; this is the thread's last
            # resort so the round is never left waiting for a deadline.
            candidate = self._unanswered(job, "collector_failed")
        self._results.put((job.slot, candidate))


class ProviderUsageService:
    def __init__(
        self,
        *,
        settings_loader: Callable[[], ProviderUsageSettings | object],
        credentials: object,
        home: Path,
        collectors: dict[str, Collector] | None = None,
        clock: Callable[[], float] = time.time,
        state_loader: Callable[[], ProviderUsageState] | None = None,
        state_saver: Callable[[ProviderUsageState], object] | None = None,
        receipt_handler: Callable[[RefreshPublicationReceipt], object] | None = None,
        incident_lookup: IncidentLookup = _default_incident_lookup,
        extra_source: Callable[..., tuple[ProviderUsageSnapshot, ...]] | None = None,
        max_concurrent_collectors: int = DEFAULT_MAX_CONCURRENT_COLLECTORS,
        collector_deadline_seconds: float = DEFAULT_COLLECTOR_DEADLINE_SECONDS,
        partial_publish_after_seconds: float | None = DEFAULT_PARTIAL_PUBLISH_AFTER_SECONDS,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        if type(max_concurrent_collectors) is not int or max_concurrent_collectors < 1:
            raise ValueError("invalid collector concurrency")
        if (
            isinstance(collector_deadline_seconds, bool)
            or not isinstance(collector_deadline_seconds, (int, float))
            or not math.isfinite(float(collector_deadline_seconds))
            or float(collector_deadline_seconds) <= 0.0
        ):
            raise ValueError("invalid collector deadline")
        if partial_publish_after_seconds is not None and (
            isinstance(partial_publish_after_seconds, bool)
            or not isinstance(partial_publish_after_seconds, (int, float))
            or not math.isfinite(float(partial_publish_after_seconds))
            or float(partial_publish_after_seconds) < 0.0
        ):
            raise ValueError("invalid partial publication delay")
        self._max_concurrent_collectors = max_concurrent_collectors
        self._collector_deadline_seconds = float(collector_deadline_seconds)
        self._partial_publish_after = (
            None
            if partial_publish_after_seconds is None
            else float(partial_publish_after_seconds)
        )
        self._monotonic = monotonic
        self._settings_loader = settings_loader
        self._credentials = credentials
        self._home = Path(home)
        self._collectors = dict(_default_collectors() if collectors is None else collectors)
        self._clock = clock
        self._state_saver = state_saver
        if receipt_handler is not None and not callable(receipt_handler):
            raise ValueError("invalid refresh receipt handler")
        self._receipt_handler = receipt_handler
        self._incident_lookup = incident_lookup
        #: Snapshots from outside the configured providers: the CLIProxyAPI
        #: hub's accounts (cliproxy_hub.HubSource), each its own instance.
        self._extra_source = extra_source
        self._lock = threading.RLock()
        self._closed = False
        self._settings_snapshot: ProviderUsageSettings | None = None
        self._settings_revision = 0
        self._explicit_settings_revision: int | None = None
        loaded_state = (
            state_loader()
            if state_loader is not None
            else ProviderUsageState((), None, None, False)
        )
        if type(loaded_state) is not ProviderUsageState or loaded_state.refreshing:
            loaded_state = ProviderUsageState((), None, None, False)
        loaded_state = self._identity_checked_restored_state(loaded_state)
        self._last_known_good: dict[tuple[str, str, str], ProviderUsageSnapshot] = {
            self._continuity_key(snapshot): snapshot
            for snapshot in loaded_state.snapshots
            if snapshot.state in {ProviderSourceState.READY, ProviderSourceState.STALE}
            and self._can_retain(snapshot)
        }
        self._state = loaded_state
        self._callbacks: list[
            tuple[int, Callable[[ProviderUsageState], None]]
        ] = []
        self._worker: threading.Thread | None = None
        self._workers: set[threading.Thread] = set()
        self._pending_refresh: tuple[
            int, tuple[ProviderRefreshScope, ...] | None, bool
        ] | None = None
        self._refresh_generation = 0
        # Per-provider retry gates (see provider_reconnect): terminal
        # auth failures wait for the credential source to change,
        # transient failures ride an exponential ladder. In-memory only
        # -- a relaunch deliberately retries everything once.
        self._failure_gates: dict[tuple[str, str], FailureGate] = {}
        self._refresh_receipts: deque[RefreshPublicationReceipt] = deque(maxlen=32)
        self._refresh_sequence = 0
        self._last_publication_revision: int | None = None
        #: When the owner last opened the menu -- the cadence ladder's
        #: only attention signal. None means 'not since launch'.
        self._menu_last_opened_at: float | None = None
        #: True while the LED bar renders Quota Runway.
        self._ambient_usage_visible = False
        #: While a jump waits for its confirming read, the last moment it
        #: can still be confirmed (note_reset_candidates); None otherwise.
        self._reset_confirm_until: float | None = None
        self._last_cadence_plan = plan_adaptive_refresh_cadence(
            (),
            observed_at=0.0,
        )

    @staticmethod
    def _can_retain(snapshot: ProviderUsageSnapshot) -> bool:
        return snapshot.provider_id != "claude" or snapshot.account_discriminator is not None

    @staticmethod
    def _is_invented_antigravity_reading(snapshot: ProviderUsageSnapshot) -> bool:
        """The READY "Antigravity CLI 100% left" lane older builds made up.

        One rule shared with the saved-file reader
        (``provider_usage_platform.is_invented_antigravity_reading``), so a
        state that reaches the daemon by any road is purged the same way.
        """
        from .provider_usage_platform import is_invented_antigravity_reading

        return is_invented_antigravity_reading(snapshot)

    def _identity_checked_restored_state(
        self,
        state: ProviderUsageState,
    ) -> ProviderUsageState:
        """Withhold saved Claude quota until its account scope is proved.

        Also drops a saved Antigravity reading no server ever measured, so
        it is not served back as a stale "last known good".
        """
        try:
            from .claude_quota import account_facts_from_claude_config

            _plan, current_claude_account = account_facts_from_claude_config(
                self._home
            )
        except Exception:
            current_claude_account = None
        kept = tuple(
            snapshot
            for snapshot in state.snapshots
            if not self._is_invented_antigravity_reading(snapshot)
            and (
                snapshot.provider_id != "claude"
                or (
                    snapshot.source_instance_id == "default"
                    and current_claude_account is not None
                    and snapshot.account_discriminator == current_claude_account
                )
            )
        )
        if len(kept) == len(state.snapshots):
            return state
        return replace(state, snapshots=kept, next_refresh_at=None)

    @staticmethod
    def _continuity_key(snapshot: ProviderUsageSnapshot) -> tuple[str, str, str]:
        return (
            snapshot.provider_id,
            snapshot.source_instance_id,
            snapshot.account_discriminator or "",
        )

    def note_ambient_usage_visible(self, visible: bool) -> None:
        """Tell the cadence whether a usage number is on screen already."""
        with self._lock:
            self._ambient_usage_visible = bool(visible)
            self._replan_cached_cadence_locked(float(self._clock()))

    def note_reset_candidates(self, confirm_until: float | None) -> None:
        """Tell the cadence a jump in remaining is waiting to be confirmed.

        A jump is announced only after a second read 1 to 30 minutes
        later agrees (provider_usage_qol.confirm_reset_events). The idle
        cadence is 30 minutes, so without this the confirming read would
        usually come too late. Until ``confirm_until`` the next read comes
        within two minutes; None when nothing is waiting.
        """
        with self._lock:
            until = None if confirm_until is None else float(confirm_until)
            if until is not None and not math.isfinite(until):
                until = None
            self._reset_confirm_until = until
            self._replan_cached_cadence_locked(float(self._clock()))

    def note_menu_opened(self, *, now: float | None = None) -> None:
        """Record a visit; the cadence ladder keys off how long ago."""
        with self._lock:
            observed_at = float(self._clock()) if now is None else float(now)
            self._menu_last_opened_at = observed_at
            self._replan_cached_cadence_locked(observed_at)

    def _replan_cached_cadence_locked(self, observed_at: float) -> None:
        """Shorten an accepted schedule when a local attention signal changes."""
        plan = plan_adaptive_refresh_cadence(
            self._state.snapshots,
            observed_at=observed_at,
            menu_last_opened_at=self._menu_last_opened_at,
            constrained=self._last_cadence_plan.constrained,
            ambient_usage_visible=self._ambient_usage_visible,
            reset_confirm_until=self._reset_confirm_until,
        )
        next_refresh_at = self._state.next_refresh_at
        if next_refresh_at is not None:
            next_refresh_at = min(
                next_refresh_at,
                observed_at + plan.interval_seconds,
            )
            self._state = replace(self._state, next_refresh_at=next_refresh_at)
        self._last_cadence_plan = plan

    def snapshot(self) -> ProviderUsageState:
        with self._lock:
            return self._state

    def settings_snapshot(self) -> ProviderUsageSettings | None:
        with self._lock:
            return self._settings_snapshot

    def cadence_plan(self) -> AdaptiveRefreshPlan:
        """Return the current scheduled cadence without reading system state."""
        with self._lock:
            return self._last_cadence_plan

    def refresh_receipts(self) -> tuple[RefreshPublicationReceipt, ...]:
        with self._lock:
            return tuple(self._refresh_receipts)

    def _record_receipt(
        self,
        outcome: RefreshPublicationOutcome,
        settings_revision: int,
        *,
        error_code: str | None = None,
    ) -> RefreshPublicationReceipt:
        with self._lock:
            self._refresh_sequence += 1
            receipt = RefreshPublicationReceipt(
                self._refresh_sequence,
                settings_revision,
                outcome,
                error_code,
            )
            self._refresh_receipts.append(receipt)
            handler = self._receipt_handler
        if handler is not None:
            try:
                handler(receipt)
            except Exception:
                pass
        return receipt

    def note_settings_updated(self, settings: ProviderUsageSettings) -> None:
        if type(settings) is not ProviderUsageSettings:
            raise ValueError("invalid provider usage settings")
        with self._lock:
            self._settings_revision += 1
            self._settings_snapshot = settings
            self._explicit_settings_revision = self._settings_revision

    def _settings(self) -> ProviderUsageSettings:
        settings, _revision = self._settings_with_revision()
        return settings

    def _settings_with_revision(self) -> tuple[ProviderUsageSettings, int]:
        with self._lock:
            starting_revision = self._settings_revision
        loaded = self._settings_loader()
        settings = getattr(loaded, "settings", loaded)
        if type(settings) is not ProviderUsageSettings:
            raise ValueError("invalid provider usage settings")
        with self._lock:
            # A user may save a menu preference while this load is in
            # flight. The worker can finish its already-started collection
            # with the version it read, but it must not overwrite the newer
            # explicit-action snapshot that AppKit should project.
            if self._settings_revision == starting_revision:
                if self._explicit_settings_revision == starting_revision:
                    # A bounded rerun can read a lagging source again. Keep
                    # the explicit edit as the projected snapshot for that
                    # rerun, then allow later ordinary loads to refresh it.
                    self._explicit_settings_revision = None
                else:
                    self._settings_snapshot = settings
        return settings, starting_revision

    def _run_refresh(
        self,
        *,
        providers: tuple[ProviderRefreshScope, ...] | None,
        force: bool = False,
        generation: int | None = None,
        publish_partials: bool = False,
    ) -> tuple[ProviderUsageState, RefreshPublicationOutcome]:
        """Ask the providers, a few at a time, and publish what they said.

        Three steps. First, in settings order and on this thread, decide for
        each configured instance whether it is skipped (out of scope, off,
        no collector, retry gate armed) or asked. Second, ask the instances
        that need asking a few at a time, each under a deadline; the answers
        are settled here, on this thread, as they arrive, so the retry gates,
        last-known-good readings and incident notes are exactly what they were
        when the loop was serial (all of them are keyed per instance, so
        arrival order cannot change them). Third, publish once, in settings
        order whatever order the answers came in.

        With ``publish_partials`` a refresh that is still waiting on slow
        providers first publishes the quick ones: each slow provider keeps the
        snapshot it had, so a partial state never drops a last good reading.
        """
        observed_at = float(self._clock())
        settings, settings_revision = self._settings_with_revision()
        collection_settings = project_collection_settings(settings)
        selected = None if providers is None else frozenset(providers)
        selected_provider_ids = frozenset(
            item for item in selected or () if isinstance(item, str)
        )
        selected_instances = frozenset(
            item for item in selected or ()
            if isinstance(item, tuple) and len(item) == 2
        )
        with self._lock:
            previous_state = self._state
            books = _RefreshBooks(
                dict(self._failure_gates),
                dict(self._last_known_good),
            )
        previous_by_provider = {
            snapshot.identity: snapshot for snapshot in previous_state.snapshots
        }
        #: One entry per configured instance, in settings order. None is an
        #: instance with nothing to show yet: out of scope with no earlier
        #: snapshot, or still being asked.
        slots: list[ProviderUsageSnapshot | None] = []
        jobs: list[_CollectJob] = []
        superseded = False
        for preference in collection_settings.providers:
            if generation is not None:
                with self._lock:
                    if self._closed or generation != self._refresh_generation:
                        superseded = True
                        break
            provider_id = preference.provider_id
            identity = preference.identity
            slot = len(slots)
            slots.append(None)
            if selected is not None and (
                provider_id not in selected_provider_ids
                and identity not in selected_instances
            ):
                slots[slot] = previous_by_provider.get(identity)
                continue
            if not preference.enabled:
                # A disabled provider's old failure gate must not
                # outlive the disable: re-enabling should probe fresh,
                # not serve the pre-disable failure for up to an hour.
                books.failure_gates.pop(identity, None)
                slots[slot] = _empty_snapshot(
                    provider_id,
                    observed_at=observed_at,
                    state=ProviderSourceState.DISABLED,
                    source_instance_id=preference.source_instance_id,
                )
                continue
            collector = self._collectors.get(provider_id)
            if collector is None:
                slots[slot] = _empty_snapshot(
                    provider_id,
                    observed_at=observed_at,
                    state=ProviderSourceState.SOURCE_NOT_FOUND,
                    reason="collector_not_configured",
                    action=f"Configure {provider_descriptor(provider_id).label}",
                    source_instance_id=preference.source_instance_id,
                )
                continue
            gate = books.failure_gates.get(identity, FailureGate())
            fingerprint = credential_fingerprint(self._home, provider_id)
            previous = previous_by_provider.get(identity)
            if previous is not None and not should_collect(
                gate,
                now=observed_at,
                fingerprint=fingerprint,
                forced=force,
            ):
                # The gate is armed and nothing changed: serve the last
                # snapshot instead of re-asking a server that already
                # said no. This is what stops a 429 from becoming a
                # permanent 429.
                slots[slot] = previous
                continue
            books.refreshed_provider_ids.add(provider_id)
            jobs.append(
                _CollectJob(
                    slot=slot,
                    preference=preference,
                    collector=collector,
                    gate=gate,
                    fingerprint=fingerprint,
                    repair_grok=(
                        provider_id == "grok"
                        and preference.source_instance_id == "default"
                        and gate.terminal
                        and fingerprint != gate.terminal_fingerprint
                    ),
                )
            )
        #: What an instance shows while it is still being asked.
        carried = {job.slot: previous_by_provider.get(job.identity) for job in jobs}

        def current_snapshots() -> list[ProviderUsageSnapshot]:
            shown = (
                slot if slot is not None else carried.get(index)
                for index, slot in enumerate(slots)
            )
            return [snapshot for snapshot in shown if snapshot is not None]

        collection = _CollectionRound(
            jobs,
            run=lambda job: self._collect_job(job, observed_at),
            unanswered=lambda job, reason: self._unanswered_snapshot(
                job, observed_at, reason
            ),
            max_concurrent=self._max_concurrent_collectors,
            deadline_seconds=self._collector_deadline_seconds,
            monotonic=self._monotonic,
        )
        partial_due = (
            self._monotonic() + self._partial_publish_after
            if publish_partials and self._partial_publish_after is not None
            else None
        )
        unpublished = False
        if superseded:
            collection.stop_starting()
        while not collection.finished:
            if not superseded and generation is not None:
                with self._lock:
                    superseded = self._closed or generation != self._refresh_generation
                if superseded:
                    # What is already running cannot be interrupted; it is
                    # awaited, as it always was, but nothing new is asked.
                    collection.stop_starting()
            showing_partials = partial_due is not None and not superseded
            answered = collection.advance(
                wake_at=partial_due if showing_partials and unpublished else None
            )
            for job, candidate in answered:
                slots[job.slot] = self._settle_candidate(
                    job,
                    candidate,
                    books,
                    observed_at=observed_at,
                )
            unpublished = unpublished or bool(answered)
            if (
                partial_due is not None
                and showing_partials
                and unpublished
                and not collection.finished
                and self._monotonic() >= partial_due
            ):
                self._decide_incidents(books, observed_at, collection=collection)
                shown = tuple(
                    self._with_incident_decisions(current_snapshots(), books)
                )
                if self._extra_source is not None:
                    # The hub's accounts keep what they showed until the
                    # final state asks the hub again.
                    shown = self._with_extra_snapshots(
                        shown,
                        previous_state,
                        observed_at=observed_at,
                        force=force,
                        wanted=False,
                    )
                self._publish_partial(
                    shown,
                    books,
                    generation=generation,
                    settings_revision=settings_revision,
                )
                unpublished = False
        self._decide_incidents(books, observed_at)
        ordered = tuple(self._with_incident_decisions(current_snapshots(), books))
        if self._extra_source is not None:
            ordered = self._with_extra_snapshots(
                ordered,
                previous_state,
                observed_at=observed_at,
                force=force,
                wanted=selected is None or bool({"claude", "codex"} & selected_provider_ids),
            )
        cadence_plan = plan_adaptive_refresh_cadence(
            ordered,
            observed_at=observed_at,
            menu_last_opened_at=getattr(self, "_menu_last_opened_at", None),
            constrained=_machine_is_constrained(),
            ambient_usage_visible=bool(
                getattr(self, "_ambient_usage_visible", False)
            ),
            reset_confirm_until=getattr(self, "_reset_confirm_until", None),
        )
        state = ProviderUsageState(
            snapshots=ordered,
            refreshed_at=observed_at,
            next_refresh_at=observed_at + cadence_plan.interval_seconds,
            refreshing=False,
        )
        # State publication and its durable save are one revision-fenced
        # critical section. An explicit settings edit cannot land between
        # the check and the save, and an older worker therefore cannot leak
        # either state or persistence past the edit.
        publication_outcome: RefreshPublicationOutcome
        publication_error: str | None = None
        with self._lock:
            if self._closed:
                publication_outcome = RefreshPublicationOutcome.REFUSED
                result = self._state
            elif (
                generation is not None
                and generation != self._refresh_generation
            ):
                publication_outcome = RefreshPublicationOutcome.SUPERSEDED
                result = self._state
            elif settings_revision != self._settings_revision:
                publication_outcome = RefreshPublicationOutcome.SUPERSEDED
                result = self._state
            else:
                self._state = state
                self._last_known_good = books.last_known_good
                self._failure_gates = books.failure_gates
                self._last_cadence_plan = cadence_plan
                self._last_publication_revision = settings_revision
                result = state
                publication_outcome = RefreshPublicationOutcome.ACCEPTED
                if self._state_saver is not None:
                    try:
                        self._state_saver(state)
                    except Exception:
                        publication_outcome = RefreshPublicationOutcome.FAILED
                        publication_error = "state_persistence_failed"
        self._record_receipt(
            publication_outcome,
            settings_revision,
            error_code=publication_error,
        )
        return result, publication_outcome

    def _collect_job(
        self,
        job: _CollectJob,
        observed_at: float,
    ) -> ProviderUsageSnapshot:
        """Run one instance's collector. Runs on a collection thread.

        Touches nothing but what it is handed and the service's read-only
        fields; the refresh's books are settled by the thread that started
        the round.
        """
        preference = job.preference
        try:
            if job.repair_grok:
                # The user just ran `grok login`: clear any wedged
                # stored-token copy so the fresh file wins immediately.
                # Background-safe -- file reads only, never a prompt.
                try:
                    repair_grok_credential(
                        self._credentials,
                        home=self._home,
                        now=observed_at,
                    )
                except Exception:
                    pass
            candidate = job.collector(
                preference,
                self._home,
                observed_at,
                _InstanceCredentialView(
                    self._credentials,
                    ProviderInstanceKey(
                        job.provider_id,
                        preference.source_instance_id,
                    ),
                ),
            )
            if type(candidate) is not ProviderUsageSnapshot:
                raise ValueError("collector returned invalid snapshot")
            if candidate.identity != job.identity:
                candidate = replace(
                    candidate,
                    source_instance_id=preference.source_instance_id,
                )
            return candidate
        except Exception:
            return self._unanswered_snapshot(job, observed_at, "collector_failed")

    @staticmethod
    def _unanswered_snapshot(
        job: _CollectJob,
        observed_at: float,
        reason: str,
    ) -> ProviderUsageSnapshot:
        """A transient failure for an instance that gave no usable answer.

        A collector that raised is an error; one that ran past its deadline
        is unavailable. Both ride the transient retry ladder, and a provider
        with a last good reading keeps it, marked stale.
        """
        return _empty_snapshot(
            job.provider_id,
            observed_at=observed_at,
            state=(
                ProviderSourceState.UNAVAILABLE
                if reason == "collector_timeout"
                else ProviderSourceState.ERROR
            ),
            reason=reason,
            action="Retry",
            source_instance_id=job.preference.source_instance_id,
        )

    def _settle_candidate(
        self,
        job: _CollectJob,
        candidate: ProviderUsageSnapshot,
        books: _RefreshBooks,
        *,
        observed_at: float,
    ) -> ProviderUsageSnapshot:
        """Fold one instance's answer into the books; return what it shows."""
        identity = job.identity
        if candidate.state is not ProviderSourceState.SOURCE_NOT_FOUND:
            # A source that is there but failing (signed out, rate
            # limited, erroring) is exactly when "the provider is down"
            # is worth saying, so only a missing source is skipped.
            books.found_provider_ids.add(job.provider_id)
        if candidate.incident:
            books.collector_incidents[identity] = candidate.incident
        if candidate.state in _TERMINAL_FAILURE_STATES:
            books.failure_gates[identity] = note_failure(
                job.gate,
                now=observed_at,
                terminal=True,
                fingerprint=job.fingerprint,
            )
        elif candidate.state in _TRANSIENT_FAILURE_STATES:
            books.failure_gates[identity] = note_failure(
                job.gate,
                now=observed_at,
                terminal=False,
                fingerprint=None,
            )
        else:
            books.failure_gates.pop(identity, None)
        continuity_key = self._continuity_key(candidate)
        previous_good = (
            books.last_known_good.get(continuity_key)
            if self._can_retain(candidate)
            else None
        )
        if candidate.provider_id == "claude" and candidate.account_discriminator is not None:
            books.last_known_good = {
                key: value
                for key, value in books.last_known_good.items()
                if key[:2] != identity or key == continuity_key
            }
        if (
            candidate.state is ProviderSourceState.READY
            and not candidate.lanes
            and previous_good is not None
            and previous_good.lanes
        ):
            # A lane-less READY means "the scan worked and found no
            # quota evidence" -- e.g. Codex transcripts rotated away.
            # That is the ABSENCE of a reading, not a newer reading;
            # letting it overwrite last-known-good silently degraded
            # "48% left" to a bare "ready" card with no number.
            return replace(
                previous_good,
                observed_at=candidate.observed_at,
                # The scan ran now; the numbers were read earlier.
                read_at=previous_good.effective_read_at,
                state=ProviderSourceState.STALE,
                reason_code="reading_evidence_missing",
                action_label=previous_good.action_label or "Retry",
            )
        if candidate.state is ProviderSourceState.READY:
            if self._can_retain(candidate):
                books.last_known_good[continuity_key] = candidate
            return candidate
        if candidate.state is ProviderSourceState.UNSUPPORTED:
            # The source says this account HAS no quota (OpenCode
            # without a Go subscription). Old lanes are not a stale
            # reading of something that exists; they must go.
            books.last_known_good = {
                key: value
                for key, value in books.last_known_good.items()
                if key[:2] != identity
            }
            return candidate
        if candidate.state is ProviderSourceState.STALE and candidate.lanes:
            # A stale-but-real reading is NEWER information than the
            # last known good one, and it is the same numbers wearing
            # an honest label. Substituting last_known_good here is
            # what let a Codex quota frozen three days ago keep
            # rendering as a live "ready" reading.
            return candidate
        if previous_good is not None:
            return select_authoritative_snapshot(
                (candidate,),
                last_known_good=previous_good,
            )
        return candidate

    def _decide_incidents(
        self,
        books: _RefreshBooks,
        observed_at: float,
        *,
        collection: _CollectionRound | None = None,
    ) -> None:
        """Look up each refreshed provider's status-page incident once.

        With a ``collection`` still running, only providers whose every
        instance has answered are looked up (an incident is a fact about a
        provider, and "found" depends on all of its instances); without one,
        every provider not decided yet is, in name order.
        """
        for provider_id in sorted(books.refreshed_provider_ids):
            if provider_id in books.incident_decisions:
                continue
            if collection is not None and not collection.settled_all(provider_id):
                continue
            if provider_id not in books.found_provider_ids:
                # No lookup, but the provider still takes part below so its
                # collector's own note stands as it always did.
                books.incident_decisions[provider_id] = None
                continue
            try:
                books.incident_decisions[provider_id] = self._incident_lookup(
                    provider_id, observed_at
                )
            except Exception:
                books.incident_decisions[provider_id] = None

    @staticmethod
    def _with_incident_decisions(
        snapshots: list[ProviderUsageSnapshot],
        books: _RefreshBooks,
    ) -> list[ProviderUsageSnapshot]:
        return [
            replace(
                snapshot,
                # The status feed's outage wins; a collector's own note
                # (OpenCode logging a limit error) stands when it is quiet.
                incident=(
                    books.incident_decisions[snapshot.provider_id]
                    or books.collector_incidents.get(snapshot.identity)
                ),
            )
            if snapshot.provider_id in books.incident_decisions
            else snapshot
            for snapshot in snapshots
        ]

    def _publish_partial(
        self,
        snapshots: tuple[ProviderUsageSnapshot, ...],
        books: _RefreshBooks,
        *,
        generation: int | None,
        settings_revision: int,
    ) -> None:
        """Show the providers that have answered while others are still asked.

        Revision-fenced like the final publication, so an older worker or an
        edited setting publishes nothing. It stays `refreshing`, keeps the
        schedule it had, is never written to disk (the file only ever holds a
        finished refresh), records no receipt, and hands the same pending
        callbacks the state without retiring them: they are retired by the
        final publication. The books go with it so the gates and last good
        readings always match the state on show.
        """
        with self._lock:
            if (
                self._closed
                or (generation is not None and generation != self._refresh_generation)
                or settings_revision != self._settings_revision
            ):
                return
            state = ProviderUsageState(
                snapshots=snapshots,
                refreshed_at=self._state.refreshed_at,
                next_refresh_at=self._state.next_refresh_at,
                refreshing=True,
            )
            if state == self._state:
                return
            self._state = state
            self._last_known_good = dict(books.last_known_good)
            self._failure_gates = dict(books.failure_gates)
            if generation is None:
                return
            callbacks = tuple(
                callback
                for callback_generation, callback in self._callbacks
                if callback_generation == generation
            )
            for callback in callbacks:
                try:
                    callback(state)
                except Exception:
                    continue

    def _with_extra_snapshots(
        self,
        ordered: tuple[ProviderUsageSnapshot, ...],
        previous_state: ProviderUsageState,
        *,
        observed_at: float,
        force: bool,
        wanted: bool,
    ) -> tuple[ProviderUsageSnapshot, ...]:
        """The extra source's snapshots after the configured ones; a refresh
        scoped elsewhere keeps the last ones. A configured identity always
        wins over an extra one."""
        taken = {snapshot.identity for snapshot in ordered}
        if wanted:
            try:
                extra = tuple(self._extra_source(observed_at, force=force))
            except Exception:
                extra = ()
        else:
            extra = tuple(
                snapshot
                for snapshot in previous_state.snapshots
                if snapshot.source_instance_id.startswith("cliproxy")
            )
        kept: list[ProviderUsageSnapshot] = []
        for snapshot in extra:
            if type(snapshot) is not ProviderUsageSnapshot or snapshot.identity in taken:
                continue
            taken.add(snapshot.identity)
            kept.append(snapshot)
        return (*ordered, *kept)

    def refresh_now(
        self,
        *,
        providers: tuple[ProviderRefreshScope, ...] | None = None,
        force: bool = False,
    ) -> ProviderUsageState:
        # `force` used to be deleted here, which meant a user-initiated
        # reconnect could not push through a failure gate. Now it can.
        with self._lock:
            if self._closed:
                self._record_receipt(
                    RefreshPublicationOutcome.REFUSED,
                    self._settings_revision,
                )
                return self._state
            self._refresh_generation += 1
            generation = self._refresh_generation
            self._callbacks = [
                (generation, callback)
                for _old_generation, callback in self._callbacks
            ]
        state, _outcome = self._run_refresh(
            providers=providers,
            force=force,
            generation=generation,
        )
        if _outcome is RefreshPublicationOutcome.ACCEPTED:
            with self._lock:
                self._start_callback_delivery_locked(generation, state)
        return state

    def _start_callback_delivery_locked(
        self,
        generation: int,
        state: ProviderUsageState,
    ) -> None:
        if not any(
            callback_generation == generation
            for callback_generation, _callback in self._callbacks
        ):
            return
        threading.Thread(
            target=self._deliver_callbacks,
            args=(generation, state),
            name=f"JRBarProviderUsageCallback-{generation}",
            daemon=True,
        ).start()

    def _deliver_callbacks(
        self,
        generation: int,
        state: ProviderUsageState,
    ) -> None:
        with self._lock:
            if self._closed or generation != self._refresh_generation:
                return
            callbacks = tuple(
                callback
                for callback_generation, callback in self._callbacks
                if callback_generation == generation
            )
            self._callbacks = [
                item for item in self._callbacks if item[0] != generation
            ]
        for callback in callbacks:
            with self._lock:
                if self._closed or generation != self._refresh_generation:
                    return
                try:
                    callback(state)
                except Exception:
                    continue

    def _start_worker_locked(
        self,
        *,
        generation: int,
        providers: tuple[ProviderRefreshScope, ...] | None,
        force: bool,
    ) -> None:
        worker = threading.Thread(
            target=self._worker_main,
            kwargs={
                "generation": generation,
                "providers": providers,
                "force": force,
            },
            name=f"JRBarProviderUsage-{generation}",
            daemon=True,
        )
        self._worker = worker
        self._workers.add(worker)
        try:
            worker.start()
        except Exception:
            self._workers.discard(worker)
            if self._worker is worker:
                self._worker = None
            raise

    def _retire_worker_locked(self, worker: threading.Thread) -> None:
        """Retire ``worker`` and start only the newest queued replacement."""
        self._workers.discard(worker)
        if self._worker is worker:
            self._worker = None
        pending = self._pending_refresh
        self._pending_refresh = None
        if self._closed or pending is None:
            return
        generation, providers, force = pending
        if generation != self._refresh_generation:
            return
        self._start_worker_locked(
            generation=generation,
            providers=providers,
            force=force,
        )

    def request(
        self,
        *,
        callback: Callable[[ProviderUsageState], None],
        providers: tuple[ProviderRefreshScope, ...] | None = None,
        force: bool = False,
    ) -> ProviderUsageState:
        if not callable(callback):
            raise TypeError("callback must be callable")
        with self._lock:
            if self._closed:
                self._record_receipt(
                    RefreshPublicationOutcome.REFUSED,
                    self._settings_revision,
                )
                return self._state
            now = float(self._clock())
            if (
                not force
                and self._state.next_refresh_at is not None
                and now < self._state.next_refresh_at
            ):
                return self._state
            active = any(worker.is_alive() for worker in self._workers)
            if active and not force:
                self._callbacks.append((self._refresh_generation, callback))
                return self._state
            self._refresh_generation += 1
            generation = self._refresh_generation
            # A forced request replaces every undelivered request. Move
            # their callbacks to the new generation so nobody observes the
            # obsolete result that happened to start first.
            self._callbacks = [
                (generation, pending_callback)
                for _old_generation, pending_callback in self._callbacks
            ]
            self._callbacks.append((generation, callback))
            self._state = replace(self._state, refreshing=True)
            if active:
                # The in-flight collector cannot be interrupted safely. Keep
                # exactly one replace-latest request for when it retires.
                self._pending_refresh = (generation, providers, True)
                return self._state
            self._start_worker_locked(
                generation=generation,
                providers=providers,
                force=force,
            )
            return self._state

    def _worker_main(
        self,
        *,
        generation: int,
        providers: tuple[ProviderRefreshScope, ...] | None,
        force: bool = False,
    ) -> None:
        while True:
            state, outcome = self._run_refresh(
                providers=providers,
                force=force,
                generation=generation,
                publish_partials=True,
            )
            with self._lock:
                if self._closed or generation != self._refresh_generation:
                    self._retire_worker_locked(threading.current_thread())
                    return
                if outcome is RefreshPublicationOutcome.SUPERSEDED:
                    # The settings revision changed during collection. This
                    # generation remains current, so repeat it with the new
                    # settings. A newer refresh generation takes the branch
                    # above and retires this worker instead.
                    force = True
                    continue
                callbacks = tuple(
                    callback
                    for callback_generation, callback in self._callbacks
                    if callback_generation == generation
                )
                self._callbacks = [
                    item for item in self._callbacks if item[0] != generation
                ]
                publication_revision = self._last_publication_revision
                # Retire the worker UNDER THE LOCK, in the same critical
                # section as the final rerun check. The exit used to
                # happen while `is_alive()` was still true, so a forced
                # request landing during callback delivery piggybacked
                # on a thread that would never look at its flags again:
                # the click was swallowed and the leaked flags fired a
                # spurious forced run up to five minutes later.
                self._workers.discard(threading.current_thread())
                if self._worker is threading.current_thread():
                    self._worker = None
            superseded_callbacks = False
            for index, callback in enumerate(callbacks):
                # Keep the revision check and callback invocation in one
                # critical section. A settings update from another thread
                # therefore either precedes this callback and suppresses it,
                # or waits until the callback has begun and is ordered after
                # the publication it observes.
                with self._lock:
                    if (
                        self._closed
                        or generation != self._refresh_generation
                    ):
                        return
                    if publication_revision != self._settings_revision:
                        self._callbacks = [
                            (generation, pending_callback)
                            for pending_callback in callbacks[index:]
                        ] + self._callbacks
                        self._worker = threading.current_thread()
                        self._workers.add(threading.current_thread())
                        superseded_callbacks = True
                        break
                    try:
                        callback(state)
                    except Exception:
                        continue
            if superseded_callbacks:
                force = True
                continue
            break

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._refresh_generation += 1
            self._callbacks.clear()
            self._pending_refresh = None
            workers = tuple(self._workers)
        deadline = time.monotonic() + 1.0
        for worker in workers:
            if worker is threading.current_thread():
                continue
            worker.join(timeout=max(0.0, deadline - time.monotonic()))


__all__ = [
    "ProviderRefreshScope",
    "ProviderUsageApply",
    "ProviderUsageService",
    "ProviderUsageState",
    "RefreshPublicationOutcome",
    "RefreshPublicationReceipt",
    "status_feed_incident_lookup",
]
