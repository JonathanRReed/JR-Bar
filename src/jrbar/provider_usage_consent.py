"""The person's consent to each provider's usage read.

A provider's quota read either asks that provider's servers for a number, or
reads a sign-in another app keeps (a Keychain item, an auth file, a browser
session). Both are off until the person turns that provider on, one provider
at a time. What stays on without asking is local: counting tokens in files on
this Mac, hook data, and Claude Code's own status line file.

This module owns three things:

* the plain-words disclosure for each provider (what is asked, of whom, with
  which sign-in), shown verbatim in Setup, Settings and the docs;
* the gate that keeps a provider's collector from running without consent,
  and the honest "usage off" state it leaves behind;
* the one-time migration that keeps what already works working.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path

from .provider_usage_platform import (
    USAGE_OFF_REASON,
    USAGE_OFF_WORDS,
    ProviderSourceState,
    ProviderUsageSnapshot,
    provider_descriptor,
)
from .provider_usage_settings import (
    USAGE_CONSENT_MIGRATION_VERSION,
    USAGE_CONSENT_VERSION,
    ProviderPreference,
    ProviderUsageSettingsError,
    ProviderUsageSettingsWriteRefusedError,
    load_provider_usage_settings,
    save_provider_usage_settings,
)


@dataclass(frozen=True, slots=True)
class UsageDisclosure:
    """What turning one provider's usage on lets JR-Bar do."""

    provider_id: str
    label: str
    #: The Setup question, e.g. "Show Claude usage?".
    question: str
    #: Who is asked, as hosts (an empty tuple: nothing leaves the Mac).
    hosts: tuple[str, ...]
    #: Whose sign-in the request carries, in plain words.
    credential: str
    #: The one sentence Setup shows under the question.
    summary: str
    #: The one line Settings shows under the switch.
    detail: str


def _disclosure(
    provider_id: str,
    *,
    hosts: tuple[str, ...],
    credential: str,
    summary: str,
    detail: str,
) -> UsageDisclosure:
    label = provider_descriptor(provider_id).label
    return UsageDisclosure(
        provider_id=provider_id,
        label=label,
        question=f"Show {label} usage?",
        hosts=hosts,
        credential=credential,
        summary=summary,
        detail=detail,
    )


