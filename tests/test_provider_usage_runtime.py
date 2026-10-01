from __future__ import annotations

import threading
import time
from dataclasses import replace as dataclass_replace

import pytest

from jrbar.provider_feature_settings import (
    ProviderCollectionFeature,
    project_presentation_settings,
)
from jrbar.provider_reconnect import FailureGate
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
)
from jrbar.provider_usage_runtime import (
    ProviderUsageApply,
    ProviderUsageService,
    ProviderUsageState,
    RefreshPublicationOutcome,
    _CollectionRound,
    _CollectJob,
    _RefreshBooks,
)
from jrbar.provider_usage_settings import default_provider_usage_settings


def snapshot(
    provider,
    *,
    state=ProviderSourceState.READY,
    remaining=50,
    observed=1000,
    account_discriminator="default",
):
    lanes = ()
    reason = None
    action = None
    if state in {ProviderSourceState.READY, ProviderSourceState.STALE}:
        lanes = (
            UsageLane(
                provider_id=provider,
                lane_id="weekly",
                label="Weekly",
                remaining_percent=remaining,
                reset_at=3000,
                scope="all",
                model=None,
                feature=None,
                bindable=True,
                source_id="fixture",
            ),
        )
        if state is ProviderSourceState.STALE:
            reason = "network_unavailable"
            action = "Retry"
    elif state is not ProviderSourceState.DISABLED:
        reason = "network_unavailable"
        action = "Retry"
    discriminator = (
        "claude-account-fixture"
        if provider == "claude" and account_discriminator == "default"
        else account_discriminator
    )
    if discriminator == "default":
        discriminator = None
    return ProviderUsageSnapshot(
        provider_id=provider,
        account_label=None,
        observed_at=observed,
        state=state,
        reason_code=reason,
        action_label=action,
        lanes=lanes,
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
        account_discriminator=discriminator,
    )


def test_refresh_attaches_only_a_confirmed_provider_incident(tmp_path):
    settings = default_provider_usage_settings()
    lookups: list[tuple[str, float]] = []

    def incident_lookup(provider_id: str, observed_at: float) -> str | None:
        lookups.append((provider_id, observed_at))
        return "OpenAI: Elevated API errors" if provider_id == "codex" else None

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "codex": lambda _pref, _home, observed, _credentials: snapshot(
                "codex", observed=observed
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        incident_lookup=incident_lookup,
    )

    result = service.refresh_now(providers=("codex",)).by_provider("codex")

    assert result.incident == "OpenAI: Elevated API errors"
    assert lookups == [("codex", 1000.0)]


def test_default_incident_lookup_starts_nothing_and_asks_no_status_page(monkeypatch):
    from jrbar.provider_usage_runtime import _default_incident_lookup

    class Poller:
        def start(self, **_kwargs):
            raise AssertionError("the default lookup started a status feed")

        def incident_for(self, *_args, **_kwargs):
            raise AssertionError("the default lookup read a status feed")

    monkeypatch.setattr(
        "jrbar.status_feeds.shared_status_feed_poller", lambda: Poller()
    )

    assert _default_incident_lookup("codex", 1000.0) is None


def test_status_feed_incident_lookup_starts_only_the_requested_provider(monkeypatch):
    from types import SimpleNamespace

    from jrbar.provider_usage_runtime import status_feed_incident_lookup

    starts: list[tuple[str, ...]] = []

    class Poller:
        def start(self, *, provider_ids, enabled):
            assert enabled() is True
            starts.append(provider_ids)

        def stop(self):
            raise AssertionError("a lookup that is allowed stopped the feeds")

        def incident_for(self, provider_id, *, now):
            assert provider_id == "codex"
            assert now == 1000.0
            return None

    monkeypatch.setattr(
        "jrbar.status_feeds.shared_status_feed_poller", lambda: Poller()
    )
    lookup = status_feed_incident_lookup(
        lambda: SimpleNamespace(provider_status_feeds_enabled=True)
    )

    assert lookup("codex", 1000.0) is None
    assert starts == [("codex",)]


def test_incident_lookup_is_deduplicated_across_provider_instances__and_2_more(tmp_path) -> None:
    # --- scenario: incident_lookup_is_deduplicated_across_provider_instances
    settings = default_provider_usage_settings()
    settings = settings.with_instance(
        dataclass_replace(settings.preference("claude"), source_instance_id="work")
    )
    lookups: list[tuple[str, float]] = []

    def incident_lookup(provider_id: str, observed_at: float) -> str | None:
        lookups.append((provider_id, observed_at))
        return "Anthropic: API errors"

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "claude": lambda preference, _home, observed, _credentials: dataclass_replace(
                snapshot("claude", observed=observed),
                source_instance_id=preference.source_instance_id,
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        incident_lookup=incident_lookup,
    )

    result = service.refresh_now(providers=("claude",), force=True)

    assert lookups == [("claude", 1000.0)]
    assert {item.incident for item in result.snapshots} == {"Anthropic: API errors"}

    # --- scenario: disabled_provider_performs_no_incident_lookup
    settings = default_provider_usage_settings().with_enabled("grok", False)

    def forbidden(*_args):
        raise AssertionError("disabled provider performed incident lookup")

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"grok": forbidden},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        incident_lookup=forbidden,
    )

    result = service.refresh_now(providers=("grok",), force=True)

    assert result.by_provider("grok").state is ProviderSourceState.DISABLED

    # --- scenario: attempted_collector_failure_still_gets_incident_context
    settings = default_provider_usage_settings()

    def broken(*_args):
        raise RuntimeError("usage endpoint failed")

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": broken},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        incident_lookup=lambda _provider, _observed: "OpenAI: API errors",
    )

    result = service.refresh_now(providers=("codex",), force=True)

    assert result.by_provider("codex").state is ProviderSourceState.ERROR
    assert result.by_provider("codex").incident == "OpenAI: API errors"



def test_partial_refresh_preserves_untouched_provider_incident__and_2_more(tmp_path) -> None:
    # --- scenario: partial_refresh_preserves_untouched_provider_incident
    settings = default_provider_usage_settings()
    decisions = {
        "codex": "OpenAI: first incident",
        "claude": "Anthropic: preserved incident",
    }
    lookups: list[str] = []

    def incident_lookup(provider_id: str, _observed_at: float) -> str | None:
        lookups.append(provider_id)
        return decisions.get(provider_id)

    collectors = {
        provider_id: (
            lambda selected: lambda _pref, _home, observed, _credentials: snapshot(
                selected, observed=observed
            )
        )(provider_id)
        for provider_id in ("codex", "claude")
    }
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors=collectors,
        credentials=object(),
        home=tmp_path,
        clock=iter((1000.0, 1100.0)).__next__,
        incident_lookup=incident_lookup,
    )
    service.refresh_now(providers=("codex", "claude"), force=True)
    lookups.clear()
    decisions["codex"] = None

    result = service.refresh_now(providers=("codex",), force=True)

    assert lookups == ["codex"]
    assert result.by_provider("codex").incident is None
    assert result.by_provider("claude").incident == "Anthropic: preserved incident"

    # --- scenario: superseded_incident_lookup_cannot_publish
    settings = default_provider_usage_settings()
    first_lookup_started = threading.Event()
    release_first_lookup = threading.Event()
    lookup_calls = 0
    lookup_lock = threading.Lock()
    superseded = threading.Event()

    def incident_lookup(_provider_id: str, _observed_at: float) -> str | None:
        nonlocal lookup_calls
        with lookup_lock:
            lookup_calls += 1
            call = lookup_calls
        if call == 1:
            first_lookup_started.set()
            assert release_first_lookup.wait(3.0)
            return "OpenAI: stale incident"
        return "OpenAI: current incident"

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "codex": lambda _pref, _home, observed, _credentials: snapshot(
                "codex", observed=observed
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=time.time,
        incident_lookup=incident_lookup,
        receipt_handler=lambda receipt: (
            superseded.set()
            if receipt.outcome is RefreshPublicationOutcome.SUPERSEDED
            else None
        ),
    )
    service.request(callback=lambda _state: None, providers=("codex",), force=True)
    assert first_lookup_started.wait(1.0)

    current = service.refresh_now(providers=("codex",), force=True)
    release_first_lookup.set()
    assert superseded.wait(2.0)

    assert current.by_provider("codex").incident == "OpenAI: current incident"
    assert service.snapshot().by_provider("codex").incident == "OpenAI: current incident"
    service.close()

    # --- scenario: refresh_preserves_registry_order_and_disabled_state
    settings = default_provider_usage_settings().with_enabled("grok", False)
    collectors = {
        preference.provider_id: (
            lambda provider: lambda _pref, _home, observed, _credentials: snapshot(
                provider, observed=observed
            )
        )(preference.provider_id)
        for preference in settings.providers
    }
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors=collectors,
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
    )

    state = service.refresh_now()

    assert tuple(item.provider_id for item in state.snapshots) == tuple(
        preference.provider_id for preference in settings.providers
    )
    assert state.by_provider("grok").state is ProviderSourceState.DISABLED
    assert state.refreshing is False



