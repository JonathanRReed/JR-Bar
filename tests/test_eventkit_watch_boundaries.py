"""Calendar and reminder reads use fake stores and dates only."""

from __future__ import annotations

from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from jrbar import calendar_watch, reminders_watch

NOW = 1_800_000_000.0


class FakeDate:
    def __init__(self, timestamp):
        self.timestamp = timestamp

    def timeIntervalSince1970(self):
        return self.timestamp

    @classmethod
    def date(cls):
        return cls(NOW)

    @classmethod
    def dateWithTimeIntervalSince1970_(cls, timestamp):
        return cls(timestamp)


class FakeEvent:
    def __init__(self, start, title="Meeting", all_day=False):
        self.start = start
        self.name = title
        self.all_day = all_day

    def isAllDay(self):
        return self.all_day

    def startDate(self):
        return None if self.start is None else FakeDate(self.start)

    def title(self):
        return self.name


class FakeReminder:
    def __init__(self, identifier, completed=False):
        self.identifier = identifier
        self.completed = completed

    def isCompleted(self):
        return self.completed

    def calendarItemIdentifier(self):
        return self.identifier

    def title(self):
        return "Reminder"


class FakeStore:
    def __init__(self):
        self.events = []
        self.bounds = None
        self.callback = None

    def predicateForEventsWithStartDate_endDate_calendars_(self, start, end, calendars):
        self.bounds = (start.timestamp, end.timestamp, calendars)
        return "events"

    def eventsMatchingPredicate_(self, predicate):
        assert predicate == "events"
        return self.events

    def predicateForIncompleteRemindersWithDueDateStarting_ending_calendars_(self, start, end, calendars):
        self.bounds = (start.timestamp, end.timestamp, calendars)
        return "reminders"

    def fetchRemindersMatchingPredicate_completion_(self, predicate, completion):
        assert predicate == "reminders"
        self.callback = completion


@pytest.fixture(autouse=True)
def fake_eventkit(monkeypatch):
    calendar_watch.forget_app_calendar_facts()
    reminders_watch.forget_app_reminders()
    store = FakeStore()
    status = [3]
    eventkit = SimpleNamespace(
        EKEntityTypeEvent=0,
        EKEntityTypeReminder=1,
        EKEventStore=SimpleNamespace(authorizationStatusForEntityType_=lambda _entity: status[0]),
    )
    monkeypatch.setattr(calendar_watch, "_eventkit", lambda: eventkit)
    monkeypatch.setattr(reminders_watch, "_eventkit", lambda: eventkit)
    monkeypatch.setattr(calendar_watch, "_shared_store", lambda: store)
    monkeypatch.setattr(reminders_watch, "_shared_store", lambda: store)
    monkeypatch.setattr("jrbar.native_eventkit.Date", FakeDate)
    monkeypatch.setattr("time.time", lambda: NOW)
    yield store, status
    calendar_watch.forget_app_calendar_facts()
    reminders_watch.forget_app_reminders()


@pytest.mark.parametrize("watch", [calendar_watch, reminders_watch])
@pytest.mark.parametrize("status, expected", [(0, "not_determined"), (1, "denied"), (2, "denied"),
                                               (3, "authorized"), (4, "denied"), (99, "denied")])
def test_only_full_access_can_read(watch, status, expected, fake_eventkit):
    store, permission = fake_eventkit
    permission[0] = status
    assert watch.authorization_status() == expected
    if expected != "authorized":
        error = watch.CalendarUnavailableError if watch is calendar_watch else watch.RemindersUnavailableError
        with pytest.raises(error, match="access not granted"):
            if watch is calendar_watch:
                watch.next_event_start(5)
            else:
                watch.fetch_due(120, lambda _items: pytest.fail("denied read completed"))
        assert store.bounds is None


def test_calendar_uses_exact_window_and_skips_bad_or_all_day_dates(fake_eventkit):
    store, _status = fake_eventkit
    store.events = [FakeEvent(float("nan")), FakeEvent(float("inf")), FakeEvent(None),
                    FakeEvent(NOW - 31), FakeEvent(NOW + 301), FakeEvent(NOW + 5, all_day=True),
                    FakeEvent(NOW + 300, "Boundary"), FakeEvent(NOW + 30, "Earliest")]
    assert calendar_watch.next_event_start(5) == (
        "Earliest", datetime.fromtimestamp(NOW + 30, tz=timezone.utc))
    assert store.bounds == (NOW, NOW + 300, None)
    store.events = [FakeEvent(NOW + 300, "Boundary")]
    assert calendar_watch.next_event_start(5)[0] == "Boundary"
    assert calendar_watch.next_event_start(0) is None


def test_calendar_retains_thirty_second_start_grace(fake_eventkit):
    store, _status = fake_eventkit
    store.events = [FakeEvent(NOW - 30, "Just started")]
    assert calendar_watch.next_event_start(5)[0] == "Just started"
    calendar_watch.adopt_app_calendar_facts(NOW - 30, now=NOW)
    assert calendar_watch.app_next_event_start(5, now=NOW) is not None
    assert calendar_watch.app_next_event_start(5, now=NOW + 0.1) is None


