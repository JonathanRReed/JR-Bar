"""Bounded JSONL tails that resume at the last observed byte."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class TranscriptRow:
    text: str
    decoded: Any = None
    loaded: bool = False
    context: object = None
    result: Any = None

    @property
    def value(self):
        if not self.loaded:
            try:
                self.decoded = json.loads(self.text)
            except ValueError:
                self.decoded = None
            self.loaded = True
        return self.decoded

    def memo(self, context, build):
        if self.context != context:
            self.result = build(self.value)
            self.context = context
            # The raw line can rebuild a row when its incoming context changes.
            # Do not retain a second parsed copy of the event's message bodies.
            self.decoded = None
            self.loaded = False
        return self.result


@dataclass
class TranscriptTail:
    maximum_bytes: int
    identity: tuple[int, int] | None = None
    size: int = 0
    data: bytes = b""
    rows: dict[str, TranscriptRow] = field(default_factory=dict)

    def update(self, path: Path) -> None:
        with path.open("rb") as handle:
            stat = os.fstat(handle.fileno())
            identity = (stat.st_dev, stat.st_ino)
            append = self.identity == identity and stat.st_size > self.size
            if append:
                # Check the old end as well. A truncate-and-regrow between
                # scans must not join the old prefix to a replacement file.
                guard = self.data[-256:]
                handle.seek(self.size - len(guard))
                append = handle.read(len(guard)) == guard
            if append and stat.st_size - self.size < self.maximum_bytes:
                handle.seek(self.size)
                data = self.data + handle.read(stat.st_size - self.size)
            else:
                handle.seek(max(0, stat.st_size - self.maximum_bytes))
                data = handle.read(self.maximum_bytes)
                self.rows.clear()
            self.data = data[-self.maximum_bytes:]
            self.identity = identity
            self.size = stat.st_size

    def lines(self, max_lines: int, *, legacy: bool = False) -> list[str]:
        # Match both existing readers' chunk boundaries and byte caps exactly.
        chunk = 64 * 1024 if legacy else 8192
        limit = self.maximum_bytes if legacy else self.maximum_bytes - 1
        position = self.size
        count = 0
        used = 0
        while position > 0 and count <= max_lines and used < limit:
            step = min(chunk, position, limit - used)
            position -= step
            end = len(self.data) - used
            count += self.data[end - step:end].count(b"\n")
            used += step
            if legacy and used > 256 * 1024 * 8:
                break
        data = self.data[-used:] if used else b""
        if not legacy and position > 0:
            preceding = len(self.data) - used - 1
            if preceding < 0 or self.data[preceding:preceding + 1] != b"\n":
                boundary = data.find(b"\n")
                data = data[boundary + 1:] if boundary >= 0 else b""
        lines = data.decode("utf-8", errors="replace").splitlines()
        if legacy and position > 0 and lines:
            lines = lines[1:]
        lines = lines[-max_lines:]
        if legacy:
            lines = [line for line in lines if len(line) <= 256 * 1024]
        # Keep one extra chunk for the next backward reader's alignment and
        # boundary byte. A long session must not fill the cache with old text.
        self.data = self.data[-min(self.maximum_bytes, used + chunk + 1):]
        return lines

    def parsed(self, lines):
        retained = {}
        for line in lines:
            item = self.rows.get(line)
            if item is None:
                item = TranscriptRow(line)
            retained[line] = item
            yield item
        self.rows = retained


def transcript_rows(lines, tail: TranscriptTail | None = None):
    if tail is not None:
        yield from tail.parsed(lines)
        return
    for line in lines:
        yield TranscriptRow(line)
