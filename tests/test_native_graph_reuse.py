"""Native reuse must match complete fresh documents from isolated transcripts."""

import json
import os
import threading
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from jrbar import local_token_history, provider_homes, usage_stats
from jrbar import usage_graph_worker as worker


def write_rows(path, rows, *, touched=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps({
        "type": "assistant", "timestamp": (datetime.now(timezone.utc) - timedelta(days=days)).isoformat(),
        "message": {"id": identity, "model": model, "usage": {"input_tokens": tokens, "output_tokens": 5}},
    }) for days, identity, model, tokens in rows) + "\n")
    if not touched:
        timestamp = (datetime.now() - timedelta(days=max(row[0] for row in rows))).timestamp()
        os.utime(path, (timestamp, timestamp))


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    # This suite tests the retired in-memory reuse component against its
    # original scanner. Production uses the persistent index instead.
    original_scan = worker.scan_usage_all_homes
    def legacy_scan(*args, **kwargs):
        kwargs["aggregate"] = False
        return original_scan(*args, **kwargs)
    monkeypatch.setattr(worker, "scan_usage_all_homes", legacy_scan)
    root = tmp_path / "claude" / "projects"
    write_rows(root / "old.jsonl", [(40, "shared", "claude-opus-4", 10)])
    write_rows(root / "recent.jsonl", [(0, "shared", "claude-opus-4", 10), (0, "new", "unknown-model", 20)])
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(root.parent))
    monkeypatch.setattr(provider_homes, "_home", lambda _home=None: tmp_path / "home")
    monkeypatch.setattr(provider_homes, "configured_extra_homes", lambda *_args: {})
    monkeypatch.setattr(worker, "default_state_dir", lambda: tmp_path / "state")
    monkeypatch.setattr(local_token_history, "roots", lambda **_kwargs: {})
    monkeypatch.setattr(worker, "_usage_doc_cache_read", lambda: {})
    monkeypatch.setattr(worker, "_usage_doc_cache_store", lambda *_args: None)
    settings = SimpleNamespace(usage_graph_days=365, usage_display_mode="tokens", usage_graph_providers=("claude",))
    return root, settings


def test_real_pre_window_reuse_matches_fresh_documents_across_ranges_and_metrics(corpus, monkeypatch):
    _root, settings = corpus
    owner = worker.NativeGraphReuse()
    original_scan = worker.scan_usage_all_homes
    calls = []
    def scan(*args, **kwargs):
        calls.append(1)
        return original_scan(*args, **kwargs)
    monkeypatch.setattr(worker, "scan_usage_all_homes", scan)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    for days in (90, 30, 7):
        for metric in ("tokens", "cost", "sessions", "percent"):
            before = len(calls)
            reused = worker.usage_graph_document(settings, days=days, metric=metric, native_reuse=owner,
                                                 provider_ids=("claude",))
            assert len(calls) == before
            fresh = worker.usage_graph_document(settings, days=days, metric=metric, provider_ids=("claude",))
            assert reused == fresh
    owner.close()


@pytest.mark.parametrize("touched", [False, True])
def test_widening_recollects_even_when_historical_file_was_touched(corpus, monkeypatch, touched):
    root, settings = corpus
    write_rows(root / "older.jsonl", [(200, "older", "claude-opus-4", 30)], touched=touched)
    owner = worker.NativeGraphReuse()
    original = worker.scan_usage_all_homes
    calls = []
    def scan(*args, **kwargs):
        calls.append(1)
        return original(*args, **kwargs)
    monkeypatch.setattr(worker, "scan_usage_all_homes", scan)
    for days in (30, 90, 365):
        reused = worker.usage_graph_document(settings, days=days, native_reuse=owner, provider_ids=("claude",))
        fresh = worker.usage_graph_document(settings, days=days, provider_ids=("claude",))
        assert reused == fresh
    assert len(calls) == 6


