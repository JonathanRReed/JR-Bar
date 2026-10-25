"""Build the usage graph the ``usage_graph`` command answers.

The chart model used to ride the capacity-refresh acceptance protocol:
built inside the shared refresh worker, delivered only when that batch's
generations all matched, dropped wholesale on a stale generation. The
result was a chart that showed "No activity in this range" for data
that a direct scan finds in seconds -- the acceptance plane exists to
keep capacity READINGS honest, and the local activity chart never
needed it. The scan (incremental, cached) runs on the server's slow lane,
off the main thread, and the reply is one JSON document.
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, fields, is_dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

from . import usage_percent_history, usage_stats
from .provider_facts import SourceKey
from .provider_homes import home_scan_roots, opencode_data_root, scan_usage_all_homes
from .providers import default_state_dir
from .t3_compat import (
    T3_V2_DATABASE_RELATIVE_PATH,
    T3ReadOnlyPolicy,
    _normalize_provider,
    _open_read_only,
    t3_database_path,
)
from .usage_heatmap import build_usage_heatmap

#: Persisted answer cache for the ``usage_graph`` socket command. The
#: build itself is the expensive part (~30-65s cold over a large corpus);
#: the fingerprint that guards a hit is a stat-only walk (~0.4s over
#: 9.9k transcripts). The document is only served when every input --
#: transcript trees, ledger files, auxiliary databases, the selected
#: metric/day-range, today, and the local timezone -- is provably
#: unchanged, so a cached reply is identical to a fresh scan, not an
#: approximation of one.
_USAGE_DOC_CACHE_NAME = "usage-graph-doc-cache.json"
#: How long one ``usage_graph`` request reads transcripts before it answers
#: with what it has (and says it is still reading). The command already runs
#: on the slow lane with a long client timeout; the history service's own
#: short passes finish the corpus in the background.
GRAPH_PASS_SECONDS = 15.0
_USAGE_DOC_CACHE_VERSION = 12
_USAGE_DOC_CACHE_MAX_BYTES = 8 * 1024 * 1024
_USAGE_DOC_CACHE_SLOTS = 12

T3_MAX_ACTIVITY_RECORDS = 10_000
T3_MAX_ACTIVITY_PAYLOAD_BYTES = 64 * 1024
T3_MAX_ACTIVITY_TOTAL_BYTES = 4 * 1024 * 1024
T3_MAX_ACTIVITY_IDENTIFIER_BYTES = 1_024
T3_MAX_ACTIVITY_TIMESTAMP_BYTES = 128
T3_SQLITE_MAX_VALUE_BYTES = 128 * 1024
T3_MAX_ACTIVITY_QUERY_STEPS = 2_000_000
T3_ACTIVITY_QUERY_PROGRESS_INTERVAL = 1_000
T3_ACTIVITY_QUERY_TIMEOUT_SECONDS = 0.5
API_EQUIVALENT_COST_DISCLOSURE = "API-equivalent estimate, not subscription spend"


@dataclass(frozen=True, slots=True)
class _NativeBinding:
    sources: tuple[tuple[SourceKey, str, str], ...]
    fingerprint: tuple[tuple[str, str], ...]
    semantics: tuple
    calendar: tuple
    complete: bool


@dataclass(frozen=True, slots=True)
class _ResolvedNativeSource:
    source_key: SourceKey
    root: str
    rows: tuple[tuple, ...]
    coverage: usage_stats.UsageSourceCoverage


@dataclass(frozen=True, slots=True)
class _NativeSnapshot:
    binding: _NativeBinding
    covered_since_epoch: float
    batches: tuple[_ResolvedNativeSource, ...]
    accounted_bytes: int


@dataclass(frozen=True, slots=True)
class _NativeRejection:
    binding: _NativeBinding
    since_epoch: float


def _native_binding(provider_ids, fingerprint, calendar):
    sources = {
        row.source_key.provider_id: row for row in usage_stats.negotiated_provider_sources()
        if row.source_key.capability_id == "transcript_usage" and row.observation_invocation_allowed
    }
    roots = home_scan_roots([provider for provider in ("claude", "codex") if provider in provider_ids and provider in sources])
    ordered = [(provider, paths[0]) for provider, paths in roots.items() if provider in sources]
    ordered.extend((provider, root) for provider, paths in roots.items() if provider in sources for root in paths[1:])
    identities = tuple((sources[provider].source_key, os.path.realpath(root), repr(sources[provider]))
                       for provider, root in ordered)
    keys = tuple(key for provider, paths in roots.items()
                 for key in (provider, *(f"{provider}:{index}" for index in range(1, len(paths)))))
    witness = tuple((key, json.dumps(fingerprint.get(key), sort_keys=True)) for key in keys)
    complete = all(fingerprint.get(key, {}).get("complete") is True for key in keys)
    return _NativeBinding(identities, witness,
                          (usage_stats.CACHE_VERSION, usage_stats.CODEX_CACHE_SEMANTICS_VERSION,
                           usage_stats.USAGE_FILE_SANITY_BYTES, usage_stats.USAGE_INVENTORY_MAX_FILES),
                          calendar, complete)


class _NativeFieldTooLarge(ValueError):
    pass


def _native_size(value):
    if isinstance(value, (str, bytes)):
        if sys.getsizeof(value) > 128 * 1024:
            raise _NativeFieldTooLarge("native field exceeds reuse bound")
        return sys.getsizeof(value)
    if value is None or isinstance(value, (bool, int, float)):
        return sys.getsizeof(value)
    if isinstance(value, tuple):
        return sys.getsizeof(value) + sum(_native_size(item) for item in value)
    if is_dataclass(value) and value.__dataclass_params__.frozen:
        return sys.getsizeof(value) + sum(_native_size(getattr(value, field.name)) for field in fields(value))
    raise ValueError("native reuse requires immutable values")


class NativeGraphReuse:
    """One bounded controller-owned native input, before window deduplication."""

    def __init__(self, *, maximum_rows=20_000, maximum_bytes=8 * 1024 * 1024):
        self._maximum_rows = min(20_000, max(0, int(maximum_rows)))
        self._maximum_bytes = min(8 * 1024 * 1024, max(0, int(maximum_bytes)))
        self._lock = threading.Lock()
        self._slot = None
        self._rejected_binding = None
        self._generation = 0
        self._closed = False

    def close(self):
        with self._lock:
            self._closed = True
            self._generation += 1
            self._slot = None
            self._rejected_binding = None

    def observe(self, binding):
        with self._lock:
            retained = self._slot.binding if self._slot is not None else (
                self._rejected_binding.binding if self._rejected_binding is not None else None
            )
            if retained is not None and (not binding.complete or retained != binding):
                self._slot = None
                self._rejected_binding = None
                self._generation += 1

    def collect(self, settings, since_epoch, binding):
        with self._lock:
            slot = self._slot
            rejection = self._rejected_binding
            skip_admission = not self._closed and binding.complete and rejection is not None and rejection.binding == binding and rejection.since_epoch == since_epoch
            if not self._closed and binding.complete and slot is not None and slot.binding == binding and since_epoch >= slot.covered_since_epoch:
                batches = slot.batches
            else:
                batches = None
                self._slot = None
                if not skip_admission:
                    self._rejected_binding = None
                self._generation += 1
            generation = self._generation
        slot = None
        if batches is not None:
            return usage_stats._merge_usage_totals(tuple(
                usage_stats.UsageTotals(records=usage_stats._first_sightings(batch.rows, since_epoch),
                                       source_coverage={batch.source_key.provider_id: batch.coverage})
                for batch in batches
            ))
        captured = []
        identities = []
        rows_seen = 0
        read_complete = binding.complete
        cap_rejected = False
        rejected = skip_admission or not binding.complete
        accounted = 0
        metadata_fits = skip_admission
        if not skip_admission:
            try:
                accounted = _native_size(binding)
                metadata_fits = _native_size(_NativeRejection(binding, since_epoch)) <= self._maximum_bytes
            except ValueError:
                metadata_fits = False
            if not metadata_fits:
                rejected = True
        def capture(source_key, root, rows, coverage):
            nonlocal rows_seen, accounted, rejected, read_complete, cap_rejected
            identities.append((source_key, os.path.realpath(root)))
            rows_seen += len(rows)
            if coverage.status not in {
                usage_stats.UsageSourceStatus.OK, usage_stats.UsageSourceStatus.MISSING
            }:
                read_complete = False
            if not rejected and rows_seen > self._maximum_rows:
                cap_rejected = True
                rejected = True
            if rejected or not read_complete:
                rejected = True
                captured.clear()
                return
            batch = _ResolvedNativeSource(source_key, os.path.realpath(root), tuple(rows), coverage)
            try:
                accounted += _native_size(batch)
            except _NativeFieldTooLarge:
                cap_rejected = True
                rejected = True
            except ValueError:
                rejected = True
            if accounted > self._maximum_bytes:
                cap_rejected = True
                rejected = True
            if rejected:
                captured.clear()
            else:
                captured.append(batch)
        try:
            totals = scan_usage_all_homes(
                default_state_dir() / "usage-scan-cache.json", since_epoch=since_epoch,
                provider_ids=settings.usage_graph_providers, budget=usage_stats.ScanBudget(GRAPH_PASS_SECONDS),
                resolved_capture=capture,
            )
        except BaseException:
            with self._lock:
                if generation == self._generation:
                    self._rejected_binding = None
            raise
        expected = tuple((source_key, root) for source_key, root, _contract in binding.sources)
        valid_capture = read_complete and tuple(identities) == expected
        if skip_admission:
            if not valid_capture:
                with self._lock:
                    if generation == self._generation:
                        self._rejected_binding = None
            return totals
        if valid_capture and metadata_fits and (not rejected or cap_rejected):
            post_meta = _usage_doc_cache_meta(settings, None)
            post = _native_binding(settings.usage_graph_providers, _native_corpus_fingerprint(settings),
                                   (post_meta["date"], post_meta["tz"]))
            accounted += sys.getsizeof(tuple(captured)) + sys.getsizeof(_NativeSnapshot)
            if binding == post and post.complete:
                cap_rejected = cap_rejected or accounted > self._maximum_bytes
                candidate = None if cap_rejected else _NativeSnapshot(binding, since_epoch, tuple(captured), accounted)
                with self._lock:
                    if not self._closed and generation == self._generation:
                        self._slot = candidate
                        self._rejected_binding = _NativeRejection(binding, since_epoch) if cap_rejected else None
        return totals


@dataclass(frozen=True, slots=True)
class _UsageGraphSettingsSnapshot:
    usage_graph_days: int
    usage_display_mode: str
    usage_graph_providers: tuple[str, ...]


def _settings_snapshot(settings) -> _UsageGraphSettingsSnapshot:
    if isinstance(settings, _UsageGraphSettingsSnapshot):
        return settings
    return _UsageGraphSettingsSnapshot(
        usage_graph_days=int(getattr(settings, "usage_graph_days", 7) or 7),
        usage_display_mode=str(
            getattr(settings, "usage_display_mode", "tokens") or "tokens"
        ),
        usage_graph_providers=tuple(
            getattr(settings, "usage_graph_providers", ()) or ()
        ),
    )


def _period_start(days: int, *, now: datetime | None = None) -> datetime:
    moment = datetime.now() if now is None else now
    return (moment - timedelta(days=int(days) - 1)).replace(
        hour=0,
        minute=0,
        second=0,
        microsecond=0,
    )



def _scan_opencode_records(db_path: Path, since_epoch: float) -> list[tuple]:
    if not db_path.is_file():
        return []
    records = []
    try:
        con = sqlite3.connect(f"file:{quote(str(db_path), safe='/')}?mode=ro", uri=True)
        cursor = con.execute(
            "SELECT id, session_id, time_created, data FROM message WHERE data LIKE ? AND time_created >= ?",
            ('%"tokens"%', int(since_epoch * 1000.0) if since_epoch < 1e11 else int(since_epoch)),
        )
        for row in cursor:
            mid, sid, tc, data_str = row
            try:
                data = json.loads(data_str)
                tokens = data.get("tokens") or {}
                inp = int(tokens.get("input", 0) or 0)
                out = int(tokens.get("output", 0) or 0)
                cache_data = tokens.get("cache") or {}
                c_read = int(cache_data.get("read", 0) or 0)
                c_write = int(cache_data.get("write", 0) or 0)
                if (inp + out + c_read + c_write) <= 0:
                    continue
                model = data.get("modelID") or data.get("model") or "opencode"
                epoch = tc / 1000.0 if tc > 1e11 else float(tc)
                records.append(("opencode", sid, model, epoch, inp, c_read, c_write, out, f"opencode:{mid}"))
            except Exception:
                pass
        con.close()
    except Exception:
        pass
    return records


def _scan_t3code_records(
    db_path: Path,
    since_epoch: float,
    *,
    maximum_records: int = T3_MAX_ACTIVITY_RECORDS,
    maximum_payload_bytes: int = T3_MAX_ACTIVITY_PAYLOAD_BYTES,
    maximum_total_payload_bytes: int = T3_MAX_ACTIVITY_TOTAL_BYTES,
    maximum_query_steps: int = T3_MAX_ACTIVITY_QUERY_STEPS,
    query_timeout_seconds: float = T3_ACTIVITY_QUERY_TIMEOUT_SECONDS,
    monotonic: Callable[[], float] = time.monotonic,
    coverage_reporter: Callable[[str], None] | None = None,
) -> list[tuple]:
    if not db_path.is_file():
        if coverage_reporter is not None:
            coverage_reporter("missing")
        return []
    records = []
    con = None
    coverage_status = "complete"
    try:
        con = _open_read_only(db_path)
        con.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, T3_SQLITE_MAX_VALUE_BYTES)
        limit = min(T3_MAX_ACTIVITY_RECORDS, max(1, int(maximum_records)))
        payload_limit = min(T3_MAX_ACTIVITY_PAYLOAD_BYTES, max(1, int(maximum_payload_bytes)))
        total_limit = min(T3_MAX_ACTIVITY_TOTAL_BYTES, max(1, int(maximum_total_payload_bytes)))
        query_step_limit = min(
            T3_MAX_ACTIVITY_QUERY_STEPS,
            max(T3_ACTIVITY_QUERY_PROGRESS_INTERVAL, int(maximum_query_steps)),
        )
        deadline = monotonic() + min(
            T3_ACTIVITY_QUERY_TIMEOUT_SECONDS,
            max(0.001, float(query_timeout_seconds)),
        )
        progress_calls = 0

        def query_budget_exhausted() -> int:
            nonlocal progress_calls
            progress_calls += 1
            return int(
                progress_calls * T3_ACTIVITY_QUERY_PROGRESS_INTERVAL > query_step_limit
                or monotonic() >= deadline
            )

        con.set_progress_handler(query_budget_exhausted, T3_ACTIVITY_QUERY_PROGRESS_INTERVAL)
        iso_since = (
            datetime.fromtimestamp(since_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
            if since_epoch > 0
            else ""
        )
        range_clause = " AND created_at >= ?" if since_epoch > 0 else ""
        range_values = (iso_since,) if since_epoch > 0 else ()
        oversized = con.execute(
            "SELECT 1 FROM projection_thread_activities "
            f"WHERE kind = ?{range_clause} AND ("
            "length(CAST(activity_id AS BLOB)) > ? OR "
            "length(CAST(thread_id AS BLOB)) > ? OR "
            "length(CAST(created_at AS BLOB)) > ? OR "
            "length(CAST(payload_json AS BLOB)) > ?) LIMIT 1",
            (
                "task.completed",
                *range_values,
                T3_MAX_ACTIVITY_IDENTIFIER_BYTES,
                T3_MAX_ACTIVITY_IDENTIFIER_BYTES,
                T3_MAX_ACTIVITY_TIMESTAMP_BYTES,
                payload_limit,
            ),
        ).fetchone()
        if oversized is not None:
            coverage_status = "stable_partial"
        if since_epoch > 0:
            cursor = con.execute(
                "SELECT rowid, activity_id, thread_id, created_at "
                "FROM projection_thread_activities "
                "WHERE kind = ? AND created_at >= ? "
                "AND length(CAST(activity_id AS BLOB)) <= ? "
                "AND length(CAST(thread_id AS BLOB)) <= ? "
                "AND length(CAST(created_at AS BLOB)) <= ? "
                "AND length(CAST(payload_json AS BLOB)) <= ? AND payload_json LIKE ? "
                "ORDER BY created_at DESC, activity_id DESC LIMIT ?",
                (
                    "task.completed",
                    iso_since,
                    T3_MAX_ACTIVITY_IDENTIFIER_BYTES,
                    T3_MAX_ACTIVITY_IDENTIFIER_BYTES,
                    T3_MAX_ACTIVITY_TIMESTAMP_BYTES,
                    payload_limit,
                    '%"usage"%',
                    limit + 1,
                ),
            )
        else:
            cursor = con.execute(
                "SELECT rowid, activity_id, thread_id, created_at "
                "FROM projection_thread_activities "
                "WHERE kind = ? "
                "AND length(CAST(activity_id AS BLOB)) <= ? "
                "AND length(CAST(thread_id AS BLOB)) <= ? "
                "AND length(CAST(created_at AS BLOB)) <= ? "
                "AND length(CAST(payload_json AS BLOB)) <= ? AND payload_json LIKE ? "
                "ORDER BY created_at DESC, activity_id DESC LIMIT ?",
                (
                    "task.completed",
                    T3_MAX_ACTIVITY_IDENTIFIER_BYTES,
                    T3_MAX_ACTIVITY_IDENTIFIER_BYTES,
                    T3_MAX_ACTIVITY_TIMESTAMP_BYTES,
                    payload_limit,
                    '%"usage"%',
                    limit + 1,
                ),
            )
        payload_bytes_read = 0
        for index, row in enumerate(cursor):
            if index >= limit:
                coverage_status = "stable_partial"
                break
            rowid, aid, tid, cat = row
            payload_row = con.execute(
                "SELECT payload_json, length(CAST(payload_json AS BLOB)) "
                "FROM projection_thread_activities "
                "WHERE rowid = ? AND length(CAST(payload_json AS BLOB)) <= ?",
                (rowid, payload_limit),
            ).fetchone()
            if payload_row is None:
                coverage_status = "stable_partial"
                continue
            payload_str, payload_bytes = payload_row
            payload_bytes_read += int(payload_bytes or 0)
            if payload_bytes_read > total_limit:
                coverage_status = "stable_partial"
                break
            try:
                data = json.loads(payload_str)
                usage = data.get("usage")
                if not usage or not isinstance(usage, dict):
                    continue
                total = int(usage.get("total_tokens", 0) or 0)
                inp = int(usage.get("input_tokens", 0) or 0)
                out = int(usage.get("output_tokens", 0) or 0)
                if total <= 0 and inp <= 0 and out <= 0:
                    continue
                if inp == 0 and out == 0 and total > 0:
                    inp = total
                dt = datetime.fromisoformat(cat.replace("Z", "+00:00"))
                epoch = dt.timestamp()
                if epoch < since_epoch:
                    continue
                records.append(("other", tid, "", epoch, inp, 0, 0, out, f"t3code:{aid}"))
            except Exception:
                coverage_status = "stable_partial"
    except sqlite3.DataError:
        coverage_status = "partial"
    except sqlite3.OperationalError as error:
        coverage_status = "partial" if "interrupted" in str(error).lower() else "failed"
    except Exception:
        coverage_status = "partial" if records else "failed"
    finally:
        if con is not None:
            con.close()
        if coverage_reporter is not None:
            coverage_reporter(coverage_status)
    return records


def _scan_t3code_v2_records(
    db_path: Path,
    since_epoch: float,
    *,
    maximum_records: int = T3_MAX_ACTIVITY_RECORDS,
    maximum_query_steps: int = T3_MAX_ACTIVITY_QUERY_STEPS,
    query_timeout_seconds: float = T3_ACTIVITY_QUERY_TIMEOUT_SECONDS,
    monotonic: Callable[[], float] = time.monotonic,
    coverage_reporter: Callable[[str], None] | None = None,
) -> list[tuple]:
    """Token use per finished provider turn in a 0.0.46 ``statev2.sqlite``.

    T3 records main-agent usage on each provider turn
    (``turnTokenUsage``); its input count already includes cache reads and
    writes, so the record splits them back out and the four parts still
    add up to what T3 reported. A turn with no counts, or with only an
    unavailable status, adds nothing.
    """
    if not db_path.is_file():
        if coverage_reporter is not None:
            coverage_reporter("missing")
        return []
    records: list[tuple] = []
    con = None
    coverage_status = "complete"
    try:
        con = _open_read_only(db_path)
        con.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, T3_SQLITE_MAX_VALUE_BYTES)
        limit = min(T3_MAX_ACTIVITY_RECORDS, max(1, int(maximum_records)))
        step_limit = min(
            T3_MAX_ACTIVITY_QUERY_STEPS,
            max(T3_ACTIVITY_QUERY_PROGRESS_INTERVAL, int(maximum_query_steps)),
        )
        deadline = monotonic() + min(
            T3_ACTIVITY_QUERY_TIMEOUT_SECONDS, max(0.001, float(query_timeout_seconds))
        )
        progress_calls = 0

        def query_budget_exhausted() -> int:
            nonlocal progress_calls
            progress_calls += 1
            return int(
                progress_calls * T3_ACTIVITY_QUERY_PROGRESS_INTERVAL > step_limit
                or monotonic() >= deadline
            )

        con.set_progress_handler(query_budget_exhausted, T3_ACTIVITY_QUERY_PROGRESS_INTERVAL)
        iso_since = (
            datetime.fromtimestamp(since_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
            if since_epoch > 0
            else ""
        )
        cursor = con.execute(
            "SELECT provider_turn_id, thread_id, completed_at, "
            "json_extract(payload_json, '$.turnTokenUsage.inputTokens'), "
            "json_extract(payload_json, '$.turnTokenUsage.cachedInputTokens'), "
            "json_extract(payload_json, '$.turnTokenUsage.cacheCreationTokens'), "
            "json_extract(payload_json, '$.turnTokenUsage.outputTokens'), "
            "json_extract(payload_json, '$.nativeTurnRef.driver'), "
            "json_extract(payload_json, '$.turnTokenUsage.usageStatus') "
            "FROM orchestration_v2_projection_provider_turns "
            "WHERE completed_at IS NOT NULL AND completed_at >= ? "
            "AND length(CAST(provider_turn_id AS BLOB)) <= ? "
            "AND length(CAST(thread_id AS BLOB)) <= ? "
            "AND json_extract(payload_json, '$.turnTokenUsage') IS NOT NULL "
            "ORDER BY completed_at DESC, provider_turn_id DESC LIMIT ?",
            (
                iso_since,
                T3_MAX_ACTIVITY_IDENTIFIER_BYTES,
                T3_MAX_ACTIVITY_IDENTIFIER_BYTES,
                limit + 1,
            ),
        )

        def count(value: object) -> int:
            return int(value) if type(value) is int and value > 0 else 0

        for index, row in enumerate(cursor):
            if index >= limit:
                coverage_status = "stable_partial"
                break
            turn_id, thread_id, completed_at, total_in, cached, written, out, driver, usage_status = row
            if usage_status == "unavailable":
                continue
            if usage_status == "partial":
                coverage_status = "stable_partial"
            total_in, cached, written, out = (
                count(total_in), count(cached), count(written), count(out)
            )
            if total_in + out <= 0:
                continue
            cached = min(cached, total_in)
            written = min(written, total_in - cached)
            try:
                epoch = datetime.fromisoformat(
                    str(completed_at).replace("Z", "+00:00")
                ).timestamp()
            except ValueError:
                coverage_status = "stable_partial"
                continue
            if epoch < since_epoch:
                continue
            records.append(
                (
                    _normalize_provider(driver), str(thread_id), "", epoch,
                    total_in - cached - written, cached, written, out,
                    f"t3code:turn:{turn_id}",
                )
            )
    except sqlite3.DataError:
        coverage_status = "partial"
    except sqlite3.OperationalError as error:
        coverage_status = "partial" if "interrupted" in str(error).lower() else "failed"
    except Exception:
        coverage_status = "partial" if records else "failed"
    finally:
        if con is not None:
            con.close()
        if coverage_reporter is not None:
            coverage_reporter(coverage_status)
    return records


def _select_t3_source_records(records, native_records, provider_ids, coverage_status):
    """Keep source counts separate and prefer each provider's native history."""
    observed_providers = sorted({row[0] for row in records if row[0] not in {"other", "t3code"}})
    native_providers = {row[0] for row in native_records}
    included = [
        row for row in records
        if row[0] in provider_ids and row[0] in observed_providers
        and row[0] not in native_providers
    ]
    has_unknown = any(row[0] in {"other", "t3code"} for row in records)
    attribution = "mixed" if has_unknown and observed_providers else (
        "attributed" if observed_providers else "unattributed"
    )
    source = {
        "source_id": "t3code", "label": "T3 Code", "attribution_status": attribution,
        "tokens": sum(sum(row[4:8]) for row in records) if records else None,
        "sessions": len({row[1] for row in records}) if records else None,
        "included_tokens": sum(sum(row[4:8]) for row in included),
        "included_sessions": len({row[1] for row in included}),
        "data_status": (
            "available" if records and coverage_status == "complete"
            else "partial" if records or coverage_status in {"stable_partial", "partial", "failed"} else "unavailable"
        ),
        "provider_ids": observed_providers,
        "detail": (
            "Observed completed-turn counts from T3 Code. Native provider history takes precedence. "
            "Sessions count distinct T3 threads with token readings. "
            "Unattributed counts stay separate; historical resolved models and account quota are unavailable."
            if records else (
                "T3 Code read failed; retrying. No usable completed-turn token reading. Account quota is unavailable."
                if coverage_status == "failed"
                else "No usable completed-turn token reading from T3 Code. Account quota is unavailable."
            )
        ),
    }
    return included, source


