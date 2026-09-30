"""An OpenCode sub-agent groups under its session and follows the sub-agent rules.

OpenCode's Task tool makes a child session, and every event of that child
arrives with the child's own session id. The plugin now stamps a child's
events with Claude's shape, ``agent_id`` the child and ``session_id`` the root
session, so the existing worker path applies: the child is a sub-agent row
under its session, its asks follow the Sub-agent asks setting, and it never
counts toward keep-awake. These tests take that stamped shape as given (the
plugin's side is checked under bun in test_opencode_bridge_contract.py) and
follow it through the daemon.
"""

from __future__ import annotations

import json
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path

from jrbar import core_power
from jrbar._collector_legacy import LiveAgentMonitor
from jrbar.attention import actionable_request
from jrbar.capacity_types import SourceKey
from jrbar.ipc import ProviderRefreshHint
from jrbar.models import AgentMode, AgentStatus, HookEvent
from jrbar.provider_adapters import (
    InertProviderRecord,
    NormalizedProviderRecord,
    minimize_hook_event,
)
from jrbar.provider_contracts import negotiate_provider_contract
from jrbar.provider_facts import EventToken, ObservationAuthority, WorkLifecycle
from jrbar.settings import AgentMonitorSettings

ROOT = "ses_root0000000000000000000001"
CHILD = "ses_child000000000000000000001"
ASK = "per_test0000000000000000000001"
SOURCE = SourceKey("opencode", "hooks", "global", "live_agent_events")
_EPOCH = 1_800_000_000.0


def _contract():
    return negotiate_provider_contract(
        {
            "schema_version": {"major": 1, "minor": 0},
            "provider_id": "opencode",
            "adapter_id": "hooks",
            "source_instance_id": "global",
            "capabilities": [
                {"id": "live_agent_events", "versions": [{"major": 1, "minor": 0}]},
                {"id": "actionable_requests", "versions": [{"major": 1, "minor": 0}]},
            ],
        }
    )


def _normalize(event_name: str, *, agent_id: str | None) -> NormalizedProviderRecord | InertProviderRecord:
    event = HookEvent(
        provider="opencode",
        logged_at=datetime.fromtimestamp(_EPOCH, UTC),
        event_name=event_name,
        raw={"event_id": "event:1", "request_id": ASK},
        session_id=ROOT,
        agent_id=agent_id,
    )
    return minimize_hook_event(
        event,
        source_key=SOURCE,
        contract=_contract(),
        observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
    )


def test_a_stamped_event_names_the_child_as_a_worker_under_the_root() -> None:
    # --- scenario: an ask and a stop both carry the child as the work and the root as its parent
    for event_name in ("PermissionRequest", "Stop"):
        record = _normalize(event_name, agent_id=CHILD)

        assert type(record) is NormalizedProviderRecord, event_name
        assert record.provider_work_id is not None and record.provider_work_id.value == CHILD
        assert record.parent_work_id is not None and record.parent_work_id.value == ROOT

    # --- scenario: an unstamped event is the session itself, with no parent
    record = _normalize("Stop", agent_id=None)
    assert type(record) is NormalizedProviderRecord
    assert record.provider_work_id is not None and record.provider_work_id.value == ROOT
    assert record.parent_work_id is None


# --- through the monitor: rows, asks and keep-awake ---------------------------


def _ago(seconds: float) -> str:
    moment = datetime.now(UTC) - timedelta(seconds=seconds)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _line(event_name: str, seconds_ago: float, *, child: bool, **extra: object) -> str:
    payload: dict[str, object] = {
        "logged_at": _ago(seconds_ago),
        "hook_event_name": event_name,
        "session_id": ROOT,
        **extra,
    }
    if child:
        payload["agent_id"] = CHILD
    return json.dumps(payload)


def _replay(tmp_path: Path, lines: list[str]) -> LiveAgentMonitor:
    log = tmp_path / "opencode.jsonl"
    monitor = LiveAgentMonitor()
    with log.open("a") as handle:
        for index, line in enumerate(lines):
            handle.write(line + "\n")
            handle.flush()
            monitor.reconcile_refresh_hint(ProviderRefreshHint(SOURCE, EventToken(f"hint:{index}")), log_path=log)
    return monitor


