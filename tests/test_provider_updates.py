"""Provider updates: the CLI's own updater on a click, and an opt-in "update available".

Every updater here is a throwaway `/bin/sh` script in a temporary folder that records
how it was run and changes its own `--version`; the thread starter, the clock, the npm
registry and the terminal opener are handed in. Nothing touches a real provider tool or
the network, and nothing sleeps: the worker the coordinator would start on a thread is
captured and run by the test, so each phase can be looked at before and after it.
"""

from __future__ import annotations

import inspect
import io
import json
import shlex
from pathlib import Path
from types import SimpleNamespace

import pytest

import jrbar.core_runtime as core_runtime
from jrbar import core_server, provider_updates
from jrbar.core_server import CommandError
from jrbar.provider_cli import GEMINI_UPDATE_ADVICE, PROVIDER_CLIS, run_bounded
from jrbar.provider_updates import ProviderUpdates, fetch_latest_version, is_newer

SECRET = "sk-ant-oat01-ZZZZZZZZZZZZZZZZZZZZZZZZ"

#: A stand-in updater: `--version` prints the version file; `update` / `upgrade` records
#: how it was run, optionally "installs" FAKE_NEW_VERSION, and exits as told.
FAKE_CLI = r"""
VERSION_FILE="$FAKE_DIR/$(basename "$0").version"
case "$1" in
  --version)
    echo "fake-cli $(cat "$VERSION_FILE")"
    ;;
  update|upgrade)
    {
      printf 'argv:'; for a in "$@"; do printf ' [%s]' "$a"; done; echo
      echo "pwd:$PWD"
      echo "serve_token:${JRBAR_SERVE_ACCESS_TOKEN-unset}"
      if read -r _line; then echo "stdin:open"; else echo "stdin:closed"; fi
    } >> "$FAKE_DIR/$(basename "$0").run"
    if [ -n "$FAKE_HANG" ]; then exec sleep 600; fi
    if [ -n "$FAKE_NEW_VERSION" ]; then echo "$FAKE_NEW_VERSION" > "$VERSION_FILE"; fi
    if [ -n "$FAKE_OUTPUT" ]; then printf '%b\n' "$FAKE_OUTPUT"; fi
    exit "${FAKE_EXIT:-0}"
    ;;
esac
"""


class Terminal:
    def __init__(self, *, error: Exception | None = None) -> None:
        self.calls: list[tuple[str, str]] = []
        self.error = error

    def __call__(self, directory, command, *, terminal=None):
        self.calls.append((directory, command))
        if self.error is not None:
            raise self.error
        return {"raised": "new_tab", "app": "Ghostty", "bundle_id": "com.mitchellh.ghostty"}


class Wall:
    def __init__(self, now: float = 1_800_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class Registry:
    """The injected npm fetcher: counts every request and answers from a table."""

    def __init__(self, **answers: str | None) -> None:
        self.answers = answers
        self.requests: list[str] = []

    def __call__(self, package: str) -> str | None:
        self.requests.append(package)
        return self.answers.get(package)


def bench(
    tmp_path: Path,
    *,
    versions: dict[str, str] | None = None,
    checks: bool = False,
    environment: dict[str, str] | None = None,
    registry: Registry | None = None,
    missing: tuple[str, ...] = (),
):
    tmp_path.mkdir(parents=True, exist_ok=True)
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    directory = tmp_path / "bin"
    directory.mkdir(exist_ok=True)
    tools: dict[str, str] = {}
    for name, cli in PROVIDER_CLIS.items():
        path = directory / cli.binary
        path.write_text("#!/bin/sh\n" + FAKE_CLI, encoding="utf-8")
        path.chmod(0o755)
        (directory / f"{cli.binary}.version").write_text((versions or {}).get(name, "2.1.285"), encoding="utf-8")
        tools[name] = str(path)
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(home),
        "FAKE_DIR": str(directory),
        "JRBAR_SERVE_ACCESS_TOKEN": "bearer-for-the-serve-endpoint",
        **(environment or {}),
    }
    state = SimpleNamespace(checks=checks)
    started: list[tuple] = []
    published: list[str] = []
    wall = Wall()
    monotonic = Wall(10_000.0)
    terminal = Terminal()
    fetch = registry or Registry()
    log: list[str] = []
    updates = ProviderUpdates(
        checks_enabled=lambda: state.checks,
        locate=lambda binary: None if binary in missing else str(directory / binary),
        open_terminal=terminal,
        fetch_latest=fetch,
        clock=wall,
        monotonic=monotonic,
        start=lambda fn, name: started.append((fn, name)),
        on_change=lambda: published.append("state"),
        environ=lambda: env,
        home=lambda: home,
        log=log.append,
    )
    return SimpleNamespace(
        updates=updates,
        tools=tools,
        directory=directory,
        home=home,
        state=state,
        started=started,
        published=published,
        wall=wall,
        monotonic=monotonic,
        terminal=terminal,
        registry=fetch,
        log=log,
        env=env,
    )


def run_started(b, index: int = 0) -> None:
    """Run, on the test's own thread, the work the coordinator handed to `start`."""
    b.started[index][0]()


def version_of(b, provider: str) -> str:
    return (b.directory / f"{PROVIDER_CLIS[provider].binary}.version").read_text(encoding="utf-8").strip()


def run_log(b, provider: str) -> str:
    return (b.directory / f"{PROVIDER_CLIS[provider].binary}.run").read_text(encoding="utf-8")


# --- the click starts a worker and returns at once ----------------------------------------


def test_capabilities_use_local_installations_without_checks_or_workers(tmp_path: Path) -> None:
    b = bench(tmp_path, missing=("grok",))
    b.updates.refresh_capabilities()
    document = b.updates.document()
    assert document["claude"]["updatable"] is True
    assert document["codex"]["updatable"] is False
    assert document["gemini"]["update_advice"] == GEMINI_UPDATE_ADVICE
    assert document["grok"]["updatable"] is False
    assert "not installed" in document["grok"]["update_advice"]
    assert b.started == [] and b.registry.requests == []
    assert not list(b.directory.glob("*.run"))
    b.updates._locate = lambda _binary: pytest.fail("serialization must not discover installations")
    assert b.updates.document() == document