@pytest.mark.parametrize("change", ["same_size", "delete", "root", "admission", "instance", "calendar", "semantic"])
@pytest.mark.parametrize("rejected", [False, True])
def test_native_binding_changes_recollect_and_match_fresh(corpus, monkeypatch, tmp_path, change, rejected):
    root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_rows=1) if rejected else worker.NativeGraphReuse()
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    prior = owner._rejected_binding if rejected else owner._slot
    assert prior is not None
    admissions = []
    if rejected:
        original_size = worker._native_size
        def size(value):
            if isinstance(value, worker._NativeRejection):
                admissions.append(1)
            return original_size(value)
        monkeypatch.setattr(worker, "_native_size", size)
    if change == "same_size":
        path = root / "recent.jsonl"
        info = path.stat()
        path.write_text(path.read_text().replace('"input_tokens": 20', '"input_tokens": 21'))
        os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
        assert path.stat().st_size == info.st_size
        assert path.stat().st_ctime_ns != info.st_ctime_ns
    elif change == "delete":
        (root / "recent.jsonl").unlink()
    elif change == "root":
        new = tmp_path / "another" / "projects"
        write_rows(new / "new.jsonl", [(0, "different", "claude-opus-4", 80)])
        monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(new.parent))
    elif change in {"admission", "instance"}:
        rows = usage_stats.negotiated_provider_sources()
        if change == "admission":
            rows = tuple(row for row in rows if row.source_key.provider_id != "claude")
        else:
            changed = []
            for row in rows:
                if row.source_key.provider_id == "claude" and row.source_key.capability_id == "transcript_usage":
                    registration = replace(row.registration, source_instance_id=type(row.registration.source_instance_id)("second"))
                    key = usage_stats.SourceKey("claude", row.source_key.adapter_id, "second", "transcript_usage")
                    row = replace(row, registration=registration, source_key=key)
                changed.append(row)
            rows = tuple(changed)
        monkeypatch.setattr(usage_stats, "negotiated_provider_sources", lambda: rows)
    elif change == "semantic":
        monkeypatch.setattr(usage_stats, "CODEX_CACHE_SEMANTICS_VERSION", usage_stats.CODEX_CACHE_SEMANTICS_VERSION + 1)
    else:
        original_meta = worker._usage_doc_cache_meta
        monkeypatch.setattr(worker, "_usage_doc_cache_meta", lambda *args: {**original_meta(*args), "tz": "changed-zone"})
    days = 365 if rejected else 30
    reused = worker.usage_graph_document(settings, days=days, native_reuse=owner, provider_ids=("claude",))
    fresh = worker.usage_graph_document(settings, days=days, provider_ids=("claude",))
    assert reused == fresh
    current = owner._rejected_binding if rejected else owner._slot
    assert current is not prior
    if rejected:
        retained = owner._rejected_binding or owner._slot
        assert retained is None or retained.binding != prior.binding
        assert admissions == [1]


@pytest.mark.parametrize("limits", [{"maximum_rows": 1}, {"maximum_bytes": 1024}])
def test_cap_bypass_returns_all_records_without_retention(corpus, monkeypatch, limits):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(**limits)
    first = worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    second = worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    fresh = worker.usage_graph_document(settings, provider_ids=("claude",))
    assert first == second == fresh
    assert owner._slot is None
    assert first["graph"]["heatmap"]["aggregate"]["totals"]["tokens"] == 40


def test_partial_source_and_incomplete_walk_are_not_admitted(corpus, monkeypatch):
    root, settings = corpus
    owner = worker.NativeGraphReuse()
    (root / "bad.jsonl").write_text('{"usage": broken\n')
    first = worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._slot is None
    assert "Partial local history: Claude" in first["summary"]
    (root / "bad.jsonl").unlink()
    original = worker._native_corpus_fingerprint
    monkeypatch.setattr(worker, "_native_corpus_fingerprint", lambda snapshot:
                        {key: {**value, "complete": False} for key, value in original(snapshot).items()})
    reused = worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    fresh = worker.usage_graph_document(settings, provider_ids=("claude",))
    assert reused == fresh
    assert owner._slot is None


def test_walk_error_is_explicit_and_prevents_completeness(tmp_path, monkeypatch):
    def walk(_root, *, followlinks, onerror):
        onerror(PermissionError("synthetic denied directory"))
        return iter(())
    monkeypatch.setattr(worker.os, "walk", walk)
    assert worker._tree_fingerprint(tmp_path)["complete"] is False


