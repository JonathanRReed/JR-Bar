from __future__ import annotations

import threading
import time
from types import SimpleNamespace

from jrbar.models import AgentMode
from jrbar.optional_integration_runtime import (
    CreatorMicroOutputService,
    OptionalIntegrationRuntime,
    creator_semantic_state,
)


class Monitor:
    def __init__(self):
        self.calls = []
        self.ready = threading.Event()

    def replace_external_statuses(self, source, statuses):
        self.calls.append((source, statuses))
        self.ready.set()


def test_default_off_runtime_does_not_construct_or_read_optional_sources__and_2_more() -> None:
    # --- scenario: default_off_runtime_does_not_construct_or_read_optional_sources
    def forbidden(*_args, **_kwargs):
        raise AssertionError("disabled optional source was touched")

    target = SimpleNamespace(monitor=Monitor())
    settings = SimpleNamespace(creator_micro_enabled=False)
    runtime = OptionalIntegrationRuntime(
        target,
        settings_loader=lambda: settings,
        creator_service_factory=forbidden,
    )

    runtime.start()
    assert runtime.wait_until_configured(1)
    runtime.close()
    assert target.monitor.calls == []

    # --- scenario: close_does_not_wait_for_settings_io_or_publish_after_loader_returns
    loading = threading.Event()
    release_loader = threading.Event()
    ui_calls = []
    deck_loads = []
    target = SimpleNamespace(
        _creator_micro_output_enabled="current",
        _deck_control_settings="current",
        deck_settings_pane=object(),
        performSelectorOnMainThread_withObject_waitUntilDone_=lambda *args: ui_calls.append(args),
    )

    def load_settings():
        loading.set()
        assert release_loader.wait(1)
        return SimpleNamespace(creator_micro_enabled=True)

    runtime = OptionalIntegrationRuntime(
        target,
        settings_loader=load_settings,
        deck_settings_loader=lambda: deck_loads.append(True),
    )
    runtime.start()
    assert loading.wait(1)

    runtime.close()
    assert not release_loader.is_set()
    release_loader.set()
    assert runtime.wait_until_configured(1)

    assert target._creator_micro_output_enabled == "current"
    assert target._deck_control_settings == "current"
    assert deck_loads == []
    assert ui_calls == []

    # --- scenario: close_does_not_wait_for_blocked_deck_settings_io
    loading = threading.Event()
    release_loader = threading.Event()
    target = SimpleNamespace()

    def load_deck_settings():
        loading.set()
        assert release_loader.wait(1)
        return SimpleNamespace(enabled=False)

    runtime = OptionalIntegrationRuntime(
        target,
        settings_loader=lambda: SimpleNamespace(creator_micro_enabled=False),
        deck_settings_loader=load_deck_settings,
    )
    runtime.start()
    assert loading.wait(1)

    runtime.close()
    assert not release_loader.is_set()
    release_loader.set()
    assert runtime.wait_until_configured(1)