def test_disabled_provider_skips_collector_and_credential_filesystem_probe(
    tmp_path,
    monkeypatch,
):
    settings = default_provider_usage_settings().with_enabled("grok", False)

    def forbidden(*_args, **_kwargs):
        raise AssertionError("disabled provider performed I/O")

    monkeypatch.setattr(
        "jrbar.provider_usage_runtime.credential_fingerprint",
        forbidden,
    )
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"grok": forbidden},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
    )

    result = service.refresh_now(providers=("grok",), force=True)

    assert result.by_provider("grok").state is ProviderSourceState.DISABLED


def test_last_known_good_is_retained_when_refresh_fails__and_2_more(tmp_path) -> None:
    # --- scenario: last_known_good_is_retained_when_refresh_fails
    settings = default_provider_usage_settings()
    calls = {"codex": 0}

    def codex(_pref, _home, observed, _credentials):
        calls["codex"] += 1
        if calls["codex"] == 1:
            return snapshot("codex", remaining=20, observed=observed)
        return snapshot(
            "codex",
            state=ProviderSourceState.UNAVAILABLE,
            observed=observed,
        )

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": codex},
        credentials=object(),
        home=tmp_path,
        clock=iter((1000, 1100)).__next__,
    )
    first = service.refresh_now(providers=("codex",))
    second = service.refresh_now(providers=("codex",), force=True)

    assert first.by_provider("codex").state is ProviderSourceState.READY
    stale = second.by_provider("codex")
    assert stale.state is ProviderSourceState.STALE
    assert stale.lanes[0].remaining_percent == 20

    # --- scenario: collector_exception_becomes_actionable_error
    settings = default_provider_usage_settings()

    def broken(*_args):
        raise RuntimeError("private body must not surface")

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"claude": broken},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
    )
    result = service.refresh_now(providers=("claude",)).by_provider("claude")
    assert result.state is ProviderSourceState.ERROR
    assert result.reason_code == "collector_failed"
    assert result.action_label == "Retry"

    # --- scenario: a_low_meter_is_not_a_reason_to_poll_harder
    """Quota level must not drive cadence. A nearly-empty meter is not a
    reason to poll every 30s -- it is a reason the number matters. The
    ladder keys off ATTENTION instead (2026-08-27, mined from CodexBar,
    whose cadence deliberately excludes quota)."""
    settings = default_provider_usage_settings()
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "codex": lambda _pref, _home, observed, _credentials: snapshot(
                "codex", remaining=8, observed=observed
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
    )
    state = service.refresh_now(providers=("codex",))
    assert state.next_refresh_at == 1000 + 1800.0, "unattended: the idle rung"

    service.note_menu_opened(now=1000)
    state = service.refresh_now(providers=("codex",))
    assert state.next_refresh_at == 1000 + 120.0, "just looked: the fast rung"



def _read_time_service(tmp_path, *, script, clock, state_loader=None, state_saver=None):
    """One Codex collector driven by ``script["mode"]``: a real reading, a
    failed poll, or a scan that found no quota evidence."""
    settings = default_provider_usage_settings().with_enabled("grok", False)

    def collector(_pref, _home, observed, _credentials):
        if script["mode"] == "read":
            return snapshot("codex", remaining=48, observed=observed)
        if script["mode"] == "no_evidence":
            return dataclass_replace(snapshot("codex", observed=observed), lanes=())
        return snapshot(
            "codex", state=ProviderSourceState.UNAVAILABLE, observed=observed
        )

    return ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": collector},
        credentials=object(),
        home=tmp_path,
        clock=lambda: clock["now"],
        state_loader=state_loader,
        state_saver=state_saver,
        incident_lookup=lambda *_args: None,
    )


def test_failed_polls_keep_the_time_the_retained_reading_was_read(tmp_path) -> None:
    clock = {"now": 1000.0}
    script = {"mode": "read"}
    service = _read_time_service(tmp_path, script=script, clock=clock)

    first = service.refresh_now(providers=("codex",), force=True).by_provider("codex")
    assert first.state is ProviderSourceState.READY
    assert first.read_at is None
    assert first.effective_read_at == 1000.0

    script["mode"] = "fail"
    for now in (1100.0, 1200.0, 1300.0):
        clock["now"] = now
        stale = service.refresh_now(providers=("codex",), force=True).by_provider("codex")
        # The attempt moves with the clock; the numbers stay as old as they are.
        assert stale.state is ProviderSourceState.STALE
        assert stale.observed_at == now
        assert stale.effective_read_at == 1000.0
        assert stale.lanes[0].remaining_percent == 48
    service.close()


def test_a_scan_with_no_quota_evidence_keeps_the_time_of_the_last_real_reading(
    tmp_path,
) -> None:
    clock = {"now": 1000.0}
    script = {"mode": "read"}
    service = _read_time_service(tmp_path, script=script, clock=clock)
    service.refresh_now(providers=("codex",), force=True)

    script["mode"] = "no_evidence"
    clock["now"] = 1500.0
    codex = service.refresh_now(providers=("codex",), force=True).by_provider("codex")
    assert codex.state is ProviderSourceState.STALE
    assert codex.reason_code == "reading_evidence_missing"
    assert codex.observed_at == 1500.0
    assert codex.effective_read_at == 1000.0

    script["mode"] = "read"
    clock["now"] = 2000.0
    live = service.refresh_now(providers=("codex",), force=True).by_provider("codex")
    assert live.state is ProviderSourceState.READY
    assert live.read_at is None
    assert live.effective_read_at == 2000.0
    service.close()


def test_the_read_time_survives_a_save_and_a_restart(tmp_path) -> None:
    clock = {"now": 1000.0}
    script = {"mode": "read"}
    saved: list[ProviderUsageState] = []
    service = _read_time_service(
        tmp_path, script=script, clock=clock, state_saver=saved.append
    )
    service.refresh_now(providers=("codex",), force=True)
    script["mode"] = "fail"
    clock["now"] = 1100.0
    service.refresh_now(providers=("codex",), force=True)
    service.close()
    persisted = saved[-1]
    assert persisted.by_provider("codex").effective_read_at == 1000.0

    restarted = _read_time_service(
        tmp_path,
        script=script,
        clock=clock,
        state_loader=lambda: persisted,
    )
    clock["now"] = 1200.0
    codex = restarted.refresh_now(providers=("codex",), force=True).by_provider("codex")

    assert codex.state is ProviderSourceState.STALE
    assert codex.observed_at == 1200.0
    assert codex.effective_read_at == 1000.0
    restarted.close()


def test_the_cadence_ladder_is_pure_and_ordered():
    from jrbar.provider_usage_runtime import _interval_for

    assert _interval_for((), 10_000.0, menu_last_opened_at=9_900.0) == 120.0
    assert _interval_for((), 10_000.0, menu_last_opened_at=9_000.0) == 300.0
    assert _interval_for((), 10_000.0, menu_last_opened_at=6_000.0) == 900.0
    assert _interval_for((), 10_000.0, menu_last_opened_at=None) == 1800.0
    assert (
        _interval_for((), 10_000.0, menu_last_opened_at=9_990.0, constrained=True)
        == 1800.0
    ), "Low Power Mode outranks a fresh visit"


