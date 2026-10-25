"""Pure availability facts for provider rows, using the daemon's inventory."""

from __future__ import annotations

from .provider_usage_platform import provider_descriptor

GONE_READING_SECONDS = 7 * 24 * 60 * 60
_CAUSES = {
    "claude_keychain_access_lost": "Keychain access lost after Claude renewed its sign-in",
    "authentication_required": "Sign-in rejected",
    "network_unavailable": "Usage request could not connect",
    "response_timed_out": "Usage request timed out",
    "collector_failed": "Usage source failed",
    "invalid_provider_response": "Quota service returned an unreadable response",
    "rate_limited": "Usage requests rate limited",
    "reading_evidence_missing": "No fresh quota reading",
}


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
    if installed is False:
        if not measured:
            fields.update(availability="absent", panel_visible=False)
            return fields
        if age is not None and age >= GONE_READING_SECONDS:
            fields.update(availability="not_found", status_text="Not found on this Mac",
                          action="Hide", action_kind="hide")
            return fields
        fields.update(availability="missing_recent", status_text="Not found on this Mac")
    elif reason == "quota_service_not_running" or (installed is True and state == "source_not_found"):
        fields.update(availability="source_idle", status_text="Quota service is not running",
                      action=f"Open {label} to refresh", action_kind="open_app")
    elif state not in {"ready", "disabled", "unsupported"} and reason != "usage_not_turned_on":
        fields.update(availability="failing",
                      status_text=_CAUSES.get(reason, (reason or state).replace("_", " ").capitalize()))
    elif state == "ready" and any(lane.reset_at is not None and lane.reset_at <= now for lane in snapshot.lanes):
        fields.update(status_text="Quota window reset since the last reading", action="Retry")
    return fields
