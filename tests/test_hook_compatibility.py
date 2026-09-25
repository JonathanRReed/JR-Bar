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
    node_package_version,
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


def _node_cli(root: Path, package: str, entry: str, version: str) -> Path:
    """A node CLI laid out the way npm and Homebrew install one."""
    package_dir = root / "lib" / "node_modules" / package
    script = package_dir / entry
    script.parent.mkdir(parents=True)
    script.write_text("#!/usr/bin/env node\n", encoding="utf-8")
    name = package.rsplit("/", 1)[-1]
    (package_dir / "package.json").write_text(
        json.dumps({"name": package, "version": version, "bin": {name: entry}}), encoding="utf-8"
    )
    link = root / "bin" / name
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(script)
    return link


def test_a_node_cli_is_read_from_its_package_without_running_it(tmp_path: Path) -> None:
    pi = _node_cli(tmp_path, "@mariozechner/pi-coding-agent", "dist/cli.js", "0.73.1")
    gemini = _node_cli(tmp_path / "gemini", "@google/gemini-cli", "bundle/gemini.js", "0.46.0")
    plain = _node_cli(tmp_path / "plain", "opencode-ai", "./bin/opencode", "1.2.3")

    assert node_package_version(str(pi.resolve())) == "0.73.1"
    assert node_package_version(str(gemini.resolve())) == "0.46.0"
    assert node_package_version(str(plain.resolve())) == "1.2.3"
    # A file the package's bin doesn't name is not the CLI.
    helper = pi.resolve().parent / "helper.js"
    helper.write_text("", encoding="utf-8")
    assert node_package_version(str(helper)) is None
    assert node_package_version("/usr/bin/true") is None

    def runner(argv: list[str]) -> str:
        raise AssertionError(f"ran {argv[0]}: a node CLI must be read from its package")

    versions = installed_versions(
        {"pi": "pi", "gemini": "gemini"},
        runner=runner,
        locate=lambda name: str(pi if name == "pi" else gemini),
    )
    assert versions["pi"]["version"] == "0.73.1"
    assert versions["gemini"]["version"] == "0.46.0"
    rows = compatibility_rows(["pi", "gemini"], runner=runner, locate=lambda name: str(pi if name == "pi" else gemini))
    assert rows["pi"]["compatibility"]["status"] == "supported"
    assert rows["gemini"]["compatibility"]["status"] == "supported"


def test_a_failed_version_read_is_cached_for_a_day(tmp_path: Path) -> None:
    binary = tmp_path / "slow"
    binary.write_text("#!/bin/sh\n", encoding="utf-8")
    calls: list[list[str]] = []

    def runner(argv: list[str]) -> str | None:
        calls.append(argv)
        return None  # the two seconds ran out

    cache_path = tmp_path / "versions.json"

    def read(now: float) -> dict:
        return installed_versions(
            {"slow": "slow"},
            cache=VersionCache(cache_path),
            runner=runner,
            locate=lambda _name: str(binary),
            clock=lambda: now,
        )

    assert read(1_000.0)["slow"]["version"] is None
    assert read(1_000.0 + 3_600)["slow"]["version"] is None
    assert len(calls) == 1, "opening the Agents settings again must not start the CLI again"
    read(1_000.0 + 86_400)
    assert len(calls) == 2, "a day later it is asked again"


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