def test_an_imminent_reset_is_still_watched_closely__and_2_more(tmp_path) -> None:
    # --- scenario: an_imminent_reset_is_still_watched_closely
    """Our one deliberate divergence: we celebrate resets, so we have to
    see the boundary cross -- 120s, not the old 30s hammer."""
    from jrbar.provider_usage_runtime import _interval_for

    soon = snapshot("codex", remaining=50, observed=1000)
    lane = soon.lanes[0]
    from dataclasses import replace as dataclass_replace

    soon = dataclass_replace(
        soon, lanes=(dataclass_replace(lane, reset_at=1000 + 120.0),)
    )
    assert _interval_for((soon,), 1000.0, menu_last_opened_at=None) == 120.0

    # --- scenario: request_runs_off_caller_thread_and_coalesces
    settings = default_provider_usage_settings()
    gate = threading.Event()
    collector_threads = []
    callback_threads = []

    def collect(_pref, _home, observed, _credentials):
        collector_threads.append(threading.current_thread().name)
        gate.wait(2)
        return snapshot("codex", observed=observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": collect},
        credentials=object(),
        home=tmp_path,
        clock=time.time,
    )
    callbacks = []
    callbacks_ready = threading.Event()

    def callback(state):
        callback_threads.append(threading.current_thread().name)
        callbacks.append(state)
        callbacks_ready.set()

    first = service.request(callback=callback, providers=("codex",), force=True)
    # A FORCED request during an in-flight run may not piggyback on it:
    # that run already read the old credential, which is how "Reconnect"
    # used to report pre-click results as fresh ones. It runs once more.
    second = service.request(callback=callback, providers=("codex",), force=True)
    # An UNFORCED request still coalesces onto whatever is in flight.
    third = service.request(callback=callback, providers=("codex",))
    assert first.refreshing is True
    assert second.refreshing is True
    assert third.refreshing is True
    gate.set()
    assert callbacks_ready.wait(3)
    # The replacement always owns publication. If the obsolete worker has
    # not entered its collector yet, the generation fence cancels that read;
    # otherwise both collectors drain and only the replacement publishes.
    assert 1 <= len(collector_threads) <= 2
    assert all(
        name != threading.current_thread().name for name in collector_threads
    )
    assert callback_threads
    assert all(name != threading.current_thread().name for name in callback_threads)
    assert callbacks and callbacks[0].refreshing is False
    service.close()


    # --- scenario: replacement_refresh_publishes_first_and_older_generation_cannot_publish
    settings = default_provider_usage_settings()
    first_started = threading.Event()
    release_first = threading.Event()
    replacement_done = threading.Event()
    calls_lock = threading.Lock()
    calls = 0
    callbacks = []
    superseded = threading.Event()

    def record_receipt(receipt):
        if receipt.outcome is RefreshPublicationOutcome.SUPERSEDED:
            superseded.set()

    def collect(_pref, _home, observed, _credentials):
        nonlocal calls
        with calls_lock:
            calls += 1
            call = calls
        if call == 1:
            first_started.set()
            assert release_first.wait(3.0)
            return snapshot("codex", remaining=10, observed=observed)
        if call == 2:
            return snapshot("codex", remaining=80, observed=observed)
        return snapshot(
            "codex",
            state=ProviderSourceState.UNAVAILABLE,
            observed=observed,
        )

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": collect},
        credentials=object(),
        home=tmp_path,
        clock=time.time,
        receipt_handler=record_receipt,
    )

    service.request(
        callback=lambda state: callbacks.append(state),
        providers=("codex",),
        force=True,
    )
    assert first_started.wait(1.0)
    service.request(
        callback=lambda state: (callbacks.append(state), replacement_done.set()),
        providers=("codex",),
        force=True,
    )

    assert not replacement_done.wait(0.05), "replacement ran beside the obsolete refresh"
    release_first.set()
    assert replacement_done.wait(2.0)
    assert service.snapshot().by_provider("codex").lanes[0].remaining_percent == 80
    assert superseded.wait(2.0)

    assert service.snapshot().by_provider("codex").lanes[0].remaining_percent == 80
    assert all(
        state.by_provider("codex").lanes[0].remaining_percent == 80
        for state in callbacks
    )
    assert superseded.is_set()
    failed = service.refresh_now(providers=("codex",), force=True)
    assert failed.by_provider("codex").state is ProviderSourceState.STALE
    assert failed.by_provider("codex").lanes[0].remaining_percent == 80
    service.close()


def test_forced_refresh_burst_keeps_one_worker_and_one_latest_replacement(tmp_path) -> None:
    settings = default_provider_usage_settings()
    entered = threading.Event()
    release = threading.Event()
    completed = threading.Event()
    calls = []

    def collect(_preference, _home, observed, _credentials):
        calls.append(observed)
        if len(calls) == 1:
            entered.set()
            assert release.wait(3.0)
        return snapshot("codex", remaining=20 + len(calls), observed=observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": collect},
        credentials=object(),
        home=tmp_path,
        clock=time.time,
        incident_lookup=lambda *_args: None,
    )
    service.request(callback=lambda _state: None, providers=("codex",), force=True)
    assert entered.wait(1.0)
    for _ in range(100):
        service.request(
            callback=lambda _state: completed.set(),
            providers=("codex",),
            force=True,
        )
    assert len(service._workers) == 1
    assert service._pending_refresh is not None
    release.set()
    assert completed.wait(3.0)
    assert len(calls) == 2
    assert len(service._workers) <= 1
    service.close()



def test_refresh_now_replaces_async_work_and_delivers_its_pending_callback__and_2_more(tmp_path) -> None:
    # --- scenario: refresh_now_replaces_async_work_and_delivers_its_pending_callback
    settings = default_provider_usage_settings()
    async_started = threading.Event()
    release_async = threading.Event()
    callback_done = threading.Event()
    calls_lock = threading.Lock()
    calls = 0
    callbacks = []

    def collect(_pref, _home, observed, _credentials):
        nonlocal calls
        with calls_lock:
            calls += 1
            call = calls
        if call == 1:
            async_started.set()
            assert release_async.wait(3.0)
            return snapshot("codex", remaining=10, observed=observed)
        return snapshot("codex", remaining=80, observed=observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": collect},
        credentials=object(),
        home=tmp_path,
        clock=time.time,
    )
    caller_thread = threading.current_thread()
    service.request(
        callback=lambda state: (
            callbacks.append((threading.current_thread(), state)),
            callback_done.set(),
        ),
        providers=("codex",),
        force=True,
    )
    assert async_started.wait(1.0)

    replacement = service.refresh_now(providers=("codex",), force=True)

    assert replacement.by_provider("codex").lanes[0].remaining_percent == 80
    assert callback_done.wait(1.0), "superseded async callback was leaked"
    assert len(callbacks) == 1
    callback_thread, callback_state = callbacks[0]
    assert callback_thread is not caller_thread
    assert callback_state.by_provider("codex").lanes[0].remaining_percent == 80
    with service._lock:
        assert service._callbacks == []

    release_async.set()
    service.close()

    # --- scenario: close_refuses_late_publication_and_callback
    settings = default_provider_usage_settings()
    started = threading.Event()
    release = threading.Event()
    refused = threading.Event()
    callbacks = []

    def collect(_pref, _home, observed, _credentials):
        started.set()
        assert release.wait(3.0)
        return snapshot("codex", remaining=15, observed=observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": collect},
        credentials=object(),
        home=tmp_path,
        clock=time.time,
        receipt_handler=lambda receipt: (
            refused.set()
            if receipt.outcome is RefreshPublicationOutcome.REFUSED
            else None
        ),
    )
    initial = service.snapshot()
    service.request(
        callback=callbacks.append,
        providers=("codex",),
        force=True,
    )
    assert started.wait(1.0)

    service.close()
    release.set()
    assert refused.wait(2.0)

    assert callbacks == []
    assert service.snapshot().snapshots == initial.snapshots

    # --- scenario: request_uses_the_service_clock_for_refresh_gating
    settings = default_provider_usage_settings()
    clock = {"now": 1000.0}
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={},
        credentials=object(),
        home=tmp_path,
        clock=lambda: clock["now"],
    )

    service.refresh_now()
    clock["now"] = 1001.0
    result = service.request(
        callback=lambda _state: None,
        providers=("codex",),
        force=False,
    )

    assert result.refreshing is False
    assert service.snapshot().refreshing is False



def test_service_exposes_the_exact_settings_snapshot_used_for_collection__and_2_more(tmp_path) -> None:
    # --- scenario: service_exposes_the_exact_settings_snapshot_used_for_collection
    settings = default_provider_usage_settings().with_enabled("grok", False)
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
    )

    assert service.settings_snapshot() is None
    service.refresh_now(force=True)

    assert service.settings_snapshot() is settings

    # --- scenario: collectors_receive_only_the_typed_collection_projection
    settings = default_provider_usage_settings()
    observed_preferences = []

    def collect(preference, _home, observed, _credentials):
        observed_preferences.append(preference)
        assert type(preference) is ProviderCollectionFeature
        assert not hasattr(preference, "menu_visible")
        assert not hasattr(preference, "reset_celebrations")
        assert not hasattr(preference, "threshold_remaining")
        return snapshot("devin", observed=observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"devin": collect},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
    )

    service.refresh_now(providers=("devin",), force=True)

    assert len(observed_preferences) == 1

    # --- scenario: same_provider_instances_collect_and_remain_exactly_addressable
    settings = default_provider_usage_settings()
    settings = settings.with_instance(
        dataclass_replace(
            settings.preference("claude"),
            source_instance_id="work",
            options=(("account", "work"),),
        )
    )

    def collect(preference, _home, observed, _credentials):
        return snapshot(
            "claude",
            remaining=20 if preference.source_instance_id == "work" else 80,
            observed=observed,
        )

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"claude": collect},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
    )

    state = service.refresh_now(providers=("claude",), force=True)

    assert state.by_instance("claude", "default").lanes[0].remaining_percent == 80
    assert state.by_instance("claude", "work").lanes[0].remaining_percent == 20
    with pytest.raises(ValueError, match="ambiguous"):
        state.by_provider("claude")



