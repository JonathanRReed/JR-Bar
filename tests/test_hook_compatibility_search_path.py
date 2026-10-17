"""Where the installed-version probe looks for an agent's command."""

from __future__ import annotations

import os
from pathlib import Path

from jrbar.hook_compatibility import _search_path, locate_binary


def test_a_relative_path_entry_is_not_searched(tmp_path: Path, monkeypatch) -> None:
    planted = tmp_path / "somecli"
    planted.write_text("#!/bin/sh\nexit 0\n")
    planted.chmod(0o755)
    monkeypatch.chdir(tmp_path)

    entries = _search_path({"PATH": f".{os.pathsep}bin{os.pathsep}/usr/bin"}).split(os.pathsep)

    assert "." not in entries and "bin" not in entries
    assert "/usr/bin" in entries
    assert locate_binary("somecli", {"PATH": "."}) is None
