"""Regression checks for final control-center integration and persistence."""
from __future__ import annotations

import errno
import json
import threading
from types import SimpleNamespace

import pytest

from jrbar.deck_actions import DeckAction
from jrbar.deck_actions_macos import MacDeckActionExecutor
from jrbar.deck_board_store import DeckBoardStore
from jrbar.deck_control_center import change_deck_bank
from jrbar.deck_control_settings import DeckControlSettings
from jrbar.deck_input import ControlInput
from jrbar.deck_input_dispatch import DeckInputDispatch
from jrbar.deck_session_board import DeckSessionBoard


def test_latest_slot_save_can_return_to_the_last_written_value(tmp_path, monkeypatch):
    from jrbar import deck_board_store as module

    entered, release, finished = threading.Event(), threading.Event(), threading.Event()
    writes = []

    def write(path, payload):
        if json.loads(payload)["bank"] == 1:
            entered.set()
            assert release.wait(2)
        writes.append(json.loads(payload))
        if len(writes) >= 2:
            finished.set()

    monkeypatch.setattr(module, "atomic_private_write", write)
    board = SimpleNamespace(serialize=lambda: {"bank": 0})
    store = DeckBoardStore(tmp_path / "slots.json")
    store._last = json.dumps({"bank": 0}, sort_keys=True, separators=(",", ":")) + "\n"
    board.serialize = lambda: {"bank": 1}
    store.submit(board)
    assert entered.wait(2)
    try:
        board.serialize = lambda: {"bank": 0}
        store.submit(board)
    finally:
        release.set()
    assert finished.wait(2), "the newest request was discarded while an older write was in flight"
    assert writes[-1]["bank"] == 0


def test_store_close_drains_pending_save_and_refuses_later_changes(tmp_path):
    store = DeckBoardStore(tmp_path / "slots.json")
    board = DeckSessionBoard()
    store.submit(board)
    store.close()
    assert store.wait_until_idle(2)
    before = store.path.read_text()
    board.change_bank(1)
    store.submit(SimpleNamespace(serialize=lambda: {"invalid": True}))
    assert store.path.read_text() == before


class _CountingBoard:
    """A stand-in board whose revision covers its only field, `bank`."""

    def __init__(self, bank: int = 0) -> None:
        self.bank = bank
        self.revision = 0
        self.serialized = 0

    def set_bank(self, bank: int) -> None:
        self.bank = bank
        self.revision += 1

    def serialize(self) -> dict:
        self.serialized += 1
        return {"bank": self.bank}


def _payload(bank: int) -> str:
    return json.dumps({"bank": bank}, sort_keys=True, separators=(",", ":")) + "\n"


def _scripted_writer(*outcomes, then=None):
    """A stand-in for atomic_private_write: each call takes the next outcome.

    An outcome is None (the write lands) or an exception to raise. Once the
    outcomes run out, `then` decides the same way.
    """
    attempts: list[str] = []
    written: list[str] = []
    remaining = list(outcomes)

    def write(_path, payload):
        attempts.append(payload)
        outcome = remaining.pop(0) if remaining else then
        if outcome is not None:
            raise outcome
        written.append(payload)

    return write, attempts, written


def _no_space() -> OSError:
    return OSError(errno.ENOSPC, "no space left on device")


