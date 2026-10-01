"""A deck keymap command waits for its setup thread, and always hears back.

``_core_deck_run_setup`` parks a socket thread until the main thread applies
the setup result. A runtime reconfiguration mid-operation (``deck_set_settings``
changing something, a device hot-plug) replaces the deck runtime generation
the setup was started under, so the result arrives for a setup nobody
should act on any more. The waiter used to sleep out its whole 60 s timeout
and answer ``busy`` for work that had in fact finished.
"""

from __future__ import annotations

import threading
from types import SimpleNamespace
from typing import Any

import pytest

from jrbar import core_deck, core_runtime
from jrbar.core_server import CommandError
from jrbar.creator_micro_adapter import Receipt
from jrbar.creator_micro_keymap import KeymapPlan
from jrbar.creator_micro_setup_controller import (
    SetupPreview,
    SetupResult,
    begin_creator_micro_inspection,
)
from tests.test_core_deck import SERIAL, _FakeRuntime, deck_live  # noqa: F401  (a daemon over a fake pad)
from tests.test_core_runtime import REAL_THREAD, headless  # noqa: F401  (the headless daemon fixture)

# Only a hang waits this long: every passing run is answered at once.
HANG_BOUND_SECONDS = 5.0


def _plan() -> KeymapPlan:
    return KeymapPlan("{}", "{}", "a", "b", ("Key 0: KC_A -> KV_OAI_AG00",), 0, 1)


class _Adapter:
    def connect(self) -> Receipt:
        return Receipt("connected")

    def close(self) -> None:
        pass


def _loaded() -> Any:
    return SimpleNamespace(
        settings=SimpleNamespace(creator_micro_enabled=True, creator_micro_device_serial="approved")
    )


def _deliver_main_thread_hops_inline(controller: Any) -> list[str]:
    """Deliver the setup thread's ``waitUntilDone=False`` hop to the main
    thread the way the run loop would, from the thread that asked."""
    hops: list[str] = []
    real = controller.applyCreatorMicroSetupResult_

    def hop(selector: str, value: Any, wait: bool) -> None:
        hops.append(selector)
        assert selector == "applyCreatorMicroSetupResult:"
        real(value)

    controller.performSelectorOnMainThread_withObject_waitUntilDone_ = hop
    return hops


def _inspection(controller: Any, tmp_path: Any, *, reconfigure_midway: bool):
    """The real setup thread over a fake pad. ``reconfigure_midway`` is what
    ``reconfigure_deck_runtime`` does while the pad is being read: it stamps
    a new deck runtime generation."""

    class _Setup:
        def __init__(self, *_args: Any, **_kwargs: Any) -> None:
            pass

        def inspect(self) -> KeymapPlan:
            if reconfigure_midway:
                controller._deck_runtime_generation = object()
            return _plan()

    return lambda: begin_creator_micro_inspection(
        controller,
        settings_loader=_loaded,
        adapter_factory=lambda serial: _Adapter(),
        setup_factory=lambda adapter, serial, backup, **kwargs: _Setup(),
        backup_root=tmp_path,
    )


@pytest.fixture
def deck(headless, monkeypatch: pytest.MonkeyPatch):  # noqa: F811
    controller = headless
    # The headless harness swaps threading.Thread for an inert stand-in; the
    # setup thread has to be a real one.
    monkeypatch.setattr(threading, "Thread", REAL_THREAD)
    monkeypatch.setattr(core_runtime, "DECK_SETUP_TIMEOUT_SECONDS", HANG_BOUND_SECONDS)
    controller._runtime_termination_started = False
    controller._deck_runtime_stopping = False
    return controller


def test_a_setup_overtaken_by_a_runtime_reconfiguration_releases_its_waiter_as_superseded(
    deck, tmp_path
) -> None:
    hops = _deliver_main_thread_hops_inline(deck)

    result = deck._core_deck_run_setup(_inspection(deck, tmp_path, reconfigure_midway=True))

    assert hops == ["applyCreatorMicroSetupResult:"]
    assert result.code == "superseded"
    # The setup is over, so the next one may start: a stale result must not
    # leave the "already running" flag set for good.
    assert deck._creator_micro_setup_busy is False
    message = core_deck.receipt_message("superseded")
    assert message == core_deck.SETUP_RECEIPT_MESSAGES["superseded"]
    assert "try again" in message.lower()


