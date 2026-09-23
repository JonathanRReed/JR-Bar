"""``usage_history`` bucketing (core_usage_history.py)."""

from __future__ import annotations

import threading
from datetime import datetime, timedelta

import pytest

from jrbar import core_usage_history as history
from jrbar import usage_stats

NOW = datetime(2026, 9, 9, 21, 30, 0)


def _record(provider: str, model: str, when: datetime, *, inp=1000, cached=500, create=200, out=300, dedupe="d"):
    return (provider, "session", model, when.timestamp(), inp, cached, create, out, dedupe)


def test_days_and_hours_cover_the_range_and_dedupe_records__and_2_more() -> None:
    # --- scenario: days_and_hours_cover_the_range_and_dedupe_records
    hour_ago = NOW - timedelta(hours=1)
    records = [
        _record("claude", "fable", hour_ago, dedupe="a"),
        _record("claude", "fable", hour_ago, dedupe="a"),  # duplicate
        _record("claude", "sonnet", NOW - timedelta(days=2), inp=10, cached=0, create=0, out=5, dedupe="b"),
        _record("claude", "fable", NOW - timedelta(days=40), dedupe="old"),
        _record("codex", "gpt-5.6-sol", hour_ago, dedupe="c"),
        ("broken",),
    ]
    document = history.usage_history_document(records, provider="claude", range_name="7d", now=NOW.timestamp())
    assert document["provider"] == "claude" and document["range"] == "7d"
    assert [row["date"] for row in document["days"]] == [
        (NOW - timedelta(days=offset)).date().isoformat() for offset in range(6, -1, -1)
    ]
    assert len(document["hours"]) == history.HOURS_SHOWN
    assert document["hours"][-1]["hour"] == NOW.strftime("%Y-%m-%dT%H:00")
    today = document["days"][-1]
    assert (today["tokens_in"], today["tokens_out"], today["cache_read"]) == (1200, 300, 500)
    expected = (1000 * 10.0 + 500 * 1.0 + 200 * 12.5 + 300 * 50.0) / 1_000_000
    assert today["cost_usd"] == pytest.approx(expected, abs=1e-4)
    two_days = document["days"][-3]
    assert two_days["tokens_in"] == 10 and two_days["cost_usd"] == pytest.approx((10 * 3.0 + 5 * 15.0) / 1e6, abs=1e-4)
    last_hour = next(row for row in document["hours"] if row["hour"] == hour_ago.strftime("%Y-%m-%dT%H:00"))
    assert last_hour["tokens_in"] == 1200 and last_hour["at"] == hour_ago.replace(minute=0, second=0).timestamp()
    assert document["records"] == 2
    assert document["pricing"] == {
        "input_per_mtok": 10.0,
        "output_per_mtok": 50.0,
        "cache_read_per_mtok": 1.0,
        "as_of": usage_stats.PRICING_TABLE_AS_OF,
        "table_version": usage_stats.PRICING_TABLE_VERSION,
        "approximate": False,
        "currency": "USD",
        "model": "fable",
        "source": "table",
        "estimated": False,
    }
    assert document["estimated"] is False and document["estimated_records"] == 0

    # --- scenario: codex_costs_bill_cache_writes_at_the_input_rate
    document = history.usage_history_document(
        [_record("codex", "gpt-5.6-sol", NOW, inp=100, cached=100, create=100, out=100, dedupe="x")],
        provider="codex", range_name="30d", now=NOW.timestamp(), account={"plan": "Plus"}, state="ready",
    )
    assert len(document["days"]) == 30
    assert document["days"][-1]["cost_usd"] == pytest.approx((100 * 4.0 + 100 * 0.4 + 100 * 4.0 + 100 * 20.0) / 1e6, abs=1e-4)
    assert document["account"] == {"plan": "Plus"} and document["state"] == "ready"
    assert document["pricing"]["cache_read_per_mtok"] == pytest.approx(0.4)

    # --- scenario: unknown_models_are_estimated_at_the_reference_rate_not_zero
    document = history.usage_history_document(
        [_record("claude", "mystery-9", NOW, inp=100_000, cached=0, create=0, out=10_000, dedupe="u")],
        provider="claude", range_name="90d", now=NOW.timestamp(),
    )
    # Sonnet's rate stands in: 100k * $2 + 10k * $10 per MTok.
    assert document["days"][-1]["cost_usd"] == pytest.approx((100_000 * 2.0 + 10_000 * 10.0) / 1e6, abs=1e-4)
    assert document["pricing"]["model"] == "sonnet"
    assert document["pricing"]["source"] == "reference" and document["pricing"]["estimated"] is True
    assert document["estimated"] is True and document["estimated_records"] == 1
    with pytest.raises(ValueError):
        history.usage_history_document([], provider="claude", range_name="2d")
    assert history.range_days("365d") == 365 and history.range_days(7) is None
    assert history.scan_provider_records("grok", days=7) == []
    # A provider with no table at all still bills nothing and quotes nothing.
    assert history.price_quote("grok", "grok-4") is None
    assert history.record_cost("grok", "grok-4", 1, 1, 1, 1) == 0.0

    # --- scenario: unpriced_records_stay_visible_not_estimated (T24)
    # A record whose provider has no price table at all is counted, its
    # cost is a real absence, and it is NOT blended into "estimated".
    document = history.usage_history_document(
        [_record("grok", "grok-4", NOW, inp=5000, cached=0, create=0, out=1000, dedupe="g")],
        provider="grok", range_name="7d", now=NOW.timestamp(),
    )
    assert document["days"][-1]["tokens_in"] == 5000
    assert document["days"][-1]["cost_usd"] == 0.0
    assert document["pricing"] is None
    assert document["estimated"] is False and document["estimated_records"] == 0
    assert document["unpriced_records"] == 1 and document["unpriced_models"] == ["grok-4"]
    # A mixed provider shows both: table-priced rows, reference-priced
    # rows labeled estimated, and the unpriced count stays zero.
    document = history.usage_history_document(
        [
            _record("claude", "fable", NOW, dedupe="a"),
            _record("claude", "mystery-9", NOW, dedupe="b"),
        ],
        provider="claude", range_name="7d", now=NOW.timestamp(),
    )
    assert document["estimated_records"] == 1 and document["unpriced_records"] == 0
    assert document["unpriced_models"] == []



