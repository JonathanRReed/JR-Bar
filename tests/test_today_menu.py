"""The Today section: readable calendar/reminders, honest gaps."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from jrbar.today_menu import (
    TodayFeed,
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


def test_reminder_lines_read_the_tuple_contract(monkeypatch) -> None:
    """fetch_due delivers (identifier, title) tuples -- a consumer looking
    for a .title() method on each item drops every real reminder and the
    menu reads "Nothing due" forever."""
    from jrbar import reminders_watch

    def fake_fetch_due(lookback, completion):
        completion([("id-1", "Pay rent"), ("id-2", "Call back"), ("id-3", "")])

    monkeypatch.setattr(reminders_watch, "fetch_due", fake_fetch_due)
    assert TodayFeed()._reminder_lines() == ("Pay rent", "Call back")
