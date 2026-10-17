"""A whole-request deadline for the loopback HTTP listeners.

A handler's socket timeout limits one read, so a client that sends a byte
every few seconds holds a connection slot for as long as it likes, and a
listener with a handful of slots then answers nobody. The deadline is for the
part of a request nobody has vouched for yet: it is armed when the connection
is accepted and stands down once the request line and headers have been read
(a body is only read after the token was checked). When it fires it shuts the
socket down, which wakes the handler's blocked read.
"""

from __future__ import annotations

import socket
import threading
from collections.abc import Callable
from typing import Any

#: From accept to the end of the headers. A real client needs milliseconds.
REQUEST_HEADER_DEADLINE_SECONDS = 10.0


class RequestDeadlines:
    def __init__(
        self,
        seconds: float = REQUEST_HEADER_DEADLINE_SECONDS,
        *,
        timer_factory: Callable[..., Any] = threading.Timer,
    ) -> None:
        self._seconds = float(seconds)
        self._timer_factory = timer_factory
        self._lock = threading.Lock()
        self._timers: dict[int, Any] = {}

    def arm(self, request: socket.socket) -> None:
        timer = self._timer_factory(self._seconds, self._hang_up, (request,))
        timer.daemon = True
        with self._lock:
            self._timers[id(request)] = timer
        timer.start()

    def disarm(self, request: object) -> None:
        with self._lock:
            timer = self._timers.pop(id(request), None)
        if timer is not None:
            timer.cancel()

    def _hang_up(self, request: socket.socket) -> None:
        with self._lock:
            if self._timers.pop(id(request), None) is None:
                return
        try:
            request.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
