from __future__ import annotations

import threading
import time
from collections import deque

import pytest

from jrbar.creator_micro_adapter import (
    CreatorMicro2Adapter,
    CreatorMicro2Framer,
    DeviceCapability,
    DeviceConflict,
    RpcStreamDecoder,
    SemanticState,
)
from jrbar.creator_micro_hidapi import HidApiTransport, NoDeviceError

INFO = {"vendor_id": 0x303A, "product_id": 0x8297, "usage_page": 0xFF00, "usage": 1}


def rpc_result(ident: int, result=None) -> bytes:
    return b"".join(
        CreatorMicro2Framer.encode_message({"jsonrpc": "2.0", "id": ident, "result": {} if result is None else result})
    )


class FakeTransport:
    def __init__(self, reads=(), open_error=None):
        self.reads, self.open_error, self.writes = deque(reads), open_error, []
        self.opened = self.closed = False
        self.opens = self.closes = 0

    def open(self, *, nonexclusive=True):
        assert nonexclusive
        if self.open_error:
            raise self.open_error
        self.opened = True
        self.opens += 1

    def write(self, report):
        self.writes.append(report)

    def read(self, *, timeout_ms):
        assert 0 <= timeout_ms <= 8_000
        return self.reads.popleft() if self.reads else None

    def close(self):
        self.closed = True
        self.closes += 1


def test_frames_every_fragment_and_reassembles_split_and_concatenated_messages__and_2_more() -> None:
    # --- scenario: frames_every_fragment_and_reassembles_split_and_concatenated_messages
    message = {"jsonrpc": "2.0", "method": "x" * 150, "params": {"text": 'a } \\" { b'}, "id": 7}
    reports = CreatorMicro2Framer.encode_request(message)
    assert len(reports) >= 3
    assert all(len(report) == 64 and report[0:2] == b"\x06\x02" for report in reports)
    decoder, out = RpcStreamDecoder(), []
    for report in reports:
        out.extend(decoder.feed(report))
    out.extend(decoder.feed(rpc_result(8)[1:]))
    assert out == [message, {"jsonrpc": "2.0", "id": 8, "result": {}}]

    # --- scenario: request_envelope_is_strict
    for message in [
        {"method": "x", "id": 1},
        {"jsonrpc": "1.0", "method": "x", "id": 1},
        {"jsonrpc": "2.0", "method": "x"},
        {"jsonrpc": "2.0", "method": "x", "id": True},
        {"jsonrpc": "2.0", "method": "x", "id": 1000},
    ]:
        with pytest.raises(ValueError):
            CreatorMicro2Framer.encode_request(message)

    # --- scenario: decoder_rejects_malformed_reports_and_envelopes_without_retaining_fragments
    decoder = RpcStreamDecoder()
    with pytest.raises(ValueError, match="length"):
        decoder.feed(bytes((6, 2, 62)) + bytes(61))
    with pytest.raises(ValueError, match="JSON-RPC"):
        payload = b'{"id":1,"unknown":{}}'
        decoder.feed(bytes((6, 2, len(payload))) + payload.ljust(61, b"\0"))
    assert decoder.pending_bytes == 0



def test_decoder_routes_a_null_id_push_as_a_notification__and_2_more() -> None:
    # --- scenario: decoder_routes_a_null_id_push_as_a_notification
    """The live pad's unsolicited pushes carry ``"id": null`` (JSON-RPC
    allows it); that is nobody's answer, so it must flow as a notification
    instead of failing the stream as a malformed response."""
    decoder = RpcStreamDecoder()
    payload = b'{"id":null,"m":"v.oai.hid","p":{"k":"AG03","act":1}}'
    messages = decoder.feed(bytes((6, 2, len(payload))) + payload.ljust(61, b"\0"))
    assert messages == [{"m": "v.oai.hid", "p": {"k": "AG03", "act": 1}}]
    with pytest.raises(ValueError, match=r"response id \(str\)"):
        bad = b'{"id":"abc","result":{}}'
        decoder.feed(bytes((6, 2, len(bad))) + bad.ljust(61, b"\0"))

    # --- scenario: incoming_envelopes_reject_ambiguous_or_extra_fields
    ambiguous = {"jsonrpc": "2.0", "id": 1, "result": {}, "method": "also-a-response", "params": {}}
    wrong_version = {"jsonrpc": "1.0", "m": "v.oai.hid", "p": {}}
    for message in (ambiguous, wrong_version):
        with pytest.raises(ValueError):
            CreatorMicro2Framer.validate_incoming(message)
    # A notification carries whatever the firmware attaches: extra keys pass.
    CreatorMicro2Framer.validate_incoming({"jsonrpc": "2.0", "m": "v.oai.hid", "p": {}, "extra": True})
    # A response with extra fields is still refused: correlation stays strict.
    with pytest.raises(ValueError):
        CreatorMicro2Framer.validate_incoming({"jsonrpc": "2.0", "id": 1, "result": {}, "extra": True})

    # --- scenario: notification_without_params_is_accepted
    CreatorMicro2Framer.validate_incoming({"m": "v.oai.hid"})
    CreatorMicro2Framer.validate_incoming({"jsonrpc": "2.0", "method": "v.oai.hid"})
    CreatorMicro2Framer.validate_incoming({"m": "v.oai.hid", "params": {"k": "AG03"}})



