"""Synthetic history only. No provider configuration or real home is read."""

import json
from datetime import datetime

from jrbar import usage_stats as usage
from jrbar.core_usage_history import usage_history_document
from jrbar.token_history_index import TokenHistoryIndex


def claude(ident, stamp, *, inp=100, model="claude-sonnet-4-5"):
    return (
        json.dumps(
            {
                "type": "assistant",
                "timestamp": stamp,
                "message": {
                    "id": ident,
                    "model": model,
                    "usage": {
                        "input_tokens": inp,
                        "cache_read_input_tokens": 20,
                        "cache_creation_input_tokens": 10,
                        "output_tokens": 30,
                    },
                },
            }
        )
        + "\n"
    )


def legacy(roots):
    records = []
    for provider, paths in roots.items():
        for root in paths:
            source = usage._provider_inventory(provider, root).sources[0]
            for candidate in source.candidates:
                parser = usage._parse_file if provider == "claude" else usage._parse_codex_file
                records.extend(parser(candidate.path, candidate.info, b"s" * 32).records)
    return usage._canonical_window_records(records, 0)


def compare(index, roots, now):
    old = legacy(roots)
    totals = index.scan(roots)
    for provider in roots:
        expected = usage_history_document(old, provider=provider, range_name="30d", now=now)
        actual = usage_history_document(totals.records, provider=provider, range_name="30d", now=now)
        assert actual == expected
    return totals


def test_rewrite_rotation_duplicates_and_append(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    root = tmp_path / "transcripts"
    root.mkdir()
    first = root / "a.jsonl"
    first.write_text(claude("one", "2026-10-25T01:00:00Z"))
    copy = root / "b.jsonl"
    copy.write_text(first.read_text() + claude("two", "2026-10-25T02:00:00Z"))
    roots = {"claude": (root,)}
    now = datetime.fromisoformat("2026-10-25T12:00:00+00:00").timestamp()
    index = TokenHistoryIndex(tmp_path / "state" / "history.sqlite3")
    compare(index, roots, now)
    with first.open("a") as file:
        file.write(claude("three", "2026-10-25T03:00:00Z"))
    compare(index, roots, now)
    first.rename(root / "z.jsonl")
    compare(index, roots, now)
    copy.write_text(claude("four", "2026-10-25T04:00:00Z", inp=240_000))
    compare(index, roots, now)
    copy.unlink()
    compare(index, roots, now)
    # Unchanged opens perform no parser work, even in a new index instance.
    monkeypatch.setattr(usage, "_parse_file", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("reparsed")))
    TokenHistoryIndex(index.path).scan(roots)


def test_codex_forks_copies_late_ancestor_and_tail(tmp_path):
    from tests.test_codex_usage_lineage import _meta, _tokens, _write

    root = tmp_path / "codex"
    parent = _tokens(100, 100, "2026-10-25T10:00:00Z")
    child = _tokens(140, 40, "2026-10-25T10:01:00Z")
    grand = _tokens(170, 30, "2026-10-25T10:02:00Z")
    _write(
        root / "child.jsonl", [_meta("child", forked_from_id="parent", timestamp="2026-10-25T10:00:30Z"), parent, child]
    )
    _write(
        root / "grand.jsonl",
        [
            _meta("grand", forked_from_id="child", parent_thread_id="parent", timestamp="2026-10-25T10:01:30Z"),
            parent,
            child,
            grand,
        ],
    )
    now = datetime.fromisoformat("2026-10-25T12:00:00+00:00").timestamp()
    roots = {"codex": (root,)}
    index = TokenHistoryIndex(tmp_path / "state" / "index.sqlite3")
    compare(index, roots, now)
    _write(root / "parent.jsonl", [_meta("parent", timestamp="2026-10-25T09:00:00Z"), parent])
    compare(index, roots, now)
    _write(root / "copy.jsonl", [_meta("parent", timestamp="2026-10-25T09:00:00Z"), parent])
    compare(index, roots, now)
    with (root / "grand.jsonl").open("a") as file:
        file.write(json.dumps(_tokens(190, 20, "2026-10-25T10:03:00Z")) + "\n")
    totals = compare(index, roots, now)
    assert totals.codex_tokens == 190
    (root / "parent.jsonl").unlink()
    compare(index, roots, now)


