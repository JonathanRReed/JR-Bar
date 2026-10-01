"""Synthetic busy months of Claude and Codex transcripts, and the totals they hold.

Everything here is invented: session and message ids are counters, token
counts come from a seeded generator, and the files are written under a
temporary home. Each builder returns the *truth* it wrote, worked out from its
own bookkeeping and never from ``usage_stats``, so a test can compare the scan
with an expectation that does not share its code.

A busy Mac repeats itself. Claude Code writes one usage line per content
block, so a message appears two or three times in a row, and a resumed or
forked session copies older messages into a new file verbatim. Codex forks copy
their parent's token events, and a rollout can be copied whole. The builders
reproduce all of that, because the totals that matter are the ones that count
each message once.
"""

from __future__ import annotations

import os
import random
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

DAY = 24 * 60 * 60

#: Claude model names as the transcripts write them, and the key each one is
#: priced under (``usage_stats._record_model_key``). Four models, one of which
#: reads its cache at a different rate than the rest.
CLAUDE_MODELS = (
    "claude-opus-4-5-20251101",
    "claude-sonnet-4-5",
    "claude-haiku-4-5",
    "claude-fable-5-1",
)
CLAUDE_MODEL_KEYS = ("opus-4-5", "sonnet-4", "haiku", "fable-5-1")

CODEX_MODELS = ("gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-astra")


def card_window_start(now: float) -> float:
    """Local midnight at the start of the 30-day card window ending at ``now``.

    Written out again here, from the rule the docs state (today and the 29
    days before it, by this Mac's own calendar), so a test never takes its
    window from the code it checks.
    """
    today = datetime.fromtimestamp(now).date()
    first = today - timedelta(days=29)
    return datetime(first.year, first.month, first.day).timestamp()


