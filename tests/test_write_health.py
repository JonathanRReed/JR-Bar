"""Write health: the device card can say why the strip looks wrong -- how
long the last write took, what the safety compiler changed, and what never
reached the device."""

from __future__ import annotations

from pathlib import Path

import pytest

from jrbar import device_writer, write_health
from jrbar.core_lights import augment_device_health
from jrbar.core_runtime import doc_significant_equal


@pytest.fixture(autouse=True)
def _fresh() -> None:
    write_health.reset()
    yield
    write_health.reset()


def test_a_landed_write_a_clamped_one_and_a_refusal_are_each_counted(tmp_path: Path) -> None:
    pro = tmp_path / "SidePulse"
    pro.mkdir()
    device_writer.write_led_program("1:#00FF00 1s", device_path=pro)
    health = write_health.health_document(str(pro))
    assert health is not None
    assert health["writes"] == 1 and health["transformed"] == 0 and health["refused"] == 0
    assert isinstance(health["latency_ms"], int) and health["latency_ms"] >= 0

    # A flash faster than the gate allows is slowed, and counted as changed.
    device_writer.write_led_program("#FF0000 100ms\n#000000 100ms\nrepeat", device_path=pro)
    assert write_health.health_document(str(pro))["transformed"] == 1

    # An 8-LED program on the 2-LED Dot never reaches it, and says why.
    dot = tmp_path / "SidePulseDot"
    dot.mkdir()
    with pytest.raises(device_writer.DeviceWriteError):
        device_writer.write_led_program("7:#FFFFFF", device_path=dot)
    refused = write_health.health_document(str(dot))
    assert refused["writes"] == 0 and refused["refused"] == 1
    assert "2-LED device" in refused["last_refusal"]
    assert refused["last_refusal_at"] is not None


def test_a_dry_run_is_not_a_write(tmp_path: Path) -> None:
    pro = tmp_path / "SidePulse"
    pro.mkdir()
    device_writer.write_led_program("1:#00FF00 1s", device_path=pro, dry_run=True)
    assert write_health.health_document(str(pro)) is None


def test_the_state_carries_it_and_only_a_refusal_rebroadcasts(tmp_path: Path) -> None:
    root = str(tmp_path / "SidePulse")

    def state() -> dict:
        document = {
            "devices": [
                {"id": "pro", "kind": "pro", "path": root},
                {"id": "screen-bar", "kind": "screen_bar"},
            ]
        }
        augment_device_health(document)
        return document

    assert "write_health" not in state()["devices"][0]
    write_health.record_write(root, seconds=0.031, transformed=False)
    first = state()
    assert first["devices"][0]["write_health"]["latency_ms"] == 31
    assert "write_health" not in first["devices"][1]
    write_health.record_write(root, seconds=0.9, transformed=True)
    assert doc_significant_equal("state", first, state())
    write_health.record_refusal(root, "LED program failed the presentation safety gate.")
    refusing = state()
    assert not doc_significant_equal("state", first, refusing)
    assert refusing["devices"][0]["write_health"]["failing"] is True


def test_a_device_that_keeps_failing_is_news_once(tmp_path: Path) -> None:
    root = str(tmp_path / "SidePulse")

    def state() -> dict:
        document = {"devices": [{"id": "pro", "kind": "pro", "path": root}]}
        augment_device_health(document)
        return document

    write_health.record_write(root, seconds=0.03, transformed=False, at=100.0)
    working = state()
    assert working["devices"][0]["write_health"]["failing"] is False
    write_health.record_refusal(root, "The device stopped answering.", at=110.0)
    failing = state()
    assert not doc_significant_equal("state", working, failing)
    # The retry every few seconds fails the same way: the count moves, the
    # news does not.
    write_health.record_refusal(root, "The device stopped answering.", at=120.0)
    again = state()
    assert again["devices"][0]["write_health"]["refused"] == 2
    assert doc_significant_equal("state", failing, again)
    # A new reason is news; so is the device coming back.
    write_health.record_refusal(root, "LED program failed the presentation safety gate.", at=130.0)
    reasoned = state()
    assert not doc_significant_equal("state", again, reasoned)
    write_health.record_write(root, seconds=0.03, transformed=False, at=140.0)
    recovered = state()
    assert recovered["devices"][0]["write_health"]["failing"] is False
    assert not doc_significant_equal("state", reasoned, recovered)


def test_reasons_are_bounded_and_devices_are_capped() -> None:
    write_health.record_refusal("/Volumes/A", "x" * 1000)
    assert len(write_health.health_document("/Volumes/A")["last_refusal"]) == write_health.MAX_REASON_CHARACTERS
    for index in range(write_health.MAX_DEVICES + 5):
        write_health.record_write(f"/Volumes/D{index}", seconds=0.01, transformed=False, at=float(index))
    kept = [index for index in range(write_health.MAX_DEVICES + 5) if write_health.health_document(f"/Volumes/D{index}")]
    assert len(kept) <= write_health.MAX_DEVICES
    assert kept[-1] == write_health.MAX_DEVICES + 4
    assert write_health.health_document(None) is None