def test_dst_and_local_day_boundaries(tmp_path, monkeypatch):
    import time

    old = __import__("os").environ.get("TZ")
    monkeypatch.setenv("TZ", "America/Chicago")
    time.tzset()
    try:
        root = tmp_path / "claude"
        root.mkdir()
        # Both occurrences of 01:30 during fall-back, plus local midnight.
        (root / "one.jsonl").write_text(
            "".join(
                claude(str(i), stamp)
                for i, stamp in enumerate(
                    [
                        "2026-11-01T04:59:59Z",
                        "2026-11-01T05:00:00Z",
                        "2026-11-01T06:30:00Z",
                        "2026-11-01T07:30:00Z",
                    ]
                )
            )
        )
        now = datetime.fromisoformat("2026-11-01T12:00:00+00:00").timestamp()
        index = TokenHistoryIndex(tmp_path / "state" / "index.sqlite3")
        totals = compare(index, {"claude": (root,)}, now)
        assert sum(r.record_count for r in totals.records) == 4
    finally:
        if old is None:
            monkeypatch.delenv("TZ", raising=False)
        else:
            monkeypatch.setenv("TZ", old)
        time.tzset()


def test_parser_version_rebuild_and_copied_homes(tmp_path, monkeypatch):
    root = tmp_path / "primary"
    extra = tmp_path / "extra"
    root.mkdir()
    extra.mkdir()
    (root / "one.jsonl").write_text(claude("same", "2026-10-25T01:00:00Z"))
    (extra / "copy.jsonl").write_text((root / "one.jsonl").read_text())
    index = TokenHistoryIndex(tmp_path / "state" / "index.sqlite3")
    now = datetime.fromisoformat("2026-10-25T12:00:00+00:00").timestamp()
    compare(index, {"claude": (root, extra)}, now)
    monkeypatch.setattr(usage, "CACHE_VERSION", usage.CACHE_VERSION + 1)
    totals = compare(index, {"claude": (root, extra)}, now)
    assert sum(row.record_count for row in totals.records) == 1
    # Removing an extra home retracts its unique contributions.
    (extra / "unique.jsonl").write_text(claude("unique", "2026-10-25T02:00:00Z"))
    compare(index, {"claude": (root, extra)}, now)
    compare(index, {"claude": (root,)}, now)


def test_window_filter_precedes_deduplication(tmp_path):
    root = tmp_path / "claude"
    root.mkdir()
    (root / "a.jsonl").write_text(claude("same", "2026-08-01T01:00:00Z"))
    (root / "b.jsonl").write_text(claude("same", "2026-10-25T01:00:00Z"))
    now = datetime.fromisoformat("2026-10-25T12:00:00+00:00").timestamp()
    since = usage.card_window_start(now)
    roots = {"claude": (root,)}
    source = usage._provider_inventory("claude", root).sources[0]
    raw = [row for file in source.candidates for row in usage._parse_file(file.path, file.info, b"x" * 32).records]
    expected = usage_history_document(
        usage._canonical_window_records(raw, since), provider="claude", range_name="30d", now=now
    )
    index = TokenHistoryIndex(tmp_path / "state" / "index.sqlite3")
    actual = usage_history_document(
        index.scan(roots, since_epoch=since).records, provider="claude", range_name="30d", now=now
    )
    assert actual == expected


def test_off_starts_no_history_work(tmp_path, monkeypatch):
    from types import SimpleNamespace

    import pytest

    from jrbar import core_runtime, provider_usage_codex_claude, token_history_index
    from jrbar.core_server import CommandError
    from jrbar.core_usage_history import UsageHistoryService

    def forbidden(*args, **kwargs):
        raise AssertionError("history work while off")

    monkeypatch.setattr(core_runtime.threading, "Thread", forbidden)
    monkeypatch.setattr(token_history_index, "_ENABLED", True)
    monkeypatch.setattr(token_history_index, "_INDEXES", {})
    owner = SimpleNamespace(settings=SimpleNamespace(token_history_enabled=False))
    core_runtime._usage_history_warm_later(owner)
    for command in (core_runtime._cmd_usage_history, core_runtime._cmd_usage_graph):
        with pytest.raises(CommandError) as caught:
            command(owner, {})
        assert caught.value.code == "disabled"
    with pytest.raises(CommandError) as caught:
        core_runtime._cmd_session_usage(owner, {})
    assert caught.value.code == "invalid_value"
    monkeypatch.setattr(provider_usage_codex_claude, "_codex_windows_only", lambda home: {"windows": []})
    monkeypatch.setattr(usage, "_provider_inventory", forbidden)
    assert token_history_index.scan_history(home=tmp_path).records == []
    assert provider_usage_codex_claude._default_provider_local_scan("codex", tmp_path, 1) == {"windows": []}
    assert provider_usage_codex_claude._cached_provider_local_scan("claude", tmp_path, 1) is None
    service = UsageHistoryService(forbidden, enabled=lambda: False, thread_factory=forbidden)
    service.warm()
    assert not service.is_scanning()
    assert not list(tmp_path.iterdir())