_DISCLOSURES: dict[str, UsageDisclosure] = {
    item.provider_id: item
    for item in (
        _disclosure(
            "kiro",
            hosts=("codewhisperer.us-east-1.amazonaws.com", "q.eu-central-1.amazonaws.com"),
            credential="the existing Kiro CLI sign-in and profile in its local SQLite database",
            summary="JR-Bar will ask Kiro's regional AWS endpoint for account allowances with your CLI sign-in and profile ARN. Nothing else is sent.",
            detail=("Reads the Kiro CLI database without changing its credentials. Sends its access token and profile ARN "
                    "to codewhisperer.us-east-1.amazonaws.com or q.eu-central-1.amazonaws.com, as selected by that profile. "
                    "JR-Bar never refreshes the token or runs a chat. Bonus and trial spend cannot be separated by this API."),
        ),
        _disclosure(
            "kimi",
            hosts=("api.kimi.com", "api.kimi.ai", "www.kimi.com", "www.kimi.ai"),
            credential="your saved Kimi Code key, connected web session or existing Kimi CLI sign-in",
            summary="JR-Bar will ask Kimi for your Code allowance with the sign-in you connect. Nothing else is sent.",
            detail=("Reads Kimi Code windows from api.kimi.com or api.kimi.ai with your saved key or CLI sign-in. "
                    "Saved web sessions use www.kimi.com or www.kimi.ai."),
        ),
        _disclosure(
            "kilo",
            hosts=("app.kilo.ai",),
            credential="your existing Kilo CLI sign-in or a saved Kilo key",
            summary="JR-Bar will ask Kilo for your credits and plan allowances with your sign-in. Nothing else is sent.",
            detail="Asks app.kilo.ai for account usage with the existing CLI sign-in or saved key. Usage stays off until you enable it.",
        ),
        _disclosure(
            "codex",
            hosts=("chatgpt.com",),
            credential="the sign-in Codex already has (~/.codex/auth.json)",
            summary=(
                "JR-Bar will ask OpenAI for your Codex limits, by running "
                "Codex's own app server with the sign-in Codex already has. "
                "Nothing else is sent."
            ),
            detail=(
                "Runs `codex app-server`, which asks chatgpt.com for your "
                "Codex limits with Codex's own sign-in. Nothing else is sent."
            ),
        ),
        _disclosure(
            "claude",
            hosts=("api.anthropic.com",),
            credential="the sign-in Claude Code already has (its Keychain item)",
            summary=(
                "JR-Bar will ask Anthropic for your usage with the sign-in "
                "Claude Code already has. Nothing else is sent."
            ),
            detail=(
                "Asks api.anthropic.com for your 5-hour and weekly windows "
                "with the sign-in Claude Code keeps in your Keychain. "
                "Nothing else is sent."
            ),
        ),
        _disclosure(
            "cursor",
            hosts=("cursor.com",),
            credential="the sign-in Cursor already has (read from Cursor's own database)",
            summary=(
                "JR-Bar will ask Cursor for your plan usage with the sign-in "
                "the Cursor app already has. Nothing else is sent."
            ),
            detail=(
                "Asks cursor.com for your plan usage with the sign-in read "
                "from Cursor's own local database, or a browser session you "
                "imported. Nothing else is sent."
            ),
        ),
        _disclosure(
            "devin",
            hosts=("app.devin.ai",),
            credential="a Devin token you gave JR-Bar, or a browser session you approved",
            summary=(
                "JR-Bar will ask Devin for your daily and weekly quota with "
                "the token you gave it. Nothing else is sent."
            ),
            detail=(
                "Asks app.devin.ai for your quota with a token kept in "
                "JR-Bar's Keychain item or a browser session you approved. "
                "Nothing else is sent."
            ),
        ),
        _disclosure(
            "grok",
            hosts=("cli-chat-proxy.grok.com",),
            credential="the sign-in the Grok CLI already has (~/.grok/auth.json)",
            summary=(
                "JR-Bar will ask Grok for your credit usage with the sign-in "
                "the Grok CLI already has. Nothing else is sent."
            ),
            detail=(
                "Asks cli-chat-proxy.grok.com for your credits with the "
                "sign-in in ~/.grok/auth.json. Nothing else is sent."
            ),
        ),
        _disclosure(
            "gemini",
            hosts=("cloudcode-pa.googleapis.com", "oauth2.googleapis.com"),
            credential="the sign-in the Gemini CLI already has (~/.gemini/oauth_creds.json)",
            summary=(
                "JR-Bar will ask Google for your Gemini quota with the "
                "sign-in the Gemini CLI already has. Nothing else is sent."
            ),
            detail=(
                "Asks cloudcode-pa.googleapis.com for your quota, and "
                "oauth2.googleapis.com to renew the token in memory, with "
                "the sign-in in ~/.gemini/oauth_creds.json. Nothing else is sent."
            ),
        ),
        _disclosure(
            "antigravity",
            hosts=(),
            credential=("the local token of the running Antigravity app and the Gemini sign-in's email"),
            summary=(
                "JR-Bar will ask the Antigravity app running on this Mac for its reported quota. "
                "Nothing else is sent."
            ),
            detail=(
                "Reads the running Antigravity app's local port and token "
                "from the process list, then asks it on 127.0.0.1 without "
                "forcing a backend refresh. Antigravity manages its own quota cache."
            ),
        ),
        _disclosure(
            "opencode",
            hosts=("opencode.ai",),
            credential="your OpenCode Go key (OpenCode's auth.json or OPENCODE_API_KEY)",
            summary=(
                "JR-Bar will ask OpenCode for your Go plan limits with your "
                "OpenCode Go key. This only matters if you have a Go "
                "subscription. Nothing else is sent."
            ),
            detail=(
                "Asks opencode.ai for your Go plan limits with the OpenCode "
                "Go key in OpenCode's auth.json or OPENCODE_API_KEY. Token "
                "totals from OpenCode's database stay local either way."
            ),
        ),
        _disclosure(
            "factory",
            hosts=("api.factory.ai", "api.workos.com"),
            credential="your explicitly connected Factory browser session or optional API key in JR-Bar Keychain",
            summary=(
                "JR-Bar will ask Factory for your subscription usage limits "
                "with the browser session or API key you connect. Browser session renewal sends its refresh token to WorkOS only after you explicitly permit it. Nothing else is sent."
            ),
            detail=(
                "Asks api.factory.ai for Standard and Core usage windows "
                "with your saved browser session or optional API key. If you explicitly connect a browser session, api.workos.com renews its tokens. Browser storage is read only when you choose Import."
            ),
        ),
        _disclosure(
            "openai-api",
            hosts=("api.openai.com",),
            credential="the Admin key you gave JR-Bar (kept in its Keychain item)",
            summary=(
                "JR-Bar will ask OpenAI for your organization's API spend "
                "with the Admin key you gave it. Nothing else is sent."
            ),
            detail=(
                "Asks api.openai.com for 30 days of usage and cost with the "
                "Admin key kept in JR-Bar's Keychain item. Nothing else is sent."
            ),
        ),
    )
}