def test_enabled_creator_micro_discovery_runs_off_the_caller__and_2_more() -> None:
    # --- scenario: enabled_creator_micro_discovery_runs_off_the_caller
    calls = []
    configured = threading.Event()

    class CreatorService:
        def __init__(self, **kwargs):
            assert kwargs["approved_serial"] == "CM2-123"

        def start(self):
            calls.append(threading.current_thread().name)
            configured.set()
            return True

        def close(self):
            pass

    settings = SimpleNamespace(
        creator_micro_enabled=True,
        creator_micro_device_serial="CM2-123",
    )
    runtime = OptionalIntegrationRuntime(
        SimpleNamespace(monitor=Monitor()),
        settings_loader=lambda: settings,
        creator_service_factory=CreatorService,
    )
    caller = threading.current_thread().name

    runtime.start()
    assert configured.wait(1)
    runtime.close()
    assert calls and calls[0] != caller

    # --- scenario: enabled_creator_micro_without_approved_identity_fails_closed
    target = SimpleNamespace(monitor=Monitor())
    settings = SimpleNamespace(
        creator_micro_enabled=True,
        creator_micro_device_serial=None,
    )
    runtime = OptionalIntegrationRuntime(
        target,
        settings_loader=lambda: settings,
        creator_service_factory=lambda **_kwargs: (_ for _ in ()).throw(
            AssertionError("identity-less Creator Micro output started")
        ),
    )

    runtime.start()
    assert runtime.wait_until_configured(1)
    runtime.close()
    assert target._creator_micro_output_receipt.reason == "device_identity_required"

    # --- scenario: creator_semantic_mapping_is_explicit
    for mode, signal, want in [
        (AgentMode.WAITING_FOR_INPUT, None, "input_required"),
        (AgentMode.BLOCKED_ERROR, None, "failure"),
        (AgentMode.WORKING, None, "active"),
        (AgentMode.COMPLETED, None, "completed"),
        (AgentMode.IDLE_READY, None, "idle"),
        (AgentMode.IDLE_READY, "quota_exhausted", "quota_exhausted"),
        (AgentMode.IDLE_READY, "quota_warning", "quota_warning"),
        (AgentMode.IDLE_READY, "reset", "reset"),
        (AgentMode.WAITING_FOR_INPUT, "quota_exhausted", "input_required"),
        (AgentMode.BLOCKED_ERROR, "reset", "failure"),
        (AgentMode.WORKING, "quota_warning", "active"),
        (AgentMode.WORKING, "reset", "reset"),
    ]:
        assert creator_semantic_state(mode, signal=signal).value == want



def test_output_service_negotiates_before_writes_and_retries_a_conflict__and_2_more() -> None:
    # --- scenario: output_service_negotiates_before_writes_and_retries_a_conflict
    """A conflict used to end the worker for the daemon's life. Now the
    receipt stays visible and the adapter's own retry is asked to reconnect."""
    calls, receipts = [], []
    conflicted = threading.Event()

    class Adapter:
        conflict = SimpleNamespace(active=False)

        def connect(self):
            calls.append("connect")
            return SimpleNamespace(code="connected", detail="")

        def negotiate_capabilities(self):
            calls.append("negotiate")
            return SimpleNamespace(code="capabilities_negotiated", detail="v.oai.thstatus")

        def capabilities(self):
            return SimpleNamespace(methods=frozenset({"v.oai.thstatus"}))

        def apply(self, state):
            calls.append(state.value)
            self.conflict.active = True
            conflicted.set()
            return SimpleNamespace(code="device_conflict", detail="foreign response")

        def poll_inputs(self):
            return []

        def recover_conflict(self):
            calls.append("recover")
            # Still inside the retry delay: the accusation stands.
            return SimpleNamespace(code="device_conflict", detail="")

        def close(self):
            calls.append("close")

    service = CreatorMicroOutputService(adapter_factory=Adapter, callback=receipts.append)
    service.start()
    service.submit(AgentMode.WORKING)
    assert conflicted.wait(1)
    assert service.wait_until_idle(1)
    service.submit(AgentMode.IDLE_READY)
    assert service.wait_until_idle(1)
    # The worker did not stop on the accusation; it keeps asking to retry.
    deadline = threading.Event()
    assert service._thread is not None and service._thread.is_alive()
    waited = deadline.wait(0.6)
    assert not waited
    service.close()

    assert calls[:3] == ["connect", "negotiate", "active"]
    assert "recover" in calls and "idle" in calls and calls[-1] == "close"
    assert receipts[-1].reason == "device_conflict"

    # --- scenario: output_service_reports_unsupported_firmware_without_applying
    class Adapter:
        conflict = SimpleNamespace(active=False)

        def connect(self):
            return SimpleNamespace(code="connected", detail="")

        def negotiate_capabilities(self):
            return SimpleNamespace(code="capabilities_negotiated", detail="")

        def capabilities(self):
            return SimpleNamespace(methods=frozenset())

        def apply(self, _state):
            raise AssertionError("unsupported firmware received output")

        def close(self):
            pass

    receipts = []
    service = CreatorMicroOutputService(adapter_factory=Adapter, callback=receipts.append)
    service.start()
    service.submit(AgentMode.WORKING)
    assert service.wait_until_idle(1)
    service.close()
    assert receipts[-1].reason == "unsupported_firmware"

    # --- scenario: output_service_recovers_from_an_unexpected_poll_failure
    """A bug in a poll or one malformed packet used to kill deck I/O
    until the daemon restarted: the worker's outer except latched
    ``_closed`` and the service could never start again. An unexpected
    failure is a device failure -- the adapter closes, the owner is told,
    and the loop reconnects on the same backoff a disconnect takes."""
    receipts, builds = [], []
    repolled = threading.Event()

    class Adapter:
        def __init__(self):
            self.conflict = SimpleNamespace(active=False)
            self.connected = True
            self.polls = 0

        def connect(self):
            return SimpleNamespace(code="connected", detail="")

        def negotiate_capabilities(self):
            return SimpleNamespace(code="capabilities_negotiated", detail="")

        def capabilities(self):
            return SimpleNamespace(methods=frozenset({"v.oai.thstatus"}))

        def apply(self, _state):
            return SimpleNamespace(code="applied", detail="")

        def poll_inputs(self):
            self.polls += 1
            if len(builds) == 1:
                raise RuntimeError("bad packet")
            repolled.set()
            return []

        def close(self):
            self.connected = False

    def factory():
        adapter = Adapter()
        builds.append(adapter)
        return adapter

    service = CreatorMicroOutputService(adapter_factory=factory, callback=receipts.append)
    service.start()
    try:
        assert repolled.wait(4.0)
    finally:
        service.close()
    assert len(builds) == 2
    assert any(receipt.reason == "reconnecting" for receipt in receipts)
    # The replacement adapter went through a full live loop -- connect,
    # negotiate, poll -- not just a retry attempt that died again.
    assert builds[1].polls > 0



