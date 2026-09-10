"""The shared keyboard/vendor collection must never be seized on macOS."""

import ctypes
import sys
from types import SimpleNamespace

import pytest

from jrbar.creator_micro_hidapi import HidApiTransport


@pytest.fixture
def backend(monkeypatch):
    monkeypatch.setattr(sys, "platform", "darwin")
    # ``access`` is IOHIDCheckAccess's answer: 0 granted, 1 denied, 2 unknown.
    state = SimpleNamespace(exclusive=1, opened=[], closed=0, setter_works=True, access=0, checked=[])

    class Function:
        def __init__(self, callback):
            self.callback = callback

        def __call__(self, *args):
            return self.callback(*args)

    def set_policy(value):
        if state.setter_works:
            state.exclusive = value

    native = SimpleNamespace(
        hid_darwin_set_open_exclusive=Function(set_policy),
        hid_darwin_get_open_exclusive=Function(lambda: state.exclusive),
    )

    class Device:
        def open_path(self, path):
            assert state.exclusive == 0, "macOS keyboard collection cannot be seized"
            state.opened.append(path)

        def set_nonblocking(self, value):
            pass

        def close(self):
            state.closed += 1

    class Hid:
        __file__ = "/fixture/hid.cpython-312-darwin.so"

        def device(self):
            return Device()

        def enumerate(self, _vendor):
            return [{"vendor_id": 0x303A, "product_id": 0x8297,
                     "usage_page": 0xFF00, "usage": 1,
                     "serial_number": "fixture-device", "path": b"vendor-collection"}]

    def check_access(request):
        state.checked.append(request)
        return state.access

    iokit = SimpleNamespace(IOHIDCheckAccess=Function(check_access))

    def load(path):
        if path.endswith("IOKit"):
            return iokit
        assert path == Hid.__file__
        return native

    monkeypatch.setattr(ctypes, "CDLL", load)
    return state, native, HidApiTransport(Hid(), approved_serial="fixture-device")


def test_macos_open_uses_the_pinned_library_and_disables_seizing_before_open(backend):
    state, native, transport = backend
    transport.open(nonexclusive=True)
    assert state.opened == [b"vendor-collection"]
    assert state.exclusive == 0
    assert native.hid_darwin_set_open_exclusive.argtypes == [ctypes.c_int]
    assert native.hid_darwin_set_open_exclusive.restype is None
    transport.close()
    assert state.closed == 1


@pytest.mark.parametrize("failure", ["missing_symbols", "policy_not_applied"])
def test_macos_refuses_open_if_nonexclusive_mode_cannot_be_confirmed(backend, failure):
    state, native, transport = backend
    if failure == "missing_symbols":
        del native.hid_darwin_set_open_exclusive
    else:
        state.setter_works = False
    with pytest.raises(OSError, match="nonexclusive"):
        transport.open()
    assert state.opened == []


def test_macos_reconnect_reapplies_nonexclusive_policy(backend):
    state, _native, transport = backend
    transport.open()
    transport.close()
    state.exclusive = 1  # hid_init can restore the library's default policy.
    transport.open()
    assert state.opened == [b"vendor-collection", b"vendor-collection"]
    transport.close()


def test_macos_refuses_the_open_when_input_monitoring_is_denied(backend):
    """Bluetooth puts the keyboard and vendor collections on one macOS HID
    device, so a denial makes every open fail with an unexplained I/O error.
    Naming it is the difference between "grant this" and "the pad is gone"."""
    state, _native, transport = backend
    state.access = 1
    with pytest.raises(PermissionError) as refused:
        transport.open()
    assert refused.value.code == "input_monitoring_denied"
    assert state.opened == []
    assert state.checked == [1]  # kIOHIDRequestTypeListenEvent


def test_macos_opens_when_access_was_never_decided(backend):
    """``unknown`` is nobody having been asked yet: the open itself is what
    raises the prompt, so refusing here would never let it be granted."""
    state, _native, transport = backend
    state.access = 2
    transport.open()
    assert state.opened == [b"vendor-collection"]
    transport.close()


def test_input_monitoring_check_treats_a_missing_getter_as_no_evidence(monkeypatch):
    """An OS without ``IOHIDCheckAccess`` has not denied anything."""
    from jrbar.creator_micro_hidapi import macos_input_monitoring_denied

    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(ctypes, "CDLL", lambda path: SimpleNamespace())
    assert macos_input_monitoring_denied() is False