def test_t3_precedence_and_auxiliary_reads_are_recomputed_after_narrowing(corpus, monkeypatch):
    root, settings = corpus
    (root / "recent.jsonl").unlink()
    calls = []
    def scan(_policy, since, *, coverage_reporter):
        calls.append(since)
        coverage_reporter("stable_partial")
        return [("claude", "t3-thread", "", datetime.now().timestamp(), 12, 0, 0, 3, "t3:turn"),
                ("other", "unattributed", "", datetime.now().timestamp(), 4, 0, 0, 1, "t3:unknown")]
    monkeypatch.setattr(worker, "scan_t3_activity_statistics", scan)
    policy = worker.T3ReadOnlyPolicy(True, True, str(root.parent), None)
    owner = worker.NativeGraphReuse()
    broad = worker.usage_graph_document(settings, days=90, native_reuse=owner, t3_policy=policy, provider_ids=("claude",))
    narrow = worker.usage_graph_document(settings, days=30, native_reuse=owner, t3_policy=policy, provider_ids=("claude",))
    fresh = worker.usage_graph_document(settings, days=30, t3_policy=policy, provider_ids=("claude",))
    assert narrow == fresh
    assert len(calls) == 3
    assert broad["graph"]["source_statistics"][0]["included_tokens"] == 0
    assert narrow["graph"]["source_statistics"][0]["included_tokens"] == 15


def test_replacement_and_shutdown_cannot_publish_an_inflight_capture(corpus, monkeypatch):
    _root, settings = corpus
    owner = worker.NativeGraphReuse()
    separate = worker.NativeGraphReuse()
    worker.usage_graph_document(settings, days=30, native_reuse=owner, provider_ids=("claude",))
    assert owner._slot is not None
    entered = threading.Event()
    release = threading.Event()
    original = usage_stats._scan_inventory_usage_with_index
    def scan(*args, **kwargs):
        assert owner._slot is None
        capture = kwargs["resolved_capture"]
        def observe(*values):
            capture(*values)
            entered.set()
            assert release.wait(2)
        kwargs["resolved_capture"] = observe
        return original(*args, **kwargs)
    monkeypatch.setattr(usage_stats, "_scan_inventory_usage_with_index", scan)
    failures = []
    def collect():
        try:
            worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
        except Exception as error:
            failures.append(error)
    thread = threading.Thread(target=collect)
    thread.start()
    assert entered.wait(2)
    owner.close()
    release.set()
    thread.join(2)
    assert not thread.is_alive() and not failures
    assert owner._slot is None and separate._slot is None
    monkeypatch.setattr(usage_stats, "_scan_inventory_usage_with_index", original)
    worker.usage_graph_document(settings, native_reuse=separate, provider_ids=("claude",))
    assert separate._slot is not None
    separate.close()
    assert separate._slot is None


def test_reused_working_lists_cannot_mutate_retained_batches(corpus):
    _root, settings = corpus
    owner = worker.NativeGraphReuse()
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    binding = owner._slot.binding
    floor = worker._period_start(30).timestamp()
    first = owner.collect(worker._settings_snapshot(settings), floor, binding)
    expected = list(first.records)
    first.records.clear()
    first.source_coverage.clear()
    second = owner.collect(worker._settings_snapshot(settings), floor, binding)
    assert second.records == expected
    assert second.source_coverage["claude"].status is usage_stats.UsageSourceStatus.OK


def test_post_capture_change_does_not_admit_snapshot(corpus, monkeypatch):
    root, settings = corpus
    owner = worker.NativeGraphReuse()
    original = worker.scan_usage_all_homes
    def scan(*args, **kwargs):
        totals = original(*args, **kwargs)
        write_rows(root / "changed.jsonl", [(0, "changed", "claude-opus-4", 70)])
        return totals
    monkeypatch.setattr(worker, "scan_usage_all_homes", scan)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._slot is None


