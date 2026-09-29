"""Grok's StopCancelled ends a turn that did not finish, so the row goes idle.

Grok runs StopCancelled INSTEAD of Stop when a turn ends without completing:
the person presses Ctrl+C, a permission prompt is declined, the turn hits its
turn limit, or Grok gives up making progress (the hooks guide in grok
1.0.41). JR-Bar never registered it, so a cancelled turn left the row Working
(and holding keep-awake) until the next prompt or the process exited. The
meaning is the same as a Codex Interrupt: the session stays open, idle,
waiting for the person.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from jrbar._collector_legacy import LiveAgentMonitor
from jrbar.hook import _normalized_hook_record, routed_hook_payload
from jrbar.install import install_grok_hooks
from jrbar.ipc import ProviderRefreshHint
from jrbar.models import AgentMode
from jrbar.provider_adapters import (
    InertProviderRecord,
    NormalizedProviderRecord,
    ProviderEventName,
    minimize_hook_event,
    normalized_provider_record_to_payload,
    provider_facts_for_record,
)
from jrbar.provider_facts import EventToken, SourceKey, WorkLifecycle
from jrbar.providers import GROK_EVENTS, detect_grok_config, parse_log_line

SOURCE = SourceKey("grok", "hooks", "global", "live_agent_events")
SESSION = "grok-session-01"


def _cancelled(**extra: object) -> dict[str, object]:
    return {
        "hook_event_name": "StopCancelled",
        "sessionId": SESSION,
        "cwd": "/tmp/work",
        "reason": "user_interrupt",
        "cancelledBy": "user",
        **extra,
    }


def _records(payload: dict[str, object]):
    """The normalized record the hook writes, and the parsed event a replay reads."""
    text = json.dumps(payload)
    actual, _, line = routed_hook_payload("grok", Path("/tmp/grok.jsonl"), text)
    return _normalized_hook_record(actual, line), parse_log_line(actual, json.dumps(line))


def _batch(record: NormalizedProviderRecord | InertProviderRecord):
    from jrbar._collector_legacy import _registered_hook_source

    source = _registered_hook_source("grok")
    assert source is not None
    return provider_facts_for_record(
        record,
        contract=source.contract,
        observation_authority=source.registration.observation_authority,
        observed_at_epoch=1_800_000_000.0,
    )


def test_stop_cancelled_is_registered_without_a_matcher__and_2_more(tmp_path: Path) -> None:
    # --- scenario: the installer writes the hook and a second install changes nothing
    assert "StopCancelled" in GROK_EVENTS
    config = tmp_path / "hooks" / "jrbar.json"
    log = tmp_path / "grok.jsonl"

    first = install_grok_hooks(log_path=log, config_path=config, python_executable="python3")

    assert first.changed
    data = json.loads(config.read_text())
    entry = data["hooks"]["StopCancelled"][-1]
    assert "matcher" not in entry
    assert any("--provider grok" in hook["command"] for hook in entry["hooks"])
    assert not install_grok_hooks(log_path=log, config_path=config, python_executable="python3").changed

    # --- scenario: the detector lists it among the installed events
    home = tmp_path / "home"
    (home / ".grok" / "hooks").mkdir(parents=True)
    installed = home / ".grok" / "hooks" / "jrbar.json"
    install_grok_hooks(log_path=log, config_path=installed, python_executable="python3")
    detected = detect_grok_config(home)
    assert detected.hooks_enabled
    assert "StopCancelled" in detected.hook_events

    # --- scenario: StopCancelled sits with the other turn ends, before SessionEnd
    assert GROK_EVENTS.index("StopFailure") < GROK_EVENTS.index("StopCancelled")
    assert GROK_EVENTS.index("StopCancelled") < GROK_EVENTS.index("SessionEnd")


def test_stop_cancelled_parses_in_both_payload_spellings() -> None:
    # --- scenario: the snake_case hook name and the camelCase key both resolve
    event = parse_log_line("grok", json.dumps(_cancelled()))
    assert event is not None and event.event_name == "StopCancelled"
    assert event.provider == "grok" and event.session_id == SESSION

    camel = parse_log_line(
        "grok",
        json.dumps({"hookEventName": "stop_cancelled", "sessionId": SESSION, "reason": "max_turns"}),
    )
    assert camel is not None and camel.event_name == "StopCancelled"


@pytest.mark.parametrize(
    "reason",
    ["user_interrupt", "permission_rejected", "permission_cancelled", "max_turns", "no_progress", "unknown"],
)
def test_every_stop_cancelled_reason_returns_the_work_to_idle(reason: str) -> None:
    # --- scenario: the reason is a vendor detail, so every reason means the same idle
    normalized, event = _records(_cancelled(reason=reason))

    assert type(normalized) is NormalizedProviderRecord
    assert normalized.event_name is ProviderEventName.INTERRUPT
    assert event is not None
    (work,) = _batch(normalized).work_facts
    assert work.lifecycle is WorkLifecycle.IDLE


def test_a_replayed_stop_cancelled_record_reduces_again() -> None:
    # --- scenario: the persisted record spells the event "interrupt", so the table must too
    normalized, _ = _records(_cancelled())
    assert type(normalized) is NormalizedProviderRecord
    payload = normalized_provider_record_to_payload(normalized)

    replayed = parse_log_line("grok", json.dumps(payload))

    assert replayed is not None
    assert replayed.event_name == "Interrupt"
    from jrbar._collector_legacy import _registered_hook_source

    source = _registered_hook_source("grok")
    assert source is not None
    again = minimize_hook_event(
        replayed,
        source_key=source.source_key,
        contract=source.contract,
        observation_authority=source.registration.observation_authority,
    )
    assert type(again) is NormalizedProviderRecord
    (work,) = _batch(again).work_facts
    assert work.lifecycle is WorkLifecycle.IDLE


def test_a_subagents_cancel_is_not_the_sessions_stop() -> None:
    # --- scenario: a subagent's own cancel is dropped at ingress, never marked inert
    for key in ("subagentType", "subagent_type"):
        payload = _cancelled(**{key: "explore"})
        normalized, event = _records(payload)

        assert event is None, key
        assert normalized is None, key

    # An empty marker is not a subagent, and the session's own cancel still counts.
    normalized, event = _records(_cancelled(subagentType=""))
    assert type(normalized) is NormalizedProviderRecord
    assert event is not None


# --- the reducer: what the row shows after each ordering ---------------------


def _ago(seconds: float) -> str:
    moment = datetime.now(timezone.utc) - timedelta(seconds=seconds)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _line(event_name: str, seconds_ago: float, **extra: object) -> str:
    return json.dumps(
        {
            "logged_at": _ago(seconds_ago),
            "hook_event_name": event_name,
            "session_id": SESSION,
            "cwd": "/tmp/work",
            **extra,
        }
    )


def _replay(tmp_path: Path, lines: list[str]) -> LiveAgentMonitor:
    log = tmp_path / "grok.jsonl"
    monitor = LiveAgentMonitor()
    with log.open("a") as handle:
        for index, line in enumerate(lines):
            handle.write(line + "\n")
            handle.flush()
            monitor.reconcile_refresh_hint(ProviderRefreshHint(SOURCE, EventToken(f"hint:{index}")), log_path=log)
    return monitor


def _mode(monitor: LiveAgentMonitor) -> AgentMode:
    statuses = [status for status in monitor.snapshot().statuses if status.session_id == SESSION]
    assert len(statuses) == 1
    return statuses[0].mode


def test_a_cancelled_turn_leaves_a_working_row_idle(tmp_path: Path) -> None:
    # --- scenario: Ctrl+C mid-turn returns the row to idle
    monitor = _replay(
        tmp_path,
        [
            _line("SessionStart", 9.0),
            _line("UserPromptSubmit", 8.0),
            _line("PreToolUse", 7.0, tool_name="run_terminal_command"),
            _line("StopCancelled", 5.0, reason="user_interrupt", cancelledBy="user"),
        ],
    )
    assert _mode(monitor) is AgentMode.IDLE_READY


def test_a_declined_permission_prompt_leaves_a_waiting_row_idle(tmp_path: Path) -> None:
    # --- scenario: a decline that sends only StopCancelled clears the ask
    monitor = _replay(
        tmp_path,
        [
            _line("SessionStart", 9.0),
            _line("UserPromptSubmit", 8.0),
            _line("Notification", 7.0, notification_type="permission_prompt"),
            _line("StopCancelled", 5.0, reason="permission_rejected", cancelledBy="user"),
        ],
    )
    assert _mode(monitor) is AgentMode.IDLE_READY


def test_a_cancel_wins_a_same_stamp_tie_with_stop_but_not_with_session_end(tmp_path: Path) -> None:
    # --- scenario: Stop then StopCancelled on one stamp reads idle (rank 83 over 81)
    stamp = 5.0
    monitor = _replay(
        tmp_path,
        [
            _line("SessionStart", 9.0),
            _line("UserPromptSubmit", 8.0),
            _line("Stop", stamp),
            _line("StopCancelled", stamp),
        ],
    )
    assert _mode(monitor) is AgentMode.IDLE_READY

    # --- scenario: StopCancelled then SessionEnd on one stamp ends the session
    other = tmp_path / "second"
    other.mkdir()
    monitor = _replay(
        other,
        [
            _line("SessionStart", 9.0),
            _line("UserPromptSubmit", 8.0),
            _line("StopCancelled", stamp),
            _line("SessionEnd", stamp),
        ],
    )
    assert _mode(monitor) is AgentMode.COMPLETED


def test_the_next_prompt_after_a_cancel_works_again(tmp_path: Path) -> None:
    # --- scenario: a cancelled turn does not stop the next one showing Working
    monitor = _replay(
        tmp_path,
        [
            _line("SessionStart", 9.0),
            _line("UserPromptSubmit", 8.0),
            _line("StopCancelled", 6.0),
            _line("UserPromptSubmit", 4.0),
        ],
    )
    assert _mode(monitor) is AgentMode.WORKING
