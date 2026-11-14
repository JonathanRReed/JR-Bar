"""After Codex hooks change, the person is told a new session is needed."""
from pathlib import Path

from jrbar import cli
from jrbar.install import CODEX_NEW_SESSION_NOTE, InstallResult, install_note


def _result(provider: str, *, changed: bool, dry_run: bool = False) -> InstallResult:
    return InstallResult(
        provider=provider,
        config_path=Path("/synthetic/config.toml"),
        log_path=Path("/synthetic/events.jsonl"),
        changed=changed,
        dry_run=dry_run,
    )


def test_a_changed_codex_install_asks_for_a_new_session():
    assert install_note(_result("codex", changed=True)) == CODEX_NEW_SESSION_NOTE
    assert "new Codex session" in CODEX_NEW_SESSION_NOTE


def test_nothing_is_said_when_nothing_was_installed_or_no_new_session_is_needed():
    # Already in place: the running sessions have these hooks.
    assert install_note(_result("codex", changed=False)) == ""
    # A dry run installed nothing, so it must not claim anything took effect.
    assert install_note(_result("codex", changed=True, dry_run=True)) == ""
    # Only Codex is known to need it.
    assert install_note(_result("claude", changed=True)) == ""
    assert install_note(_result("gemini", changed=True)) == ""


def test_the_cli_prints_the_note_under_a_changed_codex_install(capsys):
    cli.print_install_results(
        [_result("codex", changed=True), _result("claude", changed=True)], dry_run=False
    )
    out = capsys.readouterr().out
    assert out.count(CODEX_NEW_SESSION_NOTE) == 1
    assert out.index("codex: updated") < out.index(CODEX_NEW_SESSION_NOTE) < out.index("claude: updated")

    cli.print_install_results([_result("codex", changed=True, dry_run=True)], dry_run=True)
    dry = capsys.readouterr().out
    assert "would update" in dry and CODEX_NEW_SESSION_NOTE not in dry

    cli.print_install_results([_result("codex", changed=False)], dry_run=False)
    assert CODEX_NEW_SESSION_NOTE not in capsys.readouterr().out