def usage_disclosure(provider_id: str) -> UsageDisclosure:
    try:
        return _DISCLOSURES[provider_id]
    except KeyError:
        raise ValueError(f"unsupported native provider: {provider_id}") from None


def usage_disclosures() -> tuple[UsageDisclosure, ...]:
    return tuple(_DISCLOSURES.values())


def usage_consented(preference: object) -> bool:
    """Whether the saved consent covers this build's usage read."""
    version = getattr(preference, "usage_consent_version", 0)
    return type(version) is int and version >= USAGE_CONSENT_VERSION


def usage_off_snapshot(
    provider_id: str,
    *,
    observed_at: float,
    source_instance_id: str = "default",
    input_tokens: int = 0,
    cached_input_tokens: int = 0,
    output_tokens: int = 0,
    model_count: int = 0,
    estimated_cost_usd: float | None = None,
    cache_savings_usd: float | None = None,
) -> ProviderUsageSnapshot:
    """The honest state of a provider whose usage read is off: no lane, an
    action that says how to turn it on, and any token totals counted from
    files on this Mac."""
    label = provider_descriptor(provider_id).label
    return ProviderUsageSnapshot(
        provider_id=provider_id,
        account_label=None,
        observed_at=observed_at,
        state=ProviderSourceState.NEEDS_CONSENT,
        reason_code=USAGE_OFF_REASON,
        action_label=f"Turn on {label} usage",
        lanes=(),
        input_tokens=input_tokens,
        cached_input_tokens=cached_input_tokens,
        output_tokens=output_tokens,
        model_count=model_count,
        estimated_cost_usd=estimated_cost_usd,
        cache_savings_usd=cache_savings_usd,
        credits_remaining=None,
        incident=None,
        source_instance_id=source_instance_id,
    )


def is_usage_off(snapshot: object) -> bool:
    return getattr(snapshot, "reason_code", None) == USAGE_OFF_REASON


def _with_local_totals(
    snapshot: ProviderUsageSnapshot,
    local: ProviderUsageSnapshot,
) -> ProviderUsageSnapshot:
    return replace(
        snapshot,
        input_tokens=local.input_tokens,
        cached_input_tokens=local.cached_input_tokens,
        output_tokens=local.output_tokens,
        model_count=local.model_count,
        estimated_cost_usd=local.estimated_cost_usd,
        cache_savings_usd=local.cache_savings_usd,
    )


# ---------------------------------------------------------------------------
# The gate.


