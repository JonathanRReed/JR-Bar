"""A line to the person's phone, through ntfy, when an agent needs them.

ntfy (https://ntfy.sh) turns one HTTPS POST into a notification on a phone.
This module is the only place JR-Bar sends one, and it keeps the promises
the feature was approved on:

* **Off until asked.** ``ntfy_enabled`` is false by default. Nothing is sent
  until the person has entered a topic AND turned it on. The Settings page's
  Test button is the one exception, and only because the person clicked it.
* **Only a fixed line.** The body is "<Agent> needs you" or "<Agent>
  finished", where the agent is the provider's name from JR-Bar's own table
  ("Claude", "Codex"). No prompt text, path, project name, session label,
  token or account id ever reaches this module, so none can leave the Mac.
* **Only when away, by default.** ``ntfy_only_when_away`` sends a line only
  while the screen is locked or the Mac has been idle (the same five minutes
  the quiet policy calls away). If JR-Bar cannot tell, it does not send.
* **It never answers anything.** It notifies. A phone cannot approve or deny
  through it, and nothing here reads a reply.
* **The transport is injectable.** Tests hand in a fake and make no request.

The topic is either a bare name (sent to ntfy.sh) or the full https URL of
the person's own ntfy server. A URL must be https, on port 443 or 8443, with
no credentials, query or fragment, and exactly one path segment for the topic.
Redirects are refused.
"""

from __future__ import annotations

import http.client
import ipaddress
import re
import socket
import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from typing import Final
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener

from . import __version__

NTFY_HOST: Final = "ntfy.sh"
ALLOWED_PORTS: Final = frozenset({443, 8443})
REQUEST_TIMEOUT_SECONDS: Final = 8.0
#: The same agent saying the same thing is one line, not a stream.
MIN_REPEAT_SECONDS: Final = 20.0
#: A hard ceiling on lines per hour, whatever the agents do.
MAX_PER_HOUR: Final = 30
#: Idle this long counts as away, like a locked screen (presence.py).
AWAY_IDLE_SECONDS: Final = 300.0

KIND_NEEDS_YOU: Final = "needs_you"
KIND_FINISHED: Final = "finished"
KINDS: Final = (KIND_NEEDS_YOU, KIND_FINISHED)
TEST_MESSAGE: Final = "JR-Bar test: your phone will hear from your agents here."
GENERIC_AGENT: Final = "An agent"

_TOPIC: Final = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")
_LABEL: Final = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._+-]{0,23}\Z")


class Reason:
    """Why an alert did or did not go. Product-owned words, never an error
    string from the network."""

    QUEUED = "queued"
    SENT = "sent"
    OFF = "off"
    NO_TOPIC = "no_topic"
    INVALID_TARGET = "invalid_target"
    AT_THE_MAC = "at_the_mac"
    REPEAT = "repeat"
    BUDGET = "budget"
    UNKNOWN_KIND = "unknown_kind"
    UNREACHABLE = "unreachable"
    REJECTED = "rejected"


_PLAIN: Final = {
    Reason.QUEUED: "Sending a line to your phone.",
    Reason.SENT: "Sent. Your phone should show it in a moment.",
    Reason.OFF: "Phone alerts are off.",
    Reason.NO_TOPIC: "Enter an ntfy topic first.",
    Reason.INVALID_TARGET: (
        "That is not a topic JR-Bar can use. Use a plain topic name, or an https "
        "address ending in one topic."
    ),
    Reason.AT_THE_MAC: "You are at the Mac, so no line was sent.",
    Reason.REPEAT: "The same line was just sent.",
    Reason.BUDGET: "Too many lines this hour, so this one was held back.",
    Reason.UNKNOWN_KIND: "Nothing to send.",
    Reason.UNREACHABLE: "Could not reach the ntfy server.",
    Reason.REJECTED: "The ntfy server refused the line.",
}


@dataclass(frozen=True, slots=True)
class NtfyTarget:
    """Where a line goes: always an https URL ending in one topic."""

    url: str
    host: str


@dataclass(frozen=True, slots=True)
class Outcome:
    sent: bool
    reason: str

    @property
    def message(self) -> str:
        return _PLAIN.get(self.reason, "Nothing to send.")


