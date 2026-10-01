"""A sweep for the Alcove defect, everywhere else it already lived.

The Alcove bug was never really about Alcove. It was a call site where a
missing permission, a real failure, a not-yet-loaded state and a genuine
empty result all came back as the SAME falsy value, so no surface could
tell them apart and the user was shown a confident-looking nothing --
a switch reading ON over a feature that had never once run.

These pin the other instances of it that still have a live owner:

* The Codex installer wrote a hook and reported success when the trust
  handshake never happened, leaving a hook Codex refuses to execute.
* A doctor probe that raised before reading anything still rendered a
  denominator, e.g. "unavailable [0/32]" out of 32 paths never examined.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest

from jrbar import doctor as doctor_module
from jrbar.doctor import (
    DiagnosticCheck,
    DiagnosticCode,
    DiagnosticProbe,
    collect_diagnostics,
    render_diagnostic_result,
)
from jrbar.install import (
    CodexHookTrust,
    CodexHookTrustStatus,
    InstallResult,
    install_codex_hooks,
    resolve_codex_hook_trust,
)

# --- The Codex installer's trust handshake -------------------------------


def test_no_codex_binary_is_not_the_same_as_nothing_to_trust() -> None:
    """Both used to be an empty dict, and the installer returned on it.

    Codex refuses to run a hook whose hash it has not trusted, so this
    is the difference between "installed" and "installed, and it will
    not run until you approve it".
    """
    with patch("jrbar.install.codex_cli_path", return_value=None):
        missing = resolve_codex_hook_trust(Path("/tmp/config.toml"))
    with (
        patch("jrbar.install.local_codex_hook_hashes", return_value={}),
        patch("jrbar.install.codex_cli_path", return_value=Path("/usr/bin/codex")),
        patch("jrbar.install.resolve_codex_hook_hashes", return_value={}),
    ):
        silent = resolve_codex_hook_trust(Path("/tmp/config.toml"))

    assert missing.status is CodexHookTrustStatus.CLI_NOT_FOUND
    assert silent.status is CodexHookTrustStatus.NOT_CONFIRMED
    assert missing.status is not silent.status
    assert missing.hashes == {} and silent.hashes == {}



def test_a_confirmed_handshake_carries_its_hashes__and_2_more() -> None:
    # --- scenario: a_confirmed_handshake_carries_its_hashes
    with (
        patch("jrbar.install.codex_cli_path", return_value=Path("/usr/bin/codex")),
        patch(
            "jrbar.install.resolve_codex_hook_hashes",
            return_value={"key": "sha256:abc"},
        ),
    ):
        trust = resolve_codex_hook_trust(Path("/tmp/config.toml"))

    assert trust.status is CodexHookTrustStatus.TRUSTED
    assert trust.hashes == {"key": "sha256:abc"}

    # --- scenario: a_trust_status_cannot_disagree_with_its_payload
    with pytest.raises(ValueError):
        CodexHookTrust(CodexHookTrustStatus.TRUSTED)
    with pytest.raises(ValueError):
        CodexHookTrust(CodexHookTrustStatus.CLI_NOT_FOUND, {"key": "sha256:abc"})

    # --- scenario: an_install_that_could_not_get_trusted_says_so
    """`changed` was the installer's only bit, and it was True here."""
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        config = base / "config.toml"
        log = base / "codex.jsonl"
        config.write_text("[features]\nhooks = true\n")

        with (
            patch("jrbar.install.should_refresh_codex_hook_trust", return_value=True),
            patch("jrbar.install.local_codex_hook_hashes", return_value={}),
            patch("jrbar.install.codex_cli_path", return_value=None),
        ):
            result = install_codex_hooks(
                log_path=log, config_path=config, python_executable="python3"
            )

    assert result.changed
    assert result.codex_trust is CodexHookTrustStatus.CLI_NOT_FOUND
    assert "Codex will ask you to trust it" in result.public_warning
    assert result.to_dict()["codex_trust"] == "cli_not_found"



def test_a_trusted_install_carries_no_warning__and_2_more() -> None:
    # --- scenario: a_trusted_install_carries_no_warning
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        config = base / "config.toml"
        log = base / "codex.jsonl"
        key = f"{config}:pre_tool_use:0:0"
        config.write_text("[features]\nhooks = true\n")

        with (
            patch("jrbar.install.should_refresh_codex_hook_trust", return_value=True),
            patch(
                "jrbar.install.codex_cli_path", return_value=Path("/usr/bin/codex")
            ),
            patch(
                "jrbar.install.resolve_codex_hook_hashes",
                return_value={key: "sha256:new"},
            ),
        ):
            result = install_codex_hooks(
                log_path=log, config_path=config, python_executable="python3"
            )

    assert result.codex_trust is CodexHookTrustStatus.TRUSTED
    assert result.public_warning == ""

    # --- scenario: a_provider_without_a_handshake_is_not_reported_as_untrusted
    """None means "this provider has no trust step", not "it failed"."""
    result = InstallResult("claude", Path("/tmp/c"), Path("/tmp/l"), True)

    assert result.codex_trust is None
    assert result.public_warning == ""
    assert result.to_dict()["warning"] == ""

    # --- scenario: a_failed_probe_does_not_render_a_total_it_never_counted
    """"unavailable [0/32]" reads as 32 paths checked and none private.

    The probe raised before reading one of them. The manifest ceiling is
    a bound on what MAY be reported, not a count of what was.
    """

    def exploding() -> None:
        raise PermissionError("denied")

    probes = tuple(
        DiagnosticProbe(
            check,
            exploding
            if check is DiagnosticCheck.PRIVATE_PATH_MODES
            else (
                lambda c=check: doctor_module._finding(
                    c,
                    (
                        DiagnosticCode.RECOVERING
                        if c is DiagnosticCheck.ALCOVE_FOLLOW_STATE
                        else DiagnosticCode.UNAVAILABLE
                    ),
                    0,
                    0,
                )
            ),
        )
        for check in DiagnosticCheck
    )

    result = collect_diagnostics(probes=probes)
    finding = result.finding(DiagnosticCheck.PRIVATE_PATH_MODES)

    assert finding.code is DiagnosticCode.UNAVAILABLE
    assert (finding.count, finding.limit) == (0, 0)
    assert "private path modes: unavailable [0/0]" in render_diagnostic_result(result)