def test_card_and_history_share_index_without_transcript_reads(tmp_path, monkeypatch):
    from jrbar import provider_homes, token_history_index

    root = tmp_path / ".claude" / "projects"
    root.mkdir(parents=True)
    (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
    now = datetime.fromisoformat("2026-10-25T12:00:00+00:00").timestamp()
    monkeypatch.setattr(provider_homes, "configured_extra_homes", lambda: {})
    monkeypatch.setattr(token_history_index, "_ENABLED", True)
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    path = tmp_path / ".local" / "state" / "jrbar" / "token-history.sqlite3"
    index = token_history_index.shared_index(path)
    index.scan({"claude": (root,)}, since_epoch=usage.card_window_start(now))
    monkeypatch.setattr(usage, "_provider_inventory", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("walk")))
    card = token_history_index.cached_card("claude", tmp_path, now)
    assert card["input_tokens"] == 100
    assert card["cached_input_tokens"] == 20
    assert card["output_tokens"] == 30
    monkeypatch.setattr(index, "_records", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("session view rebuilt for card")))
    assert token_history_index.cached_card("claude", tmp_path, now)["input_tokens"] == 100
    assert len(index.views) == 1
    assert index.view_bytes <= token_history_index.VIEW_BYTES


def test_same_size_rewrite_with_restored_mtime_is_reparsed(tmp_path):
    import os

    root = tmp_path / "claude"
    root.mkdir()
    path = root / "one.jsonl"
    path.write_text(claude("same", "2026-10-25T01:00:00Z", inp=100))
    index = TokenHistoryIndex(tmp_path / "state/index.sqlite3")
    roots = {"claude": (root,)}
    first = index.scan(roots)
    before = path.stat()
    path.write_text(path.read_text().replace('"input_tokens": 100', '"input_tokens": 101'))
    os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
    second = index.scan(roots)
    assert second.input_tokens == first.input_tokens + 1


def test_positive_record_coverage_and_long_context_tiers(tmp_path, monkeypatch):
    root = tmp_path / "codex"
    root.mkdir()
    path = root / "one.jsonl"
    path.write_text("{}\n")
    epoch = datetime.fromisoformat("2026-10-25T01:00:00+00:00").timestamp()
    records = [
        ("codex", "session", "gpt-5.6", epoch, amount, 0, 0, 0, f"record-{amount}")
        for amount in (0, 100, 200_000, 300_000)
    ]
    monkeypatch.setattr(
        usage, "_parse_codex_file", lambda *a, **kw: usage._ParseResult(records, 0, True, parsed_size=3)
    )
    index = TokenHistoryIndex(tmp_path / "state/index.sqlite3")
    totals = index.scan({"codex": (root,)})
    now = datetime.fromtimestamp(epoch)
    old_coverage, new_coverage = {}, {}
    old = usage.daily_buckets(records, days=30, now=now, cost_coverage=old_coverage)
    new = usage.daily_buckets(totals.records, days=30, now=now, cost_coverage=new_coverage)
    assert old == new
    assert old_coverage == new_coverage
    assert new_coverage["observed_records"] == 3
    assert sum(row.record_count for row in totals.records) == 4


