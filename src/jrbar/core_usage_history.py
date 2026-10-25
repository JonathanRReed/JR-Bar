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
from .local_token_history import LOCAL_HISTORY_PROVIDERS
from .state_paths import default_state_dir

RANGE_DAYS: Final = {"7d": 7, "30d": 30, "90d": 90, "365d": 365}
HOURS_SHOWN: Final = 7 * 24
#: Providers whose transcripts ``scan_usage`` reads.
SCANNED_PROVIDERS: Final = ("claude", "codex")
#: Every provider with a local token history: Claude and Codex, plus Pi,
#: Grok, Gemini CLI and OpenClaw, whose own session files
#: ``local_token_history`` reads.
HISTORY_PROVIDERS: Final = (*SCANNED_PROVIDERS, *LOCAL_HISTORY_PROVIDERS)
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
            "table_version": usage_stats.PRICING_TABLE_VERSION,
            "approximate": self.estimated,
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
    """The table rates for a record; the graph prices records the same way."""
    rates = usage_stats.rates_for_record(provider, model)
    return None if rates is None else (rates.input_rate, rates.output_rate)


def price_quote(provider: str, model: str, *, codex_default_model: str | None = None) -> PriceQuote | None:
    """The quote a record is billed at; None for a provider with no table."""

    def cache(priced_model: str, input_rate: float) -> float:
        return input_rate * usage_stats.cache_read_rate_for_model(priced_model)

    if provider == "codex" and str(model or "").lower() == CODEX_RECORD_MODEL and codex_default_model:
        rates = _table_rates(provider, codex_default_model)
        if rates is not None:
            return PriceQuote(codex_default_model, rates[0], rates[1], cache(codex_default_model, rates[0]), QUOTE_CODEX_DEFAULT, False)
    rates = _table_rates(provider, str(model or ""))
    if rates is not None:
        return PriceQuote(str(model), rates[0], rates[1], cache(str(model), rates[0]), QUOTE_TABLE, False)
    reference = REFERENCE_MODEL.get(provider)
    if reference is None:
        return None
    rates = _table_rates(provider, reference)
    if rates is None:
        return None
    return PriceQuote(reference, rates[0], rates[1], cache(reference, rates[0]), QUOTE_REFERENCE, True)


def record_rates(provider: str, model: str, *, codex_default_model: str | None = None) -> tuple[float, float, float] | None:
    """(input, output, cache read) dollars per million tokens for a record."""
    quote = price_quote(provider, model, codex_default_model=codex_default_model)
    if quote is None:
        return None
    return quote.input_per_mtok, quote.output_per_mtok, quote.cache_read_per_mtok


def quote_write_rate(provider: str, quote: PriceQuote) -> float:
    """Dollars per million tokens a quote bills cache writes at."""
    # OpenAI bills cache writes at the plain input rate; Anthropic at 1.25x.
    default_write = 1.0 if provider == "codex" else usage_stats.CACHE_WRITE_RATE
    return quote.input_per_mtok * usage_stats.cache_write_rate_for_model(quote.model, default_write)


def quote_cost(
    provider: str,
    quote: PriceQuote | None,
    inp: int,
    cached_in: int,
    cache_create: int,
    out: int,
    *,
    write_rate: float | None = None,
    long_context: bool = False,
) -> float:
    """Dollars for these tokens at ``quote``. A pass over many records of one
    model passes ``write_rate`` (``quote_write_rate``) so the person's
    overrides are read once, not once per record. ``long_context`` marks one
    request over OpenAI's 272K prompt line, billed at 2x input-side and 1.5x
    output; the caller decides it per request, never from a sum."""
    if quote is None:
        return 0.0
    input_rate, output_rate, cache_rate = quote.input_per_mtok, quote.output_per_mtok, quote.cache_read_per_mtok
    if write_rate is None:
        write_rate = quote_write_rate(provider, quote)
    input_side = inp * input_rate + cached_in * cache_rate + cache_create * write_rate
    if long_context:
        input_side *= usage_stats.LONG_CONTEXT_INPUT_MULTIPLIER
        output_side = out * output_rate * usage_stats.LONG_CONTEXT_OUTPUT_MULTIPLIER
    else:
        output_side = out * output_rate
    return (input_side + output_side) / 1_000_000.0


