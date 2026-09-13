import json

from jrbar.accessibility_display import AccessibilityDisplayPreferences
from jrbar.dnd_policy import DisplayAdmission
from jrbar.scenes import (
    DEFAULT_SCENE,
    SCENE_POLICIES,
    DeviceSelection,
    MotionLevel,
    NotificationMode,
    Scene,
    ScenePolicy,
    SurfaceRole,
    effective_policy_for_scene,
    policy_for_scene,
    scene_from_value,
    scene_options,
)
from jrbar.settings import AgentMonitorSettings, load_settings, save_settings


def test_all_scenes_have_bounded_policies__and_2_more() -> None:
    # --- scenario: all_scenes_have_bounded_policies
    assert set(SCENE_POLICIES) == set(Scene)
    for policy in SCENE_POLICIES.values():
        assert 0.0 <= policy.brightness <= 1.0
        assert isinstance(policy.display_admission, DisplayAdmission)

    # --- scenario: scene_parsing_fails_closed
    assert scene_from_value("focus") is Scene.FOCUS
    assert scene_from_value("unknown") is None
    assert scene_from_value(None) is None
    assert policy_for_scene("unknown") is None
    assert policy_for_scene("focus", reduce_motion="yes") is None

    # --- scenario: reduce_motion_changes_effective_motion_without_mutating_policy
    policy = policy_for_scene(Scene.DEMO, reduce_motion=True)
    assert policy is not None
    assert policy.motion is MotionLevel.FULL
    assert policy.effective_motion is MotionLevel.STATIC
    assert policy_for_scene(Scene.DEMO).effective_motion is MotionLevel.FULL



def test_effective_policy_consumes_existing_accessibility_snapshot__and_2_more() -> None:
    # --- scenario: effective_policy_consumes_existing_accessibility_snapshot
    preferences = AccessibilityDisplayPreferences(reduce_motion=True)

    policy = effective_policy_for_scene(
        Scene.DEMO,
        accessibility_preferences=preferences,
    )

    assert policy is not None
    assert policy.motion is MotionLevel.FULL
    assert policy.effective_motion is MotionLevel.STATIC

    # --- scenario: scene_semantics
    assert policy_for_scene(Scene.NIGHT).notifications is NotificationMode.NONE
    assert policy_for_scene(Scene.DND).device_selection is DeviceSelection.NONE
    assert policy_for_scene(Scene.CALM).surface_role is SurfaceRole.AMBIENT

    # --- scenario: options_are_stable_and_complete
    assert scene_options() == tuple(Scene)



def test_settings_persist_active_scene_and_apply_accessibility_snapshot(tmp_path):
    path = tmp_path / "settings.json"
    settings = AgentMonitorSettings().with_active_scene(Scene.DEMO)

    save_settings(settings, path)
    loaded = load_settings(path)

    assert loaded.active_scene == Scene.DEMO.value
    assert loaded.to_dict()["active_scene"] == Scene.DEMO.value
    policy = loaded.effective_scene_policy(
        AccessibilityDisplayPreferences(reduce_motion=True)
    )
    assert policy is not None
    assert policy.scene is Scene.DEMO
    assert policy.effective_motion is MotionLevel.STATIC


def test_settings_default_scene_is_backward_compatible_for_missing_or_bad_values(
    tmp_path,
):
    missing_path = tmp_path / "missing-scene.json"
    missing_path.write_text('{"settings_schema_version": 2}\n')
    invalid_path = tmp_path / "invalid-scene.json"
    invalid_path.write_text(
        json.dumps({"settings_schema_version": 2, "active_scene": "unknown"})
    )

    assert load_settings(missing_path).active_scene == DEFAULT_SCENE.value
    assert load_settings(invalid_path).active_scene == DEFAULT_SCENE.value


def _pack_row(scene: Scene, **fields) -> ScenePolicy:
    base = SCENE_POLICIES[scene]
    values = {
        field: getattr(base, field) for field in base.__dataclass_fields__
    }
    values.update(fields)
    return ScenePolicy(**values)


