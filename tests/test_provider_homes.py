"""Every Claude and Codex home is scanned, and each real folder once.

``CLAUDE_CONFIG_DIR``, ``CODEX_HOME`` and ``provider_extra_homes`` (for
claude-swap and friends) used to be ignored, so a second account's usage
was missing. A symlinked duplicate must not double a total either.
"""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import usage_stats
from jrbar.provider_homes import (
    claude_homes,
    claude_project_roots,
    codex_homes,
    extra_scan_roots,
    home_scan_roots,
    normalized_extra_homes,
    opencode_data_root,
    primary_claude_projects,
    primary_codex_sessions,
    scan_usage_all_homes,
)
from jrbar.settings import load_settings


def _assistant_row(message_id: str, *, inp: int = 1000, out: int = 500) -> dict:
    return {
        "type": "assistant",
        "timestamp": "2026-09-20T12:00:00Z",
        "message": {
            "id": message_id,
            "model": "claude-sonnet-5",
            "usage": {
                "input_tokens": inp,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
                "output_tokens": out,
            },
        },
    }


def _transcript(root: Path, session: str, rows: list[dict]) -> None:
    path = root / "projects" / "proj" / f"{session}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")


def test_the_environment_home_comes_first(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / ".claude" / "projects").mkdir(parents=True)
    (home / ".codex" / "sessions").mkdir(parents=True)
    configured = tmp_path / "claude-work"
    (configured / "projects").mkdir(parents=True)
    codex_home = tmp_path / "codex-work"
    (codex_home / "sessions").mkdir(parents=True)
    env = {"CLAUDE_CONFIG_DIR": str(configured), "CODEX_HOME": str(codex_home)}

    assert claude_homes(env=env, home=home) == (configured, home / ".claude")
    assert codex_homes(env=env, home=home) == (codex_home, home / ".codex")
    assert primary_claude_projects(env=env, home=home) == configured / "projects"
    assert primary_codex_sessions(env=env, home=home) == codex_home / "sessions"
    # The default home is still read, as a second account.
    assert extra_scan_roots("claude", env=env, home=home) == (home / ".claude" / "projects",)
    # A variable naming a folder that is not there falls back to the default.
    missing = {"CLAUDE_CONFIG_DIR": str(tmp_path / "nowhere")}
    assert primary_claude_projects(env=missing, home=home) == home / ".claude" / "projects"


def test_extra_homes_are_absolute_only_and_capped() -> None:
    kept = normalized_extra_homes(
        {"claude": ["/Users/me/.claude-work", "relative/path", 3, "/Users/me/.claude-work"], "codex": "x", "grok": ["/a"]}
    )
    assert kept == {"claude": ("/Users/me/.claude-work",), "codex": ()}
    assert normalized_extra_homes(None) == {"claude": (), "codex": ()}


def test_symlinked_duplicates_are_counted_once(tmp_path: Path) -> None:
    home = tmp_path / "home"
    (home / ".claude" / "projects").mkdir(parents=True)
    work = tmp_path / "claude-work"
    (work / "projects").mkdir(parents=True)
    alias_of_default = tmp_path / "alias-default"
    alias_of_default.symlink_to(home / ".claude")
    alias_of_work = tmp_path / "alias-work"
    alias_of_work.symlink_to(work)
    extras = [str(alias_of_default), str(work), str(alias_of_work), str(work) + "/"]

    roots = extra_scan_roots("claude", env={}, home=home, extras=extras)

    assert roots == (work / "projects",)
    assert len(claude_project_roots(env={}, home=home, extras=extras)) == 2


def test_a_missing_directory_is_ignored(tmp_path: Path) -> None:
    home = tmp_path / "home"
    home.mkdir()

    assert claude_homes(env={}, home=home, extras=[str(tmp_path / "gone")]) == ()
    assert extra_scan_roots("codex", env={}, home=home, extras=[str(tmp_path / "gone")]) == ()
    assert home_scan_roots(["claude", "grok"], env={}, home=home, extras={}) == {
        "claude": (home / ".claude" / "projects",)
    }