def test_slot_save_failure_retries_on_the_next_tick__and_5_more(tmp_path, monkeypatch):
    from jrbar import deck_board_store as module

    clock = [0.0]

    def store_at(name):
        return DeckBoardStore(tmp_path / name, monotonic=lambda: clock[0])

    # --- scenario: same_revision_failed_write_is_retried_after_backoff
    """Deletion: drop the `_last_revision = -1` reset in the failure branch,
    and the unchanged revision swallows the retry."""
    clock[0] = 0.0
    write, attempts, written = _scripted_writer(_no_space())
    monkeypatch.setattr(module, "atomic_private_write", write)
    store = store_at("same-revision.json")
    board = _CountingBoard(bank=2)
    board.set_bank(2)
    store.submit(board)
    assert store.wait_until_idle(2) is False
    assert store.error is None
    assert store.write_error is not None
    assert len(attempts) == 1
    assert board.serialized == 1

    clock[0] = 4.9
    store.submit(board)
    assert len(attempts) == 1
    assert board.serialized == 1, "a submit inside the backoff window serialized the board"

    clock[0] = 5.0
    store.submit(board)
    assert store.wait_until_idle(2) is True
    assert len(attempts) == 2
    assert written == [_payload(2)]
    assert store.write_error is None
    assert store.error is None

    # --- scenario: newer_change_submitted_during_a_failing_write_is_not_lost
    """Deletion: keep the payload the failed write dropped, or skip the memo
    reset, and the newer bank never reaches the file."""
    clock[0] = 0.0
    entered, release = threading.Event(), threading.Event()
    outcomes: list[str] = []

    def blocking_then_failing(path, payload):
        if not outcomes:
            outcomes.append("failed")
            entered.set()
            assert release.wait(2)
            raise _no_space()
        outcomes.append("landed")
        landed.append(payload)

    landed: list[str] = []
    monkeypatch.setattr(module, "atomic_private_write", blocking_then_failing)
    store = store_at("newer-change.json")
    board = _CountingBoard(bank=0)
    store.submit(board)
    assert entered.wait(2)
    try:
        board.set_bank(1)
        store.submit(board)
    finally:
        release.set()
    assert store.wait_until_idle(2) is False
    clock[0] = 5.0
    store.submit(board)
    assert store.wait_until_idle(2) is True
    assert landed == [_payload(1)]

    # --- scenario: persistent_failure_is_bounded
    """Deletion: drop the backoff gate at the top of `submit`, and every tick
    serializes the board and starts a writer."""
    clock[0] = 0.0
    write, attempts, written = _scripted_writer(then=_no_space())
    monkeypatch.setattr(module, "atomic_private_write", write)
    store = store_at("persistent.json")
    board = _CountingBoard()
    store.submit(board)
    assert store.wait_until_idle(2) is False
    for _ in range(50):
        store.submit(board)
    assert len(attempts) == 1
    assert board.serialized == 1

    now = 0.0
    expected_attempts = 1
    for delay in (5.0, 10.0, 20.0, 40.0, 60.0, 60.0):
        clock[0] = now + delay - 0.1
        store.submit(board)
        assert len(attempts) == expected_attempts, f"retried {delay}s early"
        now += delay
        clock[0] = now
        store.submit(board)
        assert store.wait_until_idle(2) is False
        expected_attempts += 1
        assert len(attempts) == expected_attempts
    assert written == []

    # --- scenario: load_failure_stays_sticky_and_the_file_is_untouched
    """Deletion: let a later submit clear `store.error`, and the store writes
    over a file it could not read."""
    clock[0] = 0.0
    path = tmp_path / "invalid.json"
    path.write_bytes(b"{not json")

    def refuse(*_args):
        raise AssertionError("a store that failed to load must not write")

    monkeypatch.setattr(module, "atomic_private_write", refuse)
    store = DeckBoardStore(path, monotonic=lambda: clock[0])
    with pytest.raises(ValueError):
        store.load(DeckSessionBoard())
    sticky = store.error
    assert sticky is not None
    board = _CountingBoard()
    store.submit(board)
    clock[0] = 3600.0
    board.set_bank(1)
    store.submit(board)
    assert path.read_bytes() == b"{not json"
    assert store.wait_until_idle(2) is False
    assert store.error == sticky
    assert store.write_error is None
    assert board.serialized == 0

    # --- scenario: closed_store_refuses_the_retry
    """Deletion: let `submit` retry after `close()`."""
    clock[0] = 0.0
    write, attempts, written = _scripted_writer(_no_space())
    monkeypatch.setattr(module, "atomic_private_write", write)
    store = store_at("closed.json")
    board = _CountingBoard(bank=3)
    store.submit(board)
    assert store.wait_until_idle(2) is False
    store.close()
    clock[0] = 3600.0
    store.submit(board)
    assert len(attempts) == 1
    assert written == []

    # --- scenario: revert_to_written_content_clears_the_failure
    """Deletion: leave the failure state set when the payload matches what is
    already on disk."""
    clock[0] = 0.0
    write, attempts, written = _scripted_writer(None, _no_space())
    monkeypatch.setattr(module, "atomic_private_write", write)
    store = store_at("revert.json")
    board = _CountingBoard(bank=0)
    store.submit(board)
    assert store.wait_until_idle(2) is True
    assert written == [_payload(0)]
    board.set_bank(1)
    store.submit(board)
    assert store.wait_until_idle(2) is False
    assert store.write_error is not None
    board.set_bank(0)
    clock[0] = 5.0
    store.submit(board)
    assert store.wait_until_idle(2) is True
    assert store.write_error is None
    assert len(attempts) == 2, "the file already held this content; no write was needed"


