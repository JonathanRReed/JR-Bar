from __future__ import annotations

import json
import multiprocessing
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar.core_projection import hook_health, managed_hooks
from jrbar.doctor import DiagnosticCode
from jrbar.install import refresh_managed_hooks
from jrbar.intake_health import ProviderIntake
from jrbar.providers import (
    KIRO_MANAGED_DESCRIPTION,
    default_log_path,
    detect_claude_config,
    detect_codex_config,
    detect_grok_config,
    is_jrbar_hook_command,
)


def _hold_hook_lock(state: str, ready, release) -> None:
    from jrbar.install import hook_mutation_lock

    with hook_mutation_lock(state_dir=Path(state), timeout=1):
        ready.send(True)
        release.recv()


def test_foreign_codex_and_claude_hooks_are_not_managed(tmp_path: Path) -> None:
    codex = tmp_path / ".codex" / "config.toml"
    codex.parent.mkdir()
    codex.write_text('[features]\nhooks = true\n[[hooks.SessionStart]]\ncommand = "other-tool"\n')
    claude = tmp_path / ".claude" / "settings.json"
    claude.parent.mkdir()
    claude.write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "other-tool"}]}]}}))

    assert not detect_codex_config(tmp_path).managed
    assert not detect_claude_config(tmp_path).managed


@pytest.mark.parametrize(
    "command",
    [
        "echo jrbar-hook --provider claude",
        "python -m other_tool --label jrbar.hook_client --provider claude",
        "python /tmp/unrelated/hook_entry.py --provider claude",
        "echo agent-monitor hook-client --provider claude",
    ],
)
def test_mentioning_jrbar_tokens_does_not_establish_ownership(command: str) -> None:
    assert not is_jrbar_hook_command(command, "claude")


def test_foreign_mentions_stay_byte_identical_through_refresh(tmp_path: Path) -> None:
    config = tmp_path / ".claude" / "settings.json"
    config.parent.mkdir()
    payload = {
        "hooks": {
            "SessionStart": [
                {"hooks": [{"command": "echo jrbar-hook --provider claude"}]},
                {"hooks": [{"command": "python -m other_tool --label jrbar.hook_client --provider claude"}]},
            ]
        }
    }
    config.write_text(json.dumps(payload, indent=2) + "\n")
    before = config.read_bytes()
    results = refresh_managed_hooks(home=tmp_path, state_dir=tmp_path / "state")
    assert "claude" not in results
    assert config.read_bytes() == before


def test_foreign_grok_is_not_managed_and_legacy_claude_is(tmp_path: Path) -> None:
    grok = tmp_path / ".grok" / "hooks" / "jrbar.json"
    grok.parent.mkdir(parents=True)
    grok.write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [{"command": "other-tool"}]}]}}))
    assert not detect_grok_config(tmp_path).managed

    log = default_log_path("claude", tmp_path)
    claude = tmp_path / ".claude" / "settings.json"
    claude.parent.mkdir()
    command = f"agent-monitor hook-client --provider claude --log {log}"
    claude.write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [{"command": command}]}]}}))
    assert detect_claude_config(tmp_path).managed


def test_owned_json_commands_without_log_use_the_default_path(tmp_path: Path) -> None:
    claude = tmp_path / ".claude" / "settings.json"
    claude.parent.mkdir()
    for command in (
        "/tmp/jrbar-hook --provider claude",
        "agent-monitor hook-client --provider claude",
    ):
        claude.write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [{"command": command}]}]}}))
        detected = detect_claude_config(tmp_path)
        assert detected.managed
        assert detected.log_paths == ()


def test_flat_owned_commands_without_log_count_for_cursor_hermes_and_kiro(tmp_path: Path) -> None:
    cursor = tmp_path / ".cursor" / "hooks.json"
    cursor.parent.mkdir()
    cursor.write_text(json.dumps({"hooks": {"sessionStart": [{"command": "/tmp/jrbar-hook --provider cursor"}]}}))
    assert __import__("jrbar.providers", fromlist=["detect_cursor_config"]).detect_cursor_config(tmp_path).managed

    hermes = tmp_path / ".hermes" / "config.yaml"
    hermes.parent.mkdir()
    hermes.write_text('hooks:\n  on_session_start:\n    - command: "/tmp/jrbar-hook --provider hermes"\n')
    assert __import__("jrbar.providers", fromlist=["detect_hermes_config"]).detect_hermes_config(tmp_path).managed

    kiro = tmp_path / ".kiro" / "agents" / "jrbar.json"
    kiro.parent.mkdir(parents=True)
    kiro.write_text(json.dumps({"description": KIRO_MANAGED_DESCRIPTION, "hooks": {"agentSpawn": [{"command": "/tmp/jrbar-hook --provider kiro"}]}}))
    assert __import__("jrbar.providers", fromlist=["detect_kiro_config"]).detect_kiro_config(tmp_path).managed


