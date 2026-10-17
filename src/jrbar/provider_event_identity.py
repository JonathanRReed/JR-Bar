"""Configured account captions for public events, without collector identity."""

import unicodedata

from .provider_account_identity import configured_user_alias
from .provider_feature_settings import ProviderInstanceVisualProjection


def instance_event_label(
    visual: ProviderInstanceVisualProjection | None,
    provider: str,
    instance: str | None = None,
    *, privacy_mode: bool = True,
) -> str | None:
    instance = instance or "default"
    if visual is None:
        return None
    profiles = [item for item in visual.providers if item.provider_id == provider]
    policy = next((item for item in profiles if item.source_instance_id == instance), None)
    if policy is None:
        return None
    alias = configured_user_alias(provider_id=provider, source_instance_id=instance,
                                  visual_label=policy.label)
    if (alias and not privacy_mode and "@" not in alias
            and not any(unicodedata.category(character) == "Cc" for character in alias)):
        return alias
    if len(profiles) > 1:
        return f"Account {profiles.index(policy) + 1}"
    return None


def controller_event_identity(controller) -> tuple[ProviderInstanceVisualProjection | None, bool]:
    policies = getattr(controller, "_jrbar_provider_instance_policies", None)
    visual = getattr(policies, "visual", None)
    presentation = getattr(controller, "_jrbar_provider_presentation_settings", None)
    return visual, getattr(presentation, "privacy_mode", None) is not False


def public_event_fields(controller, kind: str, fields: dict) -> dict:
    if kind not in {"quota_crossed", "quota_pace", "quota_reset"}:
        return fields
    visual, privacy = controller_event_identity(controller)
    public = {key: value for key, value in fields.items() if key != "instance_label"}
    provider = fields.get("provider")
    if isinstance(provider, str):
        label = instance_event_label(visual, provider, fields.get("instance"), privacy_mode=privacy)
        if label is not None:
            public["instance_label"] = label
    return public
