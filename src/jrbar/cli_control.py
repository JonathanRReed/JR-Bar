"""Control verbs for the running JR-Bar: ``jrbar status | quiet | snooze |
set | get | confetti`` over the core socket, and ``jrbar toggle | awake |
open`` through the app's ``jrbar://`` links.

The install and diagnose commands already existed; nothing let a script,
a Raycast Script Command, an Alfred workflow, cron or a Makefile *drive*
the monitor. These are user-invoked verbs on the same protocol the app
speaks (docs/CORE-PROTOCOL.md): one connection, the command, the reply,
done. They are not the retired inbound signal API, and none answers an
ask -- Approve and Deny stay where the ask is on screen.

Daemon-side verbs need the core running and say so plainly when it is
not. App-side verbs (the quick toggles, keep-awake) hand a ``jrbar://``
link to ``/usr/bin/open -g``, so they run in the app exactly as a click
would, without bringing it to the front.
"""

from __future__ import annotations

import argparse
import json
import re
import socket
import subprocess
import sys
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode

VERBS = frozenset(
    {"status", "quiet", "snooze", "set", "get", "confetti", "toggle", "awake", "deepwork", "open"}
)

QUIET_MODES = {
    "pause": "pause",
    "dnd": "pause",
    "dim": "dim",
    "mute": "mute",
    "asks-only": "asks_only",
    "asks_only": "asks_only",
    "dark": "dark",
}

# The quick toggles the app's links take, by the names a person types.
TOGGLE_NAMES = (
    "awake",
    "dark",
    "desktop",
    "hidden",
    "mute",
    "saver",
    "lock",
    "dock",
    "mic",
    "eject",
    "sleep",
)

MAX_SECONDS = 86_400
EXIT_NO_CORE = 3
#: A hook's JSON on stdin is a few kilobytes; anything past this is not one.
MAX_HOOK_PAYLOAD_BYTES = 1 << 20

_DURATION_PART = re.compile(r"(\d+)([smhd])")
_CLOCK = re.compile(r"(\d{1,2})(?::(\d{2}))?(am|pm|a|p)?")
_UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86_400}