def test_copied_codex_lineage_and_extra_home_order_match_fresh(corpus, monkeypatch, tmp_path):
    from test_codex_usage_lineage import _meta, _tokens, _write
    root, settings = corpus
    codex = tmp_path / "codex" / "sessions"
    old = (datetime.now(timezone.utc) - timedelta(days=40)).isoformat()
    recent = datetime.now(timezone.utc).isoformat()
    ancestor = [_meta("parent", timestamp=old), _tokens(100, 100, old), _tokens(160, 60, recent)]
    _write(codex / "ancestor.jsonl", ancestor)
    _write(codex / "copy.jsonl", ancestor)
    _write(codex / "child.jsonl", [_meta("child", forked_from_id="parent", timestamp=recent),
                                  _tokens(100, 100, old), _tokens(200, 100, recent)])
    extra = tmp_path / "extra"
    write_rows(extra / "projects" / "extra.jsonl", [(0, "extra", "claude-opus-4", 90)])
    monkeypatch.setenv("CODEX_HOME", str(codex.parent))
    monkeypatch.setattr(provider_homes, "configured_extra_homes", lambda *_args: {"claude": (str(extra),)})
    owner = worker.NativeGraphReuse()
    wide = worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("codex", "claude"))
    assert owner._slot is not None
    assert [(batch.source_key.provider_id, batch.root) for batch in owner._slot.batches] == [
        ("claude", str(root)), ("codex", str(codex)), ("claude", str(extra / "projects")),
    ]
    for days in (90, 30):
        reused = worker.usage_graph_document(settings, days=days, native_reuse=owner, provider_ids=("codex", "claude"))
        fresh = worker.usage_graph_document(settings, days=days, provider_ids=("codex", "claude"))
        assert reused == fresh
    assert wide["graph"]["heatmap"]["providers"]["codex"]["totals"]["tokens"] > 0


def test_auxiliary_collectors_still_run_for_native_hits(corpus, monkeypatch):
    from jrbar import session_history
    _root, settings = corpus
    calls = {"opencode": 0, "local": 0, "ledger": 0, "percent": 0}
    def called(name, value):
        def collect(*_args, **_kwargs):
            calls[name] += 1
            return value
        return collect
    monkeypatch.setattr(worker, "_scan_opencode_records", called("opencode", []))
    monkeypatch.setattr(local_token_history, "scan_local_records", called("local", []))
    monkeypatch.setattr(session_history, "ledger_session_days", called("ledger", {}))
    original_percent = worker.usage_percent_history.shared_percent_graph_model
    def percent(*args, **kwargs):
        calls["percent"] += 1
        return original_percent(*args, **kwargs)
    monkeypatch.setattr(worker.usage_percent_history, "shared_percent_graph_model", percent)
    owner = worker.NativeGraphReuse()
    for metric in ("tokens", "sessions", "percent"):
        worker.usage_graph_document(settings, metric=metric, native_reuse=owner, provider_ids=("claude", "opencode"))
    assert owner._slot is not None
    assert calls == {"opencode": 3, "local": 3, "ledger": 1, "percent": 1}


@pytest.mark.parametrize("incomplete", ["pending", "failed", "extra_home", "oversized_field"])
def test_incomplete_or_oversized_native_capture_bypasses_without_changing_document(corpus, monkeypatch, tmp_path, incomplete):
    root, settings = corpus
    if incomplete == "pending":
        monkeypatch.setattr(worker, "GRAPH_PASS_SECONDS", 0)
    elif incomplete == "failed":
        original = usage_stats._provider_inventory
        def inventory(*args, **kwargs):
            result = original(*args, **kwargs)
            source = result.sources[0]
            coverage = replace(source.coverage, status=usage_stats.UsageSourceStatus.FAILED,
                               root_walked=False, unreadable_files=1)
            return replace(result, sources=(replace(source, candidates=(), coverage=coverage, walk_complete=False),))
        monkeypatch.setattr(usage_stats, "_provider_inventory", inventory)
    elif incomplete == "extra_home":
        extra = tmp_path / "extra" / "projects"
        extra.mkdir(parents=True)
        (extra / "bad.jsonl").write_text('{"usage":broken\n')
        monkeypatch.setattr(provider_homes, "configured_extra_homes", lambda *_args: {"claude": (str(extra.parent),)})
    else:
        original = usage_stats._scan_inventory_usage_with_index
        def oversized(*args, **kwargs):
            capture = kwargs.get("resolved_capture")
            if capture is not None:
                def observe(key, path, rows, coverage):
                    row = (*rows[0][:8], "x" * 200_000)
                    capture(key, path, [row, *rows[1:]], coverage)
                kwargs["resolved_capture"] = observe
            return original(*args, **kwargs)
        monkeypatch.setattr(usage_stats, "_scan_inventory_usage_with_index", oversized)
    owner = worker.NativeGraphReuse()
    reused = worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    if incomplete == "pending":
        monkeypatch.setattr(worker, "default_state_dir", lambda: tmp_path / "independent-fresh")
    fresh = worker.usage_graph_document(settings, provider_ids=("claude",))
    assert reused == fresh
    assert owner._slot is None