def test_notification_with_extra_keys_is_queued_under_extra__and_2_more() -> None:
    # --- scenario: notification_with_extra_keys_is_queued_under_extra
    payload = b'{"m":"v.oai.hid","p":{"k":"AG03","act":1},"fw":7,"seq":2}'
    report = bytes((6, 2, len(payload))) + payload.ljust(61, b"\0")
    transport = FakeTransport([report])
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    assert adapter.poll_inputs() == [
        {"method": "v.oai.hid", "params": {"k": "AG03", "act": 1}, "extra": {"fw": 7, "seq": 2}}
    ]

    # --- scenario: notification_with_conflicting_method_keys_is_rejected_with_keys_named
    message = {"m": "v.oai.hid", "method": "v.oai.other", "p": {}}
    with pytest.raises(ValueError) as excinfo:
        CreatorMicro2Framer.validate_incoming(message)
    detail = str(excinfo.value)
    assert "conflicting" in detail and "'m'" in detail and "'method'" in detail
    # The recorded detail also carries a bounded slice of what the pad sent.
    assert "v.oai.hid" in detail

    # --- scenario: bad_notification_in_the_same_report_as_a_response_neither_disconnects_nor_loses_it
    payload = b'{"m":5,"p":{}}' + b'{"id":1,"result":{"ok":1}}'
    fragments = [payload[index:index + 61] for index in range(0, len(payload), 61)]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    transport.reads.extend(
        bytes((6, 2, len(part))) + part.ljust(61, b"\0") for part in fragments
    )

    receipt, response = adapter._call("device.status", None)

    assert receipt.code == "applied"
    assert response == {"id": 1, "result": {"ok": 1}}
    assert adapter.connected and not transport.closed
    assert adapter.last_malformed_notification
    assert "keys:" in adapter.last_malformed_notification



def test_poll_inputs_skips_a_malformed_notification_and_keeps_the_transport__and_2_more() -> None:
    # --- scenario: poll_inputs_skips_a_malformed_notification_and_keeps_the_transport
    def report(payload):
        return bytes((6, 2, len(payload))) + payload.ljust(61, b"\0")

    transport = FakeTransport([
        report(b'{"m":5,"p":{}}'),
        report(b'{"m":"v.oai.hid","p":{"k":"AG03","act":1}}'),
    ])
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    assert adapter.poll_inputs() == [{"method": "v.oai.hid", "params": {"k": "AG03", "act": 1}}]
    assert adapter.connected and not transport.closed
    assert adapter.last_malformed_notification

    # --- scenario: vendor_envelopes_without_a_jsonrpc_field_deliver_responses_and_key_presses
    def report(payload):
        return bytes((6, 2, len(payload))) + payload.ljust(61, b"\0")

    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO, capabilities=DeviceCapability.from_methods(["v.oai.thstatus"]))
    adapter.connect()
    transport.reads.extend([
        report(b'{"m":"v.oai.hid","p":{"k":"AG03","act":1}}'),
        report(b'{"id":1,"method":"v.oai.thstatus","params":{"ok":1}}'),
    ])
    assert adapter.apply(SemanticState.ACTIVE).code == "applied"
    assert adapter.poll_inputs() == [{"method": "v.oai.hid", "params": {"k": "AG03", "act": 1}}]

    # --- scenario: device_status_result_with_echoed_method_is_accepted
    payload = (
        b'{"id":1,"method":"device.status","result":'
        b'{"version":"v0.6.1","layer_index":1,"profile_index":0}}'
    )
    parts = [payload[index:index + 61] for index in range(0, len(payload), 61)]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO)
    assert adapter.connect().code == "connected"
    transport.reads.extend(
        bytes((6, 2, len(part))) + part.ljust(61, b"\0") for part in parts
    )

    receipt, response = adapter._call("device.status", None)

    assert receipt.code == "applied"
    assert response["result"] == {
        "version": "v0.6.1", "layer_index": 1, "profile_index": 0,
    }



