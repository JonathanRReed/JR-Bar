"""Fix sign-in (`provider_sign_in`): the best automatic thing, and an honest sentence.

Every tool here is a throwaway `/bin/sh` script in a temporary folder that records
what it was asked; the terminal opener, the clock, the "re-read" step and the
Keychain-fingerprint reader are all handed in. Nothing touches the real Keychain,
`~/.claude`, a real provider CLI or the network, and nothing sleeps: a hung call is a
script that blocks until the runner's own timeout ends it.
"""

from __future__ import annotations

import inspect
import os
import shlex
import subprocess
import tempfile
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

import jrbar.core_runtime as core_runtime
from jrbar import core_server, provider_sign_in
from jrbar.core_server import CommandError
from jrbar.provider_cli import PROVIDER_CLIS, run_bounded
from jrbar.provider_reconnect import RepairOutcome, ResignInResult
from jrbar.provider_sign_in import ProviderSignIn

LIVE_STATE = "/live/jrbar/state"
SECRET_OUTPUT = "SECRET-OUTPUT-MARKER sk-ant-oat01-abcdefghijklmnopqrstuvwxyz"

#: A stand-in for `claude`: `auth status` prints what FAKE_AUTH_STATUS says; `-p`
#: records how it was started and "renews" by changing the fake fingerprint file.
FAKE_CLAUDE = r"""
case "$1" in
  auth)
    echo "auth $2" >> "$FAKE_LOG/calls"
    printf '%s\n' "$FAKE_AUTH_STATUS"
    ;;
  -p)
    echo "run" >> "$FAKE_LOG/calls"
    {
      printf 'argv:'; for a in "$@"; do printf ' [%s]' "$a"; done; echo
      echo "pwd:$PWD"
      echo "state:$JRBAR_STATE_DIR"
      echo "serve_token:${JRBAR_SERVE_ACCESS_TOKEN-unset}"
      if read -r _line; then echo "stdin:open"; else echo "stdin:closed"; fi
    } >> "$FAKE_LOG/renew.log"
    if [ -n "$FAKE_HANG" ]; then
      echo $$ > "$FAKE_LOG/pid"
      exec sleep 600
    fi
    if [ -n "$FAKE_RENEW_TO" ]; then echo "$FAKE_RENEW_TO" > "$FAKE_FINGERPRINT_FILE"; fi
    echo "$FAKE_OUTPUT"
    exit "${FAKE_EXIT:-0}"
    ;;
esac
"""


def write_cli(directory: Path, name: str, body: str) -> str:
    path = directory / name
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(0o755)
    return str(path)


