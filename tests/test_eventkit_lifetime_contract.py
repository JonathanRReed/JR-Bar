"""Keep native EventKit ownership and cancellation out of view lifecycles."""

from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "app" / "Sources" / "JRBarApp"


def test_one_native_store_constructor_and_no_fetch_cancellation() -> None:
    constructors = []
    cancellations = []
    for path in APP.rglob("*.swift"):
        source = path.read_text()
        if "EKEventStore()" in source:
            constructors.append(str(path.relative_to(APP)))
            assert source.count("EKEventStore()") == 1
        if "cancelFetchRequest(" in source:
            cancellations.append(str(path.relative_to(APP)))
    assert constructors == ["ShelfEventStore.swift"]
    assert cancellations == []


def test_permission_actions_use_the_shared_reader() -> None:
    source = (APP / "Setup" / "SetupModel.swift").read_text()
    assert "requestCalendar(reader: ShelfCalendarReader = .shared)" in source
    assert "requestReminders(reader: ShelfCalendarReader = .shared)" in source
    assert "await reader.requestAccess()" in source
    assert "await reader.requestAccess(to: .reminder)" in source
