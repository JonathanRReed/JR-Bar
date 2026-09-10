"""``usage_history``: daily and hourly token/cost rows for one provider.

The rows come from the same local transcript scan the Python Usage window
used (``usage_stats.scan_usage`` over ``~/.claude/projects`` and
``~/.codex/sessions``); this module only buckets records, so it is pure and
tested without the scan. A record is the ``usage_stats`` tuple
``(provider, session, model, epoch, input, cached_input, cache_create,
output, dedupe)``.
"""

from __future__ import annotations

import threading
import time
import tomllib
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Final

from . import usage_stats
from .state_paths import default_state_dir

RANGE_DAYS: Final = {"7d": 7, "30d": 30, "90d": 90, "365d": 365}
HOURS_SHOWN: Final = 7 * 24
#: Providers whose transcripts ``scan_usage`` reads.
SCANNED_PROVIDERS: Final = ("claude", "codex")
#: Codex transcripts record the model as the literal ``codex``; the price
#: is the configured default model's (``~/.codex/config.toml``).
CODEX_RECORD_MODEL: Final = "codex"
#: The model a provider is priced at when a record's model is not in the
#: table (or a provider has no transcripts at all): the current
#: mid-range list price, marked ``estimated`` rather than billed at $0.
REFERENCE_MODEL: Final = {"claude": "sonnet", "codex": "gpt-5.6", "gemini": "gemini-3-flash"}

QUOTE_TABLE: Final = "table"
QUOTE_CODEX_DEFAULT: Final = "codex_default"
QUOTE_REFERENCE: Final = "reference"


@dataclass(frozen=True, slots=True)
class PriceQuote:
    """Dollars per million tokens for one record's model."""

    model: str
    input_per_mtok: float
    output_per_mtok: float
    cache_read_per_mtok: float
    #: ``table`` (the model's own row), ``codex_default`` (a ``codex``
    #: record priced at the configured default model), ``reference`` (an
    #: unknown model priced at the provider's reference rate).
    source: str
    #: True when the price is a stand-in, not the model's own row.
    estimated: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "input_per_mtok": self.input_per_mtok,
            "output_per_mtok": self.output_per_mtok,
            "cache_read_per_mtok": self.cache_read_per_mtok,
            "as_of": usage_stats.PRICING_TABLE_AS_OF,
            "approximate": True,
            "currency": "USD",
            "model": self.model,
            "source": self.source,
            "estimated": self.estimated,
        }


def range_days(range_name: object) -> int | None:
    return RANGE_DAYS.get(str(range_name)) if isinstance(range_name, str) else None


def default_codex_model(home: Path | None = None) -> str | None:
    """The ``model`` the Codex CLI is configured to use, or None."""
    base = Path(home) if home is not None else Path.home()
    try:
        with (base / ".codex" / "config.toml").open("rb") as handle:
            document = tomllib.load(handle)
    except (OSError, ValueError, tomllib.TOMLDecodeError):
        return None
    model = document.get("model") if isinstance(document, dict) else None
    return model.strip() if isinstance(model, str) and model.strip() else None


def _table_rates(provider: str, model: str) -> tuple[float, float] | None:
    if provider == "codex":
        return usage_stats._gpt_pricing_for_model(model)
    if provider == "gemini":
        return usage_stats._gemini_pricing_for_model(model)
    if provider == "claude":
        return usage_stats._pricing_for_model(model)
    return None


