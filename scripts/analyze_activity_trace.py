#!/usr/bin/env python3
"""Read CPU and memory from an Instruments Activity Monitor XML export.

This is a diagnostic. It does not identify the app's hidden, static or motion
state, measure interaction latency, or certify the release performance budget.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def _resolve(element: ET.Element, references: dict[str, ET.Element]) -> ET.Element:
    seen: set[str] = set()
    while reference := element.get("ref"):
        if reference in seen:
            raise ValueError("cyclic XML reference")
        seen.add(reference)
        target = references.get(reference)
        if target is None:
            raise ValueError(f"missing XML reference: {reference}")
        element = target
    return element


def _number(element: ET.Element, label: str) -> float:
    try:
        value = float(element.text or "")
    except ValueError:
        raise ValueError(f"invalid {label}") from None
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"invalid {label}")
    return value


def summarize(path: Path) -> dict[str, float | int | str]:
    raw = path.read_bytes()
    root = ET.fromstring(raw)
    schemas = list(root.iter("schema"))
    if len(schemas) != 1 or schemas[0].get("name") != "activity-monitor-process-live":
        raise ValueError("expected one Activity Monitor process-live table")
    columns = [column.findtext("mnemonic") for column in schemas[0].findall("col")]
    required = {"duration", "cpu-percent", "memory-physical-footprint"}
    if not required.issubset(columns):
        raise ValueError("Activity Monitor export is missing required columns")

    references = {element.get("id"): element for element in root.iter() if element.get("id")}
    samples: list[tuple[float, float]] = []
    footprints: list[float] = []
    for row in root.iter("row"):
        if len(row) != len(columns):
            raise ValueError("Activity Monitor row has the wrong number of columns")
        values = {name: _resolve(cell, references) for name, cell in zip(columns, row)}
        footprint = values["memory-physical-footprint"]
        if footprint.text:
            footprints.append(_number(footprint, "memory footprint") / 1_048_576)
        cpu = values["cpu-percent"]
        if not cpu.text:
            continue
        percent = _number(cpu, "CPU percentage")
        seconds = _number(values["duration"], "interval duration") / 1_000_000_000
        if seconds <= 0:
            raise ValueError("interval duration must be positive")
        samples.append((percent, seconds))
    if not samples:
        raise ValueError("the Activity Monitor export has no CPU intervals")
    if not footprints:
        raise ValueError("the Activity Monitor export has no memory readings")

    duration = sum(seconds for _, seconds in samples)
    mean = sum(percent * seconds for percent, seconds in samples) / duration
    boundary = duration * 0.95
    elapsed = 0.0
    p95 = max(percent for percent, _ in samples)
    for percent, seconds in sorted(samples):
        elapsed += seconds
        if elapsed >= boundary:
            p95 = percent
            break
    return {
        "export_sha256": hashlib.sha256(raw).hexdigest(),
        "cpu_intervals": len(samples),
        "covered_seconds": duration,
        "mean_cpu_percent": mean,
        "p95_cpu_percent": p95,
        "min_cpu_percent": min(percent for percent, _ in samples),
        "max_cpu_percent": max(percent for percent, _ in samples),
        "peak_physical_footprint_mib": max(footprints),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", type=Path)
    args = parser.parse_args()
    try:
        result = summarize(args.export)
    except (OSError, UnicodeError, ET.ParseError, ValueError) as exc:
        print(f"Activity Monitor export rejected: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
