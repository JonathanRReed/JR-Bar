from __future__ import annotations

from datetime import datetime, timezone
from types import SimpleNamespace

import jrbar.provider_usage_controller_actions as actions
from jrbar import provider_usage_sync_cache as sync_cache
from jrbar.capacity_types import SourceKey
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import WorkIdentifier, WorkKey
from jrbar.provider_instances import ProviderInstanceKey, ProviderInstanceProfile
from jrbar.provider_usage_runtime import ProviderUsageState
from jrbar.provider_usage_settings import default_provider_usage_settings
from jrbar.provider_usage_sync import MergedProviderSync


def test_settings_snapshot_cache_projects_all_consumer_domains() -> None:
    settings = (
        default_provider_usage_settings()
        .with_profile(
            ProviderInstanceProfile(
                ProviderInstanceKey("claude", "work"),
                "Claude Work",
                open_session_action="terminal",
            )
        )
        .with_menu_flag("privacy_mode", True)
    )
    service_updates = []
    controller = SimpleNamespace(
        _jrbar_provider_usage_service=SimpleNamespace(
            note_settings_updated=service_updates.append,
        ),
    )

    actions.apply_provider_usage_settings_snapshot(
        controller,
        settings,
        notify_service=True,
    )

    assert controller._jrbar_provider_usage_settings_snapshot is settings
    assert controller._jrbar_provider_presentation_settings.provider("claude")
    assert (
        controller._jrbar_provider_instance_policies.visual.provider(
            "claude",
            "work",
        ).label
        == "Claude Work"
    )
    assert service_updates == [settings]


def test_settings_snapshot_change_invalidates_merged_sync_for_old_sharing_policy(
    monkeypatch,
) -> None:
    monkeypatch.setattr(sync_cache, "_memo", None)
    monkeypatch.setattr(sync_cache, "_memo_generation", 0)
    state = ProviderUsageState((), 1000.0, 1100.0, False)
    merged = MergedProviderSync((), (), 0, 0, 0, None, None)
    status_only = default_provider_usage_settings().with_profile(
        ProviderInstanceProfile(
            ProviderInstanceKey("codex", "default"),
            "Codex",
            remote_sharing_choice="status_only",
        )
    )
    never = status_only.with_profile(
        ProviderInstanceProfile(
            ProviderInstanceKey("codex", "default"),
            "Codex",
            remote_sharing_choice="never",
        )
    )
    controller = SimpleNamespace()
    actions.apply_provider_usage_settings_snapshot(controller, status_only)
    sync_cache.refresh_cached_merged_sync(
        state,
        loader=lambda _state: merged,
        sharing_signature=(("codex", "default", "status_only"),),
        monotonic=lambda: 100.0,
    )
    assert sync_cache.cached_merged_sync(state, monotonic=lambda: 100.0) is merged

    actions.apply_provider_usage_settings_snapshot(controller, never)

    assert sync_cache.cached_merged_sync(state, monotonic=lambda: 100.0) is None


def test_nonsharing_settings_change_preserves_fresh_merged_sync(monkeypatch) -> None:
    monkeypatch.setattr(sync_cache, "_memo", None)
    monkeypatch.setattr(sync_cache, "_memo_generation", 0)
    state = ProviderUsageState((), 1000.0, 1100.0, False)
    merged = MergedProviderSync((), (), 0, 0, 0, None, None)
    first = default_provider_usage_settings().with_profile(
        ProviderInstanceProfile(
            ProviderInstanceKey("codex", "default"),
            "Codex",
            remote_sharing_choice="status_only",
        )
    )
    renamed = first.with_profile(
        ProviderInstanceProfile(
            ProviderInstanceKey("codex", "default"),
            "Codex Personal",
            remote_sharing_choice="status_only",
        )
    )
    controller = SimpleNamespace()
    actions.apply_provider_usage_settings_snapshot(controller, first)
    sync_cache.refresh_cached_merged_sync(
        state,
        loader=lambda _state: merged,
        sharing_signature=(("codex", "default", "status_only"),),
        monotonic=lambda: 100.0,
    )

    actions.apply_provider_usage_settings_snapshot(controller, renamed)

    assert sync_cache.cached_merged_sync(state, monotonic=lambda: 100.0) is merged


def test_profile_session_action_overrides_only_an_exact_nondefault_status() -> None:
    settings = default_provider_usage_settings().with_profile(
        ProviderInstanceProfile(
            ProviderInstanceKey("claude", "work"),
            "Claude Work",
            open_session_action="terminal",
        )
    )
    controller = SimpleNamespace()
    actions.apply_provider_usage_settings_snapshot(controller, settings)
    status = AgentStatus(
        provider="claude",
        agent_id="claude:session:one",
        display_name="Claude work",
        mode=AgentMode.WORKING,
        updated_at=datetime.now(timezone.utc),
        event_name="PreToolUse",
        session_id="one",
        cwd="/tmp",
        work_key=WorkKey(
            SourceKey("claude", "hook", "work", "sessions"),
            WorkIdentifier("work:one"),
        ),
    )

    assert actions.profile_session_action(controller, status, None) == "terminal"
    assert actions.profile_session_action(controller, status, "app") == "app"
