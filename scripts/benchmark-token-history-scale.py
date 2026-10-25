#!/usr/bin/env python3
"""Measure synthetic token indexing, fork appends and 360 idle scans.

No provider home is read. Generation and imports are outside the CPU timer.
The idle run simulates six scans per minute for an hour, without waiting.
Active timing completes each append; bounded passes have separate tests.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import statistics
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


def tokens(total, stamp):
    return {"type": "event_msg", "timestamp": stamp, "payload": {"type": "token_count", "info": {
        "total_token_usage": {"input_tokens": total, "output_tokens": 0},
        "last_token_usage": {"input_tokens": 100, "output_tokens": 0}}}}


def generate(root, count):
    now = datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0)
    forks, parent_count = (100, 1000) if count >= 102000 else (5, 100)
    codex_count = (forks + 1) * parent_count
    claude_count, old_count = count - codex_count, int(count * .6)
    assert claude_count >= old_count
    claude_root, codex_root = root / ".claude/projects", root / ".codex/sessions"
    claude_root.mkdir(parents=True)
    codex_root.mkdir(parents=True)
    for batch in range((claude_count + 999) // 1000):
        with (claude_root / f"{batch:04}.jsonl").open("w") as handle:
            for number in range(batch * 1000, min((batch + 1) * 1000, claude_count)):
                days = 31 + batch % 300 if number < old_count else batch % 29
                row = {"type": "assistant", "timestamp": (now - timedelta(days=days)).isoformat(), "message": {
                    "id": f"synthetic-{number}", "model": "claude-sonnet-4-5", "usage": {
                        "input_tokens": 100, "cache_read_input_tokens": 20,
                        "cache_creation_input_tokens": 10, "output_tokens": 30}}}
                handle.write(json.dumps(row) + "\n")
    parent_start = now - timedelta(hours=3)
    events = [tokens((i + 1) * 100, (parent_start + timedelta(seconds=i)).isoformat()) for i in range(parent_count)]
    fork_start = parent_start + timedelta(seconds=parent_count + 60)
    for number in range(-1, forks):
        owner = "parent" if number == -1 else f"fork-{number}"
        stamp = parent_start - timedelta(seconds=60) if number == -1 else fork_start
        payload = {"id": owner, "timestamp": stamp.isoformat()}
        if number != -1:
            payload["forked_from_id"] = "parent"
        with (codex_root / f"{owner}.jsonl").open("w") as handle:
            for row in [{"type": "session_meta", "timestamp": stamp.isoformat(), "payload": payload},
                        {"type": "turn_context", "payload": {"model": "gpt-6.1-sol"}}, *events]:
                handle.write(json.dumps(row) + "\n")
    return now, claude_count, codex_count, parent_count, fork_start


def summary(rows):
    return {"median": statistics.median(rows), "min": min(rows), "max": max(rows)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--records", type=int, default=860000)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--profile")
    args = parser.parse_args()
    from jrbar import token_history_index as module
    from jrbar.core_usage_history import usage_history_document
    with tempfile.TemporaryDirectory(prefix="jrbar-scale-") as folder:
        root = Path(folder)
        os.environ.update(HOME=str(root), XDG_STATE_HOME=str(root / "state"), XDG_CONFIG_HOME=str(root / "config"))
        now, claude_count, codex_count, parent_count, fork_start = generate(root, args.records)
        roots = {"claude": (root / ".claude/projects",), "codex": (root / ".codex/sessions",)}
        path = root / "state/history.sqlite3"
        print(json.dumps({"corpus_records": args.records, "claude_records": claude_count,
            "codex_records": codex_count, "older_than_30d": int(args.records * .6),
            "transcript_bytes": sum(p.stat().st_size for p in root.rglob("*.jsonl")),
            "logical_cpus": os.cpu_count(), "load_average": os.getloadavg()}), flush=True)
        cold = []
        for run in range(args.runs):
            for suffix in ("", "-wal", "-shm"):
                Path(str(path) + suffix).unlink(missing_ok=True)
            index = module.TokenHistoryIndex(path)
            cpu, wall = time.process_time(), time.monotonic()
            totals = index.scan(roots)
            elapsed, wall_elapsed = time.process_time() - cpu, time.monotonic() - wall
            with sqlite3.connect(path) as db:
                raw = db.execute("SELECT COUNT(*) FROM raw").fetchone()[0]
                canonical = db.execute("SELECT COUNT(*) FROM events").fetchone()[0]
                assert db.execute("PRAGMA quick_check").fetchone() == ("ok",)
            assert raw == args.records, (raw, index.error)
            assert canonical == claude_count + parent_count, canonical
            assert totals.input_tokens == claude_count * 100
            assert totals.codex_tokens == parent_count * 100
            documents = [usage_history_document(totals.records, provider=p, range_name="365d", now=now.timestamp()) for p in roots]
            assert sum(d["records"] for d in documents) == canonical
            assert sum(r["processed_tokens"] for d in documents for r in d["days"]) == claude_count * 160 + parent_count * 100
            row = {"phase": "cold", "run": run, "cpu_seconds": elapsed, "wall_seconds": wall_elapsed,
                   "database_bytes": path.stat().st_size, "raw_records": raw, "canonical_records": canonical}
            cold.append(elapsed)
            print(json.dumps(row), flush=True)
        if args.profile:
            import cProfile
            profile_path = root / "state/profile.sqlite3"
            profiler = cProfile.Profile()
            profiler.runcall(module.TokenHistoryIndex(profile_path).scan, roots)
            profiler.dump_stats(args.profile)
        active = []
        current_total = parent_count * 100
        for minute in range(5):
            cpu = time.process_time()
            for refresh in range(6):
                with (roots["codex"][0] / "fork-0.jsonl").open("a") as handle:
                    for event in range(10):
                        current_total += 100
                        stamp = fork_start + timedelta(seconds=60 + minute * 60 + refresh * 10 + event)
                        handle.write(json.dumps(tokens(current_total, stamp.isoformat())) + "\n")
                totals = index.scan({"codex": roots["codex"]})
                assert totals.codex_tokens == current_total, (totals.codex_tokens, current_total, index.error)
                assert index.resolved_last_pass == 0
            active.append(time.process_time() - cpu)
        # A witness connection keeps the WAL open. Row changes, data_version
        # and exact database/WAL bytes distinguish no growth from no writes.
        index.scan(roots)
        witness = index._connect()
        def stamp():
            return {suffix: (p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest())
                    for suffix in ("", "-wal") if (p := Path(str(path) + suffix)).exists()}
        before = stamp()
        version = witness.execute("PRAGMA data_version").fetchone()
        changed_rows = []
        class CountedConnection(sqlite3.Connection):
            def close(self):
                changed_rows.append(self.total_changes)
                super().close()
        real_connect = module.sqlite3.connect
        def counted(*a, **kw):
            return real_connect(*a, **kw, factory=CountedConnection)
        module.sqlite3.connect = counted
        idle_cpu = time.process_time()
        try:
            for _ in range(360):
                assert index.scan(roots).codex_tokens == current_total
        finally:
            module.sqlite3.connect = real_connect
        idle_cpu = time.process_time() - idle_cpu
        assert sum(changed_rows) == 0, (sum(changed_rows), max(changed_rows), len([n for n in changed_rows if n]))
        assert witness.execute("PRAGMA data_version").fetchone() == version
        assert stamp() == before
        witness.close()
        print(json.dumps({"summary": "scale", "cold_cpu_seconds": summary(cold),
            "database_bytes": path.stat().st_size, "bytes_per_raw_record": path.stat().st_size / args.records,
            "active_cpu_seconds_per_simulated_minute": summary(active),
            "active_scans_per_minute": 6, "active_providers": ["codex"], "active_new_events_per_minute": 60,
            "idle_scans": 360, "idle_cpu_seconds": idle_cpu,
            "idle_changed_rows": sum(changed_rows), "idle_committed_database_bytes_per_simulated_hour": 0,
            "idle_proof": "unchanged data_version and exact DB/WAL hashes, zero total_changes",
            "errors": 0}), flush=True)


if __name__ == "__main__":
    main()
