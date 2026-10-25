"""Claude Code's command-only usage probe. Unverified versions fail closed."""

from __future__ import annotations

import codecs
import fcntl
import json
import os
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time
from dataclasses import dataclass, field
from pathlib import Path

from .provider_cli import _kill_group, installed_version, resolve_cli

# Add a version only after its supervised command dispatch and audit succeed.
VERIFIED_VERSIONS: frozenset[str] = frozenset()
_CANDIDATE_VERSION = "2.1.309"
_model_turn_detected = False
_ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
_LABELS = (
    ("Current session", "5-hour"),
    ("Current week (all models)", "Weekly"),
    ("Current week (Sonnet only)", "weekly-sonnet"),
    ("Current week (Sonnet)", "weekly-sonnet"),
    ("Current week (Opus)", "weekly-opus"),
)
_BLOCKERS = (
    "welcome to claude", "choose the text style", "select a theme", "onboarding",
    "trust this folder", "trust this workspace", "trust the files", "ready to code here",
    "is this a project you created", "do you trust", "quick safety check", "login",
    "log in", "sign in", "api key", "select an option", "choose an option",
    "enter to confirm", "enter to select", "yes / no", "yes, i trust",
)


def parse_usage_screen(text: str) -> list[dict]:
    """Require complete labelled session and weekly sections on one screen."""
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
            raise ValueError("claude_cli_usage_unavailable")
        percent = float(match[1])
        if not 0 <= percent <= 100 or label in windows:
            raise ValueError("claude_cli_usage_unavailable")
        windows[label] = {"label": label, "utilization": percent if match[2].lower() == "used" else 100 - percent}
    if "5-hour" not in windows or "Weekly" not in windows or re.search(r"loading|fetching", clean, re.I):
        raise ValueError("claude_cli_usage_unavailable")
    # Human reset descriptions have no reliable timezone. Do not invent one.
    return list(windows.values())


