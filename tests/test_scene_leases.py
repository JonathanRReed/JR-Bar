"""Automatic scenes keep synthetic manual choices intact."""
from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar import core_runtime, scene_leases
from jrbar.core_auth import COMMAND_PRIVILEGE, OPEN
from jrbar.core_projection import READ_ONLY_SETTINGS, build_settings_document
from jrbar.core_server import CommandError
from jrbar.settings import AgentMonitorSettings
from tests.test_core_runtime import headless  # noqa: F401


@pytest.fixture
def clock():
    return SimpleNamespace(mono=10.0, epoch=1000.0)


@pytest.fixture
def holder(clock):
    return scene_leases.SceneLeases(clock=lambda: clock.mono, epoch=lambda: clock.epoch)


def acquire(holder, lease_id="rule-a", scene="focus", revision=None):
    return holder.apply({"action": "acquire", "lease_id": lease_id,
                         "scene": scene, "expected_revision": revision or holder.revision}, "calm")


def release(holder, lease_id="rule-a"):
    return holder.apply({"action": "release", "lease_id": lease_id}, "calm")


def test_acquire_renew_expire_and_reacquire_leave_selected_scene(holder, clock):
    revision = holder.revision
    result = acquire(holder)
    assert result == {"status": "acquired", "revision": revision, "scene": "focus", "until": 1030.0}
    assert holder.document("calm")["selected_scene"] == "calm"
    clock.mono += 20
    clock.epoch += 20
    assert acquire(holder, revision=revision)["until"] == 1050.0
    clock.mono += 30
    clock.epoch += 30
    assert holder.effective("calm") == "calm"
    assert holder.expire()
    assert holder.document("calm")["lease_id"] is None
    assert holder.revision == revision
    assert acquire(holder, revision=revision)["scene"] == "focus"


def test_lost_reply_replay_is_idempotent_and_cannot_change_scene(holder):
    before = holder.revision
    acquire(holder, revision=before)
    assert acquire(holder, revision=before)["scene"] == "focus"
    with pytest.raises(CommandError, match="cannot change"):
        acquire(holder, scene="night", revision=before)
    assert holder.effective("calm") == "focus"


def test_manual_same_scene_and_pack_intent_supersede(holder):
    controller = SimpleNamespace(settings=AgentMonitorSettings(), _core_scene_leases=holder)
    for path in ["active_scene", "active_scene_pack"]:
        revision = holder.revision
        acquire(holder, lease_id=path)
        scene_leases.settings_changed(controller, controller.settings, controller.settings, touched=[path])
        assert holder.revision != revision
        assert scene_leases.effective_scene(controller) == "calm"
        with pytest.raises(CommandError):
            acquire(holder, lease_id=path, revision=revision)


def test_unrelated_settings_do_not_yield_but_external_changed_choice_does(holder):
    selected = AgentMonitorSettings()
    controller = SimpleNamespace(settings=selected, _core_scene_leases=holder)
    acquire(holder)
    revision = holder.revision
    scene_leases.settings_changed(controller, selected, replace(selected, alert_burst=4), touched=["alert_burst"])
    assert holder.revision == revision
    assert holder.effective("calm") == "focus"
    for candidate in [replace(selected, active_scene="night"), replace(selected, active_scene_pack="synthetic-pack")]:
        scene_leases.settings_changed(controller, selected, candidate)
        assert holder.lease_id is None


def test_releases_retire_pending_ids_without_releasing_replacement(holder):
    revision = holder.revision
    release(holder)
    assert release(holder)["revision"] == revision
    with pytest.raises(CommandError):
        acquire(holder, revision=revision)
    acquire(holder, lease_id="rule-b")
    assert release(holder)["scene"] == "focus"
    assert holder.lease_id == "rule-b"
    with pytest.raises(CommandError):
        acquire(holder, lease_id="rule-c")
    assert release(holder, "rule-b")["scene"] == "calm"
    assert acquire(holder, lease_id="rule-c")["scene"] == "focus"