def test_echoed_result_for_another_method_is_refused_and_disconnects__and_2_more() -> None:
    # --- scenario: echoed_result_for_another_method_is_refused_and_disconnects
    payload = b'{"id":1,"method":"fs.read","result":{}}'
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    transport.reads.append(bytes((6, 2, len(payload))) + payload.ljust(61, b"\0"))

    receipt, response = adapter._call("device.status", None)

    assert receipt.code == "malformed_report"
    assert response is None
    assert transport.closed and not adapter.connected

    # --- scenario: echoed_result_does_not_accept_ambiguous_or_extra_fields
    for extra in [{"params": {}}, {"error": {}}, {"extra": True}]:
        with pytest.raises(ValueError, match="response"):
            CreatorMicro2Framer.validate_incoming({
                "id": 1, "method": "device.status", "result": {}, **extra,
            })

    # --- scenario: key_notification_after_a_response_in_the_same_report_is_not_lost
    payload = b'{"id":1,"result":"' + b"x" * 50 + b'"}'
    payload += b'{"m":"v.oai.hid","p":{"k":"AG03","act":1}}'
    fragments = [payload[index:index + 61] for index in range(0, len(payload), 61)]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO, capabilities=DeviceCapability.from_methods(["v.oai.thstatus"]))
    adapter.connect()
    transport.reads.extend(bytes((6, 2, len(part))) + part.ljust(61, b"\0") for part in fragments)
    assert adapter.apply(SemanticState.ACTIVE).code == "applied"
    assert adapter.poll_inputs() == [{"method": "v.oai.hid", "params": {"k": "AG03", "act": 1}}]



def test_discovery_is_exact_and_has_no_transport_side_effects__and_2_more() -> None:
    # --- scenario: discovery_is_exact_and_has_no_transport_side_effects
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO)
    assert adapter.discover() and not CreatorMicro2Framer.discover({**INFO, "usage": 6})
    assert not transport.opened and transport.writes == []

    # --- scenario: connect_returns_explicit_no_device_permission_and_unavailable_receipts
    assert CreatorMicro2Adapter(FakeTransport(), {**INFO, "product_id": 1}).connect().code == "no_device"
    assert CreatorMicro2Adapter(FakeTransport(open_error=NoDeviceError()), INFO).connect().code == "no_device"
    assert CreatorMicro2Adapter(FakeTransport(open_error=PermissionError()), INFO).connect().code == "permission_denied"
    assert (
        CreatorMicro2Adapter(FakeTransport(open_error=OSError("backend gone")), INFO).connect().code
        == "transport_unavailable"
    )

    # --- scenario: apply_writes_all_fragments_and_correlates_response
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO, capabilities=DeviceCapability.from_methods(["v.oai.thstatus"]))
    assert adapter.connect().code == "connected"
    transport.reads.append(rpc_result(1))
    params = [{"id": i, "c": 0x123456, "b": 1, "e": 1, "s": 0.5} for i in range(13)]
    assert adapter.apply(SemanticState.INPUT_REQUIRED, params).code == "applied"
    assert len(transport.writes) > 1
    decoder = RpcStreamDecoder()
    decoded = (message for report in transport.writes for message in decoder.feed(report))
    assert next(decoded)["params"] == params