def test_a_superseded_inspection_is_refused_with_the_superseded_code_by_the_command(
    deck, tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from jrbar import creator_micro_setup_controller

    _deliver_main_thread_hops_inline(deck)
    start = _inspection(deck, tmp_path, reconfigure_midway=True)
    # deck_plan_keymap and deck_apply_keymap inspect first, through this call.
    monkeypatch.setattr(creator_micro_setup_controller, "begin_creator_micro_inspection", lambda target: start())

    with pytest.raises(CommandError) as refused:
        deck._core_deck_inspect()

    assert refused.value.code == "superseded"
    assert "try again" in str(refused.value).lower()


def test_a_setup_that_is_not_overtaken_still_delivers_its_own_result(deck, tmp_path) -> None:
    _deliver_main_thread_hops_inline(deck)

    result = deck._core_deck_run_setup(_inspection(deck, tmp_path, reconfigure_midway=False))

    assert result.code == "inspection_ready"
    assert type(result.preview) is SetupPreview


def test_a_daemon_that_is_stopping_releases_a_waiting_setup_instead_of_timing_out(deck) -> None:
    generation = object()

    def start() -> object:
        deck._creator_micro_setup_generation = generation
        deck._deck_runtime_generation = generation
        deck._creator_micro_setup_busy = True
        # The deck runtime begins stopping before the result is applied.
        deck._deck_runtime_stopping = True
        deck.applyCreatorMicroSetupResult_(SetupResult(generation, "inspect", "setup_failed"))
        return object()

    result = deck._core_deck_run_setup(start)

    assert result.code == "superseded"


def test_a_result_for_an_older_setup_never_releases_the_waiter_of_a_newer_one(deck, monkeypatch) -> None:
    monkeypatch.setattr(core_runtime, "DECK_SETUP_TIMEOUT_SECONDS", 0.2)
    older, newer = object(), object()

    def start() -> object:
        deck._creator_micro_setup_generation = newer
        deck._deck_runtime_generation = newer
        deck._creator_micro_setup_busy = True
        deck.applyCreatorMicroSetupResult_(SetupResult(older, "inspect", "keymap_verified"))
        return object()

    with pytest.raises(CommandError) as refused:
        deck._core_deck_run_setup(start)

    assert refused.value.code == "busy"
    assert deck._creator_micro_setup_busy is True


def test_a_pad_reconfigured_mid_inspection_answers_superseded_and_the_restart_still_runs(
    deck_live, monkeypatch: pytest.MonkeyPatch  # noqa: F811
) -> None:
    """The whole path: a real inspection over a fake pad, with a real
    ``reconfigure_deck_runtime`` landing while the pad is being read."""
    from jrbar.deck_controller import reconfigure_deck_runtime

    controller = deck_live
    device = controller._deck_test_devices[SERIAL]
    monkeypatch.setattr(core_runtime, "DECK_SETUP_TIMEOUT_SECONDS", HANG_BOUND_SECONDS)
    controller._core_deck_inspection = None
    restarted = threading.Event()

    def restart_factory(target: Any) -> _FakeRuntime:
        restarted.set()
        return _FakeRuntime(target)

    real_connect = device.connect

    def connect_while_deck_settings_change():
        reconfigure_deck_runtime(controller, runtime_factory=restart_factory)
        return real_connect()

    device.connect = connect_while_deck_settings_change

    with pytest.raises(CommandError) as refused:
        controller._core_dispatch("deck_plan_keymap", {"profile": 0, "layer": 0})

    assert refused.value.code == "superseded"
    # The reconfiguration that overtook the setup still puts the pad's output
    # service back, once the setup lets go of the restart lock.
    assert restarted.wait(HANG_BOUND_SECONDS)
    assert controller._creator_micro_setup_busy is False
    device.connect = real_connect
    plan = controller._core_dispatch("deck_plan_keymap", {"profile": 0, "layer": 0})
    assert plan["changes"]
