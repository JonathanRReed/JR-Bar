"""Notary decisions use synthetic replies and a clock advanced by commands."""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "packaging" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


notary = load("notarize")
command = load("notary_command")


def job(status="Accepted", id="fixture-submission"):
    return {"id": id, "status": status}


def history(*ids):
    return {"history": [{"id": id, "name": "fixture.zip",
                         "createdDate": "2026-01-01T00:00:00Z"} for id in ids]}


class Transport:
    def __init__(self, tmp_path, replies, monkeypatch, deadline=100):
        self.now = 0
        self.calls = []
        self.replies = iter(replies)
        monkeypatch.setattr(notary.time, "time", lambda: 1767225600)
        self.response = tmp_path / "reply.json"
        self.client = notary.Notarizer("fixture-tool", "fixture-profile", deadline,
                                      self.response, clock=lambda: self.now,
                                      sleep=self.advance, runner=self.run)

    def advance(self, seconds):
        self.now += seconds

    def run(self, args, *, stdout, stderr, timeout, check):
        self.calls.append((args, timeout))
        expected, code, reply, duration = next(self.replies)
        assert args[2] == expected
        assert args[-4:] == ["--keychain-profile", "fixture-profile", "--output-format", "json"]
        stderr.write(b"SECRET_TRANSPORT_CANARY\n")
        if duration >= timeout:
            self.advance(timeout)
            raise subprocess.TimeoutExpired(args, timeout)
        self.advance(duration)
        stdout.write(json.dumps(reply).encode() if reply is not None else b"broken json")
        return subprocess.CompletedProcess(args, code)

    def submit(self, no_acceleration=True):
        self.client.notarize(Path("fixture.zip"), no_acceleration)


def test_success_uploads_once_without_acceleration_and_keeps_diagnostics_private(tmp_path, monkeypatch, capsys):
    t = Transport(tmp_path, [("submit", 0, job(), 1), ("info", 0, job(), 1)], monkeypatch)
    t.submit()
    assert len(t.calls) == 2
    args = t.calls[0][0]
    assert "--no-s3-acceleration" in args and "--no-wait" in args and "--no-progress" in args
    assert json.loads(t.response.read_text()) == job()
    assert "SECRET_TRANSPORT_CANARY" not in str(capsys.readouterr())
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in tmp_path.iterdir())


@pytest.mark.parametrize("code", [-10, 138, -11, 139])
def test_crashed_pending_upload_is_replaced_once(tmp_path, monkeypatch, code):
    t = Transport(tmp_path, [("submit", code, job(id="partial"), 1),
                            ("history", 0, history("partial"), 1),
                            ("info", 0, job("In Progress", "partial"), 1),
                            ("submit", 0, job(id="complete"), 1),
                            ("info", 0, job(id="complete"), 1)], monkeypatch)
    t.submit(no_acceleration=False)
    uploads = [args for args, _ in t.calls if args[2] == "submit"]
    assert len(uploads) == 2
    assert "--no-s3-acceleration" not in uploads[0]
    assert "--no-s3-acceleration" in uploads[1]
    assert json.loads(t.response.read_text()) == job(id="complete")
    assert t.client.ids == ["partial", "complete"]


@pytest.mark.parametrize("status", ["Accepted", "Invalid", "Rejected"])
def test_terminal_crashed_upload_is_recovered_without_resubmission(tmp_path, monkeypatch, status):
    t = Transport(tmp_path, [("submit", 138, None, 1),
                            ("history", 0, history("complete"), 1),
                            ("info", 0, job(status, "complete"), 1)], monkeypatch)
    t.submit()
    assert len(t.calls) == 3
    assert json.loads(t.response.read_text()) == job(status, "complete")


@pytest.mark.parametrize("code", [0, 1])
def test_noncrash_lost_response_keeps_unique_history_recovery(tmp_path, monkeypatch, code):
    t = Transport(tmp_path, [("submit", code, None, 1),
                            ("history", 0, history("complete"), 1),
                            ("info", 0, job("In Progress", "complete"), 1),
                            ("info", 0, job(id="complete"), 1)], monkeypatch)
    t.submit()
    assert sum(args[2] == "submit" for args, _ in t.calls) == 1


