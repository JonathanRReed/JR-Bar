"""A source that stays broken the same way is asked less and less often.

A provider with no quota source (Cursor without an imported browser session,
Gemini without a Code Assist project) can only be fixed by the person, and
their fix asks for a refresh itself. Asking every two minutes meanwhile kept
every other provider's collector (a spawned CLI, a keychain read, a network
call) running on that same two-minute beat for as long as the Mac was awake.
"""

from __future__ import annotations

from dataclasses import replace

from jrbar import adaptive_refresh
from jrbar.provider_usage_platform import ProviderSourceState
from jrbar.provider_usage_runtime import ProviderUsageService
from jrbar.provider_usage_settings import default_provider_usage_settings
from tests.test_adaptive_refresh_acceptance import _usage_snapshot

QUICK = adaptive_refresh.DEGRADED_INTERVAL_SECONDS
SETTLED = adaptive_refresh.DEGRADED_SETTLED_INTERVAL_SECONDS


def test_the_quick_retry_covers_the_first_minutes_and_only_then_widens() -> None:
    steps = [
        (None, QUICK),
        (0.0, QUICK),
        (599.0, QUICK),
        (601.0, 300.0),
        (3599.0, 300.0),
        (3601.0, SETTLED),
        (86_400.0, SETTLED),
    ]
    for degraded_for, expected in steps:
        plan = adaptive_refresh.plan_adaptive_refresh_cadence(
            (_usage_snapshot(state="source_not_found"),),
            observed_at=10_000.0,
            degraded_for_seconds=degraded_for,
        )
        assert plan.interval_seconds == expected, degraded_for
        assert plan.reason is adaptive_refresh.AdaptiveRefreshReason.DEGRADED_SOURCE


def test_a_wider_degraded_interval_never_beats_a_nearer_attention_signal() -> None:
    ambient = adaptive_refresh.plan_adaptive_refresh_cadence(
        (_usage_snapshot(state="source_not_found"),),
        observed_at=10_000.0,
        ambient_usage_visible=True,
        degraded_for_seconds=7200.0,
    )
    assert ambient.interval_seconds == adaptive_refresh.AMBIENT_VISIBLE_CEILING_SECONDS
    assert ambient.reason is adaptive_refresh.AdaptiveRefreshReason.AMBIENT_USAGE

    recent_menu = adaptive_refresh.plan_adaptive_refresh_cadence(
        (_usage_snapshot(state="source_not_found"),),
        observed_at=10_000.0,
        menu_last_opened_at=9_990.0,
        degraded_for_seconds=7200.0,
    )
    assert recent_menu.interval_seconds == 120.0
    assert recent_menu.reason is adaptive_refresh.AdaptiveRefreshReason.RECENT_MENU

    resetting = adaptive_refresh.plan_adaptive_refresh_cadence(
        (_usage_snapshot(state="source_not_found", reset_at=10_120.0),),
        observed_at=10_000.0,
        degraded_for_seconds=7200.0,
    )
    assert resetting.interval_seconds == 120.0
    assert resetting.reason is adaptive_refresh.AdaptiveRefreshReason.RESET_WATCH


def test_the_signature_names_what_is_degraded_and_how() -> None:
    healthy = _usage_snapshot()
    missing = _usage_snapshot(state="source_not_found")
    signed_out = _usage_snapshot(state="needs_sign_in")

    assert adaptive_refresh.degraded_signature((healthy,)) == frozenset()
    assert adaptive_refresh.degraded_signature((healthy, missing)) == adaptive_refresh.degraded_signature((missing,))
    assert adaptive_refresh.degraded_signature((missing,)) != adaptive_refresh.degraded_signature((signed_out,))
    other_reason = replace(missing, reason_code="another_reason")
    assert adaptive_refresh.degraded_signature((missing,)) != adaptive_refresh.degraded_signature((other_reason,))


def _service(tmp_path, clock, snapshot_for_state):
    return ProviderUsageService(
        settings_loader=default_provider_usage_settings,
        credentials=object(),
        home=tmp_path,
        clock=lambda: clock[0],
        collectors={"codex": lambda _preference, _home, now, _credentials: replace(snapshot_for_state[0], observed_at=now)},
    )


def test_a_service_widens_its_schedule_while_a_source_stays_broken_and_starts_over_when_it_changes(tmp_path) -> None:
    clock = [10_000.0]
    snapshot = [_usage_snapshot(state="source_not_found")]
    service = _service(tmp_path, clock, snapshot)

    first = service.refresh_now(providers=("codex",))
    assert first.next_refresh_at == 10_000.0 + QUICK

    clock[0] = 10_000.0 + 400.0
    second = service.refresh_now(providers=("codex",))
    assert second.next_refresh_at == clock[0] + QUICK

    clock[0] = 10_000.0 + 700.0
    third = service.refresh_now(providers=("codex",))
    assert third.next_refresh_at == clock[0] + 300.0

    clock[0] = 10_000.0 + 4000.0
    fourth = service.refresh_now(providers=("codex",))
    assert fourth.next_refresh_at == clock[0] + SETTLED
    assert service.cadence_plan().reason is adaptive_refresh.AdaptiveRefreshReason.DEGRADED_SOURCE

    # The same provider now fails a different way: that is news, so the quick
    # retry comes back.
    snapshot[0] = _usage_snapshot(state="needs_sign_in")
    clock[0] += 60.0
    changed = service.refresh_now(providers=("codex",))
    assert changed.next_refresh_at == clock[0] + QUICK

    # Fixed (the person's fix forces a refresh): the ordinary idle schedule.
    snapshot[0] = _usage_snapshot()
    clock[0] += 60.0
    healthy = service.refresh_now(providers=("codex",), force=True)
    assert healthy.next_refresh_at == clock[0] + adaptive_refresh.IDLE_INTERVAL_SECONDS
    service.close()


def test_opening_the_menu_still_pulls_a_settled_schedule_forward(tmp_path) -> None:
    clock = [10_000.0]
    snapshot = [_usage_snapshot(state="source_not_found")]
    service = _service(tmp_path, clock, snapshot)
    service.refresh_now(providers=("codex",))
    clock[0] = 10_000.0 + 4000.0
    settled = service.refresh_now(providers=("codex",))
    assert settled.next_refresh_at == clock[0] + SETTLED

    service.note_menu_opened(now=clock[0])

    assert service.snapshot().next_refresh_at == clock[0] + 120.0
    service.close()


def test_a_forced_refresh_ignores_the_schedule_so_a_fix_shows_at_once(tmp_path) -> None:
    clock = [10_000.0]
    snapshot = [_usage_snapshot(state="source_not_found")]
    service = _service(tmp_path, clock, snapshot)
    service.refresh_now(providers=("codex",))
    clock[0] = 10_000.0 + 4000.0
    service.refresh_now(providers=("codex",))

    snapshot[0] = _usage_snapshot()
    clock[0] += 5.0
    fixed = service.refresh_now(providers=("codex",), force=True)

    assert fixed.snapshots[0].state is ProviderSourceState.READY
    service.close()


def test_the_slowest_degraded_pace_keeps_the_usage_pace_samples_fresh() -> None:
    from jrbar.core_usage_samples import STALE_SAMPLE_SECONDS

    assert SETTLED < STALE_SAMPLE_SECONDS
