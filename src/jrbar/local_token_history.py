"""Local token history for Pi, Grok, Gemini CLI and OpenClaw.

Claude, Codex, OpenCode and T3 already had a token history read from their
own files; these four had none, so the usage graph and the Usage Center
showed them empty. Each reader here walks one agent's own session files,
read-only and bounded, and yields the same record tuple the other scans
do: ``(provider, session, model, epoch, input, cache_read, cache_write,
output, dedupe_key)``.

The formats come from ccusage's MIT adapters, read as documentation:

- Pi: ``$PI_CODING_AGENT_DIR`` or ``~/.pi/agent/sessions/**/*.jsonl``,
  assistant ``message`` records with ``usage.{input, output, cacheRead,
  cacheWrite}``. ``subagent-artifacts/`` transcripts repeat calls the main
  session already recorded and are skipped.
- Grok: ``$GROK_HOME`` or ``~/.grok/sessions/**/updates.jsonl``, only
  ``turn_completed`` updates, where ``inputTokens`` includes cached reads.
- Gemini CLI: ``~/.gemini/tmp/*/chats/*.json``, ``messages[]`` of type
  ``gemini`` with ``tokens.{input, output, cached, thoughts, tool}``.
- OpenClaw: ``$OPENCLAW_DIR`` or ``~/.openclaw``, session JSONL and the
  per-agent ``agents/*/agent/openclaw-agent.sqlite`` ``transcript_events``,
  which win over a migrated JSONL copy of the same event.

Count each source once (CodexBar's rule): Pi and OpenClaw can run on a
Claude or Codex subscription, but their records are always Pi's and
OpenClaw's own. They are never added to the Claude or Codex totals, which
come only from those CLIs' own transcripts, so no token is counted twice.
Every record carries a dedupe key, and a key seen twice is kept once.
"""

from __future__ import annotations

import json
import os
import sqlite3
from collections.abc import Iterable, Iterator, Mapping
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

LOCAL_HISTORY_PROVIDERS = ("pi", "grok", "gemini", "openclaw")
MAX_FILES = 4000
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_LINE_BYTES = 4 * 1024 * 1024
MAX_SQLITE_ROWS = 200_000


def _home(home: Path | str | None) -> Path:
    return Path.home() if home is None else Path(home)


def _environment(env: Mapping[str, str] | None) -> Mapping[str, str]:
    return os.environ if env is None else env


def _absolute(value: object) -> Path | None:
    if not isinstance(value, str) or not value.strip():
        return None
    path = Path(os.path.expanduser(value.strip()))
    return path if path.is_absolute() else None


def pi_root(*, env=None, home=None) -> Path:
    environment = _environment(env)
    configured = _absolute(environment.get("PI_CODING_AGENT_DIR")) or _absolute(environment.get("PI_AGENT_DIR"))
    if configured is not None:
        return configured if configured.name == "sessions" else configured / "sessions"
    return _home(home) / ".pi" / "agent" / "sessions"


def grok_root(*, env=None, home=None) -> Path:
    return (_absolute(_environment(env).get("GROK_HOME")) or _home(home) / ".grok") / "sessions"


def gemini_root(*, env=None, home=None) -> Path:
    return (_absolute(_environment(env).get("GEMINI_DATA_DIR")) or _home(home) / ".gemini") / "tmp"


def openclaw_root(*, env=None, home=None) -> Path:
    return _absolute(_environment(env).get("OPENCLAW_DIR")) or _home(home) / ".openclaw"


def roots(*, env=None, home=None) -> dict[str, Path]:
    return {
        "pi": pi_root(env=env, home=home),
        "grok": grok_root(env=env, home=home),
        "gemini": gemini_root(env=env, home=home),
        "openclaw": openclaw_root(env=env, home=home),
    }


