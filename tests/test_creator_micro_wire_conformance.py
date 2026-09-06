"""Wire/backend conformance regressions, independent of the production encoder.

No device is opened. FakeHidDevice models cython-hidapi's timeout=0 behavior;
WouldBlock deliberately fails fast instead of hanging a test worker.
"""
from __future__ import annotations

import json
from collections import deque

import pytest

from sidepulse.creator_micro_adapter import (
    CreatorMicro2Adapter,
    CreatorMicro2Framer,
    RpcStreamDecoder,
)
from sidepulse.creator_micro_hidapi import HidApiTransport, NoDeviceError

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


@pytest.mark.parametrize("text", ["", "x" * 200, "🙂é" * 50, 'line\nquote"brace}\\'])
def test_request_uses_crlf_boundaries_on_the_actual_wire(text):
    request = {"jsonrpc": "2.0", "method": "device.status", "params": {"text": text}, "id": 1}
    payload = wire_payload(CreatorMicro2Framer.encode_request(request))
    expected = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode()
    assert payload == b"\r\n" + expected + b"\r\n"


def test_request_wire_boundaries_are_included_in_the_byte_budget():
    request = {"jsonrpc": "2.0", "method": "x", "params": None, "id": 1}
    size = len(json.dumps(request, separators=(",", ":")).encode())
    with pytest.raises(ValueError, match="report limit"):
        CreatorMicro2Framer.encode_request(request, max_bytes=size + 3)
    assert len(wire_payload(CreatorMicro2Framer.encode_request(request, max_bytes=size + 4))) == size + 4


@pytest.mark.parametrize("size", [0, 1, 59, 60, 61, 62, 120, 121, 122, 123, 700])
def test_framed_requests_still_decode_across_fragment_boundaries(size):
    request = {"jsonrpc": "2.0", "method": "x", "params": {"text": "x" * size}, "id": 7}
    decoder = RpcStreamDecoder()
    received = [item for report in CreatorMicro2Framer.encode_request(request) for item in decoder.feed(report)]
    assert received == [request]
    assert decoder.pending_bytes == 0


@pytest.mark.parametrize("report_id", [True, False])
@pytest.mark.parametrize("code", [-32601, 404, -32602])
def test_method_tagged_firmware_error_decodes_without_weakening_validation(report_id, code):
    response = {"id": 1, "method": "device.status", "error": {"code": code, "message": "test error"}}
    decoder = RpcStreamDecoder()
    received = [item for report in raw_reports(response, include_report_id=report_id) for item in decoder.feed(report)]
    assert received == [response]
    assert decoder.pending_bytes == 0


@pytest.mark.parametrize("changes", [
    {"error": "not an object"}, {"result": {}}, {"params": {}},
    {"extra": 1}, {"id": True}, {"id": 1000}, {"method": None},
])
def test_malformed_or_ambiguous_firmware_errors_remain_rejected(changes):
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


def test_adapter_reports_firmware_error_instead_of_malformed_wire():
    response = {"id": 1, "method": "device.status", "error": {"code": 404, "message": "not found"}}
    transport = ScriptedTransport(raw_reports(response))
    adapter = CreatorMicro2Adapter(transport, INFO)
    assert adapter.connect().code == "connected"
    receipt, actual = adapter._call("device.status", None)
    assert receipt.code == "rpc_error"
    assert actual == response
    assert adapter.connected


def test_method_mismatch_still_disconnects():
    response = {"id": 1, "method": "fs.read", "error": {"code": 404}}
    transport = ScriptedTransport(raw_reports(response))
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    receipt, actual = adapter._call("device.status", None)
    assert receipt.code == "malformed_report" and actual is None
    assert not adapter.connected and transport.closed


def test_foreign_response_still_revokes_input():
    response = {"id": 999, "method": "device.status", "error": {"code": 404}}
    transport = ScriptedTransport(raw_reports(response))
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
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
    monkeypatch.setattr("sidepulse.creator_micro_hidapi._enable_macos_nonexclusive", lambda _: None)
    device = FakeHidDevice(**kwargs)
    transport = HidApiTransport(FakeHid(device), approved_serial=SERIAL)
    transport.open()
    return transport, device


def test_zero_timeout_poll_cannot_block_on_an_empty_queue(monkeypatch):
    transport, device = open_transport(monkeypatch)
    assert transport.read(timeout_ms=0) is None
    assert device.nonblocking is True


@pytest.mark.parametrize(("requested", "expected"), [(1, 1), (250, 250), (8000, 8000), (9999, 8000)])
def test_positive_timeouts_remain_bounded(monkeypatch, requested, expected):
    transport, device = open_transport(monkeypatch)
    assert transport.read(timeout_ms=requested) is None
    assert device.read_args == [(64, expected)]


def test_adapter_empty_input_poll_returns_and_owner_can_close(monkeypatch):
    transport, device = open_transport(monkeypatch)
    adapter = CreatorMicro2Adapter(transport, INFO)
    adapter.connect()
    assert adapter.poll_inputs() == []
    adapter.close()
    assert device.closed and not adapter.connected


@pytest.mark.parametrize("result", [-1, 0, 1, 63, 65, None])
def test_short_or_failed_hid_writes_raise(monkeypatch, result):
    transport, _ = open_transport(monkeypatch, write_result=result)
    transport.enable_writes()
    with pytest.raises(OSError, match="HID write"):
        transport.write(bytes(64))


def test_full_hid_write_succeeds(monkeypatch):
    transport, device = open_transport(monkeypatch)
    transport.enable_writes()
    transport.write(bytes(64))
    assert device.writes == [bytes(64)]


def test_write_opt_in_is_not_weakened(monkeypatch):
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
    assert device.read_args == []


def test_approved_device_identity_is_still_required():
    with pytest.raises(PermissionError, match="approved device"):
        HidApiTransport(FakeHid(FakeHidDevice())).open()


def test_no_device_is_not_silently_replaced_by_another_identity():
    transport = HidApiTransport(FakeHid(FakeHidDevice()), approved_serial="different-fixture")
    with pytest.raises(NoDeviceError):
        transport.open()
