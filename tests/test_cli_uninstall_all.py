"""`agent-monitor uninstall all` and `install all` keep going past one bad provider.

One config JR-Bar refuses to touch (a dotfiles symlink) or cannot read (a
commented JSON file) used to end the whole command with a traceback: no
provider printed an outcome and every provider after it was skipped. The
uninstaller now visits every provider, says what happened to each, and exits
1 only after the last one.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from jrbar import cli
from jrbar.install import InstallResult, install_claude_hooks
from jrbar.providers import HOOK_PROVIDERS


def _result(provider: str, tmp_path: Path, *, changed: bool = False) -> InstallResult:
    return InstallResult(
        provider,
        tmp_path / f"{provider}.config",
        tmp_path / f"{provider}.jsonl",
        changed,
    )


def _private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.parent.chmod(0o700)
    path.chmod(0o600)


@pytest.fixture
def home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    place = tmp_path / "home"
    place.mkdir(mode=0o700)
    monkeypatch.setenv("HOME", str(place))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    return place


def _install_claude(home: Path) -> Path:
    install_claude_hooks(python_executable="python3")
    config = home / ".claude" / "settings.json"
    assert "jrbar" in config.read_text().lower()
    return config


def _config_naming_jrbar(home: Path, relative: str) -> Path:
    """A private agent config with a JR-Bar hook line in it, so a failure to
    edit it is a real leftover and not a file with nothing to remove."""
    path = home / relative
    _private(path, "// jrbar-hook --provider x\n")
    return path


def test_uninstall_all_visits_every_provider_when_one_raises(
    tmp_path: Path, home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    _config_naming_jrbar(home, ".codex/config.toml")
    visited: list[str] = []
    refusal = OSError(f"refusing non-regular file: {tmp_path / 'config.toml'}")

    def fake(provider: str, **_kwargs: object) -> InstallResult:
        visited.append(provider)
        if provider == "codex":
            raise refusal
        return _result(provider, tmp_path, changed=provider == "claude")

    monkeypatch.setattr(cli, "uninstall_provider_hooks", fake)

    code = cli.main(["uninstall", "all", "--dry-run"])

    captured = capsys.readouterr()
    assert visited == list(HOOK_PROVIDERS)
    assert code == 1
    assert "codex: could not remove hooks (OSError: refusing non-regular file" in captured.err
    assert "config.toml" in captured.err
    assert "by hand" in captured.err
    assert "codex: removed" not in captured.out + captured.err
    assert "codex: already uninstalled" not in captured.out + captured.err
    assert "claude: would remove" in captured.out
    for provider in HOOK_PROVIDERS:
        if provider not in {"codex", "claude"}:
            assert f"{provider}: already uninstalled" in captured.out


def test_uninstall_all_names_the_config_it_could_not_clean(
    tmp_path: Path, home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    _config_naming_jrbar(home, ".gemini/settings.json")

    def fake(provider: str, **_kwargs: object) -> InstallResult:
        if provider == "gemini":
            raise ValueError("Expecting value: line 1 column 1 (char 0)")
        return _result(provider, tmp_path)

    monkeypatch.setattr(cli, "uninstall_provider_hooks", fake)

    assert cli.main(["uninstall", "gemini"]) == 1

    err = capsys.readouterr().err
    assert "gemini: could not remove hooks (ValueError: Expecting value" in err
    assert f"config: {home / '.gemini' / 'settings.json'}" in err


def test_uninstall_all_bounds_a_long_reason(
    tmp_path: Path, home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    _config_naming_jrbar(home, ".codex/config.toml")

    def fake(provider: str, **_kwargs: object) -> InstallResult:
        raise OSError("x" * 5000)

    monkeypatch.setattr(cli, "uninstall_provider_hooks", fake)

    assert cli.main(["uninstall", "codex"]) == 1

    assert "x" * 501 not in capsys.readouterr().err


def test_uninstall_all_real_configs_symlink_and_jsonc(
    tmp_path: Path, home: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A symlinked or commented config that does hold a JR-Bar hook is a
    leftover JR-Bar will not edit: named, untouched, exit 1."""
    claude = _install_claude(home)

    outside = tmp_path / "dotfiles" / "config.toml"
    _private(outside, "# my codex settings\n[[hooks.Stop]]\ncommand = \"/opt/jrbar/bin/jrbar-hook --provider codex\"\n")
    codex = home / ".codex" / "config.toml"
    codex.parent.mkdir(mode=0o700)
    codex.symlink_to(outside)

    gemini = home / ".gemini" / "settings.json"
    commented = '// my gemini settings\n{"hooks": {"AfterAgent": [{"command": "jrbar-hook --provider gemini"}]}}\n'
    _private(gemini, commented)
    outside_before = outside.read_bytes()

    code = cli.main(["uninstall", "all"])

    captured = capsys.readouterr()
    assert code == 1
    assert "jrbar" not in claude.read_text().lower()
    assert outside.read_bytes() == outside_before
    assert codex.is_symlink()
    assert gemini.read_text() == commented
    assert "codex: could not remove hooks" in captured.err
    assert "gemini: could not remove hooks" in captured.err
    assert "claude: removed" in captured.out
    assert "devin: already uninstalled" in captured.out
    assert "kiro: already uninstalled" in captured.out


