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

import pytest

from jrbar.completion_visibility import filter_visible_sessions
from jrbar.core_deck import DeckSlotFacts, build_deck_document, device_document
from jrbar.core_projection import (
    MAX_DURATION_SECONDS,
    WHY_VALUES,
    DeviceFacts,
    EscalationFacts,
    LightFacts,
    PowerFacts,
    SessionExtras,
    SurfaceFacts,
    aggregate_counts,
    aggregate_mode,
    bounded_duration,
    build_lights_document,
    build_settings_document,
    build_state_document,
    duration_since,
    history_rows,
    hook_health,
    lifecycle_for_mode,
    light_why,
    origin_document,
    session_document,
    session_label,
    short_session_id,
    strip_session_short_id,
    terminal_from_command,
    usage_document,
    usage_window_name,
    why_detail,
    why_for_glance,
)
from jrbar.core_usage_samples import UsageSampleBuffer
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
                    # A window the provider HAS but has not stated a
                    # reading for: ``remaining_percent`` of None, which the
                    # projection writes as ``used_pct: null``. It is here so
                    # the Swift decoder's optional handling is exercised
                    # against a document the Python side actually produced,
                    # not only against a hand-written mock -- the shape is
                    # agreed by construction. Unread is not absent: the
                    # reset the provider did state survives.
                    SimpleNamespace(lane_id="seven_day", label="7d", remaining_percent=None, reset_at=NOW + 320400.0, scope="account", model=None),
                ),
            ),
        ),
    )
    # An hour of the Claude 5h window climbing 12 points an hour: the
    # forecast says it runs out before the reset (8040 s away, 58 % left).
    usage_samples = UsageSampleBuffer()
    for offset in range(60, -1, -5):
        usage_samples.record("claude", "five_hour", 42.0 - 12.0 * offset / 60.0, at=NOW - offset * 60.0)
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
    deck = build_deck_document(
        device=device_document(
            serial="D0CF130481EC", transport="bluetooth", connected=True, approved=True, layer=0, profile=0,
            receipt={"code": "ready", "message": "Creator Micro 2 ready.", "at": NOW - 30.0},
        ),
        slots=[
            DeckSlotFacts(0, "a" * 64, CODEX_ID, "sidepulse-core", "codex", "input_required", pinned=True, navigable=True),
            DeckSlotFacts(1, "b" * 64, CLAUDE_ID, "jr-bar-b7", "claude", "active", navigable=True),
            DeckSlotFacts(2, "c" * 64, None, None, None, "unavailable"),
            *(DeckSlotFacts(index) for index in range(3, 13)),
        ],
        bank=0,
        bank_count=1,
        rail_edge="left",
        keymap_state="applied",
        backup_at=NOW - 86400.0,
        keymap_generation=3,
        layers=[{"profile": 0, "layer": 0, "label": "Profile 1 / Layer 1: Base"}],
        input_check=False,
        last_input={"index": 1, "kind": "press", "at": NOW - 4.0},
        settings={"enabled": True, "session_mode": True, "analog_enabled": False},
        bindings={14: "next_bank", 13: "previous_bank"},
        driven=True,
    )
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
        deck=deck,
        usage_samples=usage_samples,
    )


def test_state_document_carries_the_deck_when_given() -> None:
    document = build_state_document(**fixture_inputs())
    deck = document["deck"]
    assert deck["device"]["serial"] == "D0CF130481EC" and deck["device"]["transport"] == "bluetooth"
    assert len(deck["slots"]) == 13 and deck["slots"][0]["color"] == "#FF3A00" and deck["slots"][1]["color"] == "#00E5FF"
    assert deck["slots"][2]["state"] == "unavailable" and deck["slots"][2]["color"] == "#020204"
    assert [row["mapping"] for row in deck["aux"]][:2] == ["previous_bank", "next_bank"]
    assert deck["keymap"]["state"] == "applied" and deck["rail"] == {"edge": "left"}
    inputs = fixture_inputs()
    inputs.pop("deck")
    assert "deck" not in build_state_document(**inputs)


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
    # The forecast is about the primary (5h) window, from the sample buffer.
    assert claude["forecast"]["window_id"] == "five_hour" and claude["forecast"]["pace"] == "under"
    assert claude["forecast"]["exhausts_at"] == pytest.approx(NOW + 58.0 / 12.0 * 3600.0, abs=1.0)
    assert claude["forecast"]["remaining_pct"] == 58.0 and claude["forecast"]["samples"] == 13
    # No history for codex yet: no forecast rather than a guess.
    assert codex["forecast"] is None
    assert usage_document(fixture_inputs()["usage_state"])["providers"][0]["forecast"] is None
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
    # Read-only daemon facts ride in the document; only catalogued ones.
    settings = build_settings_document(
        {"alert_burst": 3}, generation=18, read_only={"cloud_ingest_token_path": "/s/t.token", "pid": 1}
    )
    assert settings["document"] == {"alert_burst": 3, "cloud_ingest_token_path": "/s/t.token"}


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
    assert aggregate_mode({"needs_you": 0, "failed": 0, "active": 0, "ready": 2}) == "done"
    assert aggregate_mode({"needs_you": 0, "failed": 0, "active": 0, "ready": 0}) == "idle"
    assert aggregate_mode({}) == "idle"
    assert why_for_glance(SimpleNamespace(semantic=SimpleNamespace(value="attention"), override_reason=SimpleNamespace(value="none"))) == ("waiting", None)
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


#: A glance's ``relay_epoch`` is a ``time.monotonic()`` reading, not a
#: wall clock: on this Mac it is the machine's uptime, five orders of
#: magnitude smaller than ``NOW``. Fixtures that made it look like an
#: epoch are what let the mixed-clock subtraction pass review.
MONOTONIC_NOW = 200_000.0


