"""Opted-in Claude Code /usage probe. No prompts, login or token writes."""

from __future__ import annotations

import os
import pty
import re
import select
import subprocess
import tempfile
import time

from .provider_cli import _kill_group, resolve_cli

_ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
_LABELS = (
    ("Current session", "5-hour"),
    ("Current week (all models)", "Weekly"),
    ("Current week (Sonnet only)", "weekly-sonnet"),
    ("Current week (Sonnet)", "weekly-sonnet"),
    ("Current week (Opus)", "weekly-opus"),
)


def parse_usage_screen(text: str) -> list[dict]:
    """Accept labelled quota sections only, never a context or tool meter."""
    clean = _ANSI.sub("", text).replace("\r", "")
    start = clean.rfind("Current session")
    if start < 0:
        raise ValueError("claude_cli_usage_unavailable")
    clean = clean[start:]
    sections = list(re.finditer(r"Current (?:session|week[^\n]*)", clean))
    windows = {}
    for index, section in enumerate(sections):
        end = sections[index + 1].start() if index + 1 < len(sections) else len(clean)
        block = clean[section.start():end]
        label = next((lane for heading, lane in _LABELS if block.startswith(heading)), None)
        match = re.search(r"(?<![\d.])(\d{1,3}(?:\.\d+)?)\s*%\s*(used|left|remaining)\b", block, re.I)
        if label is None or match is None:
            continue
        percent = float(match[1])
        if not 0 <= percent <= 100:
            raise ValueError("claude_cli_usage_unavailable")
        windows[label] = {"label": label, "utilization": percent if match[2].lower() == "used" else 100 - percent}
    if "5-hour" not in windows:
        raise ValueError("claude_cli_usage_unavailable")
    # Human reset descriptions have no reliable timezone. Do not invent one.
    return list(windows.values())


def probe_usage(access_token: str, *, timeout: float = 20.0) -> list[dict]:
    """Refuse until a command-only CLI transport has been verified.

    The CLI documents its positional argument as a model prompt. Passing
    /usage there cannot guarantee local command dispatch across versions.
    """
    raise ValueError("claude_cli_command_transport_unverified")


def _probe_usage(access_token: str, *, timeout: float = 20.0) -> list[dict]:
    """Run the installed CLI in a private PTY, then kill its process group.

    No trust, login or other interactive question is answered. Only /usage
    is requested. Output stays in memory and never reaches diagnostics.
    """
    if not access_token or len(access_token) > 65536 or any(ord(c) < 32 for c in access_token):
        raise ValueError("claude_cli_usage_unavailable")
    executable = resolve_cli("claude")
    if executable is None:
        raise ValueError("claude_cli_not_found")
    master, slave = pty.openpty()
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix="jrbar-claude-usage-") as working:
            environment = {
                key: value for key, value in os.environ.items()
                if not key.startswith(("CLAUDE", "ANTHROPIC"))
            }
            environment.update(
                TERM="xterm-256color", DISABLE_AUTOUPDATER="1",
                CLAUDE_CONFIG_DIR=working, CLAUDE_CODE_OAUTH_TOKEN=access_token,
                CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1",
            )
            try:
                process = subprocess.Popen(
                    [executable, "/usage"], stdin=slave, stdout=slave, stderr=slave,
                    cwd=working, start_new_session=True,
                    env=environment,
                )
                os.close(slave)
                slave = -1
                deadline = time.monotonic() + timeout
                output = bytearray()
                while time.monotonic() < deadline and len(output) < 256 * 1024:
                    remaining = max(0, deadline - time.monotonic())
                    ready, _, _ = select.select([master], [], [], min(0.25, remaining))
                    if ready:
                        try:
                            chunk = os.read(master, 8192)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output.extend(chunk)
                        text = output.decode("utf-8", errors="replace")
                        clean = _ANSI.sub("", text).lower()
                        if any(marker in clean for marker in (
                            "welcome to claude", "choose the text style", "select a theme",
                            "trust this folder", "trust this workspace", "trust the files",
                            "is this a project you created", "do you trust", "log in to continue",
                            "sign in to continue", "login method",
                        )):
                            raise ValueError("claude_cli_interaction_required")
                        try:
                            return parse_usage_screen(text)
                        except ValueError:
                            pass
                    elif process.poll() is not None:
                        break
                raise ValueError("claude_cli_usage_unavailable")
            finally:
                if process is not None:
                    _kill_group(process)
                    process.wait(timeout=2)

    except (OSError, subprocess.SubprocessError):
        raise ValueError("claude_cli_usage_unavailable") from None
    finally:
        os.close(master)
        if slave >= 0:
            os.close(slave)
