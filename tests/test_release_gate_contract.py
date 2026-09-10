import os
import shutil
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from scripts import verify_hardware_release
from scripts.verify_performance_budget import validate_performance_evidence

ROOT = Path(__file__).resolve().parents[1]


def _write_executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def _run_bootstrap(tmp_path: Path) -> subprocess.CompletedProcess[str]:
    venv = tmp_path / "venv"
    env = os.environ.copy()
    env.pop("JRBAR_REQUIRED_HARDWARE", None)
    env.pop("JRBAR_HARDWARE_CONFIRM", None)
    env.update(
        {
            "PATH": f"{tmp_path / 'bin'}:/usr/bin:/bin",
            "JRBAR_DEV_VENV": str(venv),
        }
    )
    env.pop("PYTHON", None)
    return subprocess.run(
        [str(ROOT / "scripts" / "bootstrap-dev.sh")],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def _fake_python(path: Path, version: str, log: Path | None = None) -> None:
    log_line = f"printf '%s\\n' '{version}' >> '{log}'\n" if log else ""
    _write_executable(
        path,
        f"""#!/bin/bash
{log_line}if [ "$1" = "-c" ]; then
    [ "{version}" = "3.12" ]
    exit
fi
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
    mkdir -p "$3/bin"
    cp "$0" "$3/bin/python"
    exit 0
fi
if [ "$1" = "-V" ]; then
    echo "Python {version}.0"
fi
exit 0
""",
    )


def _run_release_ref_gate(
    tmp_path: Path,
    *,
    checkout: str = "tip",
    required_hardware: str | None = None,
    confirm_hardware: bool = False,
    app_identity: str | None = "test-app",
    keychain_identities: str = '  1) AAAA "Developer ID Application: Discovered (TEAM123456)"\n',
    notary_profile_exists: bool = False,
    arguments: tuple[str, ...] = (),
) -> subprocess.CompletedProcess[str]:
    origin = tmp_path / "origin.git"
    repo = tmp_path / "release"
    subprocess.run(["git", "init", "--bare", str(origin)], check=True, capture_output=True)
    subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "release@example.invalid"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Release Test"], cwd=repo, check=True)
    (repo / "scripts").mkdir()
    (repo / "packaging").mkdir()
    shutil.copy2(ROOT / "scripts" / "verify_macos_release.sh", repo / "scripts")
    _write_executable(repo / "packaging" / "build_macos_pkg.sh", "#!/bin/bash\necho PACKAGING_REACHED\nexit 73\n")
    (repo / "performance.json").write_text("{}\n", encoding="utf-8")
    subprocess.run(["git", "add", "."], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "first"], cwd=repo, check=True, capture_output=True)
    first = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()
    (repo / "second").write_text("second\n", encoding="utf-8")
    subprocess.run(["git", "add", "second"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "second"], cwd=repo, check=True, capture_output=True)
    tip = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()
    subprocess.run(["git", "remote", "add", "origin", str(origin)], cwd=repo, check=True)
    subprocess.run(["git", "push", "-u", "origin", "main"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "checkout", "--detach", tip if checkout == "tip" else first], cwd=repo, check=True, capture_output=True)

    fake_bin = tmp_path / "bin"
    _write_executable(fake_bin / "uname", "#!/bin/bash\necho Darwin\n")
    # The gate discovers signing capability instead of demanding it, so the
    # keychain and notarytool are seams the test can answer for.
    _write_executable(
        fake_bin / "security",
        f"#!/bin/bash\ncat <<'LISTING'\n{keychain_identities}LISTING\n",
    )
    _write_executable(
        fake_bin / "xcrun",
        f"#!/bin/bash\nexit {0 if notary_profile_exists else 1}\n",
    )
    env = os.environ.copy()
    for name in (
        "APP_SIGN_IDENTITY",
        "INSTALLER_SIGN_IDENTITY",
        "SPARKLE_KEY_ACCOUNT",
        "JRBAR_REQUIRED_HARDWARE",
        "JRBAR_HARDWARE_CONFIRM",
    ):
        env.pop(name, None)
    env.update(
        {
            "PATH": f"{fake_bin}:/usr/bin:/bin",
            "PYTHON": "/usr/bin/true",
            "SECURITY_TOOL": str(fake_bin / "security"),
            "XCRUN_TOOL": str(fake_bin / "xcrun"),
            "NOTARY_PROFILE": "test-notary",
            "JRBAR_PERFORMANCE_EVIDENCE": str(repo / "performance.json"),
            "JRBAR_RUN_UNINSTALL": "1",
        }
    )
    if app_identity is not None:
        env["APP_SIGN_IDENTITY"] = app_identity
    if required_hardware is not None:
        env["JRBAR_REQUIRED_HARDWARE"] = required_hardware
    if confirm_hardware:
        env["JRBAR_HARDWARE_CONFIRM"] = "1"
    return subprocess.run(
        [str(repo / "scripts" / "verify_macos_release.sh"), *arguments],
        cwd=repo,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_hardware_smoke_restores_backup_after_partial_write_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    target = tmp_path / "LEDS.LED"
    backup = b"#112233 1s solid\n"
    target.write_bytes(backup)
    calls = 0

    def failing_smoke(program: str, *, device_path: Path) -> None:
        nonlocal calls
        calls += 1
        if calls == 1:
            device_path.write_bytes(b"partial")
            raise OSError("smoke write failed")
        device_path.write_text(program, encoding="ascii")

    monkeypatch.setattr(verify_hardware_release, "discover_devices", lambda: [SimpleNamespace(root=tmp_path, target=target)])
    monkeypatch.setattr(verify_hardware_release, "write_led_program", failing_smoke)
    monkeypatch.setattr("sys.argv", ["verify_hardware_release.py", "--confirm-write"])

    assert verify_hardware_release.main() == 1
    assert target.read_bytes() == backup
    assert "smoke write failed" in capsys.readouterr().out


def test_hardware_smoke_removes_partial_file_when_target_was_absent(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    target = tmp_path / "LEDS.LED"

    def failing_smoke(program: str, *, device_path: Path) -> None:
        device_path.write_bytes(b"partial")
        raise OSError("smoke write failed")

    monkeypatch.setattr(verify_hardware_release, "discover_devices", lambda: [SimpleNamespace(root=tmp_path, target=target)])
    monkeypatch.setattr(verify_hardware_release, "write_led_program", failing_smoke)
    monkeypatch.setattr("sys.argv", ["verify_hardware_release.py", "--confirm-write"])

    assert verify_hardware_release.main() == 1
    assert not target.exists()


def test_hardware_smoke_reports_smoke_and_restore_failures(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    target = tmp_path / "LEDS.LED"
    target.write_bytes(b"#112233 1s solid\n")
    calls = 0

    def failing_writes(program: str, *, device_path: Path) -> None:
        nonlocal calls
        calls += 1
        raise OSError("smoke failed" if calls == 1 else "restore failed")

    monkeypatch.setattr(verify_hardware_release, "discover_devices", lambda: [SimpleNamespace(root=tmp_path, target=target)])
    monkeypatch.setattr(verify_hardware_release, "write_led_program", failing_writes)
    monkeypatch.setattr("sys.argv", ["verify_hardware_release.py", "--confirm-write"])

    assert verify_hardware_release.main() == 1
    output = capsys.readouterr().out
    assert "smoke failed" in output
    assert "restore failed" in output


@pytest.mark.parametrize("backup", [b"\xff", b"x" * 513])
def test_hardware_smoke_never_writes_an_invalid_backup(
    backup: bytes, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    target = tmp_path / "LEDS.LED"
    target.write_bytes(backup)
    writes = 0

    def record_write(program: str, *, device_path: Path) -> None:
        nonlocal writes
        writes += 1

    monkeypatch.setattr(verify_hardware_release, "discover_devices", lambda: [SimpleNamespace(root=tmp_path, target=target)])
    monkeypatch.setattr(verify_hardware_release, "write_led_program", record_write)
    monkeypatch.setattr("sys.argv", ["verify_hardware_release.py", "--confirm-write"])

    assert verify_hardware_release.main() == 1
    assert writes == 0
    assert target.read_bytes() == backup


def test_bootstrap_defaults_to_python_312_even_when_313_is_available(
    tmp_path: Path,
) -> None:
    log = tmp_path / "interpreters.log"
    _fake_python(tmp_path / "bin" / "python3.13", "3.13", log)
    _fake_python(tmp_path / "bin" / "python3.12", "3.12", log)

    result = _run_bootstrap(tmp_path)

    assert result.returncode == 0, result.stderr
    assert (tmp_path / "venv" / "bin" / "python").exists()
    assert "3.12" in log.read_text(encoding="utf-8").splitlines()
    assert "3.13" not in log.read_text(encoding="utf-8").splitlines()


def test_bootstrap_rejects_existing_venv_with_wrong_python_without_replacing_it(
    tmp_path: Path,
) -> None:
    existing = tmp_path / "venv" / "bin" / "python"
    _fake_python(existing, "3.13")
    original = existing.read_bytes()
    _fake_python(tmp_path / "bin" / "python3.12", "3.12")

    result = _run_bootstrap(tmp_path)

    assert result.returncode == 2
    assert "existing virtual environment" in result.stderr.lower()
    assert "Python 3.12" in result.stderr
    assert existing.read_bytes() == original


def test_release_gate_accepts_detached_head_only_at_fresh_origin_main(tmp_path: Path) -> None:
    result = _run_release_ref_gate(tmp_path, checkout="tip")

    assert result.returncode == 73
    assert "PACKAGING_REACHED" in result.stdout


def test_release_gate_defaults_to_software_only_without_hardware_authorization(
    tmp_path: Path,
) -> None:
    result = _run_release_ref_gate(tmp_path, checkout="tip")

    assert result.returncode == 73
    assert "JRBAR_HARDWARE_CONFIRM" not in result.stderr


def test_release_gate_requires_authorization_for_an_explicit_hardware_profile(
    tmp_path: Path,
) -> None:
    result = _run_release_ref_gate(
        tmp_path,
        checkout="tip",
        required_hardware="pro",
    )

    assert result.returncode == 2
    assert "JRBAR_HARDWARE_CONFIRM=1" in result.stderr
    assert "PACKAGING_REACHED" not in result.stdout


def test_release_gate_discovers_the_developer_id_identity_from_the_keychain(
    tmp_path: Path,
) -> None:
    result = _run_release_ref_gate(tmp_path, app_identity=None)

    assert result.returncode == 73, result.stderr
    assert "Developer ID Application: Discovered (TEAM123456)" in result.stdout
    assert "PACKAGING_REACHED" in result.stdout


def test_release_gate_refuses_a_candidate_with_no_developer_id_identity(
    tmp_path: Path,
) -> None:
    result = _run_release_ref_gate(
        tmp_path,
        app_identity=None,
        keychain_identities='  1) BBBB "Nautilus Local Dev"\n',
    )

    assert result.returncode == 2
    assert "No 'Developer ID Application' identity" in result.stderr
    assert "PACKAGING_REACHED" not in result.stdout


def test_release_gate_reports_missing_notary_and_installer_instead_of_failing(
    tmp_path: Path,
) -> None:
    # The reason this file could not be touched for so long: it demanded four
    # environment variables that name material this Mac does not have yet.
    result = _run_release_ref_gate(tmp_path, arguments=("--preflight",))

    assert result.returncode == 0, result.stderr
    assert "NOT NOTARIZED" in result.stdout
    assert "UNSIGNED" in result.stdout
    assert "verify the candidate but not publish it" in result.stdout
    # Preflight is a read-only report: it may not build anything.
    assert "PACKAGING_REACHED" not in result.stdout


def test_release_gate_notarizes_as_soon_as_the_keychain_profile_appears(
    tmp_path: Path,
) -> None:
    result = _run_release_ref_gate(
        tmp_path,
        notary_profile_exists=True,
        arguments=("--preflight",),
    )

    assert result.returncode == 0, result.stderr
    assert "notarization: keychain profile test-notary" in result.stdout
    assert "NOT NOTARIZED" not in result.stdout


def test_release_gate_rejects_detached_old_commit(tmp_path: Path) -> None:
    result = _run_release_ref_gate(tmp_path, checkout="old")

    assert result.returncode == 2
    assert "PACKAGING_REACHED" not in result.stdout
    assert "origin/main" in result.stderr


def test_authoritative_release_gate_requires_every_external_evidence_class() -> None:
    text = (ROOT / "scripts" / "verify_macos_release.sh").read_text()
    receipt_runner = (ROOT / "scripts" / "release_evidence.py").read_text()
    for required in (
        "verify.sh --no-bootstrap",
        "verify_performance_budget.py",
        "pkgutil --check-signature",
        "spctl -a -vv -t install",
        "verify_hardware_release.py",
        "verify_uninstalled_candidate.py",
        "capture_installed_release_baseline.py",
        "release_evidence.py",
        "JRBAR_RUN_UNINSTALL",
        "git rev-parse origin/main",
    ):
        assert required in text or required in receipt_runner
    assert "stapling-receipt" in text
    assert '["/usr/bin/xcrun", "stapler", "validate", str(args.pkg)]' in receipt_runner


def test_release_gate_verifies_the_0_8_bundle_layout_it_actually_builds() -> None:
    text = (ROOT / "scripts" / "verify_macos_release.sh").read_text()

    # 0.8 assembles the candidate at build/macos-pkg/app; build/macos-pkg/swift
    # is the Swift input and build/macos-pkg/pyinstaller is PyInstaller's raw
    # output. The gate used to look for JR-Bar.app under pyinstaller/, where
    # nothing has been assembled since the Swift rewrite.
    assert 'APP="$BUILD_DIR/app/JR-Bar.app"' in text
    assert 'SWIFT_APP="$BUILD_DIR/swift/JR-Bar.app"' in text
    assert "pyinstaller/JR-Bar.app" not in text

    # The bundle is three programs. All three are checked for presence and
    # for being sealed by the outer signature.
    assert 'CORE_HELPER="Contents/Helpers/jrbar-core.app"' in text
    assert 'HOOK_HELPER="Contents/Helpers/jrbar-hook"' in text
    assert "codesign --verify --deep --strict" in text
    assert "sealed, team" in text
    assert "Sparkle.framework" in text


def test_release_gate_runs_the_bundled_daemon_doctor_against_the_installed_app() -> None:
    text = (ROOT / "scripts" / "verify_macos_release.sh").read_text()

    # Contents/MacOS/JR-Bar is the Swift menu-bar app and takes no arguments.
    # The 0.8 doctor is a subcommand of the bundled daemon.
    assert '"$core" doctor' in text
    assert '"$core" hooks doctor' in text
    assert "status-bar start" not in text
    assert "integrations\", \"status\"" not in text
    # The installed daemon has to point at the shim inside its own bundle,
    # not at whatever a developer checkout left in the provider config.
    assert 'hook shim: $app/Contents/Helpers/jrbar-hook' in text


def test_release_gate_quiesces_the_running_app_before_it_installs_over_it() -> None:
    text = (ROOT / "scripts" / "verify_macos_release.sh").read_text()

    # A running JR-Bar rewrites its own settings as devices and sessions come
    # and go, so a field that moved between the before and after snapshots
    # could not be told apart from an installer that damaged it. Quitting
    # first is also what a real upgrade does.
    assert "tell application \"JR-Bar\" to quit" in text
    assert "pgrep -x JR-Bar" in text
    assert "refusing to install underneath it" in text
    # And the Mac is left the way it was found.
    assert "relaunching" in text
    assert "start_app" in text


def test_release_gate_installs_into_the_home_applications_folder_by_default() -> None:
    text = (ROOT / "scripts" / "verify_macos_release.sh").read_text()

    # /Applications needs an administrator password, which would stall the
    # gate; the product archive enables currentUserHome for exactly this.
    assert 'INSTALLED_APP="$HOME/Applications/JR-Bar.app"' in text
    assert 'INSTALLER_TARGET="CurrentUserHomeDirectory"' in text
    assert 'INSTALL_SCOPE="${JRBAR_INSTALL_SCOPE:-home}"' in text
    # A home install records its receipt on the home volume, not on /.
    assert '"--volume" "$HOME"' in text
    # The system path is still reachable, and still the only one that can
    # exercise the root-only supported uninstaller.
    assert 'INSTALLED_APP="/Applications/JR-Bar.app"' in text


def test_release_gate_records_every_exact_candidate_receipt_kind() -> None:
    text = (ROOT / "scripts" / "verify_macos_release.sh").read_text()
    for required in (
        "source-gate",
        "performance",
        "pkg-signature",
        "notarization",
        "stapling",
        "pkg-gatekeeper",
        "package-contents",
        "app-signature",
        "app-gatekeeper",
        "bundle-closure",
        "entitlements",
        "hardware-smoke",
        "installed-upgrade",
        "settings-preservation",
        "update-archive",
        "sparkle-nested-signing",
        "app-notarization",
        "app-stapling",
        "signed-appcast",
        "uninstall",
        "clean-install",
        "sbom",
    ):
        assert required in text


def test_release_manifest_consumes_receipts_instead_of_asserting_success() -> None:
    text = (ROOT / "scripts" / "generate_release_manifest.py").read_text()

    assert 'parser.add_argument("--candidate"' in text
    assert 'parser.add_argument("--receipt"' in text
    assert 'developer_id_verified": True' not in text
    assert 'notarization_verified": True' not in text
    assert 'installed_upgrade": True' not in text


def test_installed_app_receipt_binds_the_installed_tree_to_the_exact_candidate() -> None:
    text = (ROOT / "scripts" / "verify_macos_release.sh").read_text()

    # An installed bundle that merely looks right is not evidence. The
    # clean-install receipt hashes the installed tree and compares it with the
    # candidate the receipts describe.
    assert "the installed app is not the exact candidate" in text
    assert "the upgraded app is not the exact candidate" in text
    assert "require_strict_version_upgrade" in text
    assert "sha256_tree" in text


def test_release_publication_is_draft_first_and_rolls_back_on_failure() -> None:
    text = (ROOT / "scripts" / "publish_release.sh").read_text()
    assert "git status --porcelain --untracked-files=all" in text
    assert "--draft" in text
    assert "release upload" in text
    assert "release edit" in text
    assert "--cleanup-tag" in text


def test_release_gate_binds_exact_sparkle_assets_and_app_notary_evidence() -> None:
    text = (ROOT / "scripts" / "verify_macos_release.sh").read_text()

    for required in (
        "contract updater-path",
        "contract appcast-path",
        "contract channel-metadata-path",
        "generate_sparkle_channel.py",
        "app-notary-submission.json",
        "app-notary-log.json",
        "app-notary-submitted-zip.sha256",
        "--update-archive",
        "JRBAR_RELEASE_CHANNEL",
        '--channel "$RELEASE_CHANNEL"',
        "JRBAR_SPARKLE_HISTORY_DIR",
        "--previous-appcast",
        "--previous-archive",
    ):
        assert required in text
    assert "SPARKLE_PRIVATE_KEY" not in text
    assert "NOTARY_PASSWORD" not in text


def test_performance_evidence_requires_measured_budgets_and_trace_review() -> None:
    evidence = {
        "warm_launch_ms": 450,
        "menu_open_p95_ms": 40,
        "pane_switch_p95_ms": 80,
        "longest_main_thread_task_ms": 12,
        "idle_cpu_hidden_percent": 0.5,
        "idle_cpu_static_bar_percent": 1.0,
        "idle_cpu_motion_percent": 2.5,
        "measurement_duration_seconds": 300,
        "instruments_trace_reviewed": True,
        "menu_tracking_io_observed": False,
    }
    assert validate_performance_evidence(evidence) == ()

    evidence["menu_open_p95_ms"] = 75
    assert any(failure.startswith("menu_open_p95_ms") for failure in validate_performance_evidence(evidence))
