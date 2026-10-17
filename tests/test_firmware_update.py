"""The firmware update as a job: its order, its refusals and its honesty.

Everything is fake and deterministic: a temporary folder stands in for the
drive (with a root directory that runs out of entries), the device's
STATUS.TXT follows an injected clock, and "sleeping" just moves that clock.
No test touches a real volume, the network or the wall clock.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from jrbar import firmware_hold
from jrbar.device_firmware import FirmwareRelease
from jrbar.firmware_drive import DriveError
from jrbar.firmware_update import (
    FINISHED_JOB_SECONDS,
    MIN_BATTERY_PERCENT,
    DeviceRef,
    FirmwareService,
    UpdateRefused,
    battery_refusal,
)
from tests.firmware_fakes import (
    FakeDevice,
    FakeFat,
    FakeWorld,
    dot_status,
    make_image,
    make_release,
    make_zip,
    populate_pro_drive,
    pro_status,
)
from tests.test_firmware_package import FakeResponse, _opener


@pytest.fixture(autouse=True)
def _no_leftover_holds():
    firmware_hold.clear_all()
    yield
    firmware_hold.clear_all()


class AssertingFat(FakeFat):
    """A fake drive that notes whether the write hold was in force for each
    change made to it."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.held_during: list[tuple[str, str, bool]] = []

    def _note(self, kind: str, root: Path, name: str) -> None:
        self.held_during.append((kind, name, firmware_hold.held_reason(root) is not None))

    def write_file(self, root, name, data, *, replace):
        self._note("write", root, name)
        super().write_file(root, name, data, replace=replace)

    def unlink(self, root, name):
        self._note("unlink", root, name)
        super().unlink(root, name)


@dataclass
class Rig:
    tmp: Path
    model: str = "pro"
    release: FirmwareRelease = field(init=False)
    world: FakeWorld = field(default_factory=FakeWorld)
    ops: AssertingFat = field(default_factory=AssertingFat)
    requests: list = field(default_factory=list)
    phases: list[str] = field(default_factory=list)
    battery: object | None = None
    package: bytes = b""
    service: FirmwareService = field(init=False)
    device: FakeDevice = field(init=False)
    root: Path = field(init=False)
    ref: DeviceRef = field(init=False)
    finished: threading.Event = field(default_factory=threading.Event)

    def __post_init__(self) -> None:
        image = make_image(self.model)
        version = "1.1.0" if self.model == "pro" else "1.1.14"
        self.release = make_release(self.model, version, image=image)
        self.package = make_zip(self.release.package_name, image)
        # The synthetic release is pinned to the package built here.
        self.release = make_release(self.model, version, image=image, package=self.package)
        drive = "SidePulse" if self.model == "pro" else "PulseDot"
        self.root = self.tmp / drive
        if self.model == "pro":
            populate_pro_drive(self.root)
            old = pro_status("1.0.2")
            new = pro_status(version, slot="B", uptime_ms=1200, other_version="27251.50806")
            name = "SidePulse Pro"
        else:
            self.root.mkdir()
            (self.root / "STATUS.TXT").write_text(dot_status())
            (self.root / "FIRMWARE.BIN").write_bytes(b"factory image\n" * 50)
            old = dot_status("1.0.4")
            new = dot_status(version, ticks=900)
            name = "SidePulse Dot"
            self.ops = AssertingFat(stamp_sidecars=False)
        self.device = FakeDevice(self.model, self.root, old, new, world=self.world)
        self.world.devices[self.model] = self.device
        self.ref = DeviceRef(f"{self.model}-1", name, self.root)
        self.service = self.make_service()

    def opener(self):
        return _opener(lambda request: FakeResponse(self.package, request.full_url), self.requests)

    def make_service(self, **overrides) -> FirmwareService:
        def note() -> None:
            job = self.service.job if hasattr(self, "service") else None
            if job is not None:
                if not self.phases or self.phases[-1] != job.phase:
                    self.phases.append(job.phase)
                if job.outcome is not None:
                    self.finished.set()

        options = {
            "state_dir": self.tmp / "state",
            "devices": lambda: [self.ref],
            "find_roots": self.world.find_roots,
            "battery": lambda: self.battery,
            "ops": self.ops,
            "read": self.world.read,
            "clock": self.world.clock,
            "wall": self.world.wall,
            "sleep": self.world.sleep,
            "opener": self.opener(),
            "on_change": note,
            "releases": (self.release,),
        }
        options.update(overrides)
        return FirmwareService(**options)

    def run(self, **kwargs):
        job = self.service.begin_update(self.ref.id, confirm=True, **kwargs)
        return self.service.execute(job)


