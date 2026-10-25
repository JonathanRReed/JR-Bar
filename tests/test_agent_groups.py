"""Versioned synthetic native formats; no installed provider data is read."""
from __future__ import annotations

import json
import os
import sqlite3
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar.agent_groups import active_agent_groups, resolve_agent_groups
from jrbar.collector import _merged_status_candidates
from jrbar.lineage_adapters import (
    LocalLineageReader,
    claude_parent_links,
    codex_parent_links,
    devin_parent_links,
    factory_parent_links,
    read_devin_links,
    t3_parent_links,
)
from jrbar.models import AgentMode, AgentStatus, ParentLink

NOW = 1_790_000_000.0
FIXTURES = Path(__file__).parent / "fixtures" / "lineage" / "v1"


def fixture(name):
    return json.loads((FIXTURES / f"{name}.json").read_text())


def status(key, *, links=(), mode=AgentMode.WORKING, **kwargs):
    return AgentStatus(key.split(":")[0], key, "Synthetic agent", mode,
                       datetime.fromtimestamp(NOW, timezone.utc), "PermissionRequest" if mode is AgentMode.WAITING_FOR_INPUT else "PreToolUse",
                       parent_links=tuple(links), **kwargs)


def snapshot(rows):
    return SimpleNamespace(statuses=tuple(rows), stale_statuses=(), collected_at=datetime.fromtimestamp(NOW, timezone.utc))


def seven_members():
    t3 = fixture("t3")
    keys, links = t3_parent_links(t3["threads"], t3["bindings"], observed_at=NOW)
    links += claude_parent_links(fixture("claude"), observed_at=NOW)
    links += codex_parent_links(fixture("codex"), observed_at=NOW)
    links += factory_parent_links(fixture("factory"), observed_at=NOW)
    members = set(keys.values()) | {link.child for link in links}
    return tuple(status(key, links=[link for link in links if link.child == key]) for key in sorted(members))


def test_native_binding_conflicts_do_not_pick_a_provider_instance():
    data = fixture("t3")
    data["bindings"].append({**data["bindings"][0], "provider_instance_id": "another-instance"})
    keys, links = t3_parent_links(data["threads"], data["bindings"], observed_at=NOW)
    result = resolve_agent_groups([status(key) for key in keys.values()], links, now=NOW)
    assert {keys[t] for t in ("factory-child", "claude-child", "codex-child")} <= result.unlinked_workers


def test_codex_parent_fields_agree_and_fork_is_never_delegation():
    row = {"type": "session_meta", "payload": {"id": "child", "forked_from_id": "root"}}
    assert codex_parent_links(row, observed_at=NOW) == ()
    row["payload"]["parent_thread_id"] = "root"
    assert codex_parent_links(row, observed_at=NOW)[0].parent == "codex:session:root"
    row["payload"]["source"] = {"subagent": {"thread_spawn": {"parent_thread_id": "different"}}}
    links = codex_parent_links(row, observed_at=NOW)
    assert len(links) == 2
    result = resolve_agent_groups([status("codex:session:root"), status("codex:session:child")], links, now=NOW)
    assert result.unlinked_workers == {"codex:session:child"}


def test_claude_nested_metadata_joins_worker_transitively():
    links = claude_parent_links(fixture("claude-meta"), observed_at=NOW, agent_id="nested")
    rows = [status("claude:session:native-claude"),
            status("claude:agent:native-claude-worker", session_id="native-claude"),
            status("claude:agent:nested", links=links)]
    assert len(resolve_agent_groups(rows, now=NOW).groups[0].members) == 3


def test_devin_native_sidekick_and_unknown_parent_fallback_are_session_scoped():
    native = devin_parent_links(fixture("devin"), observed_at=NOW)
    root = status("devin:session:native-devin")
    child = status("devin:agent:unknown")
    assert len(resolve_agent_groups([root, child], now=NOW).groups[0].members) == 2
    result = resolve_agent_groups([root, child, status("devin:session:other")], now=NOW)
    assert child.agent_id in result.unlinked_workers
    result = resolve_agent_groups([root, child, status("devin:agent:native-sidekick")], native, now=NOW)
    assert len(result.groups[0].members) == 3


def test_merging_native_status_retains_t3_links_without_changing_work_state():
    t3 = status("codex:session:child", links=[ParentLink("codex:session:child", "claude:session:root", "t3code", NOW)])
    hook = replace(t3, parent_links=(), mode=AgentMode.TOOL_RUNNING)
    merged, = _merged_status_candidates([t3, hook])
    assert merged.mode == hook.mode
    assert merged.parent_links == t3.parent_links


