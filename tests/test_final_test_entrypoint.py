"""The owner receives one full, non-publishing final-test command."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_final_command_help_is_available_without_bootstrap_or_macos():
    result = subprocess.run(["bash", str(ROOT / "scripts/final-test.sh"), "--help"],
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0
    assert "--no-bootstrap" in result.stdout and "--allow-dirty" in result.stdout


def test_non_macos_final_command_refuses_before_bootstrap():
    if sys.platform == "darwin":
        return
    result = subprocess.run(["bash", str(ROOT / "scripts/final-test.sh"), "--no-bootstrap"],
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 2
    assert "requires macOS" in result.stderr


def test_final_command_keeps_full_build_and_test_gates_and_source_identity():
    script = (ROOT / "scripts/final-test.sh").read_text()
    assert "scripts/verify_fast.py" in script
    assert "./scripts/verify.sh --no-bootstrap" in script
    assert "--skip-build" not in script and "--skip-clean-install" not in script
    assert "SIDEPULSE_VERIFY_MACOS_PACKAGE=0" in script
    assert "git rev-parse HEAD" in script and "git status --porcelain" in script
    assert "--junitxml=" in script and "exit-code.txt" in script
    assert "final-test:" in (ROOT / "Makefile").read_text()
    assert ".jrbar-verification/" in (ROOT / ".gitignore").read_text()


def test_fast_and_portable_gates_include_control_center_regressions():
    for path in ("scripts/verify_fast.py", "scripts/verify.sh"):
        script = (ROOT / path).read_text()
        for test in ("test_creator_micro_wire_conformance.py", "test_creator_micro_setup.py",
                     "test_deck_control_center_contracts.py", "test_deck_final_readiness.py"):
            assert test in script, (path, test)


def test_fresh_checkout_bootstraps_before_selecting_venv_python(tmp_path):
    """Exercise the shell handoff with a fake Mac/toolchain, not real Mac gates."""
    import os
    import shlex

    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "final-test.sh").write_text((ROOT / "scripts/final-test.sh").read_text())
    (tmp_path / ".gitignore").write_text(".venv/\n.jrbar-verification/\nfake-bin/\n")
    tools = tmp_path / "fake-bin"
    tools.mkdir()
    for name, output in (("uname", "Darwin"), ("sw_vers", "Synthetic Mac shell fixture")):
        tool = tools / name
        tool.write_text(f"#!/bin/sh\nprintf '%s\\n' '{output}'\n")
        tool.chmod(0o755)
    interpreter = "#!/bin/bash\nif [ \"$1 $2\" = '-m pip' ]; then echo fixture-package==1; exit 0; fi\n"
    interpreter += f"exec {shlex.quote(sys.executable)} \"$@\"\n"
    bootstrap = scripts / "bootstrap-dev.sh"
    bootstrap.write_text(
        "#!/bin/bash\nset -eu\n"
        "if [ -n \"${PYTHON:-}\" ] && [ ! -x \"$PYTHON\" ]; then exit 9; fi\n"
        "mkdir -p .venv/bin\ncat > .venv/bin/python <<'INTERPRETER'\n"
        + interpreter + "INTERPRETER\nchmod +x .venv/bin/python\n"
    )
    bootstrap.chmod(0o755)
    (scripts / "verify_fast.py").write_text("import os\nassert not os.environ.get('PYTEST_ADDOPTS')\n")
    verify = scripts / "verify.sh"
    verify.write_text(
        "#!/bin/bash\nset -eu\n"
        "test \"$PYTHON\" = \"$PWD/.venv/bin/python\"\n"
        "[[ \"$PYTEST_ADDOPTS\" == --junitxml=* ]]\n"
        "[[ \"$PYTEST_ADDOPTS\" != *inherited-filter* ]]\n"
    )
    verify.chmod(0o755)
    for args in (("init", "-q"), ("add", "."),
                 ("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                  "commit", "-qm", "fixture")):
        subprocess.run(["git", *args], cwd=tmp_path, check=True, capture_output=True, timeout=5)
    env = dict(os.environ)
    for key in ("PYTHON", "VENV_DIR", "SIDEPULSE_DEV_VENV"):
        env.pop(key, None)
    env["PATH"] = str(tools) + os.pathsep + env["PATH"]
    env["PYTEST_ADDOPTS"] = "-k inherited-filter"
    result = subprocess.run(["bash", str(scripts / "final-test.sh")], cwd=tmp_path,
                            env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    reports = list((tmp_path / ".jrbar-verification").glob("*/exit-code.txt"))
    assert len(reports) == 1 and reports[0].read_text().strip() == "0"