@pytest.fixture
def pro(tmp_path: Path) -> Rig:
    return Rig(tmp_path, "pro")


@pytest.fixture
def dot(tmp_path: Path) -> Rig:
    return Rig(tmp_path, "dot")


# --- the happy path ---------------------------------------------------------------------


def test_a_pro_update_runs_the_vendor_sequence_and_proves_the_new_version(pro: Rig) -> None:
    job = pro.run()
    assert (job.outcome, job.code) == ("updated", None)
    assert pro.phases == [
        "checking", "downloading", "verifying", "preparing", "copying", "restarting", "confirming", "done",
    ]
    assert job.from_version == "1.0.2" and job.to_version == "1.1.0"
    assert job.source == "download" and len(pro.requests) == 1
    assert job.new_slot == "B" and job.from_slot == "A"
    # The vendor: leave it alone at least ten seconds after the copy.
    assert sum(pro.world.sleeps) >= 10.0
    # Sidecars were cleared first, and the new one afterwards.
    assert {"._LEDS.LED", "._keepalive"} <= set(job.removed_sidecars)
    assert "._FIRMWARE.BIN" in job.removed_sidecars
    assert not any(item.name.startswith("._") for item in pro.root.iterdir())
    assert (pro.root / "FIRMWARE.BIN").read_bytes() == make_image("pro")
    # Device files were not touched.
    for name in ("STATUS.TXT", "INIT.LED", "LEDS.LED", "keepalive", ".claude"):
        assert (pro.root / name).exists()
    assert not firmware_hold.any_held()


def test_a_pro_update_records_that_the_old_firmware_is_kept_in_the_other_slot(pro: Rig) -> None:
    job = pro.run()
    assert job.previous_kept is not None
    assert job.previous_kept["version"] == "1.0.2"
    assert job.previous_kept["slot"] == "A" and job.previous_kept["valid"] is True
    document = job.to_document()
    assert document["previous_firmware"]["slot"] == "A"
    assert document["colour_check"] is True  # 1.0.2 -> 1.1.0 crosses the firmware's own colour gains


def test_the_old_firmware_is_not_claimed_when_the_other_slot_is_not_valid(pro: Rig) -> None:
    pro.device.new_status = pro_status("1.1.0", slot="B", uptime_ms=1200, other_valid=False, other_version="27251.50806")
    job = pro.run()
    assert job.outcome == "updated" and job.previous_kept is None


def test_a_dot_update_replaces_the_virtual_firmware_file_and_reads_app_version(dot: Rig) -> None:
    job = dot.run()
    assert job.outcome == "updated" and job.to_version == "1.1.14"
    assert (dot.root / "FIRMWARE.BIN").read_bytes() == make_image("dot")
    assert job.previous_kept is None and job.colour_check is False
    assert dot.ops.held_during == [("write", "FIRMWARE.BIN", True)]


def test_a_second_device_of_the_same_model_needs_no_download(pro: Rig, tmp_path: Path) -> None:
    pro.run()
    assert len(pro.requests) == 1
    again = Rig(tmp_path / "second", "pro")
    again.package = pro.package
    again.release = pro.release
    again.service = again.make_service(
        state_dir=pro.tmp / "state", releases=(pro.release,), opener=_opener(lambda r: pytest.fail("fetched"), [])
    )
    job = again.run()
    assert job.outcome == "updated" and job.source == "cache"