def test_capability_refresh_reassesses_installations_and_preserves_results(tmp_path: Path) -> None:
    b = bench(tmp_path)
    b.updates.update("claude")
    run_started(b)
    before = b.updates.document()["claude"]
    b.updates._locate = lambda _binary: None
    b.updates.refresh_capabilities()
    missing = b.updates.document()["claude"]
    assert missing["updatable"] is False
    assert missing["phase"] == before["phase"] and missing["message"] == before["message"]
    b.updates._locate = lambda binary: str(b.directory / binary)
    b.updates.refresh_capabilities()
    assert b.updates.document()["claude"]["updatable"] is True
    assert b.updates.document()["claude"]["update_advice"] is None
    def unavailable(_binary):
        raise OSError("synthetic unreadable installation")
    b.updates._locate = unavailable
    b.updates.refresh_capabilities()
    assert b.updates.document()["claude"]["updatable"] is None


def test_hooks_doctor_refreshes_cached_capability_on_its_existing_worker(tmp_path, monkeypatch):
    from jrbar import hook_doctor
    b = bench(tmp_path)
    report = {"providers": [{"provider": "claude", "version": "2.1.285"}]}
    monkeypatch.setattr(hook_doctor, "hook_doctor_report", lambda: report)
    daemon = SimpleNamespace(_jrbar_provider_updates=b.updates)
    assert core_runtime._cmd_hooks_doctor(daemon, {}) is report
    assert b.updates.document()["claude"]["updatable"] is True
    assert b.started == [] and b.registry.requests == []


def test_a_click_returns_at_once_and_the_updater_runs_on_a_worker(tmp_path: Path) -> None:
    b = bench(tmp_path, environment={"FAKE_NEW_VERSION": "2.1.290"})

    reply = b.updates.update("claude")

    assert reply == {"provider": "claude", "started": True, "reason": None, "message": "Updating Claude Code…"}
    assert len(b.started) == 1 and b.started[0][1] == "JRBarProviderUpdate-claude"
    # Nothing has run yet: only the phase is known.
    assert not (b.directory / "claude.run").exists()
    assert b.updates.document()["claude"] == {
        "phase": "running",
        "from_version": None,
        "to_version": None,
        "latest_version": None,
        "up_to_date_version": None,
        "message": "Updating Claude Code…",
        "finished_at": None,
        "updatable": True,
        "update_advice": None,
    }
    assert len(b.published) == 1

    run_started(b)

    assert b.updates.document()["claude"] == {
        "phase": "updated",
        "from_version": "2.1.285",
        "to_version": "2.1.290",
        "latest_version": None,
        "up_to_date_version": None,
        "message": "Updated 2.1.285 to 2.1.290",
        "finished_at": b.wall.now,
        "updatable": True,
        "update_advice": None,
    }
    assert len(b.published) == 5, "start, version check, updater, verification, finish"
    assert b.log == ["core: provider update claude updated"]


def test_the_updater_is_the_tables_argv_run_with_a_closed_stdin_in_the_owners_environment(tmp_path: Path) -> None:
    b = bench(tmp_path)
    # Devin is not here: its updater asks before it installs, so it gets a terminal (below).
    for provider, tail in (("claude", "update"), ("grok", "update"), ("opencode", "upgrade")):
        b.started.clear()
        b.updates.update(provider)
        run_started(b)
        log = run_log(b, provider)
        assert f"argv: [{tail}]" in log, provider
        assert f"pwd:{b.home.resolve()}" in log or f"pwd:{b.home}" in log
        assert "stdin:closed" in log
        # The daemon's own bearer token is not the updater's business.
        assert "serve_token:unset" in log
        assert list(PROVIDER_CLIS[provider].update or ()) == [tail]


def test_the_click_names_no_command_of_its_own(tmp_path: Path) -> None:
    assert list(inspect.signature(ProviderUpdates.update).parameters) == ["self", "provider"]
    source = inspect.getsource(provider_updates)
    for forbidden in ("shell=True", "os.system", "os.popen"):
        assert forbidden not in source
    # A provider id that is not in the table cannot run anything.
    b = bench(tmp_path)
    for odd in ("claude; rm -rf ~", "../claude", "CLAUDE", "cursor", "pi"):
        reply = b.updates.update(odd)
        assert reply["started"] is False and reply["reason"] == "no_updater", odd
    assert b.started == []


def test_unchanged_failed_and_unreadable_results_say_so(tmp_path: Path) -> None:
    same = bench(tmp_path / "same")
    same.updates.update("grok")
    run_started(same)
    assert same.updates.document()["grok"]["phase"] == "unchanged"
    assert same.updates.document()["grok"]["message"] == "Already up to date (2.1.285)"

    failed = bench(
        tmp_path / "failed",
        environment={"FAKE_EXIT": "1", "FAKE_OUTPUT": f"downloading\\nAuthorization: Bearer {SECRET}\\ntoken={SECRET}\\ndisk full"},
    )
    failed.updates.update("claude")
    run_started(failed)
    record = failed.updates.document()["claude"]
    assert record["phase"] == "failed"
    assert record["message"].startswith("Claude Code's updater failed (exit 1): ")
    assert record["message"].endswith("disk full")
    assert "ZZZZZZ" not in record["message"] and "ZZZZZZ" not in repr(failed.updates.document())
    assert (record["from_version"], record["to_version"]) == ("2.1.285", None)
    assert len(record["message"]) <= 240

    unreadable = bench(tmp_path / "unreadable", environment={"FAKE_NEW_VERSION": "not a version"})
    unreadable.updates.update("grok")
    run_started(unreadable)
    record = unreadable.updates.document()["grok"]
    assert record["phase"] == "unchanged"
    assert "could not be read" in record["message"]


def test_a_hung_updater_is_killed_at_the_timeout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(provider_updates, "UPDATE_TIMEOUT_SECONDS", 1.0)
    b = bench(tmp_path, environment={"FAKE_HANG": "1"})
    b.updates.update("opencode")

    run_started(b)

    record = b.updates.document()["opencode"]
    assert record["phase"] == "failed"
    assert "did not finish within 10 minutes" in record["message"]
    assert record["from_version"] == "2.1.285"