def test_identical_concurrent_scans_parse_each_file_once(tmp_path, monkeypatch):
    import threading

    root = tmp_path / "claude"
    root.mkdir()
    (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
    entered, release, second_started = threading.Event(), threading.Event(), threading.Event()
    parser = usage._parse_file
    calls, results = [], []

    def blocked(*args, **kwargs):
        calls.append(1)
        entered.set()
        assert release.wait(5)
        return parser(*args, **kwargs)

    monkeypatch.setattr(usage, "_parse_file", blocked)
    index = TokenHistoryIndex(tmp_path / "state/index.sqlite3")

    def run(second=False):
        if second:
            second_started.set()
        results.append(index.scan({"claude": (root,)}))

    first = threading.Thread(target=run)
    second = threading.Thread(target=run, args=(True,))
    first.start()
    assert entered.wait(5)
    second.start()
    assert second_started.wait(5)
    release.set()
    first.join(5)
    second.join(5)
    assert not first.is_alive() and not second.is_alive()
    assert calls == [1]
    assert any(result.input_tokens == 100 for result in results)
    for result in results:
        assert result.input_tokens == 100 or result.source_coverage["claude"].pending_files == 1
    assert index.scan({"claude": (root,)}).input_tokens == 100


def test_another_index_writer_invalidates_the_shared_view(tmp_path):
    root = tmp_path / "claude"
    root.mkdir()
    path = root / "one.jsonl"
    path.write_text(claude("one", "2026-10-25T01:00:00Z"))
    first = TokenHistoryIndex(tmp_path / "state/index.sqlite3")
    roots = {"claude": (root,)}
    assert first.scan(roots).input_tokens == 100
    with path.open("a") as handle:
        handle.write(claude("two", "2026-10-25T02:00:00Z"))
    assert TokenHistoryIndex(first.path).scan(roots).input_tokens == 200
    assert first.scan(roots).input_tokens == 200


def test_disable_closes_the_maintenance_loop(tmp_path, monkeypatch):
    from types import SimpleNamespace

    from jrbar import core_runtime, token_history_index

    monkeypatch.setattr(token_history_index, "_ENABLED", True)
    monkeypatch.setattr(token_history_index, "_INDEXES", {})
    calls, waits = [], []
    owner = SimpleNamespace(settings=SimpleNamespace(token_history_enabled=True), _core_ready_at=1)

    class Stop:
        stopped = False

        def wait(self, seconds):
            waits.append(seconds)
            if len(waits) == 1:
                return False
            owner.settings.token_history_enabled = False
            core_runtime._sync_token_history(owner)
            return self.stopped

        def is_set(self):
            return self.stopped

    stop = Stop()

    class Service:
        stopping = stop

        def warm(self, providers):
            calls.append("warm")

        def close(self):
            stop.stopped = True

    service = Service()
    owner._core_usage_history_service = service

    class Thread:
        def __init__(self, *, target, **kwargs):
            self.target = target

        def start(self):
            calls.append("thread")
            self.target()

    monkeypatch.setattr(core_runtime.threading, "Thread", Thread)
    core_runtime._usage_history_warm_later(owner)
    assert waits == [8.0, 60.0]
    assert calls == ["thread", "warm"]
    assert stop.stopped
    assert owner._core_usage_history_service is None
    core_runtime._usage_history_warm_later(owner)
    assert calls == ["thread", "warm"]


def test_all_local_adapters_match_old_totals_and_reopen_without_parsing(tmp_path, monkeypatch):
    import shutil

    from jrbar import local_token_history as local
    from tests.test_local_token_history import FIXTURES, _openclaw_tree

    copied = tmp_path / "fixtures"
    shutil.copytree(FIXTURES, copied)
    roots = {
        "pi": (copied / "pi/sessions",),
        "grok": (copied / "grok/sessions",),
        "gemini": (copied / "gemini/tmp",),
        "openclaw": (_openclaw_tree(tmp_path),),
    }
    now = datetime.fromisoformat("2026-09-21T12:00:00+00:00").timestamp()
    index = TokenHistoryIndex(tmp_path / "state/index.sqlite3")
    totals = index.scan(roots)
    for provider, paths in roots.items():
        records = local._SCANNERS[provider](paths[0], 0)
        old = usage_history_document(records, provider=provider, range_name="30d", now=now)
        new = usage_history_document(totals.records, provider=provider, range_name="30d", now=now)
        assert old == new
    monkeypatch.setattr(
        local, "_SCANNERS", {p: lambda *a, **k: (_ for _ in ()).throw(AssertionError("reparse")) for p in roots}
    )
    reused = TokenHistoryIndex(index.path).scan(roots)
    assert sum(sum(r[4:8]) for r in totals.records) == sum(sum(r[4:8]) for r in reused.records)


def test_openclaw_wal_growth_updates_buckets(tmp_path):
    import sqlite3

    from tests.test_local_token_history import _openclaw_tree

    root = _openclaw_tree(tmp_path)
    database = root / "agents/main/agent/openclaw-agent.sqlite"
    index = TokenHistoryIndex(tmp_path / "state/index.sqlite3")
    with sqlite3.connect(database) as writer:
        writer.execute("PRAGMA journal_mode=WAL")
        before = index.scan({"openclaw": (root,)})
        stamp = database.stat().st_mtime_ns
        writer.execute(
            "INSERT INTO transcript_events VALUES (?,?,?,?)",
            (
                "main",
                9,
                json.dumps(
                    {
                        "type": "message",
                        "id": "new",
                        "timestamp": "2026-09-20T09:20:00Z",
                        "message": {
                            "role": "assistant",
                            "modelId": "claude-opus-5",
                            "usage": {"input": 1, "output": 2},
                        },
                    }
                ),
                0,
            ),
        )
        writer.commit()
        assert database.stat().st_mtime_ns == stamp
        after = index.scan({"openclaw": (root,)})
        assert sum(sum(r[4:8]) for r in after.records) == sum(sum(r[4:8]) for r in before.records) + 3


def test_corrupt_history_cache_does_not_interrupt_quota_card_reads(tmp_path, monkeypatch):
    from jrbar import provider_usage_codex_claude, token_history_index

    path = tmp_path / ".local/state/jrbar/token-history.sqlite3"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"synthetic damaged cache")
    monkeypatch.setattr(token_history_index, "_ENABLED", True)
    assert token_history_index.cached_card("claude", tmp_path, 1_792_929_600) is None
    assert provider_usage_codex_claude._cached_provider_local_scan("claude", tmp_path, 1_792_929_600)["history_state"] == "building"


