"""Every Claude and Codex home is scanned, and each real folder once.

``CLAUDE_CONFIG_DIR``, ``CODEX_HOME`` and ``provider_extra_homes`` (for
claude-swap and friends) used to be ignored, so a second account's usage
was missing. A symlinked duplicate must not double a total either.
"""

from __future__ import annotations

import json
from pathlib import Path

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