def test_default_state_output_sets_explicit_lighting_instead_of_only_an_id__and_2_more() -> None:
    # --- scenario: default_state_output_sets_explicit_lighting_instead_of_only_an_id
    for state in list(SemanticState):
        transport = FakeTransport()
        adapter = CreatorMicro2Adapter(
            transport, INFO, capabilities=DeviceCapability.from_methods(["v.oai.thstatus"])
        )
        adapter.connect()
        transport.reads.append(rpc_result(1))
        assert adapter.apply(state).code == "applied"
        decoder = RpcStreamDecoder()
        request = next(message for report in transport.writes for message in decoder.feed(report))
        assert request["method"] == "v.oai.thstatus"
        assert len(request["params"]) == 20
        assert [item["id"] for item in request["params"]] == list(range(20))
        assert all({"c", "b", "e", "s", "sk", "sa"} <= set(item) for item in request["params"])
        if state is SemanticState.IDLE:
            assert all(item["b"] == 0 and item["e"] == 0 for item in request["params"])
        else:
            assert all(item["b"] > 0 and item["e"] > 0 and item["c"] > 0 for item in request["params"])

    # --- scenario: notifications_survive_fragmentation_while_waiting_for_response
    note = {"jsonrpc": "2.0", "m": "v.oai.hid", "p": {"k": "AG01", "act": 1}}
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO, capabilities=DeviceCapability.from_methods(["v.oai.thstatus"]))
    adapter.connect()
    transport.reads.extend([*CreatorMicro2Framer.encode_message(note), rpc_result(1)])
    assert adapter.apply(SemanticState.ACTIVE, [{"id": 1}]).code == "applied"
    assert adapter.poll_inputs() == [{"method": "v.oai.hid", "params": {"k": "AG01", "act": 1}}]

    # --- scenario: input_poll_has_a_report_budget_and_preserves_remaining_input
    note = {"jsonrpc": "2.0", "m": "v.oai.hid", "p": {"k": "AG01", "act": 1}}
    reports = CreatorMicro2Framer.encode_message(note)
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    transport.reads.extend(reports * 200)
    first = adapter.poll_inputs()
    assert 0 < len(first) < 200
    assert transport.reads
    received = len(first)
    while transport.reads:
        received += len(adapter.poll_inputs())
    assert received == 200



def test_input_conflict_discards_notifications_from_the_contested_batch__and_2_more() -> None:
    # --- scenario: input_conflict_discards_notifications_from_the_contested_batch
    note = {"jsonrpc": "2.0", "m": "v.oai.hid", "p": {"k": "AG01", "act": 1}}
    now = [10.0]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO, clock=lambda: now[0])
    adapter.connect()
    now[0] += adapter.STARTUP_GRACE_SECONDS + 1
    transport.reads.extend([*CreatorMicro2Framer.encode_message(note), rpc_result(999)])
    assert adapter.poll_inputs() == []
    assert adapter.conflict.active

    # --- scenario: disconnect_discards_queued_input_instead_of_replaying_it_on_reconnect
    note = {"jsonrpc": "2.0", "m": "v.oai.hid", "p": {"k": "AG01", "act": 1}}
    transport = FakeTransport(CreatorMicro2Framer.encode_message(note))
    adapter = CreatorMicro2Adapter(
        transport, INFO, capabilities=DeviceCapability.from_methods(["v.oai.thstatus"])
    )
    adapter.connect()
    assert adapter.apply(SemanticState.ACTIVE).code == "timeout"
    assert adapter.poll_inputs() == []

    # --- scenario: foreign_response_activates_single_writer_stop_and_closes_safely
    now = [10.0]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(
        transport, INFO, capabilities=DeviceCapability.from_methods(["v.oai.thstatus"]),
        clock=lambda: now[0],
    )
    adapter.connect()
    now[0] += adapter.STARTUP_GRACE_SECONDS + 1
    transport.reads.extend([rpc_result(999), rpc_result(1)])
    assert adapter.apply(SemanticState.ACTIVE, [{"id": 1}]).code == "device_conflict"
    before = len(transport.writes)
    assert adapter.apply(SemanticState.IDLE).code == "device_conflict"
    assert len(transport.writes) == before
    adapter.close()
    adapter.close()
    assert transport.closed and not adapter.connected