def parse_target(value: object) -> NtfyTarget | None:
    """A topic name or a full https URL, as a target; ``None`` when it is
    neither. Never resolves a name and never opens a connection."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if _TOPIC.fullmatch(text):
        return NtfyTarget(f"https://{NTFY_HOST}/{text}", NTFY_HOST)
    try:
        parts = urlsplit(text)
        port = parts.port
    except ValueError:
        return None
    host = (parts.hostname or "").lower()
    if (
        parts.scheme.lower() != "https"
        or not host
        or parts.username is not None
        or parts.password is not None
        or parts.query
        or parts.fragment
        or (port is not None and port not in ALLOWED_PORTS)
    ):
        return None
    segments = [segment for segment in parts.path.split("/") if segment]
    if len(segments) != 1 or not _TOPIC.fullmatch(segments[0]):
        return None
    if host == "localhost" or host.endswith(".localhost") or not _public_host(host):
        return None
    netloc = host if port is None else f"{host}:{port}"
    return NtfyTarget(f"https://{netloc}/{segments[0]}", host)


def _public_host(host: str) -> bool:
    """A literal address must be public; a name is the person's own to pick."""
    try:
        address = ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        return True
    return bool(address.is_global)


def agent_label(provider_id: object) -> str:
    """The provider's name from JR-Bar's own table, else "An agent". Never a
    session label or anything the agent said."""
    if isinstance(provider_id, str) and provider_id:
        try:
            from .provider_usage_platform import provider_descriptor

            label = provider_descriptor(provider_id).label.strip()
        except Exception:
            return GENERIC_AGENT
        if _LABEL.fullmatch(label):
            return label
    return GENERIC_AGENT


def message_for(kind: str, provider_id: object) -> str | None:
    """The whole body of a line, or ``None`` for a kind there is no line for."""
    label = agent_label(provider_id)
    if kind == KIND_NEEDS_YOU:
        return f"{label} needs you"
    if kind == KIND_FINISHED:
        return f"{label} finished"
    return None


# --- the transport ------------------------------------------------------------------


class _NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post_ntfy(target: NtfyTarget, body: bytes) -> int | None:
    """One plain POST: https only, no cookies, no credentials, no redirects,
    a short timeout. Returns the HTTP status, or ``None`` when nothing
    answered."""
    request = Request(
        target.url,
        data=body,
        headers={
            "Content-Type": "text/plain; charset=utf-8",
            "Title": "JR-Bar",
            "User-Agent": f"JR-Bar/{__version__}",
        },
        method="POST",
    )
    opener = build_opener(_NoRedirects(), HTTPSHandler())
    try:
        with opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            response.read(4096)
            return int(getattr(response, "status", 200))
    except HTTPError as error:
        return int(error.code)
    except (URLError, OSError, TimeoutError, ValueError):
        return None


