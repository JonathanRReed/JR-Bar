"""The launch-time janitor: old process records, stranded scratch files and
the logs of retired processes go; anything live stays."""

from __future__ import annotations

import json
import os
from pathlib import Path

from jrbar import core_runtime
from jrbar.audit import (
    RETIRED_LOG_IDLE_SECONDS,
    SCRATCH_IDLE_SECONDS,
    remove_retired_logs,
    run_state_housekeeping,
    sweep_orphan_scratch_files,
)
from jrbar.process_registry import ProcessEntry, prune_registry, record_agent_process, record_path

NOW = 1_800_000_000.0
SCRATCH_NAME = "latest.json.21010.8726741760." + "ab" * 16 + ".tmp"


def _age(path: Path, seconds: float) -> None:
    stamp = NOW - seconds
    os.utime(path, (stamp, stamp))


def test_a_stranded_scratch_file_goes_and_a_fresh_one_stays(tmp_path: Path) -> None:
    stranded = tmp_path / SCRATCH_NAME
    stranded.write_text("x")
    _age(stranded, SCRATCH_IDLE_SECONDS + 5)
    nested = tmp_path / "processes" / "claude"
    nested.mkdir(parents=True)
    in_flight = nested / ("s.json.7.9." + "cd" * 16 + ".tmp")
    in_flight.write_text("x")
    _age(in_flight, 5)
    lookalike = tmp_path / "notes.tmp"
    lookalike.write_text("mine")
    _age(lookalike, 10 * SCRATCH_IDLE_SECONDS)

    assert sweep_orphan_scratch_files(tmp_path, now=NOW) == 1
    assert not stranded.exists()
    assert in_flight.exists()
    assert lookalike.read_text() == "mine"


def test_a_retired_log_goes_only_after_it_has_gone_quiet(tmp_path: Path) -> None:
    quiet = tmp_path / "status-bar.out.log"
    quiet.write_text("old")
    _age(quiet, RETIRED_LOG_IDLE_SECONDS + 60)
    busy = tmp_path / "sd-eject-guard.out.log"
    busy.write_text("recent")
    _age(busy, 3600)
    live = tmp_path / "core-crash.log"
    live.write_text("keep")
    _age(live, 100 * 86400)

    assert remove_retired_logs(tmp_path, now=NOW) == 1
    assert not quiet.exists()
    assert busy.exists() and live.exists()


def test_the_registry_keeps_a_running_session_a_week_past_its_start(tmp_path: Path) -> None:
    running = record_agent_process(
        "codex", "running", ProcessEntry(9, 1, 1.0, "codex"), state_dir=tmp_path
    )
    ended = record_agent_process(
        "codex", "ended", ProcessEntry(10, 1, 1.0, "codex"), state_dir=tmp_path
    )
    ended_path = record_path("codex", ended.session_id, tmp_path)
    payload = json.loads(ended_path.read_text())
    payload["ended_at_epoch"] = NOW - 9 * 86400
    ended_path.write_text(json.dumps(payload))
    for session in (running, ended):
        _age(record_path("codex", session.session_id, tmp_path), 9 * 86400)

    assert prune_registry(state_dir=tmp_path, now=NOW) == 1
    assert record_path("codex", running.session_id, tmp_path).exists()
    assert not ended_path.exists()


def test_housekeeping_reports_each_step_and_survives_a_missing_directory(tmp_path: Path) -> None:
    stranded = tmp_path / SCRATCH_NAME
    stranded.write_text("x")
    _age(stranded, SCRATCH_IDLE_SECONDS + 5)

    counts = run_state_housekeeping(tmp_path, now=NOW)
    assert counts == {"registry": 0, "scratch": 1, "logs": 0}
    assert run_state_housekeeping(tmp_path / "nope", now=NOW) == {
        "registry": 0,
        "scratch": 0,
        "logs": 0,
    }


def test_the_launch_trim_step_runs_the_housekeeping() -> None:
    source = Path(core_runtime.__file__).read_text(encoding="utf-8")
    trim = source.split("def trim_logs() -> None:", 1)[1].split("# AppKit swallows", 1)[0]
    assert "run_state_housekeeping" in trim