class ConsentGatedCollector:
    """A collector that only makes its request, or reads its sign-in, once the
    person has turned the provider on.

    Without consent it runs ``local_only`` instead, which is handed no
    credential store and no transport, so it cannot ask anyone or read a
    sign-in even by mistake. ``requires_usage_consent`` tells the refresh
    loop not to touch the provider's credential sources either.
    """

    requires_usage_consent = True

    def __init__(
        self,
        provider_id: str,
        granted: Callable[[object, Path, float, object], ProviderUsageSnapshot],
        local_only: Callable[[object, Path, float], ProviderUsageSnapshot] | None = None,
    ) -> None:
        self.provider_id = provider_id
        self._granted = granted
        self._local_only = local_only

    def __call__(
        self,
        preference: object,
        home: Path,
        observed_at: float,
        credentials: object,
    ) -> ProviderUsageSnapshot:
        if usage_consented(preference):
            return self._granted(preference, home, observed_at, credentials)
        return self.off(preference, home, observed_at)

    def off(
        self,
        preference: object,
        home: Path,
        observed_at: float,
    ) -> ProviderUsageSnapshot:
        instance = getattr(preference, "source_instance_id", "default")
        if self._local_only is not None:
            snapshot = self._local_only(preference, Path(home), observed_at)
            if self.provider_id in {"claude", "codex"} and instance != "default":
                # These local counters cover provider homes, not this account.
                snapshot = replace(
                    snapshot, input_tokens=0, cached_input_tokens=0,
                    output_tokens=0, model_count=0,
                    estimated_cost_usd=None, cache_savings_usd=None,
                )
            if snapshot.lanes:
                # A local reading (Codex's rollouts, Claude Code's status
                # line) is real and stays: nothing left the Mac to get it.
                return snapshot
            return _with_local_totals(
                usage_off_snapshot(
                    self.provider_id,
                    observed_at=observed_at,
                    source_instance_id=instance,
                ),
                snapshot,
            )
        return usage_off_snapshot(
            self.provider_id,
            observed_at=observed_at,
            source_instance_id=instance,
        )


def consent_gated_collectors(
    *,
    live_probe: Callable[[], dict | None] | None = None,
    http_json: Callable[..., object] | None = None,
) -> dict[str, ConsentGatedCollector]:
    """Every shipped collector, each behind its provider's consent.

    ``live_probe`` and ``http_json`` are the Codex probe and the HTTP
    transport; tests hand in ones that fail on any call.
    """
    from .provider_usage_codex_claude import (
        collect_claude,
        collect_claude_local_only,
        collect_codex,
        collect_codex_local_only,
    )
    from .provider_usage_collectors import (
        collect_antigravity,
        collect_cursor,
        collect_devin,
        collect_gemini,
        collect_grok,
        collect_openai_api,
        collect_opencode,
        collect_opencode_local_only,
    )
    from .provider_usage_factory import collect_factory
    from .provider_usage_kilo import collect_kilo
    from .provider_usage_kimi import collect_kimi
    from .provider_usage_kiro import collect_kiro

    if live_probe is None:
        from .provider_reconnect import codex_app_server_probe

        live_probe = codex_app_server_probe
    transport = {} if http_json is None else {"http_json": http_json}

    return {
        "codex": ConsentGatedCollector(
            "codex",
            lambda preference, home, observed, credentials: collect_codex(
                preference,
                home=home,
                observed_at=observed,
                live_probe=live_probe,
            ),
            lambda preference, home, observed: collect_codex_local_only(preference, home=home, observed_at=observed),
        ),
        "claude": ConsentGatedCollector(
            "claude",
            lambda preference, home, observed, credentials: collect_claude(
                preference,
                home=home,
                observed_at=observed,
                credentials=credentials,
            ),
            lambda preference, home, observed: collect_claude_local_only(preference, home=home, observed_at=observed),
        ),
        "cursor": ConsentGatedCollector(
            "cursor",
            lambda preference, home, observed, credentials: collect_cursor(
                preference,
                home=home,
                observed_at=observed,
                credentials=credentials,
                **transport,
            ),
        ),
        "devin": ConsentGatedCollector(
            "devin",
            lambda preference, home, observed, credentials: collect_devin(
                preference,
                observed_at=observed,
                credentials=credentials,
                **transport,
            ),
        ),
        "grok": ConsentGatedCollector(
            "grok",
            lambda preference, home, observed, credentials: collect_grok(
                preference,
                home=home,
                observed_at=observed,
                credentials=credentials,
                **transport,
            ),
        ),
        "gemini": ConsentGatedCollector(
            "gemini",
            lambda preference, home, observed, credentials: collect_gemini(
                preference,
                home=home,
                observed_at=observed,
                credentials=credentials,
                **transport,
            ),
        ),
        "antigravity": ConsentGatedCollector(
            "antigravity",
            lambda preference, home, observed, credentials: collect_antigravity(
                preference,
                observed_at=observed,
                home=home,
                **transport,
            ),
        ),
        "opencode": ConsentGatedCollector(
            "opencode",
            lambda preference, home, observed, credentials: collect_opencode(
                preference,
                observed_at=observed,
                home=home,
                **transport,
            ),
            lambda preference, home, observed: collect_opencode_local_only(preference, observed_at=observed, home=home),
        ),
        "factory": ConsentGatedCollector(
            "factory",
            lambda preference, home, observed, credentials: collect_factory(
                preference,
                observed_at=observed,
                credentials=credentials,
                **transport,
            ),
        ),
        "openai-api": ConsentGatedCollector(
            "openai-api",
            lambda preference, home, observed, credentials: collect_openai_api(
                preference,
                observed_at=observed,
                credentials=credentials,
                **transport,
            ),
        ),
        "kimi": ConsentGatedCollector(
            "kimi",
            lambda preference, home, observed, credentials: collect_kimi(
                preference, home=home, observed_at=observed, credentials=credentials, **transport,
            ),
        ),
        "kilo": ConsentGatedCollector(
            "kilo",
            lambda preference, home, observed, credentials: collect_kilo(
                preference, home=home, observed_at=observed, credentials=credentials, **transport,
            ),
        ),
        "kiro": ConsentGatedCollector(
            "kiro",
            lambda preference, home, observed, credentials: collect_kiro(
                preference, home=home, observed_at=observed, **transport,
            ),
        ),
    }


