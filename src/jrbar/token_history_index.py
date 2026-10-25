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

SCHEMA_VERSION = 6
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
        self.scan_lock = threading.Lock()
        self.cards = OrderedDict()
        self.retry_at = 0.0
        self.error = None
        self.checked_identity = None
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
                identity = (expected.st_dev, expected.st_ino)
                if self.checked_identity != identity:
                    if db.execute("PRAGMA quick_check").fetchone() != ("ok",):
                        raise sqlite3.DatabaseError("history cache quick_check failed")
                    self.checked_identity = identity
                db.execute("PRAGMA journal_mode=WAL")
                db.execute("PRAGMA synchronous=NORMAL")
                db.execute("PRAGMA cache_size=-32768")
                db.execute(f"PRAGMA max_page_count={MAX_DATABASE_BYTES // 4096}")
                db.execute("PRAGMA temp_store=MEMORY")
                db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID")
                version = json.dumps(semantics())
                old = db.execute("SELECT value FROM meta WHERE key='version'").fetchone()
                if old != (version,):
                    self._clear_views()
                    for table in ("files", "raw", "events", "hours", "days", "conflicts", "canonicals", "parents", "resolutions", "dependencies", "dirty", "own_dirty", "parent_dirty", "resolve_dirty", "resolve_queue"):
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
                CREATE TABLE IF NOT EXISTS canonicals (
                    owner TEXT, event TEXT, dedupe BLOB, PRIMARY KEY(owner,event)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS parents (owner TEXT PRIMARY KEY,parent TEXT) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS resolutions (
                    owner TEXT,event TEXT,canonical BLOB,PRIMARY KEY(owner,event)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS dependencies (
                    ancestor TEXT,event TEXT,owner TEXT,PRIMARY KEY(ancestor,event,owner)) WITHOUT ROWID;
                CREATE INDEX IF NOT EXISTS dependency_owner ON dependencies(owner,event);
                CREATE TABLE IF NOT EXISTS dirty (key BLOB PRIMARY KEY) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS resolve_dirty (owner TEXT,event TEXT,PRIMARY KEY(owner,event)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS own_dirty (owner TEXT,event TEXT,PRIMARY KEY(owner,event)) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS parent_dirty (owner TEXT PRIMARY KEY) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS resolve_queue (owner TEXT,event TEXT,PRIMARY KEY(owner,event)) WITHOUT ROWID;
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

    def _reconcile(self, db, budget=None):
        self._indexes(db)
        self._lineage(db, budget)
        if db.execute("SELECT 1 FROM resolve_queue LIMIT 1").fetchone():
            return
        limit = 4096 if budget is not None else -1
        db.execute("CREATE TEMP TABLE active_dirty AS SELECT key FROM dirty LIMIT ?", (limit,))
        keys = "provider,session,model,day,hour,long_context"
        db.execute(f"CREATE TEMP TABLE affected AS SELECT DISTINCT {keys} FROM events WHERE dedupe IN (SELECT key FROM active_dirty)")
        db.execute("DELETE FROM events WHERE dedupe IN (SELECT key FROM active_dirty)")
        db.execute("DELETE FROM conflicts WHERE dedupe IN (SELECT key FROM active_dirty)")
        db.execute("""INSERT INTO conflicts SELECT canonical FROM raw
            WHERE canonical IN (SELECT key FROM active_dirty) GROUP BY canonical HAVING MIN(day)!=MAX(day)""")
        db.execute("""INSERT INTO events
            SELECT canonical,provider,session,model,epoch,inp,cached,created,out,day,hour,long_context FROM (
                SELECT r.*,ROW_NUMBER() OVER (PARTITION BY canonical ORDER BY f.ordering,r.seq) AS position
                FROM raw r JOIN files f ON f.id=r.file
                WHERE canonical IN (SELECT key FROM active_dirty) AND canonical NOT IN (SELECT dedupe FROM conflicts)
            ) WHERE position=1""")
        db.execute(f"INSERT INTO affected SELECT DISTINCT {keys} FROM events WHERE dedupe IN (SELECT key FROM active_dirty)")
        db.execute(f"DELETE FROM hours WHERE ({keys}) IN (SELECT {keys} FROM affected)")
        db.execute(f"""INSERT INTO hours SELECT {keys},SUM(inp),SUM(cached),SUM(created),SUM(out),COUNT(*),
            SUM(CASE WHEN inp+cached+created+out>0 THEN 1 ELSE 0 END) FROM events
            WHERE ({keys}) IN (SELECT {keys} FROM affected) GROUP BY {keys}""")
        db.execute("DROP TABLE affected")
        db.execute("DELETE FROM dirty WHERE key IN (SELECT key FROM active_dirty)")
        db.execute("DROP TABLE active_dirty")

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

    def _mark_file(self, db, key, seq=0):
        db.execute("INSERT OR IGNORE INTO resolve_dirty SELECT owner,event FROM raw WHERE file=? AND seq>=? AND kind IN ('inherited','boundary')", (key, seq))
        db.execute("INSERT OR IGNORE INTO own_dirty SELECT owner,event FROM raw WHERE file=? AND seq>=? AND kind='own'", (key, seq))
        db.execute("INSERT OR IGNORE INTO parent_dirty SELECT owner FROM raw WHERE file=? AND seq>=? AND parent IS NOT NULL", (key, seq))

    def _remove(self, db, key):
        self._mark_file(db, key)
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
        self._mark_file(db, key, seq)

    def _lineage(self, db, budget=None):
        # Resolve only changed copies and copies that depended on changed own
        # events or parent links. A missing ancestor is also a dependency.
        db.execute("DELETE FROM canonicals WHERE (owner,event) IN (SELECT owner,event FROM own_dirty)")
        db.execute("""INSERT INTO canonicals SELECT owner,event,dedupe FROM (
            SELECT r.owner,r.event,r.dedupe,ROW_NUMBER() OVER (
                PARTITION BY r.owner,r.event ORDER BY f.ordering,r.seq) AS position
            FROM own_dirty d JOIN raw r ON r.owner=d.owner AND r.event=d.event
            JOIN files f ON f.id=r.file WHERE r.kind='own') WHERE position=1""")
        db.execute("CREATE TEMP TABLE previous_parents AS SELECT * FROM parents WHERE owner IN (SELECT owner FROM parent_dirty)")
        db.execute("DELETE FROM parents WHERE owner IN (SELECT owner FROM parent_dirty)")
        db.execute("""INSERT INTO parents SELECT owner,parent FROM (
            SELECT r.owner,r.parent,ROW_NUMBER() OVER (
                PARTITION BY r.owner ORDER BY f.ordering,r.seq) AS position
            FROM parent_dirty d JOIN raw r ON r.owner=d.owner JOIN files f ON f.id=r.file
            WHERE r.parent IS NOT NULL) WHERE position=1""")
        db.execute("""DELETE FROM parent_dirty WHERE
            (SELECT parent FROM parents p WHERE p.owner=parent_dirty.owner) IS
            (SELECT parent FROM previous_parents p WHERE p.owner=parent_dirty.owner)""")
        db.execute("DROP TABLE previous_parents")
        db.execute("""INSERT OR IGNORE INTO resolve_queue
            SELECT owner,event FROM resolve_dirty
            UNION SELECT d.owner,d.event FROM dependencies d JOIN own_dirty o
                ON o.owner=d.ancestor AND o.event=d.event
            UNION SELECT d.owner,d.event FROM dependencies d JOIN parent_dirty p ON p.owner=d.ancestor""")
        for table in ("own_dirty", "parent_dirty", "resolve_dirty"):
            db.execute(f"DELETE FROM {table}")
        # Raw offsets and the reconciliation queue survive an interrupted pass.
        db.commit()
        limit = 256 if budget is not None else -1
        for session, event in db.execute("SELECT owner,event FROM resolve_queue LIMIT ?", (limit,)).fetchall():
            if budget is not None and budget.expired():
                break
            db.execute("DELETE FROM resolve_queue WHERE owner=? AND event=?", (session, event))
            row = db.execute("""SELECT r.kind,r.parent,r.root,r.dedupe FROM raw r JOIN files f ON f.id=r.file
                WHERE r.owner=? AND r.event=? AND r.kind IN ('inherited','boundary')
                ORDER BY f.ordering,r.seq LIMIT 1""", (session, event)).fetchone()
            db.execute("DELETE FROM dependencies WHERE owner=? AND event=?", (session, event))
            db.execute("DELETE FROM resolutions WHERE owner=? AND event=?", (session, event))
            if row is None:
                continue
            kind, parent, root, dedupe = row
            owner, visited, canonical = parent, set(), None
            while owner is not None and owner not in visited:
                visited.add(owner)
                own = db.execute("SELECT dedupe FROM canonicals WHERE owner=? AND event=?", (owner, event)).fetchone()
                if own:
                    canonical = own[0]
                    break
                ancestor = db.execute("SELECT parent FROM parents WHERE owner=?", (owner,)).fetchone()
                owner = ancestor[0] if ancestor else None
            if canonical is None and root is not None:
                visited.add(root)
                own = db.execute("SELECT dedupe FROM canonicals WHERE owner=? AND event=?", (root, event)).fetchone()
                canonical = own[0] if own else None
            if canonical is None:
                canonical = dedupe if kind == "boundary" else _digest(f"codex-unresolved:{parent or root or session}:{event}")
            db.executemany("INSERT OR IGNORE INTO dependencies VALUES (?,?,?)", ((owner, event, session) for owner in visited))
            db.execute("INSERT INTO resolutions VALUES (?,?,?)", (session, event, canonical))
            db.execute("""INSERT OR IGNORE INTO dirty SELECT canonical FROM raw
                WHERE owner=? AND event=? AND kind IN ('inherited','boundary') AND canonical!=?""", (session, event, canonical))
            db.execute("""UPDATE raw SET canonical=? WHERE owner=? AND event=?
                AND kind IN ('inherited','boundary') AND canonical!=?""", (canonical, session, event, canonical))
            db.execute("INSERT OR IGNORE INTO dirty VALUES (?)", (canonical,))
            self.resolved_last_pass += 1

    def _failed_totals(self, roots):
        totals = usage.UsageTotals()
        totals.source_coverage = {p: usage._CoverageState(p, root_present=True, unreadable_files=1).finalize() for p in roots}
        return totals

    def _recover(self, error):
        if getattr(error, "sqlite_errorcode", None) in {sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED, sqlite3.SQLITE_INTERRUPT}:
            return
        full = getattr(error, "sqlite_errorcode", None) == sqlite3.SQLITE_FULL
        self.error = "history_disk_full" if full else "history_cache_unavailable"
        self.retry_at = time.monotonic() + (3600 if full else 60)
        if not full and isinstance(error, sqlite3.DatabaseError) and not isinstance(error, sqlite3.OperationalError):
            # Preserve damaged bytes for diagnosis; never repeatedly rebuild a
            # damaged cache in the maintenance loop. Refuse unsafe leaves.
            from .private_io import _private_parent, _require_private_leaf
            try:
                with _private_parent(self.path) as (target, parent, name):
                    _require_private_leaf(target, parent, name)
                    suffix = ".damaged-" + secrets.token_hex(6)
                    for ending in ("", "-wal", "-shm", "-journal"):
                        leaf = Path(str(target) + ending)
                        if _require_private_leaf(leaf, parent, leaf.name) is not None:
                            os.rename(leaf.name, name + suffix + ending, src_dir_fd=parent, dst_dir_fd=parent)
                self.checked_identity = None
            except OSError:
                pass

    def _cached_totals(self, roots, since_epoch):
        if not self.path.exists() or time.monotonic() < self.retry_at:
            return None
        db = self._connect()
        try:
            for provider, paths in roots.items():
                manifest = json.dumps([os.path.realpath(root) for root in paths])
                if db.execute("SELECT value FROM meta WHERE key=?", ("roots:" + provider,)).fetchone() != (manifest,):
                    return None
            totals = self._totals(db, roots, since_epoch)
            totals.history_stale = self.scan_lock.locked() or any(db.execute("SELECT value FROM meta WHERE key=?", ("complete:" + p,)).fetchone() != ("True",) for p in roots)
            return totals
        finally:
            db.close()

    def scan(self, roots, *, since_epoch=0.0, budget=None, cached_only=False, source_bindings=None):
        try:
            if cached_only:
                return self._cached_totals(roots, since_epoch)
            if time.monotonic() < self.retry_at:
                return self._failed_totals(roots)
            from .usage_graph_worker import _drop_to_utility_qos
            _drop_to_utility_qos()
            return self._scan(roots, since_epoch=since_epoch, budget=budget, source_bindings=source_bindings)
        except (OSError, ValueError, sqlite3.Error) as error:
            self._recover(error)
            return None if cached_only else self._failed_totals(roots)

    def _scan(self, roots, *, since_epoch=0.0, budget=None, source_bindings=None):
        """Update changed files and return compact records for one window.

        All roots of each provider are reconciled together, so duplicates
        across configured homes count once. Incomplete walks retain files.
        """
        if not self.scan_lock.acquire(timeout=0.05):
            totals = self._cached_totals(roots, since_epoch)
            if totals is not None:
                totals.source_coverage = {p: usage._CoverageState(p, root_present=True, root_walked=True, pending_files=1).finalize() for p in roots}
                return totals
            return self._failed_totals(roots)
        try:
            if self.stopping.is_set() or not self.enabled:
                return usage.UsageTotals()
            db = self._connect()
            db.set_progress_handler(lambda: int(self.stopping.is_set() or not self.enabled), 1000)
            parse_budget = budget.share(2) if budget is not None else None
            self.resolved_last_pass = 0
            try:
                secret = bytes.fromhex(db.execute("SELECT value FROM meta WHERE key='secret'").fetchone()[0])
                coverage = {}
                changed = False
                for provider, binding in (source_bindings or {}).items():
                    key = "source:" + provider
                    encoded = json.dumps(binding, sort_keys=True)
                    previous = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
                    if previous != (encoded,):
                        for (file,) in db.execute("SELECT id FROM files WHERE provider=?", (provider,)).fetchall():
                            self._remove(db, file)
                        db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, encoded))
                        changed = True
                changed = self._rebucket(db) or changed
                cutoff = time.time() - RETENTION_SECONDS
                prune_day = str(int(cutoff // 86400))
                if db.execute("SELECT value FROM meta WHERE key='pruned'").fetchone() != (prune_day,):
                    db.execute("INSERT OR IGNORE INTO dirty SELECT canonical FROM raw WHERE epoch<?", (cutoff,))
                    if db.execute("SELECT 1 FROM dirty LIMIT 1").fetchone():
                        for (file,) in db.execute("SELECT DISTINCT file FROM raw WHERE epoch<?", (cutoff,)).fetchall():
                            self._mark_file(db, file)
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
                for provider, paths in roots.items():
                    for root_rank, root in enumerate(paths):
                        if self.stopping.is_set():
                            break
                        inventory = _inventory(provider, Path(root))
                        source = inventory.sources[0]
                        state = usage._CoverageState.from_coverage(source.coverage)
                        root_key = f"{provider}:{os.path.realpath(root)}"
                        present = set()
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
                                self._mark_file(db, key)
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
                                or (parse_budget is not None and parse_budget.expired())
                            ):
                                state.pending_files += 1
                                continue
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
                                    budget=_CancelableBudget(self, parse_budget),
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
                                    result = parser(candidate.path, info, secret, _CancelableBudget(self, parse_budget))
                            if not result.read_ok:
                                state.unreadable_files += 1
                                continue
                            if not append:
                                self._mark_file(db, key)
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
                            db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", ("complete:" + provider, "False"))
                            db.commit()
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
                db.commit()
                def pending():
                    return any(db.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone() for table in
                        ("dirty", "own_dirty", "parent_dirty", "resolve_dirty", "resolve_queue"))
                while pending() and (budget is None or not budget.expired()):
                    db.set_progress_handler(lambda: int(self.stopping.is_set() or not self.enabled or (budget is not None and budget.expired())), 1000)
                    try:
                        self._reconcile(db, budget)
                        db.execute("INSERT INTO meta VALUES ('generation','1') ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1")
                        db.commit()
                    except sqlite3.OperationalError as error:
                        db.rollback()
                        if getattr(error, "sqlite_errorcode", None) != sqlite3.SQLITE_INTERRUPT:
                            raise
                        break
                    finally:
                        db.set_progress_handler(None, 0)
                    self._clear_views()
                unfinished = pending()
                if unfinished:
                    coverage = {p: replace(c, status=usage.UsageSourceStatus.PARTIAL, pending_files=max(1, c.pending_files)) for p, c in coverage.items()}
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
                self.error = None
                return totals
            except sqlite3.OperationalError:
                if self.stopping.is_set() or not self.enabled:
                    return usage.UsageTotals()
                raise
            finally:
                db.close()
        finally:
            self.scan_lock.release()

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

    def _clear_views(self):
        with self.lock:
            self.views.clear()
            self.view_bytes = 0

    def _records(self, db, roots, since_epoch):
        if not self.lock.acquire(timeout=0.05):
            raise sqlite3.OperationalError("history view is busy")
        try:
            return self._locked_records(db, roots, since_epoch)
        finally:
            self.lock.release()

    def _locked_records(self, db, roots, since_epoch):
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
                with index.lock:
                    index.views.clear()
                    index.view_bytes = 0
                    index.cards.clear()


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
    card_key = (provider, usage.card_window_start(observed_at))
    def previous():
        with index.lock:
            card = index.cards.get(card_key)
            return {**card, "history_stale": True} if card is not None else None
    try:
        totals = index.scan(roots, since_epoch=usage.card_window_start(observed_at), cached_only=True)
    except (OSError, ValueError, sqlite3.Error):
        return previous()
    if totals is None:
        return previous()
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

    document["history_stale"] = bool(getattr(totals, "history_stale", False))
    with index.lock:
        index.cards[card_key] = document
        while len(index.cards) > 16:
            index.cards.popitem(last=False)
    if provider == "codex":
        document["windows"] = list(totals.codex_rate_limit_evidence)
        document["windows_observed_at"] = totals.codex_rate_limit_observed_at
    return document