def test_a_view_over_its_byte_limit_is_served_without_retaining_it(tmp_path, monkeypatch):
    from jrbar import token_history_index

    root = tmp_path / "claude"
    root.mkdir()
    (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
    monkeypatch.setattr(token_history_index, "VIEW_BYTES", 256)
    index = TokenHistoryIndex(tmp_path / "state/index.sqlite3")
    assert index.scan({"claude": (root,)}).input_tokens == 100
    assert not index.views
    assert index.view_bytes == 0


def test_retention_skips_old_files_prunes_old_rows_and_reads_newest_first(tmp_path, monkeypatch):
    import os

    from jrbar import token_history_index as module

    now = datetime.fromisoformat("2026-10-25T12:00:00+00:00").timestamp()
    monkeypatch.setattr(module.time, "time", lambda: now)
    root = tmp_path / "claude"
    root.mkdir()
    for name, stamp, age in [("old", "2024-01-01T00:00:00Z", 400),
                             ("recent", "2026-10-24T00:00:00Z", 1),
                             ("newest", "2026-10-25T00:00:00Z", 0)]:
        path = root / f"{name}.jsonl"
        path.write_text(claude(name, stamp))
        os.utime(path, (now - age * 86400, now - age * 86400))
    parser, calls = usage._parse_file, []
    def record(path, *args, **kwargs):
        calls.append(path.stem)
        return parser(path, *args, **kwargs)
    monkeypatch.setattr(usage, "_parse_file", record)
    index = TokenHistoryIndex(tmp_path / "state/history.sqlite3")
    assert index.scan({"claude": (root,)}).input_tokens == 200
    assert calls == ["newest", "recent"]
    monkeypatch.setattr(module.time, "time", lambda: now + 370 * 86400)
    assert index.scan({"claude": (root,)}).input_tokens == 0
    with index._connect() as db:
        assert db.execute("SELECT COUNT(*) FROM raw").fetchone()[0] == 0


def test_timezone_change_rebuckets_without_parsing(tmp_path, monkeypatch):
    import os
    import time
    original = os.environ.get("TZ")
    try:
        monkeypatch.setenv("TZ", "UTC")
        time.tzset()
        root = tmp_path / "claude"
        root.mkdir()
        (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
        index = TokenHistoryIndex(tmp_path / "state/history.sqlite3")
        index.scan({"claude": (root,)})
        monkeypatch.setattr(usage, "_parse_file", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("reparse")))
        monkeypatch.setenv("TZ", "America/Chicago")
        time.tzset()
        totals = index.scan({"claude": (root,)})
        assert datetime.fromtimestamp(totals.records[0][3]).day == 24
        assert totals.input_tokens == 100
    finally:
        if original is None:
            monkeypatch.delenv("TZ", raising=False)
        else:
            monkeypatch.setenv("TZ", original)
        time.tzset()


def test_compact_schema_idle_scan_makes_no_database_writes(tmp_path, monkeypatch):
    root = tmp_path / "claude"
    root.mkdir()
    (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
    index = TokenHistoryIndex(tmp_path / "state/history.sqlite3")
    index.scan({"claude": (root,)})
    connect, connections = index._connect, []
    def counted():
        db = connect()
        connections.append(db)
        return db
    # Keep a separate connection open so the WAL remains inspectable.
    db = connect()
    try:
        before = db.execute("PRAGMA data_version").fetchone()
        monkeypatch.setattr(index, "_connect", counted)
        for _ in range(6):
            assert index.scan({"claude": (root,)}).input_tokens == 100
        assert db.execute("PRAGMA data_version").fetchone() == before
        assert db.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
        assert db.execute("PRAGMA max_page_count").fetchone()[0] > 65536
        assert db.execute("SELECT length(dedupe),kind,owner,event FROM raw").fetchone() == (16, None, None, None)
        assert not db.execute("SELECT 1 FROM sqlite_master WHERE type='trigger' OR name='days'").fetchall()
    finally:
        db.close()


def test_arbitrary_since_filters_before_dedupe(tmp_path):
    root = tmp_path / "claude"
    root.mkdir()
    (root / "a.jsonl").write_text(claude("same", "2026-10-25T01:00:00Z"))
    (root / "b.jsonl").write_text(claude("same", "2026-10-25T02:00:00Z"))
    index = TokenHistoryIndex(tmp_path / "state/history.sqlite3")
    since = datetime.fromisoformat("2026-10-25T01:30:00+00:00").timestamp()
    assert index.scan({"claude": (root,)}, since_epoch=since).input_tokens == 100


def test_fork_heavy_append_resolves_only_changed_events(tmp_path):
    from datetime import timedelta

    from tests.test_codex_usage_lineage import _meta, _tokens, _write

    root = tmp_path / "codex"
    start = datetime.fromisoformat("2026-10-25T10:00:00+00:00")
    events = [_tokens((i + 1) * 100, 100, (start + timedelta(seconds=i)).isoformat()) for i in range(40)]
    _write(root / "parent.jsonl", [_meta("parent", timestamp="2026-10-25T09:00:00Z"), *events])
    for fork in range(6):
        _write(root / f"fork-{fork}.jsonl", [
            _meta(f"fork-{fork}", forked_from_id="parent", timestamp="2026-10-25T10:01:00Z"), *events])
    index = TokenHistoryIndex(tmp_path / "state/history.sqlite3")
    roots = {"codex": (root,)}
    first = index.scan(roots)
    assert first.codex_tokens == 4000
    assert index.resolved_last_pass == 240
    with (root / "fork-0.jsonl").open("a") as handle:
        handle.write(json.dumps(_tokens(4100, 100, "2026-10-25T10:02:00Z")) + "\n")
    assert index.scan(roots).codex_tokens == 4100
    assert index.resolved_last_pass == 0
    (root / "parent.jsonl").unlink()
    assert index.scan(roots).codex_tokens == 4100
    assert index.resolved_last_pass == 240


def test_corruption_is_quarantined_then_rebuilt_after_backoff(tmp_path, monkeypatch):
    from jrbar import token_history_index as module
    root = tmp_path / "claude"
    root.mkdir()
    (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
    path = tmp_path / "state/history.sqlite3"
    path.parent.mkdir()
    path.write_bytes(b"damaged synthetic cache")
    index = TokenHistoryIndex(path)
    clock = [100.0]
    monkeypatch.setattr(module.time, "monotonic", lambda: clock[0])
    failed = index.scan({"claude": (root,)})
    assert failed.source_coverage["claude"].status == usage.UsageSourceStatus.FAILED
    assert len(list(path.parent.glob("*.damaged-*"))) == 1
    assert not path.exists()
    assert index.scan({"claude": (root,)}).records == []
    assert not path.exists()
    clock[0] += 61
    assert index.scan({"claude": (root,)}).input_tokens == 100
    assert index.error is None


def test_sqlite_full_stops_parsing_for_an_hour(tmp_path, monkeypatch):
    import sqlite3

    from jrbar import token_history_index as module
    root = tmp_path / "claude"
    root.mkdir()
    (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
    index = TokenHistoryIndex(tmp_path / "state/history.sqlite3")
    calls = []
    def full(*args):
        calls.append(1)
        error = sqlite3.OperationalError("database or disk is full")
        error.sqlite_errorcode = sqlite3.SQLITE_FULL
        raise error
    monkeypatch.setattr(index, "_append", full)
    monkeypatch.setattr(module.time, "monotonic", lambda: 100.0)
    assert index.scan({"claude": (root,)}).source_coverage["claude"].status == usage.UsageSourceStatus.FAILED
    for _ in range(60):
        index.scan({"claude": (root,)})
    assert calls == [1]
    assert index.error == "history_disk_full"
    assert index.retry_at == 3700
    assert not list(index.path.parent.glob("*.damaged-*"))


def test_cached_card_reads_committed_view_during_a_scan(tmp_path, monkeypatch):
    import threading

    from jrbar import token_history_index as module
    monkeypatch.setattr(module, "_ENABLED", True)
    monkeypatch.setattr(module, "_INDEXES", {})
    root = tmp_path / ".claude/projects"
    root.mkdir(parents=True)
    path = root / "one.jsonl"
    path.write_text(claude("one", "2026-10-25T01:00:00Z"))
    index = module.shared_index(tmp_path / ".local/state/jrbar/token-history.sqlite3")
    roots = {"claude": (root,)}
    observed = datetime.fromisoformat("2026-10-25T12:00:00+00:00").timestamp()
    index.scan(roots)
    assert module.cached_card("claude", tmp_path, observed)["input_tokens"] == 100
    path.write_text(path.read_text() + claude("two", "2026-10-25T02:00:00Z"))
    entered, release = threading.Event(), threading.Event()
    parser = usage._parse_file_tail
    def blocked(*args, **kwargs):
        entered.set()
        assert release.wait(5)
        return parser(*args, **kwargs)
    monkeypatch.setattr(usage, "_parse_file_tail", blocked)
    thread = threading.Thread(target=lambda: index.scan(roots))
    thread.start()
    try:
        assert entered.wait(5)
        assert module.cached_card("claude", tmp_path, observed)["input_tokens"] == 100
    finally:
        release.set()
        thread.join(5)
    assert not thread.is_alive()
    assert module.cached_card("claude", tmp_path, observed)["input_tokens"] == 200


def test_budgeted_reconciliation_resumes_without_reparsing(tmp_path, monkeypatch):
    from datetime import timedelta

    from tests.test_codex_usage_lineage import _meta, _tokens, _write
    root = tmp_path / "codex"
    start = datetime.fromisoformat("2026-10-25T10:00:00+00:00")
    events = [_tokens((i + 1) * 100, 100, (start + timedelta(seconds=i)).isoformat()) for i in range(600)]
    _write(root / "fork.jsonl", [_meta("fork", forked_from_id="absent", timestamp="2026-10-25T11:00:00Z"), *events])
    index = TokenHistoryIndex(tmp_path / "state/history.sqlite3")
    class Budget:
        stopped = False
        def expired(self):
            return self.stopped
        def share(self, parts):
            return self
    budget = Budget()
    lineage = index._lineage
    def bounded(db, allowance):
        lineage(db, allowance)
        budget.stopped = True
    monkeypatch.setattr(index, "_lineage", bounded)
    first = index.scan({"codex": (root,)}, budget=budget)
    assert first.source_coverage["codex"].pending_files == 1
    assert index.resolved_last_pass <= 256
    monkeypatch.setattr(usage, "_parse_codex_file", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("reparse")))
    reopened = TokenHistoryIndex(index.path)
    final = reopened.scan({"codex": (root,)})
    assert final.codex_tokens == 60000
    assert final.source_coverage["codex"].pending_files == 0


def test_retired_cache_is_never_a_card_fallback_and_is_removed_only_when_complete(tmp_path, monkeypatch):
    from jrbar import provider_usage_codex_claude as cards
    from jrbar import token_history_index as module
    monkeypatch.setattr(module, "_ENABLED", True)
    monkeypatch.setattr(module, "_INDEXES", {})
    state = tmp_path / ".local/state/jrbar"
    state.mkdir(parents=True)
    dead = state / "usage-scan-cache.json"
    dead.write_text('{"old": "synthetic"}')
    assert cards._cached_provider_local_scan("claude", tmp_path, 1792929600, extra_homes=())["history_state"] == "building"
    assert dead.exists()
    root = tmp_path / ".claude/projects"
    root.mkdir(parents=True)
    (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
    index = module.shared_index(state / "token-history.sqlite3")
    index.scan({"claude": (root,)})
    assert dead.exists()
    index.scan({"codex": (tmp_path / ".codex/sessions",)})
    assert not dead.exists()


def test_history_off_preserves_codex_quota_without_token_parsing(tmp_path, monkeypatch):
    from jrbar import provider_usage_codex_claude as cards
    from jrbar import token_history_index as module
    from jrbar.provider_usage_settings import ProviderPreference
    from tests.test_codex_usage_lineage import _meta, _tokens, _write
    row = _tokens(100, 100, "2026-10-25T10:00:00Z")
    row["payload"]["rate_limits"] = {"primary": {"used_percent": 40, "window_minutes": 300, "resets_at": 1792933200}}
    _write(tmp_path / ".codex/sessions/one.jsonl", [_meta("one"), row])
    monkeypatch.setattr(module, "_ENABLED", False)
    monkeypatch.setattr(usage, "_parse_codex_file", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("token parser")))
    snapshot = cards.collect_codex(ProviderPreference("codex", True, False), home=tmp_path, observed_at=1792929600, read_auth=False)
    assert snapshot.lanes[0].remaining_percent == 60
    assert snapshot.model_count == 0
    assert not (tmp_path / ".local/state/jrbar/token-history.sqlite3").exists()


def test_partial_file_resumes_even_when_physical_stat_is_unchanged(tmp_path):
    root = tmp_path / "claude"
    root.mkdir()
    (root / "one.jsonl").write_text("".join(claude(str(i), "2026-10-25T01:00:00Z") for i in range(1000)))
    index = TokenHistoryIndex(tmp_path / "state/history.sqlite3")
    class Budget:
        checks = 0
        def share(self, parts):
            return self
        def expired(self):
            self.checks += 1
            return self.checks > 1
    index.scan({"claude": (root,)}, budget=Budget())
    with index._connect() as db:
        metadata = json.loads(db.execute("SELECT metadata FROM files").fetchone()[0])
        assert metadata["size"] < (root / "one.jsonl").stat().st_size
        assert "stat_size" not in metadata
    final = TokenHistoryIndex(index.path).scan({"claude": (root,)})
    assert final.input_tokens == 100000
    assert sum(r.record_count for r in final.records) == 1000


def test_busy_view_lock_returns_last_card_marked_stale(tmp_path, monkeypatch):
    import threading

    from jrbar import token_history_index as module
    monkeypatch.setattr(module, "_ENABLED", True)
    monkeypatch.setattr(module, "_INDEXES", {})
    root = tmp_path / ".claude/projects"
    root.mkdir(parents=True)
    (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
    index = module.shared_index(tmp_path / ".local/state/jrbar/token-history.sqlite3")
    index.scan({"claude": (root,)})
    observed = datetime.fromisoformat("2026-10-25T12:00:00+00:00").timestamp()
    module.cached_card("claude", tmp_path, observed)
    entered, release, finished = threading.Event(), threading.Event(), threading.Event()
    results = []
    def hold():
        with index.lock:
            entered.set()
            assert release.wait(5)
    def read():
        results.append(module.cached_card("claude", tmp_path, observed))
        finished.set()
    holder = threading.Thread(target=hold)
    reader = threading.Thread(target=read)
    holder.start()
    assert entered.wait(5)
    reader.start()
    try:
        assert finished.wait(2)
        assert results[0]["input_tokens"] == 100
        assert results[0]["history_stale"] is True
    finally:
        release.set()
        holder.join(5)
        reader.join(5)
    assert not holder.is_alive() and not reader.is_alive()


def test_history_off_keeps_session_context_command(tmp_path, monkeypatch):
    from types import SimpleNamespace

    from jrbar import core_runtime, session_usage, token_history_index
    monkeypatch.setattr(token_history_index, "_ENABLED", False)
    calls = []
    def read(requests, **kwargs):
        calls.extend(requests)
        return {"sessions": [{"id": "one", "context_tokens": 900, "context_window": 10000}], "gaps": {}}
    monkeypatch.setattr(session_usage, "session_usage_document", read)
    owner = SimpleNamespace(last_snapshot=SimpleNamespace(statuses=[SimpleNamespace(agent_id="one", provider="codex", session_id="synthetic")]))
    result = core_runtime._cmd_session_usage(owner, {"ids": ["one"]})
    assert result["sessions"][0]["context_tokens"] == 900
    assert calls == [("one", "codex", "synthetic", None)]


def test_scan_restores_the_callers_qos(tmp_path):
    import ctypes
    import sys

    import pytest
    if sys.platform != "darwin":
        pytest.skip("Darwin scheduling classes")
    library = ctypes.CDLL(None)
    library.qos_class_self.restype = ctypes.c_uint
    previous = library.qos_class_self()
    try:
        assert library.pthread_set_qos_class_self_np(0x15, 0) == 0
        index = TokenHistoryIndex(tmp_path / "state/history.sqlite3")
        observed = []
        scan = index._scan
        def during(*args, **kwargs):
            observed.append(library.qos_class_self())
            return scan(*args, **kwargs)
        index._scan = during
        index.scan({})
        assert observed == [0x11]
        assert library.qos_class_self() == 0x15
    finally:
        library.pthread_set_qos_class_self_np(previous, 0)


def test_card_reopen_does_not_run_writer_integrity_checks(tmp_path, monkeypatch):
    import sqlite3

    from jrbar import token_history_index as module
    monkeypatch.setattr(module, "_ENABLED", True)
    monkeypatch.setattr(module, "_INDEXES", {})
    root = tmp_path / ".claude/projects"
    root.mkdir(parents=True)
    (root / "one.jsonl").write_text(claude("one", "2026-10-25T01:00:00Z"))
    path = tmp_path / ".local/state/jrbar/token-history.sqlite3"
    module.shared_index(path).scan({"claude": (root,)})
    monkeypatch.setattr(module, "_INDEXES", {})
    real_connect, queries = sqlite3.connect, []
    class Reader(sqlite3.Connection):
        def execute(self, sql, *args, **kwargs):
            assert "quick_check" not in sql.lower()
            queries.append(sql)
            return super().execute(sql, *args, **kwargs)
    def connect(*args, **kwargs):
        assert kwargs.get("uri") is True
        assert str(args[0]).endswith("?mode=ro")
        return real_connect(*args, **kwargs, factory=Reader)
    monkeypatch.setattr(module.sqlite3, "connect", connect)
    card = module.cached_card("claude", tmp_path, 1792929600)
    assert card["input_tokens"] == 100
    assert "PRAGMA query_only=ON" in queries


def test_off_interrupts_the_writer_integrity_check(tmp_path, monkeypatch):
    import sqlite3

    import pytest

    from jrbar import token_history_index as module
    path = tmp_path / "state/history.sqlite3"
    path.parent.mkdir()
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE synthetic (value INTEGER)")
        db.executemany("INSERT INTO synthetic VALUES (?)", ((i,) for i in range(5000)))
    index = module.TokenHistoryIndex(path)
    real_connect = sqlite3.connect
    class Stopped(sqlite3.Connection):
        def execute(self, sql, *args, **kwargs):
            if sql == "PRAGMA quick_check":
                index.stopping.set()
            return super().execute(sql, *args, **kwargs)
    monkeypatch.setattr(module.sqlite3, "connect", lambda *a, **kw: real_connect(*a, **kw, factory=Stopped))
    with pytest.raises(sqlite3.OperationalError) as caught:
        index._connect()
    assert caught.value.sqlite_errorcode == sqlite3.SQLITE_INTERRUPT