def test_a_package_file_named_by_the_person_needs_no_network(pro: Rig, tmp_path: Path) -> None:
    path = tmp_path / "pro.zip"
    path.write_bytes(pro.package)
    pro.service = pro.make_service(opener=_opener(lambda r: pytest.fail("fetched"), []))
    job = pro.run(from_file=path)
    assert job.outcome == "updated" and job.source == "file"
    assert "downloading" not in pro.phases


# --- nothing leaves the Mac without a request ---------------------------------------------


def test_looking_at_the_status_never_reaches_the_network(pro: Rig) -> None:
    document = pro.service.status_document()
    assert pro.requests == []
    [device] = document["devices"]
    assert device["update_available"] is True and device["can_update"] is True
    assert document["download_host"] == "raw.githubusercontent.com"
    [entry] = document["catalog"]
    assert entry["package"]["cached"] is False and entry["package"]["host"] == "raw.githubusercontent.com"


def test_registering_an_update_downloads_nothing_until_it_runs(pro: Rig) -> None:
    job = pro.service.begin_update(pro.ref.id, confirm=True)
    assert pro.requests == [] and job.running
    pro.service.execute(job)
    assert len(pro.requests) == 1


def test_an_update_without_the_explicit_confirmation_is_refused(pro: Rig) -> None:
    with pytest.raises(UpdateRefused) as caught:
        pro.service.begin_update(pro.ref.id, confirm=False)
    assert caught.value.kind == "invalid_args" and pro.requests == []
    with pytest.raises(UpdateRefused):
        pro.service.begin_update(pro.ref.id, confirm="yes")  # type: ignore[arg-type]


# --- the hold -----------------------------------------------------------------------------


def test_no_led_write_gets_through_between_copying_and_confirmed(pro: Rig) -> None:
    attempts: list[tuple[str, str, bool]] = []

    def led_writer(world: FakeWorld) -> None:
        job = pro.service.job
        blocked = firmware_hold.held_reason(pro.root / "LEDS.LED") is not None
        attempts.append((job.phase if job else "-", f"{world.now:.0f}", blocked))

    pro.world.hooks.append(led_writer)
    job = pro.run()
    assert job.outcome == "updated"
    during_wait = [attempt for attempt in attempts if attempt[0] == "restarting"]
    assert during_wait and all(blocked for _phase, _now, blocked in during_wait)
    # Every change made to the drive happened under the hold.
    assert pro.ops.held_during and all(held for _kind, _name, held in pro.ops.held_during)
    # And it resumes afterwards.
    assert firmware_hold.held_reason(pro.root / "LEDS.LED") is None


def test_the_hold_is_released_when_the_copy_fails(pro: Rig) -> None:
    class Failing(AssertingFat):
        def write_file(self, root, name, data, *, replace):
            raise DriveError("copy_failed", "The file could not be copied. The device is still on its old firmware.")

    pro.ops = Failing()
    pro.service = pro.make_service(ops=pro.ops)
    job = pro.run()
    assert job.outcome == "failed" and job.code == "copy_failed"
    assert not firmware_hold.any_held()
    assert pro.device.seen_image_at is None  # the device never saw an image


def test_the_hold_is_released_when_something_unexpected_goes_wrong(pro: Rig) -> None:
    calls = {"count": 0}

    def exploding(root: Path):
        calls["count"] += 1
        if calls["count"] > 2:
            raise RuntimeError("synthetic bug")
        return pro.world.read(root)

    pro.service = pro.make_service(read=exploding)
    job = pro.run()
    assert job.outcome == "failed" and job.code == "internal"
    assert not firmware_hold.any_held()


def test_a_linked_partner_is_held_too(pro: Rig, tmp_path: Path) -> None:
    partner = tmp_path / "PulseDot"
    partner.mkdir()
    seen: list[bool] = []

    def probe(world: FakeWorld) -> None:
        seen.append(firmware_hold.held_reason(partner / "LEDS.LED") is not None)

    pro.world.hooks.append(probe)
    pro.service = pro.make_service(partners=lambda ref: [partner])
    pro.run()
    assert seen and all(seen)
    assert not firmware_hold.any_held()