def test_explicit_settings_update_outlives_an_older_worker_load(tmp_path):
    initial = default_provider_usage_settings()
    updated = initial.with_enabled("grok", False)
    load_started = threading.Event()
    release_load = threading.Event()

    def load_settings():
        load_started.set()
        release_load.wait(2.0)
        return initial

    service = ProviderUsageService(
        settings_loader=load_settings,
        collectors={},
        credentials=object(),
        home=tmp_path,
        clock=time.time,
    )
    callbacks = []
    callbacks_ready = threading.Event()

    def callback(state):
        callbacks.append(state)
        callbacks_ready.set()

    service.request(callback=callback, force=True)
    assert load_started.wait(1.0)

    service.note_settings_updated(updated)
    release_load.set()
    assert callbacks_ready.wait(3.0)

    assert callbacks
    assert service.settings_snapshot() is updated
    service.close()


def test_provider_usage_apply_rejects_mixed_or_untyped_payloads():
    state = ProviderUsageState((), None, None, False)
    settings = project_presentation_settings(default_provider_usage_settings())

    assert ProviderUsageApply(state, settings).state is state
    with pytest.raises(ValueError, match="invalid provider usage state"):
        ProviderUsageApply(object(), settings)
    with pytest.raises(ValueError, match="invalid provider usage settings"):
        ProviderUsageApply(state, object())


def test_service_restores_and_persists_last_known_good__and_2_more(tmp_path) -> None:
    # --- scenario: service_restores_and_persists_last_known_good
    settings = default_provider_usage_settings()
    initial = ProviderUsageState(
        (snapshot("codex", remaining=17, observed=900),),
        900,
        960,
        False,
    )
    saved = []
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "codex": lambda _pref, _home, observed, _credentials: snapshot(
                "codex",
                state=ProviderSourceState.UNAVAILABLE,
                observed=observed,
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
        state_loader=lambda: initial,
        state_saver=saved.append,
    )
    assert service.snapshot() == initial
    refreshed = service.refresh_now(providers=("codex",), force=True)
    assert refreshed.by_provider("codex").state is ProviderSourceState.STALE
    assert refreshed.by_provider("codex").lanes[0].remaining_percent == 17
    assert saved == [refreshed]

    # --- scenario: a_stale_but_real_reading_is_not_replaced_by_the_last_known_good
    """Reported as "why does it say codex ... 48 percent, it should be
    around 96". The collector correctly marked a three-day-old Codex
    quota STALE, and this substitution handed the OLDER ready snapshot
    back instead -- so a frozen number kept rendering as live. A stale
    reading carrying real lanes is newer information than last_known_good
    and must win; only a reading with nothing in it falls back."""
    settings = default_provider_usage_settings().with_enabled("grok", False)
    current = {"state": ProviderSourceState.READY}

    def collector(_pref, _home, observed, _credentials):
        return snapshot("codex", state=current["state"], remaining=48, observed=observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": collector},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
    )

    first = service.refresh_now()
    codex = next(s for s in first.snapshots if s.provider_id == "codex")
    assert codex.state is ProviderSourceState.READY

    current["state"] = ProviderSourceState.STALE
    second = service.refresh_now()
    codex = next(s for s in second.snapshots if s.provider_id == "codex")
    assert codex.state is ProviderSourceState.STALE, "last_known_good masked a stale reading"
    assert codex.lanes[0].remaining_percent == 48

    # --- scenario: rate_limited_provider_backs_off_instead_of_hammering
    """The Claude usage endpoint 429s; before the failure gate the
    service asked again every refresh, which is how one STAYS rate
    limited. A gated provider serves its previous snapshot; a forced
    (user-initiated) refresh still pushes through."""
    settings = default_provider_usage_settings().with_enabled("grok", False)
    calls = []
    clock = {"now": 1000.0}

    def collector(_pref, _home, observed, _credentials):
        calls.append(observed)
        return snapshot(
            "claude", state=ProviderSourceState.RATE_LIMITED, observed=observed
        )

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"claude": collector},
        credentials=object(),
        home=tmp_path,
        clock=lambda: clock["now"],
    )

    service.refresh_now(providers=("claude",))
    assert len(calls) == 1
    clock["now"] = 1120.0  # inside the 300 s first rung
    service.refresh_now(providers=("claude",))
    assert len(calls) == 1, "a gated provider was re-collected"
    service.refresh_now(providers=("claude",), force=True)
    assert len(calls) == 2, "force must bypass the gate"
    clock["now"] = 1000.0 + 10_000.0  # past every rung
    service.refresh_now(providers=("claude",))
    assert len(calls) == 3



def test_terminal_gate_lifts_when_the_credential_file_changes__and_2_more(tmp_path) -> None:
    # --- scenario: terminal_gate_lifts_when_the_credential_file_changes
    """A signed-out provider is not worth re-asking every two minutes;
    it IS worth re-asking the moment the user signs in somewhere. The
    gate watches the provider's own credential file for that."""
    import json as _json

    settings = default_provider_usage_settings()
    calls = []
    clock = {"now": 1000.0}

    def collector(_pref, _home, observed, _credentials):
        calls.append(observed)
        return snapshot(
            "grok", state=ProviderSourceState.NEEDS_SIGN_IN, observed=observed
        )

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"grok": collector},
        credentials=object(),
        home=tmp_path,
        clock=lambda: clock["now"],
    )

    service.refresh_now(providers=("grok",))
    assert len(calls) == 1
    clock["now"] = 1200.0
    service.refresh_now(providers=("grok",))
    assert len(calls) == 1, "terminal failure was re-collected with no change"

    grok_dir = tmp_path / ".grok"
    grok_dir.mkdir()
    (grok_dir / "auth.json").write_text(
        _json.dumps({"https://auth.x.ai::a": {"key": "k" * 24}}),
        encoding="utf-8",
    )
    clock["now"] = 1300.0
    service.refresh_now(providers=("grok",))
    assert len(calls) == 2, "a credential change must lift the gate"

    # --- scenario: ready_without_lanes_does_not_clobber_a_real_reading
    """A lane-less READY says "the scan found no quota evidence" -- the
    absence of a reading, not a newer one. It must neither replace the
    last known good numbers nor render as a bare card with no number."""
    settings = default_provider_usage_settings().with_enabled("grok", False)
    current = {"lanes": True}

    def collector(_pref, _home, observed, _credentials):
        if current["lanes"]:
            return snapshot("codex", remaining=48, observed=observed)
        base = snapshot("codex", observed=observed)
        import dataclasses as _dataclasses

        return _dataclasses.replace(base, lanes=())

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": collector},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
    )

    first = service.refresh_now(providers=("codex",))
    assert first.by_provider("codex").lanes

    current["lanes"] = False
    second = service.refresh_now(providers=("codex",))
    codex = second.by_provider("codex")
    assert codex.state is ProviderSourceState.STALE
    assert codex.lanes and codex.lanes[0].remaining_percent == 48

    current["lanes"] = True
    third = service.refresh_now(providers=("codex",))
    assert third.by_provider("codex").state is ProviderSourceState.READY

    # --- scenario: forced_request_during_callback_delivery_is_not_swallowed
    """Hostile-review regression: the worker used to exit its rerun
    loop and only THEN deliver callbacks, still alive -- a forced
    request landing in that window piggybacked on a thread that would
    never look at its flags again. The click was swallowed and the
    leaked flags fired a spurious forced run minutes later. The worker
    now retires under the lock, so a request during delivery starts a
    fresh worker."""
    settings = default_provider_usage_settings()
    collects = []

    def collect(_pref, _home, observed, _credentials):
        collects.append(observed)
        return snapshot("codex", observed=observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": collect},
        credentials=object(),
        home=tmp_path,
        clock=time.time,
    )

    states = []
    second_round = threading.Event()

    def first_callback(state):
        states.append(("first", state))
        # We are INSIDE delivery: the worker has already made its exit
        # decision. A forced request from here must not be lost.
        service.request(
            callback=lambda s: (states.append(("second", s)), second_round.set()),
            providers=("codex",),
            force=True,
        )

    service.request(callback=first_callback, providers=("codex",), force=True)
    assert second_round.wait(3), "the mid-delivery forced request was swallowed"
    assert len(collects) == 2
    assert [name for name, _s in states] == ["first", "second"]
    service.close()


