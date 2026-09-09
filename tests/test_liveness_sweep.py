from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from sidepulse import process_registry as pr
from sidepulse.liveness_sweep import reap_dead_agents, synthetic_end_payloads
from sidepulse.models import AgentMode, AgentStatus


def _status(provider, agent_id, session_id, mode=AgentMode.WORKING):
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name=agent_id,
        mode=mode,
        updated_at=datetime.now(timezone.utc),
        event_name="PostToolUse",
        session_id=session_id,
    )


def test_synthetic_payloads_end_workers_then_session():
    record = pr.AgentProcessRecord("claude", "sess", 10, 1.0, "claude", "/w", 0.0)
    dead = pr.DeadAgentProcess(record, "process_exited")
    statuses = [
        _status("claude", "claude:session:sess", "sess"),
        _status("claude", "claude:agent:worker-1", "sess"),
        _status("codex", "codex:session:other", "other"),
    ]
    payloads = [json.loads(p) for p in synthetic_end_payloads(dead, statuses, now=5.0)]
    assert [p["hook_event_name"] for p in payloads] == ["SubagentStop", "SessionEnd"]
    assert payloads[0]["agent_id"] == "worker-1"
    assert payloads[1]["session_id"] == "sess"
    assert payloads[1]["reason"] == "jrbar_process_process_exited"
    assert all(p["jrbar_synthetic"] for p in payloads)


def test_reap_only_sweeps_live_rows_and_routes_through_hook_pipeline(tmp_path: Path):
    pr.record_agent_process("codex", "dead", pr.ProcessEntry(301, 1, 6.0, "codex"), state_dir=tmp_path)
    pr.record_agent_process("codex", "done", pr.ProcessEntry(302, 1, 6.0, "codex"), state_dir=tmp_path)
    sweeper = pr.ProcessSweeper(state_dir=tmp_path, table_loader=lambda: {1: pr.ProcessEntry(1, 0, 0.0, "launchd")}, claude_index_loader=dict)
    seen = []

    def fake_process(provider, log_path, payload, *, refresh_hint_handler):
        seen.append((provider, log_path, json.loads(payload), refresh_hint_handler))

    statuses = [
        _status("codex", "codex:session:dead", "dead"),
        _status("codex", "codex:session:done", "done", AgentMode.COMPLETED),
    ]
    handler = object()
    result = reap_dead_agents(
        statuses,
        sweeper=sweeper,
        refresh_hint_handler=handler,
        process_payload=fake_process,
        log_path_for=lambda provider: Path(f"/logs/{provider}.jsonl"),
    )
    assert [d.record.session_id for d in result.ended_sessions] == ["dead"]
    assert result.synthesized_events == 1
    provider, log_path, payload, passed_handler = seen[0]
    assert provider == "codex" and log_path == Path("/logs/codex.jsonl")
    assert payload["hook_event_name"] == "SessionEnd" and payload["session_id"] == "dead"
    assert passed_handler is handler


def test_reap_swallows_pipeline_errors(tmp_path: Path):
    pr.record_agent_process("codex", "dead", pr.ProcessEntry(301, 1, 6.0, "codex"), state_dir=tmp_path)
    sweeper = pr.ProcessSweeper(state_dir=tmp_path, table_loader=lambda: {1: pr.ProcessEntry(1, 0, 0.0, "launchd")}, claude_index_loader=dict)

    def boom(*a, **k):
        raise RuntimeError("no")

    result = reap_dead_agents(
        [_status("codex", "codex:session:dead", "dead")],
        sweeper=sweeper,
        refresh_hint_handler=None,
        process_payload=boom,
        log_path_for=lambda p: Path("/x"),
    )
    assert result.synthesized_events == 0 and len(result.ended_sessions) == 1