def record_cost(
    provider: str, model: str, inp: int, cached_in: int, cache_create: int, out: int, *, codex_default_model: str | None = None
) -> float:
    return quote_cost(provider, price_quote(provider, model, codex_default_model=codex_default_model), inp, cached_in, cache_create, out)


def _empty_row() -> dict[str, Any]:
    return {"tokens_in": 0, "tokens_out": 0, "cache_read": 0, "cost_usd": 0.0}


def _published_bucket(row: dict[str, Any]) -> dict[str, Any]:
    return {
        **row,
        "cost_usd": round(row["cost_usd"], 4),
        "estimated_cost_usd": round(row["cost_usd"], 4),
        "processed_tokens": row["tokens_in"] + row["tokens_out"] + row["cache_read"],
    }


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
    write_rates: dict[str, float] = {}
    seen: set[str] = set()
    counted = 0
    estimated_records = 0
    unpriced_records = 0
    unpriced_models: list[str] = []
    model_rows: dict[str, dict[str, Any]] = {}
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
        model_name = str(model)
        # A message's one-hour cache writes ride a second record under the
        # same model plus a marker (usage_stats.ONE_HOUR_WRITE_SUFFIX). It
        # prices at its own rate but is the same request on the same model:
        # it is neither a model of its own nor another record.
        display_name = usage_stats.base_model_key(model_name)
        companion = display_name != model_name
        if not companion:
            counted += getattr(record, "record_count", 1)
        for priced_name in {model_name, display_name}:
            if priced_name not in quotes:
                quotes[priced_name] = price_quote(provider, priced_name, codex_default_model=codex_default_model)
                priced_quote = quotes[priced_name]
                if priced_quote is not None:
                    write_rates[priced_name] = quote_write_rate(provider, priced_quote)
        quote = quotes[model_name]
        if quote is None:
            # No price at all: the tokens are counted, the $0 is NOT a
            # price. Unpriced coverage stays its own number (T24) --
            # never blended into "estimated" and never hidden.
            if not companion:
                unpriced_records += getattr(record, "record_count", 1)
            if display_name not in unpriced_models:
                unpriced_models.append(display_name)
        elif quote.estimated and not companion:
            estimated_records += getattr(record, "record_count", 1)
        long_context = getattr(record, "long_context", None)
        if long_context is None:
            long_context = usage_stats.is_long_context_request(
                provider, model_name, int(inp) + int(cached_in) + int(cache_create)
            )
        cost = quote_cost(
            provider, quote, int(inp), int(cached_in), int(cache_create), int(out),
            write_rate=write_rates.get(model_name),
            long_context=long_context,
        )
        total = int(inp) + int(cached_in) + int(cache_create) + int(out)
        model_tokens[display_name] = model_tokens.get(display_name, 0) + total
        # The per-model split the Usage Center's breakdown draws.
        model_split = model_rows.setdefault(display_name, {"tokens": 0, "cost_usd": 0.0, "records": 0})
        model_split["tokens"] += total
        model_split["cost_usd"] += cost
        if not companion:
            model_split["records"] += getattr(record, "record_count", 1)
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
        "days": [{"date": key, **_published_bucket(row)} for key, row in days.items()],
        "hours": [{"hour": key, **_published_bucket(row)} for key, row in hours.items()],
        "pricing": quote.to_dict() if quote is not None else None,
        "account": account,
        "state": state,
        "records": counted,
        # Transcripts the scan has not finished reading (the service fills it
        # in; a document built from records alone has read everything it was
        # given).
        "reading_files": 0,
        # True when any counted record was priced at a stand-in rate: the
        # dollars are approximate anyway, these more so.
        "estimated": estimated_records > 0,
        "estimated_records": estimated_records,
        # Records whose model has no price at all: their tokens are in the
        # rows, their cost contribution is a real $0 absence -- visible,
        # never silently folded into the total (T24).
        "unpriced_records": unpriced_records,
        "unpriced_models": sorted(unpriced_models),
        # Tokens, estimated dollars and record count per model over the
        # range, most tokens first -- "why did cost double this week?"
        # answered by which model the week ran on. `priced` false marks a
        # model whose dollars are a real absence, `estimated` a stand-in.
        "models": [
            {
                "model": name,
                "tokens": row["tokens"],
                "processed_tokens": row["tokens"],
                "estimated_cost_usd": round(row["cost_usd"], 4),
                "cost_usd": round(row["cost_usd"], 4),
                "records": row["records"],
                "priced": quotes.get(name) is not None,
                "estimated": bool(quotes.get(name) and quotes[name].estimated),
            }
            for name, row in sorted(model_rows.items(), key=lambda item: -item[1]["tokens"])
        ],
    }