def test_claude_cache_continuity_requires_the_same_proved_account(tmp_path) -> None:
    settings = default_provider_usage_settings().with_enabled("grok", False)
    current = {"account": "claude-account-first", "state": ProviderSourceState.READY}

    def collector(_pref, _home, observed, _credentials):
        return snapshot(
            "claude",
            state=current["state"],
            remaining=25,
            observed=observed,
            account_discriminator=current["account"],
        )

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"claude": collector},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
        incident_lookup=lambda *_args: None,
    )
    assert service.refresh_now(providers=("claude",)).by_provider("claude").lanes

    current["state"] = ProviderSourceState.UNAVAILABLE
    same = service.refresh_now(providers=("claude",), force=True).by_provider("claude")
    assert same.state is ProviderSourceState.STALE
    assert same.lanes[0].remaining_percent == 25

    current["account"] = "claude-account-second"
    switched = service.refresh_now(providers=("claude",), force=True).by_provider("claude")
    assert switched.state is ProviderSourceState.UNAVAILABLE
    assert switched.lanes == ()

    current["account"] = None
    unknown = service.refresh_now(providers=("claude",), force=True).by_provider("claude")
    assert unknown.state is ProviderSourceState.UNAVAILABLE
    assert unknown.lanes == ()
    service.close()


def test_restored_claude_quota_is_withheld_before_refresh_after_account_switch(tmp_path) -> None:
    import json

    from jrbar.claude_quota import account_facts_from_claude_config

    (tmp_path / ".claude.json").write_text(
        json.dumps({"oauthAccount": {"emailAddress": "current@example.invalid"}}),
        encoding="utf-8",
    )
    _plan, current_account = account_facts_from_claude_config(tmp_path)
    assert current_account is not None
    old_claude = snapshot(
        "claude",
        remaining=9,
        account_discriminator="claude-account-previous",
    )
    codex = snapshot("codex", remaining=44)
    restored = ProviderUsageState((old_claude, codex), 900, 10_000, False)
    service = ProviderUsageService(
        settings_loader=default_provider_usage_settings,
        collectors={},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
        state_loader=lambda: restored,
        incident_lookup=lambda *_args: None,
    )

    before_refresh = service.snapshot()

    assert all(item.provider_id != "claude" for item in before_refresh.snapshots)
    assert before_refresh.by_provider("codex").lanes[0].remaining_percent == 44
    assert before_refresh.next_refresh_at is None
    service.close()



def _antigravity_reading(
    *,
    lane_id: str,
    source_id: str,
    remaining: float,
    input_tokens: int = 0,
    observed: float = 900,
) -> ProviderUsageSnapshot:
    return ProviderUsageSnapshot(
        provider_id="antigravity",
        account_label=None,
        observed_at=observed,
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=(
            UsageLane(
                provider_id="antigravity",
                lane_id=lane_id,
                label="Fixture",
                remaining_percent=remaining,
                reset_at=None,
                scope="gemini",
                model=None,
                feature=None,
                bindable=True,
                source_id=source_id,
            ),
        ),
        input_tokens=input_tokens,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
    )


def _antigravity_not_running(observed):
    return ProviderUsageSnapshot(
        provider_id="antigravity",
        account_label=None,
        observed_at=observed,
        state=ProviderSourceState.SOURCE_NOT_FOUND,
        reason_code="antigravity_not_detected",
        action_label="Open Antigravity",
        lanes=(),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
    )


def test_a_saved_invented_antigravity_lane_is_purged_on_restore(tmp_path) -> None:
    """Earlier builds saved a READY "Antigravity CLI 100% left" lane that no
    server ever measured, plus a steps-based token figure. Restoring it as
    the last known good would serve it back as a stale reading forever."""
    settings = default_provider_usage_settings()
    invented = _antigravity_reading(
        lane_id="cli",
        source_id="antigravity-oauth",
        remaining=100.0,
        input_tokens=3500,
    )
    initial = ProviderUsageState((invented,), 900, 960, False)
    saved: list[ProviderUsageState] = []
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "antigravity": lambda _pref, _home, observed, _credentials: (
                _antigravity_not_running(observed)
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
        state_loader=lambda: initial,
        state_saver=saved.append,
        incident_lookup=lambda *_args: None,
    )

    assert service.snapshot().snapshots == ()
    refreshed = service.refresh_now(providers=("antigravity",), force=True)
    reading = refreshed.by_provider("antigravity")

    assert reading.state is ProviderSourceState.SOURCE_NOT_FOUND
    assert reading.lanes == ()
    assert reading.input_tokens == 0
    for state in (service.snapshot(), *saved):
        for item in state.snapshots:
            assert all(lane.lane_id != "cli" for lane in item.lanes)
    service.close()


def test_a_real_antigravity_reading_is_kept_and_marked_stale_when_the_app_closes(
    tmp_path,
) -> None:
    settings = default_provider_usage_settings()
    real = _antigravity_reading(
        lane_id="gemini-weekly",
        source_id="antigravity-app",
        remaining=30.0,
    )
    initial = ProviderUsageState((real,), 900, 960, False)
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "antigravity": lambda _pref, _home, observed, _credentials: (
                _antigravity_not_running(observed)
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000,
        state_loader=lambda: initial,
        incident_lookup=lambda *_args: None,
    )

    reading = service.refresh_now(providers=("antigravity",), force=True).by_provider(
        "antigravity"
    )

    assert reading.state is ProviderSourceState.STALE
    assert reading.reason_code == "antigravity_not_detected"
    assert reading.action_label == "Open Antigravity"
    assert [lane.lane_id for lane in reading.lanes] == ["gemini-weekly"]
    assert reading.lanes[0].remaining_percent == 30.0
    service.close()


def test_an_antigravity_sign_in_refusal_waits_for_a_forced_refresh(tmp_path) -> None:
    """With no invented fallback lane to mask it, a server that answers
    401/403 reaches the terminal gate. Antigravity has no credential file
    the gate could watch, so only a forced refresh (or a relaunch) asks
    again. This pins that sticky behaviour so changing it is deliberate."""
    settings = default_provider_usage_settings()
    calls: list[float] = []
    clock = {"now": 1000.0}

    def collector(_pref, _home, observed, _credentials):
        calls.append(observed)
        return snapshot(
            "antigravity", state=ProviderSourceState.NEEDS_SIGN_IN, observed=observed
        )

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"antigravity": collector},
        credentials=object(),
        home=tmp_path,
        clock=lambda: clock["now"],
        incident_lookup=lambda *_args: None,
    )

    first = service.refresh_now(providers=("antigravity",))
    assert len(calls) == 1
    clock["now"] = 5000.0
    background = service.refresh_now(providers=("antigravity",))
    assert len(calls) == 1, "a terminal refusal was re-collected in the background"
    assert background.by_provider("antigravity") == first.by_provider("antigravity")

    service.refresh_now(providers=("antigravity",), force=True)
    assert len(calls) == 2, "a forced refresh must ask again"
    service.close()


def test_a_visible_quota_strip_counts_as_attention():
    """Our one adaptation of CodexBar's ladder: they only have a menu,
    we can be showing the number on the LED bar the whole time."""
    from jrbar.provider_usage_runtime import _interval_for

    assert _interval_for((), 10_000.0, menu_last_opened_at=None) == 1800.0
    assert (
        _interval_for((), 10_000.0, menu_last_opened_at=None, ambient_usage_visible=True)
        == 300.0
    )
    # It only ever tightens; a fresh visit still wins.
    assert (
        _interval_for(
            (), 10_000.0, menu_last_opened_at=9_990.0, ambient_usage_visible=True
        )
        == 120.0
    )
    # Low Power Mode outranks the ambient surface.
    assert (
        _interval_for(
            (),
            10_000.0,
            menu_last_opened_at=9_990.0,
            constrained=True,
            ambient_usage_visible=True,
        )
        == 1800.0
    )