def overlay_usage_off(
    snapshot: ProviderUsageSnapshot,
    preference: object,
) -> ProviderUsageSnapshot:
    """A saved reading of a provider whose usage is off is not shown.

    Used where a reading comes back from disk (a restart, `jrbar providers
    status`) rather than from a collector: a reading that came from a
    gated source must not outlive the consent that allowed it. A reading
    from a local source (Codex's rollouts, Claude Code's status line) stays,
    and so do the token totals counted from files on this Mac.
    """
    if usage_consented(preference) or is_usage_off(snapshot) or snapshot.state is ProviderSourceState.DISABLED:
        return snapshot
    if snapshot.lanes and all(lane.source_id in LOCAL_LANE_SOURCES for lane in snapshot.lanes):
        return snapshot
    off = usage_off_snapshot(
        snapshot.provider_id,
        observed_at=snapshot.observed_at,
        source_instance_id=snapshot.source_instance_id,
    )
    if snapshot.provider_id in LOCAL_ONLY_PROVIDERS:
        return _with_local_totals(off, snapshot)
    return off


# ---------------------------------------------------------------------------
# What counts as already working, for the migration.

#: Lane sources that are read from files on this Mac and need no consent.
LOCAL_LANE_SOURCES = frozenset({"codex-rollouts", "claude-statusline", "claude-transcripts", "opencode-db"})

#: Providers that keep local figures (token totals, a local reading) with
#: usage off.
LOCAL_ONLY_PROVIDERS = frozenset({"codex", "claude", "opencode"})


def reading_came_from_consented_source(snapshot: ProviderUsageSnapshot) -> bool:
    """Whether a saved snapshot is a successful reading that used a gated
    source: one that asked a provider, or read a sign-in, to get its numbers.

    Local readings (Codex's rollouts, Claude Code's status line) and bare
    token totals do not count: they keep working with usage off.
    """
    if snapshot.state not in {ProviderSourceState.READY, ProviderSourceState.STALE}:
        return False
    if snapshot.provider_id in LOCAL_ONLY_PROVIDERS:
        return any(lane.source_id not in LOCAL_LANE_SOURCES for lane in snapshot.lanes)
    return True


