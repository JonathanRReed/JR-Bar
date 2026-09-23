"""One Calendar and Reminders reader: while the app reports what it reads,
the glows use that and the helper never asks EventKit (or for a grant)."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from jrbar import calendar_watch, reminders_watch

NOW = 1_800_000_000.0


@pytest.fixture(autouse=True)
def _clean_module_facts():
    calendar_watch.forget_app_calendar_facts()
    reminders_watch.forget_app_reminders()
    yield
    calendar_watch.forget_app_calendar_facts()
    reminders_watch.forget_app_reminders()


def test_the_apps_next_event_answers_inside_the_lead_window() -> None:
    assert calendar_watch.app_next_event_start(5, now=NOW) is ...
    calendar_watch.adopt_app_calendar_facts(NOW + 240, now=NOW)
    title, start = calendar_watch.app_next_event_start(5, now=NOW)
    assert title == "Event" and start == datetime.fromtimestamp(NOW + 240, tz=timezone.utc)
    # Outside the lead window, or already well under way: nothing to glow for.
    assert calendar_watch.app_next_event_start(3, now=NOW) is None
    calendar_watch.adopt_app_calendar_facts(NOW + 60, now=NOW)
    assert calendar_watch.app_next_event_start(5, now=NOW + 100) is None
    # "Nothing coming" is an answer too, not a fall-back to EventKit.
    calendar_watch.adopt_app_calendar_facts(None, now=NOW)
    assert calendar_watch.app_next_event_start(5, now=NOW) is None
    # A report nobody renewed stops counting.
    assert calendar_watch.app_next_event_start(5, now=NOW + calendar_watch.APP_FACTS_TTL_SECONDS) is ...


def test_next_event_start_never_touches_eventkit_while_the_app_reports(monkeypatch: pytest.MonkeyPatch) -> None:
    def forbidden():
        raise AssertionError("EventKit must not be asked while the app reports")

    monkeypatch.setattr(calendar_watch, "authorization_status", forbidden)
    monkeypatch.setattr("time.time", lambda: NOW)
    calendar_watch.adopt_app_calendar_facts(NOW + 60, now=NOW)
    assert calendar_watch.next_event_start(5)[0] == "Event"


@pytest.mark.parametrize("bad", ["soon", True, NOW + 8 * 24 * 3600, float("nan")])
def test_an_implausible_event_start_is_refused(bad) -> None:
    with pytest.raises(ValueError):
        calendar_watch.adopt_app_calendar_facts(bad, now=NOW)


def test_the_apps_due_reminders_answer_synchronously(monkeypatch: pytest.MonkeyPatch) -> None:
    def forbidden():
        raise AssertionError("EventKit must not be asked while the app reports")

    monkeypatch.setattr(reminders_watch, "authorization_status", forbidden)
    monkeypatch.setattr("time.time", lambda: NOW)
    reminders_watch.adopt_app_reminders(["x-apple-reminder://A", "x-apple-reminder://A", "B"], now=NOW)
    seen: list = []
    reminders_watch.fetch_due(3600, seen.extend)
    assert seen == [("x-apple-reminder://A", "Reminder"), ("B", "Reminder")]
    assert reminders_watch.app_due_reminders(now=NOW + reminders_watch.APP_FACTS_TTL_SECONDS) is ...


@pytest.mark.parametrize("bad", ["A", [3], [""], ["x" * 300], ["id"] * 40])
def test_a_malformed_reminder_list_is_refused(bad) -> None:
    with pytest.raises(ValueError):
        reminders_watch.adopt_app_reminders(bad, now=NOW)


def test_the_presence_command_adopts_both_or_neither(monkeypatch: pytest.MonkeyPatch) -> None:
    from types import SimpleNamespace

    from jrbar import core_power
    from jrbar.core_server import CommandError

    controller = SimpleNamespace(settings=None)
    monkeypatch.setattr(core_power, "_apply_presence", lambda controller, facts: None)
    monkeypatch.setattr(core_power.time, "time", lambda: NOW)
    core_power.set_presence(controller, {"next_event_start": NOW + 120, "reminders_due": ["A"]})
    assert calendar_watch.app_next_event_start(5, now=NOW) is not ...
    assert reminders_watch.app_due_reminders(now=NOW) == [("A", "Reminder")]

    calendar_watch.forget_app_calendar_facts()
    with pytest.raises(CommandError) as error:
        core_power.set_presence(controller, {"next_event_start": NOW + 60, "reminders_due": "A"})
    assert error.value.code == "invalid_args"
    # The good half did not land beside the bad one.
    assert calendar_watch.app_next_event_start(5, now=NOW) is ...
    assert reminders_watch.app_due_reminders(now=NOW) == [("A", "Reminder")]