def test_stale_refresh_is_superseded_then_worker_reruns_latest_settings__and_1_more(tmp_path) -> None:
    # --- scenario: stale_refresh_is_superseded_then_worker_reruns_latest_settings
    initial = default_provider_usage_settings().with_enabled("grok", True)
    updated = initial.with_enabled("grok", False)
    load_started = threading.Event()
    release_load = threading.Event()
    calls = []
    receipts = []

    def load_settings():
        load_started.set()
        release_load.wait(2.0)
        return initial if len(calls) == 0 else updated

    def collect(preference, _home, observed, _credentials):
        calls.append(preference.provider_id)
        return snapshot(preference.provider_id, observed=observed)

    service = ProviderUsageService(
        settings_loader=load_settings,
        collectors={"grok": collect},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        receipt_handler=receipts.append,
    )
    callbacks = []
    done = threading.Event()

    service.request(
        callback=lambda state: (callbacks.append(state), done.set()), force=True
    )
    assert load_started.wait(1.0)
    service.note_settings_updated(updated)
    release_load.set()

    assert done.wait(3.0)
    assert service.settings_snapshot() is updated
    assert callbacks and callbacks[-1].by_provider("grok").state is ProviderSourceState.DISABLED
    assert len(callbacks) == 1
    assert any(item.outcome is RefreshPublicationOutcome.SUPERSEDED for item in receipts)
    assert any(item.outcome is RefreshPublicationOutcome.ACCEPTED for item in receipts)
    service.close()

    # --- scenario: settings_update_after_persistence_suppresses_old_callback
    initial = default_provider_usage_settings().with_enabled("grok", True)
    updated = initial.with_enabled("grok", False)
    current = {"settings": initial}
    saved = []
    callbacks = []
    persisted = threading.Event()
    allow_receipt = threading.Event()
    update_done = threading.Event()

    def receipt_handler(receipt):
        if receipt.outcome is RefreshPublicationOutcome.ACCEPTED and not persisted.is_set():
            # The receipt is emitted after state persistence. Hold the
            # worker in the callback-delivery gap while another thread edits
            # settings, after the durable save but before callback delivery.
            persisted.set()
            allow_receipt.wait(2.0)

    def update_settings() -> None:
        assert persisted.wait(2.0)
        current["settings"] = updated
        service.note_settings_updated(updated)
        update_done.set()

    service = ProviderUsageService(
        settings_loader=lambda: current["settings"],
        collectors={
            "grok": lambda preference, _home, observed, _credentials: snapshot(
                preference.provider_id, observed=observed
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        state_saver=saved.append,
        receipt_handler=receipt_handler,
    )
    done = threading.Event()
    updater = threading.Thread(target=update_settings, daemon=True)
    updater.start()

    service.request(
        callback=lambda state: (callbacks.append(state), done.set()),
        providers=("grok",),
        force=True,
    )

    assert persisted.wait(2.0)
    assert update_done.wait(2.0)
    allow_receipt.set()
    assert done.wait(3.0)
    assert len(saved) == 2
    assert callbacks[-1].by_provider("grok").state is ProviderSourceState.DISABLED
    assert len(callbacks) == 1
    service.close()



# --- Providers are asked together, and answered as they arrive --------------


class _Published:
    """The states a request's callback received, waited on by condition."""

    def __init__(self) -> None:
        self._condition = threading.Condition()
        self.states: list[ProviderUsageState] = []

    def __call__(self, state: ProviderUsageState) -> None:
        with self._condition:
            self.states.append(state)
            self._condition.notify_all()

    def wait_for(self, predicate, *, timeout: float = 30.0) -> ProviderUsageState:
        with self._condition:
            assert self._condition.wait_for(
                lambda: any(predicate(state) for state in self.states),
                timeout=timeout,
            ), "the state the test waits for never arrived"
            return next(state for state in self.states if predicate(state))


def _percent(state: ProviderUsageState, provider_id: str):
    lane = state.by_provider(provider_id).lanes[0]
    return lane.remaining_percent


def test_a_slow_provider_does_not_hold_back_a_quick_providers_reading(tmp_path) -> None:
    settings = default_provider_usage_settings()
    codex_running = threading.Event()
    release_codex = threading.Event()

    def slow_codex(_pref, _home, observed, _credentials):
        codex_running.set()
        assert release_codex.wait(30.0)
        return snapshot("codex", remaining=40, observed=observed)

    previous_codex = snapshot("codex", remaining=55, observed=500)
    saved: list[ProviderUsageState] = []
    receipts: list = []
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        receipt_handler=receipts.append,
        collectors={
            "codex": slow_codex,
            "claude": lambda _pref, _home, observed, _credentials: snapshot(
                "claude", remaining=70, observed=observed
            ),
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        state_loader=lambda: ProviderUsageState((previous_codex,), 900.0, 0.0, False),
        state_saver=saved.append,
        incident_lookup=lambda *_args: None,
        partial_publish_after_seconds=0.0,
    )
    published = _Published()
    service.request(callback=published, providers=("codex", "claude"), force=True)

    partial = published.wait_for(
        lambda state: any(item.provider_id == "claude" for item in state.snapshots)
    )

    # Claude's reading is on show while Codex is still being asked ...
    assert codex_running.is_set() and not release_codex.is_set()
    assert partial.refreshing is True
    assert _percent(partial, "claude") == 70
    assert service.snapshot().by_provider("claude").state is ProviderSourceState.READY
    # ... and the slow provider keeps its last good reading, not a gap.
    assert partial.by_provider("codex") == previous_codex
    # A partial is never written to disk: the file only holds a finished refresh.
    assert saved == []

    release_codex.set()
    final = published.wait_for(lambda state: not state.refreshing)
    assert _percent(final, "codex") == 40
    assert _percent(final, "claude") == 70
    assert [state.refreshing for state in saved] == [False]
    assert receipts[-1].outcome is RefreshPublicationOutcome.ACCEPTED
    assert len(receipts) == 1
    service.close()


def test_providers_are_asked_at_the_same_time(tmp_path) -> None:
    # Two collectors that can only finish if both are running at once: run one
    # after the other and the barrier breaks, and both come back as errors.
    settings = default_provider_usage_settings()
    meeting = threading.Barrier(2, timeout=30.0)

    def meets(provider_id):
        def collect(_pref, _home, observed, _credentials):
            meeting.wait()
            return snapshot(provider_id, observed=observed)

        return collect

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": meets("codex"), "claude": meets("claude")},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        incident_lookup=lambda *_args: None,
    )

    state = service.refresh_now(providers=("codex", "claude"), force=True)

    assert state.by_provider("codex").state is ProviderSourceState.READY
    assert state.by_provider("claude").state is ProviderSourceState.READY


def _round_job(slot: int, provider_id: str, instance: str = "default") -> _CollectJob:
    from types import SimpleNamespace

    return _CollectJob(
        slot=slot,
        preference=SimpleNamespace(
            provider_id=provider_id,
            source_instance_id=instance,
            identity=(provider_id, instance),
        ),
        collector=lambda *_args: None,
        gate=FailureGate(),
        fingerprint=None,
        repair_grok=False,
    )


def test_a_round_asks_a_bounded_number_at_once_in_settings_order() -> None:
    jobs = [_round_job(slot, name) for slot, name in enumerate(("codex", "claude", "cursor", "devin"))]
    release = {job.slot: threading.Event() for job in jobs}
    started: list[int] = []

    def run(job):
        started.append(job.slot)
        assert release[job.slot].wait(30.0)
        return snapshot(job.provider_id)

    collection = _CollectionRound(
        jobs,
        run=run,
        unanswered=lambda job, reason: snapshot(job.provider_id),
        max_concurrent=2,
        deadline_seconds=45.0,
        monotonic=lambda: 0.0,
    )

    # `wake_at` in the past makes advance() a poll: it starts what may start.
    assert collection.advance(wake_at=-1.0) == []
    assert collection.in_flight == 2

    release[0].set()
    finished: list[int] = []
    while not collection.finished:
        for job, _candidate in collection.advance():
            finished.append(job.slot)
            assert collection.in_flight <= 2
            for later in jobs:
                release[later.slot].set()
    assert sorted(finished) == [0, 1, 2, 3]
    # The third and fourth waited their turn, in order.
    assert started.index(2) < started.index(3)
    assert set(started[:2]) == {0, 1}


def test_a_round_never_runs_two_instances_of_one_provider_together() -> None:
    jobs = [
        _round_job(0, "claude", "default"),
        _round_job(1, "claude", "work"),
        _round_job(2, "codex"),
    ]
    release = {job.slot: threading.Event() for job in jobs}

    def run(job):
        assert release[job.slot].wait(30.0)
        return snapshot(job.provider_id)

    collection = _CollectionRound(
        jobs,
        run=run,
        unanswered=lambda job, reason: snapshot(job.provider_id),
        max_concurrent=4,
        deadline_seconds=45.0,
        monotonic=lambda: 0.0,
    )

    assert collection.advance(wake_at=-1.0) == []
    # The first Claude and Codex run; the second Claude waits for the first.
    assert collection.in_flight == 2
    assert collection.settled_all("claude") is False

    release[0].set()
    first = collection.advance()
    assert [job.slot for job, _candidate in first] == [0]
    assert collection.in_flight == 2  # the second Claude is up, beside Codex
    for event in release.values():
        event.set()
    answered = []
    while not collection.finished:
        answered.extend(job.slot for job, _candidate in collection.advance())
    assert sorted(answered) == [1, 2]


def test_a_round_gives_up_on_a_collector_past_its_deadline_and_drops_its_late_answer() -> None:
    clock = {"now": 0.0}
    hung = _round_job(0, "claude")
    fine = _round_job(1, "codex")
    hung_running = threading.Event()
    release_hung = threading.Event()
    answered_by_hung: list[str] = []

    def run(job):
        if job is hung:
            hung_running.set()
            assert release_hung.wait(30.0)
            answered_by_hung.append("late")
        return snapshot(job.provider_id)

    gave_up: list[tuple[int, str]] = []

    def unanswered(job, reason):
        gave_up.append((job.slot, reason))
        return snapshot(job.provider_id, state=ProviderSourceState.UNAVAILABLE)

    collection = _CollectionRound(
        [hung, fine],
        run=run,
        unanswered=unanswered,
        max_concurrent=4,
        deadline_seconds=45.0,
        monotonic=lambda: clock["now"],
    )
    # The fine collector answers promptly; the clock then passes the deadline.
    answers = collection.advance(wake_at=-1.0)
    assert hung_running.wait(30.0)
    while not any(job is fine for job, _candidate in answers):
        answers.extend(collection.advance(wake_at=-1.0))
    clock["now"] = 46.0
    answers.extend(collection.advance())

    assert [(job.slot, candidate.state) for job, candidate in answers] == [
        (1, ProviderSourceState.READY),
        (0, ProviderSourceState.UNAVAILABLE),
    ]
    assert gave_up == [(0, "response_timed_out")]
    assert collection.finished

    # The hung collector comes back after it was given up on: nothing reports it.
    release_hung.set()
    assert collection.advance() == []
    assert gave_up == [(0, "response_timed_out")]


def test_the_published_order_follows_the_settings_whatever_order_providers_finish(tmp_path) -> None:
    settings = default_provider_usage_settings()
    order = ("codex", "cursor", "devin")
    release = {name: threading.Event() for name in order}
    lookups: list[str] = []

    def collector(provider_id):
        def collect(_pref, _home, observed, _credentials):
            assert release[provider_id].wait(30.0)
            return snapshot(provider_id, remaining=10, observed=observed)

        return collect

    previous = tuple(snapshot(name, remaining=90, observed=500) for name in order)
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={name: collector(name) for name in order},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        state_loader=lambda: ProviderUsageState(previous, 900.0, 0.0, False),
        incident_lookup=lambda provider_id, _observed: lookups.append(provider_id),
        partial_publish_after_seconds=0.0,
    )
    published = _Published()
    service.request(callback=published, providers=order, force=True)

    # Finish them in the reverse of the settings order, one at a time.
    for name in reversed(order[1:]):
        release[name].set()
        published.wait_for(lambda state, name=name: (
            state.refreshing and _percent(state, name) == 10
        ))
    release["codex"].set()
    final = published.wait_for(lambda state: not state.refreshing)

    assert tuple(item.provider_id for item in final.snapshots) == order
    assert {_percent(final, name) for name in order} == {10}
    for state in published.states:
        assert tuple(item.provider_id for item in state.snapshots) == order
    # Each partial showed the answered providers new and the others as they were.
    devin_first = published.wait_for(lambda state: state.refreshing and _percent(state, "devin") == 10)
    assert _percent(devin_first, "codex") == 90
    # A status page is asked about each provider once for the whole refresh.
    assert sorted(lookups) == sorted(order)
    service.close()


