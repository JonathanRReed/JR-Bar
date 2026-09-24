from types import SimpleNamespace

from jrbar.deck_actions import DeckAction
from jrbar.deck_control_settings import DeckControlSettings
from jrbar.deck_controller import apply_deck_input
from jrbar.deck_input_dispatch import DeckInputDispatch


def test_controller_routes_a_hardware_press_to_the_apps_usage_center__and_2_more() -> None:
    # --- scenario: controller_routes_a_hardware_press_to_the_apps_usage_center
    queued, opened = [], []

    def request_app(kind, **fields):
        opened.append((kind, fields))
        return True

    target = SimpleNamespace(
        _deck_deliver_inline=True,
        performSelectorOnMainThread_withObject_waitUntilDone_=lambda selector, batch, wait: queued.append(batch),
        _core_request_app=request_app,
    )
    controls = DeckControlSettings(enabled=True, bindings=((3, DeckAction("open_usage")),))
    dispatch = DeckInputDispatch(target, controls)
    dispatch.receive([{"method": "v.oai.hid", "params": {"k": "AG03", "act": 1}}])
    apply_deck_input(target, queued[0])
    assert opened == [("open_window", {"window": "usage"})]
    assert target._deck_action_receipt.success

    # --- scenario: controller_ignores_input_during_termination
    queued, opened = [], []
    target = SimpleNamespace(
        _runtime_termination_started=True,
        performSelectorOnMainThread_withObject_waitUntilDone_=lambda selector, batch, wait: queued.append(batch),
        _core_request_app=lambda kind, **fields: opened.append(kind) or True,
    )
    dispatch = DeckInputDispatch(target, DeckControlSettings(enabled=True, bindings=((3, DeckAction("open_usage")),)))
    dispatch.receive([{"method": "v.oai.hid", "params": {"k": "AG03", "act": 1}}])
    # Input during termination is dropped before it is ever queued.
    assert queued == []
    assert not opened

    # --- scenario: reconfiguration_revokes_input_then_waits_for_old_device_owner_before_starting
    import threading

    from jrbar.deck_controller import reconfigure_deck_runtime

    stopping, allow_stop = threading.Event(), threading.Event()
    calls = []

    class OldRuntime:
        def revoke_deck_input(self):
            calls.append("revoke")

        def close(self):
            calls.append("close")

        def wait_until_stopped(self, timeout):
            stopping.set()
            return allow_stop.wait(timeout)

    target = SimpleNamespace(_jrbar_optional_integration_runtime=OldRuntime())
    replacement = object()

    def start(controller):
        assert controller is target
        calls.append("start")
        return replacement

    thread = reconfigure_deck_runtime(target, runtime_factory=start)
    assert stopping.wait(1)
    assert calls == ["revoke", "close"]
    allow_stop.set()
    thread.join(1)
    assert calls == ["revoke", "close", "start"]
    assert target._jrbar_optional_integration_runtime is replacement



def test_reconfiguration_never_starts_a_second_owner_if_the_first_cannot_stop__and_1_more() -> None:
    # --- scenario: reconfiguration_never_starts_a_second_owner_if_the_first_cannot_stop
    from jrbar.deck_controller import reconfigure_deck_runtime

    calls = []
    old = SimpleNamespace(revoke_deck_input=lambda: None, close=lambda: None, wait_until_stopped=lambda timeout: False)
    target = SimpleNamespace(
        _jrbar_optional_integration_runtime=old,
        performSelectorOnMainThread_withObject_waitUntilDone_=lambda selector, receipt, wait: calls.append(receipt.reason),
    )
    thread = reconfigure_deck_runtime(target, runtime_factory=lambda controller: calls.append("start"))
    thread.join(1)
    assert calls == ["previous_owner_stopping"]
    assert target._jrbar_optional_integration_runtime is old

    # --- scenario: termination_revokes_a_waiting_restart_before_old_owner_finishes
    import threading

    from jrbar.deck_controller import reconfigure_deck_runtime, stop_deck_runtime_reconfiguration

    waiting, stopped = threading.Event(), threading.Event()
    created = []

    def wait(timeout):
        waiting.set()
        return stopped.wait(timeout)

    target = SimpleNamespace(_jrbar_optional_integration_runtime=SimpleNamespace(
        revoke_deck_input=lambda: None, close=lambda: None, wait_until_stopped=wait,
    ))
    thread = reconfigure_deck_runtime(target, runtime_factory=lambda controller: created.append(1))
    assert waiting.wait(1)
    stop_deck_runtime_reconfiguration(target)
    stopped.set()
    thread.join(1)
    assert not created

