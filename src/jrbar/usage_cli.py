"""``jrbar usage``: every provider's quota windows in a terminal.

It reads what the running monitor already knows (the ``usage`` block of
its state over core.sock), and when no monitor answers, the last readings
it saved. It never asks a provider anything itself.

    jrbar usage                  one line per window: "Claude  5h 58% left · resets 2h14m"
    jrbar usage --brief          a table
    jrbar usage --json           the usage block with "schema": 1
    jrbar usage --provider codex only one provider

The exit status is 1 when any enabled provider is in ERROR, so a script
or a status-bar plugin can tell "something is broken" from "all fine",
the way CodexBar's ``cards`` does. Numbers and words only: no bar made of
block characters.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, TextIO

USAGE_JSON_SCHEMA = 1

_PROVIDER_NAMES = {
    "codex": "Codex",
    "claude": "Claude",
    "cursor": "Cursor",
    "devin": "Devin",
    "grok": "Grok",
    "gemini": "Gemini",
    "antigravity": "Antigravity",
    "opencode": "OpenCode",
    "openai-api": "OpenAI API",
    "pi": "Pi",
    "openclaw": "OpenClaw",
}
#: Why a provider has no windows, in words, for the states that say so.
_STATE_WORDS = {
    "disabled": "off",
    "needs_consent": "needs permission",
    "needs_sign_in": "sign-in required",
    "source_not_found": "source not found",
    "unavailable": "unavailable",
    "rate_limited": "rate limited, retrying later",
    "error": "error",
    "unsupported": "no quota source",
    "stale": "stale",
}
_SOURCE_WORDS = {"claude-statusline": "via Claude Code", "cliproxy": "via CLIProxyAPI"}


def provider_name(provider_id: str, instance: str | None = None) -> str:
    name = _PROVIDER_NAMES.get(provider_id, provider_id.replace("-", " ").title())
    if instance and instance != "default":
        if instance.startswith("cliproxy:"):
            return f"{name} (CLIProxyAPI)"
        return f"{name} ({instance})"
    return name


def reset_words(resets_at: float | None, now: float) -> str | None:
    """``2h14m``, ``45m``, ``3d5h``; None when the window names no reset."""
    if resets_at is None:
        return None
    seconds = int(resets_at - now)
    if seconds < -120:
        return "reset passed, the reading is older"
    if seconds <= 60:
        return "resetting now"
    minutes = seconds // 60
    if minutes < 60:
        return f"resets {minutes}m"
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return f"resets {hours}h{minutes:02d}m"
    days, hours = divmod(hours, 24)
    return f"resets {days}d{hours}h"


def _left(window: dict[str, Any]) -> str:
    used = window.get("used_pct")
    if not isinstance(used, (int, float)) or isinstance(used, bool):
        return "no reading"
    return f"{max(0.0, 100.0 - float(used)):.0f}% left"


def _source_note(provider: dict[str, Any]) -> str | None:
    for window in provider.get("windows") or []:
        note = _SOURCE_WORDS.get(str(window.get("source") or ""))
        if note:
            return note
    return None


def _why_empty(provider: dict[str, Any]) -> str:
    state = str(provider.get("state") or "")
    if provider.get("quota_source") is False:
        words = "no quota source"
    else:
        words = _STATE_WORDS.get(state, state.replace("_", " ") or "no windows")
    action = provider.get("action")
    return f"{words}: {action}" if isinstance(action, str) and action else words


def render_lines(document: dict[str, Any], *, now: float) -> list[str]:
    """One line per window; one line for a provider with none."""
    providers = [row for row in document.get("providers") or [] if isinstance(row, dict)]
    names = [provider_name(str(row.get("id")), row.get("instance")) for row in providers]
    width = max((len(name) for name in names), default=0) + 2
    lines: list[str] = []
    for provider, name in zip(providers, names):
        windows = [window for window in provider.get("windows") or [] if isinstance(window, dict)]
        suffix = []
        if provider.get("state") == "stale":
            suffix.append("stale")
        note = _source_note(provider)
        if note:
            suffix.append(note)
        if not windows:
            lines.append(f"{name:<{width}}{_why_empty(provider)}")
            continue
        credits = provider.get("reset_credits")
        if isinstance(credits, int) and not isinstance(credits, bool) and credits > 0:
            suffix.append("1 reset credit" if credits == 1 else f"{credits} reset credits")
        for window in windows:
            parts = [f"{window.get('name') or window.get('id') or '?'} {_left(window)}"]
            reset = reset_words(window.get("resets_at"), now)
            if reset:
                parts.append(reset)
            if window.get("detail") is True:
                parts.append("detail")
            parts.extend(suffix)
            lines.append(f"{name:<{width}}" + " · ".join(parts))
    return lines


def render_brief(document: dict[str, Any], *, now: float) -> str:
    rows = [("Provider", "Window", "Left", "Resets")]
    for provider in document.get("providers") or []:
        if not isinstance(provider, dict):
            continue
        name = provider_name(str(provider.get("id")), provider.get("instance"))
        windows = [window for window in provider.get("windows") or [] if isinstance(window, dict)]
        if not windows:
            rows.append((name, "-", _why_empty(provider), "-"))
            continue
        for window in windows:
            reset = reset_words(window.get("resets_at"), now) or "-"
            rows.append(
                (
                    name,
                    str(window.get("name") or window.get("id") or "?"),
                    _left(window).replace(" left", ""),
                    reset.removeprefix("resets "),
                )
            )
    widths = [max(len(row[column]) for row in rows) for column in range(4)]
    return "\n".join(
        "  ".join(cell.ljust(widths[index]) for index, cell in enumerate(row)).rstrip() for row in rows
    )


def _from_core(socket_path: Path | None) -> dict[str, Any] | None:
    from .cli_control import ControlError, CoreConnection, default_socket_path

    try:
        with CoreConnection(socket_path or default_socket_path(), timeout=3.0) as core:
            state = core.document("state")
    except ControlError:
        return None
    usage = state.get("usage")
    return usage if isinstance(usage, dict) else {"refreshed_at": None, "providers": []}


def _from_store() -> dict[str, Any]:
    from .core_projection import usage_document
    from .provider_usage_store import load_provider_usage_state

    try:
        state = load_provider_usage_state()
    except Exception:
        return {"refreshed_at": None, "providers": []}
    return usage_document(state) or {"refreshed_at": None, "providers": []}


def load_usage(
    *,
    socket_path: Path | None = None,
    core_reader: Callable[[Path | None], dict[str, Any] | None] = _from_core,
    store_reader: Callable[[], dict[str, Any]] = _from_store,
) -> tuple[dict[str, Any], str]:
    """(the usage block, where it came from: ``core`` or ``store``)."""
    live = core_reader(socket_path)
    if live is not None:
        return live, "core"
    return store_reader(), "store"


def any_error(document: dict[str, Any]) -> bool:
    """An enabled provider in ERROR (a disabled one reports ``disabled``)."""
    return any(
        isinstance(row, dict) and row.get("state") == "error" for row in document.get("providers") or []
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="jrbar usage",
        description="Every provider's quota windows, from the running monitor (or its last saved readings).",
    )
    shape = parser.add_mutually_exclusive_group()
    shape.add_argument("--brief", action="store_true", help="a table")
    shape.add_argument("--json", action="store_true", help='the usage block with "schema": 1')
    parser.add_argument("--provider", help="only this provider (codex, claude, ...)")
    parser.add_argument("--socket", type=Path, default=None, help=argparse.SUPPRESS)
    return parser


def main(
    argv: list[str] | None = None,
    *,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
    now: float | None = None,
    core_reader: Callable[[Path | None], dict[str, Any] | None] = _from_core,
    store_reader: Callable[[], dict[str, Any]] = _from_store,
) -> int:
    options = build_parser().parse_args(argv)
    document, source = load_usage(socket_path=options.socket, core_reader=core_reader, store_reader=store_reader)
    providers = [row for row in document.get("providers") or [] if isinstance(row, dict)]
    if options.provider:
        providers = [row for row in providers if row.get("id") == options.provider]
    document = {**document, "providers": providers}
    moment = time.time() if now is None else now
    if options.json:
        print(
            json.dumps({"schema": USAGE_JSON_SCHEMA, "source": source, **document}, indent=2, sort_keys=True),
            file=stdout,
        )
    elif options.brief:
        print(render_brief(document, now=moment), file=stdout)
    else:
        lines = render_lines(document, now=moment)
        print("\n".join(lines) if lines else "No provider usage yet.", file=stdout)
    if source == "store" and not options.json:
        print("(the monitor is not running: these are its last saved readings)", file=stderr)
    return 1 if any_error(document) else 0


__all__ = [
    "USAGE_JSON_SCHEMA",
    "any_error",
    "load_usage",
    "main",
    "provider_name",
    "render_brief",
    "render_lines",
    "reset_words",
]
