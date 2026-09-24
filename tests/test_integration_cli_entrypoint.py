from __future__ import annotations

import ast
import os
from pathlib import Path

from jrbar import cli_entry

ROOT = Path(__file__).resolve().parents[1]


def _source_tree(path: Path) -> ast.AST:
    return ast.parse(path.read_text(encoding="utf-8"))


def test_public_cli_routes_provider_integration_and_legacy_commands(
    monkeypatch,
) -> None:
    calls = []
    monkeypatch.setattr(
        cli_entry,
        "integration_main",
        lambda args: calls.append(("integrations", args)) or 17,
    )
    monkeypatch.setattr(
        cli_entry,
        "provider_main",
        lambda args: calls.append(("providers", args)) or 19,
    )
    monkeypatch.setattr(
        cli_entry,
        "_legacy_jrbar_main",
        lambda args: calls.append(("legacy", args)) or 23,
    )

    assert cli_entry.jrbar_main(["integrations", "status", "--json"]) == 17
    assert cli_entry.jrbar_main(["providers", "status", "--json"]) == 19
    # `status-bar` is the sleep helper's verb now; it goes to the CLI like
    # any other, never to the retired menu bar.
    assert cli_entry.jrbar_main(["status-bar", "sleep-helper-status"]) == 23
    assert cli_entry.jrbar_main(["doctor", "--json"]) == 23
    assert calls == [
        ("integrations", ["status", "--json"]),
        ("providers", ["status", "--json"]),
        ("legacy", ["status-bar", "sleep-helper-status"]),
        ("legacy", ["doctor", "--json"]),
    ]


def test_cli_entrypoint_never_starts_the_retired_menu_bar__and_1_more() -> None:
    # --- scenario: cli_entrypoint_never_starts_the_retired_menu_bar
    # `status-bar --foreground` ran the PyObjC menu bar; the Swift app is
    # the UI now, so the router imports none of it.
    tree = _source_tree(ROOT / "src" / "jrbar" / "cli_entry.py")

    imported = [
        node.module
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom)
    ]

    assert "provider_usage_status_bar" not in imported
    assert "status_bar" not in imported

    # --- scenario: bundled_daemon_entry_is_the_public_router_only
    source = (ROOT / "packaging" / "jrbar_entry.py").read_text(encoding="utf-8")

    assert "from jrbar.cli_entry import jrbar_main" in source
    assert "from jrbar.cli import jrbar_main" not in source
    assert "provider_usage_status_bar" not in source
    assert "status_bar_main" not in source



def test_bundled_daemon_entry_emulates_python_dash_m(tmp_path) -> None:
    # `jrbar-core -m jrbar.hook_client ...` must behave like
    # `python -m jrbar.hook_client ...` so an interpreter-style hook command
    # can name the frozen binary.
    import runpy
    import subprocess
    import sys

    entry = ROOT / "packaging" / "jrbar_entry.py"
    probe = tmp_path / "jrbar_entry_probe.py"
    probe.write_text("import sys\nprint('probe', sys.argv[0].endswith('jrbar_entry_probe.py'), sys.argv[1:])\n", encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(entry), "-m", "jrbar_entry_probe", "--flag", "value"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
        cwd=tmp_path,
        env={**os.environ, "PYTHONPATH": f"{tmp_path}{os.pathsep}{ROOT / 'src'}"},
    )

    assert result.returncode == 0, result.stderr
    # Like `python -m`: argv[0] is the module's file, the rest is untouched.
    assert "probe True ['--flag', 'value']" in result.stdout
    assert runpy.run_module  # the entry uses runpy; keep the import honest
