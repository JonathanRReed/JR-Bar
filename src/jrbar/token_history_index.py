"""Private incremental token history. No message text is retained.

Parsers remain in usage_stats. SQLite owns deduplication and additive buckets;
Python retains at most one bounded parse pass and one compact range view.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import sys
import threading
import time
from collections import OrderedDict
from dataclasses import replace
from datetime import datetime
from pathlib import Path

from . import local_token_history as local
from . import usage_stats as usage
from .private_io import ensure_private_file

SCHEMA_VERSION = 4
RETENTION_SECONDS = 368 * 86400
MAX_DATABASE_BYTES = 4 * 1024**3
VIEW_BYTES = 4 * 1024 * 1024


class BucketRecord(tuple):
    """A session/model/hour subtotal with the original request count."""

    def __new__(cls, values, count=1, long_context=False, positive_count=None):
        row = super().__new__(cls, values)
        row.record_count = count
        row.long_context = long_context
        row.positive_count = count if positive_count is None else positive_count
        return row


def _digest(value):
    return hashlib.blake2b(value.encode(), digest_size=16).digest()


def semantics():
    return (
        SCHEMA_VERSION,
        usage.CACHE_VERSION,
        usage.CODEX_CACHE_SEMANTICS_VERSION,
        usage._MALFORMED_SEMANTICS,
        local.PARSER_VERSION,
    )


class _CancelableBudget:
    def __init__(self, index, budget):
        self.index = index
        self.budget = budget

    def expired(self):
        return (
            self.index.stopping.is_set()
            or not self.index.enabled
            or (self.budget is not None and self.budget.expired())
        )


def _inventory(provider, root):
    if provider not in local.LOCAL_HISTORY_PROVIDERS:
        return usage._provider_inventory(provider, root)
    suffixes = (".json",) if provider == "gemini" else (".jsonl", ".sqlite") if provider == "openclaw" else (".jsonl",)
    sources = [
        usage._provider_inventory(
            provider,
            root,
            suffix=suffix,
            max_files=local.MAX_FILES,
            max_file_bytes=local.MAX_FILE_BYTES if suffix == ".json" else local.MAX_STREAMED_FILE_BYTES,
        ).sources[0]
        for suffix in suffixes
    ]
    candidates = tuple(
        candidate
        for source in sources
        for candidate in source.candidates
        if (provider != "grok" or candidate.path.name == "updates.jsonl")
        and (provider != "gemini" or candidate.path.parent.name == "chats")
        and (
            candidate.path.suffix != ".sqlite"
            or (
                candidate.path.name == "openclaw-agent.sqlite"
                and candidate.path.parent.name == "agent"
                and candidate.path.parent.parent.parent.name == "agents"
            )
        )
    )
    # OpenClaw's database copy wins over migrated JSONL, as in its adapter.
    candidates = tuple(sorted(candidates, key=lambda c: (c.path.suffix != ".sqlite", str(c.path))))
    coverage = usage._merge_usage_totals(
        tuple(usage.UsageTotals(source_coverage={provider: s.coverage}) for s in sources)
    ).source_coverage[provider]
    return usage.LocalUsageInventory(
        (
            replace(
                sources[0],
                candidates=candidates,
                coverage=coverage,
                walk_complete=all(s.walk_complete for s in sources),
            ),
        )
    )


def _sidecar_stamp(path):
    if path.suffix != ".sqlite":
        return None
    try:
        info = Path(str(path) + "-wal").lstat()
        return [info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
    except OSError:
        return None


class TokenHistoryIndex:
    def __init__(self, path: Path):
        self.path = path
        self.enabled = True
        self.lock = threading.RLock()
        self.views = OrderedDict()
        self.view_bytes = 0
        self.generation = None
        self.stopping = threading.Event()

    def close(self):
        self.stopping.set()
        with self.lock:
            self.views.clear()
            self.view_bytes = 0

    def _connect(self):
        # Creating a file needs durability; reopening an unchanged cache does not.
        if not self.path.exists():
            ensure_private_file(self.path)
        from .private_io import _private_parent, _require_leaf_identity, _require_private_leaf

        with _private_parent(self.path) as (target, parent, name):
            expected = _require_private_leaf(target, parent, name)
            if expected is None or expected.st_size > MAX_DATABASE_BYTES:
                raise sqlite3.DatabaseError("history cache exceeds its size limit")
            for suffix in ("-journal", "-wal", "-shm"):
                sidecar = Path(str(target) + suffix)
                _require_private_leaf(sidecar, parent, sidecar.name)
            db = sqlite3.connect(target, timeout=0.05)
            try:
                _require_leaf_identity(target, parent, name, expected)
                db.execute("PRAGMA journal_mode=WAL")
                db.execute("PRAGMA synchronous=NORMAL")
                db.execute("PRAGMA cache_size=-32768")
                db.execute(f"PRAGMA max_page_count={MAX_DATABASE_BYTES // 4096}")
                db.execute("PRAGMA temp_store=MEMORY")
                db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID")
                version = json.dumps(semantics())
                old = db.execute("SELECT value FROM meta WHERE key='version'").fetchone()
                if old != (version,):
                    self.views.clear()
                    self.view_bytes = 0
                    for table in ("files", "raw", "events", "hours", "days", "conflicts"):
                        db.execute(f"DROP TABLE IF EXISTS {table}")
                    db.execute("DELETE FROM meta")
                    db.executemany("INSERT INTO meta VALUES (?,?)", [("version", version), ("secret", secrets.token_hex(32))])
                db.executescript("""
                CREATE TABLE IF NOT EXISTS files (
                    id INTEGER PRIMARY KEY, key TEXT UNIQUE, provider TEXT, root TEXT, ordering TEXT, metadata TEXT);
                CREATE TABLE IF NOT EXISTS raw (
                    file INTEGER, seq INTEGER, provider TEXT, session TEXT, model TEXT,
                    epoch REAL, inp INTEGER, cached INTEGER, created INTEGER, out INTEGER,
                    dedupe BLOB, canonical BLOB, kind TEXT, owner TEXT, parent TEXT,
                    root TEXT, event TEXT, day TEXT, hour TEXT, long_context INTEGER,
                    PRIMARY KEY(file,seq)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS conflicts (dedupe BLOB PRIMARY KEY) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS events (
                    dedupe BLOB PRIMARY KEY, provider TEXT, session TEXT, model TEXT,
                    epoch REAL, inp INTEGER, cached INTEGER, created INTEGER, out INTEGER,
                    day TEXT, hour TEXT, long_context INTEGER) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS hours (
                    provider TEXT, session TEXT, model TEXT, day TEXT, hour TEXT,
                    long_context INTEGER, inp INTEGER, cached INTEGER, created INTEGER,
                    out INTEGER, records INTEGER, positive_records INTEGER,
                    PRIMARY KEY(provider,session,model,day,hour,long_context)) WITHOUT ROWID;
                CREATE TEMP TABLE dirty (key BLOB PRIMARY KEY) WITHOUT ROWID;
                """)
                db.commit()
                return db
            except BaseException:
                db.close()
                raise

    def _indexes(self, db):
        # A cold load creates these once, after inserting its first batch.
        db.execute("CREATE INDEX IF NOT EXISTS raw_key ON raw(canonical)")
        db.execute("CREATE INDEX IF NOT EXISTS raw_own ON raw(owner,event,kind)")
        db.execute("CREATE INDEX IF NOT EXISTS raw_kind ON raw(kind)")
        db.execute("CREATE INDEX IF NOT EXISTS raw_parent ON raw(owner) WHERE parent IS NOT NULL")
        db.execute("CREATE INDEX IF NOT EXISTS events_hour ON events(provider,session,model,day,hour,long_context)")

    def _reconcile(self, db):
        self._indexes(db)
        self._lineage(db)
        keys = "provider,session,model,day,hour,long_context"
        db.execute(f"CREATE TEMP TABLE affected AS SELECT DISTINCT {keys} FROM events WHERE dedupe IN (SELECT key FROM dirty)")
        db.execute("DELETE FROM events WHERE dedupe IN (SELECT key FROM dirty)")
        db.execute("DELETE FROM conflicts WHERE dedupe IN (SELECT key FROM dirty)")
        db.execute("""INSERT INTO conflicts SELECT canonical FROM raw
            WHERE canonical IN (SELECT key FROM dirty) GROUP BY canonical HAVING MIN(day)!=MAX(day)""")
        db.execute("""INSERT INTO events
            SELECT canonical,provider,session,model,epoch,inp,cached,created,out,day,hour,long_context FROM (
                SELECT r.*,ROW_NUMBER() OVER (PARTITION BY canonical ORDER BY f.ordering,r.seq) AS position
                FROM raw r JOIN files f ON f.id=r.file
                WHERE canonical IN (SELECT key FROM dirty) AND canonical NOT IN (SELECT dedupe FROM conflicts)
            ) WHERE position=1""")
        db.execute(f"INSERT INTO affected SELECT DISTINCT {keys} FROM events WHERE dedupe IN (SELECT key FROM dirty)")
        db.execute(f"DELETE FROM hours WHERE ({keys}) IN (SELECT {keys} FROM affected)")
        db.execute(f"""INSERT INTO hours SELECT {keys},SUM(inp),SUM(cached),SUM(created),SUM(out),COUNT(*),
            SUM(CASE WHEN inp+cached+created+out>0 THEN 1 ELSE 0 END) FROM events
            WHERE ({keys}) IN (SELECT {keys} FROM affected) GROUP BY {keys}""")
        db.execute("DROP TABLE affected")

    def _rebucket(self, db):
        zone = json.dumps([time.tzname, time.timezone, os.environ.get("TZ")])
        if db.execute("SELECT value FROM meta WHERE key='timezone'").fetchone() == (zone,):
            return False
        # Timezone changes touch buckets only. Raw timestamps remain UTC epochs.
        db.create_function("local_day", 1, lambda epoch: datetime.fromtimestamp(epoch).date().isoformat())
        db.create_function("local_hour", 1, lambda epoch: datetime.fromtimestamp(epoch).strftime("%Y-%m-%dT%H:00"))
        db.execute("INSERT OR IGNORE INTO dirty SELECT canonical FROM raw")
        db.execute("UPDATE raw SET day=local_day(epoch),hour=local_hour(epoch)")
        db.execute("INSERT OR REPLACE INTO meta VALUES ('timezone',?)", (zone,))
        return True

    def _remove(self, db, key):
        db.execute("INSERT OR IGNORE INTO dirty SELECT canonical FROM raw WHERE file=?", (key,))
        db.execute("DELETE FROM raw WHERE file=?", (key,))
        db.execute("DELETE FROM files WHERE id=?", (key,))

    def _append(self, db, key, records):
        seq = db.execute("SELECT COALESCE(MAX(seq),-1)+1 FROM raw WHERE file=?", (key,)).fetchone()[0]

        def rows():
            for offset, row in enumerate(records):
                provider, session, model, epoch, inp, cached, created, out, dedupe = row
                stamp = datetime.fromtimestamp(epoch)
                identity = usage._codex_event_identity(dedupe) if provider == "codex" else None
                kind, owner, parent, root, event = identity or (None, None, None, None, None)
                yield (
                    key,
                    seq + offset,
                    *row[:8],
                    _digest(dedupe),
                    _digest(dedupe),
                    kind,
                    owner,
                    parent,
                    root,
                    event,
                    stamp.date().isoformat(),
                    stamp.strftime("%Y-%m-%dT%H:00"),
                    int(usage.is_long_context_request(provider, model, inp + cached + created)),
                )

        db.executemany("INSERT INTO raw VALUES (" + ",".join("?" for _ in range(20)) + ")", rows())
        db.execute("INSERT OR IGNORE INTO dirty SELECT canonical FROM raw WHERE file=? AND seq>=?", (key, seq))

    def _lineage(self, db):
        # Only copy/boundary rows need reconciliation. Own events stay on
        # disk and are found by an indexed lookup, never a Python event map.
        parents = dict(
            db.execute("""SELECT owner,parent FROM (
                SELECT r.owner,r.parent,ROW_NUMBER() OVER (
                    PARTITION BY r.owner ORDER BY f.ordering,r.seq) AS position
                FROM raw r JOIN files f ON f.id=r.file WHERE r.parent IS NOT NULL
            ) WHERE position=1""")
        )
        for file, seq, dedupe, previous in db.execute(
            "SELECT file,seq,dedupe,canonical FROM raw WHERE kind IN ('inherited','boundary')"
        ):
            kind, session, parent, root, event = db.execute(
                "SELECT kind,owner,parent,root,event FROM raw WHERE file=? AND seq=?", (file, seq)
            ).fetchone()
            owner, visited, canonical = parent, set(), None
            while owner is not None and owner not in visited:
                visited.add(owner)
                own = db.execute(
                    "SELECT r.dedupe FROM raw r JOIN files f ON f.id=r.file WHERE r.owner=? AND r.event=? AND r.kind='own' ORDER BY f.ordering,r.seq LIMIT 1",
                    (owner, event),
                ).fetchone()
                if own:
                    canonical = own[0]
                    break
                owner = parents.get(owner)
            if canonical is None and root is not None:
                own = db.execute(
                    "SELECT r.dedupe FROM raw r JOIN files f ON f.id=r.file WHERE r.owner=? AND r.event=? AND r.kind='own' ORDER BY f.ordering,r.seq LIMIT 1",
                    (root, event),
                ).fetchone()
                canonical = own[0] if own else None
            if canonical is None:
                canonical = dedupe if kind == "boundary" else _digest(f"codex-unresolved:{parent or root or session}:{event}")
            if canonical != previous:
                db.executemany("INSERT OR IGNORE INTO dirty VALUES (?)", [(previous,), (canonical,)])
                db.execute("UPDATE raw SET canonical=? WHERE file=? AND seq=?", (canonical, file, seq))

    def scan(self, roots, *, since_epoch=0.0, budget=None, cached_only=False, source_bindings=None):
        """Update changed files and return compact records for one window.

        All roots of each provider are reconciled together, so duplicates
        across configured homes count once. Incomplete walks retain files.
        """
        with self.lock:
            if self.stopping.is_set() or not self.enabled:
                return usage.UsageTotals()
            if cached_only and not self.path.exists():
                return None
            db = self._connect()
            db.set_progress_handler(lambda: int(self.stopping.is_set() or not self.enabled), 1000)
            try:
                secret = bytes.fromhex(db.execute("SELECT value FROM meta WHERE key='secret'").fetchone()[0])
                coverage = {}
                changed = False
                for provider, binding in (source_bindings or {}).items():
                    key = "source:" + provider
                    encoded = json.dumps(binding, sort_keys=True)
                    previous = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
                    if cached_only and previous != (encoded,):
                        return None
                    if previous != (encoded,):
                        for (file,) in db.execute("SELECT id FROM files WHERE provider=?", (provider,)).fetchall():
                            self._remove(db, file)
                        db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, encoded))
                        changed = True
                if cached_only:
                    if not all(
                        db.execute("SELECT value FROM meta WHERE key=?", ("complete:" + p,)).fetchone() == ("True",)
                        for p in roots
                    ):
                        return None
                    for provider, paths in roots.items():
                        manifest = json.dumps([os.path.realpath(root) for root in paths])
                        if db.execute("SELECT value FROM meta WHERE key=?", ("roots:" + provider,)).fetchone() != (
                            manifest,
                        ):
                            return None
                    return self._totals(db, roots, since_epoch)
                changed = self._rebucket(db) or changed
                cutoff = time.time() - RETENTION_SECONDS
                prune_day = str(int(cutoff // 86400))
                if db.execute("SELECT value FROM meta WHERE key='pruned'").fetchone() != (prune_day,):
                    db.execute("INSERT OR IGNORE INTO dirty SELECT canonical FROM raw WHERE epoch<?", (cutoff,))
                    if db.execute("SELECT 1 FROM dirty LIMIT 1").fetchone():
                        db.execute("DELETE FROM raw WHERE epoch<?", (cutoff,))
                        changed = True
                    db.execute("INSERT OR REPLACE INTO meta VALUES ('pruned',?)", (prune_day,))
                configured = {
                    f"{provider}:{os.path.realpath(root)}" for provider, paths in roots.items() for root in paths
                }
                for key, provider, root in db.execute("SELECT id,provider,root FROM files").fetchall():
                    if provider in roots and root not in configured:
                        self._remove(db, key)
                        changed = True
                parse_started = False
                for provider, paths in roots.items():
                    for root_rank, root in enumerate(paths):
                        if self.stopping.is_set():
                            break
                        inventory = _inventory(provider, Path(root))
                        source = inventory.sources[0]
                        state = usage._CoverageState.from_coverage(source.coverage)
                        root_key = f"{provider}:{os.path.realpath(root)}"
                        present = set()
                        attempted = False
                        for candidate in sorted(source.candidates, key=lambda c: -c.info.st_mtime_ns):
                            if candidate.info.st_mtime < cutoff:
                                continue
                            key = root_key + ":" + usage._cache_file_key(provider, candidate.info)
                            saved = db.execute("SELECT metadata,ordering,id FROM files WHERE key=?", (key,)).fetchone()
                            if saved:
                                key = saved[2]
                            if not saved:
                                key = db.execute("INSERT INTO files(key,provider,root,ordering) VALUES (?,?,?,?) RETURNING id",
                                    (key, provider, root_key, "")).fetchone()[0]
                            present.add(key)
                            entry = json.loads(saved[0]) if saved and saved[0] else None
                            info = candidate.info
                            suffix_rank = int(candidate.path.suffix != ".sqlite")
                            ordering = f"{root_rank:04}:{suffix_rank}:{candidate.path}"
                            sidecar = _sidecar_stamp(candidate.path)
                            if saved and saved[1] != ordering:
                                db.execute("INSERT OR IGNORE INTO dirty SELECT canonical FROM raw WHERE file=?", (key,))
                                db.execute("UPDATE files SET ordering=? WHERE id=?", (ordering, key))
                                changed = True
                            if (
                                entry
                                and entry.get("mtime_ns") == info.st_mtime_ns
                                and entry.get("ctime_ns") == info.st_ctime_ns
                                and entry.get("stat_size") == info.st_size
                                and entry.get("sidecar") == sidecar
                            ):
                                state.cache_hits += 1
                                state.malformed_lines += entry.get("malformed_lines", 0)
                                continue
                            if (
                                self.stopping.is_set()
                                or not self.enabled
                                or (attempted and budget is not None and budget.expired())
                            ):
                                state.pending_files += 1
                                continue
                            if budget is not None and not parse_started:
                                budget.restart()
                            parse_started = True
                            attempted = True
                            result = None
                            offset = (
                                usage._incremental_resume_offset(entry, info)
                                if provider in {"claude", "codex"}
                                else None
                            )
                            if offset is not None:
                                result = usage._parse_file_tail(
                                    candidate.path,
                                    info,
                                    offset,
                                    provider,
                                    secret,
                                    budget=_CancelableBudget(self, budget),
                                    prefix_check=usage._saved_prefix_check(entry),
                                    codex_state=entry.get("resume"),
                                )
                            append = result is not None and result.read_ok
                            if not append:
                                if provider in local.LOCAL_HISTORY_PROVIDERS:
                                    records = local._SCANNERS[provider](Path(root), 0, files=(candidate.path,))
                                    result = usage._ParseResult(
                                        records,
                                        0,
                                        usage._physical_file_unchanged(candidate.path, info),
                                        parsed_size=info.st_size,
                                    )
                                else:
                                    parser = usage._parse_codex_file if provider == "codex" else usage._parse_file
                                    result = parser(candidate.path, info, secret, _CancelableBudget(self, budget))
                            if not result.read_ok:
                                state.unreadable_files += 1
                                continue
                            if not append:
                                db.execute("INSERT OR IGNORE INTO dirty SELECT canonical FROM raw WHERE file=?", (key,))
                                db.execute("DELETE FROM raw WHERE file=?", (key,))
                            self._append(db, key, (row for row in result.records if row[3] >= cutoff))
                            metadata = {
                                "size": result.parsed_size,
                                "device": info.st_dev,
                                "inode": info.st_ino,
                                "eof_newline": result.eof_newline,
                                "mtime_ns": info.st_mtime_ns,
                                "ctime_ns": info.st_ctime_ns,
                                "sidecar": sidecar,
                                "windows": list(
                                    result.rate_limit_windows or (entry.get("windows", []) if append else [])
                                ),
                                "malformed_lines": result.malformed_lines
                                + (entry.get("malformed_lines", 0) if append else 0),
                                **usage._resume_extras_of(result, info),
                            }
                            db.execute(
                                "UPDATE files SET provider=?,root=?,ordering=?,metadata=? WHERE id=?",
                                (provider, root_key, ordering, json.dumps(metadata), key),
                            )
                            state.files_read += 1
                            state.malformed_lines += metadata["malformed_lines"]
                            state.pending_files += int(result.stopped_early)
                            changed = True
                        if source.walk_complete:
                            for (key,) in db.execute("SELECT id FROM files WHERE root=?", (root_key,)).fetchall():
                                if key not in present:
                                    self._remove(db, key)
                                    changed = True
                        coverage[provider] = usage._merge_usage_totals(
                            (
                                usage.UsageTotals(source_coverage=coverage),
                                usage.UsageTotals(source_coverage={provider: state.finalize()}),
                            )
                        ).source_coverage[provider]
                if self.stopping.is_set() or not self.enabled:
                    db.rollback()
                    return usage.UsageTotals()
                if changed:
                    self._reconcile(db)
                    db.execute(
                        "INSERT INTO meta VALUES ('generation','1') ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1"
                    )
                    self.views.clear()
                    self.view_bytes = 0
                db.commit()
                for provider, source_coverage in coverage.items():
                    complete = source_coverage.status in {usage.UsageSourceStatus.OK, usage.UsageSourceStatus.MISSING}
                    db.execute("INSERT INTO meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value!=excluded.value", ("complete:" + provider, str(complete)))
                    db.execute(
                        "INSERT INTO meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value!=excluded.value",
                        ("roots:" + provider, json.dumps([os.path.realpath(root) for root in roots[provider]])),
                    )
                db.commit()
                totals = self._totals(db, roots, since_epoch)
                totals.source_coverage = coverage
                return totals
            except sqlite3.OperationalError:
                if self.stopping.is_set() or not self.enabled:
                    return usage.UsageTotals()
                raise
            finally:
                db.close()

    def _totals(self, db, roots, since_epoch):
        totals = usage._totals_from_window(self._records(db, roots, since_epoch))
        if roots.get("codex"):
            root = "codex:" + os.path.realpath(roots["codex"][0])
            latest = (0, [])
            for (metadata,) in db.execute("SELECT metadata FROM files WHERE root=?", (root,)):
                entry = json.loads(metadata) if metadata else {}
                if entry.get("windows") and entry.get("mtime_ns", 0) > latest[0]:
                    latest = entry["mtime_ns"], entry["windows"]
            totals.codex_rate_limit_evidence = tuple(latest[1])
            totals.codex_rate_limit_observed_at = latest[0] / 1_000_000_000 if latest[0] else None
        return totals

    def _records(self, db, roots, since_epoch):
        generation = db.execute("SELECT value FROM meta WHERE key='generation'").fetchone()
        if generation != self.generation:
            self.views.clear()
            self.view_bytes = 0
            self.generation = generation
        providers = tuple(roots)
        view_key = (providers, since_epoch, tuple(time.tzname), time.timezone)
        start = datetime.fromtimestamp(since_epoch)
        if since_epoch and (start.hour or start.minute or start.second or start.microsecond):
            return [BucketRecord(row[:9], 1, bool(row[9])) for row in db.execute(
                """SELECT canonical,provider,session,model,epoch,inp,cached,created,out,long_context FROM (
                    SELECT r.*,ROW_NUMBER() OVER (PARTITION BY canonical ORDER BY f.ordering,r.seq) AS position
                    FROM raw r JOIN files f ON f.id=r.file WHERE epoch>=?
                ) WHERE position=1""", (since_epoch,)) for row in [(row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[0], row[9])] if row[0] in providers]
        records = self.views.get(view_key)
        if records is None:
            records = []
            marks = ",".join("?" for _ in providers)
            query = f"""SELECT provider,session,model,hour,SUM(inp),SUM(cached),SUM(created),SUM(out),SUM(records),long_context,SUM(positive_records)
                        FROM hours WHERE provider IN ({marks}) AND day>=?
                        GROUP BY provider,session,model,hour,long_context ORDER BY hour,model,session"""
            for p, session, model, hour, inp, cached, created, out, count, long, positive in db.execute(
                query, (*providers, start.date().isoformat())
            ):
                records.append(
                    BucketRecord(
                        (
                            p,
                            session,
                            model,
                            datetime.fromisoformat(hour).timestamp(),
                            inp,
                            cached,
                            created,
                            out,
                            f"{p}:{session}:{model}:{hour}:{long}",
                        ),
                        count,
                        bool(long),
                        positive,
                    )
                )
            for (dedupe,) in db.execute("SELECT dedupe FROM conflicts"):
                row = db.execute(
                    """SELECT r.provider,r.session,r.model,r.epoch,r.inp,r.cached,r.created,r.out,r.canonical,r.long_context
                    FROM raw r JOIN files f ON f.id=r.file WHERE r.canonical=? AND r.epoch>=?
                    ORDER BY f.ordering,r.seq LIMIT 1""",
                    (dedupe, since_epoch),
                ).fetchone()
                if row and row[0] in providers:
                    records.append(BucketRecord(row[:9], 1, bool(row[9])))
            # Count object headers and tuple attributes as well as token
            # values. Shared objects may be counted twice, conservatively.
            size = sys.getsizeof(records) + 256
            for row in records:
                size += sys.getsizeof(row) + sys.getsizeof(vars(row))
                size += sum(sys.getsizeof(value) for value in row)
                size += sum(sys.getsizeof(key) + sys.getsizeof(value) for key, value in vars(row).items())
            if self.stopping.is_set() or not self.enabled:
                return []
            if size <= VIEW_BYTES:
                while self.views and self.view_bytes + size > VIEW_BYTES:
                    _, (_, old_size) = self.views.popitem(last=False)
                    self.view_bytes -= old_size
                self.views[view_key] = (records, size)
                self.view_bytes += size
        else:
            records = records[0]
        return records


_INDEXES = OrderedDict()
_INDEX_LOCK = threading.Lock()


def shared_index(path):
    """One byte-bounded view per daemon state directory, at most four roots."""
    with _INDEX_LOCK:
        key = str(path)
        index = _INDEXES.get(key)
        if index is None or index.stopping.is_set():
            index = TokenHistoryIndex(Path(path))
            _INDEXES[key] = index
        while len(_INDEXES) > 4:
            _, old = _INDEXES.popitem(last=False)
            old.close()
        return index


def scan_history(
    *, home=None, provider_ids=("claude", "codex"), since_epoch=0.0, budget=None, now=None, env=None, extras=None
):
    if not _ENABLED:
        return usage.UsageTotals()
    from .provider_homes import home_scan_roots
    from .state_paths import default_state_dir

    allowed = {
        s.source_key.provider_id: usage._source_key_payload(s.source_key)
        for s in usage.negotiated_provider_sources()
        if s.source_key.capability_id == "transcript_usage" and s.observation_invocation_allowed
    }
    roots = home_scan_roots([p for p in provider_ids if p in allowed], home=home, env=env, extras=extras)
    places = local.roots(home=home, env=env)
    for provider in provider_ids:
        if provider in local.LOCAL_HISTORY_PROVIDERS:
            roots[provider] = (places[provider],)
            allowed[provider] = {"provider_id": provider, "parser_version": local.PARSER_VERSION}
    if not roots:
        return usage.UsageTotals()
    return shared_index(
        default_state_dir(None if home is not None and Path(home) == Path.home() else home) / "token-history.sqlite3"
    ).scan(
        roots,
        since_epoch=since_epoch,
        budget=budget,
        source_bindings={p: allowed[p] for p in roots},
    )


_ENABLED = True


def set_enabled(enabled):
    global _ENABLED
    _ENABLED = enabled
    with _INDEX_LOCK:
        for index in _INDEXES.values():
            index.enabled = enabled
            if not enabled:
                index.stopping.set()
                index.views.clear()
                index.view_bytes = 0


def history_enabled():
    return _ENABLED


def cached_card(provider, home, observed_at, *, extra_homes=None):
    """Read the same indexed month as History without walking transcripts."""
    if not _ENABLED:
        return None
    from .provider_homes import home_scan_roots
    from .state_paths import default_state_dir

    path = default_state_dir(None if Path(home) == Path.home() else home) / "token-history.sqlite3"
    if not path.exists():
        return None
    roots = home_scan_roots((provider,), home=home, extras={provider: extra_homes} if extra_homes is not None else None)
    index = shared_index(path)
    if not index.lock.acquire(blocking=False):
        return None
    try:
        totals = index.scan(roots, since_epoch=usage.card_window_start(observed_at), cached_only=True)
    except (OSError, ValueError, sqlite3.Error):
        return None
    finally:
        index.lock.release()
    if totals is None:
        return None
    records = totals.records
    # Card pricing preserves its established semantics, while History prices
    # every provider's individual request, including long-context tiers.
    card_doc = usage._card_days_document(provider, records, usage.card_window_start(observed_at))
    card = usage.cache_card_days({"daily": card_doc}, provider) if card_doc else None
    if card is None:
        return None
    amounts = usage.card_totals(card, usage.card_window_start(observed_at), provider)
    fully_priced = amounts.total_records > 0 and amounts.priced_records == amounts.total_records
    document = {
        "input_tokens": amounts.input_tokens,
        "cached_input_tokens": amounts.cached_input_tokens,
        "output_tokens": amounts.output_tokens,
        "model_count": len(amounts.models),
        "estimated_cost_usd": amounts.estimated_cost_usd if fully_priced else None,
        "cache_savings_usd": amounts.estimated_cache_savings_usd if fully_priced else None,
    }

    if provider == "codex":
        document["windows"] = list(totals.codex_rate_limit_evidence)
        document["windows_observed_at"] = totals.codex_rate_limit_observed_at
    return document
