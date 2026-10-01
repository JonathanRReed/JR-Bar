"""Provider usage settings and session-action rules for the retained controller.

The status-bar facade exposes selectors only. Publishing a durable settings
snapshot to the controller's consumers and resolving a profile's own
session-open choice live here, so those rules have one testable owner.
"""

from __future__ import annotations

from .provider_feature_settings import (
    ProviderInstancePolicyProjection,
    project_instance_policies,
    project_presentation_settings,
)
from .provider_usage_settings import ProviderUsageSettings
from .provider_usage_sync_cache import (
    invalidate_cached_merged_sync,
    sharing_projection_signature,
)
from .session_actions import resolve_profile_session_action_for_status


def apply_provider_usage_settings_snapshot(
    controller,
    settings: ProviderUsageSettings,
    *,
    notify_service: bool = False,
) -> None:
    """Publish one durable snapshot and its privacy-safe consumer views."""

    if type(settings) is not ProviderUsageSettings:
        raise TypeError("expected ProviderUsageSettings")
    policies = project_instance_policies(settings)
    sharing_signature = sharing_projection_signature(policies.sharing)
    previous_sharing_signature = getattr(
        controller,
        "_jrbar_provider_sync_sharing_signature",
        None,
    )
    if previous_sharing_signature != sharing_signature:
        invalidate_cached_merged_sync(sharing_signature=sharing_signature)
    controller._jrbar_provider_sync_sharing_signature = sharing_signature
    controller._jrbar_provider_usage_settings_snapshot = settings
    controller._jrbar_provider_presentation_settings = (
        project_presentation_settings(settings)
    )
    controller._jrbar_provider_instance_policies = policies
    if notify_service:
        service = getattr(controller, "_jrbar_provider_usage_service", None)
        notify = getattr(service, "note_settings_updated", None)
        if callable(notify):
            notify(settings)


def profile_session_action(controller, status, action: str | None) -> str | None:
    """Apply only an exact nondefault profile override before legacy routing."""

    if action is not None:
        return action
    policies = getattr(controller, "_jrbar_provider_instance_policies", None)
    if type(policies) is not ProviderInstancePolicyProjection:
        return None
    resolution = resolve_profile_session_action_for_status(
        policies.session_action,
        status,
    )
    return resolution.action if resolution.has_override else None


__all__ = [
    "apply_provider_usage_settings_snapshot",
    "profile_session_action",
]
