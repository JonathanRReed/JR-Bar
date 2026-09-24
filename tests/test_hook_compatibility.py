"""Hook compatibility ranges and the doctor's version column.

``jrbar hooks doctor`` could not say "Claude 2.1.280 is newer than we
verified". The manifest records what verify_providers_live.py ran, and a
version outside it is a neutral note, never a warning.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar.hook_compatibility import (
    VersionCache,
    classify,
    compatibility_rows,
    installed_versions,
    load_compatibility_manifest,
    parse_version,
    range_matches,
)
from jrbar.hook_doctor import hook_doctor_report, render_hook_doctor
from jrbar.providers import PROVIDER_REGISTRY

T3_SHAPED = json.dumps(
    {
        "schemaVersion": 1,
        "providers": [
            {
                "provider": "claude",
                "binary": "claude",
                "recommended": "2.1.280",
                "ranges": [
                    {"range": ">=2.1.280", "status": "supported"},
                    {"range": ">=2.1.111 <2.1.280", "status": "graceful"},
                    {"range": "<2.1.111", "status": "unsupported"},
                ],
            },
            {
                "provider": "codex",
                "binary": "codex",
                "recommended": "0.153.4",
                "ranges": [{"range": "=0.153.4", "status": "supported"}],
            },
        ],
    }
)


def test_versions_parse_from_what_the_clis_print() -> None:
    assert parse_version("2.1.280 (Claude Code)") == (2, 1, 280)
    assert parse_version("codex-cli 0.153.4") == (0, 153, 4)
    assert parse_version("v0.73.1") == (0, 73, 1)
    assert parse_version("gemini 0.46") == (0, 46)
    assert parse_version("no version here") is None
    assert parse_version(None) is None


def test_ranges() -> None:
    assert range_matches(">=2.1.111 <2.1.280", (2, 1, 200))
    assert not range_matches(">=2.1.111 <2.1.280", (2, 1, 280))
    assert range_matches("=0.153.4", (0, 153, 4))
    assert range_matches("0.153.4", (0, 153, 4))
    assert not range_matches("=0.153.4", (0, 153, 5))
    assert range_matches("<1.0 || >=3.0", (3, 2))
    assert not range_matches("banana", (1, 0))


def test_status_selection_follows_the_manifest() -> None:
    records = load_compatibility_manifest(T3_SHAPED)

    assert classify(records["claude"], "2.1.281 (Claude Code)").status == "supported"
    assert classify(records["claude"], "2.1.200").status == "graceful"
    assert classify(records["claude"], "2.1.100").status == "unsupported"
    newer = classify(records["codex"], "codex-cli 0.160.0")
    assert (newer.status, newer.note) == ("unknown", "newer than verified (0.153.4)")
    older = classify(records["codex"], "codex-cli 0.150.0")
    assert older.note == "older than verified (0.153.4)"
    assert classify(None, "1.0").note == "no verified version on record"
    assert classify(records["codex"], None).note == "version not read"


def test_the_shipped_manifest_covers_every_hook_provider() -> None:
    records = load_compatibility_manifest()

    assert set(records) == set(PROVIDER_REGISTRY)
    assert records["claude"].recommended == "2.1.263"
    assert classify(records["claude"], "2.1.280 (Claude Code)").note == "newer than verified (2.1.263)"
    assert classify(records["codex"], "codex-cli 0.153.4").status == "supported"


def test_versions_are_read_once_per_binary_and_cached(tmp_path: Path) -> None:
    binary = tmp_path / "claude"
    binary.write_text("#!/bin/sh\n", encoding="utf-8")
    calls: list[list[str]] = []

    def runner(argv: list[str]) -> str:
        calls.append(argv)
        return "2.1.280 (Claude Code)"

    cache_path = tmp_path / "versions.json"
    first = installed_versions(
        {"claude": "claude", "grok": "grok"},
        cache=VersionCache(cache_path),
        runner=runner,
        locate=lambda name: str(binary) if name == "claude" else None,
    )
    second = installed_versions(
        {"claude": "claude"},
        cache=VersionCache(cache_path),
        runner=runner,
        locate=lambda name: str(binary),
    )

    assert first == {"claude": {"path": str(binary), "version": "2.1.280 (Claude Code)"}}
    assert second == first
    assert calls == [[str(binary), "--version"]]


def test_the_doctor_json_carries_version_and_compatibility(tmp_path: Path) -> None:
    def compatibility(providers: list[str], _state_dir: Path) -> dict:
        return compatibility_rows(
            providers,
            runner=lambda _argv: "2.1.280 (Claude Code)",
            locate=lambda name: "/usr/bin/true" if name == "claude" else None,
        )

    report = hook_doctor_report(tmp_path, compatibility=compatibility)
    rows = {entry["provider"]: entry for entry in report["providers"]}

    assert rows["claude"]["version"] == "2.1.280"
    assert rows["claude"]["compatibility"] == {
        "status": "unknown",
        "note": "newer than verified (2.1.263)",
        "verified": "2.1.263",
    }
    assert rows["grok"]["version"] is None
    assert rows["grok"]["compatibility"]["note"] == "CLI not found on this Mac"
    text = render_hook_doctor(report)
    assert "version 2.1.280 (newer than verified (2.1.263))" in text


def test_a_test_home_never_spawns_a_real_cli(tmp_path: Path, monkeypatch) -> None:
    import jrbar.hook_compatibility as module

    def forbidden(*_args, **_kwargs):
        raise AssertionError("the doctor ran a real CLI for a test home")

    monkeypatch.setattr(module, "compatibility_rows", forbidden)
    report = hook_doctor_report(tmp_path)
    assert all(entry["compatibility"]["note"] == "version not read" for entry in report["providers"])


@pytest.mark.parametrize("bad", ['{"schemaVersion": 2}', '{"schemaVersion": 1, "providers": [{"provider": "x", "ranges": [{"range": "1", "status": "fine"}]}]}'])
def test_a_bad_manifest_is_refused(bad: str) -> None:
    with pytest.raises(ValueError):
        load_compatibility_manifest(bad)