@pytest.mark.parametrize("owned", [False, True])
def test_incomplete_native_witness_cannot_serve_or_store_whole_documents(corpus, monkeypatch, owned):
    root, settings = corpus
    cache = {"entries": {}}
    monkeypatch.setattr(worker, "_usage_doc_cache_read", lambda: cache)
    monkeypatch.setattr(worker, "_usage_doc_cache_store", lambda key, fingerprint, document:
                        cache["entries"].update({key: {"fingerprint": fingerprint, "document": document}}))
    monkeypatch.setattr(worker, "_native_corpus_fingerprint", lambda _settings:
                        {"claude": {"complete": False, "stat_digest": "unchanged-observation-failure"}})
    options = {"native_reuse": worker.NativeGraphReuse()} if owned else {}
    first = worker.usage_graph_document(settings, provider_ids=("claude",), **options)
    path = root / "recent.jsonl"
    path.write_text(path.read_text().replace('"input_tokens": 20', '"input_tokens": 50'))
    second = worker.usage_graph_document(settings, provider_ids=("claude",), **options)
    assert first["graph"]["heatmap"]["aggregate"]["totals"]["tokens"] == 40
    assert second["graph"]["heatmap"]["aggregate"]["totals"]["tokens"] == 70
    assert cache["entries"] == {}


def test_observed_missing_root_is_complete_and_new_root_invalidates(corpus, monkeypatch):
    root, settings = corpus
    root.rename(root.with_name("hidden-synthetic-projects"))
    cache = {"entries": {}}
    monkeypatch.setattr(worker, "_usage_doc_cache_read", lambda: cache)
    monkeypatch.setattr(worker, "_usage_doc_cache_store", lambda key, fingerprint, document:
                        cache["entries"].update({key: {"fingerprint": fingerprint, "document": document}}))
    original = worker.scan_usage_all_homes
    calls = []
    def scan(*args, **kwargs):
        calls.append(1)
        return original(*args, **kwargs)
    monkeypatch.setattr(worker, "scan_usage_all_homes", scan)
    owner = worker.NativeGraphReuse()
    first = worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._slot is not None and owner._slot.binding.complete
    assert owner._slot.batches[0].coverage.status is usage_stats.UsageSourceStatus.MISSING
    assert worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",)) == first
    assert calls == [1]
    write_rows(root / "new.jsonl", [(0, "new-source", "claude-opus-4", 70)])
    second = worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert calls == [1, 1]
    assert second["graph"]["heatmap"]["aggregate"]["totals"]["tokens"] == 75


def test_complete_byte_rejection_skips_sizing_but_not_fresh_scans(corpus, monkeypatch):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_bytes=9_000)
    original_size = worker._native_size
    original_scan = worker.scan_usage_all_homes
    sizes = []
    scans = []
    def size(value):
        if isinstance(value, worker._ResolvedNativeSource):
            sizes.append(1)
            return 10_000
        return original_size(value)
    def scan(*args, **kwargs):
        scans.append(1)
        return original_scan(*args, **kwargs)
    monkeypatch.setattr(worker, "_native_size", size)
    monkeypatch.setattr(worker, "scan_usage_all_homes", scan)
    for metric in ("tokens", "cost", "sessions"):
        reused = worker.usage_graph_document(settings, days=365, metric=metric, native_reuse=owner, provider_ids=("claude",))
        fresh = worker.usage_graph_document(settings, days=365, metric=metric, provider_ids=("claude",))
        assert reused == fresh and owner._slot is None
    assert sizes == [1]
    assert len(scans) == 6
    assert owner._rejected_binding is not None


