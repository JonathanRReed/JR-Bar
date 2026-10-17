from __future__ import annotations

from dataclasses import replace

from jrbar.dnd_policy import (
    DndMode,
    DndSource,
    compose_dnd_contributions,
    contribution_for_mode,
)
from jrbar.local_health import LocalHealthMonitor, format_local_health
from jrbar.performance_metrics import PerformanceRegistry
from jrbar.runtime_scheduler import RuntimeWorkerDomain, RuntimeWorkerSnapshot


def _worker(**changes) -> RuntimeWorkerSnapshot:
    return replace(
        RuntimeWorkerSnapshot.empty(
            RuntimeWorkerDomain.HARDWARE_WRITE,
            accepting=True,
        ),
        **changes,
    )


def test_health_monitor_projects_the_content_free_aggregates() -> None:
    now = [100.0]
    monitor = LocalHealthMonitor(monotonic=lambda: now[0])
    performance = PerformanceRegistry(monotonic=lambda: now[0])
    performance.record("hardware_render", 10)
    performance.record("hardware_render", 30)
    performance.record("refresh", 5)
    first = monitor.observe(
        performance=performance.snapshot(),
        workers=(_worker(pending_count=2, result_count=1, thread_alive=True),),
        source_ages_seconds=(3.0, 10.0),
    )

    assert first.queue_depth == 3
    assert first.peak_queue_depth == 3
    assert first.hardware_write_latency is not None
    assert first.hardware_write_latency.p95_ms == 30
    assert first.source_freshness_seconds == 10
    assert first.worker_count == 1
    assert first.active_worker_count == 1
    assert first.shutdown_latency is None
    assert first.refresh_duration is not None
    assert first.refresh_duration.p95_ms == 5

    now[0] = 102.0

    second = monitor.observe(
        performance=performance.snapshot(),
        workers=(_worker(pending_count=1, thread_alive=True),),
        source_ages_seconds=(12.0,),
    )

    assert second.queue_depth == 1
    assert second.peak_queue_depth == 3
    assert second.source_freshness_seconds == 12


def test_invalid_or_unobserved_inputs_remain_unavailable__and_2_more() -> None:
    # --- scenario: invalid_or_unobserved_inputs_remain_unavailable
    monitor = LocalHealthMonitor(monotonic=lambda: 10.0)
    snapshot = monitor.observe(
        performance=PerformanceRegistry().snapshot(),
        workers=(),
        source_ages_seconds=(-1.0, float("nan"), float("inf")),
    )

    assert snapshot.queue_depth == 0
    assert snapshot.hardware_write_latency is None
    assert snapshot.source_freshness_seconds is None
    assert snapshot.worker_count == 0
    assert snapshot.active_worker_count == 0
    assert snapshot.shutdown_latency is None
    assert snapshot.refresh_duration is None

    # --- scenario: formatter_has_exact_fixed_rows_and_excludes_unowned_metric_content
    performance = PerformanceRegistry()
    performance.record("private/session/path", 1, outcome="https://secret.invalid")
    snapshot = LocalHealthMonitor(monotonic=lambda: 10.0).observe(
        performance=performance.snapshot(),
        workers=(),
        source_ages_seconds=(),
    )

    rendered = format_local_health(snapshot)

    assert rendered.splitlines()[0] == "Local Health (current run, never sent)"
    assert len(rendered.splitlines()) == 7
    for label in (
        "Runtime queue depth",
        "Hardware write latency",
        "Source freshness",
        "Runtime workers",
        "Shutdown latency",
        "Refresh duration",
    ):
        assert rendered.count(f"{label}:") == 1
    assert rendered.count("Unavailable") >= 4
    assert "private" not in rendered
    assert "secret" not in rendered
    assert "https" not in rendered

    # --- scenario: formatter_reuses_the_fixed_source_row_for_bounded_dnd_facts
    snapshot = LocalHealthMonitor(monotonic=lambda: 10.0).observe(
        performance=PerformanceRegistry().snapshot(),
        workers=(),
        source_ages_seconds=(),
        dnd_projection=compose_dnd_contributions(
            (contribution_for_mode(DndSource.SCHEDULE, DndMode.DIM),),
            next_transition_epoch=1_800_000_000.0,
        ),
    )

    rendered = format_local_health(snapshot)

    assert len(rendered.splitlines()) == 7
    assert (
        "Source freshness: Unavailable; DND Dim; source Scheduled; "
        "returns 2027-01-15 08:00Z"
    ) in rendered



def test_the_formatter_names_every_quiet_source_at_once() -> None:
    # A call and a meeting over a schedule and both Focus kinds, on an
    # empty desk: every source live together must still format.
    modes = tuple(DndMode)
    snapshot = LocalHealthMonitor(monotonic=lambda: 10.0).observe(
        performance=PerformanceRegistry().snapshot(),
        workers=(),
        source_ages_seconds=(),
        dnd_projection=compose_dnd_contributions(
            tuple(
                contribution_for_mode(source, modes[index % len(modes)])
                for index, source in enumerate(DndSource)
            ),
        ),
    )

    assert snapshot.dnd_status.sources == tuple(DndSource)
    assert len(snapshot.dnd_status.modes) == len(DndMode)
    rendered = format_local_health(snapshot)
    assert (
        "sources Manual+Scheduled+macOS Focus+Named Focus+Call+Meeting+Away" in rendered
    )