def test_an_updater_that_wants_a_terminal_gets_one(tmp_path: Path) -> None:
    b = bench(tmp_path, environment={"FAKE_EXIT": "1", "FAKE_OUTPUT": "Install 2.2.0? [y/N]"})
    b.updates.update("claude")

    run_started(b)

    record = b.updates.document()["claude"]
    assert record["phase"] == "needs_terminal"
    assert record["message"] == (
        "Claude Code's updater needs a terminal: opened Ghostty on `claude update`. Finish the update there."
    )
    assert b.terminal.calls == [(str(b.home), f"{shlex.quote(b.tools['claude'])} update")]

    refused = bench(
        tmp_path / "refused",
        environment={"FAKE_EXIT": "1", "FAKE_OUTPUT": "stdin is not a terminal"},
    )
    refused.terminal.error = CommandError("unsupported", "that terminal could not be opened")
    refused.updates.update("claude")
    run_started(refused)
    assert refused.updates.document()["claude"]["phase"] == "failed"
    assert "Run `claude update` yourself" in refused.updates.document()["claude"]["message"]


def test_devins_updater_is_never_run_blind_because_it_would_read_as_up_to_date(tmp_path: Path) -> None:
    # `devin update` checks and only optionally installs, and has no non-interactive flag: run with no
    # input it can exit 0 having installed nothing, which would say "Already up to date" when it is not.
    b = bench(tmp_path, environment={"FAKE_OUTPUT": "A new version is available. Install it? "})
    assert PROVIDER_CLIS["devin"].update_needs_terminal is True
    assert not any(cli.update_needs_terminal for name, cli in PROVIDER_CLIS.items() if name != "devin")

    b.updates.update("devin")
    run_started(b)

    record = b.updates.document()["devin"]
    assert record["phase"] == "needs_terminal"
    assert record["message"] == (
        "Devin's updater needs a terminal: opened Ghostty on `devin update`. Finish the update there."
    )
    assert b.terminal.calls == [(str(b.home), f"{shlex.quote(b.tools['devin'])} update")]
    assert not (b.directory / "devin.run").exists(), "the updater was not run with no one to answer it"


def test_a_failure_that_merely_says_terminal_is_not_a_prompt(tmp_path: Path) -> None:
    # Broad phrases ("in a terminal", "interactive terminal") are in ordinary failure text; they must not
    # re-run the updater in a visible terminal.
    for text in (
        "Could not reach the server. Try again in a terminal later.",
        "An interactive terminal session is not required for this step.",
        "This command requires a terminal emulator to be installed? no",
    ):
        b = bench(tmp_path / str(abs(hash(text))), environment={"FAKE_EXIT": "1", "FAKE_OUTPUT": text})
        b.updates.update("grok")

        run_started(b)

        assert b.updates.document()["grok"]["phase"] == "failed", text
        assert b.terminal.calls == [], text


def test_a_plain_failure_does_not_open_a_terminal(tmp_path: Path) -> None:
    b = bench(tmp_path, environment={"FAKE_EXIT": "2", "FAKE_OUTPUT": "network unreachable"})
    b.updates.update("claude")

    run_started(b)

    assert b.updates.document()["claude"]["phase"] == "failed"
    assert b.terminal.calls == []


# --- the limits -------------------------------------------------------------------------------------


def test_one_update_per_provider_and_at_most_two_at_once(tmp_path: Path) -> None:
    b = bench(tmp_path)

    assert b.updates.update("claude")["started"] is True
    again = b.updates.update("claude")
    assert (again["started"], again["reason"]) == (False, "busy")
    assert "already running" in again["message"]
    assert b.updates.update("opencode")["started"] is True
    third = b.updates.update("grok")
    assert (third["started"], third["reason"]) == (False, "busy")
    assert "Two updates are already running" in third["message"]
    assert "grok" not in b.updates.document(), "a refused click leaves no record"
    assert len(b.started) == 2

    run_started(b, 0)

    assert b.updates.update("grok")["started"] is True, "a finished update frees its place"


def test_gemini_and_an_absent_cli_get_a_plain_refusal_and_no_thread(tmp_path: Path) -> None:
    b = bench(tmp_path, missing=("grok",))

    gemini = b.updates.update("gemini")
    absent = b.updates.update("grok")

    assert gemini == {"provider": "gemini", "started": False, "reason": "no_updater", "message": GEMINI_UPDATE_ADVICE}
    assert "brew upgrade gemini-cli" in GEMINI_UPDATE_ADVICE
    assert (absent["started"], absent["reason"]) == (False, "not_installed")
    assert "`grok`" in absent["message"]
    assert b.started == [] and len(b.published) == 2
    assert b.updates.document()["gemini"]["updatable"] is False
    assert b.updates.document()["grok"]["updatable"] is False


@pytest.mark.parametrize("provider,package", [("codex", "@openai/codex"), ("gemini", "@google/gemini-cli")])
def test_global_package_update_uses_the_manager_and_confirms_the_same_cli(tmp_path, provider, package):
    prefix = tmp_path / "prefix with spaces"
    target = prefix / "lib" / "node_modules" / package / "bin" / "cli.js"
    target.parent.mkdir(parents=True)
    target.write_text("#!/bin/sh\nexit 0\n")
    target.chmod(0o755)
    manager = prefix / "bin" / "npm"
    manager.parent.mkdir()
    manager.write_text("#!/bin/sh\nexit 0\n")
    manager.chmod(0o755)
    entry = prefix / "bin" / provider
    entry.symlink_to(target)
    calls = []
    versions = iter(("1.0.0", "1.1.0"))

    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        output = f"fake-cli {next(versions)}" if argv[-1] == "--version" else "installed"
        return provider_updates.RunResult(0, output)

    started = []
    updates = ProviderUpdates(locate=lambda _binary: str(entry), run=run,
                              start=lambda fn, _name: started.append(fn), home=lambda: tmp_path,
                              environ=lambda: {"PATH": "/usr/bin:/bin"})
    updates.refresh_capabilities()
    assert updates.document()[provider]["updatable"] is True
    assert calls == [] and started == []
    assert updates.update(provider)["started"] is True
    assert calls == []
    started[0]()
    assert [argv for argv, _ in calls] == [
        [str(entry), "--version"],
        [str(manager), "install", "-g", "--prefix", str(prefix), f"{package}@latest"],
        [str(entry), "--version"],
    ]
    assert calls[1][1]["env"]["PATH"].split(":")[0] == str(prefix / "bin")
    assert updates.document()[provider]["phase"] == "updated"


