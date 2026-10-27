"""Production candidate checks use inert verifier and notary tools."""

import json
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "packaging/build_macos_pkg.sh"


def functions():
    source = SCRIPT.read_text()
    transport_default = next(line for line in source.splitlines() if line.startswith("NOTARY_NO_S3_ACCELERATION="))
    return transport_default + "\nNOTARY_TIMEOUT_SECONDS=100\n" + source[source.index("require_production_candidate() {"):source.index('SPARKLE_ARCHIVE="')]


def run(tmp_path, body, **values):
    verifier = tmp_path / "verify.py"
    verifier.write_text("import json,sys; print(json.dumps(sys.argv[1:]))\n")
    env = {"JRBAR_PRODUCTION_CANDIDATE": "1", "ALLOW_UNSIGNED": "0",
           "APP_SIGN_IDENTITY": "Developer ID Application: Fixture (FIXTURE)",
           "INSTALLER_SIGN_IDENTITY": "Developer ID Installer: Fixture (FIXTURE)",
           "NOTARIZE": "1", "EMBEDDED_SOURCE_VERIFY_SCRIPT": str(verifier),
           "BUILD_PYTHON": sys.executable,
           "BUILD_DIR": str(tmp_path / "build"), "DIST_DIR": str(tmp_path / "dist"),
           "HELPERS": str(tmp_path / "candidate.app/Contents/Helpers"), "ROOT_DIR": str(tmp_path / "source"),
           "RAW_EVIDENCE_DIR": str(tmp_path / "evidence"), **values}
    if "notarize_and_wait " in body:
        root = tmp_path / "notary-source"
        (root / "packaging").mkdir(parents=True, exist_ok=True)
        source = (SCRIPT.parent / "notarize.py").read_text()
        # Replace waiting with a deterministic clock advance in the subprocess.
        clock = "import time\n_now=[0.0]\ntime.monotonic=lambda: _now[0]\ntime.sleep=lambda seconds: _now.__setitem__(0, _now[0]+seconds)\n"
        (root / "packaging/notarize.py").write_text(clock + source)
        env["ROOT_DIR"] = str(root)
    return subprocess.run(["/bin/bash", "-c", "set -euo pipefail\n" + functions() + body],
                          env=env, capture_output=True, text=True, timeout=10)


@pytest.mark.parametrize("values", [
    {"APP_SIGN_IDENTITY": ""}, {"INSTALLER_SIGN_IDENTITY": ""},
    {"APP_SIGN_IDENTITY": "Nautilus Local Dev"}, {"NOTARIZE": "0"},
    {"ALLOW_UNSIGNED": "1"}, {"EMBEDDED_SOURCE_VERIFY_SCRIPT": ""},
])
def test_production_refuses_missing_requirements_before_submission(tmp_path, values):
    result = run(tmp_path, 'require_production_candidate\necho SUBMITTED\n', **values)
    assert result.returncode != 0
    assert "SUBMITTED" not in result.stdout


def test_unsigned_local_mode_still_requires_no_production_tools(tmp_path):
    result = run(tmp_path, 'require_production_candidate\nverify_embedded_source\n',
                 JRBAR_PRODUCTION_CANDIDATE="0", ALLOW_UNSIGNED="1", NOTARIZE="0",
                 APP_SIGN_IDENTITY="", INSTALLER_SIGN_IDENTITY="", EMBEDDED_SOURCE_VERIFY_SCRIPT="")
    assert result.returncode == 0, result.stderr


def test_embedded_verifier_receives_candidate_source_and_receipt(tmp_path):
    result = run(tmp_path, 'require_production_candidate\nverify_embedded_source\n')
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == [str(tmp_path / "candidate.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core"),
                                       str(tmp_path / "source/src"),
                                       str(tmp_path / "evidence/embedded-source-verification.json")]


def test_verifier_failure_prevents_submission(tmp_path):
    failed = tmp_path / "failed.py"
    failed.write_text("raise SystemExit(7)\n")
    result = run(tmp_path, 'require_production_candidate\nverify_embedded_source\necho SUBMITTED\n',
                 EMBEDDED_SOURCE_VERIFY_SCRIPT=str(failed))
    assert result.returncode != 0 and "SUBMITTED" not in result.stdout


def test_verification_hook_precedes_actual_app_submission():
    source = SCRIPT.read_text()
    call = source.index("\nverify_embedded_source\n")
    assert source.index("packaging/verify_sparkle_bundle.py") < call
    assert call < source.index('notarize_and_wait "$APP_NOTARY_ZIP"')
    assert "timeout=60" in source