def test_hold_reasserts_our_layer_and_foreign_layers_are_left_alone() -> None:
    """The hijack option: a foreign writer on a layer we own is absorbed —
    the accusation is dropped and our latest frame goes back on the wire —
    while a layer the map gave away is neither painted nor defended."""

    class Adapter:
        def __init__(self):
            self.conflict = SimpleNamespace(
                active=False,
                reset=lambda: setattr(self.conflict, "active", False),
            )
            self.connected = True
            self.writes = []
            self.foreign_pending = False
            self.status = {"layer_index": 1, "profile_index": 0}

        def connect(self):
            return SimpleNamespace(code="connected", detail="")

        def negotiate_capabilities(self):
            return SimpleNamespace(code="capabilities_negotiated", detail="")

        def capabilities(self):
            return SimpleNamespace(methods=frozenset({"v.oai.thstatus"}))

        def apply(self, state, params=None):
            self.writes.append(state.value)
            return SimpleNamespace(code="applied", detail="")

        def poll_inputs(self):
            if self.foreign_pending:
                self.foreign_pending = False
                self.conflict.active = True
            return []

        def query_status(self):
            return dict(self.status)

        def recover_conflict(self):
            raise AssertionError("hold must not yield to the conflict retry")

        def close(self):
            self.connected = False

    def until(predicate, timeout=4.0):
        pace = threading.Event()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and not predicate():
            pace.wait(0.02)
        return predicate()

    # --- scenario: hold_defends_an_owned_layer
    adapter = Adapter()
    receipts = []
    service = CreatorMicroOutputService(
        adapter_factory=lambda: adapter, callback=receipts.append,
        ownership="hold", status_poll_seconds=0.05,
    )
    try:
        service.start()
        service.submit(AgentMode.WORKING)
        assert until(lambda: adapter.writes == ["active"])
        adapter.foreign_pending = True
        assert until(lambda: len(adapter.writes) >= 2), "a foreign write on our layer was not answered"
        assert any(receipt.reason == "contention" and receipt.available for receipt in receipts)
        assert not any(receipt.reason == "device_conflict" for receipt in receipts)
    finally:
        service.close()

    # --- scenario: a_layer_handed_to_another_app_is_neither_painted_nor_defended
    adapter = Adapter()
    # The pad sits on layer 2 (assigned to codex) until the test moves it.
    # The switch back is the test's step, not a poll count: scripted by
    # polls, a runner that stalled one 50 ms status interval between the
    # external_layer receipt and the submit had already reached layer 1,
    # and the paint it then saw was correct behaviour, not a leak.
    adapter.status = {"layer_index": 2, "profile_index": 0}
    receipts = []
    service = CreatorMicroOutputService(
        adapter_factory=lambda: adapter, callback=receipts.append,
        ownership="hold", layer_owners={1: "codex"}, status_poll_seconds=0.05,
    )
    try:
        service.start()
        assert until(lambda: any(r.reason == "external_layer" for r in receipts))
        service.submit(AgentMode.WORKING)
        assert service.wait_until_idle(1)
        assert adapter.writes == [], "a foreign-owned layer must not be painted"
        # Foreign traffic there is the design, not a conflict to retry: the
        # accusation is consumed and dropped, and nothing is painted over it.
        adapter.foreign_pending = True
        assert until(lambda: not adapter.foreign_pending and not adapter.conflict.active)
        assert not any(receipt.reason == "device_conflict" for receipt in receipts)
        assert adapter.writes == [], "foreign traffic on a foreign layer must not be answered"
        # The user switches back to layer 1: the remembered frame is
        # repainted on its own.
        adapter.status = {"layer_index": 1, "profile_index": 0}
        assert until(lambda: adapter.writes == ["active"])
    finally:
        service.close()



    # --- scenario: input_is_delivered_while_output_is_idle_on_the_same_transport_owner
    from collections import deque

    from jrbar.creator_micro_adapter import CreatorMicro2Adapter, CreatorMicro2Framer, RpcStreamDecoder

    received, ready = threading.Event(), threading.Event()
    inputs, owners = [], set()

    class Transport:
        def __init__(self):
            self.reads = deque()
            self.decoder = RpcStreamDecoder()

        def open(self, **_kwargs):
            owners.add(threading.get_ident())

        def write(self, report):
            owners.add(threading.get_ident())
            for message in self.decoder.feed(report):
                self.reads.extend(CreatorMicro2Framer.encode_message(
                    {"jsonrpc": "2.0", "id": message["id"], "result": {"ok": 1}}
                ))

        def read(self, **_kwargs):
            owners.add(threading.get_ident())
            return self.reads.popleft() if self.reads else None

        def close(self):
            owners.add(threading.get_ident())

    transport = Transport()
    adapter = CreatorMicro2Adapter(transport, {
        "vendor_id": 0x303A, "product_id": 0x8297, "usage_page": 0xFF00, "usage": 1,
    })

    def on_input(batch):
        inputs.extend(batch)
        received.set()

    service = CreatorMicroOutputService(
        adapter_factory=lambda: adapter,
        callback=lambda receipt: ready.set() if receipt.reason == "ready" else None,
        input_callback=on_input,
    )
    try:
        service.start()
        assert ready.wait(1)
        transport.reads.extend(CreatorMicro2Framer.encode_message({
            "jsonrpc": "2.0", "m": "v.oai.hid", "p": {"k": "AG03", "act": 1},
        }))
        assert received.wait(1)
        service.submit(AgentMode.WORKING)
        assert service.wait_until_idle(1)
    finally:
        service.close()
    assert inputs == [{"method": "v.oai.hid", "params": {"k": "AG03", "act": 1}}]
    assert len(owners) == 1
    assert threading.get_ident() not in owners

    # --- scenario: runtime_wires_saved_macros_and_revokes_delivery_when_disabled
    from jrbar.deck_actions import DeckAction
    from jrbar.deck_actions_macos import MacDeckActionExecutor
    from jrbar.deck_control_settings import DeckControlSettings

    batches, opened = [], []
    target = SimpleNamespace(
        performSelectorOnMainThread_withObject_waitUntilDone_=lambda selector, payload, wait: batches.append(payload),
    )

    class Service:
        def __init__(self, **kwargs):
            self.receive = kwargs["input_callback"]

        def start(self):
            self.receive([{"method": "v.oai.hid", "params": {"k": "AG03", "act": 1}}])

        def close(self):
            pass

    runtime = OptionalIntegrationRuntime(
        target,
        settings_loader=lambda: SimpleNamespace(
            creator_micro_enabled=True, creator_micro_device_serial="CM2-123",
        ),
        deck_settings_loader=lambda: DeckControlSettings(
            enabled=True, bindings=((3, DeckAction("open_usage")),),
        ),
        creator_service_factory=Service,
    )
    runtime.start()
    assert runtime.wait_until_configured(1)
    assert len(batches) == 1
    executor = MacDeckActionExecutor(open_usage=lambda: opened.append("usage"))
    assert batches[0].owner.deliver(batches[0], executor)[0].success
    assert opened == ["usage"]
    runtime.close()
    assert batches[0].owner.deliver(batches[0], executor) == ()



