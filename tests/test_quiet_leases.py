"""Synthetic quiet ownership checks. No device, provider or filesystem settings writes."""

import pytest
from test_dnd_controller import _Harness

from jrbar import core_runtime
from jrbar.core_server import CommandError
from jrbar.dnd_policy import DndMode, DndOverride
from jrbar.settings import SettingsWriteRefusedError


def override(h, mode=DndMode.MUTE, seconds=300):
    return DndOverride.for_mode(mode, created_epoch=h.now, until_epoch=h.now + seconds)


def host(h):
    class Host:
        dnd_controller = h.controller
        @property
        def settings(self):
            return h.settings
        def _core_publish_state(self):
            pass
        def _set_dnd_for_duration(self, mode, seconds):
            return h.controller.set_override(override(h, mode, seconds)).applied
        def _end_dnd_override(self):
            return h.controller.set_override(None).applied
    return Host()


def acquire(h, lease="rule", revision=None):
    return core_runtime._cmd_quiet_lease(host(h), {
        "action": "acquire", "lease_id": lease,
        "expected_revision": revision or h.controller.override_revision,
    })


def release(h, lease="rule"):
    return core_runtime._cmd_quiet_lease(host(h), {"action": "release", "lease_id": lease})


def test_baseline_unconditional_release_overwrites_new_manual_quiet():
    h = _Harness()
    h.controller.start()
    app = host(h)
    core_runtime._cmd_quiet(app, {"mode": "dnd", "seconds": 900})
    manual = override(h, DndMode.DARK, 900)
    assert h.controller.set_override(manual).applied
    core_runtime._cmd_quiet(app, {"mode": "dnd", "seconds": 0})
    assert h.settings.dnd_settings().override is None


def test_lease_restores_exact_short_deadline_and_renews():
    h = _Harness()
    h.controller.start()
    before = override(h)
    assert h.controller.set_override(before).applied
    first = acquire(h)
    assert first["status"] == "acquired"
    h.now += 280
    renewed = acquire(h, revision=first["revision"])
    assert renewed["until"] == h.now + 900
    assert release(h)["status"] == "released"
    assert h.settings.dnd_settings().override == before


@pytest.mark.parametrize("identical", [False, True])
def test_manual_edit_invalidates_lease_even_with_same_deadline(identical):
    h = _Harness()
    h.controller.start()
    first = acquire(h)
    current = h.settings.dnd_settings().override
    manual = current if identical else override(h, DndMode.DARK, 900)
    assert h.controller.set_override(manual).applied
    for action in (lambda: release(h), lambda: acquire(h, revision=first["revision"])):
        with pytest.raises(CommandError) as error:
            action()
        assert error.value.code == "conflict"
        assert h.settings.dnd_settings().override == manual


@pytest.mark.parametrize("action", ["acquire", "renew", "release"])
def test_refused_saves_preserve_revision_settings_and_ownership(action):
    h = _Harness()
    h.controller.start()
    if action != "acquire":
        acquire(h)
    before = h.settings
    revision = h.controller.override_revision
    h.save_error = SettingsWriteRefusedError
    with pytest.raises(CommandError) as error:
        release(h) if action == "release" else acquire(h)
    assert error.value.code == "refused"
    assert h.settings == before
    assert h.controller.override_revision == revision
    h.save_error = None
    result = release(h) if action == "release" else acquire(h)
    assert result["status"] == ("released" if action == "release" else "acquired")


def test_long_manual_defers_and_foreign_lease_conflicts():
    h = _Harness()
    h.controller.start()
    manual = override(h, seconds=1800)
    h.controller.set_override(manual)
    revision = h.controller.override_revision
    assert acquire(h) == {"status": "deferred", "revision": revision, "until": manual.until_epoch}
    assert h.controller.override_revision == revision
    h.now += 1000
    acquire(h)
    with pytest.raises(CommandError):
        acquire(h, "foreign")
    with pytest.raises(CommandError):
        release(h, "foreign")