def _glance(semantic: str, override: str = "none", relay_epoch: float = MONOTONIC_NOW - 30.0):
    return SimpleNamespace(
        semantic=SimpleNamespace(value=semantic),
        override_reason=SimpleNamespace(value=override),
        relay_epoch=relay_epoch,
    )


def test_session_labels_prefer_the_providers_own_title_then_cwd_then_short_id() -> None:
    sid = "fca1eb06-f6d1-413e-aa5f-dd19d8e05973"
    common = dict(provider="claude", session_id=sid, agent_id=f"claude:session:{sid}")
    # The collector's content-free fallback carries nothing a person can read.
    assert session_label(display_name=f"Claude {sid}", cwd=None, extras=None, **common) == "Claude fca1eb06"
    assert session_label(display_name=f"Claude {sid}", cwd="/Users/j/Downloads/JR-Bar", extras=None, **common) == "JR-Bar"
    assert (
        session_label(display_name=f"Claude {sid}", cwd=None, extras=SessionExtras(cwd="/tmp/notes/"), **common)
        == "notes"
    )
    # Claude's own session name wins over everything.
    assert (
        session_label(display_name=f"Claude {sid}", cwd="/x/y", extras=SessionExtras(name="jr-bar-67"), **common)
        == "jr-bar-67"
    )
    # A derived display name keeps its meaning, with the short id stripped.
    assert session_label(display_name=f"JR-Bar: fix labels ({sid[:8]})", cwd=None, extras=None, **common) == "JR-Bar: fix labels"
    # Workers hang off their parent's label.
    assert (
        session_label(
            display_name="Claude agent a327411d618c21da0",
            cwd=None,
            extras=None,
            provider="claude",
            session_id=sid,
            agent_id="claude:agent:a327411d618c21da0",
            is_worker=True,
            parent_label="jr-bar-67",
        )
        == "jr-bar-67 worker a327411d"
    )
    assert short_session_id(sid) == "fca1eb06"
    assert short_session_id(None, "claude:agent:a327411d618c21da0") == "a327411d"
    assert short_session_id(None, None) is None
    document = build_state_document(**fixture_inputs())
    by_id = {row["id"]: row for row in document["sessions"]}
    assert by_id[CLAUDE_ID]["short_id"] == CLAUDE_SID[:8]
    assert by_id[CLAUDE_ID]["cwd"] == "/Users/j/Downloads/JR-Bar"
    assert by_id[CLAUDE_WORKER_ID]["label"] == f"jr-bar-b7 worker {CLAUDE_SID[:8]}"
    assert by_id[CLAUDE_WORKER_ID]["short_id"] == CLAUDE_SID[:8]


def test_usage_window_names_are_the_panels_short_forms() -> None:
    assert usage_window_name("five-hour", "5-hour") == "5h"
    assert usage_window_name("five_hour", "5h") == "5h"
    assert usage_window_name("weekly", "Weekly") == "7d"
    assert usage_window_name("seven_day", "7d") == "7d"
    assert usage_window_name("weekly", "Fable only", "fable") == "7d Fable"
    assert usage_window_name("daily", "Daily") == "Daily"
    assert usage_window_name("monthly", "Monthly") == "Monthly"
    assert usage_window_name("credits", "Credits") == "Credits"
    assert usage_window_name("billing-month", "Organization billing month") == "Organization billing month"
    document = build_state_document(**fixture_inputs())
    assert [w["name"] for w in document["usage"]["providers"][0]["windows"]] == ["5h", "7d"]
    # A model lane with its own id borrows the horizon of the account
    # window it resets with.
    lanes = (
        SimpleNamespace(lane_id="weekly", label="Weekly", remaining_percent=71.0, reset_at=NOW + 86400.0, scope="all", model=None),
        SimpleNamespace(lane_id="fable-only", label="Fable only", remaining_percent=45.0, reset_at=NOW + 86400.0, scope="all", model="fable"),
    )
    usage = SimpleNamespace(
        refreshed_at=NOW, next_refresh_at=None, refreshing=False,
        snapshots=(SimpleNamespace(provider_id="claude", source_instance_id="default", account_label=None, lanes=lanes, state=SimpleNamespace(value="ready"), reason_code=None, action_label=None, observed_at=NOW, input_tokens=0, cached_input_tokens=0, output_tokens=0, estimated_cost_usd=None, credits_remaining=None),),
    )
    from jrbar.core_projection import usage_document

    names = [(w["name"], w["id"], w["resets_at"]) for w in usage_document(usage)["providers"][0]["windows"]]
    assert names == [("7d", "weekly", NOW + 86400.0), ("7d Fable", "fable-only", NOW + 86400.0)]