def test_disabled_owned_hooks_are_managed_but_report_disabled(tmp_path: Path) -> None:
    log = tmp_path / "state" / "claude.jsonl"
    command = f"/tmp/jrbar-hook --provider claude --log {log}"
    config = tmp_path / ".claude" / "settings.json"
    config.parent.mkdir()
    config.write_text(json.dumps({"disableAllHooks": True, "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": command}]}]}}))
    detected = detect_claude_config(tmp_path)
    assert detected.managed
    assert not detected.hooks_enabled

    intake = ProviderIntake("claude", "Claude", DiagnosticCode.CONFIGURED, True, None, None, None, False)
    report = type("Report", (), {"providers": (intake,)})()
    assert hook_health(report) == {"claude": "disabled"}
    assert managed_hooks(report) == ["claude"]


def test_refresh_preserves_codex_disabled_flag(tmp_path: Path) -> None:
    state = tmp_path / "state"
    log = state / "codex.jsonl"
    config = tmp_path / ".codex" / "config.toml"
    config.parent.mkdir()
    config.write_text('[features]\nhooks = false\n# >>> jrbar hooks >>>\n[[hooks.SessionStart]]\nmatcher = "*"\n[[hooks.SessionStart.hooks]]\ntype = "command"\ncommand = "/tmp/jrbar-hook --provider codex --log ' + str(log) + '"\n# <<< jrbar hooks <<<\n')

    result = refresh_managed_hooks(home=tmp_path, state_dir=state, python_executable=sys.executable)
    assert result["codex"].provider == "codex"
    assert "hooks = false" in config.read_text()


def test_refresh_preserves_claude_disable_while_explicit_install_enables(tmp_path: Path) -> None:
    import jrbar.install as install

    state = tmp_path / ".local" / "state" / "jrbar"
    log = default_log_path("claude", tmp_path)
    config = tmp_path / ".claude" / "settings.json"
    config.parent.mkdir()
    command = f"{sys.executable} -m jrbar.hook_client --provider claude --log {log}"
    config.write_text(json.dumps({
        "disableAllHooks": True,
        "hooks": {"SessionStart": [{"matcher": "*", "hooks": [{"type": "command", "command": command}]}]},
    }))

    refresh_managed_hooks(home=tmp_path, state_dir=state, python_executable=sys.executable)
    assert json.loads(config.read_text())["disableAllHooks"] is True
    install.install_claude_hooks(log, config, python_executable=sys.executable)
    assert json.loads(config.read_text())["disableAllHooks"] is False


def test_refresh_preserves_openclaw_global_and_entry_disable(tmp_path: Path) -> None:
    import jrbar.install as install

    state = tmp_path / ".local" / "state" / "jrbar"
    log = default_log_path("openclaw", tmp_path)
    config = tmp_path / ".openclaw" / "openclaw.json"
    install.install_openclaw_hooks(log, config, python_executable=sys.executable)
    data = json.loads(config.read_text())
    data["hooks"]["internal"]["enabled"] = False
    data["hooks"]["internal"]["entries"]["jrbar-status"]["enabled"] = False
    config.write_text(json.dumps(data))

    refresh_managed_hooks(home=tmp_path, state_dir=state, python_executable=sys.executable)
    refreshed = json.loads(config.read_text())["hooks"]["internal"]
    assert refreshed["enabled"] is False
    assert refreshed["entries"]["jrbar-status"]["enabled"] is False
    install.install_openclaw_hooks(log, config, python_executable=sys.executable)
    explicit = json.loads(config.read_text())["hooks"]["internal"]
    assert explicit["enabled"] is True
    assert explicit["entries"]["jrbar-status"]["enabled"] is True


def test_refresh_reuses_one_custom_log_without_duplication(tmp_path: Path) -> None:
    import jrbar.install as install

    state = tmp_path / "state"
    custom = tmp_path / "custom" / "claude-events.jsonl"
    config = tmp_path / ".claude" / "settings.json"
    install.install_claude_hooks(custom, config, python_executable=sys.executable)
    first = config.read_text()
    refresh_managed_hooks(home=tmp_path, state_dir=state, python_executable=sys.executable)
    refresh_managed_hooks(home=tmp_path, state_dir=state, python_executable=sys.executable)
    assert config.read_text() == first
    assert config.read_text().count(str(custom)) == len(__import__("jrbar.providers", fromlist=["CLAUDE_EVENTS"]).CLAUDE_EVENTS)


