"""Pure availability facts for provider rows, using the daemon's inventory."""

from __future__ import annotations

from .provider_usage_platform import provider_descriptor

GONE_READING_SECONDS = 7 * 24 * 60 * 60
#: Every reason a provider reading can carry, as the sentence a person
#: reads: what happened and, where there is one, the fix. ``{label}`` is the
#: provider's display name. A reason missing here reads ``ATTENTION``, never
#: the code (``tests/test_provider_availability_words.py`` scans for codes).
_CAUSES = {
    "account_identity_unavailable": "{label} did not say which account this is. Retry in a moment.",
    "authentication_required": "{label} needs you to sign in again.",
    "browser_session_not_imported": "Import a {label} browser session in Settings > Providers.",
    "browser_consent_required": "Choose a {label} browser profile in Settings > Providers and allow access.",
    "browser_refresh_consent_required": "Reconnect {label} in Settings > Providers to allow browser updates.",
    "browser_token_unavailable": "{label} sign-in data was found, but its access token is unavailable. Add a {label} API key to read usage.",
    "browser_session_expired": "The {label} browser session expired. Reconnect it in Settings > Providers.",
    "claude_keychain_access_lost": "Keychain access lost after Claude renewed its sign-in. Allow it again.",
    "cleartext_refused": "{label}'s usage address is not secure, so JR-Bar did not ask it.",
    "cli_default_account_only": "{label} usage reads only the default CLI account.",
    "cli_session_changed": "The {label} CLI sign-in changed.",
    "cli_session_unavailable": "No {label} CLI sign-in was found.",
    "cliproxy_account_signed_out": "This CLIProxy account is signed out. Sign it in again in CLIProxy.",
    "cliproxy_key_missing": "Add the CLIProxy management key in Settings > Providers.",
    "cliproxy_key_rejected": "CLIProxy rejected the management key. Check it in Settings > Providers.",
    "cliproxy_management_off": "CLIProxy's management API is off. Turn it on in CLIProxy.",
    "cliproxy_provider_refused": "CLIProxy refused to read this provider's usage.",
    "cliproxy_read_failed": "CLIProxy's usage could not be read. Retry in a moment.",
    "cliproxy_slow": "CLIProxy is answering slowly. Retry in a moment.",
    "cliproxy_unreachable": "CLIProxy is not answering. Check that it is running.",
    "cliproxy_url_not_loopback": "CLIProxy must run on this Mac. Check its address in Settings > Providers.",
    "code_assist_project_required": "{label} needs a Code Assist project before it reports usage.",
    "code_assist_tier_ineligible": "This {label} plan does not report usage.",
    "collector_failed": "{label}'s usage could not be read. Retry in a moment.",
    "collector_not_configured": "{label} has no usage source set up.",
    "credential_changed": "The {label} sign-in changed.",
    "credential_redirect_refused": "{label}'s usage address redirected elsewhere, so JR-Bar stopped.",
    "http_error": "{label}'s usage service returned an error. Retry in a moment.",
    "invalid_configuration": "{label}'s usage source is set up wrong. Check it in Settings > Providers.",
    "invalid_json": "{label}'s usage service sent a reply JR-Bar could not read.",
    "invalid_local_usage": "{label}'s local usage file could not be read.",
    "invalid_provider_response": "{label}'s usage service sent a reply JR-Bar could not read.",
    "invalid_response": "{label}'s usage service sent a reply JR-Bar could not read.",
    "invalid_url": "{label}'s usage address is not valid. Check it in Settings > Providers.",
    "invalid_web_session": "The {label} browser session is not valid. Reconnect it in Settings > Providers.",
    "local_reading_stale": "{label}'s local reading is old. It updates when {label} runs.",
    "local_usage_not_found": "No local {label} usage was found yet. It appears after {label} runs.",
    "network_error": "{label}'s usage service could not be reached. Check the network.",
    "network_unavailable": "{label}'s usage service could not be reached. Check the network.",
    "no_separable_quota": "{label} does not report a separate plan allowance.",
    "not_collected": "{label}'s usage has not been read yet.",
    "opencode_data_not_found": "No OpenCode data was found on this Mac.",
    "opencode_go_not_subscribed": "This account has no OpenCode Go subscription, so there is no quota to show.",
    "opencode_no_quota_source": "OpenCode has no quota source for this account.",
    "organization_required": "{label} needs an organization chosen in Settings > Providers.",
    "provider_identity_mismatch": "That reading belonged to another account, so JR-Bar set it aside.",
    "quota_license_required": "This {label} plan does not report a quota.",
    "quota_service_not_running": "{label}'s quota service is not running.",
    "rate_limited": "{label} is limiting usage requests. JR-Bar retries later.",
    "reading_evidence_missing": "No fresh quota reading yet.",
    "request_failed": "{label}'s usage request failed. Retry in a moment.",
    "request_rejected": "{label} rejected the usage request. Retry in a moment.",
    "response_timed_out": "{label}'s usage service did not answer in time. Retry in a moment.",
    "response_too_large": "{label}'s usage reply was too large to read.",
    "source_changed": "{label}'s usage source changed while it was read. Retry.",
    "source_unavailable": "{label}'s usage source is not available.",
    "submit_failed": "{label}'s status could not be read. Retry in a moment.",
    "sync_refresh_failed": "The synced reading could not be refreshed. Retry in a moment.",
    "token_refresh_failed": "{label}'s sign-in could not be renewed. Sign in to {label} again.",
    "unsupported_cli_auth_scope": "{label}'s CLI sign-in cannot read usage. Sign in again with usage access.",
    "usage_access_denied": "{label} did not allow this account to read usage.",
    "usage_connection_required": "Connect {label} usage in Settings > Providers.",
    "usage_consent_required": "Turn on {label} usage in Settings > Providers.",
    "usage_permission_missing": "{label}'s sign-in lacks usage access. Reconnect {label}.",
    "web_session_account_changed": "The {label} browser session is for another account. Reconnect it in Settings > Providers.",
    "web_session_changed": "The {label} browser session changed. Reconnect it in Settings > Providers.",
    "web_session_unavailable": "Connect a {label} browser session in Settings > Providers.",
}
ATTENTION = "Usage source needs attention."