def test_master_device_switch_uses_serialized_reconfiguration_instead_of_starting_a_second_owner__and_1_more(monkeypatch) -> None:
    # --- scenario: master_device_switch_uses_serialized_reconfiguration_instead_of_starting_a_second_owner
    from jrbar import integration_settings
    from jrbar.optional_integration_runtime import set_creator_micro_output_enabled_async

    settings = integration_settings.IntegrationSettings(creator_micro_enabled=True, creator_micro_device_serial="CM2")
    saved, calls, ready = [], [], threading.Event()
    monkeypatch.setattr(integration_settings, "load_integration_settings", lambda: SimpleNamespace(settings=settings))
    monkeypatch.setattr(integration_settings, "save_integration_settings", lambda value, **kwargs: saved.append(value))

    def dispatch(selector, payload, wait):
        calls.append(selector)
        assert payload.enabled is False
        ready.set()

    target = SimpleNamespace(performSelectorOnMainThread_withObject_waitUntilDone_=dispatch)
    set_creator_micro_output_enabled_async(target, False)
    assert ready.wait(1)
    assert not saved[0].creator_micro_enabled
    assert calls == ["applyCreatorMicroSettings:"]

    # --- scenario: master_device_settings_last_intent_wins_during_a_slow_save
    monkeypatch.undo()
    from jrbar import integration_settings
    from jrbar.optional_integration_runtime import set_creator_micro_output_enabled_async

    current = [integration_settings.IntegrationSettings(creator_micro_device_serial="CM2")]
    first_saving, finish_first, done = threading.Event(), threading.Event(), threading.Event()
    receipts, saves = [], []
    monkeypatch.setattr(integration_settings, "load_integration_settings", lambda: SimpleNamespace(settings=current[0]))

    def save(value, **kwargs):
        saves.append(value.creator_micro_enabled)
        if len(saves) == 1:
            first_saving.set()
            assert finish_first.wait(1)
        current[0] = value

    def dispatch(selector, payload, wait):
        receipts.append(payload)
        done.set()

    monkeypatch.setattr(integration_settings, "save_integration_settings", save)
    target = SimpleNamespace(performSelectorOnMainThread_withObject_waitUntilDone_=dispatch)
    set_creator_micro_output_enabled_async(target, True)
    assert first_saving.wait(1)
    set_creator_micro_output_enabled_async(target, False)
    finish_first.set()
    assert done.wait(1)
    assert current[0].creator_micro_enabled is False
    assert saves == [True, False]
    assert len(receipts) == 1 and receipts[0].enabled is False