def test_tombstone_eviction_invalidates_old_compare_token(holder):
    revision = holder.revision
    release(holder, "old")
    for index in range(256):
        release(holder, f"retired-{index}")
    assert len(holder.retired) == 256
    assert holder.revision != revision
    with pytest.raises(CommandError):
        acquire(holder, "old", revision=revision)


def test_restart_refuses_old_revision(holder):
    acquire(holder)
    fresh = scene_leases.SceneLeases()
    assert fresh.effective("calm") == "calm"
    with pytest.raises(CommandError):
        acquire(fresh, revision=holder.revision)


@pytest.mark.parametrize("args", [
    {}, {"action": "wrong", "lease_id": "a"},
    {"action": "release", "lease_id": ""},
    {"action": "release", "lease_id": "a" * 129},
    {"action": "release", "lease_id": "é"},
    {"action": "acquire", "lease_id": "a", "scene": "focus"},
    {"action": "acquire", "lease_id": "a", "expected_revision": "x", "scene": "bad"},
])
def test_invalid_commands(holder, args):
    with pytest.raises(CommandError) as error:
        holder.apply(args, "calm")
    assert error.value.code == "invalid_args"
    assert holder.lease_id is None


def controller_for(holder):
    published = []
    refreshes = []
    controller = SimpleNamespace(settings=AgentMonitorSettings(), _core_scene_leases=holder,
        _core_settings_generation=7, _core_publish_settings=lambda: published.append(scene_leases.scene_state(controller)),
        schedule_event_refresh=lambda: refreshes.append(True), _core_after_settings_change=lambda touched: None)
    return controller, published, refreshes


def test_command_projects_without_saving_or_changing_generation(holder):
    controller, published, refreshes = controller_for(holder)
    original = controller.settings
    result = core_runtime._cmd_scene_lease(controller, {"action": "acquire", "lease_id": "a",
        "expected_revision": holder.revision, "scene": "focus"})
    assert result["scene"] == "focus"
    assert controller.settings is original
    assert controller._core_settings_generation == 7
    assert published[-1]["selected_scene"] == "calm"
    assert published[-1]["effective_scene"] == "focus"
    assert refreshes == [True]
    assert COMMAND_PRIVILEGE["scene_lease"] == OPEN
    document = build_settings_document(original.to_dict(), generation=7, read_only={"scene_state": published[-1]})
    assert document["document"]["scene_state"] == published[-1]
    assert "scene_state" not in original.to_dict()
    assert "scene_state" in READ_ONLY_SETTINGS
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_set_setting(controller, {"path": "scene_state", "value": None})
    assert error.value.code == "read_only"


def test_accepted_same_value_write_and_reset_clear_before_publication(holder):
    controller, _, _ = controller_for(holder)
    saved = []
    controller._core_save_settings_soon = lambda: saved.append(scene_leases.scene_state(controller))
    for command, args in [
        (core_runtime._cmd_set_setting, {"path": "active_scene", "value": "calm"}),
        (core_runtime._cmd_reset_settings, {"paths": ["active_scene"]}),
        (core_runtime._cmd_set_setting, {"path": "active_scene_pack", "value": None}),
        (core_runtime._cmd_reset_settings, {"paths": ["active_scene_pack"]}),
    ]:
        acquire(holder, lease_id=str(len(saved)))
        command(controller, args)
        assert saved[-1]["lease_id"] is None
        assert saved[-1]["effective_scene"] == "calm"


def test_refused_manual_save_preserves_lease_and_settings(holder):
    controller, published, _ = controller_for(holder)
    def refuse(_settings):
        raise OSError("synthetic refusal")
    controller._core_legacy = lambda: SimpleNamespace(save_settings=refuse)
    acquire(holder)
    original = controller.settings
    revision = holder.revision
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_set_setting(controller, {"path": "active_scene", "value": "night"})
    assert error.value.code == "refused"
    assert controller.settings is original
    assert holder.revision == revision
    assert holder.effective("calm") == "focus"
    assert published == []


