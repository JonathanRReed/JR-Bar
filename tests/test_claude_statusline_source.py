"""Claude Code's statusLine as an opt-in quota source.

What matters here: only the session id, the model and the rate limits are
kept; a document without rate limits is no evidence; a passed reset drops
its window; OAuth wins when it answers; and a statusline frame never
reaches hook processing, so it can never keep a session alive.
"""

from __future__ import annotations

import json
import os
import socket
from pathlib import Path

import pytest

import jrbar.claude_statusline_source as source
from jrbar.claude_statusline_source import (
    StatusLineStore,
    current_reading,
    ingest,
    minimize,
    snapshot_from_reading,
    statusline_text,
)
from jrbar.core_projection import usage_document
from jrbar.hook_ingress import HookIngressService
from jrbar.hook_ingress_protocol import (
    HookIngressDisposition,
    HookIngressRequest,
    decode_hook_ingress_response,
    encode_hook_ingress_request,
)
from jrbar.provider_usage_codex_claude import _oauth_rest_until, collect_claude
from jrbar.provider_usage_platform import ProviderSourceState
from jrbar.provider_usage_runtime import ProviderUsageState
from jrbar.provider_usage_settings import default_provider_usage_settings

NOW = 1_790_000_000.0
SECRET_PROMPT = "please refactor the payments module"


def statusline_payload(**limits) -> str:
    document = {
        "session_id": "sess-123",
        "transcript_path": f"/Users/me/.claude/projects/x/{SECRET_PROMPT}.jsonl",
        "cwd": "/Users/me/src/secret-project",
        "model": {"id": "claude-opus-5", "display_name": "Opus 5"},
        "workspace": {"current_dir": "/Users/me/src/secret-project"},
        "cost": {"total_cost_usd": 1.23},
        "version": "2.1.280",
    }
    if limits:
        document["rate_limits"] = limits
    return json.dumps(document)


LIMITS = {
    "five_hour": {"used_percentage": 42.0, "resets_at": NOW + 2 * 3600},
    "seven_day": {"used_percentage": 61.0, "resets_at": "2026-09-25T16:00:00Z"},
}


def test_only_the_session_model_and_rate_limits_are_kept(tmp_path: Path) -> None:
    store = StatusLineStore(tmp_path / "claude-statusline.json")

    assert ingest(statusline_payload(**LIMITS), now=NOW, store=store, enabled=True)

    reading = store.latest()
    assert reading.session_id == "sess-123"
    assert reading.model_id == "claude-opus-5"
    assert dict(reading.windows)["five_hour"].used_percentage == 42.0
    saved = (tmp_path / "claude-statusline.json").read_text()
    assert set(json.loads(saved)) == {"session_id", "model_id", "observed_at", "windows"}
    for leaked in (SECRET_PROMPT, "secret-project", "transcript", "cost", "1.23"):
        assert leaked not in saved


def test_no_rate_limits_is_no_evidence(tmp_path: Path) -> None:
    store = StatusLineStore(tmp_path / "reading.json")

    assert not ingest(statusline_payload(), now=NOW, store=store, enabled=True)
    assert store.latest() is None
    assert minimize("not json", now=NOW) is None
    assert minimize(json.dumps({"rate_limits": {"five_hour": {"used_percentage": "lots"}}}), now=NOW) is None


def test_a_passed_reset_drops_its_window() -> None:
    passed = {
        "five_hour": {"used_percentage": 97.0, "resets_at": NOW - 10},
        "seven_day": {"used_percentage": 61.0, "resets_at": NOW + 86400},
    }
    reading = minimize(statusline_payload(**passed), now=NOW)
    assert [key for key, _window in reading.windows] == ["seven_day"]

    # A kept reading loses a window when its reset passes later.
    later = minimize(statusline_payload(**LIMITS), now=NOW).current(NOW + 3 * 3600)
    assert [key for key, _window in later.windows] == ["seven_day"]
    everything_past = {"five_hour": {"used_percentage": 1.0, "resets_at": NOW - 1}}
    assert minimize(statusline_payload(**everything_past), now=NOW) is None


def test_the_source_is_off_until_turned_on(tmp_path: Path) -> None:
    store = StatusLineStore(tmp_path / "reading.json")
    assert not ingest(statusline_payload(**LIMITS), now=NOW, store=store, enabled=False)
    assert store.latest() is None
    ingest(statusline_payload(**LIMITS), now=NOW, store=store, enabled=True)
    assert current_reading(NOW + 60, store=store, enabled=False) is None
    assert current_reading(NOW + 60, store=store, enabled=True) is not None
    # Fifteen minutes on, it no longer stands in for anything.
    assert current_reading(NOW + 16 * 60, store=store, enabled=True) is None


class _Credentials:
    def get(self, provider, account):
        return type("Read", (), {"available": True, "secret": "oauth-token-value", "reason": None})()


def _collect(fetcher, reading, *, home: Path):
    return collect_claude(
        default_provider_usage_settings().preference("claude"),
        home=home,
        observed_at=NOW,
        credentials=_Credentials(),
        quota_fetcher=fetcher,
        local_scanner=lambda _home, _observed: {"input_tokens": 5, "output_tokens": 1},
        statusline_reader=lambda _now: reading,
    )