def test_creator_output_uses_the_same_user_colors_and_brightness_policy_as_other_devices__and_2_more() -> None:
    # --- scenario: creator_output_uses_the_same_user_colors_and_brightness_policy_as_other_devices
    from jrbar.colors import ColorSettings
    from jrbar.deck_control_settings import DeckControlSettings

    frames, brightness_targets = [], []

    class Service:
        def __init__(self, **kwargs):
            pass

        def start(self):
            pass

        def submit(self, mode, *, signal, frame=None):
            frames.append(frame)
            return True

        def close(self):
            pass

    def brightness(device):
        brightness_targets.append(device.device_id)
        return 51

    target = SimpleNamespace(
        settings=SimpleNamespace(colors=ColorSettings().with_mode_color("working", "#123456")),
        effective_brightness_for_device=brightness,
    )
    runtime = OptionalIntegrationRuntime(
        target,
        settings_loader=lambda: SimpleNamespace(
            creator_micro_enabled=True, creator_micro_device_serial="CM2",
        ),
        deck_settings_loader=DeckControlSettings,
        creator_service_factory=Service,
    )
    runtime.start()
    assert runtime.wait_until_configured(1)
    assert runtime.publish_creator_output(AgentMode.WORKING)
    runtime.close()
    assert brightness_targets == ["creator-micro"]
    assert frames[0].color == 0x123456
    assert frames[0].brightness == 0.2

    # --- scenario: a_retryable_connect_failure_keeps_its_reason_instead_of_a_bare_reconnecting
    """A pad the OS will not let us open never stops being retryable, so
    "reconnecting" is the only thing the owner would ever see. The receipt
    has to keep saying which refusal it is."""
    receipts = []

    class Adapter:
        conflict = SimpleNamespace(active=False)

        attempts = 0

        def connect(self):
            Adapter.attempts += 1
            return SimpleNamespace(
                code="input_monitoring_denied",
                detail="macOS Input Monitoring is denied for this process",
            )

        def close(self):
            pass

    published = threading.Event()

    def record(receipt):
        receipts.append(receipt)
        published.set()

    service = CreatorMicroOutputService(adapter_factory=Adapter, callback=record)
    service.start()
    assert published.wait(5), "the worker published nothing about a device it cannot open"
    assert receipts[0].reason == "input_monitoring_denied"
    assert "Input Monitoring" in receipts[0].detail
    assert receipts[0].available is False
    # The owner can lift this one while the daemon runs, so the worker must
    # still be trying rather than having given up on the pad.
    assert Adapter.attempts >= 1
    assert service._thread is not None and service._thread.is_alive()
    service.close()

    # --- scenario: a_missing_pad_still_reads_as_reconnecting_with_the_reason_kept
    """Nothing to connect to is the case "reconnecting" was written for; the
    exception's own words still travel, so the log is not silent."""
    receipts = []

    def factory():
        raise OSError("Creator Micro 2 not found")

    published = threading.Event()

    def record(receipt):
        receipts.append(receipt)
        published.set()

    service = CreatorMicroOutputService(adapter_factory=factory, callback=record)
    service.start()
    assert published.wait(5)
    service.close()
    assert receipts[0].reason == "reconnecting"
    assert receipts[0].detail == "Creator Micro 2 not found"