def test_timeout_disconnects_and_next_connect_honours_backoff__and_2_more() -> None:
    # --- scenario: timeout_disconnects_and_next_connect_honours_backoff
    now = [10.0]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(
        transport,
        INFO,
        capabilities=DeviceCapability.from_methods(["v.oai.thstatus"]),
        clock=lambda: now[0],
        rpc_timeout_ms=1,
        reconnect_backoff_s=5,
    )
    adapter.connect()
    assert adapter.apply(SemanticState.ACTIVE, [{"id": 1}]).code == "timeout"
    assert adapter.connect().code == "backoff"
    now[0] += 5
    assert adapter.connect().code == "connected"

    # --- scenario: a_late_reply_to_a_timed_out_call_is_never_a_conflict
    """The pad answering after our timeout is our own reply arriving late,
    not a second controller — same connection AND across a reconnect."""
    now = [10.0]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(
        transport,
        INFO,
        capabilities=DeviceCapability.from_methods(["v.oai.thstatus"]),
        clock=lambda: now[0],
        rpc_timeout_ms=1,
        reconnect_backoff_s=0,
    )
    adapter.connect()
    now[0] += adapter.STARTUP_GRACE_SECONDS + 1
    assert adapter.apply(SemanticState.ACTIVE, [{"id": 1}]).code == "timeout"
    adapter.close()
    adapter.connect()
    # The timed-out call's reply lands while the NEXT call waits — ours.
    transport.reads.extend([rpc_result(1), rpc_result(2)])
    now[0] += adapter.STARTUP_GRACE_SECONDS + 1
    assert adapter.apply(SemanticState.IDLE, [{"id": 2}]).code == "applied"
    assert not adapter.conflict.active

    # --- scenario: an_id_we_never_issued_is_still_a_conflict_past_the_grace
    now = [10.0]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(
        transport,
        INFO,
        capabilities=DeviceCapability.from_methods(["v.oai.thstatus"]),
        clock=lambda: now[0],
    )
    adapter.connect()
    now[0] += adapter.STARTUP_GRACE_SECONDS + 1
    transport.reads.extend([rpc_result(77), rpc_result(1)])
    assert adapter.apply(SemanticState.ACTIVE, [{"id": 1}]).code == "device_conflict"
    assert adapter.conflict.active



def test_capability_probe_is_opt_in_and_falls_back_honestly_on_method_not_found__and_1_more() -> None:
    # --- scenario: capability_probe_is_opt_in_and_falls_back_honestly_on_method_not_found
    error = {"jsonrpc": "2.0", "id": 1, "error": {"code": -32601, "message": "Method not found"}}
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    transport.reads.extend([*CreatorMicro2Framer.encode_message(error), rpc_result(2)])
    assert transport.writes == []
    assert adapter.negotiate_capabilities().code == "capabilities_negotiated"
    assert adapter.capabilities().methods == frozenset({"lights.preview"})

    # --- scenario: semantic_priority_is_explicit_and_user_priority_is_exact
    assert SemanticState.INPUT_REQUIRED.priority == 800
    assert SemanticState.FAILURE.priority == 700
    assert SemanticState.IDLE.priority == 100



def test_hidapi_transport_is_injectable_read_only_until_opt_in_and_uses_timeout_contract__and_1_more(monkeypatch) -> None:
    # --- scenario: hidapi_transport_is_injectable_read_only_until_opt_in_and_uses_timeout_contract
    monkeypatch.setattr("jrbar.creator_micro_hidapi._enable_macos_nonexclusive", lambda _: None)
    class Device:
        def open_path(self, path):
            self.path = path

        def set_nonblocking(self, value):
            assert value is True

        def write(self, report):
            self.report = report
            return len(report)

        def read(self, size, timeout):
            self.read_args = (size, timeout)
            return [6, 2, 0] + [0] * 61

        def close(self):
            self.closed = True

    device = Device()

    class Hid:
        def enumerate(self, vendor):
            return [{**INFO, "path": b"x", "serial_number": "CM2-123"}]

        def device(self):
            return device

    transport = HidApiTransport(Hid(), approved_serial="CM2-123")
    assert transport.enumerate() and not hasattr(device, "report")
    transport.open()
    with pytest.raises(PermissionError):
        transport.write(b"x")
    transport.enable_writes()
    transport.write(b"x")
    transport.read(timeout_ms=321)
    assert device.read_args == (64, 321)
    transport.close()

    # --- scenario: hidapi_output_requires_one_approved_stable_device_identity
    monkeypatch.undo()
    monkeypatch.setattr("jrbar.creator_micro_hidapi._enable_macos_nonexclusive", lambda _: None)
    opened = []

    class Device:
        def open_path(self, path):
            opened.append(path)

        def set_nonblocking(self, value):
            assert value is True

        def close(self):
            pass

    class Hid:
        def enumerate(self, vendor):
            assert vendor == INFO["vendor_id"]
            return [
                {**INFO, "path": b"spoof", "serial_number": "other-device"},
                {**INFO, "path": b"approved", "serial_number": "CM2-123"},
            ]

        def device(self):
            return Device()

    with pytest.raises(PermissionError, match="approved device identity"):
        HidApiTransport(Hid()).open()

    transport = HidApiTransport(Hid(), approved_serial="CM2-123")
    assert [row["path"] for row in transport.enumerate()] == [b"approved"]
    transport.open()
    assert opened == [b"approved"]