class Clock:
    def __init__(self, now: float = 1_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class Terminal:
    """The injected terminal opener: records what it was asked to type."""

    def __init__(self, *, app: str = "Ghostty", error: Exception | None = None) -> None:
        self.calls: list[tuple[str, str, object]] = []
        self.app = app
        self.error = error

    def __call__(self, directory, command, *, terminal=None):
        self.calls.append((directory, command, terminal))
        if self.error is not None:
            raise self.error
        return {"raised": "new_tab", "app": self.app, "bundle_id": "com.mitchellh.ghostty"}


class Reread:
    """The injected step 1 (`reconnect_provider`): answers what it is told to."""

    def __init__(self, result: ResignInResult | None = None) -> None:
        self.result = result
        self.calls: list[tuple[str, str, str | None]] = []

    def __call__(self, provider, instance="default", *, reason_code=None):
        self.calls.append((provider, instance, reason_code))
        if self.result is not None:
            return self.result
        return ResignInResult(provider, "re-read")


class RecordingRun:
    """`run_bounded` behind a recorder: every call's argv, folder, mode and environment."""

    def __init__(self) -> None:
        self.calls: list[SimpleNamespace] = []
        self.popen_kwargs: list[dict] = []

    def _popen(self, argv, **kwargs):
        assert isinstance(argv, list)
        self.popen_kwargs.append(kwargs)
        return subprocess.Popen(argv, **kwargs)

    def __call__(self, argv, *, cwd, env, timeout_seconds, output_cap=4096):
        self.calls.append(
            SimpleNamespace(
                argv=list(argv),
                cwd=str(cwd),
                env=dict(env),
                timeout=timeout_seconds,
                cap=output_cap,
                mode=os.stat(cwd).st_mode & 0o777,
            )
        )
        return run_bounded(
            argv, cwd=cwd, env=env, timeout_seconds=timeout_seconds, output_cap=output_cap, popen=self._popen
        )


def bench(tmp_path: Path, *, result: ResignInResult | None = None, auth: str = '{"loggedIn": true}', **extra):
    """A sign-in fixer wired to fake tools, and everything it records."""
    tmp_path.mkdir(parents=True, exist_ok=True)
    (tmp_path / "home").mkdir(exist_ok=True)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    log_dir = tmp_path / "log"
    log_dir.mkdir(exist_ok=True)
    scratch_root = tmp_path / "scratch"
    scratch_root.mkdir(exist_ok=True)
    fingerprint_file = tmp_path / "fingerprint"
    fingerprint_file.write_text("before", encoding="utf-8")
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(tmp_path / "home"),
        "FAKE_LOG": str(log_dir),
        "FAKE_AUTH_STATUS": auth,
        "FAKE_FINGERPRINT_FILE": str(fingerprint_file),
        "FAKE_RENEW_TO": "after",
        "FAKE_OUTPUT": SECRET_OUTPUT,
        "JRBAR_STATE_DIR": LIVE_STATE,
        "JRBAR_SERVE_ACCESS_TOKEN": "bearer-for-the-serve-endpoint",
    }
    environment.update(extra.pop("environment", {}))
    tools = {name: write_cli(bin_dir, name, FAKE_CLAUDE if name == "claude" else "exit 0\n") for name in ("claude",)}
    for name in ("grok", "codex", "opencode", "gemini", "devin"):
        tools[name] = write_cli(bin_dir, name, "exit 0\n")
    missing = set(extra.pop("missing", ()))
    clock = Clock()
    terminal = Terminal()
    reread = Reread(result)
    run = RecordingRun()
    log: list[str] = []
    scratch_dirs: list[str] = []

    def make_scratch() -> str:
        path = tempfile.mkdtemp(prefix="jrbar-signin-", dir=scratch_root)
        scratch_dirs.append(path)
        return path

    def fingerprint():
        text = fingerprint_file.read_text(encoding="utf-8").strip()
        return ("keychain", text) if text else None

    fixer = ProviderSignIn(
        locate=lambda binary: None if binary in missing else tools[binary],
        run=run,
        open_terminal=terminal,
        clock=clock,
        fingerprint=fingerprint,
        reconnect=reread,
        make_scratch=make_scratch,
        environ=lambda: environment,
        home=lambda: tmp_path / "home",
        log=log.append,
        **extra,
    )
    return SimpleNamespace(
        fixer=fixer,
        tools=tools,
        clock=clock,
        terminal=terminal,
        reread=reread,
        run=run,
        log=log,
        log_dir=log_dir,
        scratch_dirs=scratch_dirs,
        scratch_root=scratch_root,
        environment=environment,
        fingerprint_file=fingerprint_file,
        home=tmp_path / "home",
    )


def expired_claude() -> ResignInResult:
    """Step 1's answer for the owner's case: the Keychain copy has expired."""
    return ResignInResult(
        "claude", "Claude Code owns this sign-in.", outcome=RepairOutcome.NEEDS_PROVIDER_REFRESH
    )


@pytest.fixture(autouse=True)
def _home(tmp_path: Path) -> None:
    (tmp_path / "home").mkdir(exist_ok=True)


# --- step 2: Claude Code renews its own Keychain item --------------------------


