"""Failed releases retain ownership until the synthetic child exits."""

import subprocess

from jrbar.keep_awake import KeepAwakeController
from jrbar.models import AgentMode


class Process:
    def __init__(self):
        self.alive = True
        self.refuse_release = True
        self.kill_exits = True
        self.terminate_calls = 0
        self.kill_calls = 0

    def poll(self):
        return None if self.alive else 0

    def terminate(self):
        self.terminate_calls += 1
        if self.refuse_release:
            raise PermissionError("synthetic terminate refused")
        self.alive = False

    def wait(self, timeout=None):
        if self.alive:
            raise subprocess.TimeoutExpired("synthetic child", timeout)
        return 0

    def kill(self):
        self.kill_calls += 1
        if self.refuse_release:
            raise PermissionError("synthetic kill refused")
        if self.kill_exits:
            self.alive = False


def controller():
    children = []

    def factory(*_args, **_kwargs):
        child = Process()
        children.append(child)
        return child

    keep = KeepAwakeController(process_factory=factory, watch_current_process=False)
    assert keep.update(AgentMode.WORKING, now=1)
    return keep, children


def test_disabled_update_retries_failed_release_and_clears_error_after_exit():
    keep, children = controller()
    child = children[0]
    keep.set_enabled(False)
    assert keep.hold_document()["active"] is True
    assert keep.hold_document()["release_failed"] is True
    assert "Could not release" in keep.detail(now=2)
    assert "synthetic kill refused" in keep.last_error
    child.refuse_release = False
    keep.update(AgentMode.WORKING, now=2)
    assert child.terminate_calls == 2
    assert keep.hold_document()["active"] is False
    assert keep.last_error is None
    assert keep.hold_document()["release_failed"] is False


def test_reenable_does_not_duplicate_a_hold_whose_release_failed():
    keep, children = controller()
    keep.set_enabled(False)
    keep.set_enabled(True)
    assert keep.update(AgentMode.WORKING, now=2)
    assert len(children) == 1
    assert keep.last_error is None
    assert keep.hold_document()["release_failed"] is False


def test_display_policy_waits_for_old_child_to_exit_before_replacement():
    keep, children = controller()
    keep.set_keep_display_awake(True)
    keep.update(AgentMode.WORKING, now=2)
    assert len(children) == 1
    assert keep.hold_document()["display"] is False
    assert keep.hold_document()["release_failed"] is True
    children[0].refuse_release = False
    keep.update(AgentMode.WORKING, now=3)
    assert len(children) == 2
    assert not children[0].alive
    assert children[1].alive
    assert keep.last_error is None
    assert keep.hold_document()["display"] is True
    assert keep.hold_document()["release_failed"] is False


def test_successful_kill_request_does_not_confirm_exit():
    keep, children = controller()
    child = children[0]
    child.kill_exits = False
    child.refuse_release = False

    def ignored_terminate():
        child.terminate_calls += 1

    child.terminate = ignored_terminate
    keep.set_enabled(False)
    assert child.kill_calls == 1
    assert keep.hold_document()["active"] is True
    assert keep.last_error is not None
    child.alive = False
    keep.update(AgentMode.WORKING, now=2)
    assert keep.hold_document()["active"] is False
    assert keep.last_error is None