def test_rejected_binding_is_cleared_on_change_and_close(corpus, monkeypatch):
    root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_rows=1)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    prior = owner._rejected_binding
    assert prior is not None and owner._slot is None
    write_rows(root / "changed.jsonl", [(0, "changed", "claude-opus-4", 70)])
    original_size = worker._native_size
    admissions = []
    def size(value):
        if isinstance(value, worker._NativeRejection):
            admissions.append(1)
        return original_size(value)
    monkeypatch.setattr(worker, "_native_size", size)
    worker.usage_graph_document(settings, days=365, native_reuse=owner, provider_ids=("claude",))
    assert owner._rejected_binding is not None and owner._rejected_binding.binding != prior.binding
    assert admissions == [1]
    owner.close()
    assert owner._rejected_binding is None and owner._slot is None


def test_binding_metadata_overflow_cannot_be_remembered(corpus):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_bytes=1)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._rejected_binding is None and owner._slot is None


@pytest.mark.parametrize("failure", ["failed", "pending", "exception"])
def test_existing_rejection_does_not_survive_failed_or_partial_collection(corpus, monkeypatch, failure):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_rows=1)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._rejected_binding is not None
    original = worker.scan_usage_all_homes
    def scan(*args, **kwargs):
        if failure == "exception":
            raise RuntimeError("synthetic scan failure")
        capture = kwargs["resolved_capture"]
        def observe(key, root, rows, coverage):
            if failure == "failed":
                coverage = replace(coverage, status=usage_stats.UsageSourceStatus.FAILED, root_walked=False)
            else:
                coverage = replace(coverage, status=usage_stats.UsageSourceStatus.PARTIAL, pending_files=1)
            capture(key, root, rows, coverage)
        kwargs["resolved_capture"] = observe
        return original(*args, **kwargs)
    monkeypatch.setattr(worker, "scan_usage_all_homes", scan)
    if failure == "exception":
        with pytest.raises(RuntimeError, match="synthetic scan failure"):
            worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    else:
        worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._rejected_binding is None and owner._slot is None


def test_cap_rejection_cannot_publish_after_close_during_post_witness(corpus, monkeypatch):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_rows=1)
    original = worker._native_corpus_fingerprint
    calls = []
    entered = threading.Event()
    release = threading.Event()
    def fingerprint(snapshot):
        calls.append(1)
        if len(calls) == 2:
            entered.set()
            assert release.wait(2)
        return original(snapshot)
    monkeypatch.setattr(worker, "_native_corpus_fingerprint", fingerprint)
    errors = []
    def collect():
        try:
            worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
        except Exception as error:
            errors.append(error)
    thread = threading.Thread(target=collect)
    thread.start()
    assert entered.wait(2)
    owner.close()
    release.set()
    thread.join(2)
    assert not thread.is_alive() and not errors
    assert owner._rejected_binding is None and owner._slot is None


def test_cap_rejection_requires_complete_matching_post_witness(corpus, monkeypatch):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_rows=1)
    original = worker._native_corpus_fingerprint
    calls = []
    def fingerprint(snapshot):
        calls.append(1)
        result = original(snapshot)
        if len(calls) == 2:
            result = {key: {**value, "complete": False} for key, value in result.items()}
        return result
    monkeypatch.setattr(worker, "_native_corpus_fingerprint", fingerprint)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._rejected_binding is None and owner._slot is None


def test_actual_default_byte_cap_remembers_only_metadata_and_keeps_documents_fresh(corpus, monkeypatch):
    root, settings = corpus
    for path in root.glob("*.jsonl"):
        path.unlink()
    write_rows(root / "wide.jsonl", [(0, f"synthetic-{index}", "claude-opus-4", 10) for index in range(18_000)])
    owner = worker.NativeGraphReuse()
    original = worker._native_size
    sizes = []
    def size(value):
        result = original(value)
        if isinstance(value, worker._ResolvedNativeSource):
            sizes.append(result)
        return result
    monkeypatch.setattr(worker, "_native_size", size)
    first = worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    second = worker.usage_graph_document(settings, days=365, metric="cost", native_reuse=owner, provider_ids=("claude",))
    fresh = worker.usage_graph_document(settings, days=365, metric="cost", provider_ids=("claude",))
    assert second == fresh
    assert first["graph"]["heatmap"]["aggregate"]["totals"]["tokens"] == 18_000 * 15
    assert len(sizes) == 1 and sizes[0] > 8 * 1024 * 1024
    assert owner._slot is None and owner._rejected_binding is not None
    assert original(owner._rejected_binding) < 8 * 1024 * 1024