def test_an_expired_claude_copy_is_renewed_by_one_quiet_call_in_a_private_folder(tmp_path: Path) -> None:
    b = bench(tmp_path, result=expired_claude())

    result = b.fixer.sign_in("claude", reason_code="authentication_required", signed_out=True)

    assert result.outcome == "renewed"
    assert "renewed its sign-in" in result.message
    assert result.command is None
    status_call, renewal = b.run.calls
    exe = b.tools["claude"]
    assert status_call.argv == [exe, "auth", "status"]
    # The proven argv, exactly: a list, the resolved absolute path, never a shell.
    assert renewal.argv == [exe, "-p", "reply with the single word ok", "--max-turns", "1"]
    assert os.path.isabs(renewal.argv[0])
    assert all(not kwargs.get("shell") for kwargs in b.run.popen_kwargs)
    assert renewal.timeout == 90.0 and renewal.cap == 4096
    # A fresh, private folder, gone afterwards.
    assert renewal.mode == 0o700
    assert Path(renewal.cwd).parent == Path(b.scratch_dirs[0])
    assert not os.path.exists(b.scratch_dirs[0])
    assert os.listdir(b.scratch_root) == []
    # The terminal was never needed.
    assert b.terminal.calls == []
    # The re-read ran once for the click and once to copy the renewed token.
    assert [call[0] for call in b.reread.calls] == ["claude", "claude"]


def test_the_renewal_never_carries_the_live_daemons_state_or_settings(tmp_path: Path) -> None:
    b = bench(tmp_path, result=expired_claude())

    b.fixer.sign_in("claude")

    renewal = b.run.calls[1]
    state = renewal.env["JRBAR_STATE_DIR"]
    assert state != LIVE_STATE
    assert Path(state).parent == Path(b.scratch_dirs[0])
    assert Path(renewal.cwd).parent == Path(b.scratch_dirs[0])
    # No other daemon setting leaks in either; the owner's own environment still does.
    assert not [key for key in renewal.env if key.startswith("JRBAR_") and key != "JRBAR_STATE_DIR"]
    assert renewal.env["HOME"] == str(b.home)
    # What the child saw, from its own mouth: the scratch state folder, no token.
    log = (b.log_dir / "renew.log").read_text(encoding="utf-8")
    assert f"state:{state}" in log
    assert "serve_token:unset" in log
    assert LIVE_STATE not in log
    assert "stdin:closed" in log
    assert "[reply with the single word ok] [--max-turns] [1]" in log


def test_what_the_call_prints_is_never_returned_or_logged(tmp_path: Path) -> None:
    b = bench(tmp_path, result=expired_claude())

    result = b.fixer.sign_in("claude")

    everything = repr(result) + "\n".join(b.log)
    assert "SECRET-OUTPUT-MARKER" not in everything
    assert "sk-ant-oat01" not in everything
    assert b.log == ["core: sign-in claude renewed"]


def test_a_hung_call_is_killed_at_the_timeout_and_reported_as_failed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(provider_sign_in, "RENEWAL_TIMEOUT_SECONDS", 2.0)
    b = bench(tmp_path, result=expired_claude(), environment={"FAKE_HANG": "1"})

    result = b.fixer.sign_in("claude")

    assert result.outcome == "failed"
    assert "did not answer within 90 seconds" in result.message
    pid = int((b.log_dir / "pid").read_text(encoding="utf-8").strip())
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)
    # A hang is not a sign-in problem: no terminal is opened over it.
    assert b.terminal.calls == []
    assert os.listdir(b.scratch_root) == []