#: Reasons that need a person (a sign-in or an OK), not a failing source:
#: their rows stay neutral and keep their own fix.
_NEEDS_PERSON_STATES = {"needs_consent", "needs_sign_in"}
_NEEDS_PERSON_REASONS = {
    "authentication_required", "cli_session_changed", "cli_session_unavailable", "credential_changed",
    "usage_consent_required", "usage_connection_required", "usage_permission_missing",
    "web_session_unavailable", "invalid_web_session", "web_session_changed", "web_session_account_changed",
    "browser_session_expired", "browser_session_not_imported", "browser_consent_required",
    "browser_refresh_consent_required", "browser_token_unavailable", "token_refresh_failed", "claude_keychain_access_lost",
    "cliproxy_account_signed_out", "cliproxy_key_missing", "cliproxy_key_rejected",
}

#: Reasons that say this account has no quota to read: an answer, not a
#: failure. The row reads "No quota source" with the sentence and no button;
#: Retry would only ask the same question again.
NO_QUOTA_REASONS = frozenset({
    "opencode_go_not_subscribed", "opencode_no_quota_source", "no_separable_quota",
    "quota_license_required", "code_assist_tier_ineligible", "cli_default_account_only",
})

def status_sentence(reason: str | None, label: str) -> str:
    """The plain sentence for a reason code; never the code itself."""
    template = _CAUSES.get(reason or "")
    if reason == "browser_token_unavailable" and label == "Factory":
        return "Factory no longer shares its sign-in with other apps. Add a Factory API key to read usage."
    if reason == "browser_token_unavailable" and label == "Cursor":
        return "Cursor sign-in data was found, but its access token is unavailable. Import a current session token in Settings > Providers."
    return template.format(label=label) if template else ATTENTION