def test_update_refuses_a_manager_changed_after_the_click_before_any_run(tmp_path):
    prefix = tmp_path / "prefix"
    target = prefix / "lib" / "node_modules" / "@openai" / "codex" / "bin" / "codex.js"
    target.parent.mkdir(parents=True)
    target.write_text("#!/bin/sh\nexit 0\n")
    target.chmod(0o755)
    manager = prefix / "bin" / "npm"
    manager.parent.mkdir()
    manager.write_text("#!/bin/sh\nexit 0\n")
    manager.chmod(0o755)
    entry = prefix / "bin" / "codex"
    entry.symlink_to(target)
    started = []
    updates = ProviderUpdates(locate=lambda _binary: str(entry),
                              run=lambda *_args, **_kwargs: pytest.fail("changed manager was run"),
                              start=lambda fn, _name: started.append(fn), home=lambda: tmp_path)
    assert updates.update("codex")["started"] is True
    manager.chmod(0o777)
    started[0]()
    assert updates.document()["codex"]["phase"] == "failed"
    assert "installation changed" in updates.document()["codex"]["message"]


def test_unknown_codex_install_has_manual_advice_and_never_starts(tmp_path):
    b = bench(tmp_path)
    reply = b.updates.update("codex")
    assert reply["started"] is False and reply["reason"] == "no_updater"
    assert "manager you used to install it" in reply["message"]
    assert b.started == []


def manager_bench(tmp_path, monkeypatch, *, kind="npm", separate=False, outcome="complete"):
    tools = {}
    prefixes = []
    for provider, package in (("codex", "@openai/codex"), ("gemini", "@google/gemini-cli")):
        prefix = tmp_path / (provider if separate else "shared")
        prefixes.append(str(prefix))
        formula = "codex" if provider == "codex" else "gemini-cli"
        root = prefix / "lib" / "node_modules" / package if kind == "npm" else prefix / "Cellar" / formula / "1.0.0"
        target = root / "bin" / provider
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("#!/bin/sh\nexit 0\n")
        target.chmod(0o755)
        entry = prefix / "bin" / provider
        entry.parent.mkdir(exist_ok=True)
        entry.symlink_to(target)
        manager = prefix / "bin" / kind
        manager.write_text("#!/bin/sh\nexit 0\n")
        manager.chmod(0o755)
        tools[provider] = str(entry)
    original = provider_updates.resolve_update_command
    monkeypatch.setattr(provider_updates, "resolve_update_command", lambda cli, executable:
                        original(cli, executable, group_writable_roots=tuple(prefixes)))
    started = []
    attempts = 0

    def start(fn, _name):
        nonlocal attempts
        attempts += 1
        if outcome == "startup_failure" and attempts == 1:
            raise RuntimeError("synthetic thread failure")
        started.append(fn)

    def run(argv, **_kwargs):
        if argv[-1] == "--version":
            return provider_updates.RunResult(0, "fake-cli 1.0.0")
        if outcome == "failure":
            raise RuntimeError("synthetic worker failure")
        return provider_updates.RunResult(0, "finished")

    def log(_line):
        if outcome == "log_failure":
            raise RuntimeError("synthetic logging failure")

    updates = ProviderUpdates(locate=lambda binary: tools.get(binary), run=run, start=start,
                              log=log, home=lambda: tmp_path)
    return updates, started


@pytest.mark.parametrize("kind", ["npm", "brew"])
def test_different_providers_cannot_overlap_the_same_installation_manager(tmp_path, monkeypatch, kind):
    updates, started = manager_bench(tmp_path, monkeypatch, kind=kind)
    assert updates.update("codex")["started"] is True
    reply = updates.update("gemini")
    assert (reply["started"], reply["reason"]) == (False, "busy")
    assert "installation" in reply["message"]
    assert len(started) == 1 and "gemini" not in updates.document()
    started[0]()
    assert updates.update("gemini")["started"] is True


@pytest.mark.parametrize("kind", ["npm", "brew"])
def test_independent_manager_installations_keep_two_update_capacity(tmp_path, monkeypatch, kind):
    updates, started = manager_bench(tmp_path, monkeypatch, kind=kind, separate=True)
    assert updates.update("codex")["started"] is True
    assert updates.update("gemini")["started"] is True
    assert len(started) == 2


@pytest.mark.parametrize("outcome", ["failure", "startup_failure", "log_failure"])
def test_manager_ownership_is_released_on_every_failure_path(tmp_path, monkeypatch, outcome):
    updates, started = manager_bench(tmp_path, monkeypatch, outcome=outcome)
    reply = updates.update("codex")
    if outcome == "startup_failure":
        assert reply["started"] is False
        assert started == []
    elif outcome == "log_failure":
        with pytest.raises(RuntimeError, match="logging failure"):
            started[0]()
    else:
        started[0]()
        assert updates.document()["codex"]["phase"] == "failed"
    assert updates.update("gemini")["started"] is True


def test_manager_identity_follows_installation_aliases_instead_of_provider(tmp_path):
    prefix = tmp_path / "owner"
    prefix.mkdir()
    alias = tmp_path / "alias"
    alias.symlink_to(prefix, target_is_directory=True)
    first = provider_updates.ProviderUpdateCommand(str(prefix / "bin" / "npm"),
                 ("install", "-g", "--prefix", str(prefix), "@openai/codex@latest"))
    second = provider_updates.ProviderUpdateCommand(str(alias / "bin" / "npm"),
                 ("install", "-g", "--prefix", str(alias), "@google/gemini-cli@latest"))
    assert ProviderUpdates._manager_key(PROVIDER_CLIS["codex"], first) == ProviderUpdates._manager_key(PROVIDER_CLIS["gemini"], second)