def test_a_second_renewal_inside_a_minute_is_refused_with_a_clear_message(tmp_path: Path) -> None:
    b = bench(tmp_path, result=expired_claude())

    first = b.fixer.sign_in("claude")
    b.fingerprint_file.write_text("before", encoding="utf-8")  # the item looks stale again
    b.clock.now += 30.0
    second = b.fixer.sign_in("claude")
    b.clock.now += 31.0
    third = b.fixer.sign_in("claude")

    assert first.outcome == "renewed"
    assert second.outcome == "unavailable"
    assert "less than a minute ago" in second.message
    assert third.outcome == "renewed"
    runs = [call for call in b.run.calls if call.argv[1] == "-p"]
    assert len(runs) == 2, "the refused click made no call"


def test_a_claude_that_says_it_is_not_logged_in_goes_to_the_terminal(tmp_path: Path) -> None:
    b = bench(tmp_path, result=expired_claude(), auth='{"loggedIn": false}')

    result = b.fixer.sign_in("claude")

    assert [call.argv[1] for call in b.run.calls] == ["auth"], "no renewal call was made"
    assert result.outcome == "opened_terminal"
    assert result.command == "claude auth login"
    directory, typed, _ = b.terminal.calls[0]
    assert directory == str(b.home)
    assert typed == f"{shlex.quote(b.tools['claude'])} auth login"
    assert os.listdir(b.scratch_root) == []


def test_a_call_that_renews_nothing_falls_through_to_the_terminal(tmp_path: Path) -> None:
    b = bench(tmp_path, result=expired_claude(), environment={"FAKE_RENEW_TO": "", "FAKE_EXIT": "1"})

    result = b.fixer.sign_in("claude")

    assert result.outcome == "opened_terminal"
    assert result.command == "claude auth login"
    assert len(b.terminal.calls) == 1
    assert os.listdir(b.scratch_root) == []


def test_unreadable_status_output_is_not_a_login(tmp_path: Path) -> None:
    b = bench(tmp_path, result=expired_claude(), auth="not json at all")

    assert b.fixer.sign_in("claude").outcome == "opened_terminal"


def test_a_healthy_or_repaired_claude_copy_needs_no_call_at_all(tmp_path: Path) -> None:
    healthy = bench(
        tmp_path / "a",
        result=ResignInResult("claude", "current", outcome=RepairOutcome.ALREADY_HEALTHY),
    )
    repaired = bench(
        tmp_path / "b",
        result=ResignInResult("claude", "copied", changed=True, outcome=RepairOutcome.REPAIRED),
    )

    one = healthy.fixer.sign_in("claude")
    two = repaired.fixer.sign_in("claude")

    assert (one.outcome, one.message) == ("already_ok", "current")
    assert (two.outcome, two.message) == ("renewed", "copied")
    for run in (healthy.run, repaired.run):
        assert run.calls == []


def test_a_declined_keychain_prompt_is_said_not_worked_around(tmp_path: Path) -> None:
    b = bench(
        tmp_path,
        result=ResignInResult("claude", "Keychain access was declined.", outcome=RepairOutcome.BLOCKED),
    )

    result = b.fixer.sign_in("claude")

    assert (result.outcome, result.message) == ("unavailable", "Keychain access was declined.")
    assert b.run.calls == [] and b.terminal.calls == []


def test_without_the_claude_cli_the_answer_says_so(tmp_path: Path) -> None:
    b = bench(tmp_path, result=expired_claude(), missing=("claude",))

    result = b.fixer.sign_in("claude")

    assert result.outcome == "unavailable"
    assert "not installed" in result.message and "`claude`" in result.message
    assert b.terminal.calls == [] and b.run.calls == []


# --- step 3: the owner's terminal ------------------------------------------------------


def test_grok_opens_the_terminal_on_exactly_the_tables_command(tmp_path: Path) -> None:
    needs = ResignInResult("grok", "run grok login", outcome=RepairOutcome.NEEDS_SIGN_IN)
    b = bench(tmp_path, result=needs)

    result = b.fixer.sign_in("grok", terminal="com.mitchellh.ghostty", reason_code="authentication_required")

    assert result.outcome == "opened_terminal"
    assert result.command == "grok login"
    assert result.message == "Opened Ghostty on `grok login`: finish signing in there, JR-Bar notices on its own."
    assert b.terminal.calls == [(str(b.home), f"{shlex.quote(b.tools['grok'])} login", "com.mitchellh.ghostty")]
    assert b.reread.calls == [("grok", "default", "authentication_required")]
    assert b.run.calls == [], "no provider tool is run here: only opened for the person"


