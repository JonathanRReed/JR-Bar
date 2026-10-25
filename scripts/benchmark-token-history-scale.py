#!/usr/bin/env python3
"""Measure synthetic token indexing, fork appends and 360 idle scans.

No provider home is read. Generation and imports are outside the CPU timer.
The idle run simulates six scans per minute for an hour, without waiting.
Cold work uses scan_provider_pass, the daemon entry point. A five-millisecond
ticker measures main-thread lateness while CPU burner processes run.
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
import uuid
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
                    "id": str(uuid.UUID(int=number + 1)), "model": "claude-sonnet-4-5", "usage": {
                        "input_tokens": 100, "cache_read_input_tokens": 20,
                        "cache_creation_input_tokens": 10, "output_tokens": 30}}}
                handle.write(json.dumps(row) + "\n")
    parent_start = now - timedelta(hours=3)
    events = [tokens((i + 1) * 100, (parent_start + timedelta(seconds=i)).isoformat()) for i in range(parent_count)]
    fork_start = parent_start + timedelta(seconds=parent_count + 60)
    for number in range(-1, forks):
        owner = "parent" if number == -1 else f"fork-{number}"
        stamp = parent_start - timedelta(seconds=60) if number == -1 else fork_start
        payload = {"id": str(uuid.UUID(int=number + 2)), "timestamp": stamp.isoformat()}
        if number != -1:
            payload["forked_from_id"] = str(uuid.UUID(int=1))
        with (codex_root / f"{owner}.jsonl").open("w") as handle:
            for row in [{"type": "session_meta", "timestamp": stamp.isoformat(), "payload": payload},
                        {"type": "turn_context", "payload": {"model": "gpt-6.1-sol"}}, *events]:
                handle.write(json.dumps(row) + "\n")
    return now, claude_count, codex_count, parent_count, fork_start


def summary(rows):
    return {"median": statistics.median(rows), "min": min(rows), "max": max(rows)}


def verify_golden(root):
    """Compare every public document field with the legacy record pipeline."""
    from jrbar import token_history_index as module
    from jrbar import usage_stats as usage
    from jrbar.core_usage_history import usage_history_document

    root = root.resolve()
    roots = {"claude": (root / ".claude/projects",), "codex": (root / ".codex/sessions",)}
    records = []
    for provider, paths in roots.items():
        for path in paths:
            for candidate in usage._provider_inventory(provider, path).sources[0].candidates:
                parser = usage._parse_file if provider == "claude" else usage._parse_codex_file
                records.extend(parser(candidate.path, candidate.info, b"s" * 32).records)
    canonical = usage._canonical_window_records(records, 0)
    del records
    now = datetime.now(timezone.utc).timestamp()
    expected = {p: usage_history_document(canonical, provider=p, range_name="365d", now=now) for p in roots}
    del canonical
    index = module.TokenHistoryIndex(root / "golden-state/history.sqlite3")
    try:
        totals = index.scan(roots)
        assert index.error is None, index.error
        actual = {p: usage_history_document(totals.records, provider=p, range_name="365d", now=now) for p in roots}
        assert actual == expected, {p: [k for k in actual[p] if actual[p][k] != expected[p][k]] for p in roots}
        return {"phase": "full_corpus_golden", "canonical_records": sum(d["records"] for d in actual.values()),
                "processed_tokens": sum(row["processed_tokens"] for d in actual.values() for row in d["days"]),
                "match": "all public document fields", "errors": 0}
    finally:
        index.close()


def measure(root, count, burners):
    import resource
    import subprocess
    import sys
    import threading

    from jrbar import token_history_index as module
    from jrbar.core_usage_history import PASS_PAUSE_SECONDS, scan_provider_pass
    from jrbar.state_paths import default_state_dir
    from jrbar.usage_stats import ScanBudget

    root = root.resolve()
    os.environ.update(HOME=str(root), XDG_STATE_HOME=str(root / 'state'), XDG_CONFIG_HOME=str(root / 'config'),
                      CLAUDE_CONFIG_DIR=str(root / '.claude'), CODEX_HOME=str(root / '.codex'))
    path = default_state_dir() / 'token-history.sqlite3'
    index = module.shared_index(path)
    baseline = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    stop = threading.Event()
    result = {}
    cpu_load = [subprocess.Popen([sys.executable, '-c', 'while True: sum(i*i for i in range(10000))'],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for _ in range(burners)]
    def build():
        try:
            builds, passes = [], 0
            records = {}
            for provider in ('claude', 'codex'):
                deadline = time.monotonic() + 600
                while time.monotonic() < deadline:
                    outcome = scan_provider_pass(provider, days=365, seconds=2.0)
                    passes += 1
                    if outcome.reading_files == 0:
                        records[provider] = sum(r.record_count for r in outcome.records)
                        if index.child_result is not None:
                            builds.append(index.child_result)
                        break
                    if index.error:
                        raise AssertionError(index.error)
                    stop.wait(PASS_PAUSE_SECONDS)
                else:
                    raise AssertionError('cold build timed out')
            result.update(builds=builds, passes=passes, canonical_records=sum(records.values()))
        except BaseException as exc:
            result['error'] = repr(exc)
        finally:
            stop.set()
    worker = threading.Thread(target=build)
    started_cpu, started_wall = time.process_time(), time.monotonic()
    worker.start()
    worst, late_counts = 0.0, {50: 0, 100: 0, 250: 0}
    last = time.perf_counter()
    try:
        while not stop.wait(0.005):
            now = time.perf_counter()
            late = (now - last - 0.005) * 1000
            last = now
            worst = max(worst, late)
            for limit in late_counts:
                late_counts[limit] += int(late > limit)
        worker.join(timeout=10)
        assert not worker.is_alive()
        assert 'error' not in result, result
        cold_daemon_cpu = time.process_time() - started_cpu
        cold_wall = time.monotonic() - started_wall
        cold_peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        forks, parent_count = (100, 1000) if count >= 102000 else (5, 100)
        claude_count = count - (forks + 1) * parent_count
        assert result['canonical_records'] == claude_count + parent_count, result
        with sqlite3.connect(path) as db:
            raw = db.execute('SELECT COUNT(*) FROM raw').fetchone()[0]
            copies = db.execute('SELECT COUNT(*) FROM copies').fetchone()[0]
            assert raw + copies == count
            assert db.execute('PRAGMA quick_check').fetchone() == ('ok',)
            assert sum(db.execute('SELECT SUM(inp+cached+created+out) FROM hours').fetchone()) == claude_count * 160 + parent_count * 100
        # Six real budgeted Codex passes and sixty new events per minute.
        codex_root = root / '.codex/sessions'
        current = parent_count * 100
        start = datetime.now(timezone.utc)
        active = []
        for minute in range(5):
            cpu = time.process_time()
            for refresh in range(6):
                with (codex_root / 'fork-0.jsonl').open('a') as handle:
                    for event in range(10):
                        current += 100
                        stamp = start + timedelta(seconds=minute * 60 + refresh * 10 + event)
                        handle.write(json.dumps(tokens(current, stamp.isoformat())) + '\n')
                while True:
                    totals = index.scan({'codex': (codex_root,)}, budget=ScanBudget(2))
                    if not any(c.pending_files for c in totals.source_coverage.values()):
                        break
                assert totals.codex_tokens == current, (totals.codex_tokens, current, index.error)
                assert index.resolved_last_pass == 0
            active.append(time.process_time() - cpu)
        roots = {'claude': (root / '.claude/projects',), 'codex': (codex_root,)}
        index.scan(roots, budget=ScanBudget(2))
        witness = sqlite3.connect(path)
        def stamp():
            return {ending: hashlib.sha256(p.read_bytes()).hexdigest() for ending in ('', '-wal')
                    if (p := Path(str(path) + ending)).exists()}
        before = stamp()
        version = witness.execute('PRAGMA data_version').fetchone()
        changes = index.writer.total_changes
        idle_cpu = time.process_time()
        for _ in range(360):
            totals = index.scan(roots, budget=ScanBudget(2))
            assert totals.codex_tokens == current
        idle_cpu = time.process_time() - idle_cpu
        assert index.writer.total_changes == changes
        assert witness.execute('PRAGMA data_version').fetchone() == version
        assert stamp() == before
        witness.close()
        index.close()
        return {**result, 'phase': 'real_budgeted_path', 'records': count,
                'database_bytes': path.stat().st_size, 'cold_daemon_cpu_seconds': cold_daemon_cpu,
                'cold_wall_seconds': cold_wall, 'cold_child_cpu_seconds': sum(b['cpu_seconds'] for b in result['builds']),
                'cold_daemon_peak_rss_bytes': cold_peak, 'cold_daemon_rss_increase_bytes': cold_peak - baseline,
                'cold_child_peak_rss_bytes': max(b['peak_rss_bytes'] for b in result['builds']),
                'main_thread_worst_lateness_ms': worst, 'late_counts_ms': late_counts, 'cpu_burners': burners,
                'active_cpu_seconds_per_simulated_minute': summary(active), 'active_samples': active,
                'idle_scans': 360, 'idle_cpu_seconds': idle_cpu, 'idle_changed_rows': 0,
                'idle_committed_bytes_per_simulated_hour': 0, 'errors': 0}
    finally:
        index.close()
        for process in cpu_load:
            process.terminate()
        for process in cpu_load:
            process.wait(timeout=5)


def main():
    import subprocess
    import sys
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--records', type=int, default=860000)
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--burners', type=int, default=4)
    parser.add_argument('--measure', type=Path)
    parser.add_argument('--fixture', type=Path)
    parser.add_argument('--golden', action='store_true')
    args = parser.parse_args()
    if args.measure:
        print(json.dumps(measure(args.measure, args.records, args.burners)), flush=True)
        return
    def run(folder):
        root = Path(folder).resolve()
        if args.fixture is None:
            generate(root, args.records)
        if args.golden:
            print(json.dumps(verify_golden(root)), flush=True)
        print(json.dumps({'corpus_records': args.records, 'identifier_length': 36,
                          'logical_cpus': os.cpu_count(), 'load_average': os.getloadavg(),
                          'transcript_bytes': sum(p.stat().st_size for p in root.rglob('*.jsonl'))}), flush=True)
        for run in range(args.runs):
            state = root / 'state/jrbar'
            for ending in ('', '-wal', '-shm'):
                (state / ('token-history.sqlite3' + ending)).unlink(missing_ok=True)
            process = subprocess.run([sys.executable, __file__, '--measure', str(root), '--records', str(args.records),
                                      '--burners', str(args.burners)], text=True, capture_output=True, timeout=1200)
            if process.returncode:
                raise RuntimeError(process.stderr + process.stdout)
            print(process.stdout.strip(), flush=True)
            # Return the fork to the cold corpus for the next measured run.
            fork = root / '.codex/sessions/fork-0.jsonl'
            lines = fork.read_bytes().splitlines(keepends=True)
            parent_count = 1000 if args.records >= 102000 else 100
            fork.write_bytes(b''.join(lines[:parent_count + 2]))
    if args.fixture:
        run(args.fixture)
    else:
        with tempfile.TemporaryDirectory(prefix='jrbar-scale-') as folder:
            run(folder)


if __name__ == '__main__':
    main()
