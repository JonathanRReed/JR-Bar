"""Compare the production Swift mirror with independently executed WASM pixels."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from light_audit import Firmware, frame_error

REPO = Path(__file__).resolve().parents[1]


def build_sampler(directory, *, sources=None):
    executable = Path(directory) / "light-audit-sampler"
    production = REPO / "app/Sources/JRBarLEDS"
    subprocess.run(["swiftc", "-O", *map(str, sources or sorted(production.glob("*.swift"))),
                    str(REPO / "tests/fixtures/LightAuditSampler.swift"), "-o", str(executable)],
                   check=True, capture_output=True, text=True)
    return executable


def mirror_failures(executable, rows):
    firmware = Firmware()
    failures = []
    # Bound native JSON and Python trace memory even for the full audit bank.
    for start in range(0, len(rows), 16):
        batch = rows[start:start + 16]
        traces = [firmware.trace(row["program"], row["leds"]) for row in batch]
        requests = [dict(program=row["program"], leds=row["leds"],
                         times=[i * trace.interval for i in range(len(trace.frames))])
                    for row, trace in zip(batch, traces)]
        result = subprocess.run([str(executable)], input=json.dumps(requests),
                                text=True, capture_output=True, check=True)
        samples = json.loads(result.stdout)
        if len(samples) != len(batch):
            raise ValueError("Swift sampler returned the wrong number of programs")
        for row, trace, actual in zip(batch, traces, samples):
            expected = [[frame[i * row["leds"] // 8] for i in range(8)] for frame in trace.frames]
            valid = (len(actual) == len(expected) and all(len(frame) == 8 and all(len(pixel) == 3
                     for pixel in frame) for frame in actual))
            error = frame_error(expected, actual) if valid else 255
            if error > 1:
                failures.append({"case": row["case"], "error": error})
    return failures