@pytest.mark.parametrize("rows", [history(), history("one", "two"), None])
def test_noncrash_ambiguous_history_never_resubmits(tmp_path, monkeypatch, rows):
    t = Transport(tmp_path, [("submit", 1, None, 1), *[("history", 0, rows, 1)] * 3], monkeypatch)
    with pytest.raises(notary.NotaryError, match="No unique upload"):
        t.submit()
    assert len(t.calls) == 4
    assert not t.response.exists()


def test_crash_without_recoverable_id_still_gets_only_one_clean_retry(tmp_path, monkeypatch):
    t = Transport(tmp_path, [("submit", 138, None, 1),
                            *[("history", 0, history(), 1)] * 3,
                            ("submit", 138, None, 1),
                            *[("history", 0, history(), 1)] * 3], monkeypatch, deadline=200)
    with pytest.raises(notary.NotaryError, match="crashed twice"):
        t.submit()
    assert sum(args[2] == "submit" for args, _ in t.calls) == 2
    assert not t.response.exists()


@pytest.mark.parametrize("reply", [None, job(id="wrong"), {"id": "fixture-submission", "status": "unknown"}])
def test_three_bad_info_replies_stop_without_resubmission(tmp_path, monkeypatch, reply):
    t = Transport(tmp_path, [("submit", 0, job(), 1), *[("info", 0, reply, 1)] * 3], monkeypatch)
    with pytest.raises(notary.NotaryError, match="three attempts"):
        t.submit()
    assert len(t.calls) == 4


def test_upload_time_counts_toward_deadline_and_pending_id_is_retained(tmp_path, monkeypatch):
    t = Transport(tmp_path, [("submit", 0, job(), 12),
                            ("info", 0, job("In Progress"), 1)], monkeypatch, deadline=20)
    with pytest.raises(notary.NotaryError, match=r"deadline reached.*fixture-submission"):
        t.submit()
    assert t.now == 20
    assert [timeout for _, timeout in t.calls] == [20, 8]
    assert json.loads(t.response.read_text())["status"] == "In Progress"


def test_stuck_command_is_bounded_by_remaining_budget(tmp_path, monkeypatch):
    t = Transport(tmp_path, [("submit", 0, job(), 100)], monkeypatch, deadline=20)
    with pytest.raises(notary.NotaryError, match="deadline reached"):
        t.submit()
    assert t.now == 20
    assert len(t.calls) == 1


def test_shell_shares_one_deadline_between_app_and_package(tmp_path):
    packaging = tmp_path / "packaging"
    packaging.mkdir()
    (packaging / "notarize.py").write_text("import sys\nprint(sys.argv[sys.argv.index('--deadline')+1])\n")
    source = (ROOT / "packaging/build_macos_pkg.sh").read_text()
    functions = source[source.index("notarize_and_wait() {"):source.index('SPARKLE_ARCHIVE="')]
    script = ('set -euo pipefail\n' + functions +
              '\nnotarize_and_wait app.zip app.json\nnotarize_and_wait app.pkg pkg.json\n')
    result = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True, timeout=10,
                            env={"BUILD_PYTHON": sys.executable, "ROOT_DIR": str(tmp_path),
                                 "XCRUN_TOOL": "fixture", "NOTARY_PROFILE": "fixture",
                                 "NOTARY_TIMEOUT_SECONDS": "20", "NOTARY_NO_S3_ACCELERATION": "1"})
    assert result.returncode == 0, result.stderr
    deadlines = result.stdout.splitlines()
    assert len(deadlines) == 2 and deadlines[0] == deadlines[1]
    assert 'NOTARY_NO_S3_ACCELERATION="${NOTARY_NO_S3_ACCELERATION:-1}"' in source
    assert 'NOTARY_TIMEOUT_SECONDS="${NOTARY_TIMEOUT_SECONDS:-1800}"' in source
    assert source.count('notary_command "$XCRUN_TOOL" notarytool log') == 2


def test_command_deadline_bounds_profile_probe_and_log_fetch(monkeypatch):
    monkeypatch.setattr(command.time, "monotonic", lambda: 10)
    calls = []

    def timeout(args, **kwargs):
        calls.append(kwargs["timeout"])
        raise subprocess.TimeoutExpired(args, kwargs["timeout"])

    monkeypatch.setattr(command.subprocess, "run", timeout)
    assert command.run(15, ["fixture"]) == 124
    assert calls == [5]
    assert command.run(10, ["fixture"]) == 124
    assert calls == [5]
