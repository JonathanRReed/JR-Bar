#!/usr/bin/env python3
"""Validate measured JR-Bar performance evidence against release budgets."""

from __future__ import annotations

import argparse
import json
import math
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class PerformanceBudget:
    warm_launch_ms: float = 500.0
    menu_open_p95_ms: float = 50.0
    pane_switch_p95_ms: float = 100.0
    longest_main_thread_task_ms: float = 16.0
    idle_cpu_hidden_percent: float = 1.0
    idle_cpu_static_bar_percent: float = 1.5
    idle_cpu_motion_percent: float = 3.0


_REQUIRED_FIELDS = tuple(PerformanceBudget.__dataclass_fields__)


def validate_daemon_probe(document: Mapping[str, object]) -> tuple[str, ...]:
    """Catch large synthetic-workload regressions, separate from release proof."""
    failures = []
    if document.get("workload_valid") is not True:
        failures.append("the synthetic workload was not accepted")
    if document.get("tracing") or document.get("profiling"):
        failures.append("traced or profiled runs are not budget evidence")
    if _number(document, "duration_seconds") < 60:
        failures.append("measure for at least 60 seconds")
    for key, limit in (("cpu_percent", 5.0), ("rss_max_mb", 200.0), ("loop_over_250ms", 0)):
        measured = _number(document, key)
        if measured > limit:
            failures.append(f"{key}: measured {measured:g}, probe limit {limit:g}")
    wakeups = document.get("wakeups_per_minute")
    if not isinstance(wakeups, Mapping):
        raise ValueError("missing wakeups_per_minute")
    if _number(wakeups, "interrupt_wakeups") > 10_000:
        failures.append("interrupt wakeups exceed 10000 per minute")
    if document.get("workload") == "idle":
        messages = document.get("messages_per_minute")
        if not isinstance(messages, Mapping):
            raise ValueError("missing messages_per_minute")
        state_rate = sum(_number(messages, key) for key in ("state", "state_delta") if key in messages)
        if state_rate > 8:
            failures.append("idle state publishes exceed 8 per minute")
    return tuple(failures)


def validate_app_feed(document: Mapping[str, object]) -> tuple[str, ...]:
    """A CPU/allocation guard for 10000 offscreen state messages."""
    failures = []
    if _number(document, "messages") != 10_000:
        failures.append("the app feed must apply 10000 messages")
    for key, limit in (("cpu_seconds", 30.0), ("blocks_delta", 1000), ("bytes_delta", 2_000_000)):
        value = document.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"invalid app feed field: {key}")
        if value > limit:
            failures.append(f"{key}: measured {value:g}, probe limit {limit:g}")
    return tuple(failures)


def _number(document: Mapping[str, object], key: str) -> float:
    value = document.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"missing numeric performance field: {key}")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise ValueError(f"invalid performance field: {key}")
    return number


def validate_performance_evidence(
    document: Mapping[str, object],
    budget: PerformanceBudget = PerformanceBudget(),
) -> tuple[str, ...]:
    failures = []
    for key in _REQUIRED_FIELDS:
        measured = _number(document, key)
        limit = float(getattr(budget, key))
        if measured > limit:
            failures.append(f"{key}: measured {measured:g}, budget {limit:g}")
    duration = _number(document, "measurement_duration_seconds")
    if duration < 300.0:
        failures.append(
            "measurement_duration_seconds: at least 300 seconds is required"
        )
    if document.get("instruments_trace_reviewed") is not True:
        failures.append("instruments_trace_reviewed must be true")
    if document.get("menu_tracking_io_observed") is not False:
        failures.append("menu_tracking_io_observed must be false")
    return tuple(failures)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    try:
        document = json.loads(args.evidence.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise ValueError("performance evidence must be a JSON object")
        failures = validate_performance_evidence(document)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print(f"performance evidence rejected: {exc}")
        return 2
    if failures:
        print("performance budget failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("performance budget passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