@pytest.mark.parametrize("changed", [None, "app/Main.swift", "hook/main.c"])
def test_source_drift_blocks_the_submission_boundary(tmp_path, changed):
    root = tmp_path / "source"
    (root / "packaging").mkdir(parents=True)
    shutil.copyfile(SCRIPT.parent / "build_input_manifest.py", root / "packaging/build_input_manifest.py")
    for name in ["app/Main.swift", "hook/main.c"]:
        path = root / name
        path.parent.mkdir(exist_ok=True)
        path.write_text("fixture\n")
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    mutation = ""
    if changed:
        mutation = f"printf changed >> {shlex.quote(str(root / changed))}\n"
    result = run(tmp_path, "validate_build_inputs\ncapture_build_inputs\n" + mutation
                 + "verify_build_inputs\necho SUBMISSION_REACHED\n")
    assert (result.returncode == 0) is (changed is None), result.stderr
    assert ("SUBMISSION_REACHED" in result.stdout) is (changed is None)


def test_source_guards_cover_cleanup_build_and_both_notary_boundaries():
    source = SCRIPT.read_text()
    assert source.index("\nvalidate_build_inputs\n") < source.index('/bin/rm -rf "$BUILD_DIR"')
    assert source.index("\ncapture_build_inputs\n") < source.index('"$BUILD_PYTHON" -m venv')
    assert source.index("\nverify_build_inputs\n") < source.index('notarize_and_wait "$APP_NOTARY_ZIP"')
    package_call = source.index('"$VENV_DIR/bin/python" "$ROOT_DIR/scripts/package_macos_artifact.py"')
    assert source.rfind("\nverify_build_inputs\n", 0, package_call) > source.index("package_args=(")
    assert "verify_build_inputs\n    echo \"==> notarizing the package\"" in source


@pytest.mark.parametrize("cleanup_fails", [False, True])
def test_post_notary_metadata_is_removed_without_changing_signed_files(tmp_path, cleanup_fails):
    app = tmp_path / "candidate with spaces.app"
    executable = app / "Contents/MacOS/fixture"
    ticket = app / "Contents/CodeResources"
    nested = app / "Contents/Helpers/fixture-core.app"
    executable.parent.mkdir(parents=True)
    nested.mkdir(parents=True)
    executable.write_bytes(b"signed executable fixture")
    root = tmp_path / "source"
    scripts = root / "packaging"
    scripts.mkdir(parents=True)
    verifier = scripts / "verify_macos_app.py"
    verifier.write_text(
        "import pathlib,sys\n"
        "app=pathlib.Path(sys.argv[1])\n"
        "assert not list(app.rglob('.finder-info')), 'candidate signature rejected Finder metadata'\n"
        "assert (app/'Contents/MacOS/fixture').read_bytes()==b'signed executable fixture'\n"
        "assert (app/'Contents/CodeResources').read_bytes()==b'validated ticket fixture'\n"
    )
    shutil.copy2(verifier, scripts / "verify_sparkle_bundle.py")
    venv = tmp_path / "venv"
    (venv / "bin").mkdir(parents=True)
    (venv / "bin/python").symlink_to(sys.executable)
    calls = tmp_path / "calls.jsonl"
    tool = tmp_path / "xcrun"
    tool.write_text(
        f"#!{sys.executable}\nimport json,pathlib,sys\n"
        f"with open({str(calls)!r},'a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')\n"
        "assert sys.argv[1:3] in [['stapler','staple'],['stapler','validate']]\n"
        "app=pathlib.Path(sys.argv[3])\n"
        "if sys.argv[2]=='staple':\n"
        " (app/'Contents/CodeResources').write_bytes(b'validated ticket fixture')\n"
        " for p in [app,app/'Contents/Helpers/fixture-core.app']:(p/'.finder-info').touch()\n"
        "else: assert (app/'Contents/CodeResources').read_bytes()==b'validated ticket fixture'\n"
    )
    tool.chmod(0o755)
    cleaner = tmp_path / "xattr"
    cleaner.write_text(
        f"#!{sys.executable}\nimport json,pathlib,sys\n"
        f"with open({str(calls)!r},'a') as f:f.write(json.dumps(['xattr',*sys.argv[1:]])+'\\n')\n"
        f"assert sys.argv[1:]==['-cr',{str(app)!r}]\n"
        f"if {cleanup_fails!r}:raise SystemExit(7)\n"
        "for p in pathlib.Path(sys.argv[2]).rglob('.finder-info'):p.unlink()\n"
    )
    cleaner.chmod(0o755)
    source = SCRIPT.read_text()
    start = source.index('    "$XCRUN_TOOL" stapler staple "$APP_PATH"')
    end = source.index('\nfi\n\necho "==> Sparkle archive', start)
    result = run(tmp_path, source[start:end] + '\necho ARCHIVE_READY\n',
                 APP_PATH=str(app), XCRUN_TOOL=str(tool), XATTR_TOOL=str(cleaner),
                 VENV_DIR=str(venv), ROOT_DIR=str(root), SIGNED_TEAM="FIXTURE")
    observed = [json.loads(line) for line in calls.read_text().splitlines()]
    assert executable.read_bytes() == b"signed executable fixture"
    assert ticket.read_bytes() == b"validated ticket fixture"
    if cleanup_fails:
        assert result.returncode == 7
        assert "ARCHIVE_READY" not in result.stdout
        assert observed == [["stapler", "staple", str(app)], ["xattr", "-cr", str(app)]]
    else:
        assert result.returncode == 0, result.stderr
        assert "ARCHIVE_READY" in result.stdout
        assert observed == [["stapler", "staple", str(app)], ["xattr", "-cr", str(app)],
                            ["stapler", "validate", str(app)]]


