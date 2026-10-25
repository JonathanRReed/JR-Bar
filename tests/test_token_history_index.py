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
    totals = index.scan(roots, now=now)
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
    TokenHistoryIndex(index.path).scan(roots, now=now)


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
    for command in (core_runtime._cmd_usage_history, core_runtime._cmd_usage_graph, core_runtime._cmd_session_usage):
        with pytest.raises(CommandError) as caught:
            command(owner, {})
        assert caught.value.code == "disabled"
    monkeypatch.setattr(usage, "_provider_inventory", forbidden)
    assert token_history_index.scan_history(home=tmp_path).records == []
    assert provider_usage_codex_claude._default_provider_local_scan("codex", tmp_path, 1) is None
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
        results.append(index.scan({"claude": (root,)}).input_tokens)

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
    assert results == [100, 100]


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