def test_oauth_wins_when_it_answers_and_the_status_line_stands_in_when_it_cannot(tmp_path: Path) -> None:
    reading = minimize(statusline_payload(**LIMITS), now=NOW - 30)
    calls: list[str] = []
    _oauth_rest_until.clear()

    def working(token: str) -> list[dict]:
        calls.append(token)
        return [{"label": "5-hour", "utilization": 10.0, "resets_at": NOW + 3600}]

    direct = _collect(working, reading, home=tmp_path)
    assert direct.state is ProviderSourceState.READY
    assert {lane.source_id for lane in direct.lanes} == {"claude-oauth"}

    def limited(token: str) -> list[dict]:
        calls.append(token)
        raise RuntimeError("rate_limit")

    stand_in = _collect(limited, reading, home=tmp_path)
    assert stand_in.state is ProviderSourceState.READY
    assert {lane.source_id for lane in stand_in.lanes} == {"claude-statusline"}
    assert {lane.lane_id: lane.remaining_percent for lane in stand_in.lanes} == {"five-hour": 58.0, "weekly": 39.0}
    assert stand_in.input_tokens == 5
    # The endpoint rests after a 429 while the status line covers for it.
    before = len(calls)
    _collect(limited, reading, home=tmp_path)
    assert len(calls) == before

    # Without a reading the failure stays a failure.
    _oauth_rest_until.clear()
    assert _collect(limited, None, home=tmp_path).state is ProviderSourceState.RATE_LIMITED
    _oauth_rest_until.clear()


def test_the_wire_names_the_stand_in_source() -> None:
    reading = minimize(statusline_payload(**LIMITS), now=NOW)
    snapshot = snapshot_from_reading(reading, observed_at=NOW)
    document = usage_document(ProviderUsageState((snapshot,), NOW, None, False))
    windows = document["providers"][0]["windows"]
    assert {window["source"] for window in windows} == {"claude-statusline"}
    assert document["providers"][0]["quota_source"] is True


def test_a_statusline_frame_never_reaches_hook_processing(tmp_path: Path, monkeypatch) -> None:
    processed: list[HookIngressRequest] = []
    store = StatusLineStore(tmp_path / "reading.json")
    monkeypatch.setattr(source, "SHARED_STORE", store)
    monkeypatch.setattr(source, "source_enabled", lambda now=None: True)
    service = HookIngressService(
        process=processed.append,
        socket_path=tmp_path / "ingress.sock",
        rejection_path=tmp_path / "rejections.jsonl",
        peer_uid_reader=lambda _connection: os.geteuid(),
        epoch=lambda: NOW,
    )
    frame = encode_hook_ingress_request(
        HookIngressRequest(
            "claude",
            str(tmp_path / "claude.jsonl"),
            statusline_payload(**LIMITS),
            ppid=os.getppid() if os.getppid() > 1 else None,
            kind="statusline",
        )
    )
    ours, theirs = socket.socketpair()
    with ours, theirs:
        theirs.sendall(frame)
        theirs.shutdown(socket.SHUT_WR)
        service._handle_connection(ours)
        reply = theirs.recv(64)
    assert decode_hook_ingress_response(reply) is HookIngressDisposition.ACCEPTED
    assert service.wait_idle(timeout_seconds=1.0)
    assert processed == [], "a statusline frame must never become a hook event"
    assert service.snapshot().accepted == 0
    assert store.latest() is not None
    assert service.close(timeout_seconds=1.0)


def test_the_kind_is_only_statusline() -> None:
    with pytest.raises(ValueError):
        HookIngressRequest("claude", "/tmp/claude.jsonl", "{}", kind="something-else")
    with pytest.raises(ValueError):
        HookIngressRequest("claude", "/tmp/claude.jsonl", "{}", kind="statusline", decide_ms=5000)


def test_the_text_is_words_and_numbers() -> None:
    state = {
        "aggregate": {"mode": "working", "needs_you": 1, "active": 2},
        "usage": {"providers": [{"id": "claude", "instance": "default",
                                  "windows": [{"id": "five-hour", "used_pct": 42.0}]}]},
    }
    assert statusline_text(state) == "JR-Bar · 2 working · 1 needs you · 5h 58% left"
    assert statusline_text({"aggregate": {}}) == "JR-Bar · idle"


def test_the_text_file_follows_the_settings(tmp_path: Path) -> None:
    from types import SimpleNamespace

    writer = source.StatusLineTextWriter()
    state = {"aggregate": {"active": 1}}
    off = SimpleNamespace(claude_statusline_source=False, statusline_text_enabled=True)
    assert writer.write(state, tmp_path, settings=off) is None
    assert not (tmp_path / "statusline.txt").exists()
    on = SimpleNamespace(claude_statusline_source=True, statusline_text_enabled=True)
    writer.write(state, tmp_path, settings=on)
    assert (tmp_path / "statusline.txt").read_text() == "JR-Bar · 1 working\n"
    quiet = SimpleNamespace(claude_statusline_source=True, statusline_text_enabled=False)
    writer.write(state, tmp_path, settings=quiet)
    assert (tmp_path / "statusline.txt").read_text() == ""