def test_hidapi_output_rejects_ambiguous_or_identityless_matches__and_2_more() -> None:
    # --- scenario: hidapi_output_rejects_ambiguous_or_identityless_matches
    class Hid:
        def __init__(self, rows):
            self.rows = rows

        def enumerate(self, _vendor):
            return self.rows

        def device(self):
            raise AssertionError("ambiguous or identityless device was opened")

    with pytest.raises(PermissionError, match="stable serial"):
        HidApiTransport(
            Hid([{**INFO, "path": b"identityless"}]),
            approved_serial="CM2-123",
        ).open()

    with pytest.raises(PermissionError, match="ambiguous"):
        HidApiTransport(
            Hid(
                [
                    {**INFO, "path": b"one", "serial_number": "CM2-123"},
                    {**INFO, "path": b"two", "serial_number": "CM2-123"},
                ]
            ),
            approved_serial="CM2-123",
        ).open()

    # --- scenario: conflict_only_accepts_integer_ids_issued_by_this_adapter
    conflict = DeviceConflict({42})
    assert conflict.observe(42) is None
    assert conflict.observe("42") == "foreign_response_id"

    # --- scenario: a_refused_open_reports_its_code_and_its_own_words
    """The caller only ever sees the receipt, so a refusal that does not
    carry its reason is indistinguishable from a pad that is not there."""
    from jrbar.creator_micro_hidapi import DeviceAccessError

    denied = DeviceAccessError("input_monitoring_denied", "macOS Input Monitoring is denied for this process")
    receipt = CreatorMicro2Adapter(FakeTransport(open_error=denied), INFO).connect()
    assert receipt.code == "input_monitoring_denied"
    assert receipt.detail == "macOS Input Monitoring is denied for this process"
    # A refusal with nothing to say still gets a sentence.
    assert CreatorMicro2Adapter(FakeTransport(open_error=PermissionError()), INFO).connect().detail



def test_our_own_answer_arriving_twice_is_not_another_controller__and_2_more() -> None:
    # --- scenario: our_own_answer_arriving_twice_is_not_another_controller
    """Observed on the real pad over Bluetooth: a completed request is
    answered again, and the old rule read that echo as a second controller
    and stopped output for good on a pad nobody else was touching."""
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO, capabilities=DeviceCapability.from_methods({"v.oai.thstatus"}))
    assert adapter.connect().code == "connected"
    transport.reads.extend([rpc_result(1), rpc_result(1), rpc_result(2)])
    assert adapter.apply(SemanticState.ACTIVE).code == "applied"
    # The echo of id 1 is skipped; the answer to id 2 still lands.
    assert adapter.apply(SemanticState.IDLE).code == "applied"
    assert adapter.conflict.active is False

    # --- scenario: an_id_we_never_issued_is_still_a_conflict
    """The only evidence of a second owner there is must keep working — once
    the startup grace has elapsed a genuinely foreign id still stops output."""
    now = [10.0]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(
        transport, INFO, capabilities=DeviceCapability.from_methods({"v.oai.thstatus"}),
        clock=lambda: now[0],
    )
    adapter.connect()
    now[0] += adapter.STARTUP_GRACE_SECONDS + 1
    transport.reads.append(rpc_result(742))
    receipt = adapter.apply(SemanticState.ACTIVE)
    assert receipt.code == "device_conflict" and receipt.recoverable is False
    assert adapter.conflict.active is True
    assert adapter.conflict.since == now[0]

    # --- scenario: a_reconnect_forgets_the_ids_of_the_previous_connection
    """A new connection starts its ids again, so last connection's echoes
    must not excuse a genuinely foreign response on this one."""
    from jrbar.creator_micro_adapter import DeviceConflict

    conflict = DeviceConflict()
    conflict.issued_ids.add(5)
    assert conflict.observe(5) is None
    assert conflict.observe(5) == "duplicate_response_id"
    conflict.reset()
    assert conflict.observe(5) == "foreign_response_id"
    assert conflict.active is True