def test_policy_for_scene_merges_pack_overrides_over_the_base_policy__and_2_more() -> None:
    # --- scenario: policy_for_scene_merges_pack_overrides_over_the_base_policy
    overrides = {
        Scene.CALM: _pack_row(
            Scene.CALM,
            brightness=0.9,
            motion=MotionLevel.FULL,
            display_admission=DisplayAdmission.ALL,
        )
    }

    policy = policy_for_scene(Scene.CALM, overrides=overrides)

    assert policy is not None
    assert policy.brightness == 0.9
    assert policy.motion is MotionLevel.FULL
    assert policy.display_admission is DisplayAdmission.ALL
    # Fields the row does not restate come from the base policy.
    assert policy.surface_role is SurfaceRole.AMBIENT
    assert policy.notifications is NotificationMode.IMPORTANT
    assert policy.device_selection is DeviceSelection.ACTIVE
    # The scene identity is the caller's scene, never the row's.
    mismatched = policy_for_scene(
        Scene.NIGHT, overrides={Scene.NIGHT: _pack_row(Scene.DEMO, brightness=0.9)}
    )
    assert mismatched is not None
    assert mismatched.scene is Scene.NIGHT
    assert mismatched.brightness == 0.9
    # A scene the pack does not name keeps the built-in policy.
    assert policy_for_scene(Scene.NIGHT, overrides=overrides) == policy_for_scene(
        Scene.NIGHT
    )
    # reduce_motion is a runtime input, not pack data.
    reduced = policy_for_scene(
        Scene.CALM, reduce_motion=True, overrides=overrides
    )
    assert reduced is not None and reduced.reduce_motion is True

    # --- scenario: policy_for_scene_override_rows_fail_closed_to_the_base_policy
    base = policy_for_scene(Scene.FOCUS)

    assert policy_for_scene(Scene.FOCUS, overrides=object()) == base
    assert policy_for_scene(Scene.FOCUS, overrides={Scene.FOCUS: object()}) == base
    # A mapping row names only the fields it overrides; a field carrying
    # the wrong type discards the whole row rather than half-apply it.
    partial = policy_for_scene(
        Scene.FOCUS,
        overrides={Scene.FOCUS: {"brightness": 0.5}},
    )
    assert partial is not None
    assert partial.brightness == 0.5
    assert partial.motion is base.motion
    assert (
        policy_for_scene(
            Scene.FOCUS,
            overrides={Scene.FOCUS: {"brightness": "blinding"}},
        )
        == base
    )
    assert (
        policy_for_scene(
            Scene.FOCUS,
            overrides={Scene.FOCUS: {"brightness": 2.0}},
        )
        == base
    )

    # --- scenario: effective_policy_for_scene_forwards_pack_overrides
    overrides = {Scene.DEMO: _pack_row(Scene.DEMO, brightness=0.1)}

    policy = effective_policy_for_scene(Scene.DEMO, overrides=overrides)

    assert policy is not None
    assert policy.brightness == 0.1
    assert policy.reduce_motion is False



def test_settings_resolve_the_selected_scene_through_the_active_pack(
    monkeypatch,
):
    import jrbar.scene_pack_store as store_module

    monkeypatch.setattr(
        store_module.ScenePackStore,
        "policy_overrides",
        lambda _self, pack_id: (
            {Scene.CALM: _pack_row(Scene.CALM, brightness=0.9)}
            if pack_id == "quiet-work"
            else None
        ),
    )

    settings = (
        AgentMonitorSettings()
        .with_active_scene("calm")
        .with_active_scene_pack("quiet-work")
    )
    policy = settings.effective_scene_policy()
    assert policy is not None and policy.brightness == 0.9

    # An uninstalled or unreadable pack id fails closed to built-ins.
    fallback = settings.with_active_scene_pack("missing").effective_scene_policy()
    assert fallback is not None
    assert fallback.brightness == SCENE_POLICIES[Scene.CALM].brightness
