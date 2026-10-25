"""Real child builds and the daemon's budgeted entry point, synthetic homes only."""
from __future__ import annotations

import json
import sqlite3

from jrbar import token_history_index as history
from jrbar import usage_stats as usage
from tests.test_token_history_index import claude


def finish(index, roots):
    assert index.child is not None
    index.child.wait(timeout=30)
    totals = index.scan(roots, budget=usage.ScanBudget(2))
    assert index.child is None
    assert index.error is None
    return totals


def test_real_budgeted_cold_scan_uses_a_utility_process_and_reopens(tmp_path):
    root = tmp_path / 'transcripts'
    root.mkdir()
    (root / 'one.jsonl').write_text(claude('one', '2026-10-25T01:00:00Z'))
    path = tmp_path / 'state/history.sqlite3'
    index = history.TokenHistoryIndex(path, background_build=True)
    roots = {'claude': (root,)}
    try:
        first = index.scan(roots, budget=usage.ScanBudget(2))
        assert first.source_coverage['claude'].pending_files == 1
        assert index.writer is None
        assert finish(index, roots).input_tokens == 100
        assert index.child_result['phase'] == 'done'
        assert index.child_result['cpu_seconds'] > 0
        import sys
        if sys.platform == 'darwin':
            assert index.child_result['qos'] == 0x11
        with (root / 'one.jsonl').open('a') as handle:
            handle.write(claude('two', '2026-10-25T02:00:00Z'))
        assert index.scan(roots, budget=usage.ScanBudget(2)).input_tokens == 200
        assert index.child is None
        writer = index.writer
        index.scan(roots, budget=usage.ScanBudget(2))
        assert index.writer is writer
        assert writer.execute('PRAGMA temp_store').fetchone() == (1,)
        assert writer.execute('PRAGMA cache_size').fetchone() == (-6144,)
        (root / 'one.jsonl').write_text(claude('rewritten', '2026-10-25T03:00:00Z', inp=400))
        assert index.scan(roots, budget=usage.ScanBudget(2)).source_coverage['claude'].pending_files == 1
        assert finish(index, roots).input_tokens == 400
    finally:
        index.close()


def test_disable_terminates_the_owned_child(tmp_path):
    root = tmp_path / 'transcripts'
    root.mkdir()
    index = history.TokenHistoryIndex(tmp_path / 'state/history.sqlite3', background_build=True)
    index.scan({'claude': (root,)}, budget=usage.ScanBudget(2))
    child = index.child
    index.close()
    assert child.poll() is not None
    assert index.child is None


def test_timezone_change_writes_nothing_and_short_scans_do_not_mark_stale(tmp_path, monkeypatch):
    import time
    root = tmp_path / 'transcripts'
    root.mkdir()
    (root / 'one.jsonl').write_text(claude('one', '2026-10-25T01:00:00Z'))
    index = history.TokenHistoryIndex(tmp_path / 'state/history.sqlite3', background_build=False)
    roots = {'claude': (root,)}
    original = __import__('os').environ.get('TZ')
    try:
        index.scan(roots)
        with sqlite3.connect(index.path) as witness:
            before = witness.execute('PRAGMA data_version').fetchone()
            changes = index.writer.total_changes
            monkeypatch.setenv('TZ', 'Asia/Kathmandu')
            time.tzset()
            index.scan(roots)
            assert index.writer.total_changes == changes
            assert witness.execute('PRAGMA data_version').fetchone() == before
            index.writer.execute("UPDATE meta SET value='False' WHERE key='complete:claude'")
            index.writer.commit()
            with index.scan_lock:
                assert index._cached_totals(roots, 0).history_stale is False
            monkeypatch.setattr(index, 'checked_at', {'claude': time.time() - 121})
            assert index._cached_totals(roots, 0).history_stale is True
    finally:
        if original is None:
            monkeypatch.delenv('TZ', raising=False)
        else:
            monkeypatch.setenv('TZ', original)
        time.tzset()
        index.close()