def scan_provider_records(provider: str, *, days: int, home: Path | None = None) -> list[tuple]:
    """The local transcript records for one provider over the last ``days``,
    read to the end however long that takes."""
    return scan_provider_pass(provider, days=days, home=home, seconds=None).records


@dataclass(frozen=True, slots=True)
class ScanPass:
    """One bounded pass of a provider's scan: the records read so far and how
    many transcripts it left unfinished (carried on by the next pass)."""

    records: list[tuple]
    reading_files: int = 0


def scan_provider_pass(
    provider: str,
    *,
    days: int,
    home: Path | None = None,
    seconds: float | None = usage_stats.USAGE_PASS_BUDGET_SECONDS,
) -> ScanPass:
    """The local transcript records for one provider over the last ``days``,
    from at most about ``seconds`` of reading (all of it when ``seconds`` is
    None).

    A transcript of any size is read, never skipped; a pass that runs out of
    time stops on a line boundary, saves where each file got to and reports
    the files it left, so the caller asks again and the next pass carries on.
    """
    start = (datetime.now() - timedelta(days=days - 1)).replace(hour=0, minute=0, second=0, microsecond=0)
    if provider not in HISTORY_PROVIDERS:
        return ScanPass([])
    from .provider_homes import scan_usage_all_homes

    # Every home of this provider (CLAUDE_CONFIG_DIR, CODEX_HOME and
    # provider_extra_homes), each real folder once.
    options = {} if seconds is None else {"budget": usage_stats.ScanBudget(seconds)}
    totals = scan_usage_all_homes(
        default_state_dir() / "usage-scan-cache.json",
        aggregate=True,
        since_epoch=start.timestamp(),
        provider_ids=(provider,),
        home=home,
        **options,
    )
    coverage = totals.source_coverage.get(provider)
    return ScanPass(
        [record for record in totals.records if record and record[0] == provider],
        coverage.pending_files if coverage is not None else 0,
    )


#: How long a reply may wait for a running scan before it answers from
#: memory: the app abandons a command after 10 s and the Usage window
#: should never feel that; a warm scan finishes inside this.
REPLY_BUDGET_SECONDS: Final = 2.0
#: A document younger than this answers without a rescan at all.
FRESH_SECONDS: Final = 60.0
#: How long the scan thread rests between two bounded passes over a large
#: corpus, so a cold start over many gigabytes never holds a core.
PASS_PAUSE_SECONDS: Final = 0.5
#: The event the daemon pushes when a scan that outlived the budget lands.
READY_EVENT: Final = "usage_history_ready"
FAILED_EVENT: Final = "usage_history_failed"
FAILURE_MESSAGE: Final = "Local history could not be refreshed. Try again."
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


class UsageHistoryScanError(RuntimeError):
    def __init__(self) -> None:
        super().__init__("Local history scan failed")


