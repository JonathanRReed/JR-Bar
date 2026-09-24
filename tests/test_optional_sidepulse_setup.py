from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from jrbar import cli


def test_bare_setup_does_not_request_the_sd_eject_guard__and_2_more(capsys) -> None:
    # --- scenario: bare_setup_does_not_request_the_sd_eject_guard
    args = cli.build_jrbar_parser().parse_args(["setup"])

    assert args.sd_eject_guard is False

    # --- scenario: existing_guard_configuration_flags_remain_explicit_opt_ins
    parser = cli.build_jrbar_parser()

    assert parser.parse_args(["setup", "--sd-eject-guard"]).sd_eject_guard is True
    assert parser.parse_args(
        ["setup", "--sd-eject-guard-scope", "auto"]
    ).sd_eject_guard is True
    assert parser.parse_args(
        ["setup", "--sd-eject-guard-volume-uuid", "A1B2-C3D4"]
    ).sd_eject_guard is True

    # --- scenario: bare_setup_installs_hooks_and_nothing_else
    # The Swift app is the UI and registers its own login item: setup no
    # longer installs the retired menu-bar LaunchAgent.
    args = cli.build_jrbar_parser().parse_args(["setup"])
    hook_result = SimpleNamespace(
        provider="codex",
        config_path=Path("/tmp/codex.toml"),
        log_path=Path("/tmp/codex.jsonl"),
        changed=False,
        backup_path=None,
    )

    with (
        patch.object(cli, "install_hook_results", return_value=[hook_result]),
        patch("jrbar.sd_eject_guard_launch.install_sd_eject_guard") as guard,
    ):
        result = cli.cmd_jrbar_setup(args)

    assert result == 0
    guard.assert_not_called()
    assert "status-bar" not in capsys.readouterr().out



def test_no_sd_eject_guard_still_overrides_an_explicit_guard_request() -> None:
    args = cli.build_jrbar_parser().parse_args(
        ["setup", "--sd-eject-guard", "--no-sd-eject-guard"]
    )

    with (
        patch.object(cli, "install_hook_results", return_value=[]),
        patch("jrbar.sd_eject_guard_launch.install_sd_eject_guard") as guard,
    ):
        result = cli.cmd_jrbar_setup(args)

    assert result == 0
    guard.assert_not_called()
