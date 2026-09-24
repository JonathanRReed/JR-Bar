"""Claude Code's statusLine as a quota source, opt-in.

Claude Code runs a statusLine command after each response and feeds it a
JSON document on stdin. For Pro and Max accounts that document carries
``rate_limits.five_hour`` and ``rate_limits.seven_day``, each with a
``used_percentage`` and a ``resets_at``: the same windows the OAuth usage
endpoint reports, straight from Anthropic's own client, with no token and
no extra request. (ccusage's statusline command and Claude Code's docs,
code.claude.com/docs/en/statusline, describe the fields.)

``jrbar-hook --statusline`` hands that JSON to the daemon as a frame of
kind ``statusline``. This module is where it lands, and it is careful:

- only ``session_id``, ``model.id`` and the two rate-limit windows are
  kept; the prompt, the transcript path, the working directory and every
  other field are dropped here, at the boundary;
- a window whose ``resets_at`` has passed is dropped, and a document with
  no ``rate_limits`` (an API-key account, an older Claude Code) is no
  evidence at all;
- it never touches session liveness: the statusLine re-renders while
  Claude is idle, so a statusline frame is never a hook event;
- it ranks below the OAuth endpoint: the Claude collector uses it only
  when OAuth is rate limited, signed out, unavailable or not connected,
  and says so ("via Claude Code").

The daemon also writes ``statusline.txt`` for the shim to print: one line
such as ``JR-Bar · 2 working · 1 needs you · 5h 58% left``, numbers and
words only.

Install and uninstall (``jrbar agent-monitor install claude-statusline``)
live here too. They never overwrite someone's statusLine: an existing one
is refused, or with ``--wrap`` kept and run after JR-Bar's line, and
uninstall puts back exactly what was there.
"""

from __future__ import annotations

import json
import math
import threading
import time
from dataclasses import dataclass, replace
from datetime import datetime
from pathlib import Path
from typing import Any

from .provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot, UsageLane

STATUSLINE_SOURCE_ID = "claude-statusline"
STATUSLINE_TEXT_NAME = "statusline.txt"
READING_FILE_NAME = "claude-statusline.json"
BACKUP_FILE_NAME = "claude-statusline-backup.json"
MAX_TEXT_BYTES = 256
MAX_PAYLOAD_BYTES = 256 * 1024
#: A reading older than this no longer stands in for OAuth.
FRESH_SECONDS = 15 * 60.0
#: The two windows kept, as (statusLine key, lane id, label).
_WINDOWS = (("five_hour", "five-hour", "5-hour"), ("seven_day", "weekly", "Weekly"))
_SETTINGS_CACHE_SECONDS = 5.0


def _number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def _epoch(value: object) -> float | None:
    number = _number(value)
    if number is not None:
        # Milliseconds when it could not be seconds (year 5000+).
        return number / 1000.0 if number > 1e11 else number
    if not isinstance(value, str) or len(value) > 64:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _short_text(value: object, limit: int = 128) -> str | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text or len(text) > limit or any(ord(char) < 32 for char in text):
        return None
    return text


@dataclass(frozen=True, slots=True)
class StatusLineWindow:
    used_percentage: float
    resets_at: float | None


@dataclass(frozen=True, slots=True)
class StatusLineReading:
    """Everything JR-Bar keeps from one statusLine document."""

    session_id: str | None
    model_id: str | None
    windows: tuple[tuple[str, StatusLineWindow], ...]
    observed_at: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "model_id": self.model_id,
            "observed_at": self.observed_at,
            "windows": {
                key: {"used_percentage": window.used_percentage, "resets_at": window.resets_at}
                for key, window in self.windows
            },
        }

    @classmethod
    def from_dict(cls, raw: object) -> StatusLineReading | None:
        if not isinstance(raw, dict):
            return None
        observed = _number(raw.get("observed_at"))
        windows_raw = raw.get("windows")
        if observed is None or not isinstance(windows_raw, dict):
            return None
        windows = []
        for key, _lane, _label in _WINDOWS:
            entry = windows_raw.get(key)
            if not isinstance(entry, dict):
                continue
            used = _number(entry.get("used_percentage"))
            if used is None:
                continue
            windows.append((key, StatusLineWindow(max(0.0, min(100.0, used)), _number(entry.get("resets_at")))))
        if not windows:
            return None
        return cls(_short_text(raw.get("session_id")), _short_text(raw.get("model_id")), tuple(windows), observed)

    def current(self, now: float) -> StatusLineReading | None:
        """This reading without windows whose reset has passed; None when
        nothing is left."""
        kept = tuple(
            (key, window)
            for key, window in self.windows
            if window.resets_at is None or window.resets_at > now
        )
        return replace(self, windows=kept) if kept else None


