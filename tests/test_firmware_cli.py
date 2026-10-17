"""``jrbar firmware upgrade``: plain prompts, nothing done before a yes."""

from __future__ import annotations

import io
from pathlib import Path
from typing import Any

import pytest

from jrbar import firmware_cli as cli
from jrbar import firmware_hold
from jrbar.cli import build_jrbar_parser
from jrbar.cli_control import EXIT_NO_CORE, ControlError
from tests.test_firmware_update import Rig


@pytest.fixture(autouse=True)
def _no_leftover_holds():
    firmware_hold.clear_all()
    yield
    firmware_hold.clear_all()


def _device(**overrides: Any) -> dict[str, Any]:
    device = {
        "id": "SPP-000067",
        "name": "SidePulse Pro",
        "root": "/Volumes/SidePulse",
        "mounted": True,
        "model": "pro",
        "serial": "SPP-000067",
        "version": "1.0.2",
        "latest": "1.1.0",
        "update_available": True,
        "can_update": True,
        "why_not": None,
        "other_slot": {"name": "B", "has_image": False, "valid": True, "version": "none"},
    }
    device.update(overrides)
    return device


def _status(*devices: dict[str, Any], cached: bool = False) -> dict[str, Any]:
    return {
        "catalog": [
            {
                "model": "pro",
                "name": "SidePulse Pro",
                "version": "1.1.0",
                "package": {"host": "raw.githubusercontent.com", "bytes": 137875, "cached": cached},
            },
            {
                "model": "dot",
                "name": "SidePulse Dot",
                "version": "1.1.14",
                "package": {"host": "raw.githubusercontent.com", "bytes": 31349, "cached": cached},
            },
        ],
        "devices": list(devices),
        "job": None,
    }


class FakeBackend:
    name = "JR-Bar"

    def __init__(self, status: dict[str, Any], jobs: list[dict[str, Any] | None] | None = None) -> None:
        self._status = status
        self.jobs = jobs or []
        self.started: list[tuple[str, Path | None]] = []

    def status(self) -> dict[str, Any]:
        return self._status

    def start(self, device_id: str, package: Path | None) -> dict[str, Any]:
        self.started.append((device_id, package))
        return {}

    def job(self) -> dict[str, Any] | None:
        return self.jobs.pop(0) if len(self.jobs) > 1 else (self.jobs[0] if self.jobs else None)


DONE = {
    "outcome": "updated",
    "message": "The SidePulse Pro now runs firmware 1.1.0.",
    "previous_firmware": {"version": "1.0.2", "slot": "A"},
    "colour_check": True,
}


def _run(backend, *, device=None, package=None, yes=False, answer="yes", interactive=True):
    out, err = io.StringIO(), io.StringIO()
    code = cli.run_upgrade_command(
        device,
        package,
        assume_yes=yes,
        backend=backend,
        out=out,
        err=err,
        read_line=lambda prompt: answer,
        interactive=interactive,
        sleep=lambda seconds: None,
    )
    return code, out.getvalue(), err.getvalue()


def test_the_plan_says_what_is_downloaded_what_is_written_and_what_stays() -> None:
    backend = FakeBackend(_status(_device()), [DONE])
    code, out, _err = _run(backend)
    assert code == 0 and backend.started == [("SPP-000067", None)]
    assert "firmware 1.0.2 -> 1.1.0" in out
    assert "raw.githubusercontent.com" in out and "135 KB" in out
    assert "FIRMWARE.BIN" in out and "/Volumes/SidePulse" in out
    assert "about a minute" in out and "at least 10 seconds" in out
    assert "slot B" in out and "no rollback" in out
    assert "previous firmware (1.0.2) is kept in slot A" in out
    assert "check it again" in out  # the colour note


def test_nothing_is_done_without_a_yes() -> None:
    backend = FakeBackend(_status(_device()), [DONE])
    code, out, _err = _run(backend, answer="no")
    assert code == 0 and backend.started == [] and "Nothing was done" in out
    code, out, err = _run(backend, interactive=False)
    assert code == 2 and backend.started == [] and "--yes" in err


def test_yes_goes_ahead_without_asking() -> None:
    backend = FakeBackend(_status(_device()), [DONE])
    code, _out, _err = _run(backend, yes=True, interactive=False)
    assert code == 0 and len(backend.started) == 1


def test_a_cached_package_is_not_downloaded_and_a_named_one_is_read_from_disk(tmp_path: Path) -> None:
    backend = FakeBackend(_status(_device(), cached=True), [DONE])
    _code, out, _err = _run(backend, yes=True)
    assert "Nothing is downloaded" in out
    named = tmp_path / "pro.zip"
    backend = FakeBackend(_status(_device()), [DONE])
    _code, out, _err = _run(backend, yes=True, package=named)
    assert str(named) in out and "Download" not in out
    assert backend.started == [("SPP-000067", named)]


def test_a_device_with_no_update_is_left_alone() -> None:
    backend = FakeBackend(_status(_device(version="1.1.0", update_available=False)))
    code, out, _err = _run(backend)
    assert code == 0 and "up to date" in out and backend.started == []


def test_one_device_with_an_update_is_chosen_when_none_is_named() -> None:
    dot = _device(id="SPD-000120", name="SidePulse Dot", model="dot", serial="SPD-000120",
                  version="1.1.14", update_available=False, root="/Volumes/PulseDot")
    backend = FakeBackend(_status(dot, _device()), [DONE])
    code, _out, _err = _run(backend, yes=True)
    assert code == 0 and backend.started == [("SPP-000067", None)]


