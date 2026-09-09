"""The Today section: readable calendar/reminders, honest gaps."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sidepulse.today_menu import (
    TodaySnapshot,
    _relative_start,
    project_today_rows,
    today_menu_title,
)


def test_relative_start_phrasing() -> None:
    now = datetime(2026, 8, 21, 18, 0, tzinfo=timezone.utc)
    assert _relative_start(now + timedelta(seconds=30), now) == "now"
    assert _relative_start(now + timedelta(minutes=42), now) == "in 42m"
    later = _relative_start(now + timedelta(hours=3), now)
    assert ":" in later  # clock time past the hour horizon


def test_title_leads_with_the_next_calendar_event() -> None:
    quiet = TodaySnapshot(calendar_line="No events in the next 12 hours")
    assert today_menu_title(quiet) == "Today"

    busy = TodaySnapshot(calendar_line="Standup · in 12m")
    assert today_menu_title(busy) == "Today · Standup · in 12m"


def test_rows_read_in_order() -> None:
    snapshot = TodaySnapshot(
        calendar_line="Standup · in 12m",
        reminder_lines=("Pay rent", "Call back"),
    )
    rows = project_today_rows(snapshot)
    assert rows[0] == ("Next event · Standup · in 12m", False, "calendar")
    assert rows[1][0].startswith("Reminders · Pay rent")
    assert rows[1][2] == "reminders"
    assert rows[-1][2] == "reminders"
    assert not any(alert for _text, alert, _kind in rows)