@pytest.mark.parametrize("invalid", [float("nan"), float("inf"), -float("inf"), "bad", None, 10**1000])
def test_invalid_windows_never_reach_eventkit(invalid, fake_eventkit):
    store, _status = fake_eventkit
    with pytest.raises(calendar_watch.CalendarUnavailableError, match="invalid calendar lead time"):
        calendar_watch.next_event_start(invalid)
    with pytest.raises(reminders_watch.RemindersUnavailableError, match="invalid reminder lookback"):
        reminders_watch.fetch_due(invalid, lambda _items: pytest.fail("invalid read completed"))
    assert store.bounds is None


@pytest.mark.parametrize("watch", [calendar_watch, reminders_watch])
def test_native_date_setup_failures_use_unavailable_contract(watch, monkeypatch):
    monkeypatch.setattr("jrbar.native_eventkit.Date", None)
    error = watch.CalendarUnavailableError if watch is calendar_watch else watch.RemindersUnavailableError
    with pytest.raises(error):
        if watch is calendar_watch:
            watch.next_event_start(5)
        else:
            watch.fetch_due(120, lambda _items: pytest.fail("failed read completed"))


@pytest.mark.parametrize("reported", [[], ["Current"]])
def test_fresh_app_reminders_replace_pending_eventkit_results(reported, fake_eventkit):
    store, _status = fake_eventkit
    seen = []
    reminders_watch.fetch_due(120, seen.append)
    assert store.bounds == (NOW - 120, NOW, None)
    reminders_watch.adopt_app_reminders(reported, now=NOW)
    store.callback([FakeReminder("Old")])
    assert seen == [[(identifier, "Reminder") for identifier in reported]]


@pytest.mark.parametrize("reported", [None, NOW + 60])
@pytest.mark.parametrize("permission_after_read", [2, 3])
def test_fresh_app_calendar_facts_replace_pending_eventkit_results(
    reported, permission_after_read, fake_eventkit, monkeypatch,
):
    store, status = fake_eventkit

    def finish_read(predicate):
        assert predicate == "events"
        status[0] = permission_after_read
        calendar_watch.adopt_app_calendar_facts(reported, now=NOW)
        return [FakeEvent(NOW + 120, "Old")]

    monkeypatch.setattr(store, "eventsMatchingPredicate_", finish_read)

    result = calendar_watch.next_event_start(5)

    expected = None if reported is None else ("Event", datetime.fromtimestamp(reported, tz=timezone.utc))
    assert result == expected


@pytest.mark.parametrize("permission_after_read", [0, 1, 2, 4])
def test_calendar_access_revoked_during_read_discards_fallback_result(
    permission_after_read, fake_eventkit, monkeypatch,
):
    store, status = fake_eventkit

    def finish_read(predicate):
        assert predicate == "events"
        status[0] = permission_after_read
        return [FakeEvent(NOW + 120, "Old")]

    monkeypatch.setattr(store, "eventsMatchingPredicate_", finish_read)

    with pytest.raises(calendar_watch.CalendarUnavailableError, match="access not granted"):
        calendar_watch.next_event_start(5)


def test_reminders_skip_completed_and_duplicate_identifiers(fake_eventkit):
    store, _status = fake_eventkit
    seen = []
    reminders_watch.fetch_due(0, seen.append)
    assert store.bounds == (NOW, NOW, None)
    store.callback([FakeReminder("Done", completed=True), FakeReminder("A"), FakeReminder("A"),
                    FakeReminder("")])
    assert seen == [[("A", "Reminder")]]


@pytest.mark.parametrize("revoked", [False, True])
def test_failed_or_revoked_async_reads_do_not_claim_empty_results(revoked, fake_eventkit):
    store, status = fake_eventkit
    seen = []
    reminders_watch.fetch_due(120, seen.append)
    if revoked:
        status[0] = 2
        store.callback([FakeReminder("Private")])
    else:
        store.callback(None)
    assert seen == []


@pytest.mark.parametrize("invalid", [float("nan"), float("inf"), -float("inf")])
def test_app_reports_reject_nonfinite_dates_without_replacing_good_facts(invalid):
    calendar_watch.adopt_app_calendar_facts(NOW + 60, now=NOW)
    reminders_watch.adopt_app_reminders(["Good"], now=NOW)
    with pytest.raises(ValueError):
        calendar_watch.adopt_app_calendar_facts(invalid, now=NOW)
    with pytest.raises(ValueError):
        calendar_watch.adopt_app_calendar_facts(None, now=invalid)
    with pytest.raises(ValueError):
        reminders_watch.adopt_app_reminders([], now=invalid)
    assert calendar_watch.app_next_event_start(5, now=NOW)[1].timestamp() == NOW + 60
    assert reminders_watch.app_due_reminders(now=NOW) == [("Good", "Reminder")]


@pytest.mark.parametrize("invalid", [10**1000, -(10**1000), -1e100])
def test_app_calendar_date_bombs_raise_value_error(invalid):
    with pytest.raises(ValueError, match="plausible epoch"):
        calendar_watch.adopt_app_calendar_facts(invalid, now=NOW)
