from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar.models import AgentMode
from tests.test_core_power import _status, powered  # noqa: F401
from tests.test_core_runtime import headless  # noqa: F401


@pytest.mark.parametrize("mode", [AgentMode.WORKING, AgentMode.TOOL_RUNNING, AgentMode.WAITING_FOR_INPUT])
@pytest.mark.parametrize("stale_collection", [False, True])
def test_existing_manual_lease_does_not_finish_on_stale_pending_rows(powered, monkeypatch, mode, stale_collection):  # noqa: F811
    from jrbar import keep_awake

    monkeypatch.setattr(keep_awake, "read_low_power_mode", lambda: False)
    controller = powered
    core_runtime._cmd_hold_awake(controller, {"until_agents_idle": True, "sessions": ["claude:session:a"]})
    original = controller.keep_awake.lease
    stale = _status("claude:session:a", mode, stale=True)
    controller.last_snapshot = SimpleNamespace(statuses=() if stale_collection else (stale,),
                                               stale_statuses=(stale,) if stale_collection else ())
    controller._core.published.clear()
    controller.sync_keep_awake(AgentMode.IDLE_READY)
    assert controller.keep_awake.lease == original
    assert controller.keep_awake.process_running()
    assert controller.keep_awake.working_count == 0
    assert not any(kind == "event" and doc.get("detail") == "finished"
                   for kind, doc in controller._core.published)


@pytest.fixture
def manual_lease(powered, monkeypatch):  # noqa: F811
    from jrbar import keep_awake

    monkeypatch.setattr(keep_awake, "read_low_power_mode", lambda: False)
    core_runtime._cmd_hold_awake(powered, {"until_agents_idle": True, "sessions": ["claude:session:a"]})
    return powered


def test_stale_pending_sessions_cannot_start_a_new_lease(manual_lease):
    from jrbar.core_server import CommandError

    controller = manual_lease
    original = controller.keep_awake.lease
    controller.last_snapshot = SimpleNamespace(statuses=(), stale_statuses=(
        _status("claude:session:a", AgentMode.WORKING, stale=True),))
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_hold_awake(controller, {"until_agents_idle": True})
    assert error.value.code == "refused"
    assert controller.keep_awake.lease == original


@pytest.mark.parametrize("fresh_mode", [AgentMode.COMPLETED, AgentMode.IDLE_READY, AgentMode.ENDED_UNCONFIRMED])
def test_fresh_terminal_status_wins_over_old_pending_copy(manual_lease, fresh_mode):
    controller = manual_lease
    controller.last_snapshot = SimpleNamespace(statuses=(_status("claude:session:a", fresh_mode),),
        stale_statuses=(_status("claude:session:a", AgentMode.WORKING, stale=True),))
    controller.sync_keep_awake(AgentMode.IDLE_READY)
    assert controller.keep_awake.lease is None


def test_unrelated_stale_session_does_not_extend_finished_lease(manual_lease):
    controller = manual_lease
    controller.last_snapshot = SimpleNamespace(statuses=(_status("claude:session:a", AgentMode.COMPLETED),),
        stale_statuses=(_status("codex:session:other", AgentMode.WORKING, stale=True),))
    controller.sync_keep_awake(AgentMode.IDLE_READY)
    assert controller.keep_awake.lease is None


@pytest.mark.parametrize("mode", [AgentMode.COMPLETED, AgentMode.IDLE_READY, AgentMode.ENDED_UNCONFIRMED, AgentMode.BLOCKED_ERROR])
def test_retired_stale_rows_do_not_protect_a_lease(manual_lease, mode):
    controller = manual_lease
    controller.last_snapshot = SimpleNamespace(statuses=(), stale_statuses=(
        _status("claude:session:a", mode, stale=True),))
    controller.sync_keep_awake(AgentMode.IDLE_READY)
    assert controller.keep_awake.lease is None


def test_stale_pending_does_not_bypass_lease_deadline(manual_lease):
    controller = manual_lease
    deadline = controller.keep_awake.lease.until
    controller.last_snapshot = SimpleNamespace(statuses=(), stale_statuses=(
        _status("claude:session:a", AgentMode.WORKING, stale=True),))
    controller.keep_awake.wall_clock = lambda: deadline
    controller.sync_keep_awake(AgentMode.IDLE_READY)
    assert controller.keep_awake.lease is None
    assert controller._core_build_state()["power"]["last_release"]["reason"] == "expired"


def test_restored_agents_lease_survives_stale_first_observation(manual_lease):
    from jrbar.keep_awake import KeepAwakeController
    from tests.test_core_power import _Process

    controller = manual_lease
    original = controller.keep_awake.lease
    path = controller.keep_awake.lease_path
    controller.keep_awake.release()
    restored = KeepAwakeController(process_factory=_Process, watch_current_process=False)
    restored.attach_store(path.parent, power_log=controller._core_power_log)
    controller.keep_awake = restored
    assert restored.lease == original
    controller.last_snapshot = SimpleNamespace(statuses=(), stale_statuses=(
        _status("claude:session:a", AgentMode.WAITING_FOR_INPUT, stale=True),))
    controller.sync_keep_awake(AgentMode.IDLE_READY)
    assert restored.lease == original
    assert restored.process_running()


def test_stale_subagent_cannot_protect_a_main_session_lease(manual_lease):
    controller = manual_lease
    controller.last_snapshot = SimpleNamespace(statuses=(), stale_statuses=(
        _status("claude:session:a", AgentMode.WORKING, stale=True, subagent=True),))
    controller.sync_keep_awake(AgentMode.IDLE_READY)
    assert controller.keep_awake.lease is None


def test_stale_long_task_keeps_only_the_existing_lease(manual_lease):
    controller = manual_lease
    original = controller.keep_awake.lease
    controller.last_snapshot = SimpleNamespace(statuses=(), stale_statuses=(
        _status("claude:session:a", AgentMode.LONG_TASK_PROGRESS, stale=True),))
    controller.sync_keep_awake(AgentMode.IDLE_READY)
    assert controller.keep_awake.lease == original
    assert controller.keep_awake.working_count == 0


def test_unknown_empty_observation_does_not_finish_existing_lease(manual_lease):
    controller = manual_lease
    original = controller.keep_awake.lease
    controller.last_snapshot = SimpleNamespace(statuses=(), stale_statuses=(),
                                               aggregate=SimpleNamespace(mode=AgentMode.UNKNOWN))
    controller.sync_keep_awake(AgentMode.UNKNOWN)
    assert controller.keep_awake.lease == original
    assert controller.keep_awake.pending_ids is None


def test_known_empty_observation_finishes_existing_lease(manual_lease):
    controller = manual_lease
    controller.last_snapshot = SimpleNamespace(statuses=(), stale_statuses=(),
                                               aggregate=SimpleNamespace(mode=AgentMode.IDLE_READY))
    controller.sync_keep_awake(AgentMode.IDLE_READY)
    assert controller.keep_awake.lease is None
