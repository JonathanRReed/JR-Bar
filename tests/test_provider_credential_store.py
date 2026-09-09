from __future__ import annotations

from jrbar.provider_credential_store import ProviderCredentialStore
from jrbar.provider_instances import ProviderInstanceKey


class FakeBackend:
    def __init__(self) -> None:
        self.values = {}

    def set_password(self, service, account, secret) -> None:
        self.values[(service, account)] = secret

    def get_password(self, service, account):
        return self.values.get((service, account))

    def delete_password(self, service, account) -> None:
        if (service, account) not in self.values:
            raise KeyError(account)
        del self.values[(service, account)]


def test_secret_round_trip_uses_provider_scoped_keychain_service() -> None:
    backend = FakeBackend()
    store = ProviderCredentialStore(backend=backend)

    store.set("devin", "token", "auth1_secret")
    result = store.get("devin", "token")

    assert result.secret == "auth1_secret"
    assert result.available is True
    assert ("com.jonathanreed.jrbar.provider.devin", "token") in backend.values
    assert "auth1_secret" not in repr(result)


def test_delete_is_idempotent() -> None:
    backend = FakeBackend()
    store = ProviderCredentialStore(backend=backend)

    assert store.delete("openai-api", "admin-key") is False
    store.set("openai-api", "admin-key", "sk-admin")
    assert store.delete("openai-api", "admin-key") is True
    assert store.delete("openai-api", "admin-key") is False


def test_invalid_provider_or_empty_secret_is_rejected() -> None:
    store = ProviderCredentialStore(backend=FakeBackend())
    for provider, secret in (("CodexBar", "x"), ("devin", "")):
        try:
            store.set(provider, "token", secret)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid credential accepted")


def test_same_provider_credentials_are_scoped_to_the_exact_source_instance() -> None:
    backend = FakeBackend()
    store = ProviderCredentialStore(backend=backend)
    work = ProviderInstanceKey("devin", "work")
    personal = ProviderInstanceKey("devin", "personal")

    store.set_for_instance(work, "token", "work-secret")
    store.set_for_instance(personal, "token", "personal-secret")

    assert store.get_for_instance(work, "token").secret == "work-secret"
    assert store.get_for_instance(personal, "token").secret == "personal-secret"
    assert (
        "com.jonathanreed.jrbar.provider.devin.work",
        "token",
    ) in backend.values
    assert (
        "com.jonathanreed.jrbar.provider.devin.personal",
        "token",
    ) in backend.values


def test_default_instance_credential_methods_reuse_legacy_keychain_identity() -> None:
    backend = FakeBackend()
    store = ProviderCredentialStore(backend=backend)
    default = ProviderInstanceKey("devin", "default")

    store.set("devin", "token", "legacy-secret")

    assert store.get_for_instance(default, "token").secret == "legacy-secret"


def test_read_miss_falls_back_to_the_pre_rename_service_and_copies_forward() -> None:
    backend = FakeBackend()
    backend.values[("io.sidepulse.provider.devin", "token")] = "old-secret"
    store = ProviderCredentialStore(backend=backend)

    result = store.get("devin", "token")

    assert result.available is True
    assert result.secret == "old-secret"
    # Copied forward under the current service; the old item is left alone.
    assert backend.values[("com.jonathanreed.jrbar.provider.devin", "token")] == "old-secret"
    assert backend.values[("io.sidepulse.provider.devin", "token")] == "old-secret"


def test_instance_read_miss_falls_back_to_the_pre_rename_service() -> None:
    backend = FakeBackend()
    backend.values[("io.sidepulse.provider.devin.work", "token")] = "work-secret"
    store = ProviderCredentialStore(backend=backend)

    result = store.get_for_instance(ProviderInstanceKey("devin", "work"), "token")

    assert result.secret == "work-secret"
    assert backend.values[("com.jonathanreed.jrbar.provider.devin.work", "token")] == "work-secret"


def test_current_service_wins_over_a_stale_pre_rename_item() -> None:
    backend = FakeBackend()
    backend.values[("io.sidepulse.provider.devin", "token")] = "stale"
    backend.values[("com.jonathanreed.jrbar.provider.devin", "token")] = "current"
    store = ProviderCredentialStore(backend=backend)

    assert store.get("devin", "token").secret == "current"


def test_copy_forward_failure_still_returns_the_secret() -> None:
    class ReadOnlyBackend(FakeBackend):
        def set_password(self, service, account, secret) -> None:
            raise RuntimeError("keychain is read-only")

    backend = ReadOnlyBackend()
    backend.values[("io.sidepulse.provider.devin", "token")] = "old-secret"
    store = ProviderCredentialStore(backend=backend)

    assert store.get("devin", "token").secret == "old-secret"