def minimize(payload_text: str, *, now: float) -> StatusLineReading | None:
    """Keep only the session id, the model id and the live rate-limit
    windows. None when the document carries no rate limits."""
    if not isinstance(payload_text, str) or len(payload_text.encode("utf-8", errors="replace")) > MAX_PAYLOAD_BYTES:
        return None
    try:
        document = json.loads(payload_text)
    except ValueError:
        return None
    if not isinstance(document, dict):
        return None
    limits = document.get("rate_limits")
    if not isinstance(limits, dict):
        return None
    windows = []
    for key, _lane, _label in _WINDOWS:
        entry = limits.get(key)
        if not isinstance(entry, dict):
            continue
        used = _number(entry.get("used_percentage"))
        if used is None:
            continue
        resets_at = _epoch(entry.get("resets_at"))
        if resets_at is not None and resets_at <= now:
            continue
        windows.append((key, StatusLineWindow(max(0.0, min(100.0, used)), resets_at)))
    if not windows:
        return None
    model = document.get("model")
    return StatusLineReading(
        _short_text(document.get("session_id")),
        _short_text(model.get("id")) if isinstance(model, dict) else None,
        tuple(windows),
        float(now),
    )


class StatusLineStore:
    """The latest reading, in memory and in the state directory (so a
    daemon restart keeps it). Thread-safe; the file is written only when
    the reading changes."""

    def __init__(self, path: Path | None = None) -> None:
        self._lock = threading.Lock()
        self._path = path
        self._reading: StatusLineReading | None = None
        self._loaded = False

    def _state_path(self) -> Path | None:
        if self._path is not None:
            return self._path
        try:
            from .state_paths import default_state_dir

            return default_state_dir() / READING_FILE_NAME
        except Exception:
            return None

    def _load_locked(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        path = self._state_path()
        if path is None:
            return
        try:
            from .private_io import read_private_text

            self._reading = StatusLineReading.from_dict(json.loads(read_private_text(path, max_bytes=8192)))
        except (OSError, ValueError):
            self._reading = None

    def put(self, reading: StatusLineReading) -> None:
        with self._lock:
            self._load_locked()
            previous = self._reading
            self._reading = reading
            changed = previous is None or previous.windows != reading.windows or previous.model_id != reading.model_id
            if not changed and previous is not None and reading.observed_at - previous.observed_at < 60.0:
                return
            path = self._state_path()
        if path is None:
            return
        try:
            from .private_io import atomic_private_write

            atomic_private_write(path, json.dumps(reading.to_dict(), sort_keys=True))
        except Exception:
            pass

    def latest(self) -> StatusLineReading | None:
        with self._lock:
            self._load_locked()
            return self._reading


SHARED_STORE = StatusLineStore()
_settings_cache: tuple[float, bool] | None = None


def source_enabled(now: float | None = None) -> bool:
    """``claude_statusline_source`` from the settings, read at most every
    five seconds (the statusLine can render several times a second)."""
    global _settings_cache
    moment = time.monotonic() if now is None else now
    cached = _settings_cache
    if cached is not None and moment - cached[0] < _SETTINGS_CACHE_SECONDS:
        return cached[1]
    try:
        from .settings import load_settings

        enabled = bool(getattr(load_settings(), "claude_statusline_source", False))
    except Exception:
        enabled = False
    _settings_cache = (moment, enabled)
    return enabled


def ingest(payload_text: str, *, now: float | None = None, store: StatusLineStore | None = None, enabled=None) -> bool:
    """Take one statusLine document. True when it carried a reading."""
    store = SHARED_STORE if store is None else store
    moment = time.time() if now is None else float(now)
    if not (source_enabled() if enabled is None else enabled):
        return False
    reading = minimize(payload_text, now=moment)
    if reading is None:
        return False
    store.put(reading)
    return True


def current_reading(
    now: float,
    *,
    store: StatusLineStore | None = None,
    max_age: float = FRESH_SECONDS,
    enabled=None,
) -> StatusLineReading | None:
    """The latest reading while it is fresh and the source is on."""
    store = SHARED_STORE if store is None else store
    if not (source_enabled() if enabled is None else enabled):
        return None
    reading = store.latest()
    if reading is None or now - reading.observed_at > max_age or reading.observed_at > now + 60.0:
        return None
    return reading.current(now)


def snapshot_from_reading(
    reading: StatusLineReading,
    *,
    observed_at: float,
    input_tokens: int = 0,
    cached_input_tokens: int = 0,
    output_tokens: int = 0,
    model_count: int = 0,
    estimated_cost_usd: float | None = None,
    cache_savings_usd: float | None = None,
    account_plan: str | None = None,
) -> ProviderUsageSnapshot:
    """A READY Claude snapshot whose lanes say they came from Claude Code."""
    labels = {key: (lane, label) for key, lane, label in _WINDOWS}
    lanes = tuple(
        UsageLane(
            provider_id="claude",
            lane_id=labels[key][0],
            label=labels[key][1],
            remaining_percent=max(0.0, min(100.0, 100.0 - window.used_percentage)),
            reset_at=window.resets_at,
            scope="all",
            model=None,
            feature=None,
            bindable=True,
            source_id=STATUSLINE_SOURCE_ID,
        )
        for key, window in reading.windows
    )
    return ProviderUsageSnapshot(
        provider_id="claude",
        account_label=None,
        account_plan=account_plan,
        observed_at=reading.observed_at,
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=lanes,
        input_tokens=input_tokens,
        cached_input_tokens=cached_input_tokens,
        output_tokens=output_tokens,
        model_count=model_count,
        estimated_cost_usd=estimated_cost_usd,
        cache_savings_usd=cache_savings_usd,
        credits_remaining=None,
        incident=None,
    )


# --- statusline.txt ----------------------------------------------------------


def statusline_text(state: dict[str, Any]) -> str:
    """``JR-Bar · 2 working · 1 needs you · 5h 58% left`` from the core
    state document. Numbers and words only, never a block-character bar."""
    aggregate = state.get("aggregate") if isinstance(state.get("aggregate"), dict) else {}
    parts = ["JR-Bar"]
    working = aggregate.get("active")
    needs = aggregate.get("needs_you")
    if isinstance(working, int) and working > 0:
        parts.append(f"{working} working")
    if isinstance(needs, int) and needs > 0:
        parts.append(f"{needs} needs you")
    if len(parts) == 1:
        parts.append("idle")
    usage = state.get("usage") if isinstance(state.get("usage"), dict) else {}
    for provider in usage.get("providers") or []:
        if not isinstance(provider, dict) or provider.get("id") != "claude":
            continue
        if provider.get("instance") not in (None, "default"):
            continue
        for window in provider.get("windows") or []:
            if not isinstance(window, dict) or window.get("id") != "five-hour":
                continue
            used = _number(window.get("used_pct"))
            if used is not None:
                parts.append(f"5h {max(0.0, 100.0 - used):.0f}% left")
        break
    text = " · ".join(parts)
    encoded = text.encode("utf-8")[:MAX_TEXT_BYTES]
    return encoded.decode("utf-8", errors="ignore")


class StatusLineTextWriter:
    """Writes ``statusline.txt`` when its content changes."""

    def __init__(self) -> None:
        self._last: tuple[str, str] | None = None
        self._lock = threading.Lock()

    def write(self, state: dict[str, Any], state_dir: Path, *, settings: object) -> str | None:
        if not bool(getattr(settings, "claude_statusline_source", False)):
            return None
        text = statusline_text(state) if bool(getattr(settings, "statusline_text_enabled", True)) else ""
        target = Path(state_dir) / STATUSLINE_TEXT_NAME
        with self._lock:
            if self._last == (str(target), text):
                return text
            self._last = (str(target), text)
        try:
            from .private_io import atomic_private_write

            atomic_private_write(target, text + ("\n" if text else ""))
        except Exception:
            with self._lock:
                self._last = None
            return None
        return text


SHARED_TEXT_WRITER = StatusLineTextWriter()


def publish_statusline_text(controller: object, document: dict[str, Any]) -> None:
    """The daemon's state-publish step: keep statusline.txt current."""
    try:
        from .state_paths import default_state_dir

        SHARED_TEXT_WRITER.write(document, default_state_dir(), settings=getattr(controller, "settings", None))
    except Exception:
        pass


# --- install / uninstall ------------------------------------------------------

STATUSLINE_FLAG = "--statusline"


class StatusLineInstallError(ValueError):
    """A refused install or uninstall, in words."""


def _quote(text: str) -> str:
    import shlex

    return shlex.quote(text)


def statusline_command(shim: Path, *, then: str | None = None) -> str:
    command = f"{_quote(str(shim))} {STATUSLINE_FLAG}"
    if then:
        command += f" --then {_quote(then)}"
    return command


def is_ours(entry: object) -> bool:
    if not isinstance(entry, dict):
        return False
    command = entry.get("command")
    return isinstance(command, str) and "jrbar-hook" in command and STATUSLINE_FLAG in command


def claude_settings_path(home: Path | None = None, env=None) -> Path:
    from .provider_homes import primary_claude_projects

    return primary_claude_projects(env=env, home=home).parent / "settings.json"


def _backup_path(state_dir: Path) -> Path:
    return Path(state_dir) / BACKUP_FILE_NAME


def _publish(settings_path: Path, data: dict[str, Any]) -> None:
    from .install import (
        _decode_config,
        _transactional_provider_publish,
        _validated_optional_config,
    )
    from .providers import detect_log_path

    leaf = _validated_optional_config(settings_path, dry_run=False)
    _decode_config(leaf)
    _transactional_provider_publish(
        config_leaf=leaf,
        target_log=detect_log_path("claude"),
        writes={settings_path: json.dumps(data, indent=2, sort_keys=False) + "\n"},
        backup_config=True,
    )


def _read_settings(settings_path: Path) -> dict[str, Any]:
    from .install import _decode_config, _strict_json_object, _validated_optional_config

    leaf = _validated_optional_config(settings_path, dry_run=True)
    text = _decode_config(leaf)
    return _strict_json_object(text, path=settings_path) if text.strip() else {}


def install_statusline(
    *,
    shim: Path,
    settings_path: Path,
    state_dir: Path,
    wrap: bool = False,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Point Claude Code's statusLine at the shim. Never overwrites: an
    existing statusLine is refused, or with ``wrap`` kept (it runs after
    JR-Bar's line) and saved so uninstall can put it back."""
    data = _read_settings(settings_path)
    current = data.get("statusLine")
    if is_ours(current):
        return {"changed": False, "wrapped": " --then " in str(current.get("command")), "settings": str(settings_path)}
    previous_command = None
    if current is not None:
        if not wrap:
            raise StatusLineInstallError(
                "Claude Code already has a statusLine; JR-Bar will not replace it. "
                "Run again with --wrap to keep it and show JR-Bar's line above it."
            )
        if not isinstance(current, dict) or current.get("type") != "command" or not isinstance(current.get("command"), str):
            raise StatusLineInstallError("the existing statusLine is not a command JR-Bar can wrap")
        previous_command = current["command"]
    entry: dict[str, Any] = dict(current) if isinstance(current, dict) else {"type": "command"}
    entry["type"] = "command"
    entry["command"] = statusline_command(shim, then=previous_command)
    entry.setdefault("padding", 0)
    data["statusLine"] = entry
    if not dry_run:
        from .private_io import atomic_private_write

        backup = {"version": 1, "settings": str(settings_path), "previous": current, "installed_at": time.time()}
        atomic_private_write(_backup_path(state_dir), json.dumps(backup, sort_keys=True))
        _publish(settings_path, data)
    return {"changed": True, "wrapped": previous_command is not None, "settings": str(settings_path)}


def uninstall_statusline(*, settings_path: Path, state_dir: Path, dry_run: bool = False) -> dict[str, Any]:
    """Put back the statusLine JR-Bar replaced, or remove JR-Bar's own.
    A statusLine that is not JR-Bar's is left alone."""
    data = _read_settings(settings_path)
    current = data.get("statusLine")
    if not is_ours(current):
        return {"changed": False, "restored": False, "settings": str(settings_path)}
    previous = None
    backup_file = _backup_path(state_dir)
    try:
        from .private_io import read_private_text

        backup = json.loads(read_private_text(backup_file, max_bytes=64 * 1024))
        if isinstance(backup, dict):
            previous = backup.get("previous")
    except (OSError, ValueError):
        backup = None
    if previous is None and " --then " in str(current.get("command")):
        # No backup, but the wrapped command is in our own line: unwrap it.
        import shlex

        parts = shlex.split(str(current["command"]))
        if "--then" in parts and parts.index("--then") + 1 < len(parts):
            previous = {**current, "command": parts[parts.index("--then") + 1]}
    if previous is None:
        data.pop("statusLine", None)
    else:
        data["statusLine"] = previous
    if not dry_run:
        _publish(settings_path, data)
        try:
            backup_file.unlink()
        except OSError:
            pass
    return {"changed": True, "restored": previous is not None, "settings": str(settings_path)}


def _set_source_setting(enabled: bool) -> None:
    """``claude_statusline_source`` through the monitor when it answers,
    else in settings.json directly."""
    try:
        from .cli_control import CoreConnection, default_socket_path

        with CoreConnection(default_socket_path(), timeout=2.0) as core:
            core.command("set_setting", {"path": "claude_statusline_source", "value": enabled})
            return
    except Exception:
        pass
    from dataclasses import replace as settings_replace

    from .settings import load_settings, save_settings

    save_settings(settings_replace(load_settings(), claude_statusline_source=enabled))


def _apply_source_setting(controller, enabled: bool) -> None:
    from .core_runtime import _apply_settings_document

    document = controller.settings.to_dict()
    document["claude_statusline_source"] = bool(enabled)
    _apply_settings_document(controller, document, touched=["claude_statusline_source"])


def core_install_command(controller, args: dict[str, Any]) -> dict[str, Any]:
    """``claude_statusline_install {wrap}``: Settings' switch. An existing
    statusLine is never replaced; without ``wrap`` the reply says
    ``needs_wrap`` so the app can ask first."""
    from .core_server import CommandError
    from .install import hook_shim_path
    from .state_paths import default_state_dir

    shim = hook_shim_path()
    if shim is None:
        raise CommandError("unavailable", "the jrbar-hook shim is not installed")
    wrap = args.get("wrap") is True
    try:
        result = install_statusline(
            shim=shim, settings_path=claude_settings_path(), state_dir=default_state_dir(), wrap=wrap
        )
    except StatusLineInstallError as error:
        return {"installed": False, "needs_wrap": not wrap, "message": str(error)}
    except (OSError, ValueError) as error:
        raise CommandError("refused", f"could not write Claude's settings: {error}") from error
    _apply_source_setting(controller, True)
    return {"installed": True, "wrapped": bool(result["wrapped"]), "needs_wrap": False, "message": None}


def core_uninstall_command(controller, _args: dict[str, Any]) -> dict[str, Any]:
    from .core_server import CommandError
    from .state_paths import default_state_dir

    try:
        result = uninstall_statusline(settings_path=claude_settings_path(), state_dir=default_state_dir())
    except (OSError, ValueError) as error:
        raise CommandError("refused", f"could not write Claude's settings: {error}") from error
    _apply_source_setting(controller, False)
    return {"removed": bool(result["changed"]), "restored": bool(result.get("restored"))}


def uninstall_with_claude_hooks(
    *,
    dry_run: bool = False,
    settings_path: Path | None = None,
    state_dir: Path | None = None,
) -> int:
    """``jrbar agent-monitor uninstall all`` (or ``claude``) also puts back
    Claude Code's status line. The line points at a shim inside JR-Bar.app,
    so leaving it behind after the app is deleted would break Claude
    Code's status line and lose the one the person had before. Quiet when
    the status line is not JR-Bar's."""
    import sys

    from .state_paths import default_state_dir

    target = settings_path or claude_settings_path()
    try:
        result = uninstall_statusline(
            settings_path=target, state_dir=state_dir or default_state_dir(), dry_run=dry_run
        )
    except (ValueError, OSError) as error:
        print(f"claude statusLine: {error}", file=sys.stderr)
        return 1
    if not result["changed"]:
        return 0
    if not dry_run:
        _set_source_setting(False)
    verb = "would put back" if dry_run else "put back"
    what = "your previous statusLine" if result["restored"] else "no statusLine (JR-Bar's removed)"
    print(f"claude statusLine: {verb} {what}")
    print(f"  config: {target}")
    return 0


def main(argv: list[str]) -> int:
    """``jrbar agent-monitor install|uninstall claude-statusline [--wrap] [--dry-run]``."""
    import argparse
    import sys

    parser = argparse.ArgumentParser(prog="jrbar agent-monitor")
    parser.add_argument("verb", choices=("install", "uninstall"))
    parser.add_argument("target", choices=("claude-statusline",))
    parser.add_argument("--wrap", action="store_true", help="keep an existing statusLine and run it after JR-Bar's line")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--settings", type=Path, default=None, help=argparse.SUPPRESS)
    options = parser.parse_args(argv)
    from .install import hook_shim_path
    from .state_paths import default_state_dir

    settings_path = options.settings or claude_settings_path()
    state_dir = default_state_dir()
    try:
        if options.verb == "install":
            shim = hook_shim_path()
            if shim is None:
                print("the jrbar-hook shim is not built or installed; open JR-Bar once first", file=sys.stderr)
                return 1
            result = install_statusline(
                shim=shim, settings_path=settings_path, state_dir=state_dir, wrap=options.wrap, dry_run=options.dry_run
            )
            if not options.dry_run:
                _set_source_setting(True)
            what = "wrapped your statusLine" if result["wrapped"] else "installed"
            print(f"Claude statusLine {what if result['changed'] else 'already installed'}: {result['settings']}")
        else:
            result = uninstall_statusline(settings_path=settings_path, state_dir=state_dir, dry_run=options.dry_run)
            if not options.dry_run:
                _set_source_setting(False)
            if not result["changed"]:
                print(f"no JR-Bar statusLine in {result['settings']}; left it as it is")
            else:
                print("restored your previous statusLine" if result["restored"] else "removed JR-Bar's statusLine")
    except (StatusLineInstallError, ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


__all__ = [
    "FRESH_SECONDS",
    "SHARED_STORE",
    "STATUSLINE_SOURCE_ID",
    "StatusLineInstallError",
    "StatusLineReading",
    "StatusLineStore",
    "StatusLineTextWriter",
    "core_install_command",
    "core_uninstall_command",
    "current_reading",
    "ingest",
    "install_statusline",
    "is_ours",
    "main",
    "minimize",
    "publish_statusline_text",
    "snapshot_from_reading",
    "statusline_command",
    "statusline_text",
    "uninstall_statusline",
    "uninstall_with_claude_hooks",
]
