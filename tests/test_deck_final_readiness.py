"""Regression checks for final control-center integration and persistence."""
from __future__ import annotations

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
    target._sidepulse_optional_integration_runtime = SimpleNamespace(_deck_dispatch=dispatch)
    return target, dispatch, calls


def test_bank_change_revokes_explicit_actions_and_pending_automations():
    target, dispatch, calls = _dispatch_target()
    stopped, executed = [], []
    target._deck_automation_runner = SimpleNamespace(close=lambda: stopped.append(True))
    dispatch.receive_normalized((ControlInput(3, "press"),))
    change_deck_bank(target, 1)
    assert dispatch.deliver(calls[0], MacDeckActionExecutor(open_usage=lambda: executed.append(True))) == ()
    assert not executed and stopped == [True]


def test_modal_confirmation_cannot_execute_after_the_context_changes():
    target, dispatch, calls = _dispatch_target()
    token = dispatch.capture_context()
    target._deck_session_board.change_bank(1)
    assert not dispatch.receive_normalized((ControlInput(3, "press"),), virtual=True, expected_context=token)
    assert not calls
    assert dispatch.receive_normalized((ControlInput(3, "press"),), virtual=True,
                                       expected_context=dispatch.capture_context())
    assert len(calls) == 1


def test_normalized_input_is_refused_during_termination():
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