def test_restart_recovers_only_metadata_from_synthetic_headers(tmp_path):
    files = [(".codex/sessions/2026/10/25/child.jsonl", "codex"),
             (".factory/sessions/synthetic/child.jsonl", "factory"),
             (".claude/projects/synthetic/session/subagents/agent-nested.meta.json", "claude-meta")]
    for relative, name in files:
        path = tmp_path / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(fixture(name)) + "\n")
        os.utime(path, (NOW, NOW))
    providers = frozenset({"codex", "factory", "claude"})
    first = LocalLineageReader(tmp_path).read(providers, now=NOW)
    restarted = LocalLineageReader(tmp_path).read(providers, now=NOW)
    assert first == restarted
    assert len(first) == 3
    assert all(row.mode is AgentMode.UNKNOWN and row.parent_links for row in first)
    assert LocalLineageReader(tmp_path).read(frozenset(), now=NOW) == ()
    assert LocalLineageReader(tmp_path).read(providers, now=NOW+86_401) == ()


def test_devin_database_is_read_only_and_tolerates_schema_drift(tmp_path):
    database = tmp_path / "sessions.db"
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE subagent_heads(session_id TEXT, agent_id TEXT, chain_node_id TEXT)")
        connection.execute("INSERT INTO subagent_heads VALUES ('root', 'child', 'node')")
    before = database.read_bytes()
    assert read_devin_links(database, observed_at=NOW)[0].parent == "devin:session:root"
    assert database.read_bytes() == before
    with sqlite3.connect(database) as connection:
        connection.execute("ALTER TABLE subagent_heads RENAME TO old_heads")
    assert read_devin_links(database, observed_at=NOW) == ()


def test_live_monitor_keeps_header_lineage_when_canonical_mode_wins():
    from jrbar.collector import LiveAgentMonitor
    from jrbar.operator_state import BootIdentifier, ClockSample
    from tests.test_attention import _canonical_permission_request_snapshot

    canonical = _canonical_permission_request_snapshot(session_id="root", agent_id=None)
    direct = canonical.statuses[0]
    epoch = canonical.collected_at.timestamp()
    clock = ClockSample(epoch, 1.0, BootIdentifier("synthetic-boot"))
    monitor = LiveAgentMonitor(clock_sampler=lambda: clock)
    monitor.operator_state = canonical.operator_state
    link = ParentLink(direct.agent_id, "codex:session:parent", "t3code", epoch)
    header = replace(direct, mode=AgentMode.UNKNOWN, event_name="LineageObserved", parent_links=(link,))
    parent = replace(status("codex:session:parent"), updated_at=canonical.collected_at)
    monitor.replace_external_statuses("lineage", (header, parent))
    current = monitor.snapshot()
    merged = next(row for row in current.statuses if row.agent_id == direct.agent_id)
    assert merged.mode == direct.mode
    assert merged.parent_links == (link,)
    assert len(resolve_agent_groups((*current.statuses, *current.stale_statuses), now=epoch).groups) == 1


def test_t3_subagents_table_supplies_lineage_without_thread_payload():
    data = fixture("t3")
    data["threads"][1]["payload_json"] = {}
    keys, links = t3_parent_links(data["threads"], data["bindings"], observed_at=NOW,
                                 subagents=[{"thread_id": "root", "child_thread_id": "factory-child"}])
    result = resolve_agent_groups([status(key) for key in keys.values()], links, now=NOW)
    assert len(result.groups) == 1
    assert len(result.groups[0].members) == 4


def test_inactive_native_t3_subagent_is_not_resurrected():
    data = fixture("t3")
    _, links = t3_parent_links(data["threads"], data["bindings"], observed_at=NOW,
                              subagents=[{"thread_id": "root", "child_thread_id": None, "status": "completed",
                                          "native_task_ref": {"driver": "codex", "nativeId": "old-worker"}}])
    assert not any(link.child.endswith("old-worker") for link in links)


@pytest.mark.parametrize("parser,payload", [
    (codex_parent_links, {"type": "session_meta", "payload": {"id": "child", "parent_thread_id": {"unexpected": "shape"}}}),
    (factory_parent_links, {"id": "child", "callingSessionId": ["unexpected"]}),
    (claude_parent_links, {"agent_id": "child", "session_id": {"unexpected": "shape"}}),
])
def test_malformed_parent_fields_mark_worker_unlinked(parser, payload):
    links = parser(payload, observed_at=NOW)
    assert len(links) == 1 and links[0].parent is None


def test_retained_native_ask_keeps_its_parent_without_renewing_external_evidence():
    root = status("claude:session:root")
    worker = replace(status("claude:agent:worker", session_id="root", mode=AgentMode.WAITING_FOR_INPUT),
                     updated_at=datetime.fromtimestamp(NOW-86_401, timezone.utc))
    group, = resolve_agent_groups([root, worker], now=NOW).groups
    assert worker.agent_id in group.members
    assert group.lineage_evidence[0].observed_at == NOW-86_401
    stale_external = ParentLink(worker.agent_id, root.agent_id, "t3code", NOW-86_401)
    assert resolve_agent_groups([root, replace(worker, parent_links=(stale_external,))], now=NOW).unlinked_workers == {worker.agent_id}


