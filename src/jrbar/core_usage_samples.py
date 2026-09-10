"""Usage window samples and the pace forecast behind ``usage.providers[].forecast``.

The provider usage store keeps one snapshot per provider: the latest
reading, no history. A pace needs history, so the daemon keeps a small
rolling buffer of ``(at, used_pct)`` per provider window here, persisted
to ``~/.local/state/jrbar/usage-samples.json`` so a restart does not
forget the last hour. The forecast is the CodexBar reading: a straight
line through the recent samples, where it crosses 100 %, and whether
that comes before the window's reset.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

from .state_paths import default_state_dir

SAMPLES_SCHEMA: Final = 1
SAMPLES_FILE_NAME: Final = "usage-samples.json"
#: Samples kept per provider window. At the usage refresh cadence (every
#: few minutes, plus a heartbeat) that is a few hours of history.
SAMPLE_LIMIT: Final = 48
#: A sample is kept when the percentage moved, or this long after the
#: last one so a quiet window still shows as "nothing burning".
HEARTBEAT_SECONDS: Final = 5 * 60
#: The fit runs over the samples of the last 90 minutes ...
LOOKBACK_SECONDS: Final = 90 * 60
#: ... and needs at least 30 minutes between its first and last sample.
MIN_SPAN_SECONDS: Final = 30 * 60
#: Below this many percent per hour nothing is burning.
IDLE_RATE_PCT_PER_HOUR: Final = 0.05
#: A window this full is exhausted, whatever the pace says.
EXHAUSTED_PCT: Final = 99.5
#: ``on`` pace: the projected exhaustion lands within this fraction of the
#: time left until the reset, either side of it.
ON_PACE_MARGIN: Final = 0.10
#: Between saves of the buffer while samples keep arriving.
SAVE_INTERVAL_SECONDS: Final = 60.0

PACE_AHEAD: Final = "ahead"
PACE_ON: Final = "on"
PACE_UNDER: Final = "under"
PACE_EXHAUSTED: Final = "exhausted"


def default_usage_samples_path(home: Path | None = None) -> Path:
    return default_state_dir(home) / SAMPLES_FILE_NAME


@dataclass(frozen=True, slots=True)
class UsageSample:
    at: float
    used_pct: float


def _key(provider: str, window_id: str) -> str:
    return f"{provider}|{str(window_id).lower()}"


def linear_rate(samples: list[UsageSample], *, now: float) -> tuple[float, int] | None:
    """Percent per hour from a least-squares line through the samples of
    the last ``LOOKBACK_SECONDS``, after the last reset (a drop of more
    than a point). None with less than ``MIN_SPAN_SECONDS`` of spread.
    Returns ``(rate, samples_used)``; the rate is never negative."""
    recent = [sample for sample in samples if now - sample.at <= LOOKBACK_SECONDS]
    for index in range(len(recent) - 1, 0, -1):
        if recent[index].used_pct < recent[index - 1].used_pct - 1.0:
            recent = recent[index:]
            break
    if len(recent) < 2:
        return None
    span = recent[-1].at - recent[0].at
    if span < MIN_SPAN_SECONDS:
        return None
    mean_t = sum(sample.at for sample in recent) / len(recent)
    mean_p = sum(sample.used_pct for sample in recent) / len(recent)
    numerator = sum((sample.at - mean_t) * (sample.used_pct - mean_p) for sample in recent)
    denominator = sum((sample.at - mean_t) ** 2 for sample in recent)
    if denominator <= 0:
        return None
    return max(0.0, numerator / denominator * 3600.0), len(recent)


def forecast_window(
    samples: list[UsageSample],
    *,
    window_id: str | None,
    used_pct: float | None,
    resets_at: float | None,
    now: float,
) -> dict[str, Any] | None:
    """The ``forecast`` block for one window, or None while there is not
    enough history for a pace (an exhausted window needs none).

    ``pace``: ``exhausted`` at or above 99.5 % used; ``under`` when
    nothing is burning or the reset comes first by a clear margin; ``on``
    when the projected exhaustion lands within 10 % of the time left
    until the reset; ``ahead`` when it comes before that. Without a
    known reset, a window heading for 100 % is ``ahead``.
    """
    if used_pct is None:
        return None
    used = max(0.0, min(100.0, float(used_pct)))
    base: dict[str, Any] = {
        "window_id": window_id,
        "remaining_pct": round(100.0 - used, 1),
        "exhausts_at": None,
        "pace": None,
        "rate_pct_per_hour": None,
        "samples": 0,
    }
    if used >= EXHAUSTED_PCT:
        return {**base, "exhausts_at": now, "pace": PACE_EXHAUSTED}
    fit = linear_rate(samples, now=now)
    if fit is None:
        return None
    rate, used_samples = fit
    base["rate_pct_per_hour"] = round(rate, 3)
    base["samples"] = used_samples
    if rate <= IDLE_RATE_PCT_PER_HOUR:
        return {**base, "pace": PACE_UNDER}
    exhausts_at = now + (100.0 - used) / rate * 3600.0
    if resets_at is None:
        pace = PACE_AHEAD
    else:
        margin = ON_PACE_MARGIN * max(0.0, float(resets_at) - now)
        if exhausts_at < float(resets_at) - margin:
            pace = PACE_AHEAD
        elif exhausts_at <= float(resets_at) + margin:
            pace = PACE_ON
        else:
            pace = PACE_UNDER
    return {**base, "exhausts_at": round(exhausts_at, 1), "pace": pace}


class UsageSampleBuffer:
    """Per provider window, the last ``SAMPLE_LIMIT`` observations."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path
        self._table: dict[str, list[UsageSample]] = {}
        self._dirty = False
        self._saved_at = 0.0

    # -- recording -------------------------------------------------------------

    def record(self, provider: str, window_id: str, used_pct: float, *, at: float) -> bool:
        key = _key(provider, window_id)
        samples = self._table.setdefault(key, [])
        used = max(0.0, min(100.0, float(used_pct)))
        if samples:
            last = samples[-1]
            if at < last.at:
                return False
            if last.used_pct == used and at - last.at < HEARTBEAT_SECONDS:
                return False
        samples.append(UsageSample(at=float(at), used_pct=used))
        if len(samples) > SAMPLE_LIMIT:
            del samples[: len(samples) - SAMPLE_LIMIT]
        self._dirty = True
        return True

    def record_state(self, usage_state: object, *, now: float) -> int:
        """Every lane of every snapshot in a ``ProviderUsageState``."""
        recorded = 0
        for snapshot in getattr(usage_state, "snapshots", ()) or ():
            provider = getattr(snapshot, "provider_id", None)
            if not isinstance(provider, str):
                continue
            for lane in getattr(snapshot, "lanes", ()) or ():
                lane_id = getattr(lane, "lane_id", None)
                remaining = getattr(lane, "remaining_percent", None)
                if not isinstance(lane_id, str) or remaining is None:
                    continue
                try:
                    used = 100.0 - float(remaining)
                except (TypeError, ValueError):
                    continue
                if self.record(provider, lane_id, used, at=now):
                    recorded += 1
        return recorded

    # -- reading ---------------------------------------------------------------

    def samples(self, provider: str, window_id: str) -> list[UsageSample]:
        return list(self._table.get(_key(provider, window_id), ()))

    def forecast(
        self,
        provider: str,
        window_id: str | None,
        *,
        used_pct: float | None,
        resets_at: float | None,
        now: float,
    ) -> dict[str, Any] | None:
        samples = self.samples(provider, window_id) if window_id else []
        return forecast_window(samples, window_id=window_id, used_pct=used_pct, resets_at=resets_at, now=now)

    @property
    def is_empty(self) -> bool:
        return not any(self._table.values())

    # -- persistence -----------------------------------------------------------

    def to_document(self) -> dict[str, Any]:
        return {
            "schema": SAMPLES_SCHEMA,
            "windows": {
                key: [[round(sample.at, 1), round(sample.used_pct, 2)] for sample in samples]
                for key, samples in sorted(self._table.items())
                if samples
            },
        }

    @classmethod
    def from_document(cls, document: object, *, path: Path | None = None) -> UsageSampleBuffer:
        buffer = cls(path)
        windows = document.get("windows") if isinstance(document, dict) else None
        if isinstance(document, dict) and document.get("schema") == SAMPLES_SCHEMA and isinstance(windows, dict):
            for key, rows in windows.items():
                if not isinstance(key, str) or "|" not in key or not isinstance(rows, list):
                    continue
                samples: list[UsageSample] = []
                for row in rows[-SAMPLE_LIMIT:]:
                    try:
                        at, used = float(row[0]), float(row[1])
                    except (TypeError, ValueError, IndexError):
                        continue
                    if samples and at < samples[-1].at:
                        continue
                    samples.append(UsageSample(at=at, used_pct=max(0.0, min(100.0, used))))
                if samples:
                    buffer._table[key] = samples
        return buffer

    @classmethod
    def load(cls, path: Path | None = None) -> UsageSampleBuffer:
        target = path if path is not None else default_usage_samples_path()
        try:
            from .private_io import read_private_text

            document = json.loads(read_private_text(target, max_bytes=256 * 1024))
        except (OSError, UnicodeError, ValueError):
            return cls(target)
        return cls.from_document(document, path=target)

    def save(self, *, now: float | None = None) -> bool:
        if self.path is None:
            return False
        from .private_io import atomic_private_write

        atomic_private_write(self.path, json.dumps(self.to_document(), separators=(",", ":")) + "\n")
        self._dirty = False
        self._saved_at = time.monotonic() if now is None else now
        return True

    def save_if_due(self, *, now: float | None = None) -> bool:
        """Save when something changed and the last save is old enough."""
        current = time.monotonic() if now is None else now
        if not self._dirty or current - self._saved_at < SAVE_INTERVAL_SECONDS:
            return False
        return self.save(now=current)


__all__ = [
    "EXHAUSTED_PCT",
    "HEARTBEAT_SECONDS",
    "IDLE_RATE_PCT_PER_HOUR",
    "LOOKBACK_SECONDS",
    "MIN_SPAN_SECONDS",
    "ON_PACE_MARGIN",
    "PACE_AHEAD",
    "PACE_EXHAUSTED",
    "PACE_ON",
    "PACE_UNDER",
    "SAMPLE_LIMIT",
    "UsageSample",
    "UsageSampleBuffer",
    "default_usage_samples_path",
    "forecast_window",
    "linear_rate",
]
