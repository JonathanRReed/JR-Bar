"""The lid poll finds IOKit once, not on every read."""

from __future__ import annotations

import ctypes.util

import pytest

from jrbar import lid_sleep


def test_the_iokit_frameworks_are_found_and_prototyped_once_not_on_every_read(monkeypatch: pytest.MonkeyPatch) -> None:
    lookups: list[str] = []
    real_find = ctypes.util.find_library

    def counting_find(name: str):
        lookups.append(name)
        return real_find(name)

    monkeypatch.setattr(ctypes.util, "find_library", counting_find)
    monkeypatch.setattr(lid_sleep, "_IOKIT_BINDINGS", None)
    monkeypatch.setattr(lid_sleep, "_IOKIT_BINDINGS_FAILED", False)

    readings = [lid_sleep._iokit_root_domain_bool("AppleClamshellState") for _ in range(25)]

    assert len(set(readings)) == 1
    assert len(lookups) <= 2, "IOKit and CoreFoundation, once"


def test_a_mac_without_the_frameworks_does_not_look_for_them_every_second(monkeypatch: pytest.MonkeyPatch) -> None:
    lookups: list[str] = []

    def missing(name: str):
        lookups.append(name)
        return f"/nonexistent/{name}.framework/{name}"

    monkeypatch.setattr(ctypes.util, "find_library", missing)
    monkeypatch.setattr(lid_sleep, "_IOKIT_BINDINGS", None)
    monkeypatch.setattr(lid_sleep, "_IOKIT_BINDINGS_FAILED", False)

    assert [lid_sleep._iokit_root_domain_bool("SleepDisabled") for _ in range(10)] == [None] * 10
    assert len(lookups) == 1