class UsageHistoryService:
    """Serves ``usage_history`` inside a reply budget, scanning off-thread.

    Scans run on their own thread under one lock (the transcript cache is
    not built for concurrent writers); a request waits for the scan it
    needs at most ``budget`` seconds, then answers what memory holds, marked
    ``pending`` (nothing yet) or ``stale`` (an older document), and the
    scan's completion is announced with a ``usage_history_ready`` event
    carrying the fresh document's counts. A document younger than ``fresh``
    is answered as is, no scan. ``scan`` is ``(provider, days) -> records``,
    or a ``ScanPass`` when it reads in bounded passes: a pass that left
    transcripts unread (``reading_files``) is stored and announced like any
    other, the reply says it is still being read, and the thread waits
    ``pass_pause`` seconds (on the daemon's stop flag, never a sleep) and
    scans again until none are left. ``publish`` is ``(kind, **fields)``;
    ``codex_default_model`` is read at bucketing time so a config change
    prices the next answer.
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
        thread_setup: Callable[[], None] | None = None,
        pass_pause: float = PASS_PAUSE_SECONDS,
        wall_clock: Callable[[], float] | None = None,
        enabled: Callable[[], bool] = lambda: True,
    ) -> None:
        self._scan = scan
        self._enabled = enabled
        #: "Today" for the day and hour buckets; ``clock`` only dates scans.
        self._wall_clock = wall_clock if wall_clock is not None else (lambda: time.time())
        self._pass_pause = float(pass_pause)
        #: Run on each scan thread before it scans (the daemon lowers the
        #: thread's priority: six figures of JSONL lines are pure GIL time
        #: that would otherwise compete with the main thread).
        self._thread_setup = thread_setup
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
        #: Set when the daemon is going down: no new scan starts, and the
        #: warm-up's wait ends at once instead of holding a thread through
        #: interpreter shutdown.
        self.stopping = threading.Event()

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
        if provider not in HISTORY_PROVIDERS:
            return self._finish(
                usage_history_document(
                    [], provider=provider, range_name=range_name, now=self._wall_clock(),
                    codex_default_model=self._codex_default_model(),
                ),
                account, state, pending=False, stale=False, scanned_at=self._clock(),
            )
        key = (provider, days)
        now = self._clock()
        with self._state_lock:
            entry = self._entries.setdefault(key, _Entry())
            if (
                entry.document is not None
                and entry.inflight is None
                and entry.error is None
                and now - entry.scanned_at < self._fresh
                and entry.document["hours"][-1]["hour"] == datetime.fromtimestamp(self._wall_clock()).strftime("%Y-%m-%dT%H:00")
            ):
                return self._finish(entry.document, account, state, pending=False, stale=False, scanned_at=entry.scanned_at)
            event = self._start_locked(key, entry, now)
        wait = self._budget if budget is None else float(budget)
        event.wait(max(0.0, wait))
        with self._state_lock:
            return self._project_locked(self._entries[key], provider, range_name, account, state)

    def observe(
        self,
        provider: str,
        range_name: str,
        *,
        account: dict[str, Any] | None = None,
        state: str | None = None,
    ) -> dict[str, Any] | None:
        """Read the current scan outcome without starting or retrying work."""
        days = range_days(range_name)
        if days is None:
            raise ValueError("range must be one of " + ", ".join(RANGE_DAYS))
        if provider not in HISTORY_PROVIDERS:
            return self.document(provider, range_name, account=account, state=state, budget=0)
        with self._state_lock:
            entry = self._entries.get((provider, days))
            if entry is None or (entry.document is None and entry.inflight is None and entry.error is None):
                return None
            return self._project_locked(entry, provider, range_name, account, state)

    def _project_locked(
        self, entry: _Entry, provider: str, range_name: str,
        account: dict[str, Any] | None, state: str | None,
    ) -> dict[str, Any]:
        if entry.inflight is None and entry.error is not None:
            raise UsageHistoryScanError()
        if entry.inflight is not None:
            entry.owed = True
        if entry.document is None:
            empty = usage_history_document(
                [], provider=provider, range_name=range_name, now=self._wall_clock(),
                codex_default_model=self._codex_default_model(),
            )
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
                if provider in HISTORY_PROVIDERS:
                    key = (provider, days)
                    self._start_locked(key, self._entries.setdefault(key, _Entry()), now)

    def is_scanning(self) -> bool:
        with self._state_lock:
            return any(entry.inflight is not None for entry in self._entries.values())

    # -- internals -------------------------------------------------------------
    def close(self) -> None:
        """Start nothing further; a scan already running finishes on its own."""
        self.stopping.set()

    def _start_locked(self, key: tuple[str, int], entry: _Entry, _now: float) -> threading.Event:
        if entry.inflight is not None:
            return entry.inflight
        event = threading.Event()
        if self.stopping.is_set() or not self._enabled():
            event.set()
            return event
        entry.inflight = event
        entry.owed = False
        # Resolved here, not captured as a default at import time: which
        # ``threading.Thread`` is in force must not depend on when this
        # module happened to be imported.
        factory = self._thread_factory or threading.Thread
        try:
            thread = factory(target=self._run, args=(key, event), name=f"JRBarUsageScan-{key[0]}-{key[1]}", daemon=True)
            thread.start()
        except Exception:
            entry.inflight = None
            entry.owed = False
            event.set()
            raise
        return event

    def _run(self, key: tuple[str, int], event: threading.Event) -> None:
        provider, days = key
        range_name = next((name for name, count in RANGE_DAYS.items() if count == days), f"{days}d")
        if self._thread_setup is not None:
            try:
                self._thread_setup()
            except Exception:
                pass
        while True:
            document: dict[str, Any] | None = None
            error: str | None = None
            reading = 0
            started = self._clock()
            try:
                with self._scan_lock:
                    if self.stopping.is_set() or not self._enabled():
                        with self._state_lock:
                            self._entries[key].inflight = None
                        event.set()
                        return
                    outcome = self._scan(provider, days)
                if self.stopping.is_set() or not self._enabled():
                    with self._state_lock:
                        self._entries[key].inflight = None
                    event.set()
                    return
                records = outcome.records if isinstance(outcome, ScanPass) else outcome
                reading = outcome.reading_files if isinstance(outcome, ScanPass) else 0
                document = usage_history_document(
                    records, provider=provider, range_name=range_name, now=self._wall_clock(),
                    codex_default_model=self._codex_default_model(),
                )
                document["reading_files"] = reading
            except Exception as exc:  # the scan must never take the daemon down
                error = exc.__class__.__name__
            finished = self._clock()
            more = reading > 0 and error is None and not self.stopping.is_set() and self._enabled()
            following = threading.Event() if more else None
            with self._state_lock:
                entry = self._entries.setdefault(key, _Entry())
                if document is not None:
                    entry.document = document
                    entry.scanned_at = finished
                entry.error = error
                # A scan still reading hands its place to the next pass, so a
                # reply that arrives meanwhile still sees a scan in flight.
                entry.inflight = following
                owed = entry.owed
                entry.owed = False
            event.set()
            if self._log is not None:
                try:
                    if error is not None:
                        self._log(f"core: usage history scan {provider} {range_name} failed: {error}")
                    else:
                        still = f" reading={reading}" if reading else ""
                        self._log(
                            f"core: usage history scan {provider} {range_name} {finished - started:.1f}s "
                            f"records={document['records'] if document else 0}{still}"
                        )
                except Exception:
                    pass
            if self._publish is not None and owed:
                try:
                    if document is not None:
                        self._publish(
                            READY_EVENT,
                            provider=provider,
                            label=provider,
                            detail=range_name,
                            range=range_name,
                            records=document["records"],
                            reading_files=reading,
                            scanned_at=finished,
                        )
                    elif error is not None:
                        self._publish(
                            FAILED_EVENT, provider=provider, range=range_name,
                            code="unavailable", message=FAILURE_MESSAGE, notify=False,
                        )
                except Exception:
                    if following is not None:
                        with self._state_lock:
                            if entry.inflight is following:
                                # A missed partial notice is still owed when the next pass lands.
                                entry.owed = True
            if following is None:
                return
            event = following
            if self.stopping.wait(self._pass_pause):
                with self._state_lock:
                    self._entries[key].inflight = None
                event.set()
                return

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
        # ``partial`` is what the app keeps its "still reading" note and its
        # retry on: the rows are a first answer (nothing scanned yet) or the
        # pass left transcripts unread.
        partial = pending or bool(document.get("reading_files"))
        return {
            **document, "account": account, "state": state, "pending": pending, "stale": stale,
            "partial": partial, "scanned_at": scanned_at,
        }


__all__ = [
    "CODEX_RECORD_MODEL",
    "FAILED_EVENT",
    "FAILURE_MESSAGE",
    "FRESH_SECONDS",
    "HISTORY_PROVIDERS",
    "HOURS_SHOWN",
    "PASS_PAUSE_SECONDS",
    "RANGE_DAYS",
    "READY_EVENT",
    "REFERENCE_MODEL",
    "REPLY_BUDGET_SECONDS",
    "SCANNED_PROVIDERS",
    "WARM_RANGE",
    "PriceQuote",
    "ScanPass",
    "UsageHistoryScanError",
    "UsageHistoryService",
    "default_codex_model",
    "price_quote",
    "quote_cost",
    "quote_write_rate",
    "range_days",
    "record_cost",
    "record_rates",
    "scan_provider_pass",
    "scan_provider_records",
    "usage_history_document",
]
