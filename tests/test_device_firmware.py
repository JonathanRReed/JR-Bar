"""Which firmware a SidePulse runs, from its own STATUS.TXT.

The field names and the version table come from the October 2026 review of
inteliwear/sidepulse (``firmware/README.md`` and its OTA packages). The
status text here is synthetic.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar import device_firmware as firmware
from jrbar.device_firmware import (
    FirmwareIdentity,
    describe_identity,
    identify_firmware,
    parse_status_fields,
)

PRO_OLD = "release_version 1.0.2\nserial SPP-000001\nfirmware_version 27251.50806\nfirmware_slot A\nuptime_ms 5\n"
PRO_NEW = "release_version 1.1.0\nserial SPP-000002\nfirmware_version 1.1.0\nfirmware_slot B\n"
DOT_OLD = "reads 4\nticks 9\nserial SPD-000003\napp_version 1.0.4\napp_build 2026-08-19T20:08:39Z\nfw_state idle\n"
DOT_NEW = "serial SPD-000004\napp_version 1.1.14\nfw_state idle\n"


def test_a_pro_reports_its_release_version() -> None:
    identity = identify_firmware(parse_status_fields(PRO_OLD))
    assert identity == FirmwareIdentity(model="pro", version="1.0.2", serial="SPP-000001")


def test_a_dot_reports_its_app_version() -> None:
    identity = identify_firmware(parse_status_fields(DOT_OLD))
    assert identity is not None
    assert (identity.model, identity.version, identity.serial) == ("dot", "1.0.4", "SPD-000003")


def test_the_other_field_pair_also_names_the_model() -> None:
    # Builds that report the staging fields without a version line.
    assert identify_firmware({"app_build": "x", "fw_state": "idle"}).model == "dot"
    assert identify_firmware({"firmware_version": "9", "firmware_slot": "A"}).model == "pro"


@pytest.mark.parametrize(
    "text",
    ["", "hello\n", "release_version 1.0.5\napp_version 1.0.5\n", "serial SPP-000001\n"],
)
def test_an_unreadable_or_contradictory_status_names_no_model(text: str) -> None:
    assert identify_firmware(parse_status_fields(text)) is None


def test_padding_after_the_text_is_ignored() -> None:
    assert identify_firmware(parse_status_fields(DOT_NEW + "\0" * 40)).version == "1.1.14"


@pytest.mark.parametrize(
    ("text", "behind"),
    [(PRO_OLD, True), (PRO_NEW, False), (DOT_OLD, True), (DOT_NEW, False)],
)
def test_a_device_is_behind_when_a_newer_release_is_published(text: str, behind: bool) -> None:
    identity = identify_firmware(parse_status_fields(text))
    assert identity is not None
    assert firmware.is_behind_latest(identity) is behind


def test_a_prerelease_is_behind_its_own_release_and_a_newer_device_is_not_behind() -> None:
    assert firmware.is_behind_latest(FirmwareIdentity("pro", "1.1.0-rc1", None)) is True
    assert firmware.is_behind_latest(FirmwareIdentity("pro", "1.2.0", None)) is False
    assert firmware.is_behind_latest(FirmwareIdentity("dot", "v1.1.14", None)) is False


def test_an_unparseable_version_is_neither_behind_nor_current() -> None:
    odd = FirmwareIdentity("pro", "unknown", None)
    assert firmware.is_behind_latest(odd) is None
    assert "unknown" in describe_identity(odd)


def test_a_pro_from_1_1_0_balances_colour_itself() -> None:
    # Firmware 1.1.0 applies calibrated WS2816 red/green/blue gains and rounds
    # brightness and balance once, so a hand-tuned gain stacks on top of it.
    assert firmware.balances_colour_itself(FirmwareIdentity("pro", "1.0.2", None)) is False
    assert firmware.balances_colour_itself(FirmwareIdentity("pro", "1.1.0", None)) is True
    assert firmware.balances_colour_itself(FirmwareIdentity("pro", "1.1.0-rc1", None)) is False
    assert firmware.balances_colour_itself(FirmwareIdentity("dot", "1.1.14", None)) is False


def test_describe_names_the_model_version_and_what_to_do() -> None:
    old = describe_identity(identify_firmware(parse_status_fields(PRO_OLD)))
    assert "SidePulse Pro" in old and "1.0.2" in old and "1.1.0" in old
    current = describe_identity(identify_firmware(parse_status_fields(DOT_NEW)))
    assert "SidePulse Dot" in current and "up to date" in current


def test_the_status_reader_is_the_fresh_one(tmp_path: Path) -> None:
    (tmp_path / "STATUS.TXT").write_text(PRO_NEW)
    seen: list[Path] = []

    def reader(path: Path) -> tuple[bytes, float]:
        seen.append(path)
        return path.read_bytes(), 1.0

    identity = firmware.read_identity(tmp_path, reader=reader)
    assert identity is not None and identity.version == "1.1.0"
    assert seen == [tmp_path / "STATUS.TXT"]
    assert firmware.read_identity(tmp_path / "missing", reader=reader) is None


def test_the_json_document_is_stable() -> None:
    identity = identify_firmware(parse_status_fields(PRO_OLD))
    document = firmware.identity_document(identity, root=Path("/Volumes/SidePulse"))
    assert json.loads(json.dumps(document)) == {
        "model": "pro",
        "name": "SidePulse Pro",
        "version": "1.0.2",
        "serial": "SPP-000001",
        "latest_known": "1.1.0",
        "behind": True,
        "device": "/Volumes/SidePulse",
        "color_balance_in_firmware": False,
    }


def _run(argv: list[str], capsys: pytest.CaptureFixture[str]) -> tuple[int, str, str]:
    from jrbar.cli import jrbar_main

    code = jrbar_main(argv)
    captured = capsys.readouterr()
    return code, captured.out, captured.err


def test_firmware_version_names_the_device_and_changes_nothing(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (tmp_path / "STATUS.TXT").write_text(PRO_OLD)
    before = sorted(path.name for path in tmp_path.iterdir())
    code, out, _err = _run(["firmware", "version", "--device", str(tmp_path)], capsys)
    assert code == 0
    assert "SidePulse Pro" in out and "1.0.2" in out and "1.1.0" in out
    assert sorted(path.name for path in tmp_path.iterdir()) == before


def test_firmware_version_json_is_a_list_of_documents(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (tmp_path / "STATUS.TXT").write_text(DOT_NEW)
    code, out, _err = _run(["firmware", "version", "--json", "--device", str(tmp_path)], capsys)
    assert code == 0
    [document] = json.loads(out)
    assert document["model"] == "dot" and document["behind"] is False
    assert document["device"] == str(tmp_path)


def test_firmware_version_says_so_when_a_drive_is_not_a_sidepulse(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    (tmp_path / "STATUS.TXT").write_text("hello\n")
    code, _out, err = _run(["firmware", "version", "--device", str(tmp_path)], capsys)
    assert code == 1
    assert "not a SidePulse" in err or "could not read" in err


def test_without_a_device_argument_every_mounted_sidepulse_is_read(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    pro = tmp_path / "SidePulse"
    dot = tmp_path / "PulseDot"
    other = tmp_path / "Backups"
    for volume, status in ((pro, PRO_NEW), (dot, DOT_OLD), (other, "hello\n")):
        volume.mkdir()
        (volume / "STATUS.TXT").write_text(status)
        (volume / "LEDS.LED").write_text("off\n")
    code = firmware.run_version_command(None, as_json=True, mount_root=tmp_path)
    out = capsys.readouterr().out
    assert code == 0
    assert sorted(item["model"] for item in json.loads(out)) == ["dot", "pro"]


def test_no_mounted_sidepulse_is_a_plain_message(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code = firmware.run_version_command(None, as_json=False, mount_root=tmp_path)
    assert code == 1
    assert "no mounted SidePulse" in capsys.readouterr().err


# --- the pinned catalog and the update facts -------------------------------------------


def test_the_latest_versions_come_from_the_catalog() -> None:
    assert firmware.LATEST_KNOWN_VERSIONS == {"pro": "1.1.0", "dot": "1.1.14"}
    for release in firmware.RELEASES:
        assert firmware.release_for(release.model) is release
        assert release.package_url.startswith(f"https://{firmware.PACKAGE_HOST}/")
        assert len(release.package_sha256) == len(release.image_sha256) == 64
        assert release.notes
    assert firmware.release_for("toaster") is None


def test_a_pro_reading_carries_the_slot_facts_the_update_needs() -> None:
    text = (
        PRO_OLD
        + "active_slot A\nfirmware_build 2026-08-05T23:25:42Z\nreboot_requested 0\n"
        + "A image=1 valid=1 version=27251.50806 build=2026-08-05T23:25:42Z hash=6378ab999ab0\n"
        + "B image=0 valid=1 version=none build=unknown hash=unknown\n"
    )
    reading = firmware.reading_from_fields(parse_status_fields(text))
    assert reading is not None
    assert reading.active_slot == "A" and reading.other_slot == "B"
    assert reading.build == "2026-08-05T23:25:42Z"
    assert reading.uptime_ms == 5
    assert reading.serial_matches_model
    assert reading.slot("A") == firmware.SlotInfo("A", True, True, "27251.50806")
    assert reading.slot("B") == firmware.SlotInfo("B", False, True, "none")
    assert reading.busy is None


def test_a_dot_reading_uses_its_ticks_as_a_clock() -> None:
    reading = firmware.reading_from_fields(parse_status_fields(DOT_OLD))
    assert reading is not None
    assert reading.uptime_ms == 9 and reading.build == "2026-08-19T20:08:39Z"
    assert reading.active_slot is None and reading.serial_matches_model


def test_a_serial_that_does_not_fit_the_model_is_flagged() -> None:
    reading = firmware.reading_from_fields(
        parse_status_fields("release_version 1.0.2\nserial SPD-000003\nfirmware_slot A\n")
    )
    assert reading is not None and not reading.serial_matches_model
    nameless = firmware.reading_from_fields(parse_status_fields("release_version 1.0.2\n"))
    assert nameless is not None and not nameless.serial_matches_model


@pytest.mark.parametrize(
    "extra",
    ["reboot_requested 1", "fw_reboot 1", "ota receiving", "state applying", "fw_state staging"],
)
def test_a_device_that_is_restarting_or_receiving_looks_busy(extra: str) -> None:
    text = (
        DOT_OLD.replace("fw_state idle", extra)
        if extra.startswith("fw_state")
        else DOT_OLD + extra + "\n"
        if extra.startswith("fw_")
        else PRO_OLD + extra + "\n"
    )
    reading = firmware.reading_from_fields(parse_status_fields(text))
    assert reading is not None and reading.busy is not None


def test_the_reading_is_read_past_the_cache(tmp_path: Path) -> None:
    (tmp_path / "STATUS.TXT").write_text(PRO_NEW)
    seen: list[Path] = []

    def reader(path: Path) -> tuple[bytes, float]:
        seen.append(path)
        return path.read_bytes(), 1.0

    reading = firmware.read_reading(tmp_path, reader=reader)
    assert reading is not None and reading.identity.version == "1.1.0"
    assert seen == [tmp_path / "STATUS.TXT"]
    assert firmware.read_reading(tmp_path / "missing", reader=reader) is None