def _number(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return max(0, int(value))


def _epoch(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        return number / 1000.0 if number > 1e11 else number
    if isinstance(value, str) and value.strip():
        try:
            return datetime.fromisoformat(value.strip().replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


def _files(root: Path, pattern: str, since_epoch: float) -> Iterator[Path]:
    """Regular files under ``root`` matching ``pattern`` changed since
    ``since_epoch``, never following a symlink, at most ``MAX_FILES``."""
    if not root.is_dir():
        return
    seen = 0
    for path in sorted(root.rglob(pattern)):
        if seen >= MAX_FILES:
            return
        try:
            info = path.lstat()
        except OSError:
            continue
        if path.is_symlink() or not path.is_file() or info.st_size > MAX_FILE_BYTES:
            continue
        if info.st_mtime < since_epoch:
            continue
        seen += 1
        yield path


def _json_lines(path: Path) -> Iterator[dict]:
    try:
        with path.open("rb") as handle:
            for raw in handle:
                if len(raw) > MAX_LINE_BYTES or b"{" not in raw:
                    continue
                try:
                    document = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(document, dict):
                    yield document
    except OSError:
        return


def _message_record(provider: str, session: str, line: dict, since_epoch: float, key: str) -> tuple | None:
    """Pi's and OpenClaw's shared shape: an assistant ``message`` with ``usage``."""
    if line.get("type") not in (None, "message"):
        return None
    message = line.get("message")
    if not isinstance(message, dict) or message.get("role") != "assistant":
        return None
    usage = message.get("usage")
    if not isinstance(usage, dict):
        return None
    epoch = _epoch(message.get("timestamp")) or _epoch(line.get("timestamp"))
    if epoch is None or epoch < since_epoch:
        return None
    model = message.get("modelId") or message.get("model")
    return (
        provider,
        session,
        str(model).strip()[:128] if isinstance(model, str) and model.strip() else provider,
        epoch,
        _number(usage.get("input")),
        _number(usage.get("cacheRead")),
        _number(usage.get("cacheWrite")),
        _number(usage.get("output")),
        key,
    )


def scan_pi_records(root: Path, since_epoch: float) -> list[tuple]:
    records = []
    for path in _files(root, "*.jsonl", since_epoch):
        if "subagent-artifacts" in path.parts:
            continue
        session = f"pi:{path.stem}"
        for index, line in enumerate(_json_lines(path)):
            key = f"pi:{line.get('id') or f'{path.name}:{index}'}"
            record = _message_record("pi", session, line, since_epoch, key)
            if record is not None:
                records.append(record)
    return records


def scan_grok_records(root: Path, since_epoch: float) -> list[tuple]:
    records = []
    for path in _files(root, "updates.jsonl", since_epoch):
        session = f"grok:{path.parent.name}"
        for index, line in enumerate(_json_lines(path)):
            params = line.get("params") if isinstance(line.get("params"), dict) else {}
            update = params.get("update") if isinstance(params.get("update"), dict) else {}
            if update.get("sessionUpdate") != "turn_completed":
                continue
            meta = params.get("_meta") if isinstance(params.get("_meta"), dict) else {}
            epoch = _epoch(meta.get("agentTimestampMs")) or _epoch(line.get("timestamp"))
            if epoch is None or epoch < since_epoch:
                continue
            usage = update.get("usage") if isinstance(update.get("usage"), dict) else {}
            by_model = usage.get("modelUsage") if isinstance(usage.get("modelUsage"), dict) else {}
            parts = by_model.items() if by_model else (("grok", usage),)
            event = meta.get("eventId") or f"{path.parent.name}:{index}"
            for model, entry in parts:
                if not isinstance(entry, dict):
                    continue
                total_in = _number(entry.get("inputTokens"))
                cache_read = min(total_in, _number(entry.get("cachedReadTokens")))
                cache_write = min(total_in - cache_read, _number(entry.get("cacheCreationTokens")))
                records.append(
                    (
                        "grok",
                        session,
                        str(model)[:128],
                        epoch,
                        total_in - cache_read - cache_write,
                        cache_read,
                        cache_write,
                        _number(entry.get("outputTokens")),
                        f"grok:{event}:{model}",
                    )
                )
    return records


def _gemini_tokens(tokens: dict) -> tuple[int, int, int]:
    """(uncached input, cached, output) from a Gemini ``tokens`` block.

    When ``total`` shows the cached tokens were already inside ``input``,
    they are taken out of it so no token counts twice."""
    input_tokens = _number(tokens.get("input", tokens.get("prompt")))
    output = _number(tokens.get("output", tokens.get("candidates")))
    cached = _number(tokens.get("cached"))
    thoughts = _number(tokens.get("thoughts"))
    tool = _number(tokens.get("tool"))
    total = tokens.get("total")
    inclusive = input_tokens + output + thoughts + tool
    if cached and isinstance(total, (int, float)) and int(total) == inclusive:
        input_tokens = max(0, input_tokens - cached)
    return input_tokens, cached, output + thoughts


def scan_gemini_records(root: Path, since_epoch: float) -> list[tuple]:
    records = []
    if not root.is_dir():
        return records
    for path in _files(root, "*.json", since_epoch):
        if path.parent.name != "chats":
            continue
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError):
            continue
        if not isinstance(document, dict) or not isinstance(document.get("messages"), list):
            continue
        session = f"gemini:{document.get('sessionId') or path.stem}"
        fallback = _epoch(document.get("startTime")) or _epoch(document.get("lastUpdated"))
        for index, message in enumerate(document["messages"]):
            if not isinstance(message, dict) or message.get("type") != "gemini":
                continue
            tokens = message.get("tokens")
            if not isinstance(tokens, dict):
                continue
            epoch = _epoch(message.get("timestamp")) or fallback
            if epoch is None or epoch < since_epoch:
                continue
            uncached, cached, output = _gemini_tokens(tokens)
            model = message.get("model") if isinstance(message.get("model"), str) else "gemini"
            records.append(
                ("gemini", session, model[:128], epoch, uncached, cached, 0, output,
                 f"gemini:{session}:{message.get('id') or index}")
            )
    return records


def _sqlite_events(path: Path) -> Iterator[tuple[str, int, dict]]:
    uri = f"file:{quote(str(path))}?mode=ro"
    try:
        with sqlite3.connect(uri, uri=True, timeout=1.0) as connection:
            connection.execute("PRAGMA query_only=ON")
            present = connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='transcript_events'"
            ).fetchone()
            if not present:
                return
            rows = connection.execute(
                "SELECT session_id, seq, event_json FROM transcript_events ORDER BY session_id, seq LIMIT ?",
                (MAX_SQLITE_ROWS,),
            ).fetchall()
    except sqlite3.Error:
        return
    for session_id, seq, event_json in rows:
        try:
            event = json.loads(event_json)
        except (TypeError, ValueError):
            continue
        if isinstance(event, dict):
            yield str(session_id), int(seq or 0), event


def scan_openclaw_records(root: Path, since_epoch: float) -> list[tuple]:
    records: list[tuple] = []
    if not root.is_dir():
        return records
    database_keys: set[str] = set()
    agents = root / "agents"
    if agents.is_dir():
        for database in sorted(agents.glob("*/agent/openclaw-agent.sqlite"))[:64]:
            for session_id, seq, event in _sqlite_events(database):
                key = f"openclaw:{event.get('id') or f'{session_id}:{seq}'}"
                record = _message_record("openclaw", f"openclaw:{session_id}", event, since_epoch, key)
                if record is not None:
                    database_keys.add(key)
                    records.append(record)
    for path in _files(root, "*.jsonl", since_epoch):
        session = f"openclaw:{path.stem}"
        for index, line in enumerate(_json_lines(path)):
            key = f"openclaw:{line.get('id') or f'{path.name}:{index}'}"
            if key in database_keys:
                continue  # the database copy wins over a migrated JSONL copy
            record = _message_record("openclaw", session, line, since_epoch, key)
            if record is not None:
                records.append(record)
    return records


_SCANNERS = {
    "pi": scan_pi_records,
    "grok": scan_grok_records,
    "gemini": scan_gemini_records,
    "openclaw": scan_openclaw_records,
}


def scan_local_records(
    provider_ids: Iterable[str],
    since_epoch: float,
    *,
    env: Mapping[str, str] | None = None,
    home: Path | str | None = None,
) -> list[tuple]:
    """Every record for the wanted providers among the four, each dedupe
    key once."""
    places = roots(env=env, home=home)
    seen: set[str] = set()
    records: list[tuple] = []
    for provider in provider_ids:
        scanner = _SCANNERS.get(provider)
        if scanner is None:
            continue
        try:
            found = scanner(places[provider], since_epoch)
        except (OSError, ValueError):
            continue
        for record in found:
            if record[8] in seen:
                continue
            seen.add(record[8])
            records.append(record)
    return records


__all__ = [
    "LOCAL_HISTORY_PROVIDERS",
    "roots",
    "scan_gemini_records",
    "scan_grok_records",
    "scan_local_records",
    "scan_openclaw_records",
    "scan_pi_records",
]
