"""What `reconnect_provider` found, as a value Fix sign-in can decide from.

`ResignInResult.outcome` carries the repair outcome for the two providers whose own
tooling can say (Claude, Grok) and is `None` for the rest, and `keychain_fingerprint`'s
`fresh` look is how the sign-in fix asks "did Claude Code just renew its item?" without
waiting out the 60 s cache. Nothing here reads the real Keychain or `~/.claude`.
"""

from __future__ import annotations

import json
import subprocess
from types import SimpleNamespace

from jrbar import provider_reconnect
from jrbar.provider_reconnect import RepairOutcome, reconnect_provider


class Store:
    def __init__(self) -> None:
        self.secrets: dict[tuple[str, str], str] = {}

    def get(self, provider_id, account):
        secret = self.secrets.get((provider_id, account))
        return SimpleNamespace(available=secret is not None, secret=secret)

    def set(self, provider_id, account, secret):
        self.secrets[(provider_id, account)] = secret

    def delete(self, provider_id, account):
        return self.secrets.pop((provider_id, account), None) is not None


def claude_payload(*, access: str, expires_at: float | None = None) -> str:
    oauth = {"accessToken": access, "refreshToken": "refresh-held-by-claude-code"}
    if expires_at is not None:
        oauth["expiresAt"] = expires_at
    return json.dumps({"claudeAiOauth": oauth})


def test_a_claude_re_read_says_what_it_found() -> None:
    expired = reconnect_provider(
        "claude",
        credential_store=Store(),
        now=5_000.0,
        keychain_payload_reader=lambda: claude_payload(access="old-access", expires_at=1_000.0),
    )
    fresh = reconnect_provider(
        "claude",
        credential_store=Store(),
        now=1_000.0,
        keychain_payload_reader=lambda: claude_payload(access="new-access-token", expires_at=9_000_000.0),
    )
    again = Store()
    again.set("claude", "oauth-token", "new-access-token")
    already = reconnect_provider(
        "claude",
        credential_store=again,
        now=1_000.0,
        keychain_payload_reader=lambda: claude_payload(access="new-access-token", expires_at=9_000_000.0),
    )
    missing = reconnect_provider(
        "claude", credential_store=Store(), now=1_000.0, keychain_payload_reader=lambda: None
    )

    assert expired.outcome is RepairOutcome.NEEDS_PROVIDER_REFRESH and not expired.changed
    assert fresh.outcome is RepairOutcome.REPAIRED and fresh.changed
    assert already.outcome is RepairOutcome.ALREADY_HEALTHY
    assert missing.outcome is RepairOutcome.UNAVAILABLE


def test_a_grok_re_read_says_what_it_found(tmp_path) -> None:
    grok_dir = tmp_path / ".grok"
    grok_dir.mkdir()
    (grok_dir / "auth.json").write_text(
        json.dumps({"https://auth.x.ai::abc": {"key": "tok-" + "x" * 24, "email": "someone@example.invalid"}}),
        encoding="utf-8",
    )
    live = reconnect_provider("grok", credential_store=Store(), home=tmp_path, now=1_000.0)
    rejected = reconnect_provider(
        "grok",
        reason_code="authentication_required",
        credential_store=Store(),
        home=tmp_path,
        now=1_000.0,
    )
    absent = reconnect_provider("grok", credential_store=Store(), home=tmp_path / "nowhere", now=1_000.0)

    assert live.outcome in (RepairOutcome.ALREADY_HEALTHY, RepairOutcome.REPAIRED)
    assert rejected.outcome is RepairOutcome.NEEDS_SIGN_IN
    assert absent.outcome is RepairOutcome.NEEDS_SIGN_IN


def test_the_other_providers_carry_no_outcome(tmp_path) -> None:
    for provider in ("codex", "gemini", "opencode", "cursor"):
        result = reconnect_provider(provider, credential_store=Store(), home=tmp_path, now=1_000.0)
        assert result.outcome is None, provider


def test_a_fresh_look_at_the_keychain_item_skips_the_sixty_second_cache(monkeypatch) -> None:
    stamps = iter(("Jan 01 00:00:00 2026", "Jan 02 00:00:00 2026"))
    looks: list[list[str]] = []

    def fake_security(argv, **_kwargs):
        looks.append(list(argv))
        return SimpleNamespace(
            returncode=0,
            stdout=f'    "mdat"<timedate>="{next(stamps)}"\n    "cdat"<timedate>="Jan 01 00:00:00 2026"\n',
        )

    monkeypatch.setattr(subprocess, "run", fake_security)
    provider_reconnect._KEYCHAIN_FINGERPRINT_CACHE.clear()
    try:
        first = provider_reconnect.keychain_fingerprint("svc", now=0.0)
        cached = provider_reconnect.keychain_fingerprint("svc", now=30.0)
        fresh = provider_reconnect.keychain_fingerprint("svc", now=30.0, fresh=True)
        after = provider_reconnect.keychain_fingerprint("svc", now=31.0)
    finally:
        provider_reconnect._KEYCHAIN_FINGERPRINT_CACHE.clear()

    assert cached == first, "an ordinary look inside the cache is not repeated"
    assert len(looks) == 2, "the fresh look asked again, once"
    assert fresh != first and "Jan 02" in repr(fresh)
    assert after == fresh, "the fresh answer is what the gate sees next"
    # It asks for attributes only: no -w, so no secret is read.
    assert all("-w" not in argv and "-g" not in argv for argv in looks)


def test_the_credential_fingerprint_passes_a_fresh_look_through(tmp_path, monkeypatch) -> None:
    seen: list[bool] = []

    def spy(service, *, now=None, fresh=False):
        seen.append(fresh)
        return (("keychain", service, "stamp", "created"),)

    monkeypatch.setattr(provider_reconnect, "keychain_fingerprint", spy)

    provider_reconnect.credential_fingerprint(tmp_path, "claude")
    provider_reconnect.credential_fingerprint(tmp_path, "claude", fresh=True)

    assert seen == [False, True]