def test_light_why_is_the_documented_vocabulary() -> None:
    assert light_why(None) == "unknown"
    assert light_why(_glance("attention")) == "waiting"
    assert light_why(_glance("fresh_completion")) == "completed"
    assert light_why(_glance("active")) == "working"
    assert light_why(_glance("rest")) == "idle"
    assert light_why(_glance("unresolved_failure")) == "failed"
    assert light_why(_glance("capacity")) == "capacity"
    assert light_why(_glance("active"), LightFacts(preview=True)) == "preview"
    assert light_why(_glance("active"), LightFacts(display_kind="battery")) == "battery"
    assert light_why(_glance("active"), LightFacts(display_kind="low_battery")) == "battery"
    assert light_why(_glance("active"), LightFacts(display_kind="calendar")) == "calendar"
    assert light_why(_glance("active"), LightFacts(display_kind="reminders")) == "reminder"
    assert light_why(_glance("active"), LightFacts(display_kind="escalation")) == "escalation"
    assert light_why(_glance("active"), LightFacts(display_kind="studio")) == "studio"
    assert light_why(_glance("active"), LightFacts(display_kind="agent")) == "working"
    assert light_why(_glance("active"), LightFacts(dnd_display_admission="none")) == "quiet"
    assert light_why(_glance("active"), LightFacts(dnd_brightness_factor=0.0)) == "quiet"
    assert light_why(_glance("rest"), LightFacts(dimming=("idle_dim",))) == "idle_dim"
    assert light_why(_glance("rest"), LightFacts(dimming=("sleep",))) == "sleep_dim"
    assert light_why(_glance("rest"), LightFacts(dimming=("quiet",))) == "quiet"
    # A dimmed working light is still "working"; the dimming lives in why_detail.
    assert light_why(_glance("active"), LightFacts(dimming=("idle_dim",))) == "working"
    for value in ("idle", "working", "waiting", "completed", "failed", "capacity", "quiet", "sleep_dim", "idle_dim",
                  "battery", "calendar", "reminder", "escalation", "preview", "studio", "unknown"):
        assert value in WHY_VALUES


def test_why_detail_names_the_session_behind_the_light() -> None:
    document = build_state_document(**fixture_inputs())
    facts = LightFacts(dimming=("idle_dim", "quiet"), brightness_factor=0.045)
    waiting = why_detail("waiting", sessions=document["sessions"], asks=document["asks"], now=NOW, facts=facts)
    assert waiting["session"] == CODEX_ID and waiting["provider"] == "codex" and waiting["label"] == "sidepulse-core"
    assert waiting["seconds_in_state"] == round(NOW - 1788982800.0, 1)
    assert waiting["dimming"] == ["idle_dim", "quiet"] and waiting["brightness_factor"] == 0.045
    working = why_detail("working", sessions=document["sessions"], asks=document["asks"], now=NOW)
    assert working["session"] == CLAUDE_ID and working["seconds_in_state"] == 1.4
    completed = why_detail(
        "completed", sessions=document["sessions"], asks=(), unseen_completion_ids=(GEMINI_ID,), now=NOW
    )
    assert completed["session"] == GEMINI_ID and completed["seconds_in_state"] == 41.0
    idle = why_detail(
        "idle",
        sessions=document["sessions"],
        asks=(),
        now=NOW,
        monotonic_now=MONOTONIC_NOW,
        glance=_glance("rest"),
    )
    assert idle["session"] is None and idle["seconds_in_state"] == 30.0
    assert set(idle) == {"session", "label", "provider", "seconds_in_state", "brightness_factor", "dimming"}
    lights = build_lights_document(
        {"hardware": SurfaceFacts(program="off", led_count=8, why="waiting", why_detail=waiting)},
        linked=True,
        devices_linked=False,
    )
    assert lights["surfaces"]["hardware"]["why_detail"]["session"] == CODEX_ID
    assert lights["devices_linked"] is False


def test_install_probe_sessions_are_not_sessions() -> None:
    inputs = fixture_inputs()
    probe = _status(agent_id="codex:session:jrbar-install-probe", session_id="jrbar-install-probe", provider="codex", display_name="Codex jrbar-install-probe", work_key="wk-probe")
    inputs["snapshot"] = SimpleNamespace(
        aggregate=inputs["snapshot"].aggregate,
        statuses=(*inputs["snapshot"].statuses, probe),
        stale_statuses=inputs["snapshot"].stale_statuses,
        collected_at=inputs["snapshot"].collected_at,
    )
    document = build_state_document(**inputs)
    assert all(not row["id"].endswith("-install-probe") for row in document["sessions"])
    assert document["aggregate"]["total"] == 3


# --- session visibility in the state document -------------------------------


def test_only_a_real_end_event_on_a_living_session_reads_completed() -> None:
    """`completed` is the green check, and it is a claim about the provider.

    A completion the collector merely inferred, or a process that died
    without ever sending an end event, reads `ended`: grey, no check.
    `stale` says the source stopped delivering.
    """
    assert lifecycle_for_mode(AgentMode.COMPLETED, stale=True, event_name="Stop") == "completed"
    assert lifecycle_for_mode(AgentMode.COMPLETED, stale=True, event_name="SessionEnd") == "completed"
    assert lifecycle_for_mode(AgentMode.COMPLETED, stale=False, event_name="Stop", process_alive=True) == "completed"
    # An inferred completion (a notification that read as done) never claims it.
    assert lifecycle_for_mode(AgentMode.COMPLETED, stale=True, event_name="Notification") == "ended"
    assert lifecycle_for_mode(AgentMode.ENDED_UNCONFIRMED, stale=True, event_name="PostToolUse") == "ended"
    assert lifecycle_for_mode(AgentMode.BLOCKED_ERROR, stale=True, event_name="StopFailure") == "failed"
    assert lifecycle_for_mode(AgentMode.WORKING, stale=True, event_name="PostToolUse") == "stale"
    assert lifecycle_for_mode(AgentMode.WORKING, stale=False, event_name="PostToolUse") == "active"


def test_a_finished_one_shot_run_earns_done_even_though_it_has_exited() -> None:
    """`codex exec`, `claude -p` and `pi -p` send a real Stop and SessionEnd
    and then exit. That is the whole life of a one-shot run, and it is
    `completed`; demoting on a dead process meant no such run could ever
    earn the check."""

    for event in ("Stop", "SessionEnd", "SubagentStop"):
        assert (
            lifecycle_for_mode(
                AgentMode.COMPLETED,
                stale=True,
                event_name=event,
                process_alive=False,
                provider_ended=True,
            )
            == "completed"
        ), event
        # The registry may have nothing to say (record pruned, never
        # written); the provider's own event still wins.
        assert (
            lifecycle_for_mode(
                AgentMode.COMPLETED, stale=True, event_name=event, process_alive=False
            )
            == "completed"
        ), event