@pytest.mark.parametrize("upload", ["crash", "empty", "malformed", "missing_id"])
@pytest.mark.parametrize("verdict", ["Accepted", "Invalid"])
def test_notary_recovers_uploaded_submission_without_resubmitting(tmp_path, upload, verdict):
    tool, log = fake_notary(tmp_path, upload=upload, verdict=verdict, info_failures=2)
    response = tmp_path / "reply.json"
    result = run(tmp_path, f'XCRUN_TOOL="{tool}"\nNOTARY_PROFILE=fixture\n'
                 f'notarize_and_wait fixture.zip "{response}"\n')
    assert result.returncode == 0, result.stderr
    assert json.loads(response.read_text()) == {"id": "recovered", "status": verdict}
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert [call[1] for call in calls] == ["submit", "history", "info", "info", "info"]
    assert all(call[2] == "recovered" for call in calls if call[1] == "info")
    assert "SECRET_TRANSPORT_CANARY" not in result.stdout + result.stderr


@pytest.mark.parametrize("history", ["old", "wrong_name", "ambiguous", "future", "empty"])
def test_notary_refuses_unrelated_or_ambiguous_history(tmp_path, history):
    tool, log = fake_notary(tmp_path, upload="empty", history=history)
    response = tmp_path / "reply.json"
    result = run(tmp_path, f'XCRUN_TOOL="{tool}"\nNOTARY_PROFILE=fixture\n'
                 f'notarize_and_wait fixture.zip "{response}"\n')
    assert result.returncode != 0
    assert not response.exists()
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert [call[1] for call in calls] == ["submit", "history", "history", "history"]


def test_notary_stops_after_three_consecutive_info_failures(tmp_path):
    tool, log = fake_notary(tmp_path, upload="empty", info_failures=10)
    result = run(tmp_path, f'XCRUN_TOOL="{tool}"\nNOTARY_PROFILE=fixture\n'
                 f'notarize_and_wait fixture.zip "{tmp_path / "reply.json"}"\n')
    assert result.returncode != 0
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert [call[1] for call in calls] == ["submit", "history", "info", "info", "info"]
    assert "recovered" in result.stderr
    assert "SECRET_TRANSPORT_CANARY" not in result.stdout + result.stderr


def fake_notary(tmp_path, *, upload="crash", history="match", verdict="Accepted", info_failures=0):
    tool = tmp_path / "xcrun"
    log = tmp_path / "calls.jsonl"
    tool.write_text(
        f"#!{sys.executable}\n"
        "import datetime,json,os,signal,sys\n"
        f"log={str(log)!r}\n"
        "with open(log,'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
        "action=sys.argv[2]\n"
        f"upload={upload!r}; history={history!r}\n"
        "if action=='submit':\n"
        " print('SECRET_TRANSPORT_CANARY',file=sys.stderr)\n"
        " if upload=='crash': os.kill(os.getpid(),signal.SIGBUS)\n"
        " if upload=='malformed': print('{')\n"
        " if upload=='missing_id': print('{}')\n"
        " sys.exit(0)\n"
        "if action=='history':\n"
        " now=datetime.datetime.now(datetime.timezone.utc)\n"
        " if history=='old': now-=datetime.timedelta(days=1)\n"
        " if history=='future': now+=datetime.timedelta(days=1)\n"
        " row={'id':'recovered','name':'fixture.zip','createdDate':now.isoformat(),'status':'In Progress'}\n"
        " if history=='wrong_name': row['name']='other.zip'\n"
        " rows=[row]\n"
        " if history=='empty': rows=[]\n"
        " if history=='ambiguous': rows.append(dict(row,id='other'))\n"
        " print(json.dumps({'history':rows})); sys.exit(0)\n"
        "calls=[json.loads(line) for line in open(log)]\n"
        "attempt=sum(call[1]=='info' for call in calls)\n"
        f"if attempt <= {info_failures}: os.kill(os.getpid(),signal.SIGBUS)\n"
        f"print(json.dumps({{'id':'recovered','status':{verdict!r}}}))\n"
    )
    tool.chmod(0o755)
    return tool, log