def _stamp(epoch: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


@dataclass
class ClaudeTruth:
    """What the Claude files hold, one entry per distinct message id."""

    now: int
    #: message id -> (epoch, model name, input, cache read, cache write, output)
    messages: dict[str, tuple[int, str, int, int, int, int]] = field(default_factory=dict)
    raw_lines: int = 0
    files: list[Path] = field(default_factory=list)

    def add(self, mid: str, epoch: int, model: str, counts: tuple[int, int, int, int]) -> None:
        self.messages[mid] = (epoch, model, *counts)

    def window(self, start: float) -> dict:
        """Totals over the distinct messages at or after ``start``."""
        total = {"input": 0, "cached": 0, "creation": 0, "output": 0, "messages": 0}
        by_model: dict[str, list[int]] = {}
        for epoch, model, inp, cached, creation, out in self.messages.values():
            if epoch < start:
                continue
            total["input"] += inp
            total["cached"] += cached
            total["creation"] += creation
            total["output"] += out
            total["messages"] += 1
            row = by_model.setdefault(model, [0, 0, 0, 0, 0])
            row[0] += 1
            row[1] += inp
            row[2] += cached
            row[3] += creation
            row[4] += out
        total["models"] = len(by_model)
        total["by_model"] = by_model
        return total


def _claude_line(session: str, mid: str, epoch: int, model: str, counts: tuple[int, int, int, int]) -> str:
    inp, cached, creation, out = counts
    return (
        f'{{"type":"assistant","sessionId":"{session}","timestamp":"{_stamp(epoch)}",'
        f'"message":{{"id":"{mid}","model":"{model}","usage":{{"input_tokens":{inp},'
        f'"cache_read_input_tokens":{cached},"cache_creation_input_tokens":{creation},'
        f'"output_tokens":{out}}}}}}}\n'
    )


def _claude_chatter(session: str, epoch: int) -> str:
    """A line with no usage in it: the scan skips it before it is parsed."""
    return (
        f'{{"type":"user","sessionId":"{session}","timestamp":"{_stamp(epoch)}",'
        '"message":{"role":"user","content":"carry on"}}\n'
    )


def build_claude_month(
    home: Path,
    *,
    now: int,
    seed: int = 20260930,
    sessions: int = 64,
    messages_per_session: int = 2400,
    resumed_files: int = 6,
    resumed_copy_lines: int = 4000,
) -> ClaudeTruth:
    """A month of Claude transcripts under ``home/.claude/projects``.

    ``sessions`` files spread over 36 days, so the last six fall outside the
    30-day window, each holding ``messages_per_session`` distinct messages
    repeated one to three times. Three more files sit wholly in the past.
    ``resumed_files`` resumed sessions then copy ``resumed_copy_lines`` of an
    older file's lines verbatim before adding messages of their own.
    """
    rng = random.Random(seed)
    root = home / ".claude" / "projects"
    truth = ClaudeTruth(now=now)
    written: dict[Path, list[str]] = {}
    newest: dict[Path, int] = {}

    def new_file(project: int, name: str) -> Path:
        path = root / f"project-{project:02d}" / f"{name}.jsonl"
        written[path] = []
        newest[path] = 0
        truth.files.append(path)
        return path

    for index in range(sessions):
        path = new_file(index % 5, f"session-{index:03d}")
        session = f"claude-session-{index:03d}"
        # Sessions start between 36 days ago and an hour before now, and run
        # for up to six days, but never past an hour before now.
        span = rng.randrange(DAY // 4, 6 * DAY)
        started = now - span - 3600 - rng.randrange(0, 36 * DAY - span)
        model = CLAUDE_MODELS[index % len(CLAUDE_MODELS)]
        stamps = sorted(rng.randrange(started, started + span) for _ in range(messages_per_session))
        lines = written[path]
        for number, epoch in enumerate(stamps):
            mid = f"msg-{index:03d}-{number:05d}"
            counts = (
                rng.randrange(1, 3000),
                rng.randrange(0, 150_000),
                rng.randrange(0, 9000),
                rng.randrange(1, 4000),
            )
            # Most of a session runs on its own model; some turns use another.
            used = model if rng.random() < 0.85 else CLAUDE_MODELS[rng.randrange(len(CLAUDE_MODELS))]
            truth.add(mid, epoch, used, counts)
            if number % 9 == 0:
                lines.append(_claude_chatter(session, epoch))
            line = _claude_line(session, mid, epoch, used, counts)
            repeats = (1, 2, 3, 2)[number % 4]
            lines.extend([line] * repeats)
            newest[path] = max(newest[path], epoch)

    for index in range(3):
        path = new_file(index, f"ancient-{index}")
        session = f"claude-ancient-{index}"
        lines = written[path]
        for number in range(400):
            epoch = now - 40 * DAY - rng.randrange(0, 20 * DAY)
            mid = f"old-{index}-{number:04d}"
            counts = (rng.randrange(1, 3000), 0, 0, rng.randrange(1, 3000))
            truth.add(mid, epoch, CLAUDE_MODELS[0], counts)
            lines.append(_claude_line(session, mid, epoch, CLAUDE_MODELS[0], counts))
            newest[path] = max(newest[path], epoch)

    # Resumed sessions: older messages copied in whole, then new work.
    sources = [path for path in list(written) if "session-" in path.name]
    for index in range(resumed_files):
        source = sources[(index * 7) % len(sources)]
        path = new_file(index, f"resumed-{index:02d}")
        copied = [line for line in written[source] if '"usage"' in line][:resumed_copy_lines]
        lines = written[path]
        lines.extend(copied)
        newest[path] = newest[source]
        session = f"claude-resumed-{index:02d}"
        base = now - (index + 1) * 3600 * 5
        for number in range(1000):
            epoch = base - (1000 - number) * 17
            mid = f"resumed-{index:02d}-{number:04d}"
            counts = (rng.randrange(1, 3000), rng.randrange(0, 150_000), 0, rng.randrange(1, 4000))
            truth.add(mid, epoch, CLAUDE_MODELS[index % len(CLAUDE_MODELS)], counts)
            line = _claude_line(session, mid, epoch, CLAUDE_MODELS[index % len(CLAUDE_MODELS)], counts)
            lines.extend([line, line])
            newest[path] = max(newest[path], epoch)

    for path, lines in written.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(lines), encoding="utf-8")
        truth.raw_lines += sum(1 for line in lines if '"usage"' in line)
        # A transcript is last written when its newest message was.
        os.utime(path, (newest[path], newest[path]))
    return truth


def append_claude_messages(
    path: Path,
    truth: ClaudeTruth,
    *,
    count: int,
    start_epoch: int,
    prefix: str,
    seed: int,
    session: str = "claude-appended",
) -> int:
    """Append ``count`` new messages to ``path`` and record them in ``truth``.

    Returns the file's size before the append, so a test can check that a scan
    read only the bytes after it.
    """
    rng = random.Random(seed)
    before = path.stat().st_size
    lines = []
    for number in range(count):
        epoch = start_epoch + number
        mid = f"{prefix}-{number:05d}"
        counts = (rng.randrange(1, 3000), rng.randrange(0, 150_000), rng.randrange(0, 9000), rng.randrange(1, 4000))
        model = CLAUDE_MODELS[number % len(CLAUDE_MODELS)]
        truth.add(mid, epoch, model, counts)
        line = _claude_line(session, mid, epoch, model, counts)
        lines.extend([line, line])
        truth.raw_lines += 2
    with path.open("a", encoding="utf-8") as handle:
        handle.write("".join(lines))
    newest = start_epoch + count
    os.utime(path, (newest, newest))
    return before


# --- Codex -------------------------------------------------------------------


@dataclass
class CodexTruth:
    """What the rollouts hold, one entry per event that is its own session's."""

    now: int
    #: (session, event number) -> (epoch, model, input, cached, write, output)
    #: with input already split the way the scan stores it: ordinary input only.
    events: dict[tuple[str, int], tuple[int, str, int, int, int, int]] = field(default_factory=dict)
    raw_events: int = 0
    files: list[Path] = field(default_factory=list)
    #: session -> its events as written: (epoch, cumulative totals, last usage)
    rollouts: dict[str, list[tuple[int, tuple[int, int, int, int], tuple[int, int, int, int]]]] = field(
        default_factory=dict
    )
    models: dict[str, str] = field(default_factory=dict)
    paths: dict[str, Path] = field(default_factory=dict)
    starts: dict[str, int] = field(default_factory=dict)

    def window(self, start: float) -> dict:
        total = {"input": 0, "cached": 0, "write": 0, "output": 0, "events": 0}
        models: set[str] = set()
        for epoch, model, inp, cached, write, out in self.events.values():
            if epoch < start:
                continue
            total["input"] += inp
            total["cached"] += cached
            total["write"] += write
            total["output"] += out
            total["events"] += 1
            models.add(model)
        total["models"] = len(models)
        return total


def _codex_event(epoch: int, total: tuple[int, int, int, int], last: tuple[int, int, int, int]) -> str:
    return (
        f'{{"type":"event_msg","timestamp":"{_stamp(epoch)}","payload":{{"type":"token_count","info":{{'
        f'"total_token_usage":{{"input_tokens":{total[0]},"cached_input_tokens":{total[1]},'
        f'"cache_write_input_tokens":{total[2]},"output_tokens":{total[3]}}},'
        f'"last_token_usage":{{"input_tokens":{last[0]},"cached_input_tokens":{last[1]},'
        f'"cache_write_input_tokens":{last[2]},"output_tokens":{last[3]}}}}}}}}}\n'
    )


def _codex_meta(session: str, epoch: int, *, forked_from: str | None = None) -> str:
    fork = f'"forked_from_id":"{forked_from}",' if forked_from else ""
    return (
        f'{{"type":"session_meta","timestamp":"{_stamp(epoch)}",'
        f'"payload":{{"id":"{session}",{fork}"timestamp":"{_stamp(epoch)}"}}}}\n'
    )


def _codex_context(model: str, epoch: int) -> str:
    return f'{{"type":"turn_context","timestamp":"{_stamp(epoch)}","payload":{{"model":"{model}"}}}}\n'


def build_codex_month(
    home: Path,
    *,
    now: int,
    seed: int = 20260930,
    rollouts: int = 44,
    events_per_rollout: int = 2000,
    forks: int = 5,
    whole_copies: int = 2,
) -> CodexTruth:
    """A month of Codex rollouts under ``home/.codex/sessions``.

    ``rollouts`` files spread over 36 days. ``forks`` of them are forked by a
    child rollout that copies the first half of the parent's events and adds
    its own, and ``whole_copies`` are copied whole into a second file.
    """
    rng = random.Random(seed)
    root = home / ".codex" / "sessions"
    truth = CodexTruth(now=now)
    rollout_events: dict[str, list[tuple[int, tuple[int, int, int, int], tuple[int, int, int, int]]]] = {}
    rollout_model: dict[str, str] = {}
    rollout_start: dict[str, int] = {}

    def split(last: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
        inp, cached, write, out = last
        return (max(0, inp - cached - write), cached, write, out)

    for index in range(rollouts):
        session = f"codex-session-{index:03d}"
        span = rng.randrange(DAY // 4, 5 * DAY)
        started = now - span - 3600 - rng.randrange(0, 36 * DAY - span)
        model = CODEX_MODELS[index % len(CODEX_MODELS)]
        stamps = sorted(rng.randrange(started, started + span) for _ in range(events_per_rollout))
        totals = [0, 0, 0, 0]
        events = []
        for epoch in stamps:
            cached = rng.randrange(0, 40_000)
            write = rng.randrange(0, 2000)
            inp = cached + write + rng.randrange(1, 6000)
            out = rng.randrange(1, 3000)
            last = (inp, cached, write, out)
            # Every event adds tokens, so no two share a cumulative endpoint.
            totals = [totals[0] + inp, totals[1] + cached, totals[2] + write, totals[3] + out]
            events.append((epoch, tuple(totals), last))
        rollout_events[session] = events
        rollout_model[session] = model
        rollout_start[session] = started
        for number, (epoch, _total, last) in enumerate(events):
            truth.events[(session, number)] = (epoch, model, *split(last))

    def write_rollout(path: Path, lines: list[str], newest: int) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(lines), encoding="utf-8")
        os.utime(path, (newest, newest))
        truth.files.append(path)
        truth.raw_events += sum(1 for line in lines if '"token_count"' in line)

    names = sorted(rollout_events)
    for session in names:
        events = rollout_events[session]
        lines = [
            _codex_meta(session, rollout_start[session] - 60),
            _codex_context(rollout_model[session], rollout_start[session] - 30),
        ]
        lines.extend(_codex_event(epoch, total, last) for epoch, total, last in events)
        write_rollout(root / "2026" / f"rollout-{session}.jsonl", lines, events[-1][0])
        truth.paths[session] = root / "2026" / f"rollout-{session}.jsonl"
        truth.rollouts[session] = events
        truth.models[session] = rollout_model[session]
        truth.starts[session] = rollout_start[session]

    # A fork's own events come after its boundary, so its parent must have
    # reached the halfway point well before now.
    forkable = [
        name for name in names
        if rollout_events[name][len(rollout_events[name]) // 2 - 1][0] < now - DAY
    ]
    for index in range(forks):
        parent = forkable[(index * 5) % len(forkable)]
        events = rollout_events[parent]
        keep = len(events) // 2
        child = f"codex-fork-{index:02d}"
        boundary = events[keep - 1][0] + 30
        lines = [
            _codex_meta(child, boundary, forked_from=parent),
            _codex_context(rollout_model[parent], boundary),
        ]
        lines.extend(_codex_event(epoch, total, last) for epoch, total, last in events[:keep])
        totals = list(events[keep - 1][1])
        newest = boundary
        for number in range(600):
            epoch = boundary + 60 + number * 45
            cached = rng.randrange(0, 40_000)
            write = rng.randrange(0, 2000)
            inp = cached + write + rng.randrange(1, 6000)
            out = rng.randrange(1, 3000)
            last = (inp, cached, write, out)
            totals = [totals[0] + inp, totals[1] + cached, totals[2] + write, totals[3] + out]
            lines.append(_codex_event(epoch, tuple(totals), last))
            truth.events[(child, number)] = (epoch, rollout_model[parent], *split(last))
            newest = max(newest, epoch)
        write_rollout(root / "2026" / f"rollout-{child}.jsonl", lines, newest)

    for index in range(whole_copies):
        session = names[(index * 11 + 3) % len(names)]
        events = rollout_events[session]
        lines = [
            _codex_meta(session, rollout_start[session] - 60),
            _codex_context(rollout_model[session], rollout_start[session] - 30),
        ]
        lines.extend(_codex_event(epoch, total, last) for epoch, total, last in events)
        write_rollout(root / "copies" / f"rollout-copy-{index}.jsonl", lines, events[-1][0])
    return truth


def append_codex_events(
    path: Path,
    truth: CodexTruth,
    *,
    session: str,
    first_total: tuple[int, int, int, int],
    count: int,
    start_epoch: int,
    seed: int,
    model: str,
) -> tuple[int, tuple[int, int, int, int]]:
    """Append ``count`` events that continue a rollout's cumulative totals.

    Returns the file size before the append and the new cumulative totals.
    """
    rng = random.Random(seed)
    before = path.stat().st_size
    totals = list(first_total)
    lines = []
    number0 = sum(1 for key in truth.events if key[0] == session)
    for number in range(count):
        epoch = start_epoch + number * 7
        cached = rng.randrange(0, 40_000)
        write = rng.randrange(0, 2000)
        inp = cached + write + rng.randrange(1, 6000)
        out = rng.randrange(1, 3000)
        totals = [totals[0] + inp, totals[1] + cached, totals[2] + write, totals[3] + out]
        lines.append(_codex_event(epoch, tuple(totals), (inp, cached, write, out)))
        truth.events[(session, number0 + number)] = (
            epoch, model, max(0, inp - cached - write), cached, write, out,
        )
        truth.raw_events += 1
    with path.open("a", encoding="utf-8") as handle:
        handle.write("".join(lines))
    newest = start_epoch + count * 7
    os.utime(path, (newest, newest))
    return before, (totals[0], totals[1], totals[2], totals[3])


def write_codex_copy(path: Path, truth: CodexTruth, session: str) -> None:
    """A whole copy of ``session``'s rollout under another name. It adds nothing."""
    lines = [
        _codex_meta(session, truth.starts[session] - 60),
        _codex_context(truth.models[session], truth.starts[session] - 30),
    ]
    lines.extend(_codex_event(epoch, total, last) for epoch, total, last in truth.rollouts[session])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(lines), encoding="utf-8")
    newest = truth.rollouts[session][-1][0]
    os.utime(path, (newest, newest))
    truth.raw_events += len(truth.rollouts[session])


def write_codex_fork(
    path: Path,
    truth: CodexTruth,
    parent: str,
    child: str,
    *,
    copied: int,
    own: int,
    start_epoch: int,
    seed: int,
) -> None:
    """A fork of ``parent`` that copies its first ``copied`` events verbatim, then
    adds ``own`` events of its own from ``start_epoch``. Only the own events are new."""
    rng = random.Random(seed)
    events = truth.rollouts[parent]
    boundary = start_epoch - 30
    lines = [
        _codex_meta(child, boundary, forked_from=parent),
        _codex_context(truth.models[parent], boundary),
    ]
    lines.extend(_codex_event(epoch, total, last) for epoch, total, last in events[:copied])
    truth.raw_events += copied
    totals = list(events[copied - 1][1])
    newest = start_epoch
    for number in range(own):
        epoch = start_epoch + number * 9
        cached = rng.randrange(0, 40_000)
        write = rng.randrange(0, 2000)
        inp = cached + write + rng.randrange(1, 6000)
        out = rng.randrange(1, 3000)
        totals = [totals[0] + inp, totals[1] + cached, totals[2] + write, totals[3] + out]
        lines.append(_codex_event(epoch, tuple(totals), (inp, cached, write, out)))
        truth.events[(child, number)] = (
            epoch, truth.models[parent], max(0, inp - cached - write), cached, write, out,
        )
        truth.raw_events += 1
        newest = epoch
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(lines), encoding="utf-8")
    os.utime(path, (newest, newest))