def price_quote(provider: str, model: str, *, codex_default_model: str | None = None) -> PriceQuote | None:
    """The quote a record is billed at; None for a provider with no table."""

    def cache(input_rate: float) -> float:
        return input_rate * usage_stats.CACHE_READ_RATE

    if provider == "codex" and str(model or "").lower() == CODEX_RECORD_MODEL and codex_default_model:
        rates = _table_rates(provider, codex_default_model)
        if rates is not None:
            return PriceQuote(codex_default_model, rates[0], rates[1], cache(rates[0]), QUOTE_CODEX_DEFAULT, False)
    rates = _table_rates(provider, str(model or ""))
    if rates is not None:
        return PriceQuote(str(model), rates[0], rates[1], cache(rates[0]), QUOTE_TABLE, False)
    reference = REFERENCE_MODEL.get(provider)
    if reference is None:
        return None
    rates = _table_rates(provider, reference)
    if rates is None:
        return None
    return PriceQuote(reference, rates[0], rates[1], cache(rates[0]), QUOTE_REFERENCE, True)


def record_rates(provider: str, model: str, *, codex_default_model: str | None = None) -> tuple[float, float, float] | None:
    """(input, output, cache read) dollars per million tokens for a record."""
    quote = price_quote(provider, model, codex_default_model=codex_default_model)
    if quote is None:
        return None
    return quote.input_per_mtok, quote.output_per_mtok, quote.cache_read_per_mtok


def quote_cost(provider: str, quote: PriceQuote | None, inp: int, cached_in: int, cache_create: int, out: int) -> float:
    if quote is None:
        return 0.0
    input_rate, output_rate, cache_rate = quote.input_per_mtok, quote.output_per_mtok, quote.cache_read_per_mtok
    # OpenAI bills cache writes at the plain input rate; Anthropic at 1.25x.
    write_rate = input_rate if provider == "codex" else input_rate * usage_stats.CACHE_WRITE_RATE
    return (inp * input_rate + cached_in * cache_rate + cache_create * write_rate + out * output_rate) / 1_000_000.0


