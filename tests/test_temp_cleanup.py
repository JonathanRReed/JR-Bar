from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path

import pytest

from scripts.check_temp_leaks import leftover_entries, run

ROOT = Path(__file__).resolve().parents[1]


def test_guard_compares_names_without_removing_existing_entries(tmp_path):
    existing = tmp_path / "jrbar-existing"
    existing.mkdir()
    before = {path.name for path in tmp_path.iterdir()}
    (tmp_path / "jrbar-new").mkdir()
    assert leftover_entries(tmp_path, before) == ["jrbar-new"]
    assert existing.is_dir()


@pytest.mark.parametrize("leak", [False, True])
def test_command_guard_detects_leaks_and_removes_only_its_run(leak, tmp_path):
    marker = tmp_path / "root.txt"
    script = (
        "import os; from pathlib import Path; "
        f"Path({str(marker)!r}).write_text(os.environ['TMPDIR']); "
        + ("(Path(os.environ['TMPDIR']) / 'TemporaryDirectory.leaked').mkdir()" if leak else "")
    )
    assert run([sys.executable, "-c", script]) == int(leak)
    assert not Path(marker.read_text()).exists()
    assert marker.is_file()


@pytest.mark.parametrize(("leak", "builder", "discarded", "workers"), [
    (False, False, False, 0), (True, False, False, 0),
    (False, True, False, 0), (False, True, True, 0),
    (False, False, False, 2), (True, False, False, 2),
])
def test_session_finish_detects_leaks_before_sandbox_cleanup(tmp_path, leak, builder, discarded, workers):
    project = tmp_path / "project"
    project.mkdir()
    (project / "conftest.py").write_text((ROOT / "tests/conftest.py").read_text())
    (project / "pytest.ini").write_text(
        "[pytest]\ntmp_path_retention_count = 0\ntmp_path_retention_policy = none\n"
    )
    body = (
        "import tempfile\nfrom pathlib import Path\n"
        "def test_sample(tmp_path):\n"
        "    (tmp_path / 'fixture-file').touch()\n"
    )
    if leak:
        body += "    (Path(tempfile.gettempdir()) / 'jrbar-leaked').mkdir()\n"
    if builder:
        body += (
            "    import os, selectors, subprocess, sys\n"
            "    from jrbar.token_history_index import shared_index\n"
            "    index = shared_index(Path(os.environ['XDG_STATE_HOME']) / 'jrbar/token-history.sqlite3')\n"
            "    child = subprocess.Popen([sys.executable, '-c', "
            "'import signal; print(1, flush=True); signal.pause()'], stdout=subprocess.PIPE)\n"
            "    index.child = child\n"
            "    with selectors.DefaultSelector() as ready:\n"
            "        ready.register(child.stdout, selectors.EVENT_READ)\n"
            "        assert ready.select(timeout=5)\n"
            "    assert child.stdout.readline() == b'1\\n'\n"
            f"    Path({str(project / 'child.pid')!r}).write_text(str(child.pid))\n"
        )
    if discarded:
        body += "    from jrbar import token_history_index; token_history_index._INDEXES.clear()\n"
    if builder:
        (project / "late_history.py").write_text(
            "def pytest_sessionfinish(session, exitstatus):\n"
            "    from jrbar import token_history_index as history\n"
            "    history.set_enabled(True)\n"
            "    assert not history.history_enabled(), 'shutdown reopened history'\n"
        )
        with (project / "conftest.py").open("a") as stream:
            stream.write("\npytest_plugins = ['late_history']\n")
    (project / "test_sample.py").write_text(body)
    run_temp = tmp_path / "temp"
    run_temp.mkdir()
    if workers:
        (project / "late_sandbox.py").write_text(
            "import os, pytest\nfrom pathlib import Path\n"
            "@pytest.hookimpl(trylast=True)\n"
            "def pytest_unconfigure(config):\n"
            "    if hasattr(config, 'workerinput'):\n"
            "        state = Path(os.environ['XDG_STATE_HOME'])\n"
            "        state.mkdir(parents=True, exist_ok=True)\n"
            "        (state / 'late-worker-write').touch()\n"
        )
        with (project / "conftest.py").open("a") as stream:
            stream.write("\npytest_plugins = ['late_sandbox']\n")
    command = [sys.executable, "-m", "pytest", "-q", str(project)]
    if workers:
        command.extend(["-n", str(workers), "--dist", "loadfile"])
    result = subprocess.run(
        command,
        env=dict(os.environ, TMPDIR=str(run_temp)),
        capture_output=True, text=True, check=False, timeout=60,
    )
    if builder:
        child_pid = int((project / "child.pid").read_text())
        try:
            with pytest.raises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            try:
                os.kill(child_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    assert result.returncode == int(leak), result.stdout + result.stderr
    assert f"temporary entries left by this run: {int(leak)}" in result.stdout
    assert list(run_temp.iterdir()) == []


def test_tests_use_fixture_owned_temporary_paths():
    import ast

    unmanaged = []
    for source in (ROOT / "tests").glob("*.py"):
        for node in ast.walk(ast.parse(source.read_text())):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                continue
            name = node.func.attr
            if name in {"mkdtemp", "mkstemp"} or (
                name == "NamedTemporaryFile" and any(
                    keyword.arg == "delete" and isinstance(keyword.value, ast.Constant)
                    and keyword.value.value is False for keyword in node.keywords
                )
            ):
                unmanaged.append(f"{source.name}:{node.lineno}")
    assert not unmanaged, f"Use tmp_path or short_tmp_path: {unmanaged}"


@pytest.mark.skipif(sys.platform != "darwin", reason="Foundation guard runs on macOS")
def test_swift_guard_catches_foundation_leaks(tmp_path):
    library = tmp_path / "guard.dylib"
    subprocess.run(
        ["xcrun", "clang", "-dynamiclib", "-framework", "Foundation",
         str(ROOT / "scripts/test_temp_directory.m"), "-o", str(library)],
        check=True, capture_output=True,
    )
    source = tmp_path / "probe.m"
    source.write_text(
        '#import <Foundation/Foundation.h>\n'
        'int main() { @autoreleasepool {\n'
        ' NSFileManager *fm = [NSFileManager defaultManager];\n'
        ' [fm createDirectoryAtURL:[[fm temporaryDirectory] URLByAppendingPathComponent:@"jrbar-leak"]'
        ' withIntermediateDirectories:NO attributes:nil error:NULL];\n'
        ' [fm createDirectoryAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"TemporaryDirectory.leak"]'
        ' withIntermediateDirectories:NO attributes:nil error:NULL];\n'
        '} return 0; }\n'
    )
    binary = tmp_path / "JRBarTempTests"
    subprocess.run(
        ["xcrun", "clang", "-framework", "Foundation", str(source), "-o", str(binary)],
        check=True, capture_output=True,
    )
    assert run([str(binary)], environment_overrides={"DYLD_INSERT_LIBRARIES": str(library)}) == 1
