"""A sub-agent's ask is not an attention episode while worker asks are off."""

from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from jrbar.capacity_types import SourceKey
from jrbar.collector import LiveAgentMonitor
from jrbar.models import HookEvent
from jrbar.operator_history import HistoryEventKind, aggregate_operator_history
from jrbar.operator_state import BootIdentifier, ClockSample, TransitionKind
from jrbar.provider_adapters import minimize_hook_event, provider_facts_for_record
from jrbar.providers import negotiated_provider_sources
from jrbar.settings import AgentMonitorSettings

_BASE = 1_786_536_000.0
_BOOT = BootIdentifier("boot:history")
_CLAUDE = SourceKey("claude", "hooks", "global", "live_agent_events")


def _status_bar():
    try:
        from jrbar import status_bar_legacy
    except SystemExit as exit_:
        pytest.skip(str(exit_))
    return status_bar_legacy


def _snapshot(*asks: tuple[str | None, str]):
    """The canonical snapshot after each (agent_id, request_id) ask opens.

    Every ask is a Claude PermissionRequest in the one session; an ask with an
    agent_id is a sub-agent's, the way the hook payload marks it.
    """
    source = next(
        row for row in negotiated_provider_sources() if row.source_key == _CLAUDE
    )
    monitor = LiveAgentMonitor(
        clock_sampler=lambda: ClockSample(_BASE + 10.0, 110.0, _BOOT),
    )
    for sequence, (agent_id, request_id) in enumerate(asks, start=1):
        ingress = HookEvent(
            provider="claude",
            logged_at=datetime.fromtimestamp(_BASE + sequence, tz=timezone.utc),
            event_name="PermissionRequest",
            raw={
                "request_id": request_id,
                "event_id": f"event:{sequence}",
                "sequence": sequence,
            },
            session_id="session:main",
            agent_id=agent_id,
            tool_name="Bash",
        )
        normalized = minimize_hook_event(
            ingress,
            source_key=source.source_key,
            contract=source.contract,
            observation_authority=source.registration.observation_authority,
        )
        batch = provider_facts_for_record(
            normalized,
            contract=source.contract,
            observation_authority=source.registration.observation_authority,
            observed_at_epoch=_BASE + sequence,
        )
        monitor.ingest_batch(
            batch,
            clock=ClockSample(_BASE + sequence, 100.0 + sequence, _BOOT),
        )
    return monitor.snapshot()


def _observe(snapshot, *, alert: bool):
    """Run the history observer on a snapshot; return (reel, queued rows)."""
    status_bar = _status_bar()
    reel: list[str] = []
    queued: list = []
    controller = SimpleNamespace(
        settings=replace(AgentMonitorSettings(), subagent_asks_alert=alert),
        append_operator_history_reel=lambda phrase, _key: reel.append(phrase),
        _enqueue_operator_history_events=queued.extend,
    )
    status_bar.StatusBarController.observe_operator_history_events(
        controller,
        snapshot.operator_events,
        snapshot.operator_state,
    )
    return reel, queued


def _needs_user(rows) -> int:
    days = aggregate_operator_history(tuple(rows), timezone_offset_at=lambda _epoch: 0)
    return sum(day.needs_user for day in days)


def test_a_workers_ask_adds_no_needs_user_count_while_worker_asks_are_off() -> None:
    snapshot = _snapshot(("agent:worker", "request:worker"))
    opened = [
        event
        for event in snapshot.operator_events
        if event.kind is TransitionKind.REQUEST_OPENED
    ]
    assert len(opened) == 1

    reel, rows = _observe(snapshot, alert=False)

    assert _needs_user(rows) == 0
    assert all(row.kind is not HistoryEventKind.NEEDS_USER for row in rows)
    # The reel still tells the plain story: a request opened.
    assert "Request opened" in reel


def test_a_workers_ask_counts_when_worker_asks_are_on() -> None:
    snapshot = _snapshot(("agent:worker", "request:worker"))

    reel, rows = _observe(snapshot, alert=True)

    assert _needs_user(rows) == 1
    assert "Request opened" in reel


def test_a_main_ask_always_counts() -> None:
    snapshot = _snapshot((None, "request:main"))

    for alert in (False, True):
        reel, rows = _observe(snapshot, alert=alert)
        assert _needs_user(rows) == 1
        assert "Request opened" in reel


def test_only_the_workers_ask_is_left_out_of_a_mixed_tally() -> None:
    snapshot = _snapshot((None, "request:main"), ("agent:worker", "request:worker"))
    opened = [
        event
        for event in snapshot.operator_events
        if event.kind is TransitionKind.REQUEST_OPENED
    ]
    assert len(opened) == 2

    reel, rows = _observe(snapshot, alert=False)
    assert _needs_user(rows) == 1
    assert reel.count("Request opened") == 2

    _reel, rows = _observe(snapshot, alert=True)
    assert _needs_user(rows) == 2