# --- the restart wait -----------------------------------------------------------------------


def test_the_new_version_is_not_believed_before_ten_seconds_have_passed(pro: Rig) -> None:
    pro.device.apply_delay = 1.0
    pro.device.gone_for = 1.0
    job = pro.run()
    assert job.outcome == "updated"
    assert sum(pro.world.sleeps) >= 10.0


def test_a_drive_that_never_returns_is_unconfirmed_never_success(pro: Rig) -> None:
    pro.device.returns = False
    job = pro.run()
    assert job.outcome == "unconfirmed" and job.code == "no_return"
    assert "plug it in again" in job.what_to_do
    # Bounded by the injected clock: about two minutes, not forever.
    assert 119.0 <= sum(pro.world.sleeps) <= 125.0
    assert not firmware_hold.any_held()


def test_a_device_that_comes_back_on_the_old_firmware_is_a_failure(pro: Rig) -> None:
    pro.device.applies = False
    job = pro.run()
    assert (job.outcome, job.code) == ("failed", "not_applied")
    assert "1.0.2" in job.message
    assert not firmware_hold.any_held()


def test_a_device_that_comes_back_on_some_other_version_is_reported(pro: Rig) -> None:
    pro.device.new_status = pro_status("1.0.9", slot="B", uptime_ms=1000)
    job = pro.run()
    assert (job.outcome, job.code) == ("failed", "unexpected_version")


def test_a_drive_that_comes_back_under_another_name_is_found_by_its_serial(pro: Rig, tmp_path: Path) -> None:
    returned = tmp_path / "SidePulse 1"
    returned.mkdir()
    pro.device.returned_root = returned
    held_new: list[bool] = []
    pro.world.hooks.append(lambda world: held_new.append(firmware_hold.held_reason(returned) is not None))
    job = pro.run()
    assert job.outcome == "updated"
    assert (returned / "STATUS.TXT").exists() is False  # nothing was written there by the update
    # The new path was held from the moment the device was seen there.
    assert held_new[-1] is True
    assert not firmware_hold.any_held()


def test_a_different_device_with_another_serial_is_not_mistaken_for_it(pro: Rig, tmp_path: Path) -> None:
    pro.device.new_status = pro_status("1.1.0", slot="B", serial="SPP-000999")
    job = pro.run()
    assert job.outcome == "unconfirmed"


# --- refusals ----------------------------------------------------------------------------------


def _refusal(rig: Rig, **kwargs) -> UpdateRefused:
    with pytest.raises(UpdateRefused) as caught:
        rig.service.begin_update(rig.ref.id, confirm=True, **kwargs)
    return caught.value


def test_an_unknown_device_is_not_found(pro: Rig) -> None:
    with pytest.raises(UpdateRefused) as caught:
        pro.service.begin_update("nope", confirm=True)
    assert caught.value.kind == "not_found"
    with pytest.raises(UpdateRefused) as caught:
        pro.service.begin_update(None, confirm=True)
    assert caught.value.kind == "invalid_args"


def test_a_device_that_is_not_mounted_is_refused(pro: Rig) -> None:
    pro.ref = DeviceRef(pro.ref.id, pro.ref.name, pro.root, connected=False)
    assert _refusal(pro).code == "not_mounted"
    pro.ref = DeviceRef(pro.ref.id, pro.ref.name, pro.root, connected=True)
    pro.device.returns = False
    pro.device.seen_image_at = 0.0  # the drive is gone
    pro.device.apply_delay = -1.0
    assert _refusal(pro).code == "not_mounted"


def test_a_device_with_unreadable_status_is_refused_as_unknown(pro: Rig) -> None:
    pro.device.old_status = "hello world\n"
    assert _refusal(pro).code == "not_mounted"  # it did not answer as a SidePulse