def test_managed_terminal_failure_does_not_launch_an_untracked_installer(tmp_path, monkeypatch):
    updates, started = manager_bench(tmp_path / ('long-installation-prefix-' * 8), monkeypatch)

    def run(argv, **_kwargs):
        if argv[-1] == "--version":
            return provider_updates.RunResult(0, "fake-cli 1.0.0")
        return provider_updates.RunResult(1, "stdin is not a terminal")

    updates._run = run
    updates._open_terminal = lambda *_args: pytest.fail("untracked manager installer launched")
    assert updates.update("codex")["started"] is True
    started[0]()
    record = updates.document()["codex"]
    assert record["phase"] == "needs_terminal"
    assert "original npm installation" in record["message"]
    assert "`" not in record["message"]  # Never offer a truncated shell command.
    assert updates.update("gemini")["started"] is True


def test_short_manual_manager_command_is_preserved(tmp_path):
    updates = bench(tmp_path).updates
    command = provider_updates.ProviderUpdateCommand(
        "/opt/homebrew/bin/npm",
        ("install", "-g", "--prefix", "/opt/homebrew", "@openai/codex@latest"),
    )
    phase, _before, _after, message = updates._needs_terminal(
        PROVIDER_CLIS["codex"], "/opt/homebrew/bin/codex", "1.0.0", command,
    )
    assert phase == "needs_terminal"
    assert "`/opt/homebrew/bin/npm install -g --prefix /opt/homebrew @openai/codex@latest`" in message
    assert len(message) <= provider_updates.MESSAGE_LIMIT


def test_a_thread_that_cannot_start_releases_its_place(tmp_path: Path) -> None:
    b = bench(tmp_path)

    def broken(fn, name):
        raise RuntimeError("no threads")

    b.updates._start = broken

    reply = b.updates.update("claude")

    assert reply["started"] is False
    assert b.updates.document()["claude"]["phase"] == "failed"
    b.updates._start = lambda fn, name: b.started.append((fn, name))
    assert b.updates.update("claude")["started"] is True


def test_a_running_update_never_changes_the_document_as_time_passes(tmp_path: Path) -> None:
    b = bench(tmp_path)
    b.updates.update("claude")

    first = b.updates.document()
    b.wall.now += 3600.0
    b.monotonic.now += 3600.0
    second = b.updates.document()

    assert first == second
    # What the state diff sees: equal, so nothing is broadcast for a spinner.
    assert core_runtime.doc_significant_equal("state", {"provider_updates": first}, {"provider_updates": second})
    assert json.dumps(first)  # plain JSON, ready for the frame


# --- "update available": off until turned on ---------------------------------------------------------------


def test_with_checks_off_no_request_is_made_and_no_thread_starts(tmp_path: Path) -> None:
    registry = Registry(codex="9.9.9")
    b = bench(tmp_path, checks=False, registry=registry)

    assert b.updates.check(forced=True) == {"enabled": False, "started": False}
    assert b.updates.check() == {"enabled": False, "started": False}
    for _ in range(3):
        b.monotonic.now += 7 * 3600.0
        b.updates.tick()

    assert registry.requests == []
    assert b.started == []
    assert b.updates.document() == {}


def test_the_default_coordinator_asks_nothing(tmp_path: Path) -> None:
    started: list = []
    requests: list[str] = []
    updates = ProviderUpdates(
        fetch_latest=lambda package: requests.append(package),
        start=lambda fn, name: started.append(name),
    )

    assert updates.check(forced=True)["started"] is False
    updates.tick()

    assert requests == [] and started == []


def test_with_checks_on_each_installed_cli_with_a_package_is_asked_once(tmp_path: Path) -> None:
    registry = Registry(
        **{
            "@anthropic-ai/claude-code": "2.1.290",
            "@openai/codex": "2.1.285",  # up to date
            "@xai-official/grok": "2.2.0",
            "@google/gemini-cli": "2.1.286",
            "opencode-ai": "2.1.284",  # older than installed
        }
    )
    b = bench(tmp_path, checks=True, registry=registry, missing=("codex",))

    assert b.updates.check(forced=True) == {"enabled": True, "started": True}
    assert len(b.started) == 1
    run_started(b)

    # Devin has no package, codex is not installed here: neither is asked.
    assert sorted(registry.requests) == sorted(
        ["@anthropic-ai/claude-code", "@xai-official/grok", "@google/gemini-cli", "opencode-ai"]
    )
    document = b.updates.document()
    assert document["claude"]["latest_version"] == "2.1.290"
    assert document["grok"]["latest_version"] == "2.2.0"
    assert document["gemini"]["latest_version"] == "2.1.286"
    assert "codex" not in document and "devin" not in document
    assert {document[p]["phase"] for p in ("claude", "grok", "gemini")} == {"idle"}
    assert document["opencode"]["up_to_date_version"] == "2.1.285"
    assert b.published, "a new latest_version is broadcast"


def test_the_look_repeats_every_six_hours_and_a_forced_one_at_most_a_minute_apart(tmp_path: Path) -> None:
    b = bench(tmp_path, checks=True, registry=Registry(), missing=tuple(n for n in PROVIDER_CLIS if n != "claude"))

    b.updates.tick()
    assert len(b.started) == 1, "the first tick after turning it on looks at once"
    run_started(b, 0)
    b.monotonic.now += 3600.0
    b.updates.tick()
    assert len(b.started) == 1, "an hour later is too soon"
    assert b.updates.check(forced=True)["started"] is True, "the Agents refresh may ask again"
    run_started(b, 1)
    b.monotonic.now += 30.0
    assert b.updates.check(forced=True) == {"enabled": True, "started": False}
    b.monotonic.now += 6 * 3600.0
    b.updates.tick()
    assert len(b.started) == 3, "six hours on, the daemon looks again"


