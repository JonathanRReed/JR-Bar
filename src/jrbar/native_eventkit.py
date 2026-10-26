"""The calendar and reminder fallback reads through EventKit's native ABI."""
import ctypes as c
import os
from functools import lru_cache

from .native_apple_http import _call, _class, _text
from .native_blocks import completion, discard
from .native_process_info import _Object

EKEntityTypeEvent = 0
EKEntityTypeReminder = 1


@lru_cache(maxsize=1)
def _framework():
    return c.CDLL("/System/Library/Frameworks/EventKit.framework/EventKit")


class Date(_Object):
    @classmethod
    def date(cls):
        result = _call(_class("NSDate"), "date", object_result=True)
        return cls._take(result)

    @classmethod
    def dateWithTimeIntervalSince1970_(cls, seconds):
        result = _call(_class("NSDate"), "dateWithTimeIntervalSince1970:", arguments=(c.c_double,), values=(float(seconds),), object_result=True)
        return cls._take(result)

    @classmethod
    def _take(cls, result):
        pointer, result.pointer = result.pointer, None
        return cls(pointer)

    def timeIntervalSince1970(self):
        return float(_call(self.pointer, "timeIntervalSince1970", c.c_double))


def _rows(array, cls):
    count = int(_call(array, "count", c.c_ulong)) if array else 0
    result = []
    for index in range(count):
        row = _call(array, "objectAtIndex:", arguments=(c.c_ulong,), values=(index,), object_result=True)
        pointer, row.pointer = row.pointer, None
        result.append(cls(pointer))
    return result


class CalendarEvent(_Object):
    def isAllDay(self):
        return bool(_call(self.pointer, "isAllDay", c.c_bool))

    def startDate(self):
        result = _call(self.pointer, "startDate", object_result=True)
        return Date._take(result) if result else None


class Reminder(_Object):
    def isCompleted(self):
        return bool(_call(self.pointer, "isCompleted", c.c_bool))

    def _text(self, selector):
        result = _call(self.pointer, selector, object_result=True)
        return _text(result.pointer) if result else None

    def calendarItemIdentifier(self):
        return self._text("calendarItemIdentifier")

    def title(self):
        return self._text("title")


class EKEventStore(_Object):
    @classmethod
    def alloc(cls):
        _framework()
        return cls(_call(_class("EKEventStore"), "new"))

    def init(self):
        return self

    @classmethod
    def authorizationStatusForEntityType_(cls, entity):
        if os.environ.get("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ:
            return 0
        _framework()
        return int(_call(_class("EKEventStore"), "authorizationStatusForEntityType:", c.c_long, (c.c_long,), (entity,)))

    def _request_access(self, selector, callback):
        if os.environ.get("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ:
            raise RuntimeError("tests cannot request calendar access")
        block = completion(lambda granted, error: callback(bool(granted), error), (c.c_bool, c.c_void_p), b"v@?B@")
        try:
            _call(self.pointer, selector, None, (c.c_void_p,), (c.byref(block),))
        except BaseException:
            discard(block)
            raise

    def requestFullAccessToEventsWithCompletion_(self, callback):
        self._request_access("requestFullAccessToEventsWithCompletion:", callback)

    def requestFullAccessToRemindersWithCompletion_(self, callback):
        self._request_access("requestFullAccessToRemindersWithCompletion:", callback)

    def predicateForEventsWithStartDate_endDate_calendars_(self, start, end, calendars):
        return _call(self.pointer, "predicateForEventsWithStartDate:endDate:calendars:",
            arguments=(c.c_void_p,) * 3, values=(start.pointer, end.pointer, None), object_result=True)

    def eventsMatchingPredicate_(self, predicate):
        result = _call(self.pointer, "eventsMatchingPredicate:", arguments=(c.c_void_p,), values=(predicate.pointer,), object_result=True)
        return _rows(result.pointer, CalendarEvent) if result else []

    def predicateForIncompleteRemindersWithDueDateStarting_ending_calendars_(self, start, end, calendars):
        return _call(self.pointer, "predicateForIncompleteRemindersWithDueDateStarting:ending:calendars:",
            arguments=(c.c_void_p,) * 3, values=(start.pointer, end.pointer, None), object_result=True)

    def fetchRemindersMatchingPredicate_completion_(self, predicate, callback):
        block = completion(lambda rows: callback(_rows(rows, Reminder)), (c.c_void_p,), b"v@?@")
        try:
            return _call(self.pointer, "fetchRemindersMatchingPredicate:completion:", arguments=(c.c_void_p, c.c_void_p),
                values=(predicate.pointer, c.byref(block)), object_result=True)
        except BaseException:
            discard(block)
            raise