@pytest.mark.parametrize("provider", ["claude", "devin", "grok", "cursor", "hermes", "gemini"])
def test_shared_config_refresh_keeps_custom_log_and_is_idempotent(
    tmp_path: Path, provider: str
) -> None:
    import jrbar.install as install

    spec = install.PROVIDER_REGISTRY[provider]
    config = spec.config_path(tmp_path)
    custom = tmp_path / "custom" / f"{provider}.jsonl"
    install.INSTALLERS[provider](
        log_path=custom,
        config_path=config,
        python_executable=sys.executable,
    )
    first = config.read_bytes()
    state = tmp_path / "state"
    first_refresh = refresh_managed_hooks(
        home=tmp_path, state_dir=state, python_executable=sys.executable
    )
    second_refresh = refresh_managed_hooks(
        home=tmp_path, state_dir=state, python_executable=sys.executable
    )
    assert not isinstance(first_refresh[provider], Exception)
    assert not isinstance(second_refresh[provider], Exception)
    assert config.read_bytes() == first
    assert config.read_text().count(str(custom)) > 0


def test_refresh_refuses_ambiguous_logs_without_writing(tmp_path: Path, monkeypatch) -> None:
    import jrbar.install as install

    config = tmp_path / "config.json"
    config.write_text("untouched")
    spec = SimpleNamespace(
        detector=lambda _home: SimpleNamespace(
            managed=True, log_paths=(tmp_path / "a.jsonl", tmp_path / "b.jsonl")
        ),
        config_path=lambda _home: config,
    )
    monkeypatch.setattr(install, "PROVIDER_REGISTRY", {"claude": spec})
    results = install.refresh_managed_hooks(home=tmp_path, state_dir=tmp_path / "state")
    assert isinstance(results["claude"], ValueError)
    assert config.read_text() == "untouched"


def test_dry_run_refresh_creates_no_lock(tmp_path: Path) -> None:
    state = tmp_path / "state"
    assert refresh_managed_hooks(home=tmp_path, state_dir=state, dry_run=True) == {}
    assert not state.exists()


def test_dry_run_public_wrapper_creates_no_lock(tmp_path: Path) -> None:
    import jrbar.install as install

    state = tmp_path / "state"
    config = tmp_path / ".claude" / "settings.json"
    result = install.install_provider_hooks(
        "claude", config_path=config, log_path=state / "claude.jsonl",
        state_dir=state, lock_timeout=0.01, dry_run=True,
    )
    assert result.dry_run
    assert not state.exists()


def test_refresh_uses_plugin_and_extension_path_keywords(tmp_path: Path) -> None:
    import jrbar.install as install

    state = tmp_path / ".local" / "state" / "jrbar"
    install.install_opencode_plugin(
        default_log_path("opencode", tmp_path),
        tmp_path / ".config" / "opencode" / "plugins" / "jrbar.js",
        python_executable=sys.executable,
    )
    install.install_pi_extension(
        default_log_path("pi", tmp_path),
        tmp_path / ".pi" / "agent" / "extensions" / "jrbar.ts",
        python_executable=sys.executable,
    )
    results = refresh_managed_hooks(
        home=tmp_path, state_dir=state, python_executable=sys.executable
    )
    assert results["opencode"].provider == "opencode"
    assert results["pi"].provider == "pi"


def test_every_registered_provider_uses_its_installer_path_keyword() -> None:
    import jrbar.install as install

    assert {
        provider: install._refresh_path_argument(provider)
        for provider in install.PROVIDER_REGISTRY
    } == {
        provider: (
            "plugin_path" if provider == "opencode"
            else "config_path"
        )
        for provider in install.PROVIDER_REGISTRY
    }


def test_detector_failure_is_one_refresh_result(tmp_path: Path, monkeypatch) -> None:
    import jrbar.install as install

    good_path = tmp_path / "good.json"
    specs = {
        "bad": SimpleNamespace(
            detector=lambda _home: (_ for _ in ()).throw(ValueError("bad detector")),
            config_path=lambda _home: tmp_path / "bad.json",
        ),
        "good": SimpleNamespace(
            detector=lambda _home: SimpleNamespace(managed=True, log_paths=()),
            config_path=lambda _home: good_path,
        ),
    }
    monkeypatch.setattr(install, "PROVIDER_REGISTRY", specs)
    monkeypatch.setitem(
        install.INSTALLERS,
        "good",
        lambda **kwargs: install.InstallResult(
            "good", kwargs["config_path"], kwargs["log_path"], False, None, True
        ),
    )
    results = install.refresh_managed_hooks(
        home=tmp_path, state_dir=tmp_path / "state", dry_run=True
    )
    assert isinstance(results["bad"], ValueError)
    assert results["good"].provider == "good"


