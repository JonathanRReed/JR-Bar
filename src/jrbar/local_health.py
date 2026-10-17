"""Bounded, content-free current-run health aggregation for JR-Bar."""

from __future__ import annotations

import math
import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone

from .dnd_policy import DndMode, DndProjection, DndSource
from .performance_metrics import MetricSnapshot, PerformanceSnapshot
from .runtime_scheduler import RuntimeWorkerSnapshot

MAX_DND_HEALTH_RETURN_EPOCH = 4_102_444_800.0


@dataclass(frozen=True, slots=True)
class LocalHealthTiming:
    count: int
    p50_ms: float
    p95_ms: float
    latest_ms: float

    @classmethod
    def from_metric(cls, metric: MetricSnapshot | None) -> LocalHealthTiming | None:
        if metric is None or metric.count <= 0:
            return None
        return cls(
            count=metric.count,
            p50_ms=metric.p50_ms,
            p95_ms=metric.p95_ms,
            latest_ms=metric.latest_ms,
        )

    def to_dict(self) -> dict[str, int | float]:
        return {
            "count": self.count,
            "p50_ms": self.p50_ms,
            "p95_ms": self.p95_ms,
            "latest_ms": self.latest_ms,
        }


@dataclass(frozen=True, slots=True)
class LocalHealthDndStatus:
    available: bool
    modes: tuple[DndMode, ...] = ()
    sources: tuple[DndSource, ...] = ()
    return_epoch: float | None = None

    def __post_init__(self) -> None:
        if type(self.available) is not bool:
            raise TypeError("DND health availability must be a boolean")
        if type(self.modes) is not tuple or not all(
            type(mode) is DndMode for mode in self.modes
        ):
            raise TypeError("DND health modes must be typed")
        if type(self.sources) is not tuple or not all(
            type(source) is DndSource for source in self.sources
        ):
            raise TypeError("DND health sources must be typed")
        # Bounded by the vocabularies themselves: every source can be live at
        # once (a call over a schedule over a Focus), and each one distinct.
        if len(self.modes) > len(DndMode) or len(set(self.modes)) != len(self.modes):
            raise ValueError("DND health modes must remain bounded")
        if len(self.sources) > len(DndSource) or len(set(self.sources)) != len(self.sources):
            raise ValueError("DND health sources must remain bounded")
        if self.return_epoch is not None and _finite_nonnegative(
            self.return_epoch
        ) is None:
            raise ValueError("DND health return time must be finite")
        if (
            self.return_epoch is not None
            and self.return_epoch > MAX_DND_HEALTH_RETURN_EPOCH
        ):
            raise ValueError("DND health return time exceeds the bounded range")
        if not self.available and (
            self.modes or self.sources or self.return_epoch is not None
        ):
            raise ValueError("unavailable DND health cannot contain facts")

    @classmethod
    def from_projection(cls, projection: object) -> LocalHealthDndStatus:
        if type(projection) is not DndProjection:
            return cls(False)
        return cls(
            True,
            tuple(dict.fromkeys(projection.active_modes)),
            projection.active_sources,
            projection.next_transition_epoch,
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "available": self.available,
            "modes": [mode.value for mode in self.modes],
            "sources": [source.value for source in self.sources],
            "return_epoch": self.return_epoch,
        }


@dataclass(frozen=True, slots=True)
class LocalHealthSnapshot:
    generated_at: float
    queue_depth: int
    peak_queue_depth: int
    hardware_write_latency: LocalHealthTiming | None
    source_freshness_seconds: float | None
    worker_count: int
    active_worker_count: int
    shutdown_latency: LocalHealthTiming | None
    refresh_duration: LocalHealthTiming | None
    dnd_status: LocalHealthDndStatus

    def to_dict(self) -> dict[str, object]:
        return {
            "generated_at": self.generated_at,
            "queue_depth": self.queue_depth,
            "peak_queue_depth": self.peak_queue_depth,
            "hardware_write_latency": (
                self.hardware_write_latency.to_dict()
                if self.hardware_write_latency is not None
                else None
            ),
            "source_freshness_seconds": self.source_freshness_seconds,
            "worker_count": self.worker_count,
            "active_worker_count": self.active_worker_count,
            "shutdown_latency": (
                self.shutdown_latency.to_dict()
                if self.shutdown_latency is not None
                else None
            ),
            "refresh_duration": (
                self.refresh_duration.to_dict()
                if self.refresh_duration is not None
                else None
            ),
            "dnd_status": self.dnd_status.to_dict(),
        }


def _finite_nonnegative(value: object) -> float | None:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or float(value) < 0.0
    ):
        return None
    return float(value)