def test_real_controller_publishes_manual_intent_before_any_reply(headless, holder, monkeypatch):  # noqa: F811
    headless.applicationDidFinishLaunching_(None)
    headless._core_scene_leases = holder
    headless._core.published.clear()
    before = headless._core_settings_generation
    result = headless._core_dispatch("scene_lease", {"action": "acquire", "lease_id": "a",
        "expected_revision": holder.revision, "scene": "focus"})
    assert result["scene"] == "focus"
    assert headless._core_settings_generation == before
    scene = [body for kind, body in headless._core.published if kind == "settings"][-1]["document"]
    assert scene["active_scene"] == "calm"
    assert scene["scene_state"]["effective_scene"] == "focus"
    from jrbar.effect_assignment_store import EffectAssignmentCache
    monkeypatch.setattr(type(headless), "_effect_assignment_cache", EffectAssignmentCache(), raising=False)
    assert core_runtime._assignments_document(headless)["active_scene"] == "focus"
    assert core_runtime._cmd_resolve_effect(headless, {"semantic": "work"})["scene"] == "focus"
    assert core_runtime._cmd_resolve_effect(headless, {"semantic": "work", "scene": "night"})["scene"] == "night"
    headless._core_dispatch("set_setting", {"path": "active_scene", "value": "calm"})
    scene = [body for kind, body in headless._core.published if kind == "settings"][-1]["document"]
    assert scene["scene_state"]["lease_id"] is None
    assert scene["scene_state"]["effective_scene"] == "calm"
    assert headless.settings.active_scene == "calm"


def test_real_settings_setter_invalidates_external_changed_selection(headless, holder):  # noqa: F811
    headless.applicationDidFinishLaunching_(None)
    headless._core_scene_leases = holder
    acquire(holder)
    headless.settings = replace(headless.settings, active_scene="night")
    assert holder.lease_id is None
    scene = [body for kind, body in headless._core.published if kind == "settings"][-1]["document"]
    assert scene["scene_state"]["selected_scene"] == "night"
    assert scene["scene_state"]["effective_scene"] == "night"


def test_existing_refresh_expires_overlay_and_publishes_selected_scene(headless, holder, clock, monkeypatch):  # noqa: F811
    headless.applicationDidFinishLaunching_(None)
    headless._core_scene_leases = holder
    acquire(holder)
    generation = headless._core_settings_generation
    headless._core.published.clear()
    clock.mono += 31
    class StopAfterPublication(Exception):
        pass
    publish = headless._core_publish_settings
    def publish_then_stop():
        publish()
        raise StopAfterPublication
    monkeypatch.setattr(headless, "_core_publish_settings", publish_then_stop)
    # Stop before legacy refresh can inspect anything outside this fixture.
    with pytest.raises(StopAfterPublication):
        type(headless).refresh_(headless, None)
    facts = [body for kind, body in headless._core.published if kind == "settings"][-1]
    assert facts["generation"] == generation
    assert facts["document"]["scene_state"]["effective_scene"] == "calm"
    assert facts["document"]["scene_state"]["lease_id"] is None
    assert facts["document"]["scene_state"]["until"] is None
    assert holder.lease_id is None


def test_wall_clock_jump_does_not_shift_deadline_or_until(holder, clock):
    acquire(holder)
    until = holder.document("calm")["until"]
    clock.epoch += 100000
    clock.mono += 29
    assert holder.document("calm")["until"] == until
    assert holder.effective("calm") == "focus"
    assert not holder.expire()
    clock.mono += 1
    assert holder.expire()
    assert holder.effective("calm") == "calm"


def test_expired_foreign_owner_does_not_block_new_acquisition(holder, clock):
    acquire(holder)
    clock.mono += 31
    assert acquire(holder, lease_id="rule-b")["scene"] == "focus"
    assert holder.lease_id == "rule-b"