def test_a_process_that_died_without_an_end_event_is_ended_not_done() -> None:
    """The liveness sweep's synthetic `SessionEnd` looks exactly like a real
    one on the wire; `provider_ended=False` is what tells them apart."""

    assert (
        lifecycle_for_mode(
            AgentMode.COMPLETED,
            stale=True,
            event_name="SessionEnd",
            process_alive=False,
            provider_ended=False,
        )
        == "ended"
    )
    assert (
        lifecycle_for_mode(
            AgentMode.COMPLETED,
            stale=True,
            event_name="SubagentStop",
            process_alive=False,
            provider_ended=False,
        )
        == "ended"
    )
    # Nothing to judge by at all: a dead process is still over, not Done.
    assert (
        lifecycle_for_mode(AgentMode.COMPLETED, stale=True, process_alive=False) == "ended"
    )
    # An inference does not become a claim just because the registry saw a
    # real SessionEnd for the session.
    assert (
        lifecycle_for_mode(
            AgentMode.COMPLETED,
            stale=True,
            event_name="Notification",
            provider_ended=True,
        )
        == "ended"
    )


def test_a_one_shot_run_that_exited_reads_done_in_the_document() -> None:
    row = session_document(
        _status(
            mode=AgentMode.COMPLETED,
            event_name="SessionEnd",
            updated_at=_at(30.0),
        ),
        operator_state=None,
        ask_ids=frozenset(),
        extras=SessionExtras(pid=None, process_alive=False, provider_ended=True),
        workers=0,
    )
    assert row["lifecycle"] == "completed"
    # `mode` paints the check too: a Done row must keep the word.
    assert row["mode"] == "completed"
    assert row["stale"] is False


def test_a_killed_session_reads_ended_in_the_document() -> None:
    row = session_document(
        _status(
            mode=AgentMode.COMPLETED,
            event_name="SessionEnd",
            updated_at=_at(30.0),
        ),
        operator_state=None,
        ask_ids=frozenset(),
        extras=SessionExtras(pid=None, process_alive=False, provider_ended=False),
        workers=0,
    )
    assert row["lifecycle"] == "ended"
    assert row["mode"] == "ended_unconfirmed"


def test_a_dead_process_is_ended_and_stale_in_the_document_not_done() -> None:
    status = _status(
        agent_id=GEMINI_ID,
        provider="gemini",
        mode=AgentMode.COMPLETED,
        event_name="Notification",
        session_id="8a1c2e3f-5b6d-4c7e-9f0a-1b2c3d4e5f6a",
        updated_at=_at(60.0),
    )
    row = session_document(
        status,
        operator_state=None,
        ask_ids=frozenset(),
        extras=SessionExtras(pid=None, process_alive=False),
        workers=0,
    )
    assert row["lifecycle"] == "ended" and row["stale"] is True
    # The app reads `mode` too, and `completed` there would still paint the
    # green check; a demoted row must not carry the word.
    assert row["mode"] == "ended_unconfirmed"
    assert row["pid"] is None
    # Nothing looked at the registry: the older, looser reading stands.
    unknown = session_document(
        _status(mode=AgentMode.COMPLETED, event_name="Stop", updated_at=_at(60.0)),
        operator_state=None,
        ask_ids=frozenset(),
        extras=None,
        workers=0,
    )
    assert unknown["lifecycle"] == "completed" and unknown["mode"] == "completed"


def test_a_session_whose_process_is_alive_is_never_ended() -> None:
    """Liveness beats silence.

    ``ended_unconfirmed`` is what the collector says when a working session
    stops sending hooks past its window -- "probably over, nobody said so",
    which was the best guess available when a silence timer was the only
    evidence. The process registry knows better: it can see the agent's own
    process. A long tool run that says nothing for twenty minutes is not a
    dead session, and the panel must not call it one.
    """

    for event in (None, "PreToolUse", "PostToolUse"):
        assert (
            lifecycle_for_mode(
                AgentMode.ENDED_UNCONFIRMED, stale=False, event_name=event, process_alive=True
            )
            == "active"
        ), event
        # Old information about a live process is stale, never ended.
        assert (
            lifecycle_for_mode(
                AgentMode.ENDED_UNCONFIRMED, stale=True, event_name=event, process_alive=True
            )
            == "stale"
        ), event
    # Being alive is not a finish either: a live process never wins the check.
    assert (
        lifecycle_for_mode(
            AgentMode.COMPLETED, stale=False, event_name="Notification", process_alive=True
        )
        == "active"
    )


def test_the_ended_rule_still_holds_for_a_process_that_is_gone() -> None:
    """The fix the liveness rule must not undo: only ``process_alive is
    True`` outvotes the silence timer. "Nobody looked" and "the process is
    gone" both still read ``ended``."""

    for alive in (None, False):
        assert (
            lifecycle_for_mode(
                AgentMode.ENDED_UNCONFIRMED, stale=True, event_name="PostToolUse", process_alive=alive
            )
            == "ended"
        ), alive
    # The sweep's synthetic end on a dead process is still not a completion.
    assert (
        lifecycle_for_mode(
            AgentMode.COMPLETED,
            stale=True,
            event_name="SessionEnd",
            process_alive=False,
            provider_ended=False,
        )
        == "ended"
    )


