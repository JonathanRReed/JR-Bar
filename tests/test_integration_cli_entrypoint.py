from __future__ import annotations

import ast
import os
import sys
from pathlib import Path
from types import SimpleNamespace

from jrbar import cli_entry

ROOT = Path(__file__).resolve().parents[1]


def _source_tree(path: Path) -> ast.AST:
    return ast.parse(path.read_text(encoding="utf-8"))


def test_public_cli_routes_provider_integration_and_foreground_status_commands(
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
    monkeypatch.setitem(
        sys.modules,
        "jrbar.provider_usage_status_bar",
        SimpleNamespace(main=lambda: calls.append(("status-bar", ())) or 29),
    )

    assert cli_entry.jrbar_main(["integrations", "status", "--json"]) == 17
    assert cli_entry.jrbar_main(["providers", "status", "--json"]) == 19
    assert cli_entry.jrbar_main(["status-bar", "--foreground"]) == 29
    assert cli_entry.jrbar_main(["status-bar", "start", "--foreground"]) == 29
    assert cli_entry.jrbar_main(["doctor", "--json"]) == 23
    assert calls == [
        ("integrations", ["status", "--json"]),
        ("providers", ["status", "--json"]),
        ("status-bar", ()),
        ("status-bar", ()),
        ("legacy", ["doctor", "--json"]),
    ]


def test_cli_entrypoint_keeps_the_foreground_status_bar_import_inside_the_branch() -> None:
    tree = _source_tree(ROOT / "src" / "jrbar" / "cli_entry.py")

    top_level_imports = [
        node
        for node in tree.body
        if isinstance(node, ast.ImportFrom)
        and node.module == "provider_usage_status_bar"
    ]
    nested_imports = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom)
        and node.module == "provider_usage_status_bar"
    ]

    assert top_level_imports == []
    assert len(nested_imports) == 1
    assert nested_imports[0].names[0].name == "main"
    assert nested_imports[0].names[0].asname == "status_bar_main"


def test_bundled_daemon_entry_is_the_public_router_only() -> None:
    # jrbar-core (the frozen helper inside JR-Bar.app) is the CLI router:
    # `core`, `agent-monitor install all`, `hooks doctor`, `doctor`. The
    # Swift app is the UI, so the old no-argument status-bar branch is gone.
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


def test_provider_usage_status_bar_supports_direct_module_startup() -> None:
    tree = _source_tree(ROOT / "src" / "jrbar" / "provider_usage_status_bar.py")

    guards = [
        node
        for node in tree.body
        if isinstance(node, ast.If)
        and isinstance(node.test, ast.Compare)
        and isinstance(node.test.left, ast.Name)
        and node.test.left.id == "__name__"
        and len(node.test.ops) == 1
        and isinstance(node.test.ops[0], ast.Eq)
        and len(node.test.comparators) == 1
        and isinstance(node.test.comparators[0], ast.Constant)
        and node.test.comparators[0].value == "__main__"
    ]

    assert len(guards) == 1
    guard = guards[0]
    system_exit_calls = [
        node
        for node in ast.walk(guard)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "SystemExit"
    ]
    assert system_exit_calls, "expected a direct module guard to raise SystemExit(main())"