def test_over_cap_is_not_damage_and_damage_retains_only_one_copy(tmp_path, monkeypatch):
    path = tmp_path / 'state/history.sqlite3'
    path.parent.mkdir()
    path.write_bytes(b'not a database')
    index = history.TokenHistoryIndex(path, background_build=False)
    monkeypatch.setattr(history, 'MAX_DATABASE_BYTES', 2)
    assert index.scan({}).records == []
    assert index.error == 'over_cap'
    assert path.exists()
    assert not list(path.parent.glob('*.damaged-*'))
    monkeypatch.setattr(history, 'MAX_DATABASE_BYTES', 4 * 1024**3)
    for _ in range(2):
        index.retry_at = 0
        path.write_bytes(b'damaged synthetic database')
        index.scan({})
        assert index.error == 'damaged'
        assert len(list(path.parent.glob('*.damaged-*'))) == 1


def test_quota_tail_skips_each_malformed_or_non_object_line(tmp_path, monkeypatch):
    from jrbar.provider_usage_codex_claude import _codex_windows_only
    root = tmp_path / '.codex/sessions'
    root.mkdir(parents=True)
    good = {'payload': {'rate_limits': {'primary': {'used_percent': 40, 'window_minutes': 300, 'resets_at': 1792933200}}}}
    (root / 'one.jsonl').write_text(json.dumps(good) + '\n["rate_limits"]\n{"rate_limits":\n')
    monkeypatch.setenv('CODEX_HOME', str(root.parent))
    result = _codex_windows_only(tmp_path)
    assert result['windows'][0]['used_percent'] == 40


def test_cpu_budget_preserves_committed_reconcile_chunks(tmp_path, monkeypatch):
    root = tmp_path / 'transcripts'
    root.mkdir()
    (root / 'one.jsonl').write_text(claude('one', '2026-10-25T01:00:00Z'))
    (root / 'two.jsonl').write_text(claude('one', '2026-10-25T02:00:00Z'))
    index = history.TokenHistoryIndex(tmp_path / 'state/history.sqlite3', background_build=False)
    index.scan({'claude': (root,)})
    (root / 'two.jsonl').write_text(claude('one', '2026-10-25T03:00:00Z'))
    class Budget:
        stopped = False
        def share(self, _parts):
            return self
        def expired(self):
            return self.stopped
    budget = Budget()
    reconcile = index._reconcile
    def expire_after(db, allowance):
        reconcile(db, allowance)
        budget.stopped = True
    monkeypatch.setattr(index, '_reconcile', expire_after)
    totals = index.scan({'claude': (root,)}, budget=budget)
    assert totals.input_tokens == 100
    assert index.writer.execute('SELECT COUNT(*) FROM dirty').fetchone() == (0,)
    index.close()


def test_legacy_cache_retirement_is_per_provider(tmp_path):
    root = tmp_path / 'transcripts'
    root.mkdir()
    path = tmp_path / 'state/history.sqlite3'
    path.parent.mkdir()
    claude_cache = path.parent / 'usage-scan-cache.json'
    codex_cache = path.parent / 'usage-scan-cache.json.codex.synthetic'
    claude_cache.write_text('{}')
    codex_cache.write_text('{}')
    index = history.TokenHistoryIndex(path, background_build=False)
    try:
        index.scan({'claude': (root,)})
        assert not claude_cache.exists()
        assert codex_cache.exists()
        index.scan({'codex': (root,)})
        assert not codex_cache.exists()
    finally:
        index.close()


def test_rebuild_reclaims_the_previous_schema_file(tmp_path):
    path = tmp_path / 'state/history.sqlite3'
    path.parent.mkdir()
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE old_layout (payload BLOB)')
        db.executemany('INSERT INTO old_layout VALUES (?)', [(b'x' * 4096,)] * 1000)
    before = path.stat().st_size
    index = history.TokenHistoryIndex(path, background_build=True)
    roots = {'claude': (tmp_path / 'missing',)}
    try:
        index.scan(roots, budget=usage.ScanBudget(2))
        finish(index, roots)
        index.close()
        assert path.stat().st_size < before / 2
    finally:
        index.close()


