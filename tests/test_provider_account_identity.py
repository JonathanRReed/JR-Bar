from __future__ import annotations

import json
import threading

from jrbar.provider_account_identity import (
    _identity_salt,
    _salt_path,
    claude_account_metadata,
    project_provider_account_identity,
)


def test_user_alias_precedes_safe_account_label__and_2_more() -> None:
    # --- scenario: user_alias_precedes_safe_account_label
    identity = project_provider_account_identity(
        provider_id="claude",
        source_instance_id="internal:profile-42",
        account_label="person@example.com",
        user_alias="Client Claude",
    )

    assert identity.primary_label == "Client Claude"
    assert identity.account_detail is None
    assert identity.full_label == "Client Claude · person@example.com"
    assert "internal:profile-42" not in repr(identity)

    # --- scenario: opaque_or_private_account_labels_use_a_stable_safe_suffix
    for unsafe_label in (
        "org-7535461b-1234-4abc-9def-0123456789ab",
        "d3a51c1c-2b9a-4371-b335-3928397be5cd",
        "acct_8f14e45fceea167a5a36dedd4bea2543",
        "/Users/person/.codex/profiles/work",
        "4e07408562bedb8b60ce05c1decfe3ad16b722309",
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
    ):
        first = project_provider_account_identity(
            provider_id="codex",
            source_instance_id="profile:private-workspace",
            account_label=unsafe_label,
        )
        second = project_provider_account_identity(
            provider_id="codex",
            source_instance_id="profile:private-workspace",
            account_label=unsafe_label,
        )

        assert first == second
        assert first.primary_label.startswith("Codex #")
        assert first.account_detail is None
        assert unsafe_label not in repr(first)
        assert "private-workspace" not in repr(first)

    # --- scenario: privacy_mode_suppresses_alias_and_account_detail
    identity = project_provider_account_identity(
        provider_id="claude",
        source_instance_id="work",
        account_label="person@example.com",
        user_alias="Client Claude",
        privacy_mode=True,
    )

    assert identity.primary_label == "Claude"
    assert identity.account_detail is None
    assert identity.full_label == identity.primary_label
    assert identity.collision_suffix == "private"
    assert "person@example.com" not in repr(identity)
    assert "Client Claude" not in repr(identity)



def test_privacy_mode_strings_do_not_depend_on_private_account_label() -> None:
    first = project_provider_account_identity(
        provider_id="grok",
        source_instance_id="default",
        account_label="first.private@example.com",
        user_alias="Personal",
        privacy_mode=True,
    )
    second = project_provider_account_identity(
        provider_id="grok",
        source_instance_id="default",
        account_label="second.private@example.com",
        user_alias="Work",
        privacy_mode=True,
    )

    assert first == second
    assert first.primary_label == "Grok"
    assert first.full_label == "Grok"


def test_concurrent_salt_creators_reread_one_exclusive_winner(tmp_path, monkeypatch) -> None:
    barrier = threading.Barrier(2)
    lock = threading.Lock()
    issued = 0

    def token_bytes(_count):
        nonlocal issued
        with lock:
            issued += 1
            value = issued
        barrier.wait(timeout=2.0)
        return bytes([value]) * 32

    monkeypatch.setattr("jrbar.provider_account_identity.secrets.token_bytes", token_bytes)
    results = []
    threads = [threading.Thread(target=lambda: results.append(_identity_salt(tmp_path))) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=2.0)

    assert len(results) == 2
    assert results[0] == results[1]
    assert results[0] in {bytes([1]) * 32, bytes([2]) * 32}
    assert _identity_salt(tmp_path) == results[0]


def test_existing_corrupt_salt_fails_closed_without_rotation(tmp_path, monkeypatch) -> None:
    path = _salt_path(tmp_path)
    path.parent.mkdir(parents=True)
    path.write_text("not-a-private-salt", encoding="utf-8")
    monkeypatch.setattr(
        "jrbar.provider_account_identity.secrets.token_bytes",
        lambda _count: (_ for _ in ()).throw(AssertionError("must not rotate")),
    )
    (tmp_path / ".claude.json").write_text(
        json.dumps({"oauthAccount": {"emailAddress": "private@example.invalid"}}),
        encoding="utf-8",
    )

    _plan, discriminator = claude_account_metadata(tmp_path)

    assert discriminator is None
    assert path.read_text(encoding="utf-8") == "not-a-private-salt"


def test_real_home_uses_xdg_state_but_injected_home_stays_isolated(tmp_path, monkeypatch) -> None:
    real_home = tmp_path / "home"
    xdg = tmp_path / "xdg"
    injected = tmp_path / "fixture-home"
    monkeypatch.setattr("pathlib.Path.home", lambda: real_home)
    monkeypatch.setenv("XDG_STATE_HOME", str(xdg))

    assert _salt_path(real_home) == xdg / "jrbar" / "provider-account-identity.key"
    assert _salt_path(injected) == injected / ".local/state/jrbar/provider-account-identity.key"