def test_a_pad_reply_error_retries_the_probe_instead_of_killing_the_worker__and_1_more() -> None:
    # --- scenario: negotiate_probe_failure_retries_with_backoff
    """A Malformed-request reply during negotiation used to exit the
    worker for the daemon's life; a pad mid-boot or mid-conflict is a
    transient like a lost transport and is retried on the same backoff."""
    calls, receipts = [], []
    ready = threading.Event()

    class Adapter:
        conflict = SimpleNamespace(active=False)
        connected = True

        def connect(self):
            calls.append("connect")
            return SimpleNamespace(code="connected", detail="")

        def negotiate_capabilities(self):
            calls.append("negotiate")
            if calls.count("negotiate") == 1:
                return SimpleNamespace(code="capability_probe_failed", detail="busy calibrating")
            ready.set()
            return SimpleNamespace(code="capabilities_negotiated", detail="v.oai.thstatus")

        def capabilities(self):
            return SimpleNamespace(methods=frozenset({"v.oai.thstatus"}))

        def apply(self, state):
            return SimpleNamespace(code="applied", detail="")

        def poll_inputs(self):
            return []

        def close(self):
            self.connected = False

    service = CreatorMicroOutputService(adapter_factory=Adapter, callback=receipts.append)
    service.start()
    try:
        assert ready.wait(6), receipts
        assert service._thread is not None and service._thread.is_alive()
    finally:
        service.close()
    assert calls.count("negotiate") >= 2
    assert any(receipt.reason == "capability_probe_failed" for receipt in receipts)

    # --- scenario: an_apply_rpc_error_is_survivable_too
    calls, receipts = [], []
    applied = threading.Event()

    class Adapter:
        conflict = SimpleNamespace(active=False)
        connected = True

        def connect(self):
            return SimpleNamespace(code="connected", detail="")

        def negotiate_capabilities(self):
            return SimpleNamespace(code="capabilities_negotiated", detail="v.oai.thstatus")

        def capabilities(self):
            return SimpleNamespace(methods=frozenset({"v.oai.thstatus"}))

        def apply(self, state):
            calls.append("apply")
            if calls.count("apply") == 1:
                return SimpleNamespace(code="rpc_error", detail="Malformed request")
            applied.set()
            return SimpleNamespace(code="applied", detail="")

        def poll_inputs(self):
            return []

        def close(self):
            self.connected = False

    service = CreatorMicroOutputService(adapter_factory=Adapter, callback=receipts.append)
    service.start()
    service.submit(AgentMode.WORKING)
    # Latest-wins: a second submit before the worker drains the first would
    # replace it, so the retry apply must wait for the rpc_error receipt to
    # prove the first attempt already happened.
    tick = threading.Event()
    deadline = time.monotonic() + 4
    while not any(receipt.reason == "rpc_error" for receipt in receipts) and time.monotonic() < deadline:
        tick.wait(0.01)
    service.submit(AgentMode.IDLE_READY)
    try:
        assert applied.wait(4), receipts
        assert service._thread is not None and service._thread.is_alive()
    finally:
        service.close()
    assert calls.count("apply") >= 2
    assert any(receipt.reason == "rpc_error" for receipt in receipts)


