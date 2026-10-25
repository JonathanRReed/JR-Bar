"""Private incremental token history. No message text is retained.

Parsers remain in usage_stats. SQLite owns deduplication and additive buckets;
Python retains at most one bounded parse pass and one compact range view.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import secrets
import sqlite3
import subprocess
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

SCHEMA_VERSION = 7
RETENTION_SECONDS = 368 * 86400
MAX_DATABASE_BYTES = 4 * 1024**3
VIEW_BYTES = 4 * 1024 * 1024
INCREMENTAL_CPU_SECONDS = 0.05
PARSE_CHECK_LIMIT = 50000 // usage._BUDGET_CHECK_WEIGHT


def _acquire_build_lock(path):
    """One writer across daemon lifetimes. Never unlink the lock inode."""
    from .private_io import (
        _fchmod_if_needed,
        _private_parent,
        _require_leaf_identity,
        _require_opened_leaf,
        _require_private_leaf,
    )
    with _private_parent(Path(str(path) + ".lock")) as (target, parent, name):
        expected = _require_private_leaf(target, parent, name)
        descriptor = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
        try:
            opened = os.fstat(descriptor)
            _require_opened_leaf(target, expected, opened)
            _require_leaf_identity(target, parent, name, opened)
            _fchmod_if_needed(descriptor, 0o600, opened)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(descriptor)
                return None
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise


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


class _RebuildRequired(Exception):
    pass


class HistorySizeLimit(OSError):
    """The cache reached its configured cap; its bytes are not damaged."""


class _CancelableBudget:
    def __init__(self, index, budget):
        self.index = index
        self.budget = budget
        self.checks = 0

    def expired(self):
        self.checks += 1
        return (
            self.index._stopped()
            or self.checks >= PARSE_CHECK_LIMIT
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
    def __init__(self, path: Path, *, background_build=True, progress=None, builder=False, parent_pid=None):
        self.parent_pid = parent_pid
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
        self.writer = None
        self.strings = {}
        self.next_seq = {}
        self.file_metadata = {}
        self.writer_version = None
        self.file_index_ready = False
        self.resolved_last_pass = 0
        self.background_build = background_build
        self.progress = progress
        self.builder = builder
        self.child = None
        self.child_result = None
        self.child_buffer = b""
        self.inventories = {}
        self.last_walk = {}
        self.checked_at = {}
        self.directory_stamps = {}

    def _stopped(self):
        if self.parent_pid is not None and os.getppid() != self.parent_pid:
            self.stopping.set()
        return self.stopping.is_set()

    def close(self):
        self.stopping.set()
        with self.scan_lock:
            self._stop_child()
            if self.writer is not None:
                self.writer.set_progress_handler(None, 0)
                if self.builder:
                    self.writer.execute("PRAGMA optimize")
                self.writer.close()
                self.writer = None
        with self.lock:
            self.views.clear()
            self.view_bytes = 0
            self.cards.clear()

    def _stop_child(self):
        child = self.child
        if child is not None:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
            child.stdout.close()
            self.child = None

    def _poll_child(self):
        child = self.child
        if child is None:
            return False
        returncode = child.poll()
        try:
            while chunk := os.read(child.stdout.fileno(), 65536):
                self.child_buffer += chunk
        except BlockingIOError:
            pass
        while b"\n" in self.child_buffer:
            line, self.child_buffer = self.child_buffer.split(b"\n", 1)
            report = json.loads(line)
            self.child_result = report
            if report.get("phase") == "done":
                self.error = report.get("error")
            if report.get("error"):
                self.error = report["error"]
                self.retry_at = time.monotonic() + (3600 if self.error == "disk_full" else 60)
        if returncode is None:
            return True
        if returncode and not self.error:
            self.error = "failed"
            self.retry_at = time.monotonic() + 60
        child.stdout.close()
        self.child = None
        self._clear_views()
        return False

    def _needs_build(self, roots, source_bindings):
        db = self._connect(read_only=True)
        if db is None:
            return True
        try:
            for provider, paths in roots.items():
                manifest = json.dumps([os.path.realpath(root) for root in paths])
                if db.execute("SELECT value FROM meta WHERE key=?", ("roots:" + provider,)).fetchone() != (manifest,):
                    return True
                if db.execute("SELECT value FROM meta WHERE key=?", ("built:" + provider,)).fetchone() != ("True",):
                    return True
                if provider in (source_bindings or {}):
                    binding = json.dumps(source_bindings[provider], sort_keys=True)
                    if db.execute("SELECT value FROM meta WHERE key=?", ("source:" + provider,)).fetchone() != (binding,):
                        return True
            return False
        finally:
            db.close()

    def _start_child(self, roots, source_bindings, *, lock_fd=None):
        if lock_fd is None:
            lock_fd = _acquire_build_lock(self.path)
            if lock_fd is None:
                return False
            try:
                return self._start_child(roots, source_bindings, lock_fd=lock_fd)
            finally:
                os.close(lock_fd)
        # No fork of the threaded daemon, no imports of AppKit, and no shared
        # Python GIL. Only this process lowers its own scheduling class.
        if self.writer is not None:
            self.writer.close()
            self.writer = None
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(Path(__file__).resolve().parent.parent) + os.pathsep + environment.get("PYTHONPATH", "")
        child = subprocess.Popen([sys.executable, "-m", "jrbar.token_history_build"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment,
                                 pass_fds=(lock_fd,))
        request = {"path": str(self.path.absolute()), "roots": {p: [str(Path(r).absolute()) for r in paths] for p, paths in roots.items()},
                   "source_bindings": source_bindings, "lock_fd": lock_fd, "parent_pid": os.getpid()}
        self.child = child
        try:
            child.stdin.write(json.dumps(request).encode())
            child.stdin.close()
            os.set_blocking(child.stdout.fileno(), False)
        except OSError:
            self._stop_child()
            raise
        self.child_buffer = b""
        self.child_result = None
        return True

    def _background_pass(self, roots, since_epoch, source_bindings):
        if not self.scan_lock.acquire(timeout=0.05):
            return self._pending_totals(roots)
        try:
            if self._stopped() or not self.enabled:
                return usage.UsageTotals()
            if self._poll_child():
                return self._pending_totals(roots)
            if self.error and time.monotonic() < self.retry_at:
                return self._failed_totals(roots)
            lock_fd = _acquire_build_lock(self.path)
            if lock_fd is None:
                return self._pending_totals(roots)
            try:
                if self._needs_build(roots, source_bindings):
                    self._start_child(roots, source_bindings, lock_fd=lock_fd)
                    return self._pending_totals(roots)
            finally:
                os.close(lock_fd)
        finally:
            self.scan_lock.release()
        return None

    def _connect(self, *, read_only=False):
        if not read_only and self.writer is not None:
            info = self.path.stat()
            if (info.st_dev, info.st_ino) == self.checked_identity:
                if info.st_size > MAX_DATABASE_BYTES:
                    raise HistorySizeLimit("history cache exceeds its size limit")
                return self.writer
            self.writer.close()
            self.writer = None
            self.file_metadata.clear()
            self.strings.clear()
        if not self.path.exists():
            if read_only:
                return None
            ensure_private_file(self.path)
        from .private_io import _chmod_if_needed, _private_parent, _require_leaf_identity, _require_private_leaf
        with _private_parent(self.path) as (target, parent, name):
            expected = _require_private_leaf(target, parent, name)
            if expected is None:
                raise OSError("history cache is missing")
            if expected.st_size > MAX_DATABASE_BYTES:
                raise HistorySizeLimit("history cache exceeds its size limit")
            _chmod_if_needed(target, 0o600, expected)
            for suffix in ("-journal", "-wal", "-shm"):
                sidecar = Path(str(target) + suffix)
                info = _require_private_leaf(sidecar, parent, sidecar.name)
                if info is not None:
                    _chmod_if_needed(sidecar, 0o600, info)
            db = sqlite3.connect(target.as_uri() + "?mode=ro", uri=True, timeout=0.05) if read_only else sqlite3.connect(target, timeout=0.05, check_same_thread=False)
            try:
                _require_leaf_identity(target, parent, name, expected)
                db.set_progress_handler(lambda: int(self._stopped() or not self.enabled), 1000)
                if read_only:
                    db.execute("PRAGMA query_only=ON")
                    db.execute("PRAGMA cache_size=-2048")
                    db.execute("BEGIN")
                try:
                    version = db.execute("SELECT value FROM meta WHERE key='version'").fetchone()
                except sqlite3.OperationalError as error:
                    if "no such table" not in str(error):
                        raise
                    version = None
                encoded = json.dumps(semantics())
                if read_only:
                    if version != (encoded,):
                        db.close()
                        return None
                    return db
                if version != (encoded,) and db.execute("PRAGMA quick_check").fetchone() != ("ok",):
                    raise sqlite3.DatabaseError("history cache quick_check failed")
                db.execute("PRAGMA journal_mode=WAL")
                db.execute("PRAGMA synchronous=NORMAL")
                db.execute("PRAGMA cache_size=-65536" if self.builder else "PRAGMA cache_size=-6144")
                db.execute("PRAGMA temp_store=FILE")
                db.execute("PRAGMA wal_autocheckpoint=10000" if self.builder else "PRAGMA wal_autocheckpoint=1000")
                page_size = db.execute("PRAGMA page_size").fetchone()[0]
                db.execute(f"PRAGMA max_page_count={MAX_DATABASE_BYTES // page_size}")
                if version != (encoded,):
                    self._clear_views()
                    # Rebuild once. No old text columns or redundant indexes survive.
                    objects = db.execute("SELECT type,name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'").fetchall()
                    for kind, table in objects:
                        db.execute(f'DROP {kind} "{table}"')
                    self._schema(db)
                    db.executemany("INSERT INTO meta VALUES (?,?)", [("version", encoded), ("secret", secrets.token_hex(32))])
                    db.commit()
                    if expected.st_size:
                        db.execute("VACUUM")
                self.checked_identity = (expected.st_dev, expected.st_ino)
                self.writer = db
                self.writer_version = db.execute("PRAGMA data_version").fetchone()
                self.file_index_ready = db.execute("SELECT 1 FROM sqlite_master WHERE name='raw_file'").fetchone() is not None
                self.strings = dict(db.execute("SELECT value,id FROM strings"))
                self.file_metadata = {key: (json.loads(meta) if meta else None, order, ident)
                                      for key, meta, order, ident in db.execute("SELECT key,metadata,ordering,id FROM files")}
                self.next_seq = {ident: meta.get("next_seq", 0) for meta, _, ident in self.file_metadata.values() if meta}
                return db
            except BaseException:
                db.close()
                raise

    @staticmethod
    def _schema(db):
        db.executescript("""
        CREATE TABLE meta (key TEXT PRIMARY KEY,value TEXT) WITHOUT ROWID;
        CREATE TABLE strings (id INTEGER PRIMARY KEY,value TEXT UNIQUE);
        CREATE TABLE files (id INTEGER PRIMARY KEY,key TEXT UNIQUE,provider TEXT,root TEXT,ordering TEXT,metadata TEXT);
        CREATE TABLE raw (
            dedupe BLOB PRIMARY KEY,file INTEGER,seq INTEGER,provider INTEGER,session INTEGER,model INTEGER,
            bucket INTEGER,offset REAL,inp INTEGER,cached INTEGER,created INTEGER,out INTEGER,
            long_context INTEGER,active INTEGER DEFAULT 0) WITHOUT ROWID;
        CREATE INDEX raw_conflicts ON raw(provider) WHERE active=-1;
        CREATE TABLE copies (
            dedupe BLOB,file INTEGER,seq INTEGER,provider INTEGER,session INTEGER,model INTEGER,
            bucket INTEGER,offset REAL,inp INTEGER,cached INTEGER,created INTEGER,out INTEGER,
            long_context INTEGER,active INTEGER DEFAULT 0,PRIMARY KEY(dedupe,file,seq)) WITHOUT ROWID;
        CREATE INDEX copies_file ON copies(file,seq);
        CREATE INDEX copies_conflicts ON copies(provider) WHERE active=-1;
        CREATE TABLE hours (
            provider INTEGER,session INTEGER,model INTEGER,bucket INTEGER,long_context INTEGER,
            inp INTEGER,cached INTEGER,created INTEGER,out INTEGER,records INTEGER,positive_records INTEGER,
            PRIMARY KEY(provider,session,model,bucket,long_context)) WITHOUT ROWID;
        CREATE TABLE lineage (
            dedupe BLOB PRIMARY KEY,owner INTEGER,event BLOB,kind INTEGER,parent INTEGER,root INTEGER,
            fallback BLOB,canonical BLOB) WITHOUT ROWID;
        CREATE INDEX lineage_own ON lineage(owner,event,kind);
        CREATE INDEX lineage_canonical ON lineage(canonical);
        CREATE TABLE canonicals (owner INTEGER,event BLOB,dedupe BLOB,PRIMARY KEY(owner,event)) WITHOUT ROWID;
        CREATE TABLE parents (owner INTEGER PRIMARY KEY,parent INTEGER);
        CREATE TABLE dependencies (ancestor INTEGER,event BLOB,owner INTEGER,PRIMARY KEY(ancestor,event,owner)) WITHOUT ROWID;
        CREATE INDEX dependency_owner ON dependencies(owner,event);
        CREATE TABLE dirty (key BLOB PRIMARY KEY) WITHOUT ROWID;
        CREATE TABLE own_dirty (owner INTEGER,event BLOB,PRIMARY KEY(owner,event)) WITHOUT ROWID;
        CREATE TABLE parent_dirty (owner INTEGER PRIMARY KEY);
        CREATE TABLE resolve_dirty (owner INTEGER,event BLOB,PRIMARY KEY(owner,event)) WITHOUT ROWID;
        CREATE TABLE resolve_queue (owner INTEGER,event BLOB,PRIMARY KEY(owner,event)) WITHOUT ROWID;
        CREATE VIEW facts AS SELECT * FROM raw UNION ALL SELECT * FROM copies;
        """)

    def _intern(self, db, value):
        if value is None:
            return None
        ident = self.strings.get(value)
        if ident is None:
            ident = db.execute("INSERT INTO strings(value) VALUES (?) RETURNING id", (value,)).fetchone()[0]
            self.strings[value] = ident
        return ident

    def _mark_file(self, db, key, seq=0):
        db.execute("CREATE TEMP TABLE removed AS SELECT dedupe FROM raw WHERE file=? AND seq>=? UNION SELECT dedupe FROM copies WHERE file=? AND seq>=?", (key, seq, key, seq))
        db.execute("INSERT OR IGNORE INTO dirty SELECT COALESCE(l.canonical,r.dedupe) FROM removed r LEFT JOIN lineage l USING(dedupe)")
        db.execute("INSERT OR IGNORE INTO own_dirty SELECT l.owner,l.event FROM removed r CROSS JOIN lineage l USING(dedupe) WHERE l.kind=0")
        db.execute("INSERT OR IGNORE INTO resolve_dirty SELECT l.owner,l.event FROM removed r CROSS JOIN lineage l USING(dedupe) WHERE l.kind!=0")
        db.execute("INSERT OR IGNORE INTO parent_dirty SELECT l.owner FROM removed r CROSS JOIN lineage l USING(dedupe) WHERE l.parent IS NOT NULL")
        db.execute("DROP TABLE removed")

    def _delete_file_rows(self, db, key):
        db.execute("CREATE TEMP TABLE deleted_keys AS SELECT dedupe FROM raw WHERE file=? UNION SELECT dedupe FROM copies WHERE file=?", (key, key))
        self._mark_file(db, key)
        self.next_seq.pop(key, None)
        # Subtract the selected rows before deleting their only copy.
        for table in ("raw", "copies"):
            self._add_hours(db, f"SELECT * FROM {table} WHERE file={int(key)} AND active=1", -1)
            db.execute(f"DELETE FROM {table} WHERE file=?", (key,))
        # Promote a surviving duplicate without copying all other records.
        db.execute("INSERT OR IGNORE INTO raw SELECT c.* FROM deleted_keys d CROSS JOIN copies c ON c.dedupe=d.dedupe WHERE NOT EXISTS (SELECT 1 FROM raw r WHERE r.dedupe=c.dedupe) ORDER BY c.file,c.seq")
        db.execute("DELETE FROM copies WHERE (dedupe,file,seq) IN (SELECT c.dedupe,c.file,c.seq FROM deleted_keys d CROSS JOIN copies c ON c.dedupe=d.dedupe CROSS JOIN raw r USING(dedupe) WHERE c.file=r.file AND c.seq=r.seq)")
        db.execute("DELETE FROM lineage WHERE dedupe IN (SELECT dedupe FROM deleted_keys) AND NOT EXISTS (SELECT 1 FROM raw r WHERE r.dedupe=lineage.dedupe)")
        db.execute("DROP TABLE deleted_keys")

    def _remove(self, db, key):
        self._delete_file_rows(db, key)
        db.execute("DELETE FROM files WHERE id=?", (key,))
        self.file_metadata = {k: v for k, v in self.file_metadata.items() if v[2] != key}

    def _append(self, db, key, records):
        seq = self.next_seq.get(key, 0)
        facts, links = [], []
        previous_identity, interned_identity = None, None
        for offset, row in enumerate(records):
            provider, session, model, epoch, inp, cached, created, out, dedupe = row
            identity_fields = (provider, session, model)
            if identity_fields != previous_identity:
                interned_identity = tuple(self._intern(db, field) for field in identity_fields)
                previous_identity = identity_fields
            digest = _digest(dedupe)
            bucket = int(epoch // 900)
            facts.append((digest, key, seq + offset, *interned_identity, bucket,
                          epoch - bucket * 900, inp, cached, created, out, int(usage.is_long_context_request(provider, model, inp + cached + created)), 1))
            identity = usage._codex_event_identity(dedupe) if provider == "codex" else None
            if identity:
                kind, owner, parent, root, event = identity
                fallback = digest if kind in {"own", "boundary"} else _digest(f"codex-unresolved:{parent or root or owner}:{event}")
                links.append((digest, self._intern(db, owner), bytes.fromhex(event), {"own": 0, "inherited": 1, "boundary": 2}[kind],
                              self._intern(db, parent), self._intern(db, root), fallback, digest))
        if not facts:
            return
        self.next_seq[key] = seq + len(facts)
        db.execute("CREATE TEMP TABLE incoming AS SELECT * FROM raw WHERE 0")
        db.executemany("INSERT INTO incoming VALUES (" + ",".join("?" for _ in range(14)) + ")", facts)
        if links:
            db.execute("UPDATE incoming SET active=0")
        db.execute("INSERT OR IGNORE INTO raw SELECT * FROM incoming ORDER BY dedupe,seq")
        # Keep only extra copies; unique facts have no second row or key index.
        db.execute("""INSERT OR IGNORE INTO copies SELECT i.dedupe,i.file,i.seq,i.provider,i.session,i.model,
            i.bucket,i.offset,i.inp,i.cached,i.created,i.out,i.long_context,0
            FROM incoming i CROSS JOIN raw r USING(dedupe) WHERE i.file!=r.file OR i.seq!=r.seq""")
        if not links:
            self._add_hours(db, "SELECT i.* FROM incoming i CROSS JOIN raw r USING(dedupe) WHERE i.file=r.file AND i.seq=r.seq", 1)
            db.execute("INSERT OR IGNORE INTO dirty SELECT dedupe FROM copies WHERE file=? AND seq>=?", (key, seq))
        else:
            db.execute("INSERT OR IGNORE INTO dirty SELECT dedupe FROM incoming")
        if links:
            db.executemany("INSERT OR IGNORE INTO lineage VALUES (?,?,?,?,?,?,?,?)", links)
            db.execute("INSERT OR IGNORE INTO own_dirty SELECT l.owner,l.event FROM incoming i CROSS JOIN lineage l USING(dedupe) WHERE l.kind=0")
            db.execute("INSERT OR IGNORE INTO resolve_dirty SELECT l.owner,l.event FROM incoming i CROSS JOIN lineage l USING(dedupe) WHERE l.kind!=0")
            # New own events in a fork do not dirty an unchanged parent link.
            db.execute("""INSERT OR IGNORE INTO parent_dirty SELECT l.owner FROM incoming i CROSS JOIN lineage l USING(dedupe)
                LEFT JOIN parents p ON p.owner=l.owner WHERE l.parent IS NOT NULL AND p.parent IS NOT l.parent""")
        db.execute("DROP TABLE incoming")

    @staticmethod
    def _add_hours(db, query, sign):
        db.execute(f"""INSERT INTO hours SELECT provider,session,model,bucket,long_context,
            {sign}*SUM(inp),{sign}*SUM(cached),{sign}*SUM(created),{sign}*SUM(out),{sign}*COUNT(*),
            {sign}*SUM(inp+cached+created+out>0) FROM ({query})
            GROUP BY provider,session,model,bucket,long_context
            ON CONFLICT(provider,session,model,bucket,long_context) DO UPDATE SET
            inp=inp+excluded.inp,cached=cached+excluded.cached,created=created+excluded.created,
            out=out+excluded.out,records=records+excluded.records,positive_records=positive_records+excluded.positive_records""")

    def _reconcile(self, db, budget=None):
        self._lineage(db, budget)
        if db.execute("SELECT 1 FROM resolve_queue LIMIT 1").fetchone():
            return
        limit = 4096 if budget is not None else 50000
        db.execute("CREATE TEMP TABLE active_dirty AS SELECT key FROM dirty LIMIT ?", (limit,))
        # CROSS JOIN keeps a tiny changed-key set outside the large facts table.
        db.execute("""CREATE TEMP TABLE affected AS
            SELECT r.*,d.key canonical FROM active_dirty d CROSS JOIN raw r ON r.dedupe=d.key
                WHERE NOT EXISTS(SELECT 1 FROM lineage l WHERE l.dedupe=r.dedupe AND l.canonical!=d.key)
            UNION ALL SELECT r.*,d.key FROM active_dirty d CROSS JOIN lineage l ON l.canonical=d.key AND l.dedupe!=d.key
                CROSS JOIN raw r ON r.dedupe=l.dedupe
            UNION ALL SELECT c.*,d.key FROM active_dirty d CROSS JOIN copies c ON c.dedupe=d.key
                WHERE NOT EXISTS(SELECT 1 FROM lineage l WHERE l.dedupe=c.dedupe AND l.canonical!=d.key)
            UNION ALL SELECT c.*,d.key FROM active_dirty d CROSS JOIN lineage l ON l.canonical=d.key AND l.dedupe!=d.key
                CROSS JOIN copies c ON c.dedupe=l.dedupe""")
        self._add_hours(db, "SELECT * FROM affected WHERE active=1", -1)
        db.execute("""CREATE TEMP TABLE winners AS SELECT * FROM (
            SELECT a.*,ROW_NUMBER() OVER (PARTITION BY canonical ORDER BY f.ordering,a.seq) position,
                MIN(bucket) OVER (PARTITION BY canonical) lo,MAX(bucket) OVER (PARTITION BY canonical) hi
            FROM affected a JOIN files f ON f.id=a.file) WHERE position=1""")
        self._add_hours(db, "SELECT * FROM winners WHERE lo=hi", 1)
        for table in ("raw", "copies"):
            db.execute(f"UPDATE {table} SET active=0 WHERE active!=0 AND (dedupe,file,seq) IN (SELECT dedupe,file,seq FROM affected)")
            db.execute(f"UPDATE {table} SET active=1 WHERE (dedupe,file,seq) IN (SELECT dedupe,file,seq FROM winners WHERE lo=hi)")
            db.execute(f"UPDATE {table} SET active=-1 WHERE (dedupe,file,seq) IN (SELECT a.dedupe,a.file,a.seq FROM affected a JOIN winners w USING(canonical) WHERE w.lo!=w.hi)")
        db.execute("DELETE FROM hours WHERE (provider,session,model,bucket,long_context) IN (SELECT provider,session,model,bucket,long_context FROM affected) AND records=0")
        db.execute("DELETE FROM dirty WHERE key IN (SELECT key FROM active_dirty)")
        for table in ("active_dirty", "affected", "winners"):
            db.execute(f"DROP TABLE {table}")

    def _lineage(self, db, budget=None):
        if not any(db.execute(f"SELECT 1 FROM {t} LIMIT 1").fetchone() for t in ("own_dirty", "parent_dirty", "resolve_dirty", "resolve_queue")):
            return
        db.execute("DELETE FROM canonicals WHERE (owner,event) IN (SELECT owner,event FROM own_dirty)")
        db.execute("""INSERT INTO canonicals SELECT owner,event,dedupe FROM (
            SELECT l.owner,l.event,l.dedupe,ROW_NUMBER() OVER (PARTITION BY l.owner,l.event ORDER BY f.ordering,r.seq) position
            FROM own_dirty d CROSS JOIN lineage l ON l.owner=d.owner AND l.event=d.event AND l.kind=0
            CROSS JOIN raw r USING(dedupe) CROSS JOIN files f ON f.id=r.file) WHERE position=1""")
        db.execute("CREATE TEMP TABLE previous_parents AS SELECT * FROM parents WHERE owner IN (SELECT owner FROM parent_dirty)")
        db.execute("DELETE FROM parents WHERE owner IN (SELECT owner FROM parent_dirty)")
        db.execute("""INSERT INTO parents SELECT owner,parent FROM (
            SELECT l.owner,l.parent,ROW_NUMBER() OVER (PARTITION BY l.owner ORDER BY f.ordering,r.seq) position
            FROM parent_dirty d CROSS JOIN lineage l ON l.owner=d.owner AND l.parent IS NOT NULL
            CROSS JOIN raw r USING(dedupe) CROSS JOIN files f ON f.id=r.file) WHERE position=1""")
        db.execute("""DELETE FROM parent_dirty WHERE
            (SELECT parent FROM parents p WHERE p.owner=parent_dirty.owner) IS
            (SELECT parent FROM previous_parents p WHERE p.owner=parent_dirty.owner)""")
        db.execute("DROP TABLE previous_parents")
        db.execute("""INSERT OR IGNORE INTO resolve_queue SELECT owner,event FROM resolve_dirty
            UNION SELECT d.owner,d.event FROM own_dirty o CROSS JOIN dependencies d ON d.ancestor=o.owner AND d.event=o.event
            UNION SELECT d.owner,d.event FROM parent_dirty p CROSS JOIN dependencies d ON d.ancestor=p.owner""")
        for table in ("own_dirty", "parent_dirty", "resolve_dirty"):
            db.execute(f"DELETE FROM {table}")
        limit = 256 if budget is not None else 50000
        db.execute("CREATE TEMP TABLE resolving AS SELECT owner,event FROM resolve_queue LIMIT ?", (limit,))
        # One recursive traversal for the batch, including missing ancestors.
        # UNION, rather than UNION ALL, terminates cycles without Python trips.
        db.execute("""CREATE TEMP TABLE walks AS WITH RECURSIVE walk(owner,event,ancestor) AS (
            SELECT q.owner,q.event,l.parent FROM resolving q CROSS JOIN lineage l
                ON l.owner=q.owner AND l.event=q.event AND l.kind!=0 WHERE l.parent IS NOT NULL
            UNION SELECT w.owner,w.event,p.parent FROM walk w JOIN parents p ON p.owner=w.ancestor
                WHERE NOT EXISTS(SELECT 1 FROM canonicals c WHERE c.owner=w.ancestor AND c.event=w.event)
            ) SELECT * FROM walk""")
        db.execute("DELETE FROM dependencies WHERE (owner,event) IN (SELECT owner,event FROM resolving)")
        db.execute("INSERT OR IGNORE INTO dependencies SELECT ancestor,event,owner FROM walks")
        db.execute("""INSERT OR IGNORE INTO dependencies SELECT l.root,l.event,l.owner FROM resolving q CROSS JOIN lineage l
            ON l.owner=q.owner AND l.event=q.event AND l.kind!=0 WHERE l.root IS NOT NULL""")
        db.execute("CREATE INDEX walks_owner ON walks(owner,event)")
        db.execute("""CREATE TEMP TABLE resolved AS SELECT l.dedupe,l.canonical old,COALESCE(
            (SELECT c.dedupe FROM walks w CROSS JOIN canonicals c ON c.owner=w.ancestor AND c.event=w.event
                WHERE w.owner=l.owner AND w.event=l.event LIMIT 1),
            (SELECT c.dedupe FROM canonicals c WHERE c.owner=l.root AND c.event=l.event),l.fallback) canonical
            FROM resolving q CROSS JOIN lineage l ON l.owner=q.owner AND l.event=q.event AND l.kind!=0""")
        self.resolved_last_pass += db.execute("SELECT COUNT(*) FROM resolving").fetchone()[0]
        db.execute("INSERT OR IGNORE INTO dirty SELECT old FROM resolved WHERE old!=canonical")
        db.execute("INSERT OR IGNORE INTO dirty SELECT canonical FROM resolved WHERE old!=canonical")
        db.execute("CREATE INDEX resolved_key ON resolved(dedupe)")
        db.execute("UPDATE lineage SET canonical=(SELECT canonical FROM resolved r WHERE r.dedupe=lineage.dedupe) WHERE dedupe IN (SELECT dedupe FROM resolved WHERE old!=canonical)")
        db.execute("DELETE FROM resolve_queue WHERE (owner,event) IN (SELECT owner,event FROM resolving)")
        # Deleted events no longer provide parent or own evidence.
        db.execute("DELETE FROM lineage WHERE dedupe IN (SELECT l.dedupe FROM resolving q CROSS JOIN lineage l ON l.owner=q.owner AND l.event=q.event WHERE NOT EXISTS(SELECT 1 FROM raw r WHERE r.dedupe=l.dedupe))")
        for table in ("resolving", "walks", "resolved"):
            db.execute(f"DROP TABLE {table}")

    def _pending_totals(self, roots):
        totals = usage.UsageTotals()
        totals.source_coverage = {p: usage._CoverageState(p, root_present=True, root_walked=True, pending_files=1).finalize() for p in roots}
        return totals

    def _failed_totals(self, roots):
        totals = usage.UsageTotals()
        totals.source_coverage = {p: usage._CoverageState(p, root_present=True, unreadable_files=1).finalize() for p in roots}
        return totals

    def _recover(self, error):
        code = getattr(error, "sqlite_errorcode", None)
        code = code & 255 if isinstance(code, int) else None
        if code in {sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED, sqlite3.SQLITE_INTERRUPT}:
            return
        full = code == sqlite3.SQLITE_FULL
        damaged = code in {sqlite3.SQLITE_CORRUPT, sqlite3.SQLITE_NOTADB} or str(error) == "history cache quick_check failed"
        self.error = "disk_full" if full else "damaged" if damaged else "over_cap" if isinstance(error, HistorySizeLimit) else "failed"
        self.retry_at = time.monotonic() + (3600 if full else 60)
        if not self.scan_lock.acquire(timeout=0.05):
            return
        try:
            if self.writer is not None:
                self.writer.close()
                self.writer = None
            self.file_metadata.clear()
            self.strings.clear()
        finally:
            self.scan_lock.release()
        if damaged:
            # Preserve damaged bytes for diagnosis; never repeatedly rebuild a
            # damaged cache in the maintenance loop. Refuse unsafe leaves.
            from .private_io import _private_parent, _require_private_leaf
            try:
                with _private_parent(self.path) as (target, parent, name):
                    _require_private_leaf(target, parent, name)
                    for previous in target.parent.glob(name + ".damaged-*"):
                        if _require_private_leaf(previous, parent, previous.name) is not None:
                            os.unlink(previous.name, dir_fd=parent)
                    suffix = ".damaged-" + secrets.token_hex(6)
                    for ending in ("", "-wal", "-shm", "-journal"):
                        leaf = Path(str(target) + ending)
                        if _require_private_leaf(leaf, parent, leaf.name) is not None:
                            os.rename(leaf.name, name + suffix + ending, src_dir_fd=parent, dst_dir_fd=parent)
                self.checked_identity = None
            except OSError:
                pass

    def _reading_stale(self, provider):
        checked = self.checked_at.get(provider)
        if checked is None:
            try:
                checked = self.path.stat().st_mtime
            except OSError:
                return True
        return time.time() - checked > 120

    def _cached_totals(self, roots, since_epoch, *, card_only=False):
        if not self.path.exists() or time.monotonic() < self.retry_at:
            return None
        db = self._connect(read_only=True)
        if db is None:
            return None
        try:
            for provider, paths in roots.items():
                manifest = json.dumps([os.path.realpath(root) for root in paths])
                if db.execute("SELECT value FROM meta WHERE key=?", ("roots:" + provider,)).fetchone() != (manifest,):
                    return None
            totals = self._totals(db, roots, since_epoch, card_only=card_only)
            totals.history_stale = any(self._reading_stale(p) for p in roots)
            return totals
        finally:
            db.close()

    def scan(self, roots, *, since_epoch=0.0, budget=None, cached_only=False, source_bindings=None):
        if self._stopped() or not self.enabled:
            return usage.UsageTotals()
        try:
            if cached_only:
                return self._cached_totals(roots, since_epoch)
            if time.monotonic() < self.retry_at:
                return self._failed_totals(roots)
            if self.background_build:
                result = self._background_pass(roots, since_epoch, source_bindings)
                while result is not None and budget is None and self.child is not None:
                    if self.stopping.wait(0.05) or not self.enabled:
                        break
                    result = self._background_pass(roots, since_epoch, source_bindings)
                if result is not None:
                    return result
            if isinstance(budget, usage.ScanBudget):
                budget = usage.ScanBudget(min(budget._seconds, INCREMENTAL_CPU_SECONDS), time.thread_time)
            return self._incremental_pass(roots, since_epoch=since_epoch, budget=budget, source_bindings=source_bindings)
        except _RebuildRequired:
            with self.scan_lock:
                if not self._stopped() and self.enabled and self.child is None:
                    self._start_child(roots, source_bindings)
            return self._pending_totals(roots)
        except (OSError, ValueError, sqlite3.Error) as error:
            self._recover(error)
            return None if cached_only else self._failed_totals(roots)

    def _incremental_pass(self, roots, **kwargs):
        if self.builder:
            return self._scan(roots, **kwargs)
        lock_fd = _acquire_build_lock(self.path)
        if lock_fd is None:
            return self._pending_totals(roots)
        try:
            return self._scan(roots, **kwargs)
        finally:
            os.close(lock_fd)

    def _scan_inventory(self, provider, root):
        if self.background_build is not True:
            return _inventory(provider, root)
        cache_key = (provider, str(root))
        now = time.monotonic()
        cached = self.inventories.get(cache_key)
        stamps = self.directory_stamps.get(cache_key, {})
        refresh = cached is None or now - self.last_walk.get(cache_key, 0) >= 600
        if cached is not None and not stamps:
            refresh = refresh or root.exists() != cached.sources[0].coverage.root_present
        if not refresh:
            try:
                refresh = any(path.stat().st_mtime_ns != stamp for path, stamp in stamps.items())
            except OSError:
                refresh = True
        if not refresh:
            candidates = []
            for candidate in cached.sources[0].candidates:
                if candidate.info.st_mtime >= time.time() - 86400:
                    try:
                        candidate = replace(candidate, info=candidate.path.lstat())
                    except OSError:
                        refresh = True
                        break
                candidates.append(candidate)
            if not refresh:
                return replace(cached, sources=(replace(cached.sources[0], candidates=tuple(candidates)),))
        result = _inventory(provider, root)
        self.inventories[cache_key] = result
        self.last_walk[cache_key] = now
        directories = {Path(directory) for directory, _, _ in os.walk(root, followlinks=False)} if result.sources[0].coverage.root_walked else set()
        self.directory_stamps[cache_key] = {d: d.stat().st_mtime_ns for d in directories if not d.is_symlink()}
        return result

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
            return self._pending_totals(roots)
        try:
            if self._stopped() or not self.enabled:
                return usage.UsageTotals()
            db = self._connect()
            version = db.execute("PRAGMA data_version").fetchone()
            if version != self.writer_version:
                self.file_metadata = {key: (json.loads(meta) if meta else None, order, ident)
                                      for key, meta, order, ident in db.execute("SELECT key,metadata,ordering,id FROM files")}
                self.strings = dict(db.execute("SELECT value,id FROM strings"))
                self.next_seq = {ident: meta.get("next_seq", 0) for meta, _, ident in self.file_metadata.values() if meta}
                self.writer_version = version
            db.set_progress_handler(lambda: int(self._stopped() or not self.enabled), 1000)
            parse_budget = budget.share(2) if budget is not None else None
            self.resolved_last_pass = 0
            try:
                secret = bytes.fromhex(db.execute("SELECT value FROM meta WHERE key='secret'").fetchone()[0])
                coverage = {}
                changed = False
                rows_since_commit = 0
                for provider, binding in (source_bindings or {}).items():
                    key = "source:" + provider
                    encoded = json.dumps(binding, sort_keys=True)
                    previous = db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
                    if previous != (encoded,):
                        for (file,) in db.execute("SELECT id FROM files WHERE provider=?", (provider,)).fetchall():
                            self._remove(db, file)
                        db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, encoded))
                        changed = True
                cutoff = time.time() - RETENTION_SECONDS
                prune_day = str(int(cutoff // 86400))
                if db.execute("SELECT value FROM meta WHERE key='pruned'").fetchone() != (prune_day,):
                    for (file,) in db.execute("SELECT DISTINCT file FROM raw WHERE bucket<?", (int(cutoff // 900),)).fetchall():
                        # Files that still contain current events are reparsed once.
                        self._remove(db, file)
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
                        if self._stopped():
                            break
                        inventory = self._scan_inventory(provider, Path(root))
                        source = inventory.sources[0]
                        state = usage._CoverageState.from_coverage(source.coverage)
                        root_key = f"{provider}:{os.path.realpath(root)}"
                        present = set()
                        for candidate in sorted(source.candidates, key=lambda c: -c.info.st_mtime_ns):
                            if candidate.info.st_mtime < cutoff:
                                continue
                            key = root_key + ":" + usage._cache_file_key(provider, candidate.info)
                            file_key = key
                            saved = self.file_metadata.get(key)
                            if saved:
                                key = saved[2]
                            if not saved:
                                key = db.execute("INSERT INTO files(key,provider,root,ordering) VALUES (?,?,?,?) RETURNING id",
                                    (key, provider, root_key, "")).fetchone()[0]
                                self.file_metadata[file_key] = (None, "", key)
                            present.add(key)
                            entry = saved[0] if saved else None
                            info = candidate.info
                            suffix_rank = int(candidate.path.suffix != ".sqlite")
                            ordering = f"{root_rank:04}:{suffix_rank}:{candidate.path}"
                            sidecar = _sidecar_stamp(candidate.path)
                            if saved and saved[1] != ordering:
                                self._mark_file(db, key)
                                db.execute("UPDATE files SET ordering=? WHERE id=?", (ordering, key))
                                self.file_metadata[root_key + ":" + usage._cache_file_key(provider, info)] = (entry, ordering, key)
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
                                self._stopped()
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
                            if self.background_build is True and ((entry is not None and offset is None) or (entry is None and info.st_size > 1024 * 1024)):
                                raise _RebuildRequired()
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
                                if self.background_build is True and entry is not None:
                                    raise _RebuildRequired()
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
                            if not append and entry is not None:
                                self._delete_file_rows(db, key)
                            self._append(db, key, (row for row in result.records if row[3] >= cutoff))
                            metadata = {
                                "size": result.parsed_size,
                                "next_seq": self.next_seq.get(key, 0),
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
                            self.file_metadata[root_key + ":" + usage._cache_file_key(provider, info)] = (metadata, ordering, key)
                            state.files_read += 1
                            state.malformed_lines += metadata["malformed_lines"]
                            state.pending_files += int(result.stopped_early)
                            changed = True
                            db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", ("complete:" + provider, "False"))
                            rows_since_commit += len(result.records)
                            if rows_since_commit >= 50000:
                                db.commit()
                                if self.progress is not None:
                                    self.progress({"phase": "reading", "records": rows_since_commit})
                                rows_since_commit = 0
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
                if self._stopped() or not self.enabled:
                    db.commit()
                    return usage.UsageTotals()
                db.commit()
                if self.progress is not None and rows_since_commit:
                    self.progress({"phase": "reading", "records": rows_since_commit})
                if not self.file_index_ready:
                    db.execute("CREATE INDEX raw_file ON raw(file,seq)")
                    self.file_index_ready = True
                def pending():
                    return any(db.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone() for table in
                        ("dirty", "own_dirty", "parent_dirty", "resolve_dirty", "resolve_queue"))
                while pending() and (budget is None or not budget.expired()):
                    # Finish this small atomic chunk, then commit even when the CPU
                    # allowance has elapsed. Never throw away completed reconcile work.
                    db.set_progress_handler(lambda: int(self._stopped() or not self.enabled), 1000)
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
                    if not unfinished and source_coverage.pending_files == 0:
                        db.execute("INSERT OR IGNORE INTO meta VALUES (?, 'True')", ("built:" + provider,))
                    db.execute(
                        "INSERT INTO meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value!=excluded.value",
                        ("roots:" + provider, json.dumps([os.path.realpath(root) for root in roots[provider]])),
                    )
                db.commit()
                if changed:
                    db.execute("INSERT INTO meta VALUES ('generation','1') ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1")
                    db.commit()
                    self._clear_views()
                if not unfinished:
                    self._retire_legacy(db)
                totals = self._totals(db, roots, since_epoch)
                totals.source_coverage = coverage
                self.error = "failed" if any(c.status == usage.UsageSourceStatus.FAILED for c in coverage.values()) else None
                if self.error:
                    self.retry_at = time.monotonic() + 60
                for provider, state in coverage.items():
                    if state.pending_files == 0 and state.unreadable_files == 0:
                        self.checked_at[provider] = time.time()
                return totals
            except sqlite3.OperationalError:
                db.rollback()
                self.file_metadata.clear()
                self.writer_version = None
                if self._stopped() or not self.enabled:
                    return usage.UsageTotals()
                raise
            finally:
                if db.in_transaction:
                    db.commit()
        finally:
            self.scan_lock.release()

    def _retire_legacy(self, db):
        from .private_io import _private_parent, _require_private_leaf
        complete = {p for p in ("claude", "codex") if db.execute("SELECT value FROM meta WHERE key=?", ("complete:" + p,)).fetchone() == ("True",)}
        for prefix in ("usage-scan-cache.json", "provider-usage-cache.json"):
            for candidate in self.path.parent.glob(prefix + "*"):
                if candidate.name != prefix and not candidate.name.startswith((prefix + ".", prefix + ".home-")):
                    continue
                provider = "codex" if ".codex." in candidate.name else "claude"
                if provider not in complete:
                    continue
                try:
                    with _private_parent(candidate) as (target, parent, name):
                        info = _require_private_leaf(target, parent, name)
                        if info is not None and info.st_uid == os.getuid():
                            os.unlink(name, dir_fd=parent)
                except OSError:
                    pass

    def _card_records(self, db, roots, since_epoch):
        # UTC quarter hours align with present-day local timezone offsets.
        # Local days and hours are presentation only, never persisted.
        return self._read_view(db, roots, since_epoch)

    def _totals(self, db, roots, since_epoch, *, card_only=False):
        records = self._card_records(db, roots, since_epoch) if card_only else self._records(db, roots, since_epoch)
        totals = usage._totals_from_window(records)
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
        return self._read_view(db, roots, since_epoch)

    def _read_view(self, db, roots, since_epoch):
        if not self.lock.acquire(timeout=0.05):
            error = sqlite3.OperationalError("history view is busy")
            error.sqlite_errorcode = sqlite3.SQLITE_BUSY
            raise error
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
        view_key = (providers, since_epoch, tuple(time.tzname), time.timezone, os.environ.get("TZ"))
        existing = self.views.get(view_key)
        if existing is not None:
            return existing[0]
        names = dict(db.execute("SELECT id,value FROM strings"))
        ids = {ident for ident, value in names.items() if value in providers}
        records = []
        if not ids:
            return records
        start = datetime.fromtimestamp(since_epoch)
        marks = ",".join("?" for _ in ids)
        if since_epoch and (start.hour or start.minute or start.second or start.microsecond):
            query = f"""SELECT provider,session,model,bucket*900+offset,inp,cached,created,out,canonical,long_context FROM (
                SELECT r.*,COALESCE(l.canonical,r.dedupe) canonical,
                    ROW_NUMBER() OVER (PARTITION BY COALESCE(l.canonical,r.dedupe) ORDER BY f.ordering,r.seq) position
                FROM facts r JOIN files f ON f.id=r.file LEFT JOIN lineage l USING(dedupe)
                WHERE r.provider IN ({marks}) AND bucket*900+offset>=?) WHERE position=1"""
            for row in db.execute(query, (*ids, since_epoch)):
                records.append(BucketRecord((names[row[0]], names[row[1]], names[row[2]], *row[3:9]), 1, bool(row[9])))
        else:
            query = f"""SELECT provider,session,model,bucket,inp,cached,created,out,records,long_context,positive_records
                FROM hours WHERE provider IN ({marks}) AND bucket>=? AND records>0 ORDER BY bucket,model,session"""
            # Coalesce quarters into local hours without changing the database.
            grouped = {}
            for p, session, model, bucket, inp, cached, created, out, count, long, positive in db.execute(query, (*ids, int(since_epoch // 900))):
                hour = datetime.fromtimestamp(bucket * 900).replace(minute=0, second=0, microsecond=0).timestamp()
                key = (p, session, model, hour, long)
                values = grouped.setdefault(key, [0, 0, 0, 0, 0, 0])
                for i, value in enumerate((inp, cached, created, out, count, positive)):
                    values[i] += value
            for (p, session, model, hour, long), (inp, cached, created, out, count, positive) in grouped.items():
                records.append(BucketRecord((names[p], names[session], names[model], hour, inp, cached, created, out, f"{p}:{session}:{model}:{hour}:{long}"), count, bool(long), positive))
            query = f"""SELECT provider,session,model,bucket*900+offset,inp,cached,created,out,canonical,long_context FROM (
                SELECT r.*,COALESCE(l.canonical,r.dedupe) canonical,
                    ROW_NUMBER() OVER (PARTITION BY COALESCE(l.canonical,r.dedupe) ORDER BY f.ordering,r.seq) position
                FROM facts r JOIN files f ON f.id=r.file LEFT JOIN lineage l USING(dedupe)
                WHERE active=-1 AND r.provider IN ({marks}) AND bucket*900+offset>=?) WHERE position=1"""
            for row in db.execute(query, (*ids, since_epoch)):
                records.append(BucketRecord((names[row[0]], names[row[1]], names[row[2]], *row[3:9]), 1, bool(row[9])))
        size = sys.getsizeof(records) + 256
        for row in records:
            size += sys.getsizeof(row) + sys.getsizeof(vars(row))
            size += sum(sys.getsizeof(value) for value in row)
            size += sum(sys.getsizeof(key) + sys.getsizeof(value) for key, value in vars(row).items())
        if self._stopped() or not self.enabled:
            return []
        if size <= VIEW_BYTES:
            while self.views and self.view_bytes + size > VIEW_BYTES:
                _, (_, old_size) = self.views.popitem(last=False)
                self.view_bytes -= old_size
            self.views[view_key] = (records, size)
            self.view_bytes += size
        return records


_INDEXES = OrderedDict()
_INDEX_LOCK = threading.Lock()


def shared_index(path):
    """One byte-bounded view per daemon state directory, at most four roots."""
    with _INDEX_LOCK:
        key = str(path)
        index = _INDEXES.get(key)
        if index is None or index.stopping.is_set():
            index = TokenHistoryIndex(Path(path), background_build=True)
            _INDEXES[key] = index
        while len(_INDEXES) > 4:
            _, old = _INDEXES.popitem(last=False)
            old.close()
        return index


def scan_history(
    *, home=None, provider_ids=("claude", "codex"), since_epoch=0.0, budget=None, env=None, extras=None
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
        indexes = tuple(_INDEXES.values())
        for index in indexes:
            index.enabled = enabled
            if not enabled:
                index.stopping.set()
    if not enabled:
        for index in indexes:
            index.close()


def history_enabled():
    return _ENABLED


def history_state(home):
    from .state_paths import default_state_dir
    path = default_state_dir(None if Path(home) == Path.home() else home) / "token-history.sqlite3"
    index = shared_index(path)
    return index.error or "building"


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
        card = index.cards.get(card_key)
        return {**card, "history_stale": index._reading_stale(provider)} if card is not None else None
    try:
        totals = index._cached_totals(roots, usage.card_window_start(observed_at), card_only=True)
    except (OSError, ValueError, sqlite3.Error) as error:
        index._recover(error)
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
    if index.lock.acquire(timeout=0.05):
        try:
            index.cards[card_key] = document
            while len(index.cards) > 16:
                index.cards.popitem(last=False)
        finally:
            index.lock.release()
    if provider == "codex":
        document["windows"] = list(totals.codex_rate_limit_evidence)
        document["windows_observed_at"] = totals.codex_rate_limit_observed_at
    return document
