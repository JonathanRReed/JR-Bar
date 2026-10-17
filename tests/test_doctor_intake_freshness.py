from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

import pytest

import jrbar.doctor as doctor
from jrbar.doctor import DiagnosticCode


def _probe(tmp_path: Path, *, events: tuple[object, ...] | list[object] = (), watermarks: tuple[object, ...] | list[object] = (), failures: int = 0):
    (tmp_path / "latest.json").write_text(json.dumps({"source_watermarks": watermarks}))
    if events:
        (tmp_path / "claude.jsonl").write_text("\n".join(json.dumps(row) for row in events))
    (tmp_path / "hook-send-breaker.json").write_text(json.dumps({"failures": failures}))
    with (
        patch.object(doctor, "default_state_dir", return_value=tmp_path),
        patch.object(doctor, "HOOK_PROVIDERS", ("claude",)),
        patch.object(doctor.time, "time", return_value=10_000.0),
    ):
        return doctor._event_intake_freshness_probe()


def test_idle_intake_does_not_invent_a_successful_source(tmp_path: Path) -> None:
    finding = _probe(tmp_path)
    assert finding.code is DiagnosticCode.UNAVAILABLE
    assert (finding.count, finding.limit) == (0, 0)


def test_a_tripped_breaker_is_reported_even_without_recent_events(tmp_path: Path) -> None:
    finding = _probe(tmp_path, failures=3)
    assert finding.code is DiagnosticCode.PARTIAL
    assert (finding.count, finding.limit) == (0, 0)


def test_a_tripped_breaker_does_not_change_the_measured_fresh_count(tmp_path: Path) -> None:
    finding = _probe(
        tmp_path,
        events=[{"occurred_at_epoch": 9_990.0}],
        watermarks=[{"source_key": {"provider_id": "claude"}, "occurred_at_epoch": 9_990.0}],
        failures=3,
    )
    assert finding.code is DiagnosticCode.PARTIAL
    assert (finding.count, finding.limit) == (1, 1)


@pytest.mark.parametrize("occurred", [True, False, float("nan"), float("inf"), 10_001.0, -1, "9990"])
def test_invalid_event_times_cannot_claim_recent_intake(tmp_path: Path, occurred: object) -> None:
    finding = _probe(tmp_path, events=[{"occurred_at_epoch": occurred}, [], None])
    assert finding.code is DiagnosticCode.UNAVAILABLE
    assert (finding.count, finding.limit) == (0, 0)


@pytest.mark.parametrize("occurred", [True, float("inf"), 10_001.0])
def test_invalid_watermarks_cannot_hide_a_lagging_intake(tmp_path: Path, occurred: object) -> None:
    finding = _probe(
        tmp_path,
        events=[{"occurred_at_epoch": 9_990.0}],
        watermarks=[{"source_key": {"provider_id": "claude"}, "occurred_at_epoch": occurred}],
    )
    assert finding.code is DiagnosticCode.PARTIAL
    assert (finding.count, finding.limit) == (0, 1)


def test_fresh_and_lagging_sources_are_measured(tmp_path: Path) -> None:
    events = [{"occurred_at_epoch": 9_990.0}]
    fresh = _probe(tmp_path, events=events, watermarks=[
        {"source_key": {"provider_id": "claude"}, "occurred_at_epoch": 9_900.0},
    ])
    assert fresh.code is DiagnosticCode.HEALTHY
    assert (fresh.count, fresh.limit) == (1, 1)
    lagging = _probe(tmp_path, events=events)
    assert lagging.code is DiagnosticCode.PARTIAL
    assert (lagging.count, lagging.limit) == (0, 1)
