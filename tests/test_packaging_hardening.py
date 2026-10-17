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
    return transport_default + "\n" + source[source.index("require_production_candidate() {"):source.index('SPARKLE_ARCHIVE="')].replace("/bin/sleep 15", ":")


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


@pytest.mark.parametrize("setting", [None, "0", "1"])
def test_notary_upload_flag_and_single_submission(tmp_path, setting):
    tool = tmp_path / "xcrun"
    log = tmp_path / "calls.jsonl"
    tool.write_text(f"#!{sys.executable}\nimport json,sys\nwith open({str(log)!r},'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nprint(json.dumps({{'id':'fixture-submission','status':'Accepted'}}))\n")
    tool.chmod(0o755)
    values = {} if setting is None else {"NOTARY_NO_S3_ACCELERATION": setting}
    result = run(tmp_path, f'XCRUN_TOOL="{tool}"\nNOTARY_PROFILE=fixture\nnotarize_and_wait fixture.zip "{tmp_path / "reply.json"}"\n', **values)
    assert result.returncode == 0, result.stderr
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    submissions = [call for call in calls if call[:2] == ["notarytool", "submit"]]
    assert len(submissions) == 1
    assert ("--no-s3-acceleration" in submissions[0]) is (setting == "1")
    assert calls[1][:3] == ["notarytool", "info", "fixture-submission"]
    assert json.loads((tmp_path / "reply.json").read_text())["status"] == "Accepted"


@pytest.mark.parametrize("exit_code,submission", [(138, {"id": "fixture-created-job"}), (1, None)])
def test_failed_notary_upload_preserves_private_diagnostics_without_retry(tmp_path, exit_code, submission):
    tool = tmp_path / "xcrun"
    log = tmp_path / "calls.jsonl"
    response = tmp_path / "reply.json"
    canary = "SECRET_TRANSPORT_CANARY"
    tool.write_text(
        f"#!{sys.executable}\nimport json,sys\n"
        f"with open({str(log)!r},'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
        f"submission = {submission!r}\n"
        "if submission: print(json.dumps(submission))\n"
        f"print({canary!r}, file=sys.stderr)\nraise SystemExit({exit_code})\n")
    tool.chmod(0o755)
    result = run(tmp_path, f'XCRUN_TOOL="{tool}"\nNOTARY_PROFILE=fixture\n'
                 f'notarize_and_wait fixture.zip "{response}"\necho SUCCESS\n')
    assert result.returncode == exit_code
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert len(calls) == 1 and calls[0][:2] == ["notarytool", "submit"]
    assert not response.exists()
    output = result.stdout + result.stderr
    assert "SUCCESS" not in output
    assert canary not in output
    assert "notarytool history" in output and "before" in output and "retry" in output
    stdout_files = list(tmp_path.glob("reply.json.upload-stdout.*"))
    stderr_files = list(tmp_path.glob("reply.json.upload-stderr.*"))
    assert len(stdout_files) == len(stderr_files) == 1
    for artifact in stdout_files + stderr_files:
        assert artifact.stat().st_mode & 0o777 == 0o600
        assert str(artifact) in output
    assert stderr_files[0].read_text() == canary + "\n"
    assert stdout_files[0].read_text() == (json.dumps(submission) + "\n" if submission else "")


def test_notary_upload_attempts_keep_distinct_private_files(tmp_path):
    tool = tmp_path / "xcrun"
    tool.write_text("#!/bin/bash\nprintf 'attempt output'\nprintf 'attempt error' >&2\nexit 1\n")
    tool.chmod(0o755)
    response = tmp_path / "reply.json"
    for _ in range(2):
        result = run(tmp_path, f'XCRUN_TOOL="{tool}"\nNOTARY_PROFILE=fixture\n'
                     f'notarize_and_wait fixture.zip "{response}"\n')
        assert result.returncode == 1
    for stream, expected in [("stdout", "attempt output"), ("stderr", "attempt error")]:
        artifacts = list(tmp_path.glob(f"reply.json.upload-{stream}.*"))
        assert len(artifacts) == 2
        assert all(path.read_text() == expected for path in artifacts)
        assert all(path.stat().st_mode & 0o777 == 0o600 for path in artifacts)


def test_notary_signal_diagnostic_stays_private(tmp_path):
    tool = tmp_path / "xcrun"
    calls = tmp_path / "calls"
    tool.write_text(
        "#!/bin/bash\n"
        f"printf 'submit\\n' >> {shlex.quote(str(calls))}\n"
        "printf 'SIGNAL_TRANSPORT_CANARY\\n' >&2\n"
        'kill -TERM "$$"\n')
    tool.chmod(0o755)
    response = tmp_path / "reply.json"
    result = run(tmp_path, f'XCRUN_TOOL="{tool}"\nNOTARY_PROFILE=fixture\n'
                 f'notarize_and_wait fixture.zip "{response}"\necho SUCCESS\n')
    assert result.returncode == 143
    assert calls.read_text() == "submit\n"
    assert not response.exists()
    public_output = result.stdout + result.stderr
    assert "SUCCESS" not in public_output
    assert "SIGNAL_TRANSPORT_CANARY" not in public_output
    assert "Terminated" not in public_output
    errors = list(tmp_path.glob("reply.json.upload-stderr.*"))
    assert len(errors) == 1
    assert errors[0].stat().st_mode & 0o777 == 0o600
    assert "SIGNAL_TRANSPORT_CANARY" in errors[0].read_text()
    assert "Terminated" in errors[0].read_text()


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