class _Screen:
    """Bounded VT cursor/erase reconstruction, without scrollback or replies."""

    def __init__(self):
        self.rows = [[" "] * 140 for _ in range(70)]
        self.selected = [[False] * 140 for _ in range(70)]
        self.row = self.column = 0
        self.highlight = False
        self.pending = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, chunk: bytes):
        text = self.pending + self.decoder.decode(chunk)
        self.pending = ""
        index = 0
        while index < len(text):
            char = text[index]
            if char == "\x1b":
                match = re.match(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[=>78])", text[index:])
                if match is None:
                    self.pending = text[index:]
                    if len(self.pending) > 8192:
                        raise ValueError("claude_cli_unknown_terminal_sequence")
                    return
                sequence = match[0]
                if sequence.startswith("\x1b["):
                    self._control(sequence[2:-1], sequence[-1])
                index += len(sequence)
                continue
            if char == "\r":
                self.column = 0
            elif char == "\n":
                self.row += 1
                if self.row >= len(self.rows):
                    self.rows.pop(0)
                    self.rows.append([" "] * 140)
                    self.selected.pop(0)
                    self.selected.append([False] * 140)
                    self.row = len(self.rows) - 1
            elif char == "\b":
                self.column = max(0, self.column - 1)
            elif char == "\t":
                self.column = min(139, (self.column // 8 + 1) * 8)
            elif char >= " " and char != "\x7f":
                if self.column >= 140:
                    raise ValueError("claude_cli_screen_overflow")
                self.rows[self.row][self.column] = char
                self.selected[self.row][self.column] = self.highlight
                self.column += 1
            index += 1

    def _control(self, arguments: str, command: str):
        if arguments.startswith("?"):
            # Cursor visibility, bracketed paste, synchronized rendering.
            if command in "hl" and all(value in {"25", "2004", "2026", "1004"} for value in arguments[1:].split(";")):
                return
            raise ValueError("claude_cli_unknown_terminal_sequence")
        values = [int(value or 0) for value in arguments.split(";")] if arguments else [0]
        amount = values[0] or 1
        if command == "m":
            index = 0
            while index < len(values):
                value = values[index]
                if value in {0, 27, 49}:
                    self.highlight = False
                elif value == 7 or 40 <= value <= 47 or 100 <= value <= 107:
                    self.highlight = True
                elif value in {38, 48}:
                    if value == 48:
                        self.highlight = True
                    # RGB components are not independent SGR instructions.
                    index += 4 if values[index + 1:index + 2] == [2] else 2
                index += 1
        elif command in "ABCD":
            if command == "A":
                self.row = max(0, self.row - amount)
            if command == "B":
                self.row = min(69, self.row + amount)
            if command == "C":
                self.column = min(139, self.column + amount)
            if command == "D":
                self.column = max(0, self.column - amount)
        elif command in "HF":
            self.row = max(0, min(69, (values[0] or 1) - 1)) if command == "H" else max(0, self.row - amount)
            self.column = max(0, min(139, ((values[1] if len(values) > 1 else 1) or 1) - 1)) if command == "H" else 0
        elif command == "G":
            self.column = min(139, amount - 1)
        elif command in "JK":
            mode = values[0]
            if mode not in {0, 1, 2, 3}:
                raise ValueError("claude_cli_unknown_terminal_sequence")
            for row in range(70):
                for column in range(140):
                    position = (row, column)
                    cursor = (self.row, self.column)
                    clear = mode in {2, 3} or (position >= cursor if mode == 0 else position <= cursor)
                    if clear and (command == "J" or row == self.row):
                        self.rows[row][column] = " "
                        self.selected[row][column] = False
        elif command not in {"n", "q", "t"}:
            raise ValueError("claude_cli_unknown_terminal_sequence")

    def text(self):
        return "\n".join("".join(row).rstrip() for row in self.rows).rstrip()

    def usage_selected(self):
        for row, highlights in zip(self.rows, self.selected, strict=True):
            line = "".join(row).strip()
            if re.fullmatch(r"[\u276f>] ?/usage\s+Show session cost(?:, plan usage, and activity stats| and plan usage)", line):
                return True
            if re.fullmatch(r"/usage\s+Show session cost(?:, plan usage, and activity stats| and plan usage)", line):
                start = "".join(row).index("/usage")
                if all(highlights[start:start + 6]):
                    return True
        return False


@dataclass
class ProbeEvidence:
    """Only the supervised verifier retains redacted screens and sent bytes."""

    version: str | None = None
    sent_hex: list[str] = field(default_factory=list)
    screens: list[str] = field(default_factory=list)
    audit: dict = field(default_factory=dict)
    wall_seconds: float = 0

    def capture(self, text: str):
        # Keep only known UI vocabulary. Names, orgs, paths and tokens never persist.
        lines = []
        for line in text.splitlines():
            line = line.strip()
            safe = (
                re.fullmatch(r"[\u276f>]?(?: /usage)?", line)
                or re.fullmatch(r"(?:[\u276f>] )?/usage\s+Show session cost(?:, plan usage, and activity stats| and plan usage)", line)
                or line in {heading for heading, _ in _LABELS}
                or re.fullmatch(r"\d{1,3}(?:\.\d+)?% (?:used|left|remaining)", line)
                or line.lower() in {"loading usage", "esc to cancel", "escape to close", "? for shortcuts"}
            )
            lines.append(line if safe else "[redacted]")
        screen = "\n".join(lines)
        if not self.screens or screen != self.screens[-1]:
            if len(self.screens) >= 128:
                raise ValueError("claude_cli_screen_limit")
            self.screens.append(screen)


def _audit_projects(config: Path) -> dict:
    files = list((config / "projects").rglob("*.jsonl"))
    assistant = model = usage = records = 0
    size = 0
    for path in files:
        size += path.stat().st_size
        if size > 4 * 1024 * 1024 or path.is_symlink():
            raise ValueError("claude_cli_audit_unavailable")
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            record = json.loads(line)
            records += 1
            message = record.get("message") or {}
            assistant += int(record.get("type") == "assistant" or message.get("role") == "assistant")
            model += int(bool(record.get("model") or message.get("model") or message.get("role") == "model"))
            usage += int(bool(record.get("usage") or message.get("usage")))
    return {"files": len(files), "records": records, "assistant_entries": assistant,
            "model_entries": model, "usage_entries": usage}


def _lock_out(settings_path: Path | None):
    from .provider_usage_settings import load_provider_usage_settings, save_provider_usage_settings

    loaded = load_provider_usage_settings(settings_path)
    settings = loaded.settings
    for preference in settings.providers:
        if preference.provider_id == "claude":
            settings = settings.with_option("claude", "cli_fallback", "false",
                                            source_instance_id=preference.source_instance_id)
            settings = settings.with_option("claude", "cli_fallback_disabled", "true",
                                            source_instance_id=preference.source_instance_id)
    save_provider_usage_settings(settings, settings_path, loaded=loaded)


def probe_usage(access_token: str, *, timeout: float = 20.0, settings_path: Path | None = None) -> list[dict]:
    """Launch only CLI versions whose supervised safety check passed."""
    return _probe_usage(access_token, timeout=timeout, settings_path=settings_path, allowed_versions=VERIFIED_VERSIONS)


def _probe_usage(
    access_token: str, *, timeout: float = 20.0, settings_path: Path | None = None,
    evidence: ProbeEvidence | None = None, allowed_versions: frozenset[str] = VERIFIED_VERSIONS,
) -> list[dict]:
    """Drive one isolated session. The verifier explicitly opts into a candidate version."""
    from .provider_usage_settings import load_provider_usage_settings

    global _model_turn_detected
    if _model_turn_detected:
        raise ValueError("claude_cli_permanently_disabled")
    if any(p.option("cli_fallback_disabled") == "true" for p in load_provider_usage_settings(settings_path).settings.providers
           if p.provider_id == "claude"):
        raise ValueError("claude_cli_permanently_disabled")
    if not allowed_versions or not allowed_versions <= {_CANDIDATE_VERSION}:
        raise ValueError("claude_cli_command_transport_unverified")
    if not access_token or len(access_token) > 65536 or any(ord(c) < 32 for c in access_token):
        raise ValueError("claude_cli_usage_unavailable")
    executable = resolve_cli("claude")
    if executable is None:
        raise ValueError("claude_cli_not_found")
    executable = os.path.realpath(executable)
    evidence = evidence if evidence is not None else ProbeEvidence()
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="jrbar-claude-usage-") as temporary:
        root = Path(temporary).resolve()
        config, working, home = (root / name for name in ("config", "cwd", "home"))
        for directory in (config, working, home):
            directory.mkdir(mode=0o700)
        environment = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG") if key in os.environ}
        environment.update(
            HOME=str(home), TERM="xterm-256color", DISABLE_AUTOUPDATER="1",
            CLAUDE_CONFIG_DIR=str(config), CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1",
        )
        version = installed_version(executable, cwd=working, env=environment, timeout_seconds=5)
        evidence.version = version
        if version not in allowed_versions:
            raise ValueError("claude_cli_version_unverified")
        (config / ".claude.json").write_text(json.dumps({
            "hasCompletedOnboarding": True, "lastOnboardingVersion": version, "theme": "dark",
            "projects": {str(working): {"hasTrustDialogAccepted": True}},
        }))
        os.chmod(config / ".claude.json", 0o600)
        master, slave = pty.openpty()
        process = None
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 70, 140, 0, 0))
            with tempfile.TemporaryFile(dir=config) as token_file:
                os.fchmod(token_file.fileno(), 0o600)
                token_file.write(access_token.encode())
                token_file.seek(0)
                environment["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"] = str(token_file.fileno())
                settings = json.dumps({"disableAllHooks": True, "remoteControlAtStartup": False})
                process = subprocess.Popen(
                    [executable, "--allowed-tools", "", "--tools", "", "--strict-mcp-config",
                     "--settings", settings, "--setting-sources", "", "--safe-mode", "--no-chrome"],
                    stdin=slave, stdout=slave, stderr=slave, cwd=working, env=environment,
                    start_new_session=True, pass_fds=(token_file.fileno(),),
                )
                os.close(slave)
                slave = -1
                screen = _Screen()
                state = "idle"
                deadline = time.monotonic() + timeout
                last_change = time.monotonic()
                previous = ""
                total = 0
                result = None

                def send(data: bytes):
                    written = os.write(master, data)
                    evidence.sent_hex.append(data[:written].hex())
                    if written != len(data):
                        raise ValueError("claude_cli_write_failed")

                while time.monotonic() < deadline:
                    ready, _, _ = select.select([master], [], [], min(0.05, max(0, deadline - time.monotonic())))
                    if ready:
                        try:
                            chunk = os.read(master, 8192)
                        except OSError:
                            break
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > 256 * 1024:
                            raise ValueError("claude_cli_output_too_large")
                        screen.feed(chunk)
                    text = screen.text()
                    if text != previous:
                        previous = text
                        last_change = time.monotonic()
                        evidence.capture(text)
                    if any(marker in text.lower() for marker in _BLOCKERS) or re.search(r"(?m)^\s*[\u276f>] ?[1-9][.)] ", text):
                        raise ValueError("claude_cli_interaction_required")
                    if process.poll() is not None:
                        break
                    # A rendered screen must settle; terminal control traffic alone is not a redraw.
                    if screen.pending or time.monotonic() - last_change < 0.35:
                        continue
                    if state == "idle" and re.search(r"(?m)^\s*[\u276f>]\s*$", text) and "? for shortcuts" in text:
                        send(b"/usage")
                        state = "menu"
                    elif state == "menu" and screen.usage_selected():
                        send(b"\r")
                        state = "usage"
                    elif state == "usage":
                        try:
                            result = parse_usage_screen(text)
                        except ValueError:
                            continue
                        send(b"\x1b")
                        state = "exit"
                        last_change = time.monotonic()
                    elif state == "exit" and re.search(r"(?m)^\s*[\u276f>]\s*$", text) and "Current session" not in text:
                        send(b"/exit")
                        return result
                raise ValueError("claude_cli_usage_unavailable")
        except (OSError, subprocess.SubprocessError):
            raise ValueError("claude_cli_usage_unavailable") from None
        finally:
            if process is not None:
                _kill_group(process)
                process.wait(timeout=2)
            os.close(master)
            if slave >= 0:
                os.close(slave)
            try:
                evidence.audit = _audit_projects(config)
            except (OSError, ValueError, TypeError, AttributeError):
                evidence.audit = {"unavailable": True}
                raise ValueError("claude_cli_audit_unavailable") from None
            finally:
                evidence.wall_seconds = round(time.monotonic() - started, 3)
            if any(evidence.audit[key] for key in ("assistant_entries", "model_entries", "usage_entries")):
                _model_turn_detected = True
                try:
                    _lock_out(settings_path)
                except (OSError, ValueError):
                    raise ValueError("claude_cli_model_turn_detected_settings_write_failed") from None
                raise ValueError("claude_cli_model_turn_detected")