@pytest.mark.parametrize(
    ("provider", "tail", "display"),
    [
        ("claude", ["auth", "login"], "claude auth login"),
        ("grok", ["login"], "grok login"),
        ("codex", ["login"], "codex login"),
        ("opencode", ["providers", "login"], "opencode providers login"),
    ],
)
def test_the_terminal_is_only_ever_typed_the_tables_argv(
    tmp_path: Path, provider: str, tail: list[str], display: str
) -> None:
    b = bench(
        tmp_path,
        result=ResignInResult(provider, "re-read", outcome=RepairOutcome.NEEDS_SIGN_IN),
        auth='{"loggedIn": false}',
    )
    # A hostile-looking request changes nothing about what is typed.
    result = b.fixer.sign_in(provider, reason_code="; rm -rf ~ #", signed_out=True)

    assert result.outcome == "opened_terminal"
    (directory, typed, _), = b.terminal.calls
    assert directory == str(b.home)
    assert typed == " ".join(shlex.quote(part) for part in (b.tools[provider], *tail))
    assert result.command == display
    assert list(PROVIDER_CLIS[provider].sign_in or ()) == tail


def test_the_signin_function_takes_no_command_from_the_client() -> None:
    parameters = set(inspect.signature(ProviderSignIn.sign_in).parameters)
    assert parameters == {"self", "provider", "instance", "terminal", "reason_code", "signed_out"}
    source = inspect.getsource(provider_sign_in)
    for forbidden in ("shell=True", "os.system", "os.popen"):
        assert forbidden not in source


def test_a_cli_that_cannot_report_on_its_own_sign_in_is_opened_only_for_a_card_that_does_not_rule_it_out(
    tmp_path: Path,
) -> None:
    stale = bench(tmp_path / "stale", result=ResignInResult("codex", "Codex activity from 3 min ago was found."))
    signed_out = bench(tmp_path / "out", result=ResignInResult("codex", "x"))
    unknown = bench(tmp_path / "unknown", result=ResignInResult("opencode", "x"))

    no = stale.fixer.sign_in("codex", signed_out=False)
    yes = signed_out.fixer.sign_in("codex", signed_out=True)
    maybe = unknown.fixer.sign_in("opencode", signed_out=None)

    assert (no.outcome, no.message) == ("unavailable", "Codex activity from 3 min ago was found.")
    assert stale.terminal.calls == []
    assert yes.outcome == "opened_terminal" and yes.command == "codex login"
    assert maybe.outcome == "opened_terminal" and maybe.command == "opencode providers login"
    # OpenCode's sign-in is not one the daemon watches: the sentence does not claim it is.
    assert maybe.message.endswith("finish signing in there, then refresh this card.")


def test_a_provider_with_no_cli_login_gets_the_re_reads_advice(tmp_path: Path) -> None:
    gemini = bench(tmp_path / "g", result=ResignInResult("gemini", "Run `gemini` once in a terminal."))
    devin = bench(
        tmp_path / "d",
        result=ResignInResult("devin", "Sign in at app.devin.ai.", sign_in_url="https://app.devin.ai"),
    )
    cursor = bench(tmp_path / "c", result=ResignInResult("cursor", "Sign in in the Cursor app."))

    for fixer, provider in ((gemini, "gemini"), (devin, "devin"), (cursor, "cursor")):
        reply = fixer.fixer.sign_in(provider, signed_out=True)
        assert reply.outcome == "unavailable"
        assert fixer.terminal.calls == []
    assert devin.fixer.sign_in("devin").sign_in_url == "https://app.devin.ai"
    assert gemini.fixer.sign_in("gemini").message == "Run `gemini` once in a terminal."


