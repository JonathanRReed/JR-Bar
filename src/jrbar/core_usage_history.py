"""``usage_history``: daily and hourly token/cost rows for one provider.

The rows come from the same local transcript scan the Python Usage window
used (``usage_stats.scan_usage`` over ``~/.claude/projects`` and
``~/.codex/sessions``); this module only buckets records, so it is pure and
tested without the scan. A record is the ``usage_stats`` tuple
``(provider, session, model, epoch, input, cached_input, cache_create,
output, dedupe)``.
"""

from __future__ import annotations

import time
from collections.abc import Iterable
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Final

from . import usage_stats
from .state_paths import default_state_dir

RANGE_DAYS: Final = {"7d": 7, "30d": 30, "90d": 90, "365d": 365}
HOURS_SHOWN: Final = 7 * 24
#: Providers whose transcripts ``scan_usage`` reads.
SCANNED_PROVIDERS: Final = ("claude", "codex")


def range_days(range_name: object) -> int | None:
    return RANGE_DAYS.get(str(range_name)) if isinstance(range_name, str) else None


def record_rates(provider: str, model: str) -> tuple[float, float, float] | None:
    """(input, output, cache read) dollars per million tokens for a record."""
    if provider == "codex":
        pricing = usage_stats._gpt_pricing_for_model(model)
    else:
        pricing = usage_stats._pricing_for_model(model)
    if pricing is None:
        return None
    input_rate, output_rate = pricing
    return input_rate, output_rate, input_rate * usage_stats.CACHE_READ_RATE


def record_cost(provider: str, model: str, inp: int, cached_in: int, cache_create: int, out: int) -> float:
    rates = record_rates(provider, model)
    if rates is None:
        return 0.0
    input_rate, output_rate, cache_rate = rates
    # OpenAI bills cache writes at the plain input rate; Anthropic at 1.25x.
    write_rate = input_rate if provider == "codex" else input_rate * usage_stats.CACHE_WRITE_RATE
    return (inp * input_rate + cached_in * cache_rate + cache_create * write_rate + out * output_rate) / 1_000_000.0


def _empty_row() -> dict[str, Any]:
    return {"tokens_in": 0, "tokens_out": 0, "cache_read": 0, "cost_usd": 0.0}


def usage_history_document(
    records: Iterable[tuple],
    *,
    provider: str,
    range_name: str,
    now: float | None = None,
    account: dict[str, Any] | None = None,
    state: str | None = None,
) -> dict[str, Any]:
    """Bucket a provider's records into the app's ``usage_history`` shape."""
    days_wanted = range_days(range_name)
    if days_wanted is None:
        raise ValueError("range must be one of " + ", ".join(RANGE_DAYS))
    current = datetime.fromtimestamp(now if now is not None else time.time())
    midnight = current.replace(hour=0, minute=0, second=0, microsecond=0)
    day_keys = [(midnight - timedelta(days=offset)).date().isoformat() for offset in range(days_wanted - 1, -1, -1)]
    days: dict[str, dict[str, Any]] = {key: _empty_row() for key in day_keys}
    hour_top = current.replace(minute=0, second=0, microsecond=0)
    hour_starts = [hour_top - timedelta(hours=offset) for offset in range(HOURS_SHOWN - 1, -1, -1)]
    hours: dict[str, dict[str, Any]] = {
        start.strftime("%Y-%m-%dT%H:00"): {**_empty_row(), "at": start.timestamp()} for start in hour_starts
    }
    model_tokens: dict[str, int] = {}
    seen: set[str] = set()
    counted = 0
    for record in records:
        try:
            record_provider, _session, model, epoch, inp, cached_in, cache_create, out, dedupe = record
        except (TypeError, ValueError):
            continue
        if record_provider != provider or dedupe in seen:
            continue
        seen.add(dedupe)
        try:
            stamp = datetime.fromtimestamp(float(epoch))
        except (OverflowError, OSError, TypeError, ValueError):
            continue
        day_bucket = days.get(stamp.date().isoformat())
        if day_bucket is None:
            continue
        counted += 1
        cost = record_cost(provider, str(model), int(inp), int(cached_in), int(cache_create), int(out))
        total = int(inp) + int(cached_in) + int(cache_create) + int(out)
        model_tokens[str(model)] = model_tokens.get(str(model), 0) + total
        for bucket in (day_bucket, hours.get(stamp.strftime("%Y-%m-%dT%H:00"))):
            if bucket is None:
                continue
            bucket["tokens_in"] += int(inp) + int(cache_create)
            bucket["tokens_out"] += int(out)
            bucket["cache_read"] += int(cached_in)
            bucket["cost_usd"] += cost
    pricing = None
    if model_tokens:
        dominant = max(model_tokens, key=model_tokens.get)
        rates = record_rates(provider, dominant)
        if rates is not None:
            pricing = {
                "input_per_mtok": rates[0],
                "output_per_mtok": rates[1],
                "cache_read_per_mtok": rates[2],
                "as_of": usage_stats.PRICING_TABLE_AS_OF,
                "approximate": True,
                "currency": "USD",
                "model": dominant,
            }
    return {
        "provider": provider,
        "range": range_name,
        "days": [{"date": key, **{k: (round(v, 4) if k == "cost_usd" else v) for k, v in row.items()}} for key, row in days.items()],
        "hours": [{"hour": key, **{k: (round(v, 4) if k == "cost_usd" else v) for k, v in row.items()}} for key, row in hours.items()],
        "pricing": pricing,
        "account": account,
        "state": state,
        "records": counted,
    }


def scan_provider_records(provider: str, *, days: int, home: Path | None = None) -> list[tuple]:
    """The local transcript records for one provider over the last ``days``."""
    if provider not in SCANNED_PROVIDERS:
        return []
    base = Path(home) if home is not None else Path.home()
    start = (datetime.now() - timedelta(days=days - 1)).replace(hour=0, minute=0, second=0, microsecond=0)
    totals = usage_stats.scan_usage(
        base / ".claude" / "projects",
        default_state_dir() / "usage-scan-cache.json",
        since_epoch=start.timestamp(),
        codex_root=base / ".codex" / "sessions",
        provider_ids=(provider,),
    )
    return [record for record in totals.records if record and record[0] == provider]


__all__ = [
    "HOURS_SHOWN",
    "RANGE_DAYS",
    "SCANNED_PROVIDERS",
    "range_days",
    "record_cost",
    "record_rates",
    "scan_provider_records",
    "usage_history_document",
]