def test_hook_lock_rejects_links_without_changing_target_mode(tmp_path: Path) -> None:
    import jrbar.install as install

    target = tmp_path / "target"
    target.write_text("")
    target.chmod(0o644)
    hardlink = tmp_path / "hardlink"
    hardlink.hardlink_to(target)
    symlink = tmp_path / "symlink"
    symlink.symlink_to(target)

    for path in (hardlink, symlink):
        try:
            with install.hook_mutation_lock(lock_path=path, timeout=0.01):
                raise AssertionError("unsafe lock should not open")
        except OSError:
            pass
        assert target.stat().st_mode & 0o777 == 0o644


def test_hook_lock_orders_two_processes(tmp_path: Path) -> None:
    state = tmp_path / "state"
    ready_parent, ready_child = multiprocessing.Pipe()
    release_parent, release_child = multiprocessing.Pipe()
    process = multiprocessing.Process(
        target=_hold_hook_lock,
        args=(str(state), ready_child, release_child),
    )
    process.start()
    assert ready_parent.poll(2) and ready_parent.recv() is True
    started = time.monotonic()
    try:
        with __import__("jrbar.install", fromlist=["hook_mutation_lock"]).hook_mutation_lock(
            state_dir=state, timeout=0.05
        ):
            raise AssertionError("second process should own the lock")
    except TimeoutError:
        pass
    assert time.monotonic() - started >= 0.04
    release_parent.send(True)
    process.join(2)
    assert process.exitcode == 0


def test_refresh_and_remove_share_one_bounded_lock(tmp_path: Path, monkeypatch) -> None:
    import jrbar.install as install

    state = tmp_path / "state"
    entered = threading.Event()
    release = threading.Event()

    def held_refresh(**kwargs):
        with install.hook_mutation_lock(state_dir=state, timeout=1):
            entered.set()
            assert release.wait(1)

    thread = threading.Thread(target=held_refresh)
    thread.start()
    assert entered.wait(1)
    try:
        try:
            with install.hook_mutation_lock(state_dir=state, timeout=0.01):
                raise AssertionError("lock should not be re-entered")
        except TimeoutError:
            pass
    finally:
        release.set()
        thread.join(1)
    assert not thread.is_alive()


def test_remove_that_gets_lock_first_stays_removed(tmp_path: Path, monkeypatch) -> None:
    import jrbar.install as install

    state = tmp_path / ".local" / "state" / "jrbar"
    log = default_log_path("claude", tmp_path)
    config = tmp_path / ".claude" / "settings.json"
    install.install_claude_hooks(log, config, python_executable=sys.executable)
    entered = threading.Event()
    release = threading.Event()
    original = install.UNINSTALLERS["claude"]

    def held_remove(**kwargs):
        entered.set()
        assert release.wait(1)
        return original(**kwargs)

    monkeypatch.setitem(install.UNINSTALLERS, "claude", held_remove)
    remover = threading.Thread(target=lambda: install.uninstall_provider_hooks(
        "claude", log_path=log, config_path=config, state_dir=state))
    refresher_result: dict = {}
    refresher = threading.Thread(target=lambda: refresher_result.update(
        install.refresh_managed_hooks(home=tmp_path, state_dir=state, python_executable=sys.executable)))
    remover.start()
    assert entered.wait(1)
    refresher.start()
    release.set()
    remover.join(2)
    refresher.join(2)
    assert refresher_result == {}
    assert not detect_claude_config(tmp_path).managed


def test_remove_that_waits_for_refresh_runs_last(tmp_path: Path, monkeypatch) -> None:
    import jrbar.install as install

    state = tmp_path / ".local" / "state" / "jrbar"
    log = default_log_path("claude", tmp_path)
    config = tmp_path / ".claude" / "settings.json"
    install.install_claude_hooks(log, config, python_executable=sys.executable)
    entered = threading.Event()
    release = threading.Event()
    original = install.INSTALLERS["claude"]

    def held_refresh(**kwargs):
        entered.set()
        assert release.wait(1)
        return original(**kwargs)

    monkeypatch.setitem(install.INSTALLERS, "claude", held_refresh)
    refresher = threading.Thread(target=lambda: install.refresh_managed_hooks(
        home=tmp_path, state_dir=state, python_executable=sys.executable))
    remover = threading.Thread(target=lambda: install.uninstall_provider_hooks(
        "claude", log_path=log, config_path=config, state_dir=state))
    refresher.start()
    assert entered.wait(1)
    remover.start()
    release.set()
    refresher.join(2)
    remover.join(2)
    assert not detect_claude_config(tmp_path).managed