def test_polling_ignores_our_own_echo_instead_of_dropping_the_connection__and_2_more() -> None:
    # --- scenario: polling_ignores_our_own_echo_instead_of_dropping_the_connection
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(transport, INFO, capabilities=DeviceCapability.from_methods({"v.oai.thstatus"}))
    adapter.connect()
    transport.reads.append(rpc_result(1))
    assert adapter.apply(SemanticState.ACTIVE).code == "applied"
    transport.reads.extend([rpc_result(1)])
    assert adapter.poll_inputs() == []
    assert adapter.conflict.active is False and adapter.connected is True

    # --- scenario: a_reply_queued_before_connect_is_drained_not_accused
    """The previous daemon process can leave a request in flight whose late
    reply lands after the restart carrying an id this process never issued.
    It must be discarded at connect rather than read as a second controller."""
    transport = FakeTransport([rpc_result(742)])
    adapter = CreatorMicro2Adapter(
        transport, INFO, capabilities=DeviceCapability.from_methods({"v.oai.thstatus"})
    )
    assert adapter.connect().code == "connected"
    assert adapter.conflict.active is False
    assert adapter.stale_replies_drained == 1
    transport.reads.append(rpc_result(1))
    assert adapter.apply(SemanticState.ACTIVE).code == "applied"
    assert adapter.conflict.active is False

    # --- scenario: the_connect_drain_keeps_notifications_but_drops_id_bearing_replies
    note = {"jsonrpc": "2.0", "m": "v.oai.hid", "p": {"k": "AG01", "act": 1}}
    transport = FakeTransport([*CreatorMicro2Framer.encode_message(note), rpc_result(999)])
    adapter = CreatorMicro2Adapter(transport, INFO)
    assert adapter.connect().code == "connected"
    assert adapter.stale_replies_drained == 1
    assert adapter.poll_inputs() == [{"method": "v.oai.hid", "params": {"k": "AG01", "act": 1}}]
    assert adapter.conflict.active is False



def test_a_foreign_id_inside_the_startup_grace_is_a_stale_reply_not_a_conflict__and_2_more() -> None:
    # --- scenario: a_foreign_id_inside_the_startup_grace_is_a_stale_reply_not_a_conflict
    """Right after connect a foreign id can still be a stale answer to the
    previous process's request; the call keeps waiting and a later valid
    response applies."""
    now = [10.0]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(
        transport, INFO, capabilities=DeviceCapability.from_methods({"v.oai.thstatus"}),
        clock=lambda: now[0],
    )
    adapter.connect()
    transport.reads.extend([rpc_result(742), rpc_result(1)])
    assert adapter.apply(SemanticState.ACTIVE).code == "applied"
    assert adapter.conflict.active is False
    assert adapter.stale_replies_ignored == 1

    # --- scenario: a_conflict_retries_the_connection_after_its_delay
    """The accusation is not a lifetime sentence: once the retry delay
    measured from when the conflict began elapses, the adapter closes and
    reconnects, which resets the conflict."""
    now = [10.0]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(
        transport, INFO, capabilities=DeviceCapability.from_methods({"v.oai.thstatus"}),
        clock=lambda: now[0],
    )
    adapter.connect()
    now[0] += adapter.STARTUP_GRACE_SECONDS + 1
    transport.reads.append(rpc_result(742))
    assert adapter.apply(SemanticState.ACTIVE).code == "device_conflict"
    # Before the delay the accusation stays and nothing is reopened.
    now[0] += adapter.CONFLICT_RETRY_SECONDS - 1
    assert adapter.recover_conflict().code == "device_conflict"
    assert transport.opens == 1 and adapter.conflict.active
    now[0] += 1
    assert adapter.recover_conflict().code == "connected"
    assert transport.opens == 2 and adapter.conflict.active is False
    transport.reads.append(rpc_result(2))
    assert adapter.apply(SemanticState.ACTIVE).code == "applied"

    # --- scenario: a_conflict_retriggering_three_times_backs_off_to_the_long_delay
    now = [10.0]
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(
        transport, INFO, capabilities=DeviceCapability.from_methods({"v.oai.thstatus"}),
        clock=lambda: now[0],
    )
    adapter.connect()
    for _ in range(2):
        now[0] += adapter.STARTUP_GRACE_SECONDS + 1
        transport.reads.append(rpc_result(742))
        assert adapter.apply(SemanticState.ACTIVE).code == "device_conflict"
        now[0] += adapter.CONFLICT_RETRY_SECONDS
        assert adapter.recover_conflict().code == "connected"
    # The third consecutive conflict backs off to the long delay.
    now[0] += adapter.STARTUP_GRACE_SECONDS + 1
    transport.reads.append(rpc_result(742))
    assert adapter.apply(SemanticState.ACTIVE).code == "device_conflict"
    now[0] += adapter.CONFLICT_RETRY_SECONDS
    assert adapter.recover_conflict().code == "device_conflict"
    now[0] += adapter.CONFLICT_RETRY_BACKOFF_SECONDS - adapter.CONFLICT_RETRY_SECONDS
    assert adapter.recover_conflict().code == "connected"