def test_factory_headers_supply_a_root_without_inventing_activity(tmp_path):
    root = tmp_path / ".factory/sessions/synthetic"
    root.mkdir(parents=True)
    for name, payload in [("root", {"id": "native-factory", "type": "session_start"}),
                          ("child", fixture("factory"))]:
        path = root / f"{name}.jsonl"
        path.write_text(json.dumps(payload) + "\n")
        os.utime(path, (NOW, NOW))
    rows = LocalLineageReader(tmp_path).read(frozenset({"factory"}), now=NOW)
    group, = resolve_agent_groups(rows, now=NOW).groups
    assert group.members == ("factory:session:native-factory", "factory:session:native-factory-worker")
    assert active_agent_groups(snapshot(rows)) == ()


def test_native_hook_groups_recover_from_the_daemon_latest_state(tmp_path):
    from jrbar.collector import LiveAgentMonitor
    from jrbar.models import HookEvent
    from jrbar.operator_state import BootIdentifier, ClockSample

    clock = ClockSample(NOW, 1.0, BootIdentifier("synthetic-boot"))
    path = tmp_path / "latest.json"
    monitor = LiveAgentMonitor(latest_state_path=path, clock_sampler=lambda: clock)
    for event, worker, sequence in [("SessionStart", None, 1), ("SubagentStart", "worker", 2)]:
        monitor.ingest_record(HookEvent(
            provider="claude", logged_at=datetime.fromtimestamp(NOW, timezone.utc),
            event_name=event, raw={"event_id": f"synthetic-{sequence}", "sequence": sequence},
            session_id="root", agent_id=worker,
        ))
    before = monitor.snapshot()
    monitor.write_latest_state()
    restarted = LiveAgentMonitor(latest_state_path=path, clock_sampler=lambda: clock)
    after = restarted.snapshot()
    first = resolve_agent_groups((*before.statuses, *before.stale_statuses), now=NOW)
    restored = resolve_agent_groups((*after.statuses, *after.stale_statuses), now=NOW)
    assert len(first.groups) == len(restored.groups) == 1
    assert restored.groups[0].members == first.groups[0].members == ("claude:agent:worker", "claude:session:root")


def test_unlinked_harness_is_logged_once_per_failure(caplog):
    import logging

    from jrbar.collector import LiveAgentMonitor
    from jrbar.operator_state import BootIdentifier, ClockSample

    monitor = LiveAgentMonitor(clock_sampler=lambda: ClockSample(NOW, 1.0, BootIdentifier("synthetic-boot")))
    monitor.replace_external_statuses("synthetic", [status("claude:agent:orphan")])
    with caplog.at_level(logging.INFO):
        monitor.snapshot()
        monitor.snapshot()
    assert [record.message for record in caplog.records if "unlinked worker" in record.message] == [
        "unlinked worker: harness=claude reason=missing_parent",
    ]


def test_no_active_provider_starts_no_lineage_job(monkeypatch):
    import jrbar.lineage_adapters as module

    def unexpected(*args, **kwargs):
        pytest.fail("No active provider may start a lineage reader")
    monkeypatch.setattr(module.threading, "Thread", unexpected)
    assert LocalLineageReader(Path("/synthetic/home")).request(frozenset()) == ()


def test_old_devin_head_is_not_renewed_by_rereading_the_database(tmp_path):
    database = tmp_path / "sessions.db"
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE subagent_heads(session_id TEXT, agent_id TEXT, updated_at REAL)")
        connection.execute("INSERT INTO subagent_heads VALUES ('root', 'child', ?)", (NOW-86_401,))
    links = read_devin_links(database, observed_at=NOW)
    assert links[0].observed_at == NOW-86_401
    rows = [status("devin:session:root"), status("devin:agent:child")]
    assert resolve_agent_groups(rows, links, now=NOW).unlinked_workers == {"devin:agent:child"}


def test_devin_title_aliases_never_cross_sessions():
    from jrbar.models import HookEvent
    from jrbar.provider_adapters import _devin_subagent_agent_id

    ids = []
    rows = []
    for session in ("first", "second"):
        event = HookEvent("devin", datetime.fromtimestamp(NOW, timezone.utc), "PreToolUse",
                          {"tool_name": "run_subagent", "tool_input": {"title": "Same synthetic title"}},
                          session_id=session, tool_name="run_subagent")
        native = _devin_subagent_agent_id(event)
        ids.append(native)
        rows.extend([status(f"devin:session:{session}"), status(f"devin:agent:{native}", session_id=session)])
    assert ids[0] != ids[1]
    result = resolve_agent_groups(rows, now=NOW)
    assert len(result.groups) == 2 and all(len(group.members) == 2 for group in result.groups)