def test_turning_checks_off_hides_what_was_found_and_stops_the_next_request(tmp_path: Path) -> None:
    registry = Registry(**{"@anthropic-ai/claude-code": "2.1.290", "@xai-official/grok": "2.2.0"})
    b = bench(tmp_path, checks=True, registry=registry, missing=("codex", "opencode", "gemini", "devin"))
    b.updates.check(forced=True)

    # Turned off while the first request is in flight: no second request follows.
    original = registry.__call__

    def switch_off_after_first(package: str):
        answer = original(package)
        b.state.checks = False
        return answer

    b.updates._fetch_latest = switch_off_after_first
    run_started(b)

    assert registry.requests == ["@anthropic-ai/claude-code"]
    assert b.updates.document() == {}, "off: nothing says an update is available"
    b.state.checks = True
    assert b.updates.document()["claude"]["latest_version"] == "2.1.290", "remembered, shown only while on"


def test_a_registry_that_cannot_be_reached_is_silence_not_an_alarm(tmp_path: Path) -> None:
    b = bench(tmp_path, checks=True, registry=Registry(), missing=("codex", "opencode", "gemini", "devin", "grok"))
    b.updates.check(forced=True)

    run_started(b)

    assert b.updates.document() == {}
    b.monotonic.now += 61.0
    assert b.updates.check(forced=True)["started"] is True, "a finished look frees the next"


def test_an_update_that_catches_up_clears_the_available_version(tmp_path: Path) -> None:
    registry = Registry(**{"@anthropic-ai/claude-code": "2.1.290"})
    b = bench(
        tmp_path,
        checks=True,
        registry=registry,
        environment={"FAKE_NEW_VERSION": "2.1.290"},
        missing=("codex", "opencode", "gemini", "devin", "grok"),
    )
    b.updates.check(forced=True)
    run_started(b, 0)
    assert b.updates.document()["claude"]["latest_version"] == "2.1.290"

    b.updates.update("claude")
    run_started(b, 1)

    record = b.updates.document()["claude"]
    assert (record["phase"], record["latest_version"], record["to_version"]) == ("updated", None, "2.1.290")


def test_check_thread_start_failure_does_not_consume_the_retry_interval(tmp_path: Path) -> None:
    b = bench(tmp_path, checks=True)
    attempts = []

    def start(target, name):
        attempts.append(name)
        if len(attempts) == 1:
            raise RuntimeError("synthetic thread start failure")
        b.started.append((target, name))

    b.updates._start = start
    assert b.updates.check() == {"enabled": True, "started": False}
    assert b.updates.check(forced=True) == {"enabled": True, "started": True}
    assert len(attempts) == 2
    assert len(b.started) == 1
    assert b.registry.requests == [], "starting a worker does not itself ask the registry"


def test_failed_check_start_preserves_the_previous_successful_check_cadence(tmp_path: Path) -> None:
    b = bench(tmp_path, checks=True, missing=tuple(PROVIDER_CLIS))
    b.monotonic.now = 100.0
    assert b.updates.check()["started"] is True
    run_started(b)
    b.monotonic.now = 200.0
    attempts = []

    def start(target, name):
        attempts.append(name)
        if len(attempts) == 1:
            raise RuntimeError("synthetic thread start failure")
        b.started.append((target, name))

    b.updates._start = start
    assert b.updates.check(forced=True)["started"] is False
    assert b.updates._last_check_at == 100.0
    assert b.updates.check()["started"] is False
    assert len(attempts) == 1, "normal polling keeps the previous six-hour cadence"
    assert b.updates.check(forced=True)["started"] is True
    assert len(attempts) == 2
    assert b.registry.requests == []


@pytest.mark.parametrize(
    ("outcome", "latest", "expected"),
    [("updated", "2.0.0", None), ("updated", "3.0.0", "3.0.0"),
     ("failed", "2.0.0", "2.0.0"), ("unchanged", "2.0.0", "2.0.0"),
     ("unchanged", "1.0.0", None), ("failed", "1.0.0", None)],
)
def test_check_completion_respects_an_update_completed_during_its_fetch(
    tmp_path: Path, monkeypatch, outcome: str, latest: str, expected: str | None,
) -> None:
    b = bench(tmp_path, checks=True, missing=tuple(p for p in PROVIDER_CLIS if p != "claude"))
    version = ["1.0.0"]
    calls = []
    monkeypatch.setattr(provider_updates, "installed_version", lambda *args, **kwargs: version[0])

    def run(argv, **kwargs):
        calls.append(argv)
        assert kwargs["cwd"] == b.home
        if outcome == "updated":
            version[0] = "2.0.0"
        return provider_updates.RunResult(returncode=1 if outcome == "failed" else 0, output="")

    def fetch(package):
        assert package == "@anthropic-ai/claude-code"
        assert b.updates.update("claude")["started"] is True
        run_started(b, 1)
        assert b.updates.document()["claude"]["phase"] == outcome
        return latest

    b.updates._run = run
    b.updates._fetch_latest = fetch
    assert b.updates.check()["started"] is True
    run_started(b, 0)
    record = b.updates.document()["claude"]
    assert record["phase"] == outcome
    assert record["latest_version"] == expected
    current = "2.0.0" if outcome == "updated" and latest == "2.0.0" else None
    if outcome == "unchanged" and latest == "1.0.0":
        current = "1.0.0"
    assert record["up_to_date_version"] == current
    assert len(calls) == 1, "only the injected updater ran"


def test_dotted_versions_compare_by_number_not_by_text() -> None:
    assert is_newer("2.1.290", "2.1.285")
    assert is_newer("2.10.0", "2.9.9")
    assert is_newer("1.0.46", "1.0.44")
    assert not is_newer("2.1.285", "2.1.285")
    assert not is_newer("2.1.9", "2.1.285")
    assert not is_newer("0.159.3", "0.159.3")
    assert not is_newer(None, "1.0.0") and not is_newer("1.0.0", None)
    assert is_newer("3000.4.0", "3000.3.27")


# --- the registry request itself --------------------------------------------------------------------------------


class _Response:
    def __init__(self, body: bytes, status: int = 200) -> None:
        self._stream = io.BytesIO(body)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False

    def read(self, count: int = -1) -> bytes:
        return self._stream.read(count)