def sign_in_action(provider_id: str, state: str, reason: str | None) -> tuple[str, str] | None:
    """One action contract for every provider and every sign-in/consent failure."""
    if state in {"disabled", "unsupported"} or reason in NO_QUOTA_REASONS or reason == "usage_not_turned_on":
        return None
    if state not in _NEEDS_PERSON_STATES and reason not in _NEEDS_PERSON_REASONS:
        return None
    label = provider_descriptor(provider_id).label
    if reason and reason.startswith("cliproxy_"):
        return "Reconnect CLIProxyAPI account", "manage"
    if provider_id == "claude" and reason == "claude_keychain_access_lost":
        return "Allow Claude Keychain access", "resign_in"
    if reason == "usage_consent_required":
        return f"Allow {label} usage", "manage"
    if provider_id == "cursor" and reason in {"browser_consent_required", "browser_session_not_imported"}:
        action = "Enable Cursor browser access" if reason == "browser_consent_required" else "Import Cursor browser session"
        return action, "sign_in"
    if reason == "browser_token_unavailable":
        if provider_id in {"factory", "devin"}:
            return f"Add {label} API key", "manage"
        if provider_id == "cursor":
            return "Import Cursor browser session", "sign_in"
    if provider_id == "factory" and reason == "authentication_required":
        return "Add Factory API key", "manage"
    if provider_id in {"devin", "factory"}:
        verb = "Import" if reason in {"browser_consent_required", "browser_session_not_imported"} else "Reconnect"
        return f"{verb} {label} browser session", "manage"
    if state == "needs_consent" or provider_id in {"kimi", "kilo", "cliproxy"}:
        return f"Connect {label}", "manage"
    return f"Sign in to {label}", "sign_in"


def availability_document(snapshot, *, now: float, installed: bool | None, hidden: bool = False) -> dict:
    state = getattr(snapshot.state, "value", snapshot.state)
    reason = snapshot.reason_code
    label = provider_descriptor(snapshot.provider_id).label
    measured = bool(snapshot.lanes or snapshot.input_tokens or snapshot.output_tokens
                    or snapshot.cached_input_tokens or snapshot.credits_remaining is not None)
    age = max(0.0, now - snapshot.effective_read_at) if measured else None
    fields = {"availability": "available", "status_text": None,
              "last_good_age_seconds": age, "panel_visible": not hidden, "action_kind": None}
    # A named account or hub does not depend on a local executable.
    if snapshot.source_instance_id != "default":
        installed = None
    if state == "ready" and measured:
        # A live quota answer is stronger evidence than a local app marker.
        installed = None
    person_action = sign_in_action(snapshot.provider_id, state, reason)
    # A browser-backed or remote account can need sign-in without a local CLI.
    if person_action is not None:
        installed = None
    if installed is False:
        if not measured:
            fields.update(availability="absent", panel_visible=False)
            return fields
        if age is not None and age >= GONE_READING_SECONDS:
            fields.update(availability="not_found", status_text="Not found on this Mac",
                          action="Hide", action_kind="hide")
            return fields
        fields.update(availability="missing_recent", status_text="Not found on this Mac")
    elif reason == "quota_service_not_running" and snapshot.provider_id == "antigravity":
        app_backed = snapshot.action_label == "Open Antigravity"
        fields.update(availability="source_idle", status_text="Quota service is not running",
                      action=f"Open {label} to refresh" if app_backed else snapshot.action_label,
                      action_kind="open_app" if app_backed else None)
    elif reason in NO_QUOTA_REASONS:
        fields.update(status_text=status_sentence(reason, label), action=None)
        return fields
    elif state not in {"ready", "disabled", "unsupported"} and reason != "usage_not_turned_on":
        person = state in _NEEDS_PERSON_STATES or reason in _NEEDS_PERSON_REASONS
        fields.update(availability="available" if person else "failing",
                      status_text=status_sentence(reason or state, label))
    elif state == "ready" and any(lane.reset_at is not None and lane.reset_at <= now for lane in snapshot.lanes):
        fields.update(status_text="Quota window reset since the last reading", action="Retry")
    if person_action is not None:
        action, kind = person_action
        fields.update(action=action, action_kind=kind)
    elif snapshot.provider_id in {"factory", "kilo", "kimi", "kiro"} \
            and snapshot.action_label not in {None, "Retry", "Retry later"}:
        fields["action"] = None if state in {"disabled", "unsupported"} else "Retry"
        if state == "unsupported" and reason:
            fields["status_text"] = status_sentence(reason, label)
    return fields
