"""session_usage: per-session model, tokens, cost and context."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from jrbar import session_usage
from jrbar.session_usage import (
    CLAUDE_DEFAULT_CONTEXT,
    CLAUDE_LONG_CONTEXT,
    session_usage_document,
)

SID = "11111111-2222-3333-4444-555555555555"
CODEX_SID = "99999999-8888-7777-6666-555555555555"


@pytest.fixture(autouse=True)
def _fresh_cache():
    session_usage.reset_cache()
    yield
    session_usage.reset_cache()


def _write(path, rows, mode="w"):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open(mode) as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")


def _assistant(message_id, *, model="claude-opus-4-5-20251101", at="2026-09-13T10:00:05Z",
               inp=10, cache_read=1000, cache_create=100, out=50, sidechain=False):
    return {
        "type": "assistant",
        "timestamp": at,
        "isSidechain": sidechain,
        "message": {
            "id": message_id,
            "model": model,
            "role": "assistant",
            "content": [{"type": "text", "text": "ok"}],
            "usage": {
                "input_tokens": inp,
                "cache_read_input_tokens": cache_read,
                "cache_creation_input_tokens": cache_create,
                "output_tokens": out,
            },
        },
    }


def _claude_path(tmp_path):
    return tmp_path / ".claude" / "projects" / "-tmp-work" / f"{SID}.jsonl"


def test_claude_counts_each_message_once_and_names_the_model(tmp_path):
    path = _claude_path(tmp_path)
    first = _assistant("msg_1")
    # Claude Code writes one line per content block, repeating the usage.
    _write(path, [first, first, _assistant("msg_2", at="2026-09-13T10:01:00Z", out=70)])

    doc, gap = session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)

    assert gap is None
    assert doc["model"] == "claude-opus-4-5-20251101"
    assert doc["tokens"] == {"input": 20, "cached_input": 2000, "cache_creation": 200, "output": 120}
    assert doc["turns"] == 2
    assert doc["models"] == {"claude-opus-4-5-20251101": 2340}
    # Opus 4.5 is $5/$25; cache reads 0.1x, writes 1.25x.
    expected = (20 * 5 + 2000 * 0.5 + 200 * 6.25 + 120 * 25) / 1_000_000
    assert doc["estimated_cost_usd"] == pytest.approx(expected, abs=1e-4)
    assert doc["cost_estimated"] is False
    assert doc["context_tokens"] == 10 + 1000 + 100
    assert doc["context_window"] == CLAUDE_DEFAULT_CONTEXT
    assert doc["context_window_source"] == "inferred"


def test_claude_reads_only_what_was_appended(tmp_path):
    path = _claude_path(tmp_path)
    _write(path, [_assistant("msg_1")])
    doc, _ = session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)
    assert doc["turns"] == 1

    _write(path, [_assistant("msg_2", at="2026-09-13T10:02:00Z")], mode="a")
    doc, _ = session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)
    assert doc["turns"] == 2
    assert session_usage.cache_size() == 1


def test_a_partial_trailing_line_waits_for_its_newline(tmp_path):
    path = _claude_path(tmp_path)
    _write(path, [_assistant("msg_1")])
    with path.open("a") as handle:
        handle.write(json.dumps(_assistant("msg_2"))[:40])
    doc, _ = session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)
    assert doc["turns"] == 1

    with path.open("a") as handle:
        handle.write(json.dumps(_assistant("msg_2"))[40:] + "\n")
    doc, _ = session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)
    assert doc["turns"] == 2


def test_a_replaced_file_is_read_from_the_start(tmp_path):
    path = _claude_path(tmp_path)
    _write(path, [_assistant("msg_1"), _assistant("msg_2")])
    session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)
    path.unlink()
    _write(path, [_assistant("msg_9", out=5)])
    doc, _ = session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)
    assert doc["turns"] == 1
    assert doc["tokens"]["output"] == 5


def test_sidechain_turns_count_tokens_but_not_context(tmp_path):
    path = _claude_path(tmp_path)
    _write(path, [
        _assistant("msg_1", inp=5, cache_read=50_000, cache_create=0),
        _assistant("msg_2", inp=1, cache_read=10, cache_create=0, sidechain=True),
    ])
    doc, _ = session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)
    assert doc["context_tokens"] == 50_005
    assert doc["turns"] == 2


def test_a_prompt_past_the_default_window_infers_long_context(tmp_path):
    path = _claude_path(tmp_path)
    _write(path, [_assistant("msg_1", cache_read=350_000)])
    doc, _ = session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)
    assert doc["context_window"] == CLAUDE_LONG_CONTEXT


def test_an_unknown_model_is_priced_as_a_labelled_stand_in(tmp_path):
    path = _claude_path(tmp_path)
    _write(path, [_assistant("msg_1", model="claude-mystery-9")])
    doc, _ = session_usage.session_usage("claude", SID, cwd="/tmp/work", home=tmp_path)
    assert doc["estimated_cost_usd"] is not None
    assert doc["cost_estimated"] is True


def test_tokens_since_counts_only_turns_inside_the_window(tmp_path):
    path = _claude_path(tmp_path)
    _write(path, [
        _assistant("msg_1", at="2026-09-13T08:00:00Z", inp=1, cache_read=0, cache_create=0, out=1),
        _assistant("msg_2", at="2026-09-13T11:00:00Z", inp=10, cache_read=0, cache_create=0, out=10),
    ])
    since = session_usage._epoch("2026-09-13T10:00:00Z")
    doc, _ = session_usage.session_usage("claude", SID, cwd="/tmp/work", since=since, home=tmp_path)
    assert doc["tokens_since"] == 20


def _codex_rows():
    def tokens(at, total, last, window=258_400):
        return {
            "type": "event_msg",
            "timestamp": at,
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {"input_tokens": total[0], "cached_input_tokens": total[1],
                                          "output_tokens": total[2]},
                    "last_token_usage": {"input_tokens": last[0], "cached_input_tokens": last[1],
                                         "output_tokens": last[2]},
                    "model_context_window": window,
                },
            },
        }

    return [
        {"type": "turn_context", "timestamp": "2026-09-13T10:00:00Z",
         "payload": {"type": "turn_context", "model": "gpt-5.6-sol"}},
        tokens("2026-09-13T10:00:05Z", (1000, 800, 50), (1000, 800, 50)),
        # Codex re-emits the same cumulative row: the same turn, not new work.
        tokens("2026-09-13T10:00:06Z", (1000, 800, 50), (1000, 800, 50)),
        tokens("2026-09-13T10:01:00Z", (3000, 2500, 90), (2000, 1700, 40)),
    ]


def test_codex_uses_turn_deltas_and_the_reported_window(tmp_path):
    path = tmp_path / ".codex" / "sessions" / "2026" / "09" / f"rollout-{CODEX_SID}.jsonl"
    _write(path, _codex_rows())

    doc, gap = session_usage.session_usage("codex", CODEX_SID, home=tmp_path)

    assert gap is None
    assert doc["model"] == "gpt-5.6-sol"
    assert doc["turns"] == 2
    # Cache reads are a subset of Codex's input_tokens.
    assert doc["tokens"] == {"input": 500, "cached_input": 2500, "cache_creation": 0, "output": 90}
    assert doc["context_tokens"] == 2000
    assert doc["context_window"] == 258_400
    assert doc["context_window_source"] == "reported"
    assert doc["estimated_cost_usd"] is not None


def test_codex_without_deltas_derives_them_from_the_cumulative_total(tmp_path):
    path = tmp_path / ".codex" / "sessions" / f"rollout-{CODEX_SID}.jsonl"
    rows = _codex_rows()
    for row in rows:
        info = row.get("payload", {}).get("info")
        if isinstance(info, dict):
            info.pop("last_token_usage")
    _write(path, rows)
    doc, _ = session_usage.session_usage("codex", CODEX_SID, home=tmp_path)
    assert doc["tokens"]["output"] == 90
    assert doc["turns"] == 2


def test_gaps_are_named_not_zeroed(tmp_path):
    reply = session_usage_document(
        [("a", "grok", SID, None), ("b", "claude", SID, "/nowhere"), ("c", None, None, None)],
        home=tmp_path,
    )
    assert reply["sessions"] == {}
    assert reply["gaps"] == {"a": "unsupported_provider", "b": "transcript_not_found", "c": "not_found"}
    assert reply["pricing"]["semantics"] == "api_equivalent_estimate"


def test_command_resolves_roster_ids_and_names_remote_rows(tmp_path, monkeypatch):
    from jrbar.core_runtime import _cmd_session_usage

    _write(_claude_path(tmp_path), [_assistant("msg_1")])
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    status = SimpleNamespace(agent_id="claude:1", provider="claude", session_id=SID, cwd="/tmp/work")
    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(statuses=[status], stale_statuses=[]),
    )

    reply = _cmd_session_usage(controller, {"ids": ["claude:1", "remote:studio:claude:x", "ghost"]})

    assert reply["sessions"]["claude:1"]["model"] == "claude-opus-4-5-20251101"
    assert reply["gaps"] == {"remote:studio:claude:x": "remote", "ghost": "not_found"}


def test_command_refuses_an_empty_request():
    from jrbar.core_runtime import CommandError, _cmd_session_usage

    with pytest.raises(CommandError) as error:
        _cmd_session_usage(SimpleNamespace(last_snapshot=None), {"ids": []})
    assert error.value.code == "invalid_value"