class _Opener:
    def __init__(self, response: _Response | Exception) -> None:
        self.response = response
        self.requests: list[tuple] = []

    def open(self, request, timeout=None):
        self.requests.append((request, timeout))
        if isinstance(self.response, Exception):
            raise self.response
        return self.response


def with_opener(monkeypatch: pytest.MonkeyPatch, response) -> tuple[_Opener, list]:
    opener = _Opener(response)
    handlers: list = []

    def build(*given):
        handlers.extend(given)
        return opener

    monkeypatch.setattr(provider_updates, "build_opener", build)
    return opener, handlers


def test_the_registry_request_is_one_plain_get_with_no_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    body = json.dumps({"name": "@openai/codex", "version": "0.159.3", "dependencies": {}}).encode()
    opener, handlers = with_opener(monkeypatch, _Response(body))

    assert fetch_latest_version("@openai/codex") == "0.159.3"

    (request, timeout), = opener.requests
    assert request.full_url == "https://registry.npmjs.org/@openai/codex/latest"
    assert request.get_method() == "GET" and request.data is None
    assert timeout == 5.0
    headers = {name.lower(): value for name, value in request.header_items()}
    assert headers == {"accept": "application/json", "user-agent": "JR-Bar/update-check"}
    # No cookie jar and no redirects: a redirect is refused, not followed.
    assert [type(handler).__name__ for handler in handlers] == ["_NoRedirects", "HTTPSHandler"]
    assert handlers[0].redirect_request(None, None, 302, "", {}, "https://elsewhere.example") is None


@pytest.mark.parametrize(
    "response",
    [
        _Response(b"not json"),
        _Response(b'{"name": "someone-else", "version": "9.9.9"}'),
        _Response(b'{"name": "@openai/codex", "version": "next"}'),
        _Response(b'{"name": "@openai/codex"}'),
        _Response(b"[]"),
        _Response(b'{"name": "@openai/codex", "version": "1.0.0"}', status=500),
        _Response(b"x" * (256 * 1024 + 1)),
        OSError("offline"),
        TimeoutError("slow"),
    ],
)
def test_a_bad_registry_answer_is_none(monkeypatch: pytest.MonkeyPatch, response) -> None:
    with_opener(monkeypatch, response)

    assert fetch_latest_version("@openai/codex") is None


# --- the daemon commands ---------------------------------------------------------------------------------------------


def controller():
    updates = SimpleNamespace(calls=[])
    updates.update = lambda provider: updates.calls.append(("update", provider)) or {"provider": provider, "started": True}
    updates.check = lambda **kwargs: updates.calls.append(("check", kwargs)) or {"enabled": False, "started": False}
    return SimpleNamespace(_jrbar_provider_updates=updates, updates=updates)


def test_the_update_command_takes_only_a_provider_id() -> None:
    c = controller()

    reply = core_runtime._cmd_provider_update(c, {"provider": "grok", "argv": ["rm", "-rf", "~"], "command": "x"})

    assert reply == {"provider": "grok", "started": True}
    assert c.updates.calls == [("update", "grok")]
    for args, code in (
        ({}, "invalid_args"),
        ({"provider": ""}, "invalid_args"),
        ({"provider": 3}, "invalid_args"),
        ({"provider": "nonsense"}, "unknown_provider"),
    ):
        with pytest.raises(CommandError) as error:
            core_runtime._cmd_provider_update(c, args)
        assert error.value.code == code
    assert c.updates.calls == [("update", "grok")]


def test_the_check_command_is_a_forced_look_that_the_setting_still_gates() -> None:
    c = controller()

    assert core_runtime._cmd_provider_update_check(c, {}) == {"enabled": False, "started": False}
    assert c.updates.calls == [("check", {"forced": True})]


def test_the_commands_run_off_the_main_thread_and_off_the_slow_lane() -> None:
    for name in ("provider_update", "provider_update_check"):
        assert core_runtime._MAIN_THREAD_COMMANDS[name].main_thread is False
        # They return at once, so they need no slow lane of their own.
        assert name not in core_server.SLOW_LANE_COMMANDS


def test_the_daemon_builds_the_coordinator_from_its_settings_on_first_use() -> None:
    c = SimpleNamespace(
        settings=SimpleNamespace(provider_update_checks_enabled=False),
        _core_publish_state_soon=lambda: None,
    )

    updates = core_runtime._provider_updates_of(c)

    assert core_runtime._provider_updates_of(c) is updates
    assert updates.check(forced=True) == {"enabled": False, "started": False}
    c.settings = SimpleNamespace(provider_update_checks_enabled="yes")
    assert updates.check(forced=True)["enabled"] is False, "only a real true turns it on"
    c.settings = SimpleNamespace(provider_update_checks_enabled=True)
    assert updates.check(forced=True)["enabled"] is True


def test_the_refresh_tick_asks_the_coordinator_and_the_state_carries_its_document() -> None:
    from jrbar.core_projection import build_state_document

    source = inspect.getsource(core_runtime.build_headless_controller_class)
    assert "_provider_updates_of(self).tick()" in source
    assert "provider_updates=provider_updates" in source

    document = build_state_document(
        now=1_800_000_000.0,
        generation=1,
        snapshot=None,
        ask_statuses=(),
        unseen_completion_ids=(),
        provider_updates={"grok": {"phase": "updated", "message": "Updated 1.0.44 to 1.0.46"}},
    )
    assert document["provider_updates"] == {"grok": {"phase": "updated", "message": "Updated 1.0.44 to 1.0.46"}}
    absent = build_state_document(
        now=1_800_000_000.0, generation=1, snapshot=None, ask_statuses=(), unseen_completion_ids=()
    )
    assert "provider_updates" not in absent


def test_the_real_runner_is_what_runs_an_updater_by_default() -> None:
    assert inspect.signature(ProviderUpdates).parameters["run"].default is run_bounded


