import json
import sys
from datetime import datetime, timezone

from jrbar.collector import AgentMonitor
from jrbar.models import HookEvent


def test_shared_metadata_keeps_the_same_conservative_byte_budget():
    from jrbar.collector import _transcript_retained_bytes

    record = HookEvent("claude", datetime(2026, 10, 25, tzinfo=timezone.utc), "Stop",
                       {"metadata": [{"message": "synthetic message"}]})
    one = (record,)
    two = (record, record)
    one_record_bytes = _transcript_retained_bytes(one) - sys.getsizeof(one)
    assert _transcript_retained_bytes(two) == sys.getsizeof(two) + 2 * one_record_bytes


def test_metadata_cache_drops_tool_output_and_enforces_total_byte_bound(tmp_path):
    monitor = AgentMonitor(sources=(), transcript_records_cache_max_bytes=4096)
    for offset in range(4):
        path = tmp_path / f"{offset}.jsonl"
        path.write_text("{}")

        def parser(_path):
            yield HookEvent(
                "claude",
                datetime(2026, 10, 25, tzinfo=timezone.utc),
                "PostToolUse",
                {"source": "claude-transcripts", "tool_response": "x" * 100_000},
            )

        records = monitor._cached_transcript_records("claude", path, parser)
        assert "tool_response" not in records[0].raw
    assert sum(row.retained_bytes for row in monitor._transcript_records_cache.values()) <= 4096


def test_a_single_large_message_is_served_but_never_retained(tmp_path):
    monitor = AgentMonitor(sources=(), transcript_records_cache_max_bytes=1024)
    path = tmp_path / "one.jsonl"
    path.write_text("{}")
    text = "synthetic " * 1000
    records = monitor._cached_transcript_records(
        "claude",
        path,
        lambda _: [
            HookEvent(
                "claude",
                datetime(2026, 10, 25, tzinfo=timezone.utc),
                "Stop",
                {"last_assistant_message": text},
                message=text,
            )
        ],
    )
    assert records[0].message == text
    assert monitor._transcript_records_cache == {}


def test_incremental_byte_estimates_match_full_estimates_and_retire_old_records():
    from jrbar.collector import _transcript_cached_bytes, _transcript_retained_bytes

    stamp = datetime(2026, 10, 25, tzinfo=timezone.utc)
    shared = {"metadata": [{"message": "synthetic message"}]}
    first = HookEvent("claude", stamp, "Stop", shared)
    second = HookEvent("claude", stamp, "Stop", shared)
    previous = {}
    for records in [(first,), (first, second, first), (second,), ()]:
        count, previous = _transcript_cached_bytes(records, previous)
        assert count == _transcript_retained_bytes(records)
        assert set(previous) == {id(record) for record in records}


def test_four_busy_transcripts_fit_the_cache_with_long_provider_paths(tmp_path):
    from jrbar.collector import iter_claude_transcript_file

    root = tmp_path / ("x" * 120)
    root.mkdir()
    monitor = AgentMonitor(sources=())
    for session in range(4):
        path = root / f"00000000-0000-4000-8000-{session:012d}.jsonl"
        rows = [json.dumps({
            "type": "assistant", "timestamp": "2026-10-25T12:00:00Z",
            "sessionId": f"00000000-0000-4000-8000-{session:012d}", "cwd": "/synthetic/" + "x" * 80,
            "message": {"id": str(turn), "role": "assistant", "model": "synthetic-model",
                        "stop_reason": "end_turn", "content": [{"type": "text", "text": "Synthetic work"}],
                        "usage": {"input_tokens": 100, "output_tokens": 20}},
        }) for turn in range(500)]
        path.write_text("\n".join(rows) + "\n")
        monitor._cached_transcript_records("claude", path, iter_claude_transcript_file)
    assert len(monitor._transcript_records_cache) == 4
    assert sum(entry.retained_bytes for entry in monitor._transcript_records_cache.values()) <= 8 * 1024 * 1024