def test_a_late_answer_to_an_earlier_request_of_ours_is_not_a_conflict__and_1_more() -> None:
    # --- scenario: a_late_answer_to_an_earlier_request_of_ours_is_not_a_conflict
    """Over Bluetooth the pad can answer out of order: a reply to an id we
    issued for an earlier call is retired and the call keeps waiting for its
    own answer instead of accusing a second controller."""
    transport = FakeTransport()
    adapter = CreatorMicro2Adapter(
        transport, INFO, capabilities=DeviceCapability.from_methods({"v.oai.thstatus"})
    )
    adapter.connect()
    adapter.conflict.issued_ids.add(9)  # an earlier request still in flight
    transport.reads.extend([rpc_result(9), rpc_result(1)])
    assert adapter.apply(SemanticState.ACTIVE).code == "applied"
    assert adapter.conflict.active is False
    assert 9 in adapter.conflict.completed_ids

    # --- scenario: the_output_service_retries_a_conflict_instead_of_stopping_for_good
    """The worker used to publish ``device_conflict`` and exit for the
    daemon's life. Now the receipt stays visible while the adapter waits out
    its retry delay, then the same pad is reconnected and output resumes."""
    from jrbar.optional_integration_runtime import CreatorMicroOutputService

    now = [10.0]

    class Loopback:
        def __init__(self):
            self.reads = deque()
            self.decoder = RpcStreamDecoder()
            self.opens = 0

        def open(self, **_kwargs):
            self.opens += 1

        def write(self, report):
            for message in self.decoder.feed(report):
                self.reads.extend(CreatorMicro2Framer.encode_message(
                    {"jsonrpc": "2.0", "id": message["id"], "result": {"ok": 1}}
                ))

        def read(self, *, timeout_ms=0):
            return self.reads.popleft() if self.reads else None

        def close(self):
            pass

    transport = Loopback()
    adapter = CreatorMicro2Adapter(transport, INFO, clock=lambda: now[0])
    receipts, published = [], threading.Event()

    def record(receipt):
        receipts.append(receipt.reason)
        published.set()

    def wait_for(reason, count=1, timeout=4.0):
        deadline = time.monotonic() + timeout
        while receipts.count(reason) < count and time.monotonic() < deadline:
            published.wait(0.05)
        assert receipts.count(reason) >= count, receipts

    service = CreatorMicroOutputService(adapter_factory=lambda: adapter, callback=record)
    try:
        service.start()
        wait_for("ready")
        now[0] += adapter.STARTUP_GRACE_SECONDS + 1
        transport.reads.append(rpc_result(999))
        wait_for("device_conflict")
        # The worker is still alive and holding the conflict receipt.
        assert service._thread is not None and service._thread.is_alive()
        now[0] += adapter.CONFLICT_RETRY_SECONDS
        wait_for("ready", count=2)
        assert transport.opens == 2
        assert adapter.conflict.active is False
    finally:
        service.close()

