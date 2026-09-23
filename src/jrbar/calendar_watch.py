"""EventKit calendar access for the "glow before events start" signal.

Bundle-only by nature: macOS presents the Calendars permission prompt
only to a signed app bundle carrying the right usage descriptions
(NSCalendarsFullAccessUsageDescription on macOS 14+), which is exactly
what app_bundle.py builds. Every entry point is wrapped: anything that
can't work right now -- EventKit missing (bare test environments),
access not granted, API drift -- raises CalendarUnavailableError, and
callers treat that as "no calendar signal", never as an app error.
"""

from __future__ import annotations

from datetime import datetime, timezone

AUTH_AUTHORIZED = "authorized"
AUTH_DENIED = "denied"
AUTH_NOT_DETERMINED = "not_determined"


class CalendarUnavailableError(RuntimeError):
    """EventKit can't be used right now; treat as no signal."""


_store = None


def _eventkit():
    try:
        import EventKit

        return EventKit
    except Exception as exc:  # pragma: no cover - environment-specific
        raise CalendarUnavailableError(str(exc)) from exc


def _shared_store():
    global _store
    eventkit = _eventkit()
    if _store is None:
        _store = eventkit.EKEventStore.alloc().init()
    return _store


def authorization_status() -> str:
    eventkit = _eventkit()
    try:
        status = int(
            eventkit.EKEventStore.authorizationStatusForEntityType_(
                eventkit.EKEntityTypeEvent
            )
        )
    except Exception as exc:
        raise CalendarUnavailableError(str(exc)) from exc
    # 0 notDetermined / 1 restricted / 2 denied / 3 fullAccess /
    # 4 writeOnly (macOS 14+). Only full access can read events.
    if status == 3:
        return AUTH_AUTHORIZED
    if status == 0:
        return AUTH_NOT_DETERMINED
    return AUTH_DENIED


def request_access(completion) -> None:
    """Presents the system Calendars prompt; ``completion(granted)`` is
    called on an arbitrary EventKit queue -- dispatch back to the main
    thread before touching any UI."""
    eventkit = _eventkit()
    store = _shared_store()

    def _handler(granted, _error):
        try:
            completion(bool(granted))
        except Exception:
            pass

    if hasattr(store, "requestFullAccessToEventsWithCompletion_"):
        store.requestFullAccessToEventsWithCompletion_(_handler)
    else:  # pragma: no cover - pre-macOS 14 fallback
        store.requestAccessToEntityType_completion_(eventkit.EKEntityTypeEvent, _handler)


# --- the app's reading --------------------------------------------------------
#
# The app already holds the Calendars grant for the notch shelf and reads
# the next event itself; a second EventKit reader in the helper meant a
# second permission prompt and a glow that could disagree with the shelf.
# While the app keeps reporting (``presence``'s ``next_event_start``), the
# glow uses that reading and never touches EventKit here.

#: How long one app report stands before this module falls back to its own
#: EventKit read.
APP_FACTS_TTL_SECONDS = 180.0
#: The furthest ahead a reported start may lie.
MAX_APP_EVENT_AHEAD_SECONDS = 7 * 24 * 60 * 60.0

_app_facts: tuple[float, float | None] | None = None


def adopt_app_calendar_facts(next_start: float | None, *, now: float) -> None:
    """Record the app's next event start (an epoch, or None for "nothing
    coming"). ``ValueError`` for a start that is not a plausible epoch."""
    global _app_facts
    if next_start is not None:
        if isinstance(next_start, bool) or not isinstance(next_start, (int, float)):
            raise ValueError("next_event_start must be an epoch")
        value = float(next_start)
        if value != value or value - now > MAX_APP_EVENT_AHEAD_SECONDS:
            raise ValueError("next_event_start is not a plausible epoch")
        next_start = value
    _app_facts = (float(now), next_start)


def forget_app_calendar_facts() -> None:
    global _app_facts
    _app_facts = None


def app_next_event_start(within_minutes: float, *, now: float):
    """The app's answer to ``next_event_start``: ``(title, start)``, None
    for nothing inside the window, or ``...`` (Ellipsis) when the app has
    not reported recently and EventKit must be asked instead."""
    facts = _app_facts
    if facts is None or not 0.0 <= now - facts[0] < APP_FACTS_TTL_SECONDS:
        return ...
    start = facts[1]
    if start is None or start < now - 30.0 or start - now > max(0.0, float(within_minutes)) * 60.0:
        return None
    return "Event", datetime.fromtimestamp(start, tz=timezone.utc)


def next_event_start(within_minutes: float):
    """(title, start) of the earliest not-yet-started, non-all-day event
    beginning within ``within_minutes``, or None. ``start`` is timezone
    aware (UTC). The app's recent reading wins over EventKit here."""
    import time

    reported = app_next_event_start(within_minutes, now=time.time())
    if reported is not ...:
        return reported
    from Foundation import NSDate

    if authorization_status() != AUTH_AUTHORIZED:
        raise CalendarUnavailableError("calendar access not granted")
    store = _shared_store()
    now = NSDate.date()
    now_timestamp = float(now.timeIntervalSince1970())
    window_end = NSDate.dateWithTimeIntervalSinceNow_(max(0.0, float(within_minutes)) * 60.0)
    try:
        predicate = store.predicateForEventsWithStartDate_endDate_calendars_(
            now, window_end, None
        )
        events = store.eventsMatchingPredicate_(predicate) or []
    except Exception as exc:
        raise CalendarUnavailableError(str(exc)) from exc

    best = None
    for event in events:
        try:
            if event.isAllDay():
                continue
            start = event.startDate()
            if start is None:
                continue
            start_timestamp = float(start.timeIntervalSince1970())
            # The predicate also returns events already in progress;
            # the glow is a WARNING, so only future starts count.
            if start_timestamp < now_timestamp - 30.0:
                continue
            title = str(event.title() or "Event")
        except Exception:
            continue
        if best is None or start_timestamp < best[1]:
            best = (title, start_timestamp)
    if best is None:
        return None
    return best[0], datetime.fromtimestamp(best[1], tz=timezone.utc)
