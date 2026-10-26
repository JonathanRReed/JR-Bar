"""One serial daemon loop for timers and worker results, without a GUI host."""
from __future__ import annotations

import heapq
import itertools
import threading
import time
import traceback
from collections import deque


class Timer:
    def __init__(self, interval, target, selector, user_info, repeats):
        self.interval = max(0.0, float(interval))
        self.target = target
        self.selector = selector
        self._user_info = user_info
        self.repeats = repeats
        self.deadline = time.monotonic() + self.interval
        self.valid = True
        self.registered = False

    def userInfo(self):
        return self._user_info

    def invalidate(self):
        self.valid = False
        self.target = None
        self._user_info = None

    def setFireDate_(self, deadline):
        self.deadline = float(deadline)

    @classmethod
    def timerWithTimeInterval_target_selector_userInfo_repeats_(cls, interval, target, selector, info, repeats):
        return cls(interval, target, selector, info, repeats)

    @classmethod
    def scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(cls, interval, target, selector, info, repeats):
        timer = cls(interval, target, selector, info, repeats)
        application().add_timer(timer)
        return timer


class DaemonObject:
    @classmethod
    def alloc(cls):
        return cls()

    def init(self):
        return self

    def performSelectorOnMainThread_withObject_waitUntilDone_(self, selector, payload, wait):
        loop = application()
        def callback():
            return getattr(self, selector.replace(":", "_"))(payload)
        if threading.current_thread() is threading.main_thread() and wait:
            return callback()
        return loop.post(callback, wait=wait)

    def performSelector_withObject_afterDelay_(self, selector, payload, delay):
        timer = Timer(delay, self, selector, payload, False)
        # Delayed selectors receive their payload, unlike timer selectors.
        timer.delayed_selector = True
        application().add_timer(timer)

    @staticmethod
    def cancelPreviousPerformRequestsWithTarget_selector_object_(target, selector, payload):
        loop = application()
        with loop.condition:
            for _, _, timer in loop.timers:
                if timer.target is target and timer.selector == selector and timer.userInfo() == payload:
                    timer.invalidate()
            loop.condition.notify_all()


class DaemonLoop:
    def __init__(self):
        self.condition = threading.Condition()
        self.queue = deque()
        self.timers = []
        self.sequence = itertools.count()
        self.stopping = False
        self.delegate = None

    def setDelegate_(self, delegate):
        self.delegate = delegate

    def setActivationPolicy_(self, _policy):
        pass  # compatibility with callers that used to select a GUI policy

    def terminate_(self, _sender):
        with self.condition:
            self.stopping = True
            self.condition.notify_all()

    def post(self, callback, *, wait=False):
        done = threading.Event() if wait else None
        outcome = []

        def run():
            try:
                outcome.append((True, callback()))
            except BaseException as error:
                outcome.append((False, error))
                if done is None:
                    raise
            finally:
                if done is not None:
                    done.set()

        with self.condition:
            if self.stopping:
                if wait:
                    raise RuntimeError("daemon loop stopped")
                return None
            self.queue.append(run)
            self.condition.notify_all()
        if done is not None:
            # A stopped loop cannot strand a command reader during shutdown.
            while not done.wait(0.1):
                if self.stopping:
                    raise RuntimeError("daemon loop stopped")
            ok, value = outcome[0]
            if not ok:
                raise value
            return value

    def add_timer(self, timer):
        with self.condition:
            if timer.registered or not timer.valid:
                return
            timer.registered = True
            heapq.heappush(self.timers, (timer.deadline, next(self.sequence), timer))
            self.condition.notify_all()

    def addTimer_forMode_(self, timer, _mode):
        self.add_timer(timer)

    @classmethod
    def currentRunLoop(cls):
        return application()

    @classmethod
    def mainRunLoop(cls):
        return application()

    def run(self):
        try:
            self.delegate.applicationDidFinishLaunching_(None)
            while not self.stopping:
                with self.condition:
                    while self.timers and not self.timers[0][2].valid:
                        heapq.heappop(self.timers)
                    now = time.monotonic()
                    if self.queue:
                        callback = self.queue.popleft()
                    elif self.timers and self.timers[0][0] <= now:
                        _, _, timer = heapq.heappop(self.timers)
                        target = timer.target
                        payload = timer.userInfo() if getattr(timer, "delayed_selector", False) else timer
                        def callback():
                            return getattr(target, timer.selector.replace(":", "_"))(payload)
                        timer.registered = False
                        if timer.repeats:
                            timer.deadline = max(timer.deadline + timer.interval, now + 0.001)
                            self.add_timer(timer)
                    else:
                        delay = max(0.0, self.timers[0][0] - now) if self.timers else None
                        self.condition.wait(delay)
                        continue
                try:
                    callback()
                except Exception:
                    traceback.print_exc()
        finally:
            self.stopping = True
            if self.delegate is not None:
                self.delegate.applicationWillTerminate_(None)
            with self.condition:
                for _, _, timer in self.timers:
                    timer.invalidate()
                self.timers.clear()
                self.queue.clear()


_application = None


def application():
    global _application
    if _application is None:
        _application = DaemonLoop()
    return _application


class TimerFactory:
    def create_timer(self, *, delay, interval, target, selector, user_info):
        timer = Timer(interval if interval is not None else delay, target, selector, user_info, interval is not None)
        timer.deadline = time.monotonic() + delay
        return timer

    def register_timer(self, timer, *, common_modes):
        application().add_timer(timer)