def record_cost(
    provider: str, model: str, inp: int, cached_in: int, cache_create: int, out: int, *, codex_default_model: str | None = None
) -> float:
    return quote_cost(provider, price_quote(provider, model, codex_default_model=codex_default_model), inp, cached_in, cache_create, out)


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
    codex_default_model: str | None = None,
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
    quotes: dict[str, PriceQuote | None] = {}
    seen: set[str] = set()
    counted = 0
    estimated_records = 0
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
        model_name = str(model)
        if model_name not in quotes:
            quotes[model_name] = price_quote(provider, model_name, codex_default_model=codex_default_model)
        quote = quotes[model_name]
        if quote is None or quote.estimated:
            estimated_records += 1
        cost = quote_cost(provider, quote, int(inp), int(cached_in), int(cache_create), int(out))
        total = int(inp) + int(cached_in) + int(cache_create) + int(out)
        model_tokens[model_name] = model_tokens.get(model_name, 0) + total
        for bucket in (day_bucket, hours.get(stamp.strftime("%Y-%m-%dT%H:00"))):
            if bucket is None:
                continue
            bucket["tokens_in"] += int(inp) + int(cache_create)
            bucket["tokens_out"] += int(out)
            bucket["cache_read"] += int(cached_in)
            bucket["cost_usd"] += cost
    # The dominant model's quote; with no records at all, the provider's
    # reference quote (marked estimated) so the window can still show a
    # rate card for a provider without local transcripts (Gemini).
    quote = None
    if model_tokens:
        dominant = max(model_tokens, key=model_tokens.get)
        quote = quotes.get(dominant)
    else:
        reference = REFERENCE_MODEL.get(provider)
        quote = price_quote(provider, reference, codex_default_model=codex_default_model) if reference else None
        if quote is not None:
            quote = PriceQuote(quote.model, quote.input_per_mtok, quote.output_per_mtok, quote.cache_read_per_mtok, QUOTE_REFERENCE, True)
    return {
        "provider": provider,
        "range": range_name,
        "days": [{"date": key, **{k: (round(v, 4) if k == "cost_usd" else v) for k, v in row.items()}} for key, row in days.items()],
        "hours": [{"hour": key, **{k: (round(v, 4) if k == "cost_usd" else v) for k, v in row.items()}} for key, row in hours.items()],
        "pricing": quote.to_dict() if quote is not None else None,
        "account": account,
        "state": state,
        "records": counted,
        # True when any counted record was priced at a stand-in rate: the
        # dollars are approximate anyway, these more so.
        "estimated": estimated_records > 0,
        "estimated_records": estimated_records,
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


#: How long a reply may wait for a running scan before it answers from
#: memory: the app abandons a command after 10 s and the Usage window
#: should never feel that; a warm scan finishes inside this.
REPLY_BUDGET_SECONDS: Final = 2.0
#: A document younger than this answers without a rescan at all.
FRESH_SECONDS: Final = 60.0
#: The event the daemon pushes when a scan that outlived the budget lands.
READY_EVENT: Final = "usage_history_ready"
#: Ranges the startup warm-up scans so the first request finds a hot cache.
WARM_RANGE: Final = "30d"


@dataclass(slots=True)
class _Entry:
    document: dict[str, Any] | None = None
    scanned_at: float = 0.0
    inflight: threading.Event | None = None
    #: True once a request was answered pending or stale for the running
    #: scan: that client is owed a ``usage_history_ready`` event.
    owed: bool = False
    error: str | None = None


class UsageHistoryService:
    """Serves ``usage_history`` inside a reply budget, scanning off-thread.

    Scans run on their own thread under one lock (the transcript cache is
    not built for concurrent writers); a request waits for the scan it
    needs at most ``budget`` seconds, then answers what memory holds, marked
    ``pending`` (nothing yet) or ``stale`` (an older document), and the
    scan's completion is announced with a ``usage_history_ready`` event
    carrying the fresh document's counts. A document younger than ``fresh``
    is answered as is, no scan. ``scan`` is ``(provider, days) -> records``;
    ``publish`` is ``(kind, **fields)``; ``codex_default_model`` is read at
    bucketing time so a config change prices the next answer.
    """

    def __init__(
        self,
        scan: Callable[[str, int], list[tuple]],
        publish: Callable[..., None] | None = None,
        *,
        budget: float = REPLY_BUDGET_SECONDS,
        fresh: float = FRESH_SECONDS,
        codex_default_model: Callable[[], str | None] = default_codex_model,
        log: Callable[[str], None] | None = None,
        clock: Callable[[], float] = time.time,
        thread_factory: Callable[..., threading.Thread] | None = None,
    ) -> None:
        self._scan = scan
        self._publish = publish
        self._budget = float(budget)
        self._fresh = float(fresh)
        self._codex_default_model = codex_default_model
        self._log = log
        self._clock = clock
        self._thread_factory = thread_factory
        self._scan_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._entries: dict[tuple[str, int], _Entry] = {}

    # -- public ---------------------------------------------------------------
    def document(
        self,
        provider: str,
        range_name: str,
        *,
        account: dict[str, Any] | None = None,
        state: str | None = None,
        budget: float | None = None,
    ) -> dict[str, Any]:
        days = range_days(range_name)
        if days is None:
            raise ValueError("range must be one of " + ", ".join(RANGE_DAYS))
        if provider not in SCANNED_PROVIDERS:
            return self._finish(
                usage_history_document([], provider=provider, range_name=range_name, codex_default_model=self._codex_default_model()),
                account, state, pending=False, stale=False, scanned_at=self._clock(),
            )
        key = (provider, days)
        now = self._clock()
        with self._state_lock:
            entry = self._entries.setdefault(key, _Entry())
            if entry.document is not None and entry.inflight is None and now - entry.scanned_at < self._fresh:
                return self._finish(entry.document, account, state, pending=False, stale=False, scanned_at=entry.scanned_at)
            event = self._start_locked(key, entry, now)
        wait = self._budget if budget is None else float(budget)
        event.wait(max(0.0, wait))
        with self._state_lock:
            entry = self._entries[key]
            if entry.inflight is not None:
                entry.owed = True
            if entry.document is None:
                empty = usage_history_document([], provider=provider, range_name=range_name, codex_default_model=self._codex_default_model())
                return self._finish(empty, account, state, pending=True, stale=False, scanned_at=None)
            stale = entry.inflight is not None
            return self._finish(entry.document, account, state, pending=False, stale=stale, scanned_at=entry.scanned_at)

    def warm(self, providers: Iterable[str] = SCANNED_PROVIDERS, range_name: str = WARM_RANGE) -> None:
        """Start the scans a first request would need, without waiting."""
        days = range_days(range_name)
        if days is None:
            return
        now = self._clock()
        with self._state_lock:
            for provider in providers:
                if provider in SCANNED_PROVIDERS:
                    key = (provider, days)
                    self._start_locked(key, self._entries.setdefault(key, _Entry()), now)

    def is_scanning(self) -> bool:
        with self._state_lock:
            return any(entry.inflight is not None for entry in self._entries.values())

    # -- internals -------------------------------------------------------------
    def _start_locked(self, key: tuple[str, int], entry: _Entry, _now: float) -> threading.Event:
        if entry.inflight is not None:
            return entry.inflight
        event = threading.Event()
        entry.inflight = event
        entry.owed = False
        # Resolved here, not captured as a default at import time: which
        # ``threading.Thread`` is in force must not depend on when this
        # module happened to be imported.
        factory = self._thread_factory or threading.Thread
        thread = factory(target=self._run, args=(key, event), name=f"JRBarUsageScan-{key[0]}-{key[1]}", daemon=True)
        thread.start()
        return event

    def _run(self, key: tuple[str, int], event: threading.Event) -> None:
        provider, days = key
        range_name = next((name for name, count in RANGE_DAYS.items() if count == days), f"{days}d")
        document: dict[str, Any] | None = None
        error: str | None = None
        started = self._clock()
        try:
            with self._scan_lock:
                records = self._scan(provider, days)
            document = usage_history_document(
                records, provider=provider, range_name=range_name, codex_default_model=self._codex_default_model()
            )
        except Exception as exc:  # the scan must never take the daemon down
            error = exc.__class__.__name__
        finished = self._clock()
        with self._state_lock:
            entry = self._entries.setdefault(key, _Entry())
            if document is not None:
                entry.document = document
                entry.scanned_at = finished
            entry.error = error
            entry.inflight = None
            owed = entry.owed
            entry.owed = False
        event.set()
        if self._log is not None:
            if error is not None:
                self._log(f"core: usage history scan {provider} {range_name} failed: {error}")
            else:
                self._log(f"core: usage history scan {provider} {range_name} {finished - started:.1f}s records={document['records'] if document else 0}")
        if self._publish is not None and document is not None and owed:
            self._publish(
                READY_EVENT,
                provider=provider,
                label=provider,
                detail=range_name,
                range=range_name,
                records=document["records"],
                scanned_at=finished,
            )

    @staticmethod
    def _finish(
        document: dict[str, Any],
        account: dict[str, Any] | None,
        state: str | None,
        *,
        pending: bool,
        stale: bool,
        scanned_at: float | None,
    ) -> dict[str, Any]:
        return {**document, "account": account, "state": state, "pending": pending, "stale": stale, "scanned_at": scanned_at}


__all__ = [
    "CODEX_RECORD_MODEL",
    "FRESH_SECONDS",
    "HOURS_SHOWN",
    "RANGE_DAYS",
    "READY_EVENT",
    "REFERENCE_MODEL",
    "REPLY_BUDGET_SECONDS",
    "SCANNED_PROVIDERS",
    "WARM_RANGE",
    "PriceQuote",
    "UsageHistoryService",
    "default_codex_model",
    "price_quote",
    "quote_cost",
    "range_days",
    "record_cost",
    "record_rates",
    "scan_provider_records",
    "usage_history_document",
]