def test_a_collector_that_raises_costs_only_its_own_provider(tmp_path) -> None:
    settings = default_provider_usage_settings()
    calls: list[str] = []

    def broken(*_args):
        calls.append("claude")
        raise RuntimeError("private body must not surface")

    def fine(provider_id):
        def collect(_pref, _home, observed, _credentials):
            calls.append(provider_id)
            return snapshot(provider_id, remaining=33, observed=observed)

        return collect

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": fine("codex"), "claude": broken, "cursor": fine("cursor")},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        incident_lookup=lambda *_args: None,
    )

    state = service.refresh_now(providers=("codex", "claude", "cursor"), force=True)

    assert state.by_provider("claude").state is ProviderSourceState.ERROR
    assert state.by_provider("claude").reason_code == "collector_failed"
    assert _percent(state, "codex") == 33
    assert _percent(state, "cursor") == 33
    assert tuple(item.provider_id for item in state.snapshots) == ("codex", "claude", "cursor")

    # The retry gate is Claude's alone: the next unforced refresh skips Claude
    # (its ladder is armed) and asks the other two again.
    calls.clear()
    service.refresh_now(providers=("codex", "claude", "cursor"))
    assert sorted(calls) == ["codex", "cursor"]


def test_a_collector_past_its_deadline_is_a_transient_failure_for_that_provider_only(
    tmp_path,
) -> None:
    # The only test here that waits on a real deadline (one second); the
    # round's own deadline arithmetic is proved on a fake clock above.
    settings = default_provider_usage_settings()
    release_hung = threading.Event()
    calls: list[str] = []

    def hung(_pref, _home, observed, _credentials):
        calls.append("codex")
        assert release_hung.wait(30.0)
        return snapshot("codex", remaining=1, observed=observed)

    def fine(_pref, _home, observed, _credentials):
        calls.append("claude")
        return snapshot("claude", remaining=64, observed=observed)

    previous_codex = snapshot("codex", remaining=55, observed=500)
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": hung, "claude": fine},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        state_loader=lambda: ProviderUsageState((previous_codex,), 900.0, 0.0, False),
        incident_lookup=lambda *_args: None,
        collector_deadline_seconds=1.0,
        partial_publish_after_seconds=0.0,
    )
    published = _Published()
    service.request(callback=published, providers=("codex", "claude"), force=True)
    final = published.wait_for(lambda state: not state.refreshing)

    # Claude answered; Codex ran out of time and shows its last good reading.
    assert _percent(final, "claude") == 64
    assert final.by_provider("claude").state is ProviderSourceState.READY
    codex = final.by_provider("codex")
    assert codex.state is ProviderSourceState.STALE
    assert codex.reason_code == "response_timed_out"
    assert codex.action_label == "Retry"
    assert codex.lanes[0].remaining_percent == 55
    assert codex.effective_read_at == previous_codex.effective_read_at
    assert tuple(item.provider_id for item in final.snapshots) == ("codex", "claude")

    # It arms Codex's transient retry gate and nobody else's: the next
    # unforced refresh skips Codex and asks Claude again.
    calls.clear()
    again = service.refresh_now(providers=("codex", "claude"))
    assert calls == ["claude"]
    assert again.by_provider("codex").lanes[0].remaining_percent == 55

    # The overdue collector finally returns; its answer changes nothing.
    release_hung.set()
    assert service.snapshot().by_provider("codex").lanes[0].remaining_percent == 55
    service.close()


def test_a_scoped_refresh_asks_only_the_named_provider_and_keeps_the_rest(tmp_path) -> None:
    settings = default_provider_usage_settings()
    asked: list[str] = []

    def collector(provider_id, remaining):
        def collect(_pref, _home, observed, _credentials):
            asked.append(provider_id)
            return snapshot(provider_id, remaining=remaining, observed=observed)

        return collect

    clock = iter((1000.0, 1100.0))
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "codex": collector("codex", 10),
            "claude": collector("claude", 20),
            "cursor": collector("cursor", 30),
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: next(clock),
        incident_lookup=lambda *_args: None,
    )
    service.refresh_now(providers=("codex", "claude", "cursor"), force=True)
    asked.clear()

    scoped = service.refresh_now(providers=("claude",), force=True)

    assert asked == ["claude"]
    assert tuple(item.provider_id for item in scoped.snapshots) == ("codex", "claude", "cursor")
    assert scoped.by_provider("claude").observed_at == 1100.0
    assert scoped.by_provider("codex").observed_at == 1000.0
    assert scoped.by_provider("cursor").observed_at == 1000.0


