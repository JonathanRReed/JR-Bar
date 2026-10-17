from dataclasses import replace
from types import SimpleNamespace

from jrbar.activity_ledger import ActivityEntry, ActivityKind, ActivityLedger, record_activities
from jrbar.activity_ledger_store import load_activity_ledger, save_activity_ledger
from jrbar.core_projection import history_rows, usage_document
from jrbar.provider_event_identity import instance_event_label, public_event_fields
from jrbar.provider_feature_settings import project_instance_policies
from jrbar.provider_usage_settings import default_provider_usage_settings


def visual_profiles():
    settings = default_provider_usage_settings()
    default = settings.preference("claude")
    profiles = tuple(replace(item, label="Personal") if item.provider_id == "claude" else item
                     for item in settings.providers)
    settings = replace(settings, providers=(*profiles,
        replace(default, source_instance_id="work", label="Work"),
        replace(default, source_instance_id="mail", label="private@example.invalid"),
    ))
    return project_instance_policies(settings).visual


def test_public_caption_exact_alias_and_privacy_fallback():
    visual = visual_profiles()
    assert instance_event_label(visual, "claude", "work", privacy_mode=False) == "Work"
    assert instance_event_label(visual, "claude", "work", privacy_mode=True) == "Account 2"
    assert instance_event_label(visual, "claude", "mail", privacy_mode=False) == "Account 3"
    assert instance_event_label(visual, "claude", "removed", privacy_mode=False) is None
    assert instance_event_label(None, "claude", "work", privacy_mode=False) is None


def test_all_quota_events_ignore_injected_private_labels():
    controller = SimpleNamespace(_jrbar_provider_instance_policies=SimpleNamespace(visual=visual_profiles()),
                                 _jrbar_provider_presentation_settings=SimpleNamespace(privacy_mode=False))
    fields = dict(provider="claude", instance="work", label="5h", instance_label="secret@email.invalid")
    for kind in ("quota_crossed", "quota_pace", "quota_reset"):
        result = public_event_fields(controller, kind, fields)
        assert result == dict(provider="claude", instance="work", label="5h", instance_label="Work")
        controller._jrbar_provider_presentation_settings.privacy_mode = True
        assert public_event_fields(controller, kind, fields)["instance_label"] == "Account 2"
        controller._jrbar_provider_presentation_settings.privacy_mode = False
    assert "instance_label" not in public_event_fields(SimpleNamespace(), "quota_reset", fields)


def test_history_masks_stored_aliases_and_round_trips_named_identity(tmp_path):
    entries = tuple(ActivityEntry(ActivityKind.THRESHOLD_CROSSED, 100.0, "5h", "claude", detail="90%",
                                  source_instance_id=instance, instance_label="old-private@email.invalid")
                    for instance in ("default", "work"))
    ledger = record_activities(ActivityLedger(), entries)
    assert len(ledger.entries) == 2
    path = tmp_path / "synthetic-ledger.json"
    save_activity_ledger(path, ledger)
    restored = load_activity_ledger(path).ledger
    assert {entry.source_instance_id for entry in restored.entries} == {"default", "work"}
    visual = visual_profiles()
    rows = history_rows(restored, instance_visual=visual, privacy_mode=False)
    assert {row["instance_label"] for row in rows} == {"Personal", "Work"}
    masked = history_rows(restored, instance_visual=visual, privacy_mode=True)
    assert {row["instance_label"] for row in masked} == {"Account 1", "Account 2"}
    assert "old-private" not in str(masked)
    assert all("instance_label" not in row for row in history_rows(restored))


def test_usage_projects_current_privacy_without_repurposing_account_label():
    state = SimpleNamespace(snapshots=())
    assert usage_document(state, privacy_mode=True)["privacy_mode"] is True
    assert usage_document(state, privacy_mode=False)["privacy_mode"] is False
    assert "privacy_mode" not in usage_document(state)


def test_unknown_privacy_is_closed_and_control_aliases_are_not_public():
    visual = visual_profiles()
    for value in (None, "false", 0):
        controller = SimpleNamespace(
            _jrbar_provider_instance_policies=SimpleNamespace(visual=visual),
            _jrbar_provider_presentation_settings=SimpleNamespace(privacy_mode=value),
        )
        result = public_event_fields(controller, "quota_pace", {"provider": "claude", "instance": "work"})
        assert result["instance_label"] == "Account 2"
    for control in ("\x7f", "\x80"):
        changed = replace(visual, providers=tuple(
            replace(item, label="Work" + control) if item.source_instance_id == "work" else item
            for item in visual.providers
        ))
        assert instance_event_label(changed, "claude", "work", privacy_mode=False) == "Account 2"
