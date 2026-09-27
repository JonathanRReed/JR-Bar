"""Privacy-safe provider account labels and private account discriminators."""

from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
from dataclasses import dataclass
from pathlib import Path

from .private_io import atomic_private_write, read_private_text
from .provider_usage_platform import provider_descriptor
from .state_paths import default_state_dir

_SALT_BYTES = 32
_SALT_FILE = "provider-account-identity.key"
_CLAUDE_CONFIG_MAX_BYTES = 8 * 1024 * 1024
_EMAIL = re.compile(
    r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+\Z"
)
_UUID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}",
    re.IGNORECASE,
)
_LONG_HEX = re.compile(r"(?<![0-9a-f])[0-9a-f]{16,}(?![0-9a-f])", re.IGNORECASE)
_LONG_NUMBER = re.compile(r"(?<!\d)\d{8,}(?!\d)")
_INTERNAL_PREFIX = re.compile(
    r"(?:^|\b)(?:acct|account|org|organization|profile|source|tenant|workspace)"
    r"[-_:][A-Za-z0-9._~:-]{6,}",
    re.IGNORECASE,
)
_PATH_FRAGMENT = re.compile(r"(?:^|[\s(])(?:/|~[/\\]|[A-Za-z]:[/\\])")
_OPAQUE_TOKEN = re.compile(r"[A-Za-z0-9._~:+/=-]{32,}\Z")


def _salt_path(home: Path) -> Path:
    base = Path(home).expanduser()
    state = default_state_dir() if base == Path.home().expanduser() else default_state_dir(base)
    return state / _SALT_FILE


def _read_identity_salt(path: Path) -> bytes | None:
    try:
        raw = read_private_text(path, max_bytes=128).strip()
        salt = bytes.fromhex(raw)
    except (OSError, UnicodeError, ValueError):
        return None
    return salt if len(salt) == _SALT_BYTES else None


def _identity_salt(home: Path) -> bytes | None:
    path = _salt_path(home)
    try:
        path.lstat()
    except FileNotFoundError:
        salt = secrets.token_bytes(_SALT_BYTES)
        try:
            atomic_private_write(path, salt.hex(), overwrite=False)
        except FileExistsError:
            pass
        except OSError:
            return None
        return _read_identity_salt(path)
    except OSError:
        return None
    # An existing unreadable, malformed, linked, or non-regular key is not
    # replaceable identity evidence. Fail closed rather than rotating it.
    return _read_identity_salt(path)


def claude_account_metadata(home: Path) -> tuple[str | None, str | None]:
    """Return Claude's plan word and a private account discriminator.

    The email is provider-owned metadata already present in ``.claude.json``.
    It never leaves this boundary. A per-install HMAC prevents the persisted
    discriminator from being reversed with an email dictionary.
    """
    base = Path(home)
    try:
        payload = json.loads(
            read_private_text(base / ".claude.json", max_bytes=_CLAUDE_CONFIG_MAX_BYTES)
        )
    except (OSError, ValueError):
        return None, None
    account = payload.get("oauthAccount") if isinstance(payload, dict) else None
    if not isinstance(account, dict):
        return None, None
    plan = next(
        (
            value
            for key in (
                "userRateLimitTier",
                "organizationRateLimitTier",
                "seatTier",
                "organizationType",
                "subscriptionType",
            )
            if isinstance((value := account.get(key)), str) and value.strip()
        ),
        None,
    )
    email = account.get("emailAddress")
    if not isinstance(email, str) or not email.strip():
        return plan, None
    salt = _identity_salt(base)
    if salt is None:
        return plan, None
    digest = hmac.new(
        salt,
        email.strip().casefold().encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()[:32]
    return plan, f"claude-account-{digest}"


@dataclass(frozen=True, slots=True)
class ProviderAccountIdentityPresentation:
    """Only labels that are safe to hand to a renderer."""

    primary_label: str
    account_detail: str | None
    full_label: str
    collision_suffix: str


def human_readable_account_label(value: str | None) -> str | None:
    """Return a bounded human label, never an internal ID or profile path."""

    if not isinstance(value, str):
        return None
    label = " ".join(value.strip().split())
    if not label or len(label) > 96 or any(ord(character) < 32 for character in label):
        return None
    if _EMAIL.fullmatch(label):
        return label
    if _PATH_FRAGMENT.search(label) or _UUID.search(label):
        return None
    if _LONG_HEX.search(label) or _LONG_NUMBER.search(label):
        return None
    if _INTERNAL_PREFIX.search(label):
        return None
    if _OPAQUE_TOKEN.fullmatch(label):
        return None
    if sum(character.isalpha() for character in label) < 2:
        return None
    return label


def configured_user_alias(
    *,
    provider_id: str,
    source_instance_id: str,
    visual_label: str | None,
) -> str | None:
    """Distinguish an explicit visual alias from legacy generated labels."""

    alias = human_readable_account_label(visual_label)
    if alias is None:
        return None
    provider_label = provider_descriptor(provider_id).label
    generated = {provider_label, f"{provider_label} · {source_instance_id}"}
    return None if alias in generated else alias


def _collision_suffix(
    provider_id: str,
    source_instance_id: str,
    account_label: str | None,
) -> str:
    material = "\0".join((provider_id, source_instance_id, account_label or ""))
    return hashlib.blake2s(
        material.encode("utf-8", "surrogatepass"),
        digest_size=4,
        person=b"SidePuls",
    ).hexdigest()


def project_provider_account_identity(
    *,
    provider_id: str,
    source_instance_id: str,
    account_label: str | None,
    user_alias: str | None = None,
    privacy_mode: bool = False,
) -> ProviderAccountIdentityPresentation:
    """Apply the alias, account-label, and opaque-fallback display policy."""

    provider_label = provider_descriptor(provider_id).label
    if privacy_mode:
        return ProviderAccountIdentityPresentation(
            provider_label,
            None,
            provider_label,
            "private",
        )

    suffix = _collision_suffix(provider_id, source_instance_id, account_label)
    fallback = f"{provider_label} #{suffix}"
    alias = human_readable_account_label(user_alias)
    account = human_readable_account_label(account_label)
    if alias is not None:
        full_label = alias if account is None or account == alias else f"{alias} · {account}"
        return ProviderAccountIdentityPresentation(alias, None, full_label, suffix)
    if account is not None:
        return ProviderAccountIdentityPresentation(
            provider_label,
            account,
            f"{provider_label} · {account}",
            suffix,
        )
    if source_instance_id == "default" and account_label is None:
        return ProviderAccountIdentityPresentation(
            provider_label,
            None,
            provider_label,
            suffix,
        )
    return ProviderAccountIdentityPresentation(fallback, None, fallback, suffix)


__all__ = [
    "ProviderAccountIdentityPresentation",
    "claude_account_metadata",
    "configured_user_alias",
    "human_readable_account_label",
    "project_provider_account_identity",
]