class _CancellableConnection(http.client.HTTPSConnection):
    def __init__(self, *args, cancelled: threading.Event, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._cancelled = cancelled

    def connect(self) -> None:
        if self._cancelled.is_set():
            raise OSError("delivery cancelled")
        super().connect()
        if self._cancelled.is_set():
            self.close()
            raise OSError("delivery cancelled")

    def send(self, data) -> None:
        if self._cancelled.is_set():
            raise OSError("delivery cancelled")
        super().send(data)


class _Delivery:
    def __init__(self) -> None:
        self.cancelled = threading.Event()
        self._lock = threading.Lock()
        self._connection: http.client.HTTPSConnection | None = None

    def cancel(self) -> None:
        self.cancelled.set()
        with self._lock:
            connection = self._connection
        if connection is not None:
            if connection.sock is not None:
                try:
                    connection.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            connection.close()

    def post(self, target: NtfyTarget, body: bytes) -> int | None:
        parts = urlsplit(target.url)
        connection = _CancellableConnection(
            parts.hostname, parts.port or 443, timeout=REQUEST_TIMEOUT_SECONDS,
            cancelled=self.cancelled,
        )
        with self._lock:
            if self.cancelled.is_set():
                return None
            self._connection = connection
        try:
            connection.connect()
            if self.cancelled.is_set():
                return None
            connection.request("POST", parts.path, body=body, headers={
                "Content-Type": "text/plain; charset=utf-8",
                "Title": "JR-Bar", "User-Agent": f"JR-Bar/{__version__}",
            })
            response = connection.getresponse()
            response.read(4096)
            return response.status
        except (OSError, http.client.HTTPException, ValueError):
            return None
        finally:
            connection.close()
            with self._lock:
                self._connection = None


Transport = Callable[[NtfyTarget, bytes], "int | None"]


def system_is_away(idle_seconds: float = AWAY_IDLE_SECONDS) -> bool:
    """The screen is locked, or nothing has touched the keyboard or pointer
    for ``idle_seconds``. Only reads: it posts no input. When the answer
    cannot be had, the Mac is not called away."""
    try:
        import Quartz  # type: ignore[import-not-found]
    except ImportError:
        return False
    try:
        session = Quartz.CGSessionCopyCurrentDictionary()
        if session and bool(session.get("CGSSessionScreenIsLocked", False)):
            return True
        idle = Quartz.CGEventSourceSecondsSinceLastEventType(
            Quartz.kCGEventSourceStateCombinedSessionState,
            Quartz.kCGAnyInputEventType,
        )
        return float(idle) >= idle_seconds
    except Exception:
        return False


def _spawn(work: Callable[[], None]) -> None:
    threading.Thread(target=work, name="JRBarPhoneAlert", daemon=True).start()


class PhoneAlerts:
    """Decides whether a line goes, and sends it. One per daemon."""

    def __init__(
        self,
        *,
        transport: Transport = post_ntfy,
        away_probe: Callable[[], bool] = system_is_away,
        clock: Callable[[], float] = time.time,
        spawn: Callable[[Callable[[], None]], None] = _spawn,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._transport = transport
        self._away_probe = away_probe
        self._clock = clock
        self._spawn = spawn
        self._log = log
        self._lock = threading.Lock()
        self._last: dict[tuple[str, str], float] = {}
        self._sent_at: deque[float] = deque()
        self._deliveries: set[_Delivery] = set()

    def cancel(self) -> None:
        with self._lock:
            deliveries = tuple(self._deliveries)
            self._deliveries.clear()
        for delivery in deliveries:
            delivery.cancel()

    @property
    def active_deliveries(self) -> int:
        with self._lock:
            return len(self._deliveries)

    def alert(
        self,
        settings: object,
        kind: str,
        provider_id: object,
        *,
        presence_away: bool = False,
    ) -> Outcome:
        """Send "<Agent> needs you" or "<Agent> finished" if, and only if,
        the person turned phone alerts on with a usable topic and (by default)
        is away. Never blocks: the request goes out on its own thread."""
        if getattr(settings, "ntfy_enabled", False) is not True:
            self.cancel()
            return Outcome(False, Reason.OFF)
        target = parse_target(getattr(settings, "ntfy_topic", ""))
        if target is None:
            topic = getattr(settings, "ntfy_topic", "")
            blank = not (isinstance(topic, str) and topic.strip())
            return Outcome(False, Reason.NO_TOPIC if blank else Reason.INVALID_TARGET)
        message = message_for(kind, provider_id)
        if message is None:
            return Outcome(False, Reason.UNKNOWN_KIND)
        if getattr(settings, "ntfy_only_when_away", True) is not False and not (
            presence_away or self._away_probe()
        ):
            return Outcome(False, Reason.AT_THE_MAC)
        now = self._clock()
        key = (kind, agent_label(provider_id))
        with self._lock:
            previous = self._last.get(key)
            if previous is not None and 0 <= now - previous < MIN_REPEAT_SECONDS:
                return Outcome(False, Reason.REPEAT)
            while self._sent_at and now - self._sent_at[0] >= 3600.0:
                self._sent_at.popleft()
            if len(self._sent_at) >= MAX_PER_HOUR:
                return Outcome(False, Reason.BUDGET)
            self._last[key] = now
            self._sent_at.append(now)
            delivery = _Delivery()
            self._deliveries.add(delivery)
        self._spawn(lambda: self._deliver(target, message, delivery=delivery))
        return Outcome(True, Reason.QUEUED)

    def send_test(self, settings: object) -> Outcome:
        """The Test button: one fixed line, now, whatever the on switch and
        the away condition say, because the person just asked for it. It still
        needs a usable topic, and it waits for the answer."""
        topic = getattr(settings, "ntfy_topic", "")
        if not (isinstance(topic, str) and topic.strip()):
            return Outcome(False, Reason.NO_TOPIC)
        target = parse_target(topic)
        if target is None:
            return Outcome(False, Reason.INVALID_TARGET)
        return self._deliver(target, TEST_MESSAGE)

    def _deliver(self, target: NtfyTarget, message: str, *, delivery: _Delivery | None = None) -> Outcome:
        try:
            if delivery is not None and delivery.cancelled.is_set():
                return Outcome(False, Reason.OFF)
            if delivery is not None and self._transport is post_ntfy:
                status = delivery.post(target, message.encode("utf-8"))
            else:
                status = self._transport(target, message.encode("utf-8"))
        except Exception:
            status = None
        finally:
            if delivery is not None:
                with self._lock:
                    self._deliveries.discard(delivery)
        if delivery is not None and delivery.cancelled.is_set():
            return Outcome(False, Reason.OFF)
        if status is None:
            outcome = Outcome(False, Reason.UNREACHABLE)
        elif 200 <= status < 300:
            outcome = Outcome(True, Reason.SENT)
        else:
            outcome = Outcome(False, Reason.REJECTED)
        if self._log is not None:
            self._log(f"phone alert: {outcome.reason}")
        return outcome
