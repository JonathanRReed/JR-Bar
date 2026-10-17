"""The daemon's two firmware commands and the state they publish.

The protocol is in docs/CORE-PROTOCOL.md ("Firmware updates"). Here the
daemon runs for real against a fake drive in a temporary folder: no volume,
no network, no wall-clock waits.
"""

from __future__ import annotations

import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import core_runtime, firmware_hold, status_bar_legacy
from jrbar.core_server import CommandError
from jrbar.firmware_update import DeviceRef
from tests.firmware_fakes import pro_status
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)
from tests.test_firmware_update import Rig

REAL_THREAD = threading.Thread


@pytest.fixture(autouse=True)
def _no_leftover_holds():
    firmware_hold.clear_all()
    yield
    firmware_hold.clear_all()


@pytest.fixture
def daemon(headless, tmp_path: Path, monkeypatch: pytest.MonkeyPatch):  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    # The headless harness fakes threads; the update job needs a real one.
    monkeypatch.setattr(threading, "Thread", REAL_THREAD)
    rig = Rig(tmp_path / "rig", "pro")
    rig.tmp.mkdir(exist_ok=True)
    return controller, rig


def _install(controller, rig: Rig):
    controller._jrbar_firmware = rig.service
    return rig.service


def test_both_commands_are_registered_off_the_main_thread() -> None:
    specs = core_runtime._MAIN_THREAD_COMMANDS
    assert specs["firmware_status"].main_thread is False
    assert specs["firmware_update"].main_thread is False


def test_the_status_reads_never_run_on_the_socket_thread_an_ask_shares() -> None:
    from jrbar import core_server

    assert {"firmware_status", "firmware_update"} <= core_server.READ_LANE_COMMANDS
    assert {"firmware_status", "firmware_update"} <= core_server.SLOW_LANE_COMMANDS


def test_status_reports_the_catalog_and_each_device_without_any_request(daemon) -> None:
    controller, rig = daemon
    _install(controller, rig)
    reply = controller._core_dispatch("firmware_status", {})
    assert reply["download_host"] == "raw.githubusercontent.com"
    [entry] = reply["catalog"]
    assert entry["version"] == "1.1.0" and entry["package"]["cached"] is False
    [device] = reply["devices"]
    assert device["id"] == rig.ref.id and device["version"] == "1.0.2"
    assert device["update_available"] is True and device["can_update"] is True
    assert device["other_slot"]["name"] == "B"
    assert reply["job"] is None
    assert rig.requests == []


def test_the_service_is_built_from_the_daemons_own_devices(daemon, tmp_path: Path) -> None:
    controller, _rig = daemon
    root = tmp_path / "SidePulse"
    root.mkdir()
    (root / "STATUS.TXT").write_text(pro_status("1.0.2"))
    controller.status_bar_devices = lambda remember=True: [
        SimpleNamespace(device_id=status_bar_legacy.VIRTUAL_DEVICE_ID, name="Screen Bar", root=tmp_path, connected=True),
        SimpleNamespace(device_id="SPP-000901", name="SidePulse Pro", root=root, connected=True),
    ]
    reply = controller._core_dispatch("firmware_status", {})
    [device] = reply["devices"]  # the Screen Bar is not a device with firmware
    assert device["id"] == "SPP-000901" and device["model"] == "pro" and device["serial"] == "SPP-000901"
    assert device["version"] == "1.0.2" and device["root"] == str(root)
    assert device["active_slot"] == "A" and device["latest"] == "1.1.0"


def test_an_update_needs_the_explicit_confirmation(daemon) -> None:
    controller, rig = daemon
    _install(controller, rig)
    for args in ({"device": rig.ref.id}, {"device": rig.ref.id, "confirm": "yes"}, {"device": rig.ref.id, "confirm": 1}):
        with pytest.raises(CommandError) as caught:
            controller._core_dispatch("firmware_update", args)
        assert caught.value.code == "invalid_args"
    assert rig.requests == [] and not (rig.root / "FIRMWARE.BIN").exists()


def test_refusals_use_the_protocols_error_codes(daemon) -> None:
    controller, rig = daemon
    _install(controller, rig)
    with pytest.raises(CommandError) as caught:
        controller._core_dispatch("firmware_update", {"device": "nope", "confirm": True})
    assert caught.value.code == "not_found"
    with pytest.raises(CommandError) as caught:
        controller._core_dispatch("firmware_update", {"confirm": True})
    assert caught.value.code == "invalid_args"
    with pytest.raises(CommandError) as caught:
        controller._core_dispatch("firmware_update", {"device": rig.ref.id, "confirm": True, "package": 7})
    assert caught.value.code == "invalid_args"
    rig.device.old_status = pro_status("1.1.0", slot="B")
    with pytest.raises(CommandError) as caught:
        controller._core_dispatch("firmware_update", {"device": rig.ref.id, "confirm": True})
    assert caught.value.code == "refused" and "already runs" in str(caught.value)


def test_an_update_replies_at_once_and_publishes_its_progress_in_state(daemon) -> None:
    controller, rig = daemon
    service = _install(controller, rig)
    published: list[dict] = []
    original = service._on_change

    def changed() -> None:
        published.append(controller._core_build_state().get("firmware") or {})
        original()

    service._on_change = changed
    reply = controller._core_dispatch("firmware_update", {"device": rig.ref.id, "confirm": True})
    assert reply["started"] is True and reply["job"]["device"] == rig.ref.id
    assert rig.finished.wait(10.0)
    assert [item for item in published if item]  # state.firmware carried the job
    phases = [item["phase"] for item in published if item]
    assert phases[0] == "checking" and phases[-1] == "done"
    final = controller._core_build_state()["firmware"]
    assert final["outcome"] == "updated" and final["to_version"] == "1.1.0"
    assert not firmware_hold.any_held()


def test_state_has_no_firmware_entry_until_an_update_exists(daemon) -> None:
    controller, rig = daemon
    assert "firmware" not in controller._core_build_state()
    _install(controller, rig)
    assert "firmware" not in controller._core_build_state()


def test_a_second_update_while_one_runs_is_busy(daemon) -> None:
    controller, rig = daemon
    service = _install(controller, rig)
    service.begin_update(rig.ref.id, confirm=True)  # registered, not yet run
    with pytest.raises(CommandError) as caught:
        controller._core_dispatch("firmware_update", {"device": rig.ref.id, "confirm": True})
    assert caught.value.code == "busy"


def test_a_named_package_file_is_checked_like_a_download(daemon, tmp_path: Path) -> None:
    controller, rig = daemon
    _install(controller, rig)
    bad = tmp_path / "bad.zip"
    bad.write_bytes(b"not a package")
    reply = controller._core_dispatch(
        "firmware_update", {"device": rig.ref.id, "confirm": True, "package": str(bad)}
    )
    assert reply["started"] is True
    assert rig.finished.wait(10.0)
    final = controller._core_build_state()["firmware"]
    assert final["outcome"] == "failed" and final["code"] == "bad_hash"
    assert rig.requests == []


def test_the_hold_pauses_the_hardware_writer_through_the_daemons_gate(daemon) -> None:
    controller, rig = daemon
    firmware_hold.acquire(rig.root, "updating firmware")
    inputs = SimpleNamespace(app_terminating=False)
    controller._runtime_started = True
    controller.leds_enabled = True
    assert controller._hardware_write_should_run(inputs) is False
    firmware_hold.release(rig.root)
    assert controller._hardware_write_should_run(inputs) is True


def test_the_unused_device_ref_type_is_the_one_the_daemon_builds() -> None:
    assert DeviceRef("a", "b", Path("/x")).connected is True