def test_a_re_read_that_changed_something_is_a_renewal_for_any_provider(tmp_path: Path) -> None:
    b = bench(tmp_path, result=ResignInResult("devin", "Imported the browser session.", changed=True))

    result = b.fixer.sign_in("devin", signed_out=True)

    assert (result.outcome, result.message) == ("renewed", "Imported the browser session.")
    assert b.terminal.calls == []


def test_a_terminal_that_cannot_open_is_a_failure_that_names_the_command(tmp_path: Path) -> None:
    b = bench(tmp_path, result=ResignInResult("grok", "x", outcome=RepairOutcome.NEEDS_SIGN_IN))
    b.terminal.error = CommandError("unsupported", "that terminal could not be opened")

    result = b.fixer.sign_in("grok")

    assert result.outcome == "failed"
    assert result.command == "grok login"
    assert "`grok login`" in result.message and "yourself" in result.message


def test_an_unreviewed_terminal_is_the_clients_mistake_and_is_refused(tmp_path: Path) -> None:
    b = bench(tmp_path, result=ResignInResult("grok", "x", outcome=RepairOutcome.NEEDS_SIGN_IN))
    b.terminal.error = CommandError("invalid_args", "terminal must be Ghostty, Terminal or iTerm")

    with pytest.raises(CommandError) as error:
        b.fixer.sign_in("grok", terminal="com.example.not-a-terminal")
    assert error.value.code == "invalid_args"


def test_a_cli_that_is_not_installed_has_nothing_to_open(tmp_path: Path) -> None:
    b = bench(tmp_path, result=ResignInResult("grok", "x", outcome=RepairOutcome.NEEDS_SIGN_IN), missing=("grok",))

    result = b.fixer.sign_in("grok")

    assert result.outcome == "unavailable"
    assert "not installed" in result.message
    assert b.terminal.calls == []


def test_a_second_account_is_only_re_read_never_signed_in_through_the_cli(tmp_path: Path) -> None:
    b = bench(tmp_path, result=expired_claude())

    result = b.fixer.sign_in("claude", "work", signed_out=True)

    assert result.outcome == "unavailable"
    assert "second account" in result.message
    assert b.run.calls == [] and b.terminal.calls == []
    assert b.reread.calls == [("claude", "work", None)]


def test_a_second_click_while_one_is_running_is_told_so(tmp_path: Path) -> None:
    b = bench(tmp_path, result=ResignInResult("grok", "x", outcome=RepairOutcome.NEEDS_SIGN_IN))
    inside = threading.Event()
    release = threading.Event()

    def slow_terminal(directory, command, *, terminal=None):
        inside.set()
        assert release.wait(30.0)
        return {"raised": "new_tab", "app": "Ghostty", "bundle_id": "com.mitchellh.ghostty"}

    b.fixer._open_terminal = slow_terminal
    first: list = []
    worker = threading.Thread(target=lambda: first.append(b.fixer.sign_in("grok")), daemon=True)
    worker.start()
    assert inside.wait(30.0)

    second = b.fixer.sign_in("grok")
    release.set()
    worker.join(timeout=30.0)

    assert second.outcome == "unavailable" and "already running" in second.message
    assert first and first[0].outcome == "opened_terminal"
    # And the guard is released: a later click runs.
    assert b.fixer.sign_in("grok").outcome == "opened_terminal"


# --- the daemon command ------------------------------------------------------------------


