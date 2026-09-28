"""Activity Monitor exports keep CPU percentages, durations and references."""

from pathlib import Path

import pytest

from scripts import analyze_activity_trace


def _export(path: Path, rows: str) -> Path:
    path.write_text(
        '<trace-query-result><node><schema name="activity-monitor-process-live">'
        "<col><mnemonic>duration</mnemonic></col>"
        "<col><mnemonic>cpu-percent</mnemonic></col>"
        "<col><mnemonic>memory-physical-footprint</mnemonic></col>"
        "</schema>"
        f"{rows}</node></trace-query-result>",
        encoding="utf-8",
    )
    return path


def test_cpu_summary_weights_intervals_and_resolves_memory_references(tmp_path: Path) -> None:
    source = _export(
        tmp_path / "activity.xml",
        '<row><duration>18000000000</duration><sentinel />'
        '<size-in-bytes id="memory">1048576</size-in-bytes></row>'
        '<row><duration>18000000000</duration><system-cpu-percent>1</system-cpu-percent>'
        '<size-in-bytes ref="memory" /></row>'
        '<row><duration>2000000000</duration><system-cpu-percent>10</system-cpu-percent>'
        '<size-in-bytes>2097152</size-in-bytes></row>',
    )

    summary = analyze_activity_trace.summarize(source)

    assert summary["cpu_intervals"] == 2
    assert summary["covered_seconds"] == 20
    assert summary["mean_cpu_percent"] == 1.9
    assert summary["p95_cpu_percent"] == 10
    assert summary["peak_physical_footprint_mib"] == 2
    assert len(summary["export_sha256"]) == 64


@pytest.mark.parametrize(
    "cpu",
    ["-1", "nan", "inf"],
)
def test_cpu_summary_rejects_invalid_measurements(tmp_path: Path, cpu: str) -> None:
    source = _export(
        tmp_path / "bad.xml",
        f"<row><duration>1000000000</duration><system-cpu-percent>{cpu}</system-cpu-percent>"
        "<size-in-bytes>1048576</size-in-bytes></row>",
    )

    with pytest.raises(ValueError, match="CPU percentage"):
        analyze_activity_trace.summarize(source)


def test_cpu_summary_rejects_a_missing_reference_and_empty_capture(tmp_path: Path) -> None:
    missing = _export(
        tmp_path / "missing.xml",
        '<row><duration>1000000000</duration><system-cpu-percent>2</system-cpu-percent>'
        '<size-in-bytes ref="gone" /></row>',
    )
    with pytest.raises(ValueError, match="missing XML reference"):
        analyze_activity_trace.summarize(missing)

    empty = _export(tmp_path / "empty.xml", "<row><duration>1000000000</duration><sentinel />"
                    "<size-in-bytes>1048576</size-in-bytes></row>")
    with pytest.raises(ValueError, match="no CPU intervals"):
        analyze_activity_trace.summarize(empty)


def test_cpu_summary_rejects_invalid_duration_and_memory(tmp_path: Path) -> None:
    zero_duration = _export(
        tmp_path / "duration.xml",
        "<row><duration>0</duration><system-cpu-percent>2</system-cpu-percent>"
        "<size-in-bytes>1048576</size-in-bytes></row>",
    )
    with pytest.raises(ValueError, match="interval duration must be positive"):
        analyze_activity_trace.summarize(zero_duration)

    negative_memory = _export(
        tmp_path / "memory.xml",
        "<row><duration>1000000000</duration><system-cpu-percent>2</system-cpu-percent>"
        "<size-in-bytes>-1</size-in-bytes></row>",
    )
    with pytest.raises(ValueError, match="memory footprint"):
        analyze_activity_trace.summarize(negative_memory)
