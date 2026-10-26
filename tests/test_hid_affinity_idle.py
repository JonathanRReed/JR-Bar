"""The thread that keeps hidapi's run loop alive does not wake an idle Mac."""

from __future__ import annotations

import sys
import types

import pytest

from jrbar import hid_affinity


def _fake_foundation(slept: list[float], loop_runs: list[str]) -> types.ModuleType:
    module = types.ModuleType("Foundation")

    class _Date:
        @staticmethod
        def dateWithTimeIntervalSinceNow_(seconds: float) -> float:
            slept.append(seconds)
            return seconds

    class _Port:
        @staticmethod
        def port() -> object:
            return object()

    class _Loop:
        def addPort_forMode_(self, _port: object, _mode: str) -> None:
            loop_runs.append("port")

        def runMode_beforeDate_(self, _mode: str, _date: float) -> bool:
            loop_runs.append("run")
            hid_affinity._stop.set()
            return True

    class _RunLoop:
        @staticmethod
        def currentRunLoop() -> _Loop:
            return _Loop()

    module.NSDate = _Date
    module.NSDefaultRunLoopMode = "default"
    module.NSMachPort = _Port
    module.NSRunLoop = _RunLoop
    return module


def test_the_pump_sleeps_in_its_run_loop_for_an_hour_not_half_a_second(monkeypatch: pytest.MonkeyPatch) -> None:
    slept: list[float] = []
    loop_runs: list[str] = []
    fake_hid = types.ModuleType("hid")
    fake_hid.enumerate = lambda: []  # type: ignore[attr-defined]
    from jrbar import native_run_loop

    class Pump:
        def __init__(self):
            loop_runs.append("port")

        def run(self, seconds):
            slept.append(seconds)
            loop_runs.append("run")
            hid_affinity._stop.set()

        def close(self):
            pass

    monkeypatch.setattr(native_run_loop, "Pump", Pump)
    monkeypatch.setitem(sys.modules, "hid", fake_hid)
    monkeypatch.setattr(hid_affinity, "_stop", hid_affinity.threading.Event())
    monkeypatch.setattr(hid_affinity, "_ready", hid_affinity.threading.Event())
    monkeypatch.setattr(hid_affinity, "_error", None)

    hid_affinity._bind()

    assert loop_runs == ["port", "run"]
    assert slept == [hid_affinity.PUMP_WAKE_SECONDS]
    assert hid_affinity.PUMP_WAKE_SECONDS >= 600.0
    assert hid_affinity._ready.is_set()