def test_apply_rpc_error_backoff_doubles_and_resets_on_a_successful_apply() -> None:
    """Three consecutive rpc_errors step the reconnect 1 -> 2 -> 4 s, the
    same growth a lost transport gets -- a pad that never takes a write is
    not a fresh 1 s loop forever. And the delay only resets once a write
    actually lands, not when the transport merely reconnects."""
    receipts = []
    connects: list[float] = []
    applies: list[float] = []
    healthy = threading.Event()
    fail_next = [True]

    class Adapter:
        conflict = SimpleNamespace(active=False)
        connected = True

        def connect(self):
            connects.append(time.monotonic())
            return SimpleNamespace(code="connected", detail="")

        def negotiate_capabilities(self):
            return SimpleNamespace(code="capabilities_negotiated", detail="v.oai.thstatus")

        def capabilities(self):
            return SimpleNamespace(methods=frozenset({"v.oai.thstatus"}))

        def apply(self, state):
            applies.append(time.monotonic())
            if fail_next[0]:
                return SimpleNamespace(code="rpc_error", detail="Malformed request")
            healthy.set()
            return SimpleNamespace(code="applied", detail="")

        def poll_inputs(self):
            return []

        def close(self):
            self.connected = False

    tick = threading.Event()

    def wait_for(predicate, timeout=20.0):
        deadline = time.monotonic() + timeout
        while not predicate() and time.monotonic() < deadline:
            tick.wait(0.01)
        assert predicate(), receipts

    service = CreatorMicroOutputService(adapter_factory=Adapter, callback=receipts.append)
    service.start()
    try:
        wait_for(lambda: len(connects) >= 1)
        # Each failed apply drops the adapter and the next connect lands
        # retry_delay later. A fresh submit per round dodges latest-wins.
        for round_ in range(3):
            service.submit(AgentMode.WORKING)
            wait_for(lambda r=round_: len(applies) > r)
            wait_for(lambda r=round_: len(connects) > r + 1)
        gaps = [connects[i + 1] - applies[i] for i in range(3)]
        assert 0.6 < gaps[0] < 1.8
        assert 1.5 < gaps[1] < 3.4
        assert 3.0 < gaps[2] < 6.0

        # A successful apply resets the backoff; a different mode dodges
        # the same-output dedupe so the next failure is a fresh rpc_error.
        fail_next[0] = False
        service.submit(AgentMode.WORKING)
        assert healthy.wait(10), receipts
        fail_next[0] = True
        service.submit(AgentMode.IDLE_READY)
        wait_for(lambda: len(applies) >= 5)
        # The successful apply did not reconnect, so the next connect is
        # index 4 -- and it lands ~1 s out because the backoff reset.
        wait_for(lambda: len(connects) >= 5)
        reset_gap = connects[4] - applies[4]
        assert 0.6 < reset_gap < 1.8
        assert service._thread is not None and service._thread.is_alive()
    finally:
        service.close()