def _rows(monitor: LiveAgentMonitor) -> tuple[AgentStatus, AgentStatus]:
    statuses = {status.agent_id: status for status in monitor.snapshot().statuses}
    assert set(statuses) == {f"opencode:session:{ROOT}", f"opencode:agent:{CHILD}"}, sorted(statuses)
    return statuses[f"opencode:session:{ROOT}"], statuses[f"opencode:agent:{CHILD}"]


def _child_asks(tmp_path: Path) -> LiveAgentMonitor:
    return _replay(
        tmp_path,
        [
            _line("UserPromptSubmit", 9.0, child=False),
            _line("SessionStart", 8.0, child=True),
            _line("UserPromptSubmit", 7.0, child=True),
            _line("PermissionRequest", 6.0, child=True, request_id=ASK),
        ],
    )


def test_the_child_is_a_sub_agent_row_under_its_session(tmp_path: Path) -> None:
    # --- scenario: the child groups under the root and the root stays a main row
    root, child = _rows(_child_asks(tmp_path))

    assert child.is_subagent
    assert child.parent_agent_id == f"opencode:session:{ROOT}"
    assert child.mode is AgentMode.WAITING_FOR_INPUT
    assert not root.is_subagent
    assert root.parent_agent_id is None


def test_the_childs_ask_follows_the_sub_agent_asks_setting(tmp_path: Path) -> None:
    # --- scenario: muted by default, alerting when Sub-agent asks is on
    _root, child = _rows(_child_asks(tmp_path))

    assert actionable_request(child, AgentMonitorSettings()) is False
    assert actionable_request(child, replace(AgentMonitorSettings(), subagent_asks_alert=True)) is True


def test_the_child_never_counts_toward_keep_awake(tmp_path: Path) -> None:
    # --- scenario: only the root session counts as running or waiting
    monitor = _child_asks(tmp_path)
    root, child = _rows(monitor)

    pending, working = core_power.session_facts(monitor.snapshot())

    assert child.agent_id not in pending
    assert pending == frozenset({root.agent_id})
    assert working == 1


def test_the_childs_stop_completes_the_worker_not_the_session(tmp_path: Path) -> None:
    # --- scenario: session.idle for the child ends the child only
    monitor = _replay(
        tmp_path,
        [
            _line("UserPromptSubmit", 9.0, child=False),
            _line("SessionStart", 8.0, child=True),
            _line("UserPromptSubmit", 7.0, child=True),
            _line("Stop", 5.0, child=True),
        ],
    )
    snapshot = monitor.snapshot()
    works = {work.key.work_id.value: work for work in snapshot.operator_state.works}

    child = works[CHILD]
    assert child.lifecycle is WorkLifecycle.COMPLETED
    assert child.parent_key is not None and child.parent_key.work_id.value == ROOT
    root = works[ROOT]
    assert root.lifecycle is WorkLifecycle.ACTIVE
    assert root.parent_key is None
    # A finished worker leaves the rows; the session is still Working.
    (row,) = snapshot.statuses
    assert row.agent_id == f"opencode:session:{ROOT}" and row.mode is AgentMode.WORKING


def test_an_unstamped_child_is_still_a_top_level_row_as_before(tmp_path: Path) -> None:
    # --- scenario: an older plugin, or an evicted child, keeps today's behaviour
    monitor = _replay(
        tmp_path,
        [
            _line("UserPromptSubmit", 9.0, child=False),
            json.dumps(
                {
                    "logged_at": _ago(6.0),
                    "hook_event_name": "PermissionRequest",
                    "session_id": CHILD,
                    "request_id": ASK,
                }
            ),
        ],
    )

    statuses = {status.agent_id: status for status in monitor.snapshot().statuses}

    assert set(statuses) == {f"opencode:session:{ROOT}", f"opencode:session:{CHILD}"}
    assert not any(status.is_subagent for status in statuses.values())
