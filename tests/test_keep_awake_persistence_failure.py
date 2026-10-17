from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import core_power, core_runtime, private_io
from jrbar.core_server import CommandError
from jrbar.models import AgentMode
from tests.test_keep_awake_lease import NOW, _Clock, _controller


@pytest.fixture
def controlled(tmp_path: Path, monkeypatch):
    clock = _Clock()
    keep = _controller(clock, enabled=False, grace_seconds=0)
    keep.attach_store(tmp_path)
    published = []
    controller = SimpleNamespace(
        keep_awake=keep, _core_power_log=object(), last_snapshot=None,
        sync_keep_awake=lambda mode: keep.update(mode, now=100.0),
        _core_publish_state=lambda: published.append(keep.hold_document()),
    )
    monkeypatch.setattr(core_power.time, "time", lambda: NOW)
    return controller, clock, published


def _refuse_delete(monkeypatch, path: Path) -> None:
    original = Path.unlink

    def unlink(candidate: Path, *args, **kwargs):
        if candidate == path:
            raise PermissionError("synthetic delete refusal")
        return original(candidate, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", unlink)


def _refuse_write(monkeypatch, path: Path) -> None:
    original = private_io.atomic_private_write

    def write(candidate, *args, **kwargs):
        if Path(candidate) == path:
            raise OSError("synthetic private storage detail")
        return original(candidate, *args, **kwargs)

    monkeypatch.setattr(private_io, "atomic_private_write", write)


def _refuse_flush(*_args, **_kwargs) -> None:
    raise OSError("synthetic post-publication flush refusal")


@pytest.mark.parametrize("replacement", [False, True])
def test_failed_hold_save_is_refused_without_changing_the_previous_hold(controlled, monkeypatch, replacement: bool) -> None:
    controller, clock, published = controlled
    keep = controller.keep_awake
    if replacement:
        core_runtime._cmd_hold_awake(controller, {"indefinite": True})
    previous = keep.lease
    previous_process = keep.process
    _refuse_write(monkeypatch, keep.lease_path)
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_hold_awake(controller, {"indefinite": True, "display": True})
    assert error.value.code == "unavailable"
    assert "synthetic private storage detail" not in str(error.value)
    assert keep.lease == previous and keep.process is previous_process
    assert keep.hold_document().get("persistence_error") == "save_failed"
    assert published[-1].get("persistence_error") == "save_failed"
    fresh = _controller(clock, enabled=False, grace_seconds=0)
    fresh.attach_store(keep.lease_path.parent)
    assert fresh.lease == previous


def test_failed_lease_delete_uses_a_durable_cancellation_marker(controlled, monkeypatch) -> None:
    controller, clock, _published = controlled
    core_runtime._cmd_hold_awake(controller, {"indefinite": True})
    keep = controller.keep_awake
    _refuse_delete(monkeypatch, keep.lease_path)
    reply = core_runtime._cmd_release_awake(controller, {})
    assert reply["ended"] is True and not keep.process_running()
    assert json.loads(keep.lease_path.read_text()) is None
    assert reply["hold"].get("persistence_error") is None
    fresh = _controller(clock, enabled=False, grace_seconds=0)
    fresh.attach_store(keep.lease_path.parent)
    assert fresh.lease is None


def test_failed_delete_and_marker_still_stop_the_manual_hold_and_allow_cleanup_retry(controlled, monkeypatch) -> None:
    controller, clock, published = controlled
    core_runtime._cmd_hold_awake(controller, {"indefinite": True})
    keep = controller.keep_awake
    with monkeypatch.context() as refusal:
        _refuse_delete(refusal, keep.lease_path)
        _refuse_write(refusal, keep.lease_path)
        with pytest.raises(CommandError) as error:
            core_runtime._cmd_release_awake(controller, {})
        assert error.value.code == "unavailable"
        assert keep.lease is None and not keep.process_running()
        assert keep.hold_document().get("persistence_error") == "clear_failed"
        assert published[-1]["state"] == "off"
        assert published[-1].get("persistence_error") == "clear_failed"
        keep.set_enabled(True)
        keep.update(AgentMode.WORKING, now=101.0)
        assert keep.process_running()
        assert keep.hold_document().get("persistence_error") == "clear_failed"
        fresh = _controller(clock, enabled=False, grace_seconds=0)
        fresh.attach_store(keep.lease_path.parent)
        assert fresh.lease is not None
    reply = core_runtime._cmd_release_awake(controller, {})
    assert reply["ended"] is False and keep.lease is None
    assert reply["hold"].get("persistence_error") is None
    assert published[-1].get("persistence_error") is None
    fresh = _controller(clock, enabled=False, grace_seconds=0)
    fresh.attach_store(keep.lease_path.parent)
    assert fresh.lease is None


def test_expiry_cleanup_failure_is_reported_without_retaining_a_hold(controlled, monkeypatch) -> None:
    controller, clock, _published = controlled
    core_runtime._cmd_hold_awake(controller, {"seconds": 60})
    keep = controller.keep_awake
    with monkeypatch.context() as refusal:
        _refuse_delete(refusal, keep.lease_path)
        _refuse_write(refusal, keep.lease_path)
        clock.now += 61
        keep.update(AgentMode.IDLE_READY, now=102.0)
        assert keep.lease is None and not keep.process_running()
        assert keep.hold_document().get("persistence_error") == "clear_failed"
    assert core_runtime._cmd_release_awake(controller, {})["hold"].get("persistence_error") is None



def test_failed_new_save_cannot_hide_an_earlier_cleanup_failure(controlled, monkeypatch) -> None:
    controller, _clock, _published = controlled
    core_runtime._cmd_hold_awake(controller, {"indefinite": True})
    keep = controller.keep_awake
    with monkeypatch.context() as refusal:
        _refuse_delete(refusal, keep.lease_path)
        _refuse_write(refusal, keep.lease_path)
        with pytest.raises(CommandError):
            core_runtime._cmd_release_awake(controller, {})
        with pytest.raises(CommandError):
            core_runtime._cmd_hold_awake(controller, {"indefinite": True})
        assert keep.lease is None
        assert keep.hold_document().get("persistence_error") == "clear_failed"
    core_runtime._cmd_release_awake(controller, {})
    assert keep.hold_document().get("persistence_error") is None



@pytest.mark.parametrize("replacement", [False, True])
def test_post_publication_failure_restores_the_previous_saved_hold(controlled, monkeypatch, replacement: bool) -> None:
    controller, clock, _published = controlled
    keep = controller.keep_awake
    if replacement:
        core_runtime._cmd_hold_awake(controller, {"indefinite": True})
    previous = keep.lease
    with monkeypatch.context() as refusal:
        refusal.setattr(private_io, "_fsync_private_parent", _refuse_flush)
        with pytest.raises(CommandError):
            core_runtime._cmd_hold_awake(controller, {"indefinite": True, "display": True})
    assert keep.lease == previous
    fresh = _controller(clock, enabled=False)
    fresh.attach_store(keep.lease_path.parent)
    assert fresh.lease == previous


def test_unresolved_cold_publication_exposes_cleanup_until_it_is_retried(controlled, monkeypatch) -> None:
    controller, clock, _published = controlled
    keep = controller.keep_awake
    write = private_io.atomic_private_write
    writes = []

    def publish_then_refuse_rollback(path, *args, **kwargs):
        if Path(path) != keep.lease_path:
            return write(path, *args, **kwargs)
        writes.append(args[0])
        if len(writes) > 1:
            raise PermissionError("synthetic rollback refusal")
        with monkeypatch.context() as refusal:
            refusal.setattr(private_io, "_fsync_private_parent", _refuse_flush)
            return write(path, *args, **kwargs)

    with monkeypatch.context() as refusal:
        refusal.setattr(private_io, "atomic_private_write", publish_then_refuse_rollback)
        with pytest.raises(CommandError):
            core_runtime._cmd_hold_awake(controller, {"indefinite": True})
        assert keep.lease is None and not keep.process_running()
        assert keep.hold_document().get("persistence_error") == "clear_failed"
        fresh = _controller(clock, enabled=False)
        fresh.attach_store(keep.lease_path.parent)
        assert fresh.lease is not None
    core_runtime._cmd_release_awake(controller, {})
    assert keep.hold_document().get("persistence_error") is None
    fresh = _controller(clock, enabled=False)
    fresh.attach_store(keep.lease_path.parent)
    assert fresh.lease is None



def test_unreadable_cold_readback_keeps_cleanup_available(controlled, monkeypatch) -> None:
    controller, clock, _published = controlled
    keep = controller.keep_awake
    read = private_io.read_private_text

    def unreadable(path, *args, **kwargs):
        if Path(path) == keep.lease_path:
            raise PermissionError("synthetic readback refusal")
        return read(path, *args, **kwargs)

    with monkeypatch.context() as refusal:
        refusal.setattr(private_io, "_fsync_private_parent", _refuse_flush)
        refusal.setattr(private_io, "read_private_text", unreadable)
        with pytest.raises(CommandError):
            core_runtime._cmd_hold_awake(controller, {"indefinite": True})
        assert keep.lease is None
        assert keep.hold_document().get("persistence_error") == "clear_failed"
    core_runtime._cmd_release_awake(controller, {})
    fresh = _controller(clock, enabled=False)
    fresh.attach_store(keep.lease_path.parent)
    assert fresh.lease is None
