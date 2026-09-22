"""W09/T36: the audit export is redacted, scoped, and honest about gaps.

The bundle carries the projected rows the surfaces already show — never
raw provider payloads — names its coverage bound, lists what is missing,
and cannot smuggle out a credential through a label or message.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar.activity_ledger import ActivityEntry, ActivityKind, ActivityLedger
from jrbar.audit_export import audit_export_document, audit_export_markdown
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import SourceKey, WorkIdentifier, WorkKey

NOW = 1_800_000_000.0
HOME = "/Users/jonathanreed"


def _status(agent_id: str, *, provider: str = "codex",
            mode: AgentMode = AgentMode.WORKING) -> AgentStatus:
    source = SourceKey(provider, "hooks", "local", "agent_events")
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name=agent_id.rsplit(":", 1)[-1],
        mode=mode,
        updated_at=datetime.fromtimestamp(NOW, tz=timezone.utc) - timedelta(minutes=1),
        event_name="UserPromptSubmit",
        session_id=agent_id.rsplit(":", 1)[-1],
        work_key=WorkKey(source, WorkIdentifier(agent_id.replace(":", "."))),
    )


def _controller(*statuses: AgentStatus, ledger_entries=()):
    ledger = ActivityLedger(entries=tuple(ledger_entries), last_seen_epoch=0.0)
    return SimpleNamespace(
        last_snapshot=SimpleNamespace(
            statuses=statuses, stale_statuses=(), collected_at=datetime.fromtimestamp(NOW, tz=timezone.utc)
        ),
        current_operator_state=None,
        _answer_contracts_by_source=None,
        answer_handler_registry=None,
        _core_state_generation=1,
        _core_extras={},
        _core_ask_statuses=lambda: (),
        _core_snoozed_untils=lambda statuses: {},
        _core_acknowledged_keys=lambda: frozenset(),
        _core_extras_for=lambda status: None,
        ensure_activity_ledger=lambda: ledger,
        _usage_history_service=lambda: (_ for _ in ()).throw(RuntimeError("no service")),
    )


def test_export_redacts_home_paths_and_secret_runs():
    secret = "sk-live-" + "aB3xY9" * 8  # long secret-shaped run
    doc = audit_export_document(
        roster={
            "sessions": [{
                "id": "codex:session:1", "provider": "codex", "kind": "main",
                "label": f"Deploy {secret}", "cwd": f"{HOME}/Code/JR-Bar",
                "message": f"token {secret} rotated",
            }],
            "counts": {"total": 1},
            "coverage": {"source": "collector_snapshot"},
        },
        history_rows=[{
            "at": NOW, "kind": "completion", "provider": "codex",
            "session": "codex:session:1", "label": f"{HOME}/Code/JR-Bar",
            "detail": f"key {secret}",
        }],
        gaps=["test gap"],
        generated_at=NOW,
        core_version="9.9.9",
        home=HOME,
    )
    text = json.dumps(doc)
    assert secret not in text
    assert HOME not in text
    assert "~/Code/JR-Bar" in text
    assert "[redacted]" in text
    assert doc["gaps"] == ["test gap"]
    # Facts survive redaction: ids, axes, counts are not prose.
    assert doc["sessions"][0]["id"] == "codex:session:1"
    assert doc["counts"]["total"] == 1


def test_export_keeps_short_words_and_ordinary_text():
    doc = audit_export_document(
        roster={"sessions": [{
            "id": "s", "provider": "p", "kind": "main",
            "label": "Fix the flap", "message": "rebased onto main",
        }]},
        history_rows=[],
        generated_at=NOW,
        core_version="9.9.9",
        home=HOME,
    )
    assert doc["sessions"][0]["label"] == "Fix the flap"
    assert doc["sessions"][0]["message"] == "rebased onto main"


def test_markdown_names_gaps_and_pricing_coverage():
    doc = audit_export_document(
        roster={"sessions": [], "counts": {"total": 0}},
        history_rows=[],
        pricing={"range": "30d", "providers": {"codex": {"unpriced_records": 3, "unpriced_models": ["mystery-1"]}}},
        gaps=["No collector snapshot yet"],
        generated_at=NOW,
        core_version="9.9.9",
        home=HOME,
    )
    md = audit_export_markdown(doc)
    assert "No collector snapshot yet" in md
    assert "unpriced_records" in md and "mystery-1" in md
    assert "not a compliance" in md


def test_audit_export_command_round_trips_and_validates():
    controller = _controller(_status("codex:session:one"))
    reply = core_runtime._cmd_audit_export(controller, {"scope": "all"})
    doc = reply["document"]
    assert reply["format"] == "json"
    assert doc["t"] == "audit_export" and doc["schema"] == 1
    assert doc["sessions"][0]["id"] == "codex:session:one"
    # The usage service threw: the gap is named, not hidden.
    assert any("usage" in gap.lower() for gap in doc["gaps"])

    md_reply = core_runtime._cmd_audit_export(controller, {"format": "markdown"})
    assert md_reply["format"] == "markdown"
    assert "# JR-Bar audit export" in md_reply["text"]

    with pytest.raises(core_runtime.CommandError) as error:
        core_runtime._cmd_audit_export(controller, {"scope": "everything"})
    assert error.value.code == "invalid_value"


def test_audit_export_scopes_like_the_roster():
    asking = _status("codex:session:asking", mode=AgentMode.WAITING_FOR_INPUT)
    other = _status("codex:session:other")
    controller = _controller(asking, other)
    controller._core_ask_statuses = lambda: (asking,)
    doc = core_runtime._cmd_audit_export(controller, {"scope": "attention"})["document"]
    assert [row["id"] for row in doc["sessions"]] == ["codex:session:asking"]
    # A retention-truncated ledger reports the gap honestly.
    many = ActivityLedger(
        entries=tuple(
            ActivityEntry(
                kind=ActivityKind.COMPLETED,
                occurred_at_epoch=NOW - i,
                label=f"run {i}",
                provider="codex",
            )
            for i in range(5)
        ),
        last_seen_epoch=0.0,
    )
    controller.ensure_activity_ledger = lambda: many
    doc = core_runtime._cmd_audit_export(
        controller, {"scope": "all", "since": NOW - 2}
    )["document"]
    # `since` is inclusive (history_rows keeps at >= since).
    assert len(doc["activity"]) == 3


def test_audit_export_writes_to_a_chosen_path(tmp_path):
    controller = _controller(_status("codex:session:one"))
    target = tmp_path / "audit.json"
    reply = core_runtime._cmd_audit_export(
        controller, {"scope": "all", "path": str(target)}
    )
    assert reply["written"]["path"] == str(target)
    saved = json.loads(target.read_text())
    assert saved["t"] == "audit_export"
    assert saved["sessions"][0]["id"] == "codex:session:one"

    md_target = tmp_path / "audit.md"
    reply = core_runtime._cmd_audit_export(
        controller, {"format": "markdown", "path": str(md_target)}
    )
    assert md_target.read_text().startswith("# JR-Bar audit export")


def test_audit_export_narrows_to_the_rows_on_screen():
    # The Overview's preset, project, search and selection are app-side
    # cuts; the app sends the ids it shows and a name for the view.
    one = _status("codex:session:one")
    two = _status("codex:session:two")
    ledger_entries = (
        ActivityEntry(kind=ActivityKind.COMPLETED, occurred_at_epoch=NOW - 5, label="one done",
                      provider="codex", subject_id="codex:session:one"),
        ActivityEntry(kind=ActivityKind.COMPLETED, occurred_at_epoch=NOW - 4, label="two done",
                      provider="codex", subject_id="codex:session:two"),
    )
    controller = _controller(one, two, ledger_entries=ledger_entries)
    reply = core_runtime._cmd_audit_export(
        controller,
        {"scope": "all", "ids": ["codex:session:two"], "view": "Failed · search auth", "format": "markdown"},
    )
    doc = reply["document"]
    assert [row["id"] for row in doc["sessions"]] == ["codex:session:two"]
    assert [row["session"] for row in doc["activity"]] == ["codex:session:two"]
    assert any(
        "Exported the 1 sessions in Failed · search auth" in gap and "retains 2" in gap
        for gap in doc["gaps"]
    )
    assert "Failed · search auth" in reply["text"]