def test_a_live_but_silent_session_reads_working_in_the_document() -> None:
    """What the panel says: Working, with ``since`` carrying how long it has
    been quiet. The mode travels beside the lifecycle and the app reads
    whichever is more definite, so a row that is not over must not still say
    ``ended_unconfirmed`` -- `SessionActivity.reduce` would print "Idle" and
    the aggregate would drop it from ``active``."""

    row = session_document(
        _status(mode=AgentMode.ENDED_UNCONFIRMED, event_name="PreToolUse", updated_at=_at(20 * 60.0)),
        operator_state=None,
        ask_ids=frozenset(),
        extras=SessionExtras(pid=4242, process_alive=True),
        workers=0,
    )
    assert row["lifecycle"] == "active"
    assert row["mode"] == "working"
    assert row["stale"] is False
    assert row["pid"] == 4242
    # The header counts it, so the strip and the Dot keep showing work.
    counts = aggregate_counts([row])
    assert counts["active"] == 1 and counts["total"] == 1
    assert aggregate_mode(counts) == "working"


def test_a_live_but_silent_session_is_not_marked_stale_or_aged_out() -> None:
    """The third way to lose a running session, after "Ended" and "not
    active": `session_visibility` drops a **stale** row from the list ten
    quiet minutes after its last event. A row whose process the registry
    just found in the table is old, not unvouched -- so it stays listed,
    however long the tool run takes, and disappears only when the process
    does."""

    quiet = _status(
        mode=AgentMode.WORKING,
        event_name="PreToolUse",
        stale=True,
        updated_at=_at(45 * 60.0),
    )
    row = session_document(
        quiet,
        operator_state=None,
        ask_ids=frozenset(),
        extras=SessionExtras(pid=4242, process_alive=True),
        workers=0,
    )
    assert row["stale"] is False and row["lifecycle"] == "active"
    listed, hidden, _ = filter_visible_sessions([row], now=NOW)
    assert listed == [row] and hidden == 0

    # A finished row on the same live process keeps its own clock: an open
    # terminal must not pin "Done" on screen for ever.
    done = session_document(
        _status(mode=AgentMode.COMPLETED, event_name="Stop", stale=True, updated_at=_at(45 * 60.0)),
        operator_state=None,
        ask_ids=frozenset(),
        extras=SessionExtras(pid=4242, process_alive=True),
        workers=0,
    )
    assert done["stale"] is True and done["lifecycle"] == "completed"
    assert filter_visible_sessions([done], now=NOW)[0] == []


def test_a_killed_session_still_reads_ended_in_the_document() -> None:
    """The same row with the process gone: unchanged."""

    row = session_document(
        _status(mode=AgentMode.ENDED_UNCONFIRMED, event_name="PreToolUse", updated_at=_at(20 * 60.0)),
        operator_state=None,
        ask_ids=frozenset(),
        extras=SessionExtras(pid=None, process_alive=False),
        workers=0,
    )
    assert row["lifecycle"] == "ended"
    assert row["mode"] == "ended_unconfirmed"
    assert aggregate_counts([row])["active"] == 0


def _visibility_inputs(**overrides) -> dict:
    """The owner's screenshot as a snapshot: live work, plus rows long over."""
    live = _status(updated_at=_at(20.0))
    worker = _status(
        agent_id=CLAUDE_WORKER_ID,
        display_name="worker",
        mode=AgentMode.WORKING,
        updated_at=_at(25.0),
        work_key="wk-claude-worker",
    )
    fresh_completion = _status(
        provider="gemini",
        agent_id=GEMINI_ID,
        session_id="8a1c2e3f-5b6d-4c7e-9f0a-1b2c3d4e5f6a",
        mode=AgentMode.COMPLETED,
        event_name="Stop",
        updated_at=_at(3.5 * 60.0),
        stale=True,
        work_key="wk-gemini",
    )
    aged_completion = _status(
        provider="codex",
        agent_id=CODEX_ID,
        session_id="0f3b2c9a-71d4-4e0e-9a8e-2c1d5f6a7b8c",
        mode=AgentMode.COMPLETED,
        event_name="Stop",
        updated_at=_at(41.0 * 60.0),
        stale=True,
        work_key="wk-codex",
    )
    ancient_idle = _status(
        provider="devin",
        agent_id="devin:session:metal-cl",
        session_id="metal-cl",
        mode=AgentMode.IDLE_READY,
        event_name="SessionStart",
        updated_at=_at(54.4 * 60.0),
        stale=True,
        work_key="wk-devin",
    )
    snapshot = SimpleNamespace(
        aggregate=SimpleNamespace(mode=AgentMode.WORKING),
        statuses=(live, worker),
        stale_statuses=(fresh_completion, aged_completion, ancient_idle),
        collected_at=datetime.fromtimestamp(NOW, tz=timezone.utc),
    )
    inputs = dict(
        now=NOW,
        generation=1,
        snapshot=snapshot,
        ask_statuses=[],
        unseen_completion_ids=frozenset({GEMINI_ID, CODEX_ID}),
    )
    inputs.update(overrides)
    return inputs


def test_state_sessions_hold_only_live_rows_and_fresh_completions() -> None:
    document = build_state_document(**_visibility_inputs())

    assert [session["id"] for session in document["sessions"]] == [
        CLAUDE_ID,
        CLAUDE_WORKER_ID,
        GEMINI_ID,
    ]
    # Two main rows are older than their windows; History has them.
    assert document["hidden_count"] == 2
    # Only the completion still on screen counts as news.
    assert document["unseen_completions"] == [GEMINI_ID]
    assert document["aggregate"]["ready"] == 1
    assert document["aggregate"]["total"] == 2