def _t3_coverage_status(statuses):
    # A later stable omission cannot erase a failed or interrupted read.
    for status in ("failed", "partial", "stable_partial"):
        if status in statuses:
            return status
    return statuses[-1] if statuses else "missing"


def scan_t3_activity_statistics(
    policy: T3ReadOnlyPolicy,
    since_epoch: float,
    *,
    path_resolver: Callable[[Path | str | None], Path] = t3_database_path,
    scanner: Callable[[Path, float], list[tuple]] | None = None,
    coverage_reporter: Callable[[str], None] | None = None,
) -> list[tuple]:
    """Read optional T3 activity only after both admission checks pass."""
    if not policy.may_scan_activity_statistics:
        return []
    database = path_resolver(policy.base_dir)
    if scanner is not None:
        records = scanner(database, since_epoch)
        if coverage_reporter is not None:
            coverage_reporter("complete")
        return records
    if database.name == T3_V2_DATABASE_RELATIVE_PATH.name:
        return _scan_t3code_v2_records(
            database,
            since_epoch,
            coverage_reporter=coverage_reporter,
        )
    return _scan_t3code_records(
        database,
        since_epoch,
        coverage_reporter=coverage_reporter,
    )


def _scan_antigravity_records(gemini_dir: Path, since_epoch: float) -> list[tuple]:
    summaries_db = gemini_dir / "antigravity-cli" / "conversation_summaries.db"
    if not summaries_db.is_file():
        return []
    records = []
    try:
        con = sqlite3.connect(f"file:{quote(str(summaries_db), safe='/')}?mode=ro", uri=True)
        if since_epoch > 0:
            iso_since = datetime.fromtimestamp(since_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
            cursor = con.execute(
                "SELECT conversation_id, step_count, last_modified_time FROM conversation_summaries WHERE last_modified_time >= ?",
                (iso_since,),
            )
        else:
            cursor = con.execute(
                "SELECT conversation_id, step_count, last_modified_time FROM conversation_summaries"
            )
        for row in cursor:
            cid, steps, lmt = row
            try:
                if not steps or steps <= 0:
                    continue
                dt = datetime.fromisoformat(lmt)
                epoch = dt.timestamp()
                if epoch < since_epoch:
                    continue
                # A step count proves activity, not tokens or API-equivalent
                # spend. These rows are used only for session-day counts.
                records.append(("antigravity", cid, "gemini", epoch, 0, 0, 0, 0, f"antigravity:{cid}"))
            except Exception:
                pass
        con.close()
    except Exception:
        pass
    return records

def _build_payload(
    settings,
    *,
    t3_policy: T3ReadOnlyPolicy | None = None,
    native_reuse: NativeGraphReuse | None = None,
    native_binding: _NativeBinding | None = None,
) -> tuple[dict, str | None]:
    """(chart model, scan summary line) for the CURRENT metric."""
    settings = _settings_snapshot(settings)
    days = settings.usage_graph_days
    mode = settings.usage_display_mode
    provider_ids = tuple(provider for provider in settings.usage_graph_providers if provider != "t3code")
    period_start = _period_start(days)
    # Every Claude and Codex home (CLAUDE_CONFIG_DIR, CODEX_HOME and
    # provider_extra_homes), each real folder once (provider_homes).
    totals = native_reuse.collect(settings, period_start.timestamp(), native_binding) if native_reuse is not None and native_binding is not None else scan_usage_all_homes(
        default_state_dir() / "usage-scan-cache.json",
        aggregate=True,
        since_epoch=period_start.timestamp(), provider_ids=provider_ids,
        budget=usage_stats.ScanBudget(GRAPH_PASS_SECONDS),
    )
    opencode_records = (
        _scan_opencode_records(
            opencode_data_root() / "opencode.db",
            period_start.timestamp(),
        )
        if "opencode" in provider_ids
        else []
    )
    t3_coverage: list[str] = []
    t3code_records = (
        scan_t3_activity_statistics(
            t3_policy,
            period_start.timestamp(),
            coverage_reporter=t3_coverage.append,
        )
        if t3_policy is not None and t3_policy.may_scan_activity_statistics
        else []
    )
    totals.records.extend(opencode_records)
    # Pi, Grok, Gemini CLI and OpenClaw keep their own session files; each
    # record is that agent's own and never adds to Claude or Codex.
    from .local_token_history import LOCAL_HISTORY_PROVIDERS, scan_local_records

    if native_reuse is not None:
        totals.records.extend(scan_local_records(
            [provider for provider in provider_ids if provider in LOCAL_HISTORY_PROVIDERS],
            period_start.timestamp(),
        ))

    source_statistics = []
    t3_included = []
    t3_status = _t3_coverage_status(t3_coverage)
    if t3_policy is not None and t3_policy.may_scan_activity_statistics:
        t3_included, source = _select_t3_source_records(
            t3code_records, totals.records, provider_ids, t3_status
        )
        totals.records.extend(t3_included)
        source_statistics.append(source)
    records = [record for record in totals.records if record[0] in provider_ids]

    extra_sessions: dict[str, dict[str, int]] | None = None
    ledger_first_day: dict[str, str] | None = None
    if mode == "sessions":
        # Hook ledgers can supply daily session counts without token records.
        from .session_history import (
            TRANSCRIPT_SESSION_PROVIDERS,
            ledger_first_event_epochs,
            ledger_session_days,
            shared_ledger_reads,
        )

        # Both answers below read the same hook ledgers (each up to 8 MiB):
        # read and parse each once for the pair.
        with shared_ledger_reads():
            try:
                # default_state_dir() IS the ledger directory; a doubled
                # path once looked one level too deep and
                # silently emptied the Sessions graph for every hook-ledger
                # provider (2026-08-27 readiness audit).
                extra_sessions = ledger_session_days(
                    default_state_dir(),
                    since_epoch=period_start.timestamp(),
                    provider_ids=provider_ids,
                )
            except Exception:
                extra_sessions = {}
            # A provider counted only from its hook log is known only from where
            # that log now begins: it is trimmed to its newest events. Days
            # before that are unknown, not zero, so the graph draws them as gaps.
            # Providers with their own history (transcripts, local session files,
            # OpenCode, T3 Code, Antigravity) are not judged by their hook log.
            ledger_only = tuple(
                provider
                for provider in provider_ids
                if provider not in TRANSCRIPT_SESSION_PROVIDERS
                and provider not in LOCAL_HISTORY_PROVIDERS
                and provider not in {"opencode", "t3code", "antigravity"}
            )
            try:
                # Its own try: a failure here must never cost the counts above.
                first_events = ledger_first_event_epochs(
                    default_state_dir(),
                    provider_ids=ledger_only,
                )
                ledger_first_day = {
                    provider: datetime.fromtimestamp(epoch).strftime("%Y-%m-%d")
                    for provider, epoch in first_events.items()
                    if epoch > period_start.timestamp()
                }
            except Exception:
                ledger_first_day = None
        if "antigravity" in provider_ids:
            activity_days: dict[str, set[str]] = {}
            for record in _scan_antigravity_records(Path.home() / ".gemini", period_start.timestamp()):
                day = datetime.fromtimestamp(record[3]).date().isoformat()
                activity_days.setdefault(day, set()).add(record[1])
            counts = extra_sessions.setdefault("antigravity", {})
            for day, sessions in activity_days.items():
                counts[day] = max(counts.get(day, 0), len(sessions))
    #: Tokens, per model name, that the cost graph could not price. Only the
    #: cost graph draws dollars, so only it says what they leave out.
    unpriced: dict[str, int] | None = {} if mode == "cost" else None
    cost_coverage: dict | None = {} if mode == "cost" else None
    if mode == "percent":
        model = usage_percent_history.shared_percent_graph_model(
            days=days,
            period_label=usage_stats.usage_period_label(days),
        )
        model = {
            **model,
            "series": tuple(series for series in model["series"] if series["provider_id"] in provider_ids),
            "heatmap": build_usage_heatmap(records, days=days, provider_ids=provider_ids),
        }
    else:
        model = usage_stats.usage_graph_model(
            records,
            days=days,
            metric=mode,
            provider_ids=provider_ids,
            extra_sessions=extra_sessions,
            ledger_first_day=ledger_first_day,
            unpriced=unpriced,
            cost_coverage=cost_coverage,
        )
    heatmap = model["heatmap"]
    if mode == "cost":
        model = {**model, "cost_semantics": "api_equivalent_estimate", "cost_coverage": cost_coverage}
    failed_source_ids = {
        provider
        for provider, coverage in totals.source_coverage.items()
        if coverage.status == usage_stats.UsageSourceStatus.FAILED or coverage.unreadable_files
        or (coverage.root_present and not coverage.root_walked)
    }
    supplemented_providers = {record[0] for record in t3_included}
    partial_provider_ids = tuple(
        provider_id
        for provider_id in provider_ids
        if provider_id in failed_source_ids
        or (provider_id in supplemented_providers and t3_status != "complete")
    )
    #: Transcripts this pass ran out of time before finishing; the next ask
    #: carries on from where each stopped.
    reading_files = sum(
        coverage.pending_files
        for provider, coverage in totals.source_coverage.items()
        if provider in provider_ids
    )
    model = {
        **model, "partial_provider_ids": partial_provider_ids, "reading_files": reading_files,
        "source_statistics": source_statistics,
        "_cache_retry_required": t3_status in {"partial", "failed"} or any(
            coverage.status in {usage_stats.UsageSourceStatus.PARTIAL, usage_stats.UsageSourceStatus.FAILED}
            for provider, coverage in totals.source_coverage.items() if provider in provider_ids
        ),
        "series": tuple(
            {**series, "source_id": "t3code"}
            if mode != "percent" and series["provider_id"] in supplemented_providers else series
            for series in model["series"]
        ),
    }
    from .provider_usage_platform import provider_descriptors

    labels = {descriptor.provider_id: descriptor.label for descriptor in provider_descriptors()}
    labels["pi"] = "Pi"
    labels["openclaw"] = "OpenClaw"
    if mode == "sessions":
        parts = [
            f"{labels.get(series['provider_id'], series['provider_id'])} "
            f"{int(sum(value for value in series['values'] if value > 0))} session-days"
            for series in model["series"]
        ]
        detail = " · ".join(parts) or "No recorded sessions"
    elif mode == "percent":
        detail = "Remaining quota for " + ", ".join(labels.get(provider, provider) for provider in provider_ids)
    elif mode == "cost":
        parts = []
        for series in model["series"]:
            label = labels.get(series["provider_id"], series["provider_id"])
            if series.get("has_priced_usage") is False:
                parts.append(f"{label} Unpriced")
            else:
                subtotal = sum(value for value in series["values"] if value >= 0)
                parts.append(f"{label} estimated ${subtotal:.2f}")
        detail = (" · ".join(parts) or "No recorded usage") + f" · {heatmap.aggregate.totals.sessions} sessions"
    else:
        parts = [
            f"{labels.get(provider, provider)} {usage_stats.compact_token_count(value.totals.tokens)}"
            for provider, value in heatmap.providers.items() if value.totals.tokens > 0
        ]
        detail = (" · ".join(parts) or "No recorded tokens") + f" · {heatmap.aggregate.totals.sessions} sessions"
    summary = f"{usage_stats.usage_period_label(days)}: {detail}"
    partial = [
        labels.get(provider, provider)
        for provider, coverage in totals.source_coverage.items()
        if provider in provider_ids
        and coverage.status != usage_stats.UsageSourceStatus.OK
        and not _only_still_reading(coverage)
    ]
    partial.extend(
        labels.get(provider, provider)
        for provider in partial_provider_ids
        if labels.get(provider, provider) not in partial
    )
    if partial:
        summary += " · Partial local history: " + ", ".join(partial)
    for source in source_statistics:
        if source["tokens"] is not None:
            summary += f" · T3 Code source: {usage_stats.compact_token_count(source['tokens'])} observed tokens"
        if source["data_status"] != "available":
            summary += " · T3 Code source " + source["data_status"]
    if reading_files:
        summary += f" · Still reading {reading_files} {'file' if reading_files == 1 else 'files'}"
    if mode == "cost":
        if unpriced:
            summary += f" · {_unpriced_note(unpriced)}"
        summary += f" · {API_EQUIVALENT_COST_DISCLOSURE}"
    return model, summary


def _only_still_reading(coverage) -> bool:
    """Is unread work the only reason this source is not complete?"""
    return (
        coverage.status == usage_stats.UsageSourceStatus.PARTIAL
        and coverage.pending_files > 0
        and not (
            coverage.malformed_lines
            or coverage.unreadable_files
            or coverage.oversized_files
            or coverage.truncated_files
        )
    )


def _unpriced_note(unpriced: dict[str, int]) -> str:
    """"No price for a, b and 2 more": the models whose cost the graph leaves out.

    Their tokens are counted everywhere else; only the dollars are missing,
    and a missing price is never drawn as $0. Names come from files on this
    Mac, so each is cut short and stripped of anything unprintable.
    """
    ranked = sorted(unpriced.items(), key=lambda item: (-item[1], item[0]))
    names = [
        "".join(char for char in name if char.isprintable())[:40] or "unnamed model"
        for name, _tokens in ranked
    ]
    shown = names[:3]
    note = "No price for " + ", ".join(shown)
    if len(names) > len(shown):
        note += f" and {len(names) - len(shown)} more"
    note += " (tokens counted, cost left out)"
    if "t3code" in unpriced:
        note += ". T3 Code's saved usage has no per-turn model, so its cost is unpriced."
    return note


_VALID_DOCUMENT_DAYS = (7, 30, 90, 365)
_VALID_DOCUMENT_METRICS = ("tokens", "cost", "sessions", "percent")


def _file_fingerprint(path: Path) -> dict:
    """One regular file's identity for change detection, or ``missing``."""
    try:
        info = path.lstat()
    except OSError:
        return {"missing": True}
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        return {"missing": True}
    return {
        "bytes": info.st_size,
        "mtime_ns": info.st_mtime_ns,
        "ino": info.st_ino,
    }


def _tree_fingerprint(root: Path, suffix: str = ".jsonl") -> dict:
    """Stat-only fingerprint of every ``suffix`` file under ``root``.

    Each regular, non-symlinked file contributes its path and stat identity,
    so a same-size edit to an older file cannot hide under another file's mtime.
    """
    files = 0
    total_bytes = 0
    newest_ns = 0
    inode_xor = 0
    digest = hashlib.sha256()
    try:
        root_info = root.lstat()
    except FileNotFoundError:
        return {"missing": True, "complete": True}
    except OSError:
        return {"missing": True, "complete": False}
    if not stat.S_ISDIR(root_info.st_mode) or stat.S_ISLNK(root_info.st_mode):
        return {"missing": True, "complete": False}
    errors = []
    try:
        walker = os.walk(root, followlinks=False, onerror=errors.append)
        for directory, dirnames, filenames in walker:
            dirnames.sort()
            base = Path(directory)
            for name in sorted(filenames):
                if not name.endswith(suffix):
                    continue
                try:
                    info = (base / name).lstat()
                except OSError:
                    errors.append("stat_failed")
                    continue
                if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                    continue
                files += 1
                total_bytes += info.st_size
                newest_ns = max(newest_ns, info.st_mtime_ns)
                inode_xor ^= info.st_ino
                identity = (
                    str((base / name).relative_to(root)), info.st_ino, info.st_size,
                    info.st_mtime_ns, info.st_ctime_ns, info.st_mode,
                )
                digest.update(json.dumps(identity, separators=(",", ":")).encode("utf-8"))
                digest.update(b"\n")
    except OSError:
        return {"missing": True, "complete": False}
    return {"files": files, "bytes": total_bytes, "newest_ns": newest_ns,
            "inos": inode_xor, "stat_digest": digest.hexdigest(), "complete": not errors,
            "root_stat": [root_info.st_dev, root_info.st_ino, root_info.st_mode,
                          root_info.st_mtime_ns, root_info.st_ctime_ns]}


def _native_corpus_fingerprint(snapshot):
    fingerprint = {}
    admitted = {
        row.source_key.provider_id for row in usage_stats.negotiated_provider_sources()
        if row.source_key.capability_id == "transcript_usage" and row.observation_invocation_allowed
    }
    for provider_id, roots in home_scan_roots(
        [name for name in ("claude", "codex") if name in snapshot.usage_graph_providers and name in admitted]
    ).items():
        fingerprint[provider_id] = _tree_fingerprint(roots[0])
        for index, root in enumerate(roots[1:], start=1):
            fingerprint[f"{provider_id}:{index}"] = {"root": str(root), **_tree_fingerprint(root)}
    return fingerprint


def _local_history_fingerprint(provider_id: str, root: Path) -> dict:
    """What ``local_token_history`` reads for one agent, as stat tuples.

    Gemini CLI keeps its chats as ``.json``, not ``.jsonl``. OpenClaw's main
    store is one SQLite database per agent, where a new event can land in
    the write-ahead log without touching the database file itself.
    """
    if provider_id == "gemini":
        return _tree_fingerprint(root, suffix=".json")
    fingerprint = _tree_fingerprint(root)
    if provider_id == "openclaw":
        agents = root / "agents"
        try:
            databases = sorted(agents.glob("*/agent/openclaw-agent.sqlite"))[:64] if agents.is_dir() else []
        except OSError:
            databases = []
        fingerprint["databases"] = {
            str(database.relative_to(root)): {
                "db": _file_fingerprint(database),
                "wal": _file_fingerprint(database.with_name(database.name + "-wal")),
            }
            for database in databases
        }
    return fingerprint


def _corpus_fingerprint(
    snapshot: _UsageGraphSettingsSnapshot,
    *,
    t3_policy: T3ReadOnlyPolicy | None,
) -> dict:
    """Every input ``_build_payload`` can read, reduced to stat tuples."""
    providers = set(snapshot.usage_graph_providers)
    fingerprint: dict[str, object] = _native_corpus_fingerprint(snapshot)
    if "opencode" in providers:
        fingerprint["opencode"] = _file_fingerprint(opencode_data_root() / "opencode.db")
    if t3_policy is not None and t3_policy.may_scan_activity_statistics:
        database = t3_database_path(t3_policy.base_dir)
        fingerprint["t3"] = {
            "database": _file_fingerprint(database),
            "wal": _file_fingerprint(database.with_name(database.name + "-wal")),
        }
    from .local_token_history import roots as local_history_roots

    for provider_id, root in local_history_roots().items():
        if provider_id in providers:
            fingerprint[f"local:{provider_id}"] = _local_history_fingerprint(provider_id, root)
    if snapshot.usage_display_mode == "sessions":
        from .session_history import TRANSCRIPT_SESSION_PROVIDERS

        state_dir = default_state_dir()
        fingerprint["ledgers"] = {
            provider_id: _file_fingerprint(state_dir / f"{provider_id}.jsonl")
            for provider_id in sorted(providers - TRANSCRIPT_SESSION_PROVIDERS)
        }
        if "antigravity" in providers:
            fingerprint["gemini"] = _tree_fingerprint(Path.home() / ".gemini")
    if snapshot.usage_display_mode == "percent":
        fingerprint["percent"] = _file_fingerprint(
            usage_percent_history.default_percent_history_path()
        )
    return fingerprint


def _usage_doc_cache_path() -> Path:
    return default_state_dir() / _USAGE_DOC_CACHE_NAME


def _usage_doc_cache_meta(
    snapshot: _UsageGraphSettingsSnapshot,
    t3_policy: T3ReadOnlyPolicy | None,
) -> dict:
    """The non-corpus key: what the request resolved to, plus the day and
    timezone the day-buckets were cut in. A midnight rollover or a tz
    change must rebuild even on an untouched corpus."""
    return {
        "v": _USAGE_DOC_CACHE_VERSION,
        "days": snapshot.usage_graph_days,
        "metric": snapshot.usage_display_mode,
        "providers": sorted(snapshot.usage_graph_providers),
        "t3": [str(part) for part in _build_key(snapshot, t3_policy)[3]],
        "date": date.today().isoformat(),
        "tz": str(datetime.now().astimezone().tzinfo),
    }


def _usage_doc_cache_read() -> dict:
    path = _usage_doc_cache_path()
    try:
        if not path.is_file() or path.stat().st_size > _USAGE_DOC_CACHE_MAX_BYTES:
            return {}
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(document, dict) or not isinstance(document.get("entries"), dict):
        return {}
    return document


def _usage_doc_cache_write(entries: dict) -> None:
    from .private_io import atomic_private_write

    payload = json.dumps(
        {"v": _USAGE_DOC_CACHE_VERSION, "entries": entries},
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    )
    try:
        atomic_private_write(_usage_doc_cache_path(), payload)
    except OSError:
        pass


#: Agents with a local token history but no provider card (and so no
#: place in the stored provider set): charted when their files exist.
AGENT_HISTORY_PROVIDERS = ("pi", "openclaw")


def _agent_histories_found() -> tuple[str, ...]:
    from .local_token_history import roots as local_history_roots

    found = local_history_roots()
    return tuple(
        provider_id
        for provider_id in AGENT_HISTORY_PROVIDERS
        if found.get(provider_id) is not None and found[provider_id].is_dir()
    )


def usage_graph_document(
    settings,
    *,
    days=None,
    metric=None,
    provider_ids=None,
    t3_policy: T3ReadOnlyPolicy | None = None,
    native_reuse: NativeGraphReuse | None = None,
) -> dict:
    """The ``usage_graph`` command's reply: ``{"graph": model, "summary": "..."}``.

    days/metric/provider_ids are per-request overrides -- a pane asking
    for 30 days does not rewrite the stored settings. The chart model's
    heatmap is a frozen dataclass the socket cannot carry, so it is
    projected to plain JSON here, next to the builder that owns its
    shape. Invalid overrides raise ValueError; the command layer maps
    that to invalid_args rather than silently substituting a range the
    caller did not ask for.
    """
    if not getattr(settings, "token_history_enabled", True):
        raise ValueError("Token history is off.")
    snapshot = _settings_snapshot(settings)
    # Wrong-TYPED overrides are invalid too: a string "30" or a
    # non-list providers must not silently substitute the stored
    # settings -- that is the same lie an invalid value would be.
    resolved_days = snapshot.usage_graph_days
    if days is not None:
        if isinstance(days, bool) or not isinstance(days, (int, float)):
            raise ValueError("days is one of 7, 30, 90, 365")
        if isinstance(days, float) and not days.is_integer():
            raise ValueError("days is one of 7, 30, 90, 365")
        resolved_days = int(days)
    if resolved_days not in _VALID_DOCUMENT_DAYS:
        raise ValueError("days is one of 7, 30, 90, 365")
    if metric is not None and not isinstance(metric, str):
        raise ValueError("metric is tokens, cost, sessions, or percent")
    resolved_metric = (
        metric if isinstance(metric, str) else snapshot.usage_display_mode
    )
    if resolved_metric not in _VALID_DOCUMENT_METRICS:
        raise ValueError("metric is tokens, cost, sessions, or percent")
    if provider_ids is not None and not isinstance(provider_ids, (list, tuple)):
        raise ValueError("providers must be a nonempty tuple")
    resolved_providers = (
        provider_ids
        if provider_ids is not None
        else snapshot.usage_graph_providers
    )
    if any(not isinstance(provider_id, str) for provider_id in resolved_providers):
        raise ValueError("providers must be a nonempty tuple")
    resolved_providers = tuple(
        provider_id for provider_id in resolved_providers if provider_id
    )
    if not resolved_providers:
        raise ValueError("providers must be a nonempty tuple")
    if provider_ids is None and resolved_metric != "percent":
        # Pi and OpenClaw have no provider card, so the registry the
        # picker lists never names them. When their session folders are
        # on this Mac the default chart includes them; the reply then
        # names them, the picker offers them, and a click takes them out.
        resolved_providers = (
            *resolved_providers,
            *(
                provider_id
                for provider_id in _agent_histories_found()
                if provider_id not in resolved_providers
            ),
        )
    resolved_snapshot = _UsageGraphSettingsSnapshot(
        usage_graph_days=resolved_days,
        usage_display_mode=resolved_metric,
        usage_graph_providers=resolved_providers,
    )
    meta = _usage_doc_cache_meta(resolved_snapshot, t3_policy)
    meta_key = json.dumps(meta, sort_keys=True, separators=(",", ":"))
    fingerprint = _corpus_fingerprint(resolved_snapshot, t3_policy=t3_policy)
    complete_native_witness = all(
        value.get("complete") is True for key, value in fingerprint.items()
        if key.partition(":")[0] in {"claude", "codex"}
    )
    native = _native_binding(resolved_providers, fingerprint, (meta["date"], meta["tz"])) if native_reuse is not None else None
    if native is not None:
        native_reuse.observe(native)
        meta["native_admission"] = repr(native.sources)
        meta_key = json.dumps(meta, sort_keys=True, separators=(",", ":"))
    cache = _usage_doc_cache_read()
    entry = (cache.get("entries") or {}).get(meta_key)
    if (
        isinstance(entry, dict)
        and entry.get("fingerprint") == fingerprint
        and isinstance(entry.get("document"), dict)
        and complete_native_witness
        and (native is None or native.complete)
    ):
        return entry["document"]
    options = {"native_reuse": native_reuse, "native_binding": native} if native_reuse is not None else {}
    model, summary = _build_payload(resolved_snapshot, t3_policy=t3_policy, **options)
    document = _project_graph_document(model, summary, resolved_providers)
    # Unfinished and failed reads must be retried even when file stats stay unchanged.
    partial_sources = any(
        source.get("data_status") == "partial" for source in model.get("source_statistics", ())
    )
    retry_required = model.get("_cache_retry_required", bool(model.get("partial_provider_ids") or partial_sources))
    if not model.get("reading_files") and not retry_required and complete_native_witness and (native is None or native.complete):
        _usage_doc_cache_store(meta_key, fingerprint, document)
    return document


def _project_graph_document(model, summary, resolved_providers) -> dict:
    """The JSON-safe socket document for one built model.

    Shared by the command reply and the refresh worker's cache write --
    both must emit the identical shape for identical inputs.
    """
    model = dict(model)
    model.pop("_cache_retry_required", None)
    # Echo the resolved request: series omits providers that had no
    # samples, so without this a picker could not tell "unchecked"
    # from "checked but empty".
    model["providers"] = [provider for provider in resolved_providers if provider != "t3code"]
    # Tuples ride json.dumps fine, but the document should be JSON
    # shape before it ever meets the encoder.
    model["labels"] = list(model.get("labels") or ())
    model["partial_provider_ids"] = list(model.get("partial_provider_ids") or ())
    model["series"] = [
        {**series, "values": list(series.get("values") or ())}
        if isinstance(series, dict) else series
        for series in model.get("series") or ()
    ]
    heatmap = model.get("heatmap")
    if heatmap is not None:
        model["heatmap"] = _heatmap_document(heatmap)
    return {"graph": model, "summary": summary or ""}


def _usage_doc_cache_store(
    meta_key: str,
    fingerprint: dict,
    document: dict,
) -> None:
    """Insert one document under its meta key, LRU-trimmed."""
    cache = _usage_doc_cache_read()
    entries = dict(cache.get("entries") or {})
    entries[meta_key] = {
        "fingerprint": fingerprint,
        "document": document,
        "stored_at": time.time(),
    }
    # A full set is days*metrics*provider mixes; bounded regardless.
    if len(entries) > _USAGE_DOC_CACHE_SLOTS:
        entries = dict(
            sorted(entries.items(), key=lambda item: -(item[1].get("stored_at") or 0))[
                :_USAGE_DOC_CACHE_SLOTS
            ]
        )
    try:
        _usage_doc_cache_write(entries)
    except (TypeError, ValueError):
        pass


def _heatmap_document(heatmap) -> dict:
    """``UsageHeatmap`` -> the JSON-safe dict the socket can carry."""

    def cell_document(cell) -> dict:
        return {
            "day": cell.day.isoformat(),
            "tokens": cell.tokens,
            "sessions": cell.sessions,
            "intensity": cell.intensity,
            "color": cell.color,
            "accessibility_label": cell.accessibility_label,
        }

    def provider_document(provider) -> dict:
        return {
            "provider_id": provider.provider_id,
            "cells": [cell_document(cell) for cell in provider.cells],
            "totals": {
                "tokens": provider.totals.tokens,
                "sessions": provider.totals.sessions,
            },
            "data_status": provider.data_status,
        }

    return {
        "days": [day.isoformat() for day in heatmap.days],
        "providers": {
            provider_id: provider_document(provider)
            for provider_id, provider in heatmap.providers.items()
        },
        "aggregate": provider_document(heatmap.aggregate),
        "timezone": heatmap.timezone,
    }


def _build_key(
    settings,
    t3_policy: T3ReadOnlyPolicy | None = None,
) -> tuple:
    settings = _settings_snapshot(settings)
    t3_key = (
        False,
        False,
        None,
    )
    if t3_policy is not None:
        t3_key = (
            t3_policy.enabled,
            t3_policy.may_scan_activity_statistics,
            t3_policy.base_dir,
        )
    return (
        settings.usage_graph_days,
        settings.usage_display_mode,
        settings.usage_graph_providers,
        t3_key,
    )


def _drop_to_utility_qos() -> None:
    """The scan parses six figures of JSONL lines -- pure GIL time. At
    default QoS that thread competes with the main thread head-on and
    the whole app reads as laggy while the chart loads. Utility is the
    documented QoS class for continuous, user-visible-but-not-blocking
    work. Best effort."""
    try:
        import ctypes

        QOS_CLASS_UTILITY = 0x11
        ctypes.CDLL(None).pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
    except Exception:
        pass


__all__ = [
    "scan_t3_activity_statistics",
    "usage_graph_document",
]