def test_a_scoped_request_publishes_the_named_provider_quickly_beside_the_rest(tmp_path) -> None:
    # The forced scoped path a "Fix sign-in" click uses: only Claude is asked,
    # the others keep what they showed, and the state still arrives once.
    settings = default_provider_usage_settings()
    asked: list[str] = []

    def claude(_pref, _home, observed, _credentials):
        asked.append("claude")
        return snapshot("claude", remaining=88, observed=observed)

    previous_codex = snapshot("codex", remaining=55, observed=500)
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"claude": claude, "codex": lambda *_args: pytest.fail("not in scope")},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        state_loader=lambda: ProviderUsageState((previous_codex,), 900.0, 0.0, False),
        incident_lookup=lambda *_args: None,
    )
    published = _Published()
    service.request(callback=published, providers=("claude",), force=True)
    final = published.wait_for(lambda state: not state.refreshing)

    assert asked == ["claude"]
    assert _percent(final, "claude") == 88
    assert final.by_provider("codex") == previous_codex
    service.close()


def test_a_partial_state_is_published_only_by_the_run_it_belongs_to(tmp_path) -> None:
    settings = default_provider_usage_settings()
    old = snapshot("codex", remaining=55, observed=500)
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        state_loader=lambda: ProviderUsageState((old,), 900.0, 3000.0, False),
    )
    shown = []
    service._callbacks.append((0, shown.append))
    fresh = (snapshot("codex", remaining=10, observed=1000),)
    books = _RefreshBooks({}, {})

    # A run of another generation, or one whose settings were edited, or a
    # closed service: nothing is published.
    service._publish_partial(fresh, books, generation=5, settings_revision=0)
    service.note_settings_updated(settings)
    service._publish_partial(fresh, books, generation=0, settings_revision=0)
    assert service.snapshot().by_provider("codex") == old
    assert shown == []

    # The run that owns the current generation and revision publishes: still
    # refreshing, on the schedule it had, its callbacks handed the state but
    # not retired, and the books committed with it.
    revision = service._settings_revision
    books.last_known_good[("codex", "default", "")] = fresh[0]
    service._publish_partial(fresh, books, generation=0, settings_revision=revision)
    live = service.snapshot()
    assert live.refreshing is True
    assert live.next_refresh_at == 3000.0
    assert live.refreshed_at == 900.0
    assert _percent(live, "codex") == 10
    assert shown == [live]
    assert len(service._callbacks) == 1
    assert service._last_known_good == books.last_known_good
    assert service._last_known_good is not books.last_known_good

    service.close()
    service._publish_partial(
        (snapshot("codex", remaining=1, observed=1100),),
        books,
        generation=service._refresh_generation,
        settings_revision=revision,
    )
    assert _percent(service.snapshot(), "codex") == 10


# --- A replaced refresh stops waiting; a stuck provider stays busy ----------


def test_a_forced_scoped_request_does_not_wait_behind_an_older_refreshs_slowest_provider(
    tmp_path,
) -> None:
    # The Fix sign-in click is exactly this: a forced request for one provider,
    # landing while an older refresh waits on a provider that does not answer.
    settings = default_provider_usage_settings()
    cursor_running = threading.Event()
    release_cursor = threading.Event()

    def hung_cursor(_pref, _home, observed, _credentials):
        cursor_running.set()
        assert release_cursor.wait(30.0)
        return snapshot("cursor", observed=observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "cursor": hung_cursor,
            "claude": lambda _pref, _home, observed, _credentials: snapshot(
                "claude", remaining=77, observed=observed
            ),
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        incident_lookup=lambda *_args: None,
        # Far past the test's own bound: only abandoning the old refresh can
        # let the new one through in time.
        collector_deadline_seconds=600.0,
        partial_publish_after_seconds=None,
    )
    try:
        service.request(callback=_Published(), providers=("cursor",), force=True)
        assert cursor_running.wait(30.0)

        published = _Published()
        service.request(callback=published, providers=("claude",), force=True)
        final = published.wait_for(lambda state: not state.refreshing)

        # The scoped result is out while the old refresh's provider is still hung.
        assert not release_cursor.is_set()
        assert final.by_provider("claude").state is ProviderSourceState.READY
        assert _percent(final, "claude") == 77
    finally:
        release_cursor.set()
        service.close()


def test_closing_the_service_does_not_wait_for_a_hung_provider(tmp_path) -> None:
    settings = default_provider_usage_settings()
    running = threading.Event()
    release = threading.Event()

    def hung(_pref, _home, observed, _credentials):
        running.set()
        assert release.wait(30.0)
        return snapshot("codex", observed=observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"codex": hung},
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        incident_lookup=lambda *_args: None,
        collector_deadline_seconds=600.0,
    )
    service.request(callback=lambda _state: None, providers=("codex",), force=True)
    assert running.wait(30.0)
    workers = tuple(service._workers)
    assert workers

    service.close()  # joins for at most a second

    try:
        assert not any(worker.is_alive() for worker in workers)
    finally:
        release.set()


def test_a_round_that_is_abandoned_stops_waiting_and_drops_late_answers() -> None:
    hung = _round_job(0, "claude")
    running = threading.Event()
    release = threading.Event()

    def run(job):
        running.set()
        assert release.wait(30.0)
        return snapshot(job.provider_id)

    collection = _CollectionRound(
        [hung, _round_job(1, "codex")],
        run=run,
        unanswered=lambda job, reason: snapshot(job.provider_id),
        max_concurrent=1,
        deadline_seconds=45.0,
        monotonic=lambda: 0.0,
    )
    assert collection.advance(wake_at=-1.0) == []
    assert running.wait(30.0)
    assert collection.in_flight == 1 and not collection.finished

    collection.abandon()

    # Nothing running, nothing waiting: the caller is done at once, and the
    # job that never started never will.
    assert collection.in_flight == 0
    assert collection.finished
    release.set()
    assert collection.advance() == []


def test_a_round_never_blocks_longer_than_its_poll() -> None:
    import time

    release = threading.Event()
    collection = _CollectionRound(
        [_round_job(0, "claude")],
        run=lambda job: (release.wait(30.0), snapshot(job.provider_id))[1],
        unanswered=lambda job, reason: snapshot(job.provider_id),
        max_concurrent=1,
        # The fake clock never moves, so the deadline is 45 s away: only the
        # poll can bring advance() back.
        deadline_seconds=45.0,
        monotonic=lambda: 0.0,
        poll_seconds=0.01,
    )
    started = time.monotonic()
    try:
        assert collection.advance() == []
        assert time.monotonic() - started < 10.0
    finally:
        release.set()


def test_a_provider_whose_collector_was_given_up_on_stays_busy_for_the_round() -> None:
    clock = {"now": 0.0}
    first, second = _round_job(0, "claude", "default"), _round_job(1, "claude", "work")
    running = threading.Event()
    release = threading.Event()
    ran: list[int] = []

    def run(job):
        ran.append(job.slot)
        running.set()
        assert release.wait(30.0)
        return snapshot(job.provider_id)

    reasons: list[tuple[int, str]] = []

    def unanswered(job, reason):
        reasons.append((job.slot, reason))
        return snapshot(job.provider_id, state=ProviderSourceState.UNAVAILABLE)

    collection = _CollectionRound(
        [first, second],
        run=run,
        unanswered=unanswered,
        max_concurrent=4,
        deadline_seconds=45.0,
        monotonic=lambda: clock["now"],
    )
    assert collection.advance(wake_at=-1.0) == []
    assert running.wait(30.0)

    clock["now"] = 46.0
    answers = collection.advance()

    # The first instance timed out and its thread is still running, so the
    # second is not started beside it: it times out too, unasked.
    assert sorted(job.slot for job, _candidate in answers) == [0, 1]
    assert reasons == [(0, "response_timed_out"), (1, "response_timed_out")]
    assert ran == [0]
    assert collection.finished
    release.set()


def test_the_default_deadline_covers_the_slowest_source_that_can_still_succeed() -> None:
    # Gemini makes three requests in a row (token refresh, project lookup,
    # quota), each allowed HTTP_TIMEOUT_SECONDS per socket operation. A
    # shorter deadline would time it out on every slow-network refresh.
    from jrbar import provider_usage_collectors
    from jrbar.provider_usage_runtime import DEFAULT_COLLECTOR_DEADLINE_SECONDS

    assert DEFAULT_COLLECTOR_DEADLINE_SECONDS > 3 * provider_usage_collectors.HTTP_TIMEOUT_SECONDS