@dataclass(frozen=True, slots=True)
class UsageConsentMigrationReport:
    ran: bool
    migrated: tuple[tuple[str, str], ...] = ()
    reason: str | None = None


def migrate_usage_consent(
    settings_path: Path | None,
    state_loader: Callable[[], object],
    *,
    log: Callable[[str], object] | None = None,
) -> UsageConsentMigrationReport:
    """Carry what already works across the upgrade that made usage opt-in.

    Runs once per settings document (a saved marker), and again does
    nothing. A provider instance is marked as consented when it is enabled
    and its last saved reading came from a gated source successfully: the
    person has been relying on it. Anything that never worked, or was never
    on, stays off. Each migrated instance gets a consent record whose source
    is ``migration`` and one log line.
    """
    emit = log or (lambda _message: None)
    loaded = load_provider_usage_settings(settings_path)
    if loaded.read_only:
        return UsageConsentMigrationReport(False, reason="settings_read_only")
    settings = loaded.settings
    if settings.usage_consent_migration >= USAGE_CONSENT_MIGRATION_VERSION:
        return UsageConsentMigrationReport(False, reason="already_ran")
    try:
        state = state_loader()
    except Exception:
        state = None
    snapshots = {snapshot.identity: snapshot for snapshot in getattr(state, "snapshots", ()) or ()}
    migrated: list[tuple[str, str]] = []
    updated = settings
    for preference in settings.providers:
        if not preference.enabled or preference.usage_consented:
            continue
        snapshot = snapshots.get(preference.identity)
        if snapshot is None or not reading_came_from_consented_source(snapshot):
            continue
        updated = updated.with_usage_consent(
            preference.provider_id,
            True,
            source="migration",
            at=None,
            source_instance_id=preference.source_instance_id,
        )
        migrated.append(preference.identity)
        emit(
            "usage consent: kept "
            f"{preference.provider_id}"
            + ("" if preference.source_instance_id == "default" else f" ({preference.source_instance_id})")
            + " on because it was enabled and already returning usage"
            f" (consent version {USAGE_CONSENT_VERSION})"
        )
    if loaded.source_revision is None and not migrated:
        # A Mac with no saved settings and nothing that worked: there is
        # nothing to carry, and nothing is written just to say so.
        return UsageConsentMigrationReport(False, reason="fresh")
    updated = updated.with_usage_consent_migration(USAGE_CONSENT_MIGRATION_VERSION)
    try:
        save_provider_usage_settings(updated, settings_path, loaded=loaded)
    except (ProviderUsageSettingsWriteRefusedError, ProviderUsageSettingsError, OSError):
        # Not saved: the next start tries again, and nothing was turned on.
        return UsageConsentMigrationReport(False, reason="not_saved")
    return UsageConsentMigrationReport(True, tuple(migrated))


# ---------------------------------------------------------------------------
# Commands.


def usage_consent_row(preference: ProviderPreference) -> dict[str, object]:
    """The `list_providers` block for one instance: the switch's state and
    the words next to it."""
    disclosure = usage_disclosure(preference.provider_id)
    return {
        "granted": preference.usage_consented,
        "version": preference.usage_consent_version,
        "source": preference.usage_consent_source,
        "at": preference.usage_consented_at,
        "required_version": USAGE_CONSENT_VERSION,
        "question": disclosure.question,
        "summary": disclosure.summary,
        "detail": disclosure.detail,
        "hosts": list(disclosure.hosts),
        "credential": disclosure.credential,
    }


__all__ = [
    "LOCAL_LANE_SOURCES",
    "USAGE_OFF_REASON",
    "USAGE_OFF_WORDS",
    "ConsentGatedCollector",
    "UsageConsentMigrationReport",
    "UsageDisclosure",
    "consent_gated_collectors",
    "is_usage_off",
    "migrate_usage_consent",
    "overlay_usage_off",
    "reading_came_from_consented_source",
    "usage_consent_row",
    "usage_consented",
    "usage_disclosure",
    "usage_disclosures",
    "usage_off_snapshot",
]