def test_the_scan_adds_a_second_home_and_never_a_symlinked_copy(tmp_path: Path) -> None:
    home = tmp_path / "home"
    _transcript(home / ".claude", "s1", [_assistant_row("msg_a"), _assistant_row("msg_b")])
    work = tmp_path / "claude-work"
    _transcript(work, "s2", [_assistant_row("msg_c", inp=7000, out=1)])
    alias = tmp_path / "alias"
    alias.symlink_to(work)
    cache = tmp_path / "state" / "usage-scan-cache.json"
    cache.parent.mkdir(parents=True)

    alone = scan_usage_all_homes(cache, since_epoch=0.0, provider_ids=("claude",), env={}, home=home, extras={})
    both = scan_usage_all_homes(
        cache,
        since_epoch=0.0,
        provider_ids=("claude",),
        env={},
        home=home,
        extras={"claude": [str(work), str(alias)]},
    )

    assert alone.input_tokens == 2000
    assert both.input_tokens == 9000
    # Two sessions, three records: the symlinked copy of the work home
    # added nothing.
    assert len(both.records) == 3
    assert len(both.sessions) == 2


def test_the_codex_quota_evidence_stays_the_primary_accounts(tmp_path: Path) -> None:
    calls: list[tuple] = []

    def fake_scan(root, cache, *, since_epoch, codex_root=None, provider_ids=None):
        calls.append((root, codex_root, provider_ids))
        totals = usage_stats.UsageTotals()
        totals.codex_rate_limit_evidence = ({"account": "primary" if not calls[1:] else "other"},)
        totals.input_tokens = 10
        return totals

    home = tmp_path / "home"
    (home / ".codex" / "sessions").mkdir(parents=True)
    other = tmp_path / "codex-other"
    (other / "sessions").mkdir(parents=True)

    merged = scan_usage_all_homes(
        tmp_path / "cache.json",
        since_epoch=0.0,
        provider_ids=("codex",),
        env={},
        home=home,
        extras={"codex": [str(other)]},
        scan=fake_scan,
    )

    assert merged.input_tokens == 20
    assert merged.codex_rate_limit_evidence == ({"account": "primary"},)
    assert calls[1][1] == other / "sessions"
    assert calls[1][2] == ("codex",)


def test_the_setting_round_trips(tmp_path: Path) -> None:
    target = tmp_path / "settings.json"
    target.write_text(json.dumps({"provider_extra_homes": {"claude": ["/Users/me/.claude-b", "b"]}}))

    settings = load_settings(target)

    assert settings.provider_extra_homes == {"claude": ["/Users/me/.claude-b"], "codex": []}
    assert settings.to_dict()["provider_extra_homes"] == {"claude": ["/Users/me/.claude-b"], "codex": []}


def test_opencode_follows_xdg(tmp_path: Path) -> None:
    assert opencode_data_root(env={}, home=tmp_path) == tmp_path / ".local" / "share" / "opencode"
    assert opencode_data_root(env={"XDG_DATA_HOME": "/srv/data"}, home=tmp_path) == Path("/srv/data/opencode")
    assert opencode_data_root(env={"XDG_DATA_HOME": "rel"}, home=tmp_path) == tmp_path / ".local" / "share" / "opencode"