def test_codex_records_are_priced_at_the_configured_default_model(tmp_path) -> None:
    """Codex transcripts name their model ``codex``; the configured default
    model's row prices them. A default the table does not know falls back
    to the GPT-5.6 reference rate, marked estimated."""
    known = history.usage_history_document(
        [_record("codex", "codex", NOW, inp=100_000, cached=0, create=0, out=10_000, dedupe="k")],
        provider="codex", range_name="7d", now=NOW.timestamp(), codex_default_model="gpt-5.6-luna",
    )
    assert known["days"][-1]["cost_usd"] == pytest.approx((100_000 * 0.20 + 10_000 * 1.20) / 1e6, abs=1e-4)
    assert known["pricing"]["model"] == "gpt-5.6-luna" and known["pricing"]["source"] == "codex_default"
    assert known["pricing"]["estimated"] is False and known["estimated"] is False

    # A default the table now knows prices from its own row: gpt-6-astra
    # joined the table in rates-v3, so this is a codex_default quote, not
    # the reference stand-in it was under rates-v2.
    known_default = history.usage_history_document(
        [_record("codex", "codex", NOW, inp=100_000, cached=0, create=0, out=10_000, dedupe="k")],
        provider="codex", range_name="7d", now=NOW.timestamp(), codex_default_model="gpt-6-astra",
    )
    assert known_default["days"][-1]["cost_usd"] == pytest.approx((100_000 * 10.0 + 10_000 * 50.0) / 1e6, abs=1e-4)
    assert known_default["pricing"]["model"] == "gpt-6-astra" and known_default["pricing"]["source"] == "codex_default"
    assert known_default["pricing"]["estimated"] is False and known_default["estimated"] is False

    unknown = history.usage_history_document(
        [_record("codex", "codex", NOW, inp=100_000, cached=0, create=0, out=10_000, dedupe="k")],
        provider="codex", range_name="7d", now=NOW.timestamp(), codex_default_model="gpt-7-zeta",
    )
    assert unknown["days"][-1]["cost_usd"] == pytest.approx((100_000 * 4.0 + 10_000 * 20.0) / 1e6, abs=1e-4)
    assert unknown["pricing"] == {
        **unknown["pricing"], "model": "gpt-5.6", "source": "reference", "estimated": True,
        "input_per_mtok": 4.0, "output_per_mtok": 20.0, "cache_read_per_mtok": pytest.approx(0.4),
    }
    assert unknown["estimated"] is True and unknown["estimated_records"] == 1
    # No config at all: the same reference fallback.
    none = history.usage_history_document(
        [_record("codex", "codex", NOW, dedupe="k")], provider="codex", range_name="7d", now=NOW.timestamp()
    )
    assert none["pricing"]["source"] == "reference"

    (tmp_path / ".codex").mkdir()
    (tmp_path / ".codex" / "config.toml").write_text('model = "gpt-5.6-sol"\nmodel_reasoning_effort = "low"\n')
    assert history.default_codex_model(tmp_path) == "gpt-5.6-sol"
    (tmp_path / ".codex" / "config.toml").write_text("model = [broken\n")
    assert history.default_codex_model(tmp_path) is None
    assert history.default_codex_model(tmp_path / "nowhere") is None