def test_restart_and_external_snapshot_fail_closed():
    h = _Harness()
    h.controller.start()
    receipt = acquire(h)
    second = _Harness(settings=h.settings)
    second.controller.start()
    assert second.controller.override_revision != receipt["revision"]
    with pytest.raises(CommandError):
        release(second)
    manual = override(h, DndMode.DIM, 900)
    h.settings = h.settings.with_dnd_override(manual)
    h.controller.refresh()
    with pytest.raises(CommandError):
        release(h)
    assert h.settings.dnd_settings().override == manual


def test_expiry_and_unrelated_changes_keep_revision():
    h = _Harness()
    h.controller.start()
    receipt = acquire(h)
    h.controller.set_dim_fraction(0.4)
    assert h.controller.override_revision == receipt["revision"]
    h.now += 901
    h.controller.refresh()
    assert h.controller.override_revision == receipt["revision"]
    assert acquire(h)["status"] == "acquired"


def test_manual_cancel_rotates_even_when_already_off():
    h = _Harness()
    h.controller.start()
    first = h.controller.override_revision
    assert h.controller.set_override(None).applied
    assert h.controller.override_revision != first
    second = h.controller.override_revision
    assert h.controller.set_override(None).applied
    assert h.controller.override_revision != second


@pytest.mark.parametrize("args", [
    {"action": "acquire", "lease_id": "rule"},
    {"action": "acquire", "lease_id": "", "expected_revision": "x"},
    {"action": "acquire", "lease_id": "x" * 129, "expected_revision": "x"},
    {"action": "release", "lease_id": "é"},
    {"action": "other", "lease_id": "rule"},
])
def test_invalid_commands_do_not_write(args):
    h = _Harness()
    h.controller.start()
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_quiet_lease(host(h), args)
    assert error.value.code == "invalid_args"
    assert h.saved == []


def test_focus_revision_is_available_while_off():
    from jrbar.core_projection import focus_document

    h = _Harness()
    h.controller.start()
    focus = focus_document(h.controller.projection, override_revision=h.controller.override_revision)
    assert focus["mode"] == "off"
    assert focus["override_revision"] == h.controller.override_revision


def test_reentrant_manual_edit_during_acquire_publication_keeps_manual_ownership():
    h = _Harness()
    h.controller.start()
    manual = override(h, DndMode.DARK, 1800)
    original_publish = h.controller._on_projection
    invoked = False

    def publish(projection):
        nonlocal invoked
        original_publish(projection)
        if not invoked:
            invoked = True
            assert h.controller.set_override(manual).applied

    h.controller._on_projection = publish
    receipt = acquire(h)
    assert receipt["revision"] != h.controller.override_revision
    assert h.settings.dnd_settings().override == manual
    with pytest.raises(CommandError) as error:
        release(h)
    assert error.value.code == "conflict"
    assert h.settings.dnd_settings().override == manual


def test_refresh_exception_after_saved_acquire_keeps_releasable_identity():
    h = _Harness()
    h.controller.start()
    before = override(h)
    assert h.controller.set_override(before).applied
    original_publish = h.controller._on_projection

    def broken_publish(_projection):
        raise RuntimeError("injected projection failure after save")

    h.controller._on_projection = broken_publish
    with pytest.raises(RuntimeError, match="injected projection failure"):
        acquire(h)
    assert h.settings.dnd_settings().override.mode == DndMode.PAUSE
    h.controller._on_projection = original_publish
    assert release(h)["status"] == "released"
    assert h.settings.dnd_settings().override == before


def test_reentrant_manual_edit_during_release_keeps_exact_release_receipt():
    h = _Harness()
    h.controller.start()
    acquire(h)
    manual = override(h, DndMode.DARK, 1800)
    original_publish = h.controller._on_projection
    invoked = False

    def publish(projection):
        nonlocal invoked
        original_publish(projection)
        if not invoked:
            invoked = True
            assert h.controller.set_override(manual).applied

    h.controller._on_projection = publish
    receipt = release(h)
    assert receipt["revision"] != h.controller.override_revision
    assert receipt["until"] is None
    assert h.settings.dnd_settings().override == manual
    with pytest.raises(CommandError):
        acquire(h, revision=receipt["revision"])
    assert h.settings.dnd_settings().override == manual