def controller(result: provider_sign_in.SignInResult, *, snapshots=()):
    fixer = SimpleNamespace(calls=[])

    def sign_in(provider, instance, **kwargs):
        fixer.calls.append((provider, instance, kwargs))
        return result

    fixer.sign_in = sign_in
    refresh = []
    hops = []
    feedback = []
    return SimpleNamespace(
        _jrbar_provider_sign_in=fixer,
        provider_usage_state=SimpleNamespace(snapshots=snapshots),
        _request_provider_usage=lambda **kwargs: refresh.append(kwargs),
        _core_on_main=lambda fn: hops.append("main") or fn(),
        _show_provider_usage_feedback=feedback.append,
        refresh=refresh,
        hops=hops,
        feedback=feedback,
        fixer=fixer,
    )


def snapshot(provider: str, state: str, reason: str | None, instance: str = "default"):
    return SimpleNamespace(
        identity=(provider, instance),
        state=SimpleNamespace(value=state),
        reason_code=reason,
    )


def test_the_command_runs_the_fixer_then_arms_the_watch_and_forces_a_refresh() -> None:
    result = provider_sign_in.SignInResult(
        "opened_terminal", "Opened Ghostty on `grok login`: x.", command="grok login"
    )
    c = controller(result, snapshots=(snapshot("grok", "stale", "authentication_required"),))

    reply = core_runtime._cmd_provider_sign_in(c, {"provider": "grok", "terminal": "com.mitchellh.ghostty"})

    assert reply == {
        "provider": "grok",
        "instance": "default",
        "outcome": "opened_terminal",
        "message": "Opened Ghostty on `grok login`: x.",
        "command": "grok login",
        "sign_in_url": None,
    }
    assert c.fixer.calls == [
        (
            "grok",
            "default",
            {
                "terminal": "com.mitchellh.ghostty",
                "reason_code": "authentication_required",
                "signed_out": True,
            },
        )
    ]
    assert c.refresh == [{"force": True, "providers": ("grok",)}]
    assert c._jrbar_reconnect_watch[:2] == ("grok", "default")
    assert c.feedback == ["Opened Ghostty on `grok login`: x."]
    assert c.hops == ["main"], "only the controller-bound tail hops to the main thread"


def test_the_command_scopes_a_second_account_and_reads_the_cards_own_word() -> None:
    result = provider_sign_in.SignInResult("unavailable", "x")
    c = controller(
        result,
        snapshots=(snapshot("codex", "stale", "local_reading_stale", instance="work"),),
    )

    core_runtime._cmd_provider_sign_in(c, {"provider": "codex", "instance": "work"})

    assert c.refresh == [{"force": True, "providers": (("codex", "work"),)}]
    assert c.fixer.calls[0][2]["signed_out"] is False
    # No card for the provider at all: unknown, not "signed out".
    c = controller(result)
    core_runtime._cmd_provider_sign_in(c, {"provider": "codex"})
    assert c.fixer.calls[0][2]["signed_out"] is None


def test_the_command_refuses_bad_arguments_before_doing_anything() -> None:
    result = provider_sign_in.SignInResult("unavailable", "x")
    for args, code in (
        ({}, "invalid_args"),
        ({"provider": ""}, "invalid_args"),
        ({"provider": 7}, "invalid_args"),
        ({"provider": "grok", "instance": 7}, "invalid_args"),
        ({"provider": "grok", "terminal": 7}, "invalid_args"),
        ({"provider": "nonsense"}, "unknown_provider"),
    ):
        c = controller(result)
        with pytest.raises(CommandError) as error:
            core_runtime._cmd_provider_sign_in(c, args)
        assert error.value.code == code, args
        assert c.fixer.calls == [] and c.refresh == []


def test_the_command_waits_on_the_slow_lane_off_the_main_thread() -> None:
    spec = core_runtime._MAIN_THREAD_COMMANDS["provider_sign_in"]
    assert spec.main_thread is False
    # Its own lane: a held renewal must not make History, a doctor run or a scan wait.
    assert "provider_sign_in" in core_server.ACTION_LANE_COMMANDS
    assert "provider_sign_in" not in core_server.READ_LANE_COMMANDS | core_server.SCAN_LANE_COMMANDS
