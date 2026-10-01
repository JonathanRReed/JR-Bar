"""The shared provider-CLI helpers: the fixed command table, finding a CLI, and
the bounded runner both Fix sign-in and Update lean on.

Every child here is a throwaway `/bin/sh` script in a temporary folder; no real
provider tool, Keychain or network is touched. Nothing sleeps: a hung child is a
script that blocks, and the runner's own timeout is what ends it.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from jrbar import provider_cli
from jrbar.provider_cli import (
    PROVIDER_CLIS,
    installed_version,
    resolve_cli,
    run_bounded,
    scrub,
    search_environment,
    tail_lines,
)

BASE_ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}


def script(directory: Path, name: str, body: str) -> str:
    path = directory / name
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(0o755)
    return str(path)


# --- the table --------------------------------------------------------------


def test_the_command_table_is_fixed_and_says_what_each_cli_can_do() -> None:
    assert PROVIDER_CLIS["claude"].sign_in == ("auth", "login")
    assert PROVIDER_CLIS["grok"].sign_in == ("login",)
    assert PROVIDER_CLIS["codex"].sign_in == ("login",)
    assert PROVIDER_CLIS["opencode"].sign_in == ("providers", "login")
    assert PROVIDER_CLIS["claude"].update == ("update",)
    assert PROVIDER_CLIS["opencode"].update == ("upgrade",)
    # Gemini CLI has no login command and no updater of its own.
    assert PROVIDER_CLIS["gemini"].sign_in is None
    assert PROVIDER_CLIS["gemini"].update is None
    # Devin's usage comes from a browser session, so a CLI login is never opened.
    assert PROVIDER_CLIS["devin"].sign_in is None
    assert PROVIDER_CLIS["devin"].npm_package is None
    assert PROVIDER_CLIS["grok"].sign_in_display() == "grok login"
    assert PROVIDER_CLIS["opencode"].update_display() == "opencode upgrade"
    packages = {name: cli.npm_package for name, cli in PROVIDER_CLIS.items()}
    assert packages == {
        "claude": "@anthropic-ai/claude-code",
        "codex": "@openai/codex",
        "grok": "@xai-official/grok",
        "devin": None,
        "opencode": "opencode-ai",
        "gemini": "@google/gemini-cli",
    }


def test_the_table_cannot_be_changed_at_run_time() -> None:
    with pytest.raises(TypeError):
        PROVIDER_CLIS["claude"] = PROVIDER_CLIS["grok"]  # type: ignore[index]
    with pytest.raises(AttributeError):
        PROVIDER_CLIS["claude"].sign_in = ("rm", "-rf")  # type: ignore[misc]


# --- the environment and the executable ---------------------------------------


def test_a_child_gets_the_owners_environment_plus_login_shell_folders_and_no_daemon_settings(
    tmp_path: Path,
) -> None:
    env = search_environment(
        {
            "PATH": "/usr/bin",
            "HOME": str(tmp_path),
            "JRBAR_STATE_DIR": "/live/state",
            "JRBAR_SERVE_ACCESS_TOKEN": "bearer-for-the-serve-endpoint",
        },
        login_dirs=(tmp_path / "bun" / "bin", "/usr/bin"),
    )

    assert env["HOME"] == str(tmp_path)
    assert env["PATH"].split(os.pathsep) == ["/usr/bin", str(tmp_path / "bun" / "bin")]
    assert not [key for key in env if key.startswith("JRBAR_")]


def test_a_cli_is_found_as_one_absolute_path_or_not_at_all(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    exe = script(bin_dir, "jrbar-fake-agent", "exit 0\n")

    assert resolve_cli("jrbar-fake-agent", environ={"PATH": str(bin_dir)}, login_dirs=()) == exe
    # A folder only the login shell adds is searched too.
    assert resolve_cli("jrbar-fake-agent", environ={"PATH": "/usr/bin"}, login_dirs=(bin_dir,)) == exe
    assert resolve_cli("jrbar-no-such-agent", environ={"PATH": str(bin_dir)}, login_dirs=()) is None
    assert os.path.isabs(exe)


# --- the bounded runner -------------------------------------------------------


def test_a_run_is_an_argv_list_with_stdin_closed_and_reports_its_exit_code(tmp_path: Path) -> None:
    seen: dict[str, object] = {}

    def spy(argv, **kwargs):
        import subprocess

        seen["argv"] = argv
        seen["kwargs"] = kwargs
        return subprocess.Popen(argv, **kwargs)

    exe = script(
        tmp_path,
        "fake-agent",
        'if read -r line; then echo "stdin open"; else echo "stdin closed"; fi\n'
        'echo "args: $*"\nexit 3\n',
    )

    result = run_bounded([exe, "one", "two words"], cwd=tmp_path, env=BASE_ENV, timeout_seconds=30.0, popen=spy)

    assert result.returncode == 3
    assert not result.timed_out
    assert "stdin closed" in result.output
    assert "args: one two words" in result.output
    assert seen["argv"] == [exe, "one", "two words"]
    kwargs = seen["kwargs"]
    assert isinstance(kwargs, dict)
    assert not kwargs.get("shell")
    assert kwargs["start_new_session"] is True
    assert kwargs["cwd"] == str(tmp_path)


def test_output_is_kept_only_as_a_capped_tail(tmp_path: Path) -> None:
    exe = script(
        tmp_path,
        "chatty",
        'i=0\nwhile [ "$i" -lt 3000 ]; do echo "progress line $i padding padding padding"; i=$((i+1)); done\n',
    )

    result = run_bounded([exe], cwd=tmp_path, env=BASE_ENV, timeout_seconds=30.0)

    assert result.returncode == 0
    assert len(result.output.encode("utf-8")) <= 4096
    assert result.output.rstrip().endswith("progress line 2999 padding padding padding")
    lines = tail_lines(result.output)
    assert len(lines) == 20
    assert lines[-1] == "progress line 2999 padding padding padding"


def test_a_hung_child_and_what_it_started_are_killed_at_the_timeout(tmp_path: Path) -> None:
    pids = tmp_path / "pids"
    exe = script(
        tmp_path,
        "hangs",
        f'echo $$ > "{pids}.child"\nsleep 600 &\necho $! > "{pids}.grandchild"\nwait\n',
    )

    result = run_bounded([exe], cwd=tmp_path, env=BASE_ENV, timeout_seconds=1.0)

    assert result.timed_out
    assert result.returncode is None
    for name in ("child", "grandchild"):
        pid = int(Path(f"{pids}.{name}").read_text(encoding="utf-8").strip())
        # The child was reaped by the runner; the grandchild died with the group.
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)


def test_a_command_that_cannot_start_is_a_result_not_an_exception(tmp_path: Path) -> None:
    result = run_bounded([str(tmp_path / "missing")], cwd=tmp_path, env=BASE_ENV, timeout_seconds=5.0)

    assert result.returncode is None
    assert result.error == "spawn_failed"
    assert result.output == ""


# --- words that are safe to say -------------------------------------------------


def test_scrub_removes_escapes_and_anything_that_looks_like_a_credential() -> None:
    dirty = (
        "\x1b[32mDownloading\x1b[0m 2.1.290\n"
        "Authorization: Bearer abcdef0123456789abcdef0123456789\n"
        "access_token=sk-ant-oat01-ZZZZZZZZZZZZZZZZZZZZ\n"
        "id eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payloadpayload\n"
        "checksum 5b8071835b8071835b8071835b8071835b807183\n"
        "installed to /Users/someone/.local/share/claude/versions/2.1.290\n"
    )

    clean = scrub(dirty)

    assert "Downloading 2.1.290" in clean
    assert "\x1b" not in clean
    for secret in ("abcdef0123456789", "ZZZZZZ", "payloadpayload", "5b8071835b8071835b807183"):
        assert secret not in clean
    # An ordinary path and version survive.
    assert "/Users/someone/.local/share/claude/versions/2.1.290" in clean
    assert "authorization failed" in scrub("authorization failed for the update")


# --- versions -------------------------------------------------------------------


def test_a_version_is_read_from_a_node_cli_package_without_running_it(tmp_path: Path) -> None:
    package = tmp_path / "lib" / "node_modules" / "@google" / "gemini-cli"
    (package / "bin").mkdir(parents=True)
    (package / "package.json").write_text(
        '{"name": "@google/gemini-cli", "version": "0.62.0", "bin": {"gemini": "bin/gemini.js"}}',
        encoding="utf-8",
    )
    entry = package / "bin" / "gemini.js"
    entry.write_text("#!/usr/bin/env node\n", encoding="utf-8")
    entry.chmod(0o755)

    def refuse(*_args, **_kwargs):
        raise AssertionError("a node CLI's version is read from package.json")

    assert installed_version(str(entry), cwd=tmp_path, env=BASE_ENV, run=refuse) == "0.62.0"


def test_a_version_is_the_first_dotted_number_of_what_the_cli_prints(tmp_path: Path) -> None:
    exe = script(tmp_path, "grok", 'echo "grok 1.0.44 (5b807183dd79) [stable]"\n')

    assert installed_version(exe, cwd=tmp_path, env=BASE_ENV) == "1.0.44"
    failing = script(tmp_path, "broken", 'echo "boom"\nexit 1\n')
    assert installed_version(failing, cwd=tmp_path, env=BASE_ENV) is None


def test_the_module_never_starts_a_shell() -> None:
    import inspect

    source = inspect.getsource(provider_cli)
    for forbidden in ("shell=True", "os.system", "os.popen"):
        assert forbidden not in source