def test_a_large_single_file_commits_offsets_and_resumes_after_stop(tmp_path):
    root = tmp_path / 'transcripts'
    root.mkdir()
    count = 51000
    (root / 'one.jsonl').write_text(''.join(claude(str(i), '2026-10-25T01:00:00Z') for i in range(count)))
    index = history.TokenHistoryIndex(tmp_path / 'state/history.sqlite3', background_build=False)
    index.progress = lambda _: index.stopping.set()
    index.scan({'claude': (root,)})
    index.close()
    with sqlite3.connect(index.path) as db:
        committed = db.execute('SELECT COUNT(*) FROM raw').fetchone()[0]
        assert 0 < committed < count
        metadata = json.loads(db.execute('SELECT metadata FROM files').fetchone()[0])
        assert metadata['next_seq'] == committed
        assert 'stat_size' not in metadata
    resumed = history.TokenHistoryIndex(index.path, background_build=False)
    try:
        while True:
            totals = resumed.scan({'claude': (root,)})
            if not totals.source_coverage['claude'].pending_files:
                break
        assert totals.input_tokens == count * 100
        assert sum(r.record_count for r in totals.records) == count
    finally:
        resumed.close()


def test_an_expired_pass_remembers_unparsed_files(tmp_path):
    root = tmp_path / 'transcripts'
    root.mkdir()
    (root / 'one.jsonl').write_text(claude('one', '2026-10-25T01:00:00Z'))
    index = history.TokenHistoryIndex(tmp_path / 'state/history.sqlite3', background_build=False)
    try:
        first = index.scan({'claude': (root,)}, budget=usage.ScanBudget(0))
        assert first.source_coverage['claude'].pending_files == 1
        assert index.scan({'claude': (root,)}).input_tokens == 100
        assert index.error is None
    finally:
        index.close()


def test_removing_an_own_event_retracts_its_lineage(tmp_path):
    from tests.test_codex_usage_lineage import _meta, _tokens, _write
    root = tmp_path / 'codex'
    path = root / 'one.jsonl'
    _write(path, [_meta('one'), _tokens(100, 100, '2026-10-25T10:00:00Z')])
    index = history.TokenHistoryIndex(tmp_path / 'state/history.sqlite3', background_build=False)
    try:
        assert index.scan({'codex': (root,)}).codex_tokens == 100
        path.unlink()
        assert index.scan({'codex': (root,)}).codex_tokens == 0
        assert index.writer.execute('SELECT COUNT(*) FROM lineage').fetchone() == (0,)
        assert index.writer.execute('SELECT COUNT(*) FROM canonicals').fetchone() == (0,)
    finally:
        index.close()


def test_directory_changes_discover_new_files_between_full_walks(tmp_path):
    root = tmp_path / 'transcripts'
    nested = root / 'empty'
    nested.mkdir(parents=True)
    index = history.TokenHistoryIndex(tmp_path / 'state/history.sqlite3', background_build=True)
    roots = {'claude': (root,)}
    try:
        assert index.scan(roots).input_tokens == 0
        assert index.scan(roots).input_tokens == 0
        (nested / 'one.jsonl').write_text(claude('one', '2026-10-25T01:00:00Z'))
        assert index.scan(roots).input_tokens == 100
        assert index.child is None
    finally:
        index.close()


def test_a_finished_partial_build_does_not_spawn_again(tmp_path):
    root = tmp_path / 'transcripts'
    root.mkdir()
    (root / 'one.jsonl').write_text(claude('one', '2026-10-25T01:00:00Z') + '{"usage":broken}\n')
    index = history.TokenHistoryIndex(tmp_path / 'state/history.sqlite3', background_build=True)
    roots = {'claude': (root,)}
    try:
        assert index.scan(roots).input_tokens == 100
        assert index.child is None
        assert index.scan(roots).input_tokens == 100
        assert index.child is None
        assert index._cached_totals(roots, 0).history_stale is False
    finally:
        index.close()
