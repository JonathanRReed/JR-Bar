"""Wire/backend conformance regressions, independent of the production encoder.

No device is opened. FakeHidDevice models cython-hidapi's timeout=0 behavior;
WouldBlock deliberately fails fast instead of hanging a test worker.
"""
from __future__ import annotations

import json
from collections import deque

import pytest

from jrbar.creator_micro_adapter import (
    CreatorMicro2Adapter,
    CreatorMicro2Framer,
    RpcStreamDecoder,
)
from jrbar.creator_micro_hidapi import HidApiTransport, NoDeviceError

INFO = {"vendor_id": 0x303A, "product_id": 0x8298, "usage_page": 0xFF00, "usage": 1}
SERIAL = "CM2-CONFORMANCE-FIXTURE"


def raw_reports(document: dict, *, include_report_id: bool = True) -> list[bytes]:
    """Build incoming packets without calling any JR-Bar framing helper."""
    payload = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode() + b"\r\n"
    parts = [payload[i:i + 61] for i in range(0, len(payload), 61)]
    reports = [bytes((6, 2, len(part))) + part.ljust(61, b"\0") for part in parts]
    return reports if include_report_id else [report[1:] for report in reports]


def wire_payload(reports: list[bytes]) -> bytes:
    for report in reports:
        assert len(report) == 64
        assert report[:2] == b"\x06\x02"
        assert 1 <= report[2] <= 61
        assert report[3 + report[2]:] == bytes(61 - report[2])
    return b"".join(report[3:3 + report[2]] for report in reports)


def test_request_uses_crlf_boundaries_on_the_actual_wire__and_2_more() -> None:
    # --- scenario: request_uses_crlf_boundaries_on_the_actual_wire
    for text in ["", "x" * 200, "🙂é" * 50, 'line\nquote"brace}\\']:
        request = {"jsonrpc": "2.0", "method": "device.status", "params": {"text": text}, "id": 1}
        payload = wire_payload(CreatorMicro2Framer.encode_request(request))
        expected = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode()
        assert payload == b"\r\n" + expected + b"\r\n"

    # --- scenario: request_wire_boundaries_are_included_in_the_byte_budget
    request = {"jsonrpc": "2.0", "method": "x", "params": None, "id": 1}
    size = len(json.dumps(request, separators=(",", ":")).encode())
    with pytest.raises(ValueError, match="report limit"):
        CreatorMicro2Framer.encode_request(request, max_bytes=size + 3)
    assert len(wire_payload(CreatorMicro2Framer.encode_request(request, max_bytes=size + 4))) == size + 4

    # --- scenario: framed_requests_still_decode_across_fragment_boundaries
    for size in [0, 1, 59, 60, 61, 62, 120, 121, 122, 123, 700]:
        request = {"jsonrpc": "2.0", "method": "x", "params": {"text": "x" * size}, "id": 7}
        decoder = RpcStreamDecoder()
        received = [item for report in CreatorMicro2Framer.encode_request(request) for item in decoder.feed(report)]
        assert received == [request]
        assert decoder.pending_bytes == 0



def test_method_tagged_firmware_error_decodes_without_weakening_validation__and_1_more() -> None:
    # --- scenario: method_tagged_firmware_error_decodes_without_weakening_validation
    for report_id in [True, False]:
        for code in [-32601, 404, -32602]:
            response = {"id": 1, "method": "device.status", "error": {"code": code, "message": "test error"}}
            decoder = RpcStreamDecoder()
            received = [item for report in raw_reports(response, include_report_id=report_id) for item in decoder.feed(report)]
            assert received == [response]
            assert decoder.pending_bytes == 0

    # --- scenario: malformed_or_ambiguous_firmware_errors_remain_rejected
    for changes in [
    {"error": "not an object"}, {"result": {}}, {"params": {}},
    {"extra": 1}, {"id": True}, {"id": 1000}, {"method": None},
]:
        response = {"id": 1, "method": "device.status", "error": {"code": 404}, **changes}
        with pytest.raises(ValueError):
            CreatorMicro2Framer.validate_incoming(response)



class ScriptedTransport:
    def __init__(self, replies=()):
        self.replies = deque(replies)
        self.writes = []
        self.closed = False

    def open(self, *, nonexclusive=True):
        assert nonexclusive

    def write(self, report):
        self.writes.append(report)

    def read(self, *, timeout_ms):
        return self.replies.popleft() if self.replies else None

    def close(self):
        self.closed = True