def test_rail_preference_round_trips_and_old_boards_migrate():
    board = DeckSessionBoard()
    board.set_rail_edge("left")
    saved = board.serialize()
    restored = DeckSessionBoard()
    restored.restore(saved)
    assert restored.snapshot().rail_edge == "left"
    restored.restore({"version": 1, "slots": [], "pinned": [], "bank": 0})
    assert restored.snapshot().rail_edge == "off"
    with pytest.raises(ValueError):
        restored.set_rail_edge("external-command")


def _dispatch_target():
    calls = []
    target = SimpleNamespace(
        _deck_session_board=DeckSessionBoard(),
        _deck_board_store=SimpleNamespace(submit=lambda _: None),
        performSelectorOnMainThread_withObject_waitUntilDone_=lambda _, batch, __: calls.append(batch),
    )
    settings = DeckControlSettings(enabled=True, bindings=((3, DeckAction("open_usage")),))
    dispatch = DeckInputDispatch(target, settings)
    target._jrbar_optional_integration_runtime = SimpleNamespace(_deck_dispatch=dispatch)
    return target, dispatch, calls


def test_bank_change_revokes_explicit_actions_and_pending_automations__and_2_more() -> None:
    # --- scenario: bank_change_revokes_explicit_actions_and_pending_automations
    target, dispatch, calls = _dispatch_target()
    stopped, executed = [], []
    target._deck_automation_runner = SimpleNamespace(close=lambda: stopped.append(True))
    dispatch.receive_normalized((ControlInput(3, "press"),))
    change_deck_bank(target, 1)
    assert dispatch.deliver(calls[0], MacDeckActionExecutor(open_usage=lambda: executed.append(True))) == ()
    assert not executed and stopped == [True]

    # --- scenario: modal_confirmation_cannot_execute_after_the_context_changes
    target, dispatch, calls = _dispatch_target()
    token = dispatch.capture_context()
    target._deck_session_board.change_bank(1)
    assert not dispatch.receive_normalized((ControlInput(3, "press"),), virtual=True, expected_context=token)
    assert not calls
    assert dispatch.receive_normalized((ControlInput(3, "press"),), virtual=True,
                                       expected_context=dispatch.capture_context())
    assert len(calls) == 1

    # --- scenario: normalized_input_is_refused_during_termination
    target, dispatch, calls = _dispatch_target()
    target._runtime_termination_started = True
    dispatch.receive_normalized((ControlInput(3, "press"),))
    assert not calls



def test_shortcut_timeout_reaps_the_killed_child(monkeypatch):
    import signal
    import subprocess

    from jrbar import deck_automation

    waits, signals = [], []

    def wait(*, timeout):
        waits.append(timeout)
        if len(waits) == 1:
            raise subprocess.TimeoutExpired("test-shortcut", timeout)
        return -9

    process = SimpleNamespace(pid=123, poll=lambda: None, wait=wait)
    monkeypatch.setattr(deck_automation.os, "killpg", lambda pid, sig: signals.append((pid, sig)))
    deck_automation.DeckAutomationRunner._stop(process)
    assert signals == [(123, signal.SIGTERM), (123, signal.SIGKILL)]
    assert waits == [1.0, 1.0]