def test_acknowledged_rows_leave_the_list_and_come_back_on_undo() -> None:
    from jrbar.capacity_types import SourceKey
    from jrbar.clear_agents import CompletionPresentationKey

    source = SourceKey("gemini", "hooks", "local", "agent_events")
    acknowledged = (CompletionPresentationKey(source, GEMINI_ID, "Stop", NOW - 3.5 * 60.0),)

    cleared = build_state_document(**_visibility_inputs(acknowledged_keys=acknowledged))
    assert [session["id"] for session in cleared["sessions"]] == [CLAUDE_ID, CLAUDE_WORKER_ID]
    assert cleared["hidden_count"] == 3
    assert cleared["unseen_completions"] == [] and cleared["aggregate"]["ready"] == 0

    # `undo_clear` drops the receipt; visibility is recomputed from it.
    restored = build_state_document(**_visibility_inputs(acknowledged_keys=()))
    assert [session["id"] for session in restored["sessions"]] == [
        CLAUDE_ID,
        CLAUDE_WORKER_ID,
        GEMINI_ID,
    ]


def test_a_completion_drops_out_when_the_clock_passes_twenty_minutes() -> None:
    """A test clock, not twenty minutes of waiting."""
    listed = build_state_document(**_visibility_inputs(now=NOW + 16 * 60.0))
    assert GEMINI_ID in {session["id"] for session in listed["sessions"]}

    gone = build_state_document(**_visibility_inputs(now=NOW + 17.5 * 60.0))
    assert GEMINI_ID not in {session["id"] for session in gone["sessions"]}
    assert gone["unseen_completions"] == [] and gone["aggregate"]["ready"] == 0
    # Three main rows are now only in History; the live pair, which the
    # collector still says is delivering, is untouched by the clock.
    assert [session["id"] for session in gone["sessions"]] == [CLAUDE_ID, CLAUDE_WORKER_ID]
    assert gone["hidden_count"] == 3


def test_a_quiet_session_leaves_the_list_ten_minutes_after_its_last_event() -> None:
    """A row the source stopped delivering: ten minutes, then History.

    A row still being delivered is not on this clock -- a long tool call
    goes quiet for a while and is still work in progress.
    """
    quiet = _status(
        provider="devin",
        agent_id="devin:session:lapis-fl",
        session_id="lapis-fl",
        mode=AgentMode.WORKING,
        event_name="PostToolUse",
        updated_at=_at(0.0),
        stale=True,
        work_key="wk-devin",
    )
    snapshot = SimpleNamespace(
        aggregate=SimpleNamespace(mode=AgentMode.WORKING),
        statuses=(),
        stale_statuses=(quiet,),
        collected_at=datetime.fromtimestamp(NOW, tz=timezone.utc),
    )
    common = dict(generation=1, snapshot=snapshot, ask_statuses=[], unseen_completion_ids=frozenset())

    listed = build_state_document(now=NOW + 9 * 60.0, **common)
    assert [session["id"] for session in listed["sessions"]] == ["devin:session:lapis-fl"]
    assert listed["sessions"][0]["lifecycle"] == "stale" and listed["hidden_count"] == 0

    gone = build_state_document(now=NOW + 11 * 60.0, **common)
    assert gone["sessions"] == [] and gone["hidden_count"] == 1


# --- the four live defects ----------------------------------------------------
#
# Every test below was written from what the daemon on this Mac actually put
# on the wire, read over ``~/.local/state/jrbar/core.sock``.


def test_seconds_in_state_is_a_duration_never_a_clock_reading() -> None:
    """``lights.surfaces.*.why_detail.seconds_in_state`` read 1788869798.0.

    A light with no session behind it (a preview, an idle strip) fell back
    to the glance's ``relay_epoch``, which is a ``time.monotonic()``
    reading, and subtracted it from a wall-clock ``now``. The app rendered
    the difference as "20704 d".
    """

    document = build_state_document(**fixture_inputs())
    glance = _glance("rest")

    # The live shape: a monotonic relay epoch, a wall-clock now, no session.
    with_monotonic = why_detail(
        "preview", sessions=document["sessions"], asks=(), now=NOW, monotonic_now=MONOTONIC_NOW, glance=glance
    )
    assert with_monotonic["session"] is None
    assert with_monotonic["seconds_in_state"] == 30.0

    # Without a monotonic reading there is no honest answer, and a wrong
    # one is worse than none: the field says nothing rather than 56 years.
    without_monotonic = why_detail(
        "preview", sessions=document["sessions"], asks=(), now=NOW, glance=glance
    )
    assert without_monotonic["seconds_in_state"] is None

    # Even handed both clocks the wrong way round, nothing absurd escapes.
    crossed = why_detail(
        "preview",
        sessions=document["sessions"],
        asks=(),
        now=NOW,
        monotonic_now=NOW,
        glance=_glance("rest", relay_epoch=MONOTONIC_NOW),
    )
    assert crossed["seconds_in_state"] is None

    # A session-backed light still measures wall clock against wall clock.
    working = why_detail(
        "working", sessions=document["sessions"], asks=(), now=NOW, monotonic_now=MONOTONIC_NOW
    )
    assert working["session"] == CLAUDE_ID and working["seconds_in_state"] == 1.4


def test_duration_helpers_refuse_a_mixed_clock_subtraction() -> None:
    assert duration_since(NOW, NOW - 90.0) == 90.0
    # A timestamp a hair in the future is clock skew, not a negative wait.
    assert duration_since(NOW, NOW + 5.0) == 0.0
    assert duration_since(NOW, None) is None and duration_since(None, NOW) is None
    # The live defect: a monotonic reading against a wall clock.
    assert duration_since(NOW, MONOTONIC_NOW) is None
    assert duration_since(NOW, 0.0) is None
    assert duration_since(NOW, NOW - MAX_DURATION_SECONDS + 10.0) is not None

    assert bounded_duration(42.34) == 42.3
    assert bounded_duration(-3.0) == 0.0
    assert bounded_duration(MAX_DURATION_SECONDS + 1.0) is None
    assert bounded_duration(float("inf")) is None
    assert bounded_duration(None) is None
    assert bounded_duration(1.23456, digits=None) == 1.23456


