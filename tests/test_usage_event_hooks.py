"""Edge-triggered usage hooks: transitions fire once, states never do."""

from __future__ import annotations

import os
import stat

from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
)
from jrbar.usage_event_hooks import (
    UsageHookLimiter,
    UsageHookResults,
    detect_usage_hook_events,
    dispatch_usage_hooks,
    load_usage_hook_config,
)


def lane(remaining, *, provider="claude", lane_id="weekly"):
    return UsageLane(
        provider_id=provider,
        lane_id=lane_id,
        label=lane_id.title(),
        remaining_percent=remaining,
        reset_at=2_000,
        scope="all",
        model=None,
        feature=None,
        bindable=True,
        source_id=f"{provider}-oauth",
    )


def snapshot(lanes, *, provider="claude", state=ProviderSourceState.READY):
    return ProviderUsageSnapshot(
        provider_id=provider,
        account_label="fixture",
        observed_at=1_000,
        state=state,
        reason_code=None if state is ProviderSourceState.READY else "network_unavailable",
        action_label=None if state is ProviderSourceState.READY else "Retry",
        lanes=tuple(lanes),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
    )


THRESHOLDS = {"claude": 20.0}


def test_quota_low_fires_on_the_downward_crossing_only__and_2_more() -> None:
    # --- scenario: quota_low_fires_on_the_downward_crossing_only
    events = detect_usage_hook_events(
        (snapshot((lane(25.0),)),),
        (snapshot((lane(18.0),)),),
        thresholds=THRESHOLDS,
    )
    # Every move is also a usage_updated (hooks v2); the limiter, not the
    # detector, keeps that one from firing on every refresh.
    assert [event.name for event in events] == ["quota_low", "usage_updated"]
    assert events[0].detail == "18"

    # Sitting under the threshold: no repeat.
    again = detect_usage_hook_events(
        (snapshot((lane(18.0),)),),
        (snapshot((lane(15.0),)),),
        thresholds=THRESHOLDS,
    )
    assert [event.name for event in again] == ["usage_updated"]

    # --- scenario: quota_reached_and_reset_edges
    reached = detect_usage_hook_events(
        (snapshot((lane(3.0),)),),
        (snapshot((lane(0.0),)),),
        thresholds=THRESHOLDS,
    )
    # 3% was already under the 20% threshold -- no second quota_low.
    assert [event.name for event in reached] == ["quota_reached", "usage_updated"]

    # A jump alone is not a reset for a hook: the hook takes the reset the
    # celebrations confirmed (provider_usage_qol.confirm_reset_events).
    jump_only = detect_usage_hook_events(
        (snapshot((lane(2.0),)),),
        (snapshot((lane(100.0),)),),
        thresholds=THRESHOLDS,
    )
    assert [event.name for event in jump_only] == ["usage_updated"]

    from jrbar.provider_usage_qol import ResetEvent

    confirmed = ResetEvent("claude:weekly:abc", "claude", "weekly", "Weekly reset", 1_000.0)
    reset = detect_usage_hook_events(
        (snapshot((lane(2.0),)),),
        (snapshot((lane(100.0),)),),
        thresholds=THRESHOLDS,
        reset_events=(confirmed,),
    )
    assert [event.name for event in reset] == ["usage_updated", "quota_reset"]
    assert reset[1].detail == "100"

    # --- scenario: provider_availability_edges
    down = detect_usage_hook_events(
        (snapshot((lane(50.0),)),),
        (snapshot((lane(50.0),), state=ProviderSourceState.UNAVAILABLE),),
        thresholds={},
    )
    assert [event.name for event in down] == ["provider_unavailable"]

    up = detect_usage_hook_events(
        (snapshot((lane(50.0),), state=ProviderSourceState.UNAVAILABLE),),
        (snapshot((lane(50.0),)),),
        thresholds={},
    )
    assert [event.name for event in up] == ["provider_recovered"]

    # A lane appearing from nowhere is not a crossing.
    fresh = detect_usage_hook_events(
        (), (snapshot((lane(5.0),)),), thresholds=THRESHOLDS
    )
    assert fresh == ()



def _dispatch_legacy(path: str, events):
    """The first version's one hook path, run the way the monitor runs it
    now: migrated to the ``legacy`` rule and dispatched like every rule."""
    return dispatch_usage_hooks(
        load_usage_hook_config(None, legacy_path=path),
        events,
        limiter=UsageHookLimiter(interval=0.0),
        results=UsageHookResults(),
    )


def test_runner_invokes_the_executable_with_event_argv(tmp_path) -> None:
    record = tmp_path / "events.txt"
    script = tmp_path / "hook.sh"
    script.write_text(f'#!/bin/sh\necho "$1 $2 $3 $4" >> "{record}"\n')
    os.chmod(script, stat.S_IRWXU)

    events = detect_usage_hook_events(
        (snapshot((lane(25.0),)),),
        (snapshot((lane(18.0),)),),
        thresholds=THRESHOLDS,
    )
    worker = _dispatch_legacy(str(script), events)
    assert worker is not None
    # Bounded, with room for a loaded machine: the worker starts the hook
    # in its own session and waits for it.
    worker.join(timeout=10.0)
    assert not worker.is_alive()
    assert record.read_text().strip() == "quota_low claude weekly 18"


def test_hook_path_message_expands_home(tmp_path, monkeypatch) -> None:
    from jrbar.usage_event_hooks import hook_path_message

    script = tmp_path / "hook.sh"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert hook_path_message("~/hook.sh") == "Usage event hook saved."
    assert "does not exist" in hook_path_message("~/missing.sh")


def test_a_legacy_path_under_home_still_runs(tmp_path, monkeypatch) -> None:
    """The first version expanded ``~``; a path saved as ``~/hook.sh``
    must not turn into a relative path that never runs."""
    record = tmp_path / "events.txt"
    script = tmp_path / "hook.sh"
    script.write_text(f'#!/bin/sh\necho "$1 $4" >> "{record}"\n')
    os.chmod(script, stat.S_IRWXU)
    monkeypatch.setenv("HOME", str(tmp_path))

    [rule] = load_usage_hook_config(None, legacy_path="~/hook.sh").runnable()
    assert rule.executable == str(script)

    events = detect_usage_hook_events(
        (snapshot((lane(25.0),)),),
        (snapshot((lane(18.0),)),),
        thresholds=THRESHOLDS,
    )
    worker = _dispatch_legacy("~/hook.sh", events)
    assert worker is not None
    # Bounded, with room for a loaded machine.
    worker.join(timeout=10.0)
    assert not worker.is_alive()
    assert record.read_text().strip() == "quota_low 18"