class ControlError(Exception):
    """A refusal to report, with the exit status it deserves -- and, for a
    command the daemon refused, the daemon's own error code."""

    def __init__(self, message: str, status: int = 1, *, code: str | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code


def parse_duration(raw: str) -> int:
    """Seconds from ``7200``, ``90s``, ``15m``, ``2h``, ``1d`` or a run of
    them (``1h30m``); ``off`` is 0. Anything else -- a typo, a negative, a
    bare unit -- is refused rather than read as zero, the same grammar the
    app's links take."""
    text = raw.strip().lower().replace(" ", "")
    if text in ("off", "0", "none", "end", "stop"):
        return 0
    if text.isdigit():
        return int(text)
    position = 0
    total = 0
    for match in _DURATION_PART.finditer(text):
        if match.start() != position:
            break
        total += int(match.group(1)) * _UNIT_SECONDS[match.group(2)]
        position = match.end()
    if position != len(text) or not text:
        raise ControlError(f"not a duration: {raw!r} (try 90s, 15m, 2h, 1h30m or off)", 2)
    return total


def seconds_until(raw: str, now: float | None = None) -> int:
    """Seconds from ``now`` to the next time the clock reads ``raw`` --
    ``08:00``, ``8am``, ``8:30pm``, ``20:30`` -- later today, or tomorrow
    once today's has passed: Amphetamine's "until 8 AM". The same grammar
    as the app's ``until=`` links; a bare ``8`` is refused, since a bare
    number is a duration everywhere else."""
    text = raw.strip().lower().replace(" ", "").replace(".", "")
    match = _CLOCK.fullmatch(text)
    if match is None or (match.group(2) is None and match.group(3) is None):
        raise ControlError(f"not a time of day: {raw!r} (try 8am, 8:30pm or 20:30)", 2)
    hour, minute = int(match.group(1)), int(match.group(2) or 0)
    meridiem = match.group(3)
    if meridiem:
        if not 1 <= hour <= 12:
            raise ControlError(f"not a time of day: {raw!r}", 2)
        hour = hour % 12 + (12 if meridiem.startswith("p") else 0)
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise ControlError(f"not a time of day: {raw!r}", 2)
    base = time.time() if now is None else now
    day = time.localtime(base)
    # mktime normalises a day past the month's end and settles DST itself.
    target = time.mktime((day.tm_year, day.tm_mon, day.tm_mday, hour, minute, 0, 0, 0, -1))
    if target <= base:
        target = time.mktime((day.tm_year, day.tm_mon, day.tm_mday + 1, hour, minute, 0, 0, 0, -1))
    return max(1, int(-(-(target - base) // 1)))


def _length(duration: str | None, until: str | None, what: str) -> int | None:
    """One length from a duration or a clock time; both is refused."""
    if duration is not None and until is not None:
        raise ControlError(f"give {what} a duration or --until, not both", 2)
    if until is not None:
        return seconds_until(until)
    if duration is not None:
        return parse_duration(duration)
    return None


def describe_seconds(seconds: int) -> str:
    if seconds % 3600 == 0 and seconds >= 3600:
        return f"{seconds // 3600} h"
    if seconds >= 3600:
        return f"{seconds // 3600} h {(seconds % 3600) // 60} min"
    if seconds % 60 == 0:
        return f"{seconds // 60} min"
    return f"{seconds} s"


def parse_value(raw: str) -> Any:
    """A setting value as typed: JSON when it parses (``true``, ``0.4``,
    ``["claude"]``, ``null``), else the plain string."""
    try:
        return json.loads(raw)
    except ValueError:
        return raw


class CoreConnection:
    """One short-lived client on core.sock: the frames the daemon sends
    on connect (hello, state, lights, settings) and command replies."""

    def __init__(self, path: Path, timeout: float = 3.0) -> None:
        self.path = path
        self.timeout = timeout
        self._socket: socket.socket | None = None
        self._buffer = bytearray()
        self._seen: list[dict[str, Any]] = []
        self._next_id = 0

    def __enter__(self) -> CoreConnection:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout)
        try:
            connection.connect(str(self.path))
        except OSError as exc:
            connection.close()
            raise ControlError(
                f"the JR-Bar monitor is not running (nothing answers at {self.path}): {exc.strerror or exc}",
                EXIT_NO_CORE,
            ) from None
        self._socket = connection
        return self

    def __exit__(self, *_exc: object) -> None:
        if self._socket is not None:
            self._socket.close()
            self._socket = None

    def _frames(self) -> Iterator[dict[str, Any]]:
        assert self._socket is not None
        while True:
            while b"\n" in self._buffer:
                line, _, rest = bytes(self._buffer).partition(b"\n")
                self._buffer = bytearray(rest)
                try:
                    frame = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    continue
                if isinstance(frame, dict):
                    yield frame
            if len(self._buffer) > 1 << 20:
                raise ControlError("the monitor sent an oversized frame", 1)
            try:
                chunk = self._socket.recv(65536)
            except TimeoutError:
                raise ControlError("the monitor did not answer in time", 1) from None
            except OSError as exc:
                raise ControlError(f"the monitor connection failed: {exc}", 1) from None
            if not chunk:
                raise ControlError("the monitor closed the connection", 1)
            self._buffer.extend(chunk)

    def document(self, kind: str) -> dict[str, Any]:
        """The first frame of ``kind`` (``state``, ``settings``, ``hello``)."""
        for frame in self._seen:
            if frame.get("t") == kind:
                return frame
        for frame in self._frames():
            self._seen.append(frame)
            if frame.get("t") == kind:
                return frame
        raise ControlError(f"the monitor sent no {kind}", 1)  # pragma: no cover - loop exits by raising

    def seen(self, kind: str) -> dict[str, Any] | None:
        """A frame of ``kind`` that has already arrived, without waiting for
        one: the monitor sends only the documents it has."""
        for frame in self._seen:
            if frame.get("t") == kind:
                return frame
        return None

    def command(self, name: str, args: dict[str, Any]) -> dict[str, Any]:
        """Send one command and return its reply's ``result``; a refused
        reply raises with the daemon's own words."""
        assert self._socket is not None
        self._next_id += 1
        identifier = f"cli-{self._next_id}"
        frame = {"t": "command", "v": 1, "id": identifier, "name": name, "args": args}
        payload = (json.dumps(frame, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")
        try:
            self._socket.sendall(payload)
        except OSError as exc:
            raise ControlError(f"could not send {name}: {exc}", 1) from None
        for reply in self._frames():
            if reply.get("t") != "reply" or reply.get("id") != identifier:
                self._seen.append(reply)
                continue
            if reply.get("ok") is False:
                error = reply.get("error") or {}
                message = error.get("message") or error.get("code") or "refused"
                code = error.get("code") if isinstance(error.get("code"), str) else None
                raise ControlError(f"{name}: {message}", 1, code=code)
            result = reply.get("result")
            return result if isinstance(result, dict) else {}
        raise ControlError(f"no reply to {name}", 1)  # pragma: no cover


def default_socket_path() -> Path:
    from .core_server import default_core_socket_path

    return default_core_socket_path()


def open_link(url: str, runner: Callable[..., Any] = subprocess.run) -> None:
    """Hand a ``jrbar://`` link to Launch Services without raising the app."""
    result = runner(["/usr/bin/open", "-g", url], capture_output=True, text=True, timeout=10)
    if getattr(result, "returncode", 0) != 0:
        detail = (getattr(result, "stderr", "") or "").strip() or "open refused the link"
        raise ControlError(f"JR-Bar did not take {url}: {detail}", 1)


# MARK: - Verbs


def _setting_at(document: Any, path: str) -> Any:
    node = document
    for part in path.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            raise ControlError(f"no setting at {path}", 1)
    return node


def _session_line(session: dict[str, Any], asks: dict[str, dict[str, Any]]) -> str:
    provider = str(session.get("provider") or "?")
    label = str(session.get("label") or session.get("short_id") or session.get("id") or "?")
    mode = str(session.get("mode") or session.get("lifecycle") or "")
    ask = asks.get(str(session.get("id")))
    if ask is not None:
        summary = str(ask.get("summary") or ask.get("kind") or "waiting")
        return f"  ! needs you  {provider:<8} {label} -- {summary}"
    return f"  - {mode or 'idle':<10}{provider:<8} {label}"


def render_status(state: dict[str, Any], hello: dict[str, Any] | None = None) -> str:
    aggregate = state.get("aggregate") or {}
    sessions = [row for row in state.get("sessions") or [] if isinstance(row, dict)]
    asks = {
        str(ask.get("session")): ask
        for ask in state.get("asks") or []
        if isinstance(ask, dict) and ask.get("session")
    }
    version = (hello or {}).get("core_version")
    head = f"JR-Bar core {version}" if version else "JR-Bar core"
    needs = int(aggregate.get("needs_you") or len(asks))
    lines = [
        f"{head} -- {len(sessions)} session{'s' if len(sessions) != 1 else ''}"
        + (f", {needs} need{'s' if needs == 1 else ''} you" if needs else "")
    ]
    ordered = sorted(sessions, key=lambda row: (str(row.get("id")) not in asks, str(row.get("provider"))))
    lines.extend(_session_line(row, asks) for row in ordered)
    focus = state.get("focus") or {}
    if isinstance(focus, dict) and focus.get("mode") not in (None, "", "off", "none"):
        summary = focus.get("summary") or focus.get("mode")
        lines.append(f"quiet: {summary}")
    power = state.get("power") or {}
    if isinstance(power, dict) and power.get("keep_awake"):
        lines.append("keep awake: held while agents work")
    return "\n".join(lines)


def cmd_status(args: argparse.Namespace, connect: Callable[[], CoreConnection]) -> int:
    with connect() as core:
        hello = core.document("hello")
        state = core.document("state")
        lights = None
        if args.json:
            # A client's first frames are state, lights (when the monitor
            # has one) and settings: once settings is in, lights was sent
            # or never will be.
            core.document("settings")
            lights = core.seen("lights")
    if args.json:
        body = {key: value for key, value in state.items() if key not in ("t", "v")}
        # The linked Dot's timing from the lights frame (``phase_error_ms``,
        # ``clock_rate``, ``sync_writes_hour``...), for scripts and the
        # post-install check; absent without a linked pair.
        dot_link = lights.get("dot_link") if isinstance(lights, dict) else None
        if isinstance(dot_link, dict):
            body["dot_link"] = dot_link
        print(json.dumps(body, indent=2, sort_keys=True))
    else:
        print(render_status(state, hello))
    return 0


def cmd_quiet(args: argparse.Namespace, connect: Callable[[], CoreConnection]) -> int:
    seconds = _length(args.duration, args.until, "quiet")
    if seconds is None:
        raise ControlError("say how long: a duration (1h, 30m, off) or --until 8am", 2)
    if seconds > MAX_SECONDS:
        raise ControlError("quiet lasts at most a day", 2)
    mode = QUIET_MODES.get(args.mode.lower())
    if mode is None:
        raise ControlError(f"unknown quiet mode {args.mode!r} (pause, dim, mute, asks-only, dark)", 2)
    with connect() as core:
        core.command("quiet", {"mode": mode, "seconds": seconds})
    print("quiet ended" if seconds == 0 else f"quiet ({mode}) for {describe_seconds(seconds)}")
    return 0


def cmd_snooze(args: argparse.Namespace, connect: Callable[[], CoreConnection]) -> int:
    seconds = parse_duration(args.duration)
    target = "all" if args.session == "all" else args.session
    with connect() as core:
        result = core.command("snooze", {"session": target, "seconds": seconds})
    count = len(result.get("sessions") or []) if isinstance(result.get("sessions"), list) else None
    what = f"{count} session{'s' if count != 1 else ''}" if count is not None else target
    print(f"unsnoozed {what}" if seconds == 0 else f"snoozed {what}")
    return 0


def cmd_set(args: argparse.Namespace, connect: Callable[[], CoreConnection]) -> int:
    value = parse_value(args.value)
    with connect() as core:
        result = core.command("set_setting", {"path": args.path, "value": value})
    kept = result.get("value", value)
    print(f"{args.path} = {json.dumps(kept)}")
    if kept != value:
        print(f"(the monitor kept {json.dumps(kept)} instead of {json.dumps(value)})", file=sys.stderr)
    return 0


def cmd_get(args: argparse.Namespace, connect: Callable[[], CoreConnection]) -> int:
    with connect() as core:
        settings = core.document("settings")
    document = settings.get("document") if isinstance(settings.get("document"), dict) else settings
    print(json.dumps(_setting_at(document, args.path), indent=2, sort_keys=True))
    return 0


def hook_session(stream: Any) -> str:
    """The session a hook's JSON payload on stdin names (``session_id``,
    or the camel-case spelling some agents use)."""
    raw = stream.read(MAX_HOOK_PAYLOAD_BYTES + 1)
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", errors="replace")
    if len(raw) > MAX_HOOK_PAYLOAD_BYTES:
        raise ControlError("the hook payload on stdin is too large", 2)
    try:
        payload = json.loads(raw)
    except ValueError:
        raise ControlError("--from-hook reads the hook's JSON on stdin; none arrived", 2) from None
    session = payload.get("session_id") or payload.get("sessionId") if isinstance(payload, dict) else None
    if not isinstance(session, str) or not session.strip():
        raise ControlError("the hook payload names no session_id", 2)
    return session.strip()


def cmd_confetti(
    args: argparse.Namespace,
    connect: Callable[[], CoreConnection],
    stdin: Any = None,
) -> int:
    """Ask for a burst. The daemon journals it in the named session's
    colours; the app's Confetti toy fires it when it is on and the room is
    clear. ``--from-hook`` never fails the hook that runs it: a celebration
    must not cost an agent its turn."""
    try:
        session = hook_session(stdin if stdin is not None else sys.stdin) if args.from_hook else args.session
        body: dict[str, Any] = {}
        if session:
            body["session"] = session
        if args.provider:
            body["provider"] = args.provider
        if args.why:
            body["reason"] = args.why
        with connect() as core:
            result = core.command("confetti", body)
    except ControlError as exc:
        if args.from_hook:
            print(f"jrbar confetti: {exc}", file=sys.stderr)
            return 0
        raise
    if result.get("unmatched"):
        print(
            f"jrbar confetti: no watched session is {result['unmatched']!r}; the burst wears the Toys colour",
            file=sys.stderr,
        )
    if result.get("coalesced"):
        print("confetti: one went out in the last few seconds; this one joins it")
    else:
        colours = f" in {result['provider']} colours" if result.get("provider") else ""
        print(f"confetti requested{colours} (it fires when the Confetti toy is on)")
    return 0


def cmd_toggle(args: argparse.Namespace, opener: Callable[[str], None]) -> int:
    query = "" if args.state == "flip" else "?" + urlencode({"on": "1" if args.state == "on" else "0"})
    opener(f"jrbar://toggle/{quote(args.name)}{query}")
    return 0


def cmd_awake(args: argparse.Namespace, opener: Callable[[str], None]) -> int:
    seconds = _length(args.duration, args.until, "awake")
    if seconds is None:
        opener("jrbar://awake")
        return 0
    if seconds > MAX_SECONDS:
        raise ControlError("keep awake lasts at most a day", 2)
    opener("jrbar://awake?" + urlencode({"for": "off" if seconds == 0 else str(seconds)}))
    return 0


def cmd_deepwork(args: argparse.Namespace, opener: Callable[[str], None]) -> int:
    """Asks-only quiet for a focused stretch (25 min by default); the app
    says what the agents did meanwhile when it ends. ``off`` ends it."""
    if args.duration is not None and args.until is None and parse_duration(args.duration) == 0:
        opener("jrbar://deepwork/end")
        return 0
    seconds = _length(args.duration, args.until, "deepwork")
    if seconds is None:
        opener("jrbar://deepwork")
        return 0
    if not 60 <= seconds <= MAX_SECONDS:
        raise ControlError("deep work lasts between a minute and a day", 2)
    opener("jrbar://deepwork?" + urlencode({"for": str(seconds)}))
    return 0


def cmd_open(args: argparse.Namespace, opener: Callable[[str], None]) -> int:
    target = args.target.strip()
    if not target.startswith("jrbar://"):
        target = "jrbar://" + target.lstrip("/")
    opener(target)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="jrbar", description="Drive the running JR-Bar.")
    commands = parser.add_subparsers(dest="command", required=True)

    status = commands.add_parser("status", help="What the monitor sees now: sessions, asks, quiet.")
    status.add_argument("--json", action="store_true", help="The whole state document as JSON.")

    quiet = commands.add_parser("quiet", help="Quiet JR-Bar for a while (off ends it).")
    quiet.add_argument("duration", nargs="?", help="90s, 15m, 1h, 1h30m, or off")
    quiet.add_argument("--until", help="a time of day instead: 8am, 20:30")
    quiet.add_argument("--mode", default="pause", help="pause (default), dim, mute, asks-only, dark")

    snooze = commands.add_parser("snooze", help="Snooze a session's alerts (0 unsnoozes).")
    snooze.add_argument("session", help="a session id, or all")
    snooze.add_argument("duration", help="15m, 1h, ... or off")

    setter = commands.add_parser("set", help="Write one monitor setting by dot-path.")
    setter.add_argument("path", help="e.g. global_brightness_scale or colors.agent_colors.claude")
    setter.add_argument("value", help="JSON (true, 0.4, [\"claude\"]) or a plain string")

    getter = commands.add_parser("get", help="Read one monitor setting by dot-path.")
    getter.add_argument("path")

    confetti = commands.add_parser(
        "confetti", help="Ask for a burst of confetti (fires while the Confetti toy is on)."
    )
    target = confetti.add_mutually_exclusive_group()
    target.add_argument("--session", help="wear this session's colours: its id in jrbar status, or the agent's own")
    target.add_argument("--provider", help="wear this provider's colours: claude, codex, gemini, ...")
    target.add_argument(
        "--from-hook",
        action="store_true",
        help="read the session from the hook JSON on stdin (for a Stop hook); never fails the hook",
    )
    confetti.add_argument("--why", help="what earned it, for History and Event Replay")

    toggle = commands.add_parser("toggle", help="Flip or set a quick toggle in the app.")
    toggle.add_argument("name", help=", ".join(TOGGLE_NAMES))
    toggle.add_argument("state", nargs="?", choices=("flip", "on", "off"), default="flip")

    awake = commands.add_parser("awake", help="Keep the Mac awake (the app's hold): 2h, 30m, off.")
    awake.add_argument("duration", nargs="?", help="omit to hold until turned off")
    awake.add_argument("--until", help="a time of day instead: 8am, 20:30")

    deep = commands.add_parser("deepwork", help="Asks-only quiet for a stretch, then what the agents did (off ends it).")
    deep.add_argument("duration", nargs="?", help="25m (default), 50m, 1h, or off")
    deep.add_argument("--until", help="a time of day instead: 11am, 16:30")

    opener = commands.add_parser("open", help="Run any jrbar:// link, e.g. panel/toggle or settings/shortcuts.")
    opener.add_argument("target")
    return parser


def main(
    argv: list[str],
    *,
    socket_path: Path | None = None,
    opener: Callable[[str], None] | None = None,
) -> int:
    args = build_parser().parse_args(argv)
    path = socket_path or default_socket_path()

    def connect() -> CoreConnection:
        return CoreConnection(path)

    link = opener or open_link
    try:
        if args.command == "status":
            return cmd_status(args, connect)
        if args.command == "quiet":
            return cmd_quiet(args, connect)
        if args.command == "snooze":
            return cmd_snooze(args, connect)
        if args.command == "set":
            return cmd_set(args, connect)
        if args.command == "get":
            return cmd_get(args, connect)
        if args.command == "confetti":
            return cmd_confetti(args, connect)
        if args.command == "toggle":
            return cmd_toggle(args, link)
        if args.command == "awake":
            return cmd_awake(args, link)
        if args.command == "deepwork":
            return cmd_deepwork(args, link)
        return cmd_open(args, link)
    except ControlError as exc:
        print(f"jrbar {args.command}: {exc}", file=sys.stderr)
        return exc.status


__all__ = ["VERBS", "ControlError", "CoreConnection", "main", "parse_duration", "render_status", "seconds_until"]