@pytest.mark.parametrize("reverse", [False, True])
@pytest.mark.parametrize("first, second, expected", [
    ("failed", "ok", "partial"), ("failed", "failed", "failed"),
    ("missing", "ok", "ok"), ("missing", "missing", "missing"),
    ("missing", "failed", "failed"), ("ok", "ok", "ok"),
    ("partial", "ok", "partial"), ("pending", "ok", "partial"),
    ("partial", "failed", "partial"),
])
def test_each_home_retains_coverage_in_both_scan_orders(tmp_path, first, second, expected, reverse):
    home = tmp_path / "home"
    other = tmp_path / "other"
    (home / ".claude" / "projects").mkdir(parents=True)
    (other / "projects").mkdir(parents=True)
    def coverage(kind):
        missing = kind == "missing"
        return usage_stats.UsageSourceCoverage(
            provider_id="claude", status=usage_stats.UsageSourceStatus("partial" if kind == "pending" else kind),
            root_present=not missing, root_walked=kind not in {"failed", "missing"},
            files_discovered=0 if missing else 3, files_read=1 if kind in {"ok", "partial", "pending"} else 0,
            cache_hits=1 if kind == "ok" else 0, malformed_lines=2 if kind == "partial" else 0,
            unreadable_files=1 if kind == "failed" else 0, skipped_symlinks=0 if missing else 1,
            duplicate_physical_files=0 if missing else 2, oversized_files=1 if kind == "partial" else 0,
            truncated_files=1 if kind == "partial" else 0, pending_files=2 if kind == "pending" else 0,
        )
    inputs = [coverage(first), coverage(second)]
    ordered = iter(reversed(inputs) if reverse else inputs)
    def scan(*_args, **_kwargs):
        return usage_stats.UsageTotals(source_coverage={"claude": next(ordered)})
    merged = scan_usage_all_homes(tmp_path / "cache.json", since_epoch=0, provider_ids=("claude",),
                                 env={}, home=home, extras={"claude": [str(other)]}, scan=scan).source_coverage["claude"]
    assert merged.status.value == expected
    for field in ("files_discovered", "files_read", "cache_hits", "malformed_lines", "unreadable_files",
                  "skipped_symlinks", "duplicate_physical_files", "oversized_files", "truncated_files", "pending_files"):
        assert getattr(merged, field) == sum(getattr(value, field) for value in inputs)
    assert merged.root_present == any(value.root_present for value in inputs)
    assert merged.root_walked == (merged.root_present and all(value.root_walked for value in inputs if value.root_present))


@pytest.mark.parametrize("reverse", [False, True])
@pytest.mark.parametrize("failure", ["read", "walk"])
def test_failed_home_plus_healthy_home_remains_uncached_in_graph(tmp_path, monkeypatch, reverse, failure):
    from jrbar import local_token_history, usage_graph_worker
    home = tmp_path / "home"
    other = tmp_path / "other"
    (home / ".claude" / "projects").mkdir(parents=True)
    (other / "projects").mkdir(parents=True)
    def coverage(status):
        return usage_stats.UsageSourceCoverage(
            provider_id="claude", status=status, root_present=True,
            root_walked=status is usage_stats.UsageSourceStatus.OK,
            files_discovered=1, files_read=int(status is usage_stats.UsageSourceStatus.OK),
            cache_hits=0, malformed_lines=0,
            unreadable_files=int(failure == "read" and status is usage_stats.UsageSourceStatus.FAILED),
            skipped_symlinks=0, duplicate_physical_files=0,
        )
    parts = [coverage(usage_stats.UsageSourceStatus.FAILED), coverage(usage_stats.UsageSourceStatus.OK)]
    parts = list(reversed(parts)) if reverse else parts
    def all_homes(*_args, **_kwargs):
        readings = iter(parts)
        return scan_usage_all_homes(tmp_path / "scan-cache.json", since_epoch=0, provider_ids=("claude",),
                                    env={}, home=home, extras={"claude": [str(other)]},
                                    scan=lambda *_args, **_kwargs:
                                    usage_stats.UsageTotals(source_coverage={"claude": next(readings)}))
    monkeypatch.setattr(usage_graph_worker, "scan_usage_all_homes", all_homes)
    monkeypatch.setattr(usage_graph_worker, "default_state_dir", lambda: tmp_path)
    monkeypatch.setattr(usage_graph_worker, "_usage_doc_cache_path", lambda: tmp_path / "graph-cache.json")
    monkeypatch.setattr(usage_graph_worker, "_corpus_fingerprint", lambda *_args, **_kwargs: {})
    monkeypatch.setattr(local_token_history, "scan_local_records", lambda *_args, **_kwargs: [])
    original_build = usage_graph_worker._build_payload
    builds = []
    def build(*args, **kwargs):
        builds.append(1)
        return original_build(*args, **kwargs)
    monkeypatch.setattr(usage_graph_worker, "_build_payload", build)
    settings = SimpleNamespace(usage_graph_days=7, usage_display_mode="tokens", usage_graph_providers=("claude",))
    first = usage_graph_worker.usage_graph_document(settings, provider_ids=("claude",))
    usage_graph_worker.usage_graph_document(settings, provider_ids=("claude",))
    assert first["graph"]["partial_provider_ids"] == ["claude"]
    assert "Partial local history: Claude" in first["summary"]
    assert builds == [1, 1]