def test_uninstall_all_does_not_fail_over_configs_that_never_named_jrbar(
    tmp_path: Path, home: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A dotfiles symlink or a commented file with no JR-Bar hook in it has
    nothing to remove, so it must not stop the person from deleting the app."""
    outside = tmp_path / "dotfiles" / "config.toml"
    _private(outside, "# my codex settings\n")
    codex = home / ".codex" / "config.toml"
    codex.parent.mkdir(mode=0o700)
    codex.symlink_to(outside)
    gemini = home / ".gemini" / "settings.json"
    commented = '// my gemini settings\n{"theme": "dark"}\n'
    _private(gemini, commented)
    outside_before = outside.read_bytes()

    code = cli.main(["uninstall", "all"])

    captured = capsys.readouterr()
    assert code == 0
    assert captured.err == ""
    assert outside.read_bytes() == outside_before
    assert codex.is_symlink()
    assert gemini.read_text() == commented
    assert "codex: already uninstalled" in captured.out
    assert "gemini: already uninstalled" in captured.out


def test_uninstall_all_clean_run_is_unchanged(
    home: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    claude = _install_claude(home)

    code = cli.main(["uninstall", "all"])

    captured = capsys.readouterr()
    assert code == 0
    assert captured.err == ""
    assert "jrbar" not in claude.read_text().lower()
    lines = captured.out.splitlines()
    assert "claude: removed" in lines
    assert f"  config: {claude}" in lines
    for provider in HOOK_PROVIDERS:
        if provider != "claude":
            assert f"{provider}: already uninstalled" in lines
    # Every provider still prints its result in registry order.
    heads = [line for line in lines if not line.startswith("  ")]
    assert [line.split(":")[0] for line in heads] == list(HOOK_PROVIDERS)


def test_uninstall_all_does_not_swallow_keyboard_interrupt(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake(provider: str, **_kwargs: object) -> InstallResult:
        raise KeyboardInterrupt

    monkeypatch.setattr(cli, "uninstall_provider_hooks", fake)

    with pytest.raises(KeyboardInterrupt):
        cli.main(["uninstall", "all", "--dry-run"])


def test_a_failure_is_never_described_as_a_removal(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def fake(provider: str, **_kwargs: object) -> InstallResult:
        raise OSError(f"refusing non-regular file: {tmp_path / provider}")

    monkeypatch.setattr(cli, "uninstall_provider_hooks", fake)
    # Every config is taken to name JR-Bar, so nothing is waved through.
    monkeypatch.setattr(cli, "_config_names_no_jrbar", lambda provider: None)

    assert cli.main(["uninstall", "all"]) == 1

    captured = capsys.readouterr()
    assert captured.out == ""
    for provider in HOOK_PROVIDERS:
        assert f"{provider}: could not remove hooks" in captured.err
    assert "removed" not in captured.err.replace("could not remove", "")


def test_install_all_isolates_a_raising_provider(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    visited: list[str] = []

    def fake(provider: str, **_kwargs: object) -> InstallResult:
        visited.append(provider)
        if provider == "claude":
            raise OSError(f"refusing non-regular file: {tmp_path / 'settings.json'}")
        return _result(provider, tmp_path, changed=True)

    monkeypatch.setattr(cli, "install_provider_hooks", fake)
    args = cli.build_parser().parse_args(["install", "all", "--dry-run"])

    results = cli.install_hook_results(args)

    captured = capsys.readouterr()
    assert visited == list(HOOK_PROVIDERS)
    assert [result.provider for result in results] == [
        provider for provider in HOOK_PROVIDERS if provider != "claude"
    ]
    assert "claude: skipped (OSError: refusing non-regular file" in captured.err

    # The exit code stays 0: an install that refused wrote nothing.
    args = cli.build_parser().parse_args(["install", "all", "--dry-run"])
    assert cli.cmd_install(args) == 0


def test_install_all_keeps_the_verification_refusal_wording(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    from jrbar.install import HookVerificationError

    def fake(provider: str, **_kwargs: object) -> InstallResult:
        if provider == "codex":
            raise HookVerificationError("the hook did not run: exited 3")
        return _result(provider, tmp_path)

    monkeypatch.setattr(cli, "install_provider_hooks", fake)
    args = cli.build_parser().parse_args(["install", "all", "--dry-run"])

    results = cli.install_hook_results(args)

    assert len(results) == len(HOOK_PROVIDERS) - 1
    assert "codex: the hook did not run: exited 3" in capsys.readouterr().out


def test_install_of_one_named_provider_that_was_refused_exits_nonzero_and_names_the_fix(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def fake(provider: str, **_kwargs: object) -> InstallResult:
        raise OSError(f"refusing non-regular file: {tmp_path / 'settings.json'}")

    monkeypatch.setattr(cli, "install_provider_hooks", fake)
    args = cli.build_parser().parse_args(["install", "claude", "--dry-run"])

    assert cli.cmd_install(args) == 1
    err = capsys.readouterr().err
    assert "claude: skipped (OSError: refusing non-regular file" in err
    assert "remove its entries by hand" not in err, "this is an install: the hint says how to make it installable"
    assert "symlinked or shared-writable" in err


def test_install_all_exits_nonzero_when_not_one_provider_could_be_installed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def fake(provider: str, **_kwargs: object) -> InstallResult:
        raise ValueError("Expected an object at the top level")

    monkeypatch.setattr(cli, "install_provider_hooks", fake)
    args = cli.build_parser().parse_args(["install", "all", "--dry-run"])

    assert cli.cmd_install(args) == 1
    assert "plain JSON" in capsys.readouterr().err
