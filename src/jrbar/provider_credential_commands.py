"""Local credential writes without settings changes or usage requests."""

from __future__ import annotations

import unicodedata

from .core_server import CommandError
from .provider_instances import ProviderInstanceKey
from .provider_management import CREDENTIAL_ACCOUNTS
from .provider_usage_platform import provider_descriptor
from .provider_usage_settings import load_provider_usage_settings


def change_credential(args, credentials, *, delete=False, validate=None):
    provider = args.get("provider")
    account = args.get("account")
    instance = args.get("instance", "default")
    if provider == "factory" and account == "web-session":
        raise CommandError("invalid_args", "Use the Factory browser session import or disconnect command")
    if any(not isinstance(value, str) or not value for value in (provider, account, instance)):
        raise CommandError("invalid_args", "provider, account and instance must be nonempty strings")
    try:
        provider_descriptor(provider)
    except ValueError:
        raise CommandError("unknown_provider", "provider is not supported") from None
    if account not in CREDENTIAL_ACCOUNTS.get(provider, ()):
        raise CommandError("invalid_args", "credential account is not supported")
    try:
        key = ProviderInstanceKey(provider, instance)
        configured = load_provider_usage_settings().settings.providers
        exists = any(row.provider_id == provider and row.source_instance_id == instance for row in configured)
    except Exception:
        raise CommandError("unavailable", "provider settings could not be read") from None
    if not exists:
        raise CommandError("unknown_instance", "provider instance is not configured")
    if not delete:
        secret = args.get("secret")
        try:
            valid = (
                isinstance(secret, str)
                and bool(secret)
                and secret == secret.strip()
                and len(secret.encode("utf-8")) <= 64 * 1024
                and not any(unicodedata.category(char) in ("Cc", "Cf", "Zl", "Zp") for char in secret)
            )
        except Exception:
            valid = False
        if not valid:
            raise CommandError("invalid_args", "secret must be a nonempty single line of at most 64 KiB")
        if validate is not None:
            validate(secret)
    result = {"provider": provider, "instance": instance, "account": account}
    try:
        if not delete:
            if instance == "default":
                credentials.set(provider, account, secret)
            else:
                credentials.set_for_instance(key, account, secret)
            return {**result, "available": True}
        before = (
            credentials.get(provider, account) if instance == "default" else credentials.get_for_instance(key, account)
        )
        if not before.available and before.reason != "credential_not_found":
            raise RuntimeError
        removed = (
            credentials.delete(provider, account)
            if instance == "default"
            else credentials.delete_for_instance(key, account)
        )
        after = (
            credentials.get(provider, account) if instance == "default" else credentials.get_for_instance(key, account)
        )
        if after.available or after.reason != "credential_not_found":
            raise RuntimeError
        return {**result, "available": False, "removed": bool(removed)}
    except Exception:
        raise CommandError("credential_unavailable", "provider credential storage is unavailable") from None