class LocalHealthMonitor:
    """Aggregate existing bounded owners without retaining source content."""

    def __init__(self, *, monotonic: Callable[[], float] = time.monotonic) -> None:
        if not callable(monotonic):
            raise ValueError("invalid local health clock")
        self._monotonic = monotonic
        self._lock = threading.Lock()
        self._peak_queue_depth = 0

    def observe(
        self,
        *,
        performance: PerformanceSnapshot,
        workers: Sequence[RuntimeWorkerSnapshot],
        source_ages_seconds: Sequence[float],
        dnd_projection: DndProjection | None = None,
    ) -> LocalHealthSnapshot:
        if not isinstance(performance, PerformanceSnapshot):
            raise ValueError("invalid performance health snapshot")
        if any(not isinstance(worker, RuntimeWorkerSnapshot) for worker in workers):
            raise ValueError("invalid worker health snapshot")
        observed_at = _finite_nonnegative(self._monotonic())
        if observed_at is None:
            raise RuntimeError("local health clock returned an invalid value")
        queue_depth = sum(worker.pending_count + worker.result_count for worker in workers)
        active_worker_count = sum(worker.thread_alive for worker in workers)
        valid_ages = tuple(
            valid
            for age in source_ages_seconds
            if (valid := _finite_nonnegative(age)) is not None
        )

        with self._lock:
            self._peak_queue_depth = max(self._peak_queue_depth, queue_depth)
            peak_queue_depth = self._peak_queue_depth

        return LocalHealthSnapshot(
            generated_at=observed_at,
            queue_depth=queue_depth,
            peak_queue_depth=peak_queue_depth,
            hardware_write_latency=LocalHealthTiming.from_metric(
                performance.metric("hardware_render")
            ),
            source_freshness_seconds=max(valid_ages, default=None),
            worker_count=len(workers),
            active_worker_count=active_worker_count,
            shutdown_latency=LocalHealthTiming.from_metric(
                performance.metric("shutdown")
            ),
            refresh_duration=LocalHealthTiming.from_metric(
                performance.metric("refresh")
            ),
            dnd_status=LocalHealthDndStatus.from_projection(dnd_projection),
        )


def _timing_text(value: LocalHealthTiming | None) -> str:
    if value is None:
        return "Unavailable"
    return (
        f"P50 {value.p50_ms:.1f} ms, P95 {value.p95_ms:.1f} ms, "
        f"latest {value.latest_ms:.1f} ms, n={value.count}"
    )


def format_local_health(snapshot: LocalHealthSnapshot) -> str:
    """Render the fixed rows without dynamic identities or content."""
    if not isinstance(snapshot, LocalHealthSnapshot):
        raise ValueError("invalid local health projection")
    unavailable = "Unavailable"
    dnd = snapshot.dnd_status
    dnd_text = "DND Unavailable"
    if dnd.available:
        mode_labels = {
            DndMode.MUTE: "Mute",
            DndMode.DIM: "Dim",
            DndMode.PAUSE: "Pause",
            DndMode.ASKS_ONLY: "Asks Only",
            DndMode.DARK: "Fully Dark",
        }
        source_labels = {
            DndSource.MANUAL: "Manual",
            DndSource.SCHEDULE: "Scheduled",
            DndSource.MACOS_FOCUS: "macOS Focus",
            DndSource.NAMED_FOCUS: "Named Focus",
            DndSource.CALL: "Call",
            DndSource.CALENDAR: "Meeting",
            DndSource.AWAY: "Away",
        }
        modes = "+".join(mode_labels[value] for value in dnd.modes) or (
            "Named Rule" if dnd.sources else "Off"
        )
        sources = "+".join(source_labels[value] for value in dnd.sources) or "None"
        source_label = "source" if len(dnd.sources) == 1 else "sources"
        returns = (
            datetime.fromtimestamp(dnd.return_epoch, tz=timezone.utc).strftime(
                "%Y-%m-%d %H:%MZ"
            )
            if dnd.return_epoch is not None
            else "Unscheduled"
        )
        dnd_text = f"DND {modes}; {source_label} {sources}; returns {returns}"
    return "\n".join(
        (
            "Local Health (current run, never sent)",
            f"Runtime queue depth: {snapshot.queue_depth} current, "
            f"{snapshot.peak_queue_depth} peak",
            "Hardware write latency: "
            + _timing_text(snapshot.hardware_write_latency),
            "Source freshness: "
            + (
                f"oldest visible update {snapshot.source_freshness_seconds:.1f} s"
                if snapshot.source_freshness_seconds is not None
                else unavailable
            )
            + f"; {dnd_text}",
            f"Runtime workers: {snapshot.worker_count} registered, "
            f"{snapshot.active_worker_count} live",
            "Shutdown latency: " + _timing_text(snapshot.shutdown_latency),
            "Refresh duration: " + _timing_text(snapshot.refresh_duration),
        )
    )


__all__ = [
    "MAX_DND_HEALTH_RETURN_EPOCH",
    "LocalHealthDndStatus",
    "LocalHealthMonitor",
    "LocalHealthSnapshot",
    "LocalHealthTiming",
    "format_local_health",
]