def test_adapter_reports_firmware_error_instead_of_malformed_wire__and_2_more() -> None:
    # --- scenario: adapter_reports_firmware_error_instead_of_malformed_wire
    response = {"id": 1, "method": "device.status", "error": {"code": 404, "message": "not found"}}
    transport = ScriptedTransport()
    adapter = CreatorMicro2Adapter(transport, INFO)
    assert adapter.connect().code == "connected"
    # Replies queued before connect are drained as stale; deliver this one live.
    transport.replies.extend(raw_reports(response))
    receipt, actual = adapter._call("device.status", None)
    assert receipt.code == "rpc_error"
    assert actual == response
    assert adapter.connected

    # --- scenario: method_mismatch_still_disconnects
    response = {"id": 1, "method": "fs.read", "error": {"code": 404}}
    transport = ScriptedTransport()
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    transport.replies.extend(raw_reports(response))
    receipt, actual = adapter._call("device.status", None)
    assert receipt.code == "malformed_report" and actual is None
    assert not adapter.connected and transport.closed

    # --- scenario: foreign_response_still_revokes_input
    response = {"id": 999, "method": "device.status", "error": {"code": 404}}
    now = [10.0]
    transport = ScriptedTransport()
    adapter = CreatorMicro2Adapter(transport, INFO, clock=lambda: now[0])
    adapter.connect()
    # A foreign id is an accusation only once the startup grace has elapsed.
    now[0] += adapter.STARTUP_GRACE_SECONDS + 1
    transport.replies.extend(raw_reports(response))
    receipt, _ = adapter._call("device.status", None)
    assert receipt.code == "device_conflict"
    assert adapter.conflict.active and adapter.poll_inputs() == []



class WouldBlock(AssertionError):
    """A real blocking hid_read would wait indefinitely on this empty queue."""


class FakeHidDevice:
    def __init__(self, *, write_result=64, reads=()):
        self.nonblocking = False
        self.write_result = write_result
        self.reads = deque(reads)
        self.read_args = []
        self.writes = []
        self.closed = False

    def open_path(self, path):
        self.path = path

    def set_nonblocking(self, value):
        self.nonblocking = bool(value)

    def write(self, report):
        self.writes.append(report)
        return self.write_result

    def read(self, size, timeout):
        self.read_args.append((size, timeout))
        if self.reads:
            return list(self.reads.popleft())
        if timeout == 0 and not self.nonblocking:
            raise WouldBlock("empty hid_read with timeout=0 and blocking mode")
        return []

    def close(self):
        self.closed = True


class FakeHid:
    def __init__(self, device, entries=None):
        self.hardware = device
        self.entries = entries if entries is not None else [{**INFO, "path": b"fixture", "serial_number": SERIAL}]

    def enumerate(self, vendor):
        assert vendor == INFO["vendor_id"]
        return self.entries

    def device(self):
        return self.hardware


def open_transport(monkeypatch, **kwargs):
    # Do not call a native Darwin symbol in an OS-independent protocol test.
    monkeypatch.setattr("jrbar.creator_micro_hidapi._enable_macos_nonexclusive", lambda _: None)
    device = FakeHidDevice(**kwargs)
    transport = HidApiTransport(FakeHid(device), approved_serial=SERIAL)
    transport.open()
    return transport, device


def test_zero_timeout_poll_cannot_block_on_an_empty_queue__and_2_more(monkeypatch) -> None:
    # --- scenario: zero_timeout_poll_cannot_block_on_an_empty_queue
    transport, device = open_transport(monkeypatch)
    assert transport.read(timeout_ms=0) is None
    assert device.nonblocking is True

    # --- scenario: positive_timeouts_remain_bounded
    monkeypatch.undo()
    for requested, expected in [(1, 1), (250, 250), (8000, 8000), (9999, 8000)]:
        transport, device = open_transport(monkeypatch)
        assert transport.read(timeout_ms=requested) is None
        assert device.read_args == [(64, expected)]

    # --- scenario: adapter_empty_input_poll_returns_and_owner_can_close
    monkeypatch.undo()
    transport, device = open_transport(monkeypatch)
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    assert adapter.poll_inputs() == []
    adapter.close()
    assert device.closed and not adapter.connected



def test_short_or_failed_hid_writes_raise__and_2_more(monkeypatch) -> None:
    # --- scenario: short_or_failed_hid_writes_raise
    for result in [-1, 0, 1, 63, 65, None]:
        transport, _ = open_transport(monkeypatch, write_result=result)
        transport.enable_writes()
        with pytest.raises(OSError, match="HID write"):
            transport.write(bytes(64))

    # --- scenario: full_hid_write_succeeds
    monkeypatch.undo()
    transport, device = open_transport(monkeypatch)
    transport.enable_writes()
    transport.write(bytes(64))
    assert device.writes == [bytes(64)]

    # --- scenario: write_opt_in_is_not_weakened
    monkeypatch.undo()
    transport, device = open_transport(monkeypatch)
    with pytest.raises(PermissionError, match="opt-in"):
        transport.write(bytes(64))
    assert device.writes == []



def test_failed_write_propagates_to_adapter_and_disconnects(monkeypatch):
    transport, device = open_transport(monkeypatch, write_result=-1)
    transport.enable_writes()
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    receipt, response = adapter._call("device.status", None)
    assert receipt.code == "transport_unavailable" and response is None
    assert not adapter.connected and device.closed
    assert device.read_args == [(64, 0)]  # the connect-time stale-input drain


def test_approved_device_identity_is_still_required__and_1_more() -> None:
    # --- scenario: approved_device_identity_is_still_required
    with pytest.raises(PermissionError, match="approved device"):
        HidApiTransport(FakeHid(FakeHidDevice())).open()

    # --- scenario: no_device_is_not_silently_replaced_by_another_identity
    transport = HidApiTransport(FakeHid(FakeHidDevice()), approved_serial="different-fixture")
    with pytest.raises(NoDeviceError):
        transport.open()