def test_two_devices_with_updates_need_to_be_told_which() -> None:
    dot = _device(id="SPD-000120", name="SidePulse Dot", model="dot", serial="SPD-000120",
                  version="1.0.4", root="/Volumes/PulseDot")
    backend = FakeBackend(_status(dot, _device()), [DONE])
    code, _out, err = _run(backend, yes=True)
    assert code == 2 and backend.started == [] and "--device" in err
    code, _out, _err = _run(backend, device="pulsedot", yes=True)
    assert code == 0 and backend.started == [("SPD-000120", None)]
    code, _out, _err = _run(backend, device="spp-000067", yes=True)
    assert code == 0
    code, _out, err = _run(backend, device="nothing", yes=True)
    assert code == 2 and "no connected device matches" in err


def test_a_device_that_cannot_be_updated_says_why() -> None:
    blocked = _device(can_update=False, why_not={"code": "battery_low", "message": "Plug in the charger first."})
    backend = FakeBackend(_status(blocked))
    code, _out, err = _run(backend, yes=True)
    assert code == 1 and "Plug in the charger first." in err and backend.started == []


def test_no_device_connected_is_a_plain_message() -> None:
    code, _out, err = _run(FakeBackend(_status()))
    assert code == 1 and "no SidePulse is connected" in err


def test_failure_and_unconfirmed_have_their_own_exit_codes_and_advice() -> None:
    failed = {"outcome": "failed", "message": "The checksum differs.", "what_to_do": "Nothing was written."}
    code, _out, err = _run(FakeBackend(_status(_device()), [failed]), yes=True)
    assert code == 1 and "checksum differs" in err and "Nothing was written." in err
    unconfirmed = {
        "outcome": "unconfirmed",
        "message": "The drive did not come back.",
        "what_to_do": "Unplug it and plug it in again.",
    }
    code, out, _err = _run(FakeBackend(_status(_device()), [unconfirmed]), yes=True)
    assert code == 3 and "plug it in again" in out


def test_each_phase_is_printed_once_as_it_starts() -> None:
    jobs = [
        {"phase_label": "Downloading the update", "outcome": None, "download": {"bytes": 20480, "total": 137875}},
        {"phase_label": "Downloading the update", "outcome": None, "download": {"bytes": 20480, "total": 137875}},
        {"phase_label": "Copying the update to the device", "outcome": None},
        DONE,
    ]
    _code, out, _err = _run(FakeBackend(_status(_device()), jobs), yes=True)
    assert out.count("Downloading the update (20 of 134 KB)") == 1
    assert out.index("Copying the update") > out.index("Downloading")


def test_the_daemon_backend_speaks_the_protocol_and_unwraps_refusals() -> None:
    class Connection:
        def __init__(self) -> None:
            self.sent: list[tuple[str, dict]] = []

        def command(self, name: str, args: dict) -> dict:
            self.sent.append((name, args))
            if name == "firmware_update" and args["device"] == "bad":
                raise ControlError("firmware_update: The device looks busy.", 1, code="refused")
            if name == "firmware_update":
                return {"started": True, "job": {"id": "fw-1"}}
            return {"job": {"phase": "copying"}, "devices": []}

    connection = Connection()
    backend = cli.DaemonBackend(connection)
    assert backend.start("SPP-1", Path("/tmp/p.zip")) == {"id": "fw-1"}
    assert connection.sent[-1] == ("firmware_update", {"device": "SPP-1", "confirm": True, "package": "/tmp/p.zip"})
    assert backend.job() == {"phase": "copying"}
    with pytest.raises(cli.BackendError) as caught:
        backend.start("bad", None)
    assert caught.value.message == "The device looks busy."


def test_without_the_monitor_it_runs_in_this_process(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    rig = Rig(tmp_path, "pro")

    class NoCore:
        def __enter__(self):
            raise ControlError("the JR-Bar monitor is not running", EXIT_NO_CORE)

        def __exit__(self, *exc):
            return None

    service = rig.service
    code = cli.run_from_args(None, None, True, connect=NoCore, local=lambda: service)
    captured = capsys.readouterr()
    assert code == 0, captured
    assert "now runs firmware 1.1.0" in captured.out
    assert (rig.root / "FIRMWARE.BIN").exists()
    assert not firmware_hold.any_held()


def test_a_monitor_that_answers_badly_is_not_mistaken_for_no_monitor(capsys: pytest.CaptureFixture[str]) -> None:
    class Broken:
        def __enter__(self):
            raise ControlError("the monitor sent an oversized frame", 1)

        def __exit__(self, *exc):
            return None

    code = cli.run_from_args(None, None, True, connect=Broken, local=lambda: pytest.fail("ran locally"))
    assert code == 1 and "oversized" in capsys.readouterr().err


def test_the_parser_takes_device_from_and_yes() -> None:
    args = build_jrbar_parser().parse_args(
        ["firmware", "upgrade", "--device", "SPP-000067", "--from", "/tmp/a.zip", "--yes"]
    )
    assert (args.device, args.package, args.yes) == ("SPP-000067", Path("/tmp/a.zip"), True)
    assert args.func.__name__ == "cmd_jrbar_firmware_upgrade"
    assert build_jrbar_parser().parse_args(["firmware", "version"]).func.__name__ == "cmd_jrbar_firmware_version"