def test_models_split_tokens_and_dollars_by_model_most_tokens_first() -> None:
    hour_ago = NOW - timedelta(hours=1)
    records = [
        _record("claude", "fable", hour_ago, dedupe="a"),
        _record("claude", "fable", NOW - timedelta(days=1), dedupe="b"),
        _record("claude", "haiku", hour_ago, inp=10, cached=0, create=0, out=5, dedupe="c"),
        _record("claude", "mystery", hour_ago, inp=1, cached=0, create=0, out=1, dedupe="d"),
        _record("claude", "fable", NOW - timedelta(days=40), dedupe="old"),
    ]
    document = history.usage_history_document(records, provider="claude", range_name="7d", now=NOW.timestamp())
    models = document["models"]
    assert [row["model"] for row in models] == ["fable", "haiku", "mystery"]
    fable = models[0]
    assert fable["tokens"] == 2 * 2000 and fable["records"] == 2
    assert fable["priced"] is True and fable["estimated"] is False
    # The split adds up to the days it was cut from.
    assert sum(row["tokens"] for row in models) == sum(
        day["tokens_in"] + day["tokens_out"] + day["cache_read"] for day in document["days"]
    )
    assert sum(row["cost_usd"] for row in models) == pytest.approx(
        sum(day["cost_usd"] for day in document["days"]), abs=1e-3
    )
    # A model with no table row is priced at the reference stand-in, and says so.
    assert models[2]["estimated"] is True


def test_gemini_answers_a_reference_quote_without_transcripts() -> None:
    document = history.usage_history_document([], provider="gemini", range_name="7d", now=NOW.timestamp())
    assert document["records"] == 0 and all(row["cost_usd"] == 0.0 for row in document["days"])
    assert document["pricing"]["model"] == "gemini-3-flash"
    assert document["pricing"]["input_per_mtok"] == 0.5 and document["pricing"]["output_per_mtok"] == 3.0
    assert document["pricing"]["source"] == "reference" and document["pricing"]["estimated"] is True
    assert document["estimated"] is False
    # A named Gemini model prices from its own row.
    assert history.price_quote("gemini", "gemini-3-pro").input_per_mtok == 2.0
    assert history.price_quote("gemini", "Gemini 3.8 Flash").source == "table"


