"""core-crash.log holds crash output only, and stays small."""

from __future__ import annotations

from pathlib import Path

from jrbar.core_runtime import CRASH_LOG_LIMIT_BYTES, open_crash_log


def test_old_armed_lines_go_and_an_empty_log_stays_empty(tmp_path: Path):
    path = tmp_path / "core-crash.log"
    path.write_text("".join(f"--- crash capture armed 2026-10-{day:02d}T08:00:00Z pid={day} ---\n" for day in range(1, 27)))
    with open_crash_log(path) as handle:
        assert handle.writable()
    assert path.read_text() == ""


def test_real_crash_output_is_kept_without_the_markers(tmp_path: Path):
    path = tmp_path / "core-crash.log"
    path.write_text("--- crash capture armed 2026-10-01T08:00:00Z pid=1 ---\n"
                    "Fatal Python error: Segmentation fault\n\nThread 0x1 (most recent call first):\n"
                    "--- crash capture armed 2026-10-02T08:00:00Z pid=2 ---\n")
    with open_crash_log(path):
        pass
    assert path.read_text() == "Fatal Python error: Segmentation fault\n\nThread 0x1 (most recent call first):\n"


def test_a_crash_loop_keeps_only_the_newest_part(tmp_path: Path):
    path = tmp_path / "core-crash.log"
    path.write_bytes(b"old\n" * (CRASH_LOG_LIMIT_BYTES // 2) + b"newest\n")
    with open_crash_log(path):
        pass
    data = path.read_bytes()
    assert len(data) <= CRASH_LOG_LIMIT_BYTES // 2
    assert data.endswith(b"newest\n")


def test_arming_no_longer_writes_a_marker(tmp_path: Path):
    path = tmp_path / "core-crash.log"
    with open_crash_log(path):
        pass
    assert path.read_text() == ""
