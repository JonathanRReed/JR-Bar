"""Per-day session counts from the hook ledgers, and where each ledger starts.

Ledgers are compacted to their newest events, so a count can only speak for
the days the ledger still holds. Everything here uses synthetic ledgers in a
temporary folder and explicit epochs: no clocks, no sleeps.
"""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

from jrbar.session_history import (
    TRANSCRIPT_SESSION_PROVIDERS,
    ledger_first_event_epochs,
    ledger_session_days,
)


def _noon(year: int, month: int, day: int) -> float:
    return datetime(year, month, day, 12, 0, 0).timestamp()


def _event(
    provider: str,
    name: str,
    epoch: object,
    work: str | None = None,
) -> dict:
    row: dict[str, object] = {
        "provider_id": provider,
        "event_name": name,
        "occurred_at_epoch": epoch,
    }
    if work is not None:
        row["provider_work_id"] = work
    return row


def _write_ledger(root: Path, provider: str, rows: list, *, tail: str = "") -> Path:
    path = root / f"{provider}.jsonl"
    path.write_text(
        "".join(json.dumps(row) + "\n" for row in rows) + tail, encoding="utf-8"
    )
    return path


# --- ledger_session_days ------------------------------------------------------


def test_session_days_count_distinct_work_ids_per_day(tmp_path: Path) -> None:
    day = _noon(2026, 9, 10)
    _write_ledger(
        tmp_path,
        "devin",
        [
            _event("devin", "session_start", day, "w1"),
            _event("devin", "session_start", day + 60, "w1"),  # a replay
            _event("devin", "session_start", day + 120, "w2"),
            _event("devin", "session_start", _noon(2026, 9, 11), "w3"),
            _event("devin", "post_tool_use", day, "w1"),  # not a session start
        ],
    )

    counts = ledger_session_days(tmp_path, since_epoch=0.0, provider_ids=("devin",))

    assert counts == {"devin": {"2026-09-10": 2, "2026-09-11": 1}}


def test_session_days_drop_events_before_the_window(tmp_path: Path) -> None:
    _write_ledger(
        tmp_path,
        "devin",
        [
            _event("devin", "session_start", _noon(2026, 9, 1), "old"),
            _event("devin", "session_start", _noon(2026, 9, 10), "new"),
        ],
    )

    counts = ledger_session_days(
        tmp_path, since_epoch=_noon(2026, 9, 5), provider_ids=("devin",)
    )

    assert counts == {"devin": {"2026-09-10": 1}}


def test_session_days_skip_foreign_torn_and_boolean_records(tmp_path: Path) -> None:
    day = _noon(2026, 9, 10)
    _write_ledger(
        tmp_path,
        "devin",
        [
            _event("devin", "session_start", day, "mine"),
            _event("grok", "session_start", day, "foreign"),
            _event("devin", "session_start", True, "boolean"),
            _event("devin", "session_start", "soon", "text"),
            _event("devin", "session_start", float("nan"), "nan"),
            _event("devin", "session_start", 1e30, "huge"),
            "not an object",
        ],
        tail='{"provider_id": "devin", "event_name": "session_st',  # torn last line
    )

    counts = ledger_session_days(tmp_path, since_epoch=0.0, provider_ids=("devin",))

    assert counts == {"devin": {"2026-09-10": 1}}


def test_session_days_leave_claude_and_codex_to_their_transcripts(tmp_path: Path) -> None:
    day = _noon(2026, 9, 10)
    for provider in sorted(TRANSCRIPT_SESSION_PROVIDERS):
        _write_ledger(tmp_path, provider, [_event(provider, "session_start", day, "w1")])

    counts = ledger_session_days(
        tmp_path, since_epoch=0.0, provider_ids=("claude", "codex")
    )

    assert counts == {}


def test_session_days_skip_a_ledger_over_the_size_bound(tmp_path: Path) -> None:
    path = tmp_path / "devin.jsonl"
    path.write_bytes(b"x" * (8 * 1024 * 1024 + 1))

    assert ledger_session_days(tmp_path, since_epoch=0.0, provider_ids=("devin",)) == {}
    assert ledger_first_event_epochs(tmp_path, provider_ids=("devin",)) == {}


# --- ledger_first_event_epochs ------------------------------------------------


def test_first_event_is_the_earliest_event_of_any_name(tmp_path: Path) -> None:
    early = _noon(2026, 9, 8)
    _write_ledger(
        tmp_path,
        "devin",
        [
            _event("devin", "session_start", _noon(2026, 9, 9), "w1"),
            _event("devin", "prompt_submit", early, "w0"),
            _event("devin", "post_tool_use", _noon(2026, 9, 12), "w1"),
        ],
    )

    # A session already running when the log was cut has no session_start
    # left, so the log's start is the earliest event of any kind.
    assert ledger_first_event_epochs(tmp_path, provider_ids=("devin",)) == {"devin": early}


def test_first_event_ignores_foreign_boolean_and_non_numeric_records(tmp_path: Path) -> None:
    real = _noon(2026, 9, 10)
    _write_ledger(
        tmp_path,
        "devin",
        [
            _event("grok", "session_start", 1.0, "foreign"),
            _event("devin", "session_start", True, "boolean"),
            _event("devin", "session_start", "1", "text"),
            _event("devin", "session_start", None, "missing"),
            _event("devin", "session_start", float("nan"), "nan"),
            _event("devin", "session_start", real, "real"),
            "not an object",
        ],
        tail='{"provider_id": "devin", "occurred_at_epoch": 1',
    )

    assert ledger_first_event_epochs(tmp_path, provider_ids=("devin",)) == {"devin": real}


def test_first_event_skips_missing_files_and_transcript_providers(tmp_path: Path) -> None:
    _write_ledger(tmp_path, "claude", [_event("claude", "session_start", 5.0, "w")])
    _write_ledger(tmp_path, "codex", [_event("codex", "session_start", 5.0, "w")])

    assert (
        ledger_first_event_epochs(tmp_path, provider_ids=("claude", "codex", "devin"))
        == {}
    )


def test_first_event_does_not_depend_on_any_window(tmp_path: Path) -> None:
    first = _noon(2026, 1, 2)
    _write_ledger(
        tmp_path,
        "devin",
        [
            _event("devin", "session_start", first, "w1"),
            _event("devin", "session_start", _noon(2026, 9, 10), "w2"),
        ],
    )

    # The window trims the session counts, never where the ledger starts.
    days = ledger_session_days(
        tmp_path, since_epoch=_noon(2026, 9, 1), provider_ids=("devin",)
    )
    assert days == {"devin": {"2026-09-10": 1}}
    assert ledger_first_event_epochs(tmp_path, provider_ids=("devin",)) == {"devin": first}
