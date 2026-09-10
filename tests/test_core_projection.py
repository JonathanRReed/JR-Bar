"""The pure ``state`` / ``lights`` / ``settings`` / history projections.

The last test pins the Swift app's fixture
(``app/Tests/JRBarCoreTests/Fixtures/python-state.json``): the document the
Python projection produces from these fixtures must be byte-for-byte what
the Swift Codable models are tested against. Regenerate with
``JRBAR_UPDATE_FIXTURES=1``.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

from jrbar.core_projection import (
    DeviceFacts,
    EscalationFacts,
    PowerFacts,
    SessionExtras,
    SurfaceFacts,
    aggregate_mode,
    build_lights_document,
    build_settings_document,
    build_state_document,
    history_rows,
    hook_health,
    lifecycle_for_mode,
    origin_document,
    strip_session_short_id,
    terminal_from_command,
    why_for_glance,
)
from jrbar.models import AgentMode, AgentStatus

ROOT = Path(__file__).resolve().parents[1]
SWIFT_FIXTURE = ROOT / "app" / "Tests" / "JRBarCoreTests" / "Fixtures" / "python-state.json"
NOW = 1788982892.4
CLAUDE_SID = "fca1eb06-f6d1-413e-aa5f-dd19d8e05973"
CLAUDE_ID = f"claude:session:{CLAUDE_SID}"
CLAUDE_WORKER_ID = f"claude:agent:{CLAUDE_SID}-worker-1"
CODEX_ID = "codex:session:0f3b2c9a-71d4-4e0e-9a8e-2c1d5f6a7b8c"
GEMINI_ID = "gemini:session:8a1c2e3f-5b6d-4c7e-9f0a-1b2c3d4e5f6a"


def _at(offset: float) -> datetime:
    return datetime.fromtimestamp(NOW - offset, tz=timezone.utc)


def _status(**overrides) -> AgentStatus:
    fields = dict(
        provider="claude",
        agent_id=CLAUDE_ID,
        display_name=f"jr-bar-b7 ({CLAUDE_SID[:8]})",
        mode=AgentMode.TOOL_RUNNING,
        updated_at=_at(1.4),
        event_name="PreToolUse",
        session_id=CLAUDE_SID,
        cwd="/Users/j/Downloads/JR-Bar",
        tool_name="Bash",
        origin="Claude App",
        work_key="wk-claude",
    )
    fields.update(overrides)
    return AgentStatus(**fields)


def fixture_inputs() -> dict:
    claude = _status()
    worker = _status(
        agent_id=CLAUDE_WORKER_ID,
        display_name="worker",
        mode=AgentMode.WORKING,
        updated_at=_at(2.0),
        tool_name=None,
        work_key="wk-claude-worker",
    )
    codex = _status(
        provider="codex",
        agent_id=CODEX_ID,
        display_name="sidepulse-core",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=_at(92.4),
        event_name="PermissionRequest",
        session_id="0f3b2c9a-71d4-4e0e-9a8e-2c1d5f6a7b8c",
        cwd="/Users/j/Downloads/JR-Bar/src",
        tool_name="Bash",
        message="Run: rm -rf build",
        origin="Codex CLI",
        work_key="wk-codex",
    )
    gemini = _status(
        provider="gemini",
        agent_id=GEMINI_ID,
        display_name="docs-sweep",
        mode=AgentMode.COMPLETED,
        updated_at=_at(41.0),
        event_name="Stop",
        session_id="8a1c2e3f-5b6d-4c7e-9f0a-1b2c3d4e5f6a",
        cwd="/Users/j/Projects/notes",
        tool_name=None,
        origin=None,
        stale=True,
        work_key="wk-gemini",
    )
    snapshot = SimpleNamespace(
        aggregate=SimpleNamespace(mode=AgentMode.WAITING_FOR_INPUT),
        statuses=(claude, worker, codex),
        stale_statuses=(gemini,),
        collected_at=datetime.fromtimestamp(NOW, tz=timezone.utc),
    )
    operator_state = SimpleNamespace(
        generation=41,
        requests=(
            SimpleNamespace(
                key=SimpleNamespace(work_key="wk-codex"),
                phase=SimpleNamespace(value="live_unacknowledged"),
                request_kind=SimpleNamespace(value="permission"),
                opened_at_epoch=1788982800.0,
            ),
        ),
        works=(
            SimpleNamespace(key="wk-claude", next_actor=SimpleNamespace(value="provider")),
            SimpleNamespace(key="wk-codex", next_actor=SimpleNamespace(value="user")),
            SimpleNamespace(key="wk-gemini", next_actor=SimpleNamespace(value="user")),
        ),
    )
    usage_state = SimpleNamespace(
        refreshed_at=NOW - 42.4,
        next_refresh_at=NOW + 257.6,
        refreshing=False,
        snapshots=(
            SimpleNamespace(
                provider_id="claude",
                source_instance_id="default",
                account_label="Max",
                state=SimpleNamespace(value="ready"),
                reason_code=None,
                action_label=None,
                observed_at=NOW - 42.4,
                input_tokens=1200,
                cached_input_tokens=800,
                output_tokens=300,
                estimated_cost_usd=None,
                credits_remaining=None,
                lanes=(
                    SimpleNamespace(lane_id="five_hour", label="5h", remaining_percent=58.0, reset_at=NOW + 8040.0, scope="account", model=None),
                    SimpleNamespace(lane_id="seven_day", label="7d", remaining_percent=39.0, reset_at=NOW + 277200.0, scope="account", model=None),
                ),
            ),
            SimpleNamespace(
                provider_id="codex",
                source_instance_id="default",
                account_label=None,
                state=SimpleNamespace(value="stale"),
                reason_code="rate_limited",
                action_label="Retry later",
                observed_at=NOW - 900.0,
                input_tokens=0,
                cached_input_tokens=0,
                output_tokens=0,
                estimated_cost_usd=None,
                credits_remaining=None,
                lanes=(
                    SimpleNamespace(lane_id="five_hour", label="5h", remaining_percent=88.0, reset_at=None, scope="account", model=None),
                ),
            ),
        ),
    )
    dnd = SimpleNamespace(
        contributions=(
            SimpleNamespace(mode=SimpleNamespace(value="dim"), source=SimpleNamespace(value="schedule")),
        ),
        active_sources=(SimpleNamespace(value="schedule"),),
        next_transition_epoch=NOW + 3600.0,
        display_admission=SimpleNamespace(value="all"),
        brightness_factor=0.15,
        banner_allowed=True,
        audible_allowed=False,
        summary="Dim until 07:00",
    )
    intake = SimpleNamespace(
        providers=(
            SimpleNamespace(provider="claude", installed=True, stuck=False, delivering=True, heard_age_seconds=1.4),
            SimpleNamespace(provider="codex", installed=True, stuck=True, delivering=False, heard_age_seconds=900.0),
            SimpleNamespace(provider="pi", installed=False, stuck=False, delivering=False, heard_age_seconds=None),
        ),
        hook_state=SimpleNamespace(code=SimpleNamespace(value="configured")),
        source_health=SimpleNamespace(code=SimpleNamespace(value="partial")),
        silence_seconds=1.4,
    )
    devices = (
        DeviceFacts(id="sidepulse:pro:B293A1", kind="pro", name="SidePulse", path="/Volumes/SidePulse", leds=8, connected=True, brightness=79, linked=True, last_write=NOW - 1.09, error=None),
        DeviceFacts(id="sidepulse:dot:7F02C4", kind="dot", name="PulseDot", path="/Volumes/PulseDot", leds=2, connected=False, brightness=60, linked=True, error="volume unmounted"),
        DeviceFacts(id="screen-bar", kind="screen_bar", name="Screen Bar", leds=8, enabled=True, brightness=100, linked=True),
    )
    extras = {
        CLAUDE_ID: SessionExtras(
            pid=9170,
            origin=origin_document("Claude App", "claude_app"),
            terminal={"app": "Ghostty", "bundle_id": "com.mitchellh.ghostty", "tty": "/dev/ttys004"},
        ),
        CODEX_ID: SessionExtras(pid=9311, origin=None, terminal={"app": "Terminal", "bundle_id": "com.apple.Terminal"}),
    }
    return dict(
        now=NOW,
        generation=4812,
        snapshot=snapshot,
        ask_statuses=[codex],
        unseen_completion_ids=frozenset({GEMINI_ID}),
        operator_state=operator_state,
        devices=devices,
        usage_state=usage_state,
        power=PowerFacts(keep_awake=True, closed_lid_policy="agents", closed_lid_holding=False, helper_installed=True),
        dnd_projection=dnd,
        escalation=EscalationFacts(stage=2, since=1788982800.0),
        intake_report=intake,
        settings_generation=17,
        extras_by_id=extras,
    )


def test_state_document_projects_sessions_asks_and_aggregate() -> None:
    document = build_state_document(**fixture_inputs())
    assert document["t"] == "state" and document["v"] == 1
    assert document["generation"] == 4812 and document["now"] == NOW
    sessions = {session["id"]: session for session in document["sessions"]}
    assert set(sessions) == {CLAUDE_ID, CLAUDE_WORKER_ID, CODEX_ID, GEMINI_ID}

    claude = sessions[CLAUDE_ID]
    assert claude["kind"] == "main" and claude["parent"] is None
    assert claude["label"] == "jr-bar-b7"
    assert claude["mode"] == "tool_running" and claude["lifecycle"] == "active"
    assert claude["next_actor"] == "provider"
    assert claude["pid"] == 9170
    assert claude["origin"] == {"kind": "claude_app", "label": "Claude App", "bundle_id": "com.anthropic.claudefordesktop"}
    assert claude["terminal"]["tty"] == "/dev/ttys004"
    assert claude["workers"] == 1
    assert claude["ask"] is None

    worker = sessions[CLAUDE_WORKER_ID]
    assert worker["kind"] == "worker" and worker["parent"] == CLAUDE_ID

    codex = sessions[CODEX_ID]
    assert codex["ask"] == {"kind": "permission", "opened_at": 1788982800.0, "summary": "Run: rm -rf build"}
    assert codex["next_actor"] == "user"
    # The origin comes from the hook annotation when the registry has none.
    assert codex["origin"]["label"] == "Codex CLI" and codex["origin"]["kind"] == "codex_cli"

    gemini = sessions[GEMINI_ID]
    assert gemini["stale"] is True and gemini["lifecycle"] == "completed"

    assert document["asks"] == [
        {"session": CODEX_ID, "kind": "permission", "opened_at": 1788982800.0, "summary": "Run: rm -rf build"}
    ]
    assert document["aggregate"] == {
        "mode": "needs_you", "needs_you": 1, "active": 1, "ready": 1, "failed": 0, "total": 3,
    }
    assert document["unseen_completions"] == [GEMINI_ID]


def test_state_document_projects_devices_usage_power_focus_and_health() -> None:
    document = build_state_document(**fixture_inputs())
    devices = {device["id"]: device for device in document["devices"]}
    assert devices["sidepulse:pro:B293A1"]["brightness"] == 79
    assert devices["sidepulse:pro:B293A1"]["connected"] is True
    assert devices["sidepulse:dot:7F02C4"]["error"] == "volume unmounted"
    assert devices["screen-bar"] == {
        "id": "screen-bar", "kind": "screen_bar", "name": "Screen Bar", "leds": 8, "enabled": True,
        "brightness": 100, "linked": True, "error": None,
    }
    usage = document["usage"]
    assert usage["refreshed_at"] == NOW - 42.4
    claude, codex = usage["providers"]
    assert claude["id"] == "claude" and claude["fidelity"] == "official"
    assert [window["name"] for window in claude["windows"]] == ["5h", "7d"]
    assert claude["windows"][0]["used_pct"] == 42.0
    assert claude["windows"][1]["resets_at"] == NOW + 277200.0
    assert codex["fidelity"] == "stale" and codex["state"] == "stale"
    assert codex["windows"][0]["resets_at"] is None
    assert document["power"] == {
        "keep_awake": True,
        "closed_lid": {"policy": "agents", "holding": False, "helper_installed": True},
    }
    assert document["focus"]["mode"] == "dim" and document["focus"]["source"] == "schedule"
    assert document["focus"]["until"] == NOW + 3600.0
    assert document["escalation"] == {"stage": "menu_bar", "since": 1788982800.0}
    assert document["health"]["hooks"] == {"claude": "ok", "codex": "stale", "pi": "missing"}
    assert document["health"]["sources"]["codex"]["fresh"] is False
    assert document["health"]["intake"]["source_health"] == "partial"
    assert document["settings_generation"] == 17
    json.dumps(document)


def test_state_document_tolerates_an_empty_world() -> None:
    document = build_state_document(
        now=NOW, generation=1, snapshot=None, ask_statuses=[], unseen_completion_ids=frozenset()
    )
    assert document["sessions"] == [] and document["asks"] == []
    assert document["aggregate"]["mode"] == "idle"
    assert document["usage"] is None
    assert document["health"]["hooks"] == {}
    assert document["escalation"] == {"stage": "none", "since": None}
    json.dumps(document)


def test_lights_and_settings_documents() -> None:
    lights = build_lights_document(
        {
            "hardware": SurfaceFacts("off 160ms cosine\n#FF3A00 1.6s pulse\nrepeat", 8, NOW - 1.09, "continuous", "#FF3A00", 0.79, "needs_you"),
            "screen_bar": SurfaceFacts("off 160ms cosine\n#FF3A00 1.6s pulse\nrepeat", 8, NOW - 1.09, "continuous", "#FF3A00", 1.0, "needs_you", "dnd"),
            "dot": SurfaceFacts("#FF3A00 1.6s pulse\nrepeat", 2),
        },
        linked=True,
    )
    assert lights["t"] == "lights" and lights["linked"] is True
    assert lights["surfaces"]["hardware"]["anchor"] == NOW - 1.09
    assert lights["surfaces"]["screen_bar"]["override"] == "dnd"
    assert lights["surfaces"]["dot"] == {"program": "#FF3A00 1.6s pulse\nrepeat", "led_count": 2}
    settings = build_settings_document({"alert_burst": 3, "devices": []}, generation=17)
    assert settings == {"t": "settings", "v": 1, "generation": 17, "schema": 3, "document": {"alert_burst": 3, "devices": []}}


def test_history_rows_from_the_activity_ledger() -> None:
    ledger = SimpleNamespace(
        last_seen_epoch=NOW - 1000.0,
        entries=(
            SimpleNamespace(kind=SimpleNamespace(value="completed"), occurred_at_epoch=NOW - 5.0, label="jr-bar-b7", provider="claude", subject_id=CLAUDE_ID, detail=None),
            SimpleNamespace(kind=SimpleNamespace(value="blocked"), occurred_at_epoch=NOW - 2000.0, label="docs-sweep", provider="gemini", subject_id=GEMINI_ID, detail="rate limited"),
            SimpleNamespace(kind=SimpleNamespace(value="threshold_crossed"), occurred_at_epoch=NOW - 3000.0, label="Claude 5h at 90%", provider="claude", subject_id=None, detail="90%"),
        ),
    )
    rows = history_rows(ledger)
    assert [row["kind"] for row in rows] == ["completed", "failed", "quota_crossed"]
    assert rows[0]["unseen"] is True and rows[1]["unseen"] is False
    assert rows[1]["detail"] == "rate limited"
    assert set(rows[0]) == {"at", "kind", "provider", "session", "label", "detail", "duration", "unseen"}
    assert history_rows(ledger, since=NOW - 10.0) == rows[:1]
    assert history_rows(ledger, limit=1) == rows[:1]


def test_small_helpers() -> None:
    assert strip_session_short_id("jr-bar-b7 (fca1eb06)", CLAUDE_SID) == "jr-bar-b7"
    assert strip_session_short_id("plain", None) == "plain"
    assert lifecycle_for_mode(AgentMode.BLOCKED_ERROR, stale=False) == "failed"
    assert lifecycle_for_mode(AgentMode.IDLE_READY, stale=True) == "stale"
    assert aggregate_mode(None, asks=0, failed=0, working=0, ready=2) == "done"
    assert aggregate_mode(AgentMode.WORKING, asks=0, failed=0, working=0, ready=0) == "working"
    assert why_for_glance(SimpleNamespace(semantic=SimpleNamespace(value="attention"), override_reason=SimpleNamespace(value="none"))) == ("needs_you", None)
    assert why_for_glance(None) == (None, None)
    assert terminal_from_command("/Applications/Ghostty.app/Contents/MacOS/ghostty") == ("Ghostty", "com.mitchellh.ghostty")
    assert terminal_from_command("/usr/bin/zsh") is None
    assert hook_health(None) == {}
    assert origin_document(None) is None


def test_swift_fixture_matches_the_projection() -> None:
    document = build_state_document(**fixture_inputs())
    encoded = json.dumps(document, indent=1, sort_keys=True) + "\n"
    if os.environ.get("JRBAR_UPDATE_FIXTURES") == "1":
        SWIFT_FIXTURE.write_text(encoded, encoding="utf-8")
    assert SWIFT_FIXTURE.exists(), "run with JRBAR_UPDATE_FIXTURES=1 to write the Swift fixture"
    assert json.loads(SWIFT_FIXTURE.read_text(encoding="utf-8")) == json.loads(encoded)