def test_a_serial_that_belongs_to_the_other_model_is_refused(pro: Rig) -> None:
    pro.device.old_status = pro_status("1.0.2", serial="SPD-000001")
    refusal = _refusal(pro)
    assert refusal.code == "model_mismatch" and refusal.kind == "refused"
    assert not (pro.root / "FIRMWARE.BIN").exists()


def test_a_device_with_no_serial_is_refused(pro: Rig) -> None:
    pro.device.old_status = pro_status("1.0.2").replace("serial SPP-000901\n", "")
    assert _refusal(pro).code == "model_mismatch"


def test_a_device_whose_slot_is_unknown_is_refused(pro: Rig) -> None:
    pro.device.old_status = (
        "release_version 1.0.2\nserial SPP-000901\nstate idle\nota ready\n"
    )
    assert _refusal(pro).code == "facts_unknown"


def test_a_device_reporting_a_restart_or_transfer_is_refused_as_busy(pro: Rig) -> None:
    pro.device.old_status = pro_status("1.0.2", ota="receiving")
    assert _refusal(pro).code == "device_busy"


def test_a_device_that_is_up_to_date_is_not_updated(pro: Rig) -> None:
    pro.device.old_status = pro_status("1.1.0", slot="B")
    refusal = _refusal(pro)
    assert refusal.code == "up_to_date"
    [device] = pro.service.status_document()["devices"]
    assert device["update_available"] is False and device["can_update"] is False
    assert device["why_not"] is None  # nothing is wrong; there is just nothing to do


def test_a_model_with_no_pinned_release_is_refused(pro: Rig) -> None:
    pro.service = pro.make_service(releases=())
    assert _refusal(pro).code == "no_release"


@dataclass
class Battery:
    percent: int
    is_plugged: bool = False
    adapter_connected: bool = False
    battery_present: bool = True
    voltage: float = 12.0


def test_battery_power_below_the_floor_refuses_and_a_charger_or_desktop_does_not() -> None:
    assert battery_refusal(Battery(MIN_BATTERY_PERCENT - 1)).code == "battery_low"
    assert battery_refusal(Battery(MIN_BATTERY_PERCENT)) is None
    assert battery_refusal(Battery(5, is_plugged=True)) is None
    assert battery_refusal(Battery(5, adapter_connected=True)) is None
    assert battery_refusal(Battery(0, battery_present=False)) is None
    assert battery_refusal(Battery(0, voltage=0.0)) is None  # an empty reading is no battery
    assert battery_refusal(None) is None


def test_the_service_refuses_on_a_low_battery_before_anything_happens(pro: Rig) -> None:
    pro.battery = Battery(12)
    refusal = _refusal(pro)
    assert refusal.code == "battery_low" and "Plug in" in refusal.message
    [device] = pro.service.status_document()["devices"]
    assert device["can_update"] is False and device["why_not"]["code"] == "battery_low"
    assert pro.requests == [] and not (pro.root / "FIRMWARE.BIN").exists()
    pro.battery = Battery(12, is_plugged=True)
    assert pro.service.begin_update(pro.ref.id, confirm=True).running


def test_only_one_update_runs_at_a_time(pro: Rig) -> None:
    job = pro.service.begin_update(pro.ref.id, confirm=True)
    refusal = _refusal(pro)
    assert refusal.kind == "busy"
    pro.service.execute(job)
    pro.device.old_status = pro_status("1.0.2")
    pro.device.seen_image_at = None
    for name in ("FIRMWARE.BIN",):
        (pro.root / name).unlink(missing_ok=True)
    pro.device.applies = True
    assert pro.service.begin_update(pro.ref.id, confirm=True).running


# --- never the wrong image on the wrong drive --------------------------------------------------