def test_no_duration_shaped_field_in_state_can_claim_a_lifetime() -> None:
    """The sweep the first defect earned: every seconds-shaped field."""

    inputs = fixture_inputs()
    # An intake report whose age came off the wrong clock.
    inputs["intake_report"] = SimpleNamespace(
        providers=(
            SimpleNamespace(provider="claude", installed=True, stuck=False, delivering=True, heard_age_seconds=1.4),
            SimpleNamespace(provider="codex", installed=True, stuck=False, delivering=True, heard_age_seconds=NOW),
        ),
        hook_state=SimpleNamespace(code=SimpleNamespace(value="configured")),
        source_health=SimpleNamespace(code=SimpleNamespace(value="ok")),
        silence_seconds=1.4,
    )
    document = build_state_document(**inputs)
    sources = document["health"]["sources"]
    assert sources["claude"]["heard_age_seconds"] == 1.4
    assert sources["codex"]["heard_age_seconds"] is None

    def durations(node, path=""):
        if isinstance(node, dict):
            for key, value in node.items():
                yield from durations(value, f"{path}.{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                yield from durations(value, f"{path}[{index}]")
        elif isinstance(node, (int, float)) and not isinstance(node, bool):
            if path.endswith("_seconds") or path.endswith("seconds_in_state"):
                yield path, float(node)

    for path, value in durations(document):
        if path.endswith("silence_seconds"):
            continue  # A policy window, not an elapsed time.
        assert 0.0 <= value <= MAX_DURATION_SECONDS, f"{path} is not a duration: {value}"


def test_an_ask_always_names_a_session_the_document_lists() -> None:
    """Live: an ask for ``claude:session:5facd783…`` whose session had
    already been dropped from ``state.sessions``. The header counted it and
    the strip pulsed amber with no row to show for it."""

    # The session went quiet 40 minutes ago -- far past every window -- and
    # is still the one the daemon is asking the owner about.
    asking = _status(
        provider="claude",
        agent_id="claude:session:5facd783",
        session_id="5facd783",
        display_name="jr-bar-b7",
        mode=AgentMode.WAITING_FOR_INPUT,
        event_name="PermissionRequest",
        updated_at=_at(40 * 60.0),
        tool_name="Bash",
        message="Run: rm -rf build",
        stale=True,
        work_key="wk-asking",
    )
    snapshot = SimpleNamespace(
        aggregate=SimpleNamespace(mode=AgentMode.WAITING_FOR_INPUT),
        statuses=(),
        stale_statuses=(asking,),
        collected_at=datetime.fromtimestamp(NOW, tz=timezone.utc),
    )
    pinned = build_state_document(
        now=NOW,
        generation=1,
        snapshot=snapshot,
        ask_statuses=[asking],
        unseen_completion_ids=frozenset(),
    )
    assert [session["id"] for session in pinned["sessions"]] == ["claude:session:5facd783"]
    assert pinned["hidden_count"] == 0
    assert [ask["session"] for ask in pinned["asks"]] == ["claude:session:5facd783"]
    assert pinned["aggregate"]["mode"] == "needs_you" and pinned["aggregate"]["needs_you"] == 1

    # Without the ask the same row is forty minutes of history.
    unpinned = build_state_document(
        now=NOW,
        generation=1,
        snapshot=snapshot,
        ask_statuses=[],
        unseen_completion_ids=frozenset(),
    )
    assert unpinned["sessions"] == [] and unpinned["hidden_count"] == 1
    assert unpinned["aggregate"]["mode"] == "idle"

    # An ask whose session the snapshot no longer carries at all cannot be
    # pinned, so it is dropped rather than left dangling.
    gone = build_state_document(
        now=NOW,
        generation=1,
        snapshot=SimpleNamespace(
            aggregate=SimpleNamespace(mode=AgentMode.WAITING_FOR_INPUT),
            statuses=(),
            stale_statuses=(),
            collected_at=datetime.fromtimestamp(NOW, tz=timezone.utc),
        ),
        ask_statuses=[asking],
        unseen_completion_ids=frozenset(),
    )
    assert gone["asks"] == [] and gone["sessions"] == []
    assert gone["aggregate"]["needs_you"] == 0 and gone["aggregate"]["mode"] == "idle"


def test_an_ask_outranks_a_clear_receipt() -> None:
    """A widened ``clear_completed`` hid stale rows, an open ask included."""
    from jrbar.capacity_types import SourceKey
    from jrbar.clear_agents import CompletionPresentationKey

    asking = _status(
        provider="codex",
        agent_id=CODEX_ID,
        session_id="0f3b2c9a-71d4-4e0e-9a8e-2c1d5f6a7b8c",
        mode=AgentMode.WAITING_FOR_INPUT,
        event_name="PermissionRequest",
        updated_at=_at(30.0),
        message="Run: rm -rf build",
        work_key="wk-codex",
    )
    snapshot = SimpleNamespace(
        aggregate=SimpleNamespace(mode=AgentMode.WAITING_FOR_INPUT),
        statuses=(asking,),
        stale_statuses=(),
        collected_at=datetime.fromtimestamp(NOW, tz=timezone.utc),
    )
    source = SourceKey("codex", "hooks", "local", "agent_events")
    document = build_state_document(
        now=NOW,
        generation=1,
        snapshot=snapshot,
        ask_statuses=[asking],
        unseen_completion_ids=frozenset(),
        acknowledged_keys=(CompletionPresentationKey(source, CODEX_ID, "Stop", NOW),),
    )
    assert [session["id"] for session in document["sessions"]] == [CODEX_ID]
    assert [ask["session"] for ask in document["asks"]] == [CODEX_ID]


def test_a_pinned_worker_keeps_its_parent_listed() -> None:
    """An orphan ask one level down is the same defect."""
    parent = _status(
        agent_id=CLAUDE_ID,
        mode=AgentMode.IDLE_READY,
        event_name="SessionStart",
        updated_at=_at(45 * 60.0),
        stale=True,
        work_key="wk-claude",
    )
    worker = _status(
        agent_id=CLAUDE_WORKER_ID,
        display_name="worker",
        mode=AgentMode.WAITING_FOR_INPUT,
        event_name="PermissionRequest",
        updated_at=_at(45 * 60.0),
        message="Run: rm -rf build",
        stale=True,
        work_key="wk-claude-worker",
    )
    document = build_state_document(
        now=NOW,
        generation=1,
        snapshot=SimpleNamespace(
            aggregate=SimpleNamespace(mode=AgentMode.WAITING_FOR_INPUT),
            statuses=(),
            stale_statuses=(parent, worker),
            collected_at=datetime.fromtimestamp(NOW, tz=timezone.utc),
        ),
        ask_statuses=[worker],
        unseen_completion_ids=frozenset(),
    )
    listed = [session["id"] for session in document["sessions"]]
    assert listed == [CLAUDE_ID, CLAUDE_WORKER_ID]
    assert [ask["session"] for ask in document["asks"]] == [CLAUDE_WORKER_ID]


def _random_statuses(rng, count: int) -> tuple[list, list, list]:
    """A pseudo-random world: live, stale and finished rows of every mode."""
    modes = list(AgentMode)
    live, stale, asks = [], [], []
    for index in range(count):
        mode = rng.choice(modes)
        is_stale = rng.random() < 0.4
        provider = rng.choice(("claude", "codex", "gemini", "devin"))
        status = _status(
            provider=provider,
            agent_id=f"{provider}:session:{index:04d}",
            session_id=f"{index:04d}",
            display_name=f"row-{index}",
            mode=mode,
            event_name=rng.choice(("Stop", "PreToolUse", "PermissionRequest", "SessionEnd", "Notification")),
            updated_at=_at(rng.choice((0.5, 30.0, 4 * 60.0, 12 * 60.0, 25 * 60.0, 90 * 60.0))),
            tool_name=None,
            message=None,
            stale=is_stale,
            work_key=f"wk-{index}",
        )
        (stale if is_stale else live).append(status)
        if mode is AgentMode.WAITING_FOR_INPUT and rng.random() < 0.7:
            asks.append(status)
    return live, stale, asks


@pytest.mark.parametrize("seed", range(40))
def test_the_aggregate_is_always_derivable_from_the_rows(seed: int) -> None:
    """Live: ``"working"`` with ``active: 0``, and ``"needs_you"`` while no
    listed session had an ask. The header word came from the collector's
    aggregate over sessions the panel could not see.

    The property, over generated session sets: the counts are a function of
    the rows the document carries, and the mode is a function of the counts.
    """

    import random

    rng = random.Random(seed)
    live, stale, asks = _random_statuses(rng, rng.randint(0, 14))
    document = build_state_document(
        now=NOW,
        generation=1,
        snapshot=SimpleNamespace(
            # Deliberately unrelated to the rows: it must get no vote.
            aggregate=SimpleNamespace(mode=rng.choice(list(AgentMode))),
            statuses=tuple(live),
            stale_statuses=tuple(stale),
            collected_at=datetime.fromtimestamp(NOW, tz=timezone.utc),
        ),
        ask_statuses=asks,
        unseen_completion_ids=frozenset(
            status.agent_id for status in (*live, *stale) if rng.random() < 0.5
        ),
    )
    aggregate = document["aggregate"]
    sessions = document["sessions"]
    listed_ids = {session["id"] for session in sessions}

    # The counts come from the rows.
    recomputed = aggregate_counts(
        sessions, asks=document["asks"], ready_ids=document["unseen_completions"]
    )
    assert {key: aggregate[key] for key in recomputed} == recomputed
    # ... and the mode comes from the counts.
    assert aggregate["mode"] == aggregate_mode(recomputed)

    # The invariant the counts rest on: no ask without its row.
    assert all(ask["session"] in listed_ids for ask in document["asks"])
    assert all(identifier in listed_ids for identifier in document["unseen_completions"])

    # Each count says what it claims about the rows the app receives.
    mains = [session for session in sessions if session["kind"] == "main"]
    assert aggregate["total"] == len(mains)
    assert aggregate["needs_you"] == len(document["asks"])
    assert aggregate["active"] == sum(
        1 for row in mains if row["mode"] in {"working", "tool_running", "long_task_progress"} and not row["stale"]
    )
    assert aggregate["failed"] == sum(
        1 for row in mains if row["lifecycle"] == "failed" and not row["stale"]
    )
    assert aggregate["ready"] == len(document["unseen_completions"])

    # And the word never contradicts them.
    if aggregate["mode"] == "needs_you":
        assert aggregate["needs_you"] > 0
    if aggregate["mode"] == "working":
        assert aggregate["active"] > 0 and aggregate["needs_you"] == 0 and aggregate["failed"] == 0
    if aggregate["mode"] == "failed":
        assert aggregate["failed"] > 0 and aggregate["needs_you"] == 0
    if aggregate["mode"] == "done":
        assert aggregate["ready"] > 0 and aggregate["active"] == 0
    if aggregate["mode"] == "idle":
        assert not any(aggregate[key] for key in ("needs_you", "active", "ready", "failed"))