@pytest.mark.parametrize("mismatch", ["partial", "identity", "incomplete"])
def test_cap_decision_requires_complete_per_home_metadata(corpus, monkeypatch, mismatch):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_rows=1)
    if mismatch == "incomplete":
        original = worker._native_corpus_fingerprint
        monkeypatch.setattr(worker, "_native_corpus_fingerprint", lambda snapshot:
                            {key: {**value, "complete": False} for key, value in original(snapshot).items()})
    else:
        original = worker.scan_usage_all_homes
        def scan(*args, **kwargs):
            capture = kwargs["resolved_capture"]
            def observe(key, root, rows, coverage):
                if mismatch == "partial":
                    coverage = replace(coverage, status=usage_stats.UsageSourceStatus.PARTIAL, pending_files=1)
                else:
                    root = root.with_name("unmatched-root")
                capture(key, root, rows, coverage)
            kwargs["resolved_capture"] = observe
            return original(*args, **kwargs)
        monkeypatch.setattr(worker, "scan_usage_all_homes", scan)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._rejected_binding is None and owner._slot is None


def test_naturally_dated_narrow_window_can_admit_after_wide_rejection(corpus, monkeypatch, tmp_path):
    root, settings = corpus
    for path in root.glob("*.jsonl"):
        path.unlink()
    for age in range(54):
        write_rows(root / f"dated-{age:03}.jsonl",
                   [(age, f"synthetic-{age}-{index}", "claude-opus-4", 10) for index in range(20)], touched=False)
    owner = worker.NativeGraphReuse(maximum_rows=1_000)
    narrow = worker.usage_graph_document(settings, days=7, native_reuse=owner, provider_ids=("claude",))
    assert owner._slot is not None and owner._rejected_binding is None
    wide = worker.usage_graph_document(settings, days=365, native_reuse=owner, provider_ids=("claude",))
    assert owner._slot is None and owner._rejected_binding is not None
    # The broad persisted index retains broader pre-window rows. A fresh
    # narrow index can fit without any source-file or binding change.
    monkeypatch.setattr(worker, "default_state_dir", lambda: tmp_path / "narrow-index")
    again = worker.usage_graph_document(settings, days=7, native_reuse=owner, provider_ids=("claude",))
    assert again == narrow
    assert owner._slot is not None and owner._rejected_binding is None
    assert wide == worker.usage_graph_document(settings, days=365, provider_ids=("claude",))


def test_observe_clears_rejection_on_incomplete_witness(corpus):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_rows=1)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    rejected = owner._rejected_binding
    owner.observe(rejected.binding)
    assert owner._rejected_binding is rejected
    owner.observe(replace(rejected.binding, complete=False))
    assert owner._rejected_binding is None and owner._slot is None


def test_observe_clears_rejection_on_changed_complete_binding(corpus):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_rows=1)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    rejected = owner._rejected_binding
    changed = replace(rejected.binding, fingerprint=(("claude", "changed-complete-witness"),))
    assert changed.complete
    owner.observe(changed)
    assert owner._rejected_binding is None and owner._slot is None


def test_identity_mismatch_clears_rejection_during_skipped_admission(corpus, monkeypatch):
    _root, settings = corpus
    owner = worker.NativeGraphReuse(maximum_rows=1)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._rejected_binding is not None
    original = worker.scan_usage_all_homes
    def scan(*args, **kwargs):
        capture = kwargs["resolved_capture"]
        kwargs["resolved_capture"] = lambda key, root, rows, coverage: capture(
            key, root.with_name("different-source-root"), rows, coverage
        )
        return original(*args, **kwargs)
    monkeypatch.setattr(worker, "scan_usage_all_homes", scan)
    worker.usage_graph_document(settings, native_reuse=owner, provider_ids=("claude",))
    assert owner._rejected_binding is None and owner._slot is None