def test_a_pro_package_is_never_written_to_a_dot(dot: Rig, pro: Rig) -> None:
    """Handing a Dot the Pro's package fails its checks; the drive is untouched."""
    path = dot.tmp / "pro.zip"
    path.write_bytes(pro.package)
    before = (dot.root / "FIRMWARE.BIN").read_bytes()
    job = dot.run(from_file=path)
    assert job.outcome == "failed" and job.code == "bad_hash"
    assert (dot.root / "FIRMWARE.BIN").read_bytes() == before
    assert dot.ops.held_during == []
    assert not firmware_hold.any_held()


def test_a_device_swapped_for_another_while_preparing_gets_nothing(pro: Rig) -> None:
    reads = {"count": 0}

    def swapping(root: Path):
        reads["count"] += 1
        if reads["count"] >= 2:  # the re-read right before writing
            return pro.world.read(root).__class__(
                identity=pro.world.read(root).identity.__class__("pro", "1.0.2", "SPP-000555"),
            )
        return pro.world.read(root)

    pro.service = pro.make_service(read=swapping)
    job = pro.run()
    assert job.outcome == "failed" and job.code == "device_changed"
    assert not (pro.root / "FIRMWARE.BIN").exists()
    assert pro.ops.held_during == []
    assert not firmware_hold.any_held()


# --- download failures leave the device alone ----------------------------------------------------


def test_a_failed_download_writes_nothing_and_says_so(pro: Rig) -> None:
    pro.package = b"x" * 100  # the server sends something that is not the pinned package
    job = pro.run()
    assert job.outcome == "failed" and job.code == "bad_hash"
    assert "old firmware" in job.what_to_do
    assert pro.ops.held_during == [] and not (pro.root / "FIRMWARE.BIN").exists()
    assert not any((pro.tmp / "state").rglob("*.zip"))


# --- the drive that hit the wall by hand -----------------------------------------------------------


def test_the_hand_update_failure_is_fixed_by_the_cleanup(pro: Rig) -> None:
    # Fill the directory so a plain copy fails exactly as it did by hand.
    (pro.root / "._INIT.LED").write_bytes(bytes.fromhex("00051607") + bytes(4092))
    pro.ops = AssertingFat(capacity_entries=16)
    plain = pro.ops
    with pytest.raises(OSError):
        plain.write_file(pro.root, "FIRMWARE.BIN", make_image("pro"), replace=False)
    pro.service = pro.make_service(ops=pro.ops)
    job = pro.run()
    assert job.outcome == "updated"


def test_a_drive_that_stays_full_is_refused_with_the_names_in_the_way(pro: Rig) -> None:
    for index in range(4):
        (pro.root / f"keep-this-document-{index}.txt").write_text("mine")
    job = pro.run()
    assert (job.outcome, job.code) == ("failed", "drive_full")
    assert "keep-this-document-0.txt" in job.message
    assert (pro.root / "keep-this-document-0.txt").exists()
    assert not (pro.root / "FIRMWARE.BIN").exists()
    assert not firmware_hold.any_held()


# --- the document the app sees -------------------------------------------------------------------------


def test_the_job_document_names_the_phase_in_plain_words(pro: Rig) -> None:
    job = pro.service.begin_update(pro.ref.id, confirm=True)
    document = pro.service.job_document()
    assert document is not None
    assert document["phase"] == "checking" and document["phase_label"] == "Checking the device"
    assert document["outcome"] is None and document["download"] is None
    assert document["device"] == pro.ref.id and document["from_version"] == "1.0.2"
    pro.service.execute(job)
    finished = pro.service.job_document()
    assert finished["outcome"] == "updated" and finished["phase"] == "done"
    assert finished["download"] is None


def test_a_finished_job_leaves_the_state_after_ten_minutes(pro: Rig) -> None:
    pro.run()
    assert pro.service.job_document() is not None
    pro.world.now += FINISHED_JOB_SECONDS + 1
    assert pro.service.job_document() is None


def test_the_background_start_reports_through_on_change(pro: Rig) -> None:
    job = pro.service.start_update(pro.ref.id, confirm=True)
    assert pro.finished.wait(10.0)
    assert job.outcome == "updated"
    assert pro.phases[0] == "checking" and pro.phases[-1] == "done"
