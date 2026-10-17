"""A relative PATH entry must never resolve the Codex or Claude binary.

CodexBar 0.71 stopped running binaries from the current directory or a
relative PATH entry (a planted ``codex`` in a project folder). JR-Bar's
daemon rarely has such a PATH, but both lookups now drop non-absolute
entries as well. Synthetic executables in a temporary directory.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path

import pytest

from jrbar import hook_compatibility, provider_reconnect


def _executable(directory: Path, name: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


@pytest.mark.parametrize("entry", (".", "bin", "./bin", "", "~/bin"))
def test_a_relative_path_entry_does_not_resolve_codex(monkeypatch, tmp_path: Path, entry: str) -> None:
    _executable(tmp_path / "bin", "codex")
    _executable(tmp_path, "codex")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PATH", entry)
    monkeypatch.setenv("HOME", str(tmp_path / "empty-home"))
    # Search no extra directory the machine happens to have a codex in.
    monkeypatch.setattr(provider_reconnect.Path, "home", classmethod(lambda cls: tmp_path / "empty-home"))

    resolved = provider_reconnect._resolved_codex_binary("codex")

    assert resolved is None or not Path(resolved).resolve().is_relative_to(tmp_path.resolve())


def test_an_absolute_path_entry_still_resolves_codex(monkeypatch, tmp_path: Path) -> None:
    found = _executable(tmp_path / "abs-bin", "codex")
    monkeypatch.setenv("PATH", str(tmp_path / "abs-bin"))

    assert provider_reconnect._resolved_codex_binary("codex") == str(found)


def test_a_path_with_both_kinds_uses_only_the_absolute_one(monkeypatch, tmp_path: Path) -> None:
    _executable(tmp_path / "planted", "codex")
    real = _executable(tmp_path / "abs-bin", "codex")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PATH", os.pathsep.join(("planted", str(tmp_path / "abs-bin"))))

    assert provider_reconnect._resolved_codex_binary("codex") == str(real)


def test_a_version_lookup_drops_relative_entries_too(monkeypatch, tmp_path: Path) -> None:
    _executable(tmp_path / "planted", "claude")
    monkeypatch.chdir(tmp_path)

    search = hook_compatibility._search_path({"PATH": os.pathsep.join(("planted", ".", "", "/usr/bin"))})

    parts = search.split(os.pathsep)
    assert "planted" not in parts and "." not in parts and "" not in parts
    assert "/usr/bin" in parts
    assert all(os.path.isabs(part) for part in parts)