def test_running_stages_publish_versions_without_extra_commands(tmp_path: Path) -> None:
    b = bench(tmp_path)
    snapshots = []
    calls = []

    def publish():
        snapshots.append(b.updates.document()["claude"])

    def run(argv, **_kwargs):
        calls.append(list(argv))
        record = b.updates.document()["claude"]
        assert record["phase"] == "running"
        assert record["finished_at"] is None
        if len(calls) == 1:
            assert record["message"] == "Checking installed version…"
            assert record["from_version"] is None
            return provider_updates.RunResult(0, "fake-cli 1.0.0")
        assert record["from_version"] == "1.0.0"
        if len(calls) == 2:
            assert record["message"] == "Running updater…"
            return provider_updates.RunResult(0, "synthetic output 50%")
        assert record["message"] == "Verifying installed version…"
        return provider_updates.RunResult(0, "fake-cli 1.1.0")

    b.updates._on_change = publish
    b.updates._run = run
    b.updates.update("claude")
    run_started(b)

    assert calls == [[b.tools["claude"], "--version"],
                     [b.tools["claude"], "update"],
                     [b.tools["claude"], "--version"]]
    assert [record["message"] for record in snapshots] == [
        "Updating Claude Code…", "Checking installed version…", "Running updater…",
        "Verifying installed version…", "Updated 1.0.0 to 1.1.0",
    ]
    assert [record["from_version"] for record in snapshots] == [None, None, "1.0.0", "1.0.0", "1.0.0"]
    assert [record["phase"] for record in snapshots] == ["running"] * 4 + ["updated"]
    terminal = b.updates.document()["claude"]
    b.updates._stage("claude", "Checking installed version…")
    assert b.updates.document()["claude"] == terminal
    assert len(snapshots) == 5


@pytest.mark.parametrize("failure_at", ["updater", "verification"])
def test_running_failure_retains_version_and_releases_manager(tmp_path, monkeypatch, failure_at):
    updates, started = manager_bench(tmp_path, monkeypatch)
    calls = []

    def run(argv, **_kwargs):
        calls.append(list(argv))
        if len(calls) == 1:
            return provider_updates.RunResult(0, "fake-cli 1.0.0")
        if failure_at == "updater" or len(calls) == 3:
            raise RuntimeError("synthetic stage failure")
        return provider_updates.RunResult(0, "finished")

    updates._run = run
    updates.update("codex")
    refused = updates.update("gemini")
    assert (refused["started"], refused["reason"]) == (False, "busy")
    started[0]()
    record = updates.document()["codex"]
    assert record["phase"] == "failed"
    assert record["from_version"] == "1.0.0"
    assert record["to_version"] is None
    assert len(calls) == (2 if failure_at == "updater" else 3)
    assert updates._running == set()
    assert updates._running_managers == {}
    assert updates.update("gemini")["started"] is True


def test_stage_listener_failure_does_not_interrupt_or_repeat_updater(tmp_path: Path) -> None:
    b = bench(tmp_path)
    calls = []
    notifications = []

    def publish():
        notifications.append(b.updates.document()["claude"]["message"])
        raise RuntimeError("synthetic listener failure")

    def run(argv, **_kwargs):
        calls.append(list(argv))
        return provider_updates.RunResult(0, "fake-cli 1.0.0")

    b.updates._run = run
    b.updates._on_change = publish
    assert b.updates.update("claude")["started"] is True
    run_started(b)
    assert len(calls) == 3
    assert len(notifications) == 5
    assert b.updates.document()["claude"]["phase"] == "unchanged"
    assert b.updates._running == set()


@pytest.mark.parametrize("installed, offer, expected", [
    ("2.0.0", "2.0.0", "2.0.0"),
    ("3.0.0", "2.0.0", "3.0.0"),
    ("1.0.0", "2.0.0", None),
    (None, "2.0.0", None),
    ("unknown", "2.0.0", None),
    ("2.0.0", "unknown", None),
    ("2.0.0", None, None),
])
def test_registry_current_is_bound_to_a_readable_installed_version(
    tmp_path: Path, monkeypatch, installed, offer, expected,
) -> None:
    registry = Registry(**{"@anthropic-ai/claude-code": offer})
    b = bench(tmp_path, checks=True, registry=registry,
              missing=tuple(p for p in PROVIDER_CLIS if p != "claude"))
    monkeypatch.setattr(provider_updates, "installed_version", lambda *a, **kw: installed)
    assert b.updates.check()["started"] is True
    run_started(b)
    record = b.updates.document().get("claude", {})
    assert record.get("up_to_date_version") == expected
    if expected:
        assert record["phase"] == "idle"
        assert record["message"] == "" and record["finished_at"] is None
        assert b.published
        b.state.checks = False
        assert b.updates.document().get("claude", {}).get("up_to_date_version") is None


def test_registry_current_clears_for_a_new_offer_and_an_explicit_update(tmp_path: Path) -> None:
    registry = Registry(**{"@anthropic-ai/claude-code": "2.1.285"})
    b = bench(tmp_path, checks=True, registry=registry,
              missing=tuple(p for p in PROVIDER_CLIS if p != "claude"))
    b.updates.check()
    run_started(b)
    assert b.updates.document()["claude"]["up_to_date_version"] == "2.1.285"
    registry.answers["@anthropic-ai/claude-code"] = "2.1.290"
    b.monotonic.now += 7 * 3600
    b.updates.check()
    run_started(b, 1)
    assert b.updates.document()["claude"]["up_to_date_version"] is None
    registry.answers["@anthropic-ai/claude-code"] = "2.1.285"
    b.monotonic.now += 7 * 3600
    b.updates.check()
    run_started(b, 2)
    assert b.updates.document()["claude"]["up_to_date_version"] == "2.1.285"
    b.updates.update("claude")
    assert b.updates.document()["claude"]["up_to_date_version"] is None


def test_registry_check_does_not_mark_a_running_update_current(tmp_path: Path) -> None:
    b = bench(tmp_path, checks=True,
              missing=tuple(p for p in PROVIDER_CLIS if p != "claude"))
    def fetch(package):
        assert b.updates.update("claude")["started"] is True
        return "2.1.285"
    b.updates._fetch_latest = fetch
    b.updates.check()
    run_started(b)
    record = b.updates.document()["claude"]
    assert record["phase"] == "running"
    assert record["up_to_date_version"] is None
    assert not (b.directory / "claude.run").exists()