# -- UsageHistoryService --------------------------------------------------------
class _Clock:
    def __init__(self, start: float = 1_000.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now


class _Threads:
    """Records the scan threads the service starts, so a test can join them
    instead of polling a clock the contract forbids."""

    def __init__(self) -> None:
        self.threads: list[threading.Thread] = []

    def __call__(self, **kwargs) -> threading.Thread:
        thread = threading.Thread(**kwargs)
        self.threads.append(thread)
        return thread

    def settle(self, timeout: float = 5.0) -> None:
        for thread in tuple(self.threads):
            thread.join(timeout)


class _Gate:
    """A scan that blocks until released, so a test controls its duration."""

    def __init__(self, records: list[tuple]) -> None:
        self.release = threading.Event()
        self.records = records
        self.calls: list[tuple[str, int]] = []

    def __call__(self, provider: str, days: int) -> list[tuple]:
        self.calls.append((provider, days))
        self.release.wait(5.0)
        return self.records


def _service(scan, publish=None, clock=None, threads=None, **kw):
    return history.UsageHistoryService(
        scan,
        publish,
        codex_default_model=lambda: None,
        clock=clock or _Clock(),
        budget=0.2,
        fresh=60.0,
        thread_factory=threads or _Threads(),
        **kw,
    )


def test_service_answers_inside_the_budget_when_the_scan_is_quick__and_2_more() -> None:
    # --- scenario: service_answers_inside_the_budget_when_the_scan_is_quick
    now = datetime.now()
    service = _service(lambda provider, days: [_record("codex", "gpt-5.6", now)])
    document = service.document("codex", "7d", account={"plan": "pro"}, state="live")
    assert document["records"] == 1
    assert document["pending"] is False and document["stale"] is False
    assert document["account"] == {"plan": "pro"} and document["state"] == "live"
    assert document["scanned_at"] is not None

    # --- scenario: service_answers_pending_then_pushes_ready_when_a_cold_scan_outlives_the_budget
    now = datetime.now()
    gate = _Gate([_record("codex", "gpt-5.6", now)])
    events: list[tuple[str, dict]] = []
    clock = _Clock()
    threads = _Threads()
    service = _service(gate, lambda kind, **fields: events.append((kind, fields)), clock=clock, threads=threads)

    first = service.document("codex", "30d")
    assert first["pending"] is True and first["records"] == 0 and first["scanned_at"] is None
    assert service.is_scanning()
    clock.now += 45.0  # the cold scan took longer than the budget
    gate.release.set()
    threads.settle()
    assert not service.is_scanning()
    assert events == [
        (
            history.READY_EVENT,
            {"provider": "codex", "label": "codex", "detail": "30d", "range": "30d", "records": 1, "scanned_at": clock.now},
        )
    ]
    # The next request answers from memory, fresh, with no rescan.
    second = service.document("codex", "30d")
    assert second["records"] == 1 and second["pending"] is False and second["stale"] is False
    assert gate.calls == [("codex", 30)]

    # --- scenario: service_answers_the_last_document_stale_while_a_rescan_runs_and_stays_quiet_when_quick
    now = datetime.now()
    clock = _Clock()
    events: list[str] = []
    first_gate = _Gate([_record("codex", "gpt-5.6", now)])
    first_gate.release.set()
    scans = {"n": 0}
    slow = _Gate([_record("codex", "gpt-5.6", now, dedupe="a"), _record("codex", "gpt-5.6", now, dedupe="b")])

    def scan(provider: str, days: int) -> list[tuple]:
        scans["n"] += 1
        return first_gate(provider, days) if scans["n"] == 1 else slow(provider, days)

    threads = _Threads()
    service = _service(scan, lambda kind, **fields: events.append(kind), clock=clock, threads=threads)
    assert service.document("codex", "7d")["records"] == 1
    assert events == []  # inside the budget: no event
    clock.now += history.FRESH_SECONDS + 1  # memory is older than fresh: a rescan starts
    stale = service.document("codex", "7d")
    assert stale["records"] == 1 and stale["stale"] is True and stale["pending"] is False
    slow.release.set()
    threads.settle()
    assert service.document("codex", "7d")["records"] == 2
    assert events == [history.READY_EVENT]



def test_service_warm_starts_every_scanned_provider_once_and_survives_a_failing_scan__and_2_more() -> None:
    # --- scenario: service_warm_starts_every_scanned_provider_once_and_survives_a_failing_scan
    calls: list[tuple[str, int]] = []
    logged: list[str] = []

    def scan(provider: str, days: int) -> list[tuple]:
        calls.append((provider, days))
        if provider == "claude":
            raise OSError("cache unreadable")
        return []

    threads = _Threads()
    service = _service(scan, log=logged.append, threads=threads)
    service.warm()
    service.warm()  # a second warm while the first runs starts nothing new
    threads.settle()
    assert sorted(calls) == [("claude", 30), ("codex", 30)]
    assert any("claude 30d failed: OSError" in line for line in logged)
    # A failed scan leaves no document: the next request is pending, not wrong.
    assert service.document("claude", "30d", budget=0.0)["pending"] is True
    assert service.document("codex", "30d")["pending"] is False

    # --- scenario: service_rejects_a_bad_range_and_answers_unscanned_providers_empty
    service = _service(lambda provider, days: [])
    with pytest.raises(ValueError):
        service.document("codex", "2d")
    document = service.document("gemini", "7d")
    assert document["records"] == 0 and document["pending"] is False
    assert document["pricing"]["estimated"] is True

    # --- scenario: service_close_starts_nothing_further
    """A daemon on its way down must not begin a forty-second scan, and the
    warm-up must stop waiting the moment it is told to."""
    calls: list[tuple[str, int]] = []
    threads = _Threads()
    service = _service(lambda provider, days: calls.append((provider, days)) or [], threads=threads)
    service.close()
    assert service.stopping.is_set()
    service.warm()
    threads.settle()
    assert calls == [] and threads.threads == []
    assert service.document("codex", "7d", budget=0.0)["pending"] is True

