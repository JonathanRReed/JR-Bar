from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar import focus_sync, status_bar
from jrbar.dnd_policy import DisplayAdmission, DndMode, DndSource, OutboundAdmission
from jrbar.settings import AgentMonitorSettings
from tests.test_core_runtime import headless  # noqa: F401
from tests.test_dnd_controller import _active_focus, _FocusClient, _Harness

_ACTUAL_NAMED_READER = focus_sync.active_focus_mode_identifiers
_KNOWN_ROW = {"assertionDetailsModeIdentifier": "synthetic.work"}
_UNKNOWN_ROW = {"unrecognizedModeIdentifier": "synthetic.sleep"}


def _write_assertions(path: Path, records: object) -> None:
    path.write_text(json.dumps({"storeAssertionRecords": records}))


@pytest.mark.parametrize(
    "records",
    [
        pytest.param([_UNKNOWN_ROW], id="unknown"),
        pytest.param([_KNOWN_ROW, _UNKNOWN_ROW], id="mixed"),
        pytest.param([{"assertionDetailsModeIdentifier": "a" * 257}], id="ascii-over-limit"),
        pytest.param([{"assertionDetailsModeIdentifier": "é" * 129}], id="utf8-over-limit"),
        pytest.param([{"assertionDetailsModeIdentifier": "\ud800"}], id="escaped-surrogate"),
        pytest.param(
            [{"assertionDetailsModeIdentifier": f"synthetic.mode.{index}"} for index in range(65)],
            id="too-many-identifiers",
        ),
        pytest.param({"unexpected": [_KNOWN_ROW]}, id="malformed-record-list"),
    ],
)
def test_display_worker_publishes_unknown_named_focus_and_recovers(
    headless, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, records: object  # noqa: F811
) -> None:
    path = tmp_path / "Assertions.json"
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", path)
    # The shared headless fixture stubs this reader during composition.
    # Restore the actual parser for the worker and its error handling.
    monkeypatch.setattr(focus_sync, "active_focus_mode_identifiers", _ACTUAL_NAMED_READER)
    headless.applicationDidFinishLaunching_(None)
    headless._focus_ids_cache = (0.0, ["synthetic.previous"])
    headless.last_active_focus_ids = {"synthetic.previous"}
    command = status_bar.RuntimeWorkCommand(
        domain=status_bar.RuntimeWorkerDomain.OS_POLL,
        key="display-environment",
        generation=1,
        deadline=10.0,
        payload=status_bar.DisplayEnvironmentRequest(
            read_brightness=False, read_focus=True, read_accessibility=False,
        ),
    )

    for rows, available, identifiers in (
        (records, False, ()),
        ([_KNOWN_ROW], True, ("synthetic.work",)),
        ([], True, ()),
    ):
        _write_assertions(path, rows)
        result = headless._execute_os_poll_command(command)
        assert result.focus_available is available
        assert result.active_focus_ids == identifiers
        headless._apply_display_environment_result(result)
        assert headless._focus_ids_cache[1] == list(identifiers)
        assert headless.last_active_focus_ids == set(identifiers)
        assert headless._focus_observation_available is available
        assert headless._core_build_state()["focus"]["named_readable"] is available


@pytest.mark.parametrize("records", [[_UNKNOWN_ROW], [_KNOWN_ROW, _UNKNOWN_ROW]])
def test_public_active_focus_preserves_pause_when_named_detail_is_unknown(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, records: list[object]
) -> None:
    path = tmp_path / "Assertions.json"
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", path)
    _write_assertions(path, records)
    observation = _active_focus()
    client = _FocusClient(observation)
    settings = (
        AgentMonitorSettings()
        .with_focus_sync_enabled(True)
        .with_dnd_focus_mode(DndMode.PAUSE)
        .with_focus_dim_rule("synthetic.work", 0.4)
    )
    harness = _Harness(settings, focus=client, named_reader=_ACTUAL_NAMED_READER)
    controller = harness.controller
    try:
        assert controller.start().applied
        assert controller.named_focus_identifiers == ()
        assert controller.projection.active_sources == (DndSource.MACOS_FOCUS,)
        assert controller.projection.mode is DndMode.PAUSE
        public_contribution = controller.projection.contributions[0]

        _write_assertions(path, [_KNOWN_ROW])
        assert controller.refresh().applied
        assert controller.named_focus_identifiers == ("synthetic.work",)
        assert controller.projection.active_sources == (
            DndSource.MACOS_FOCUS, DndSource.NAMED_FOCUS,
        )
        assert controller.projection.contributions[0] == public_contribution
        assert controller.projection.display_admission is DisplayAdmission.CRITICAL
        assert controller.projection.outbound_admission is OutboundAdmission.CRITICAL
        assert controller.focus_observation == observation
        assert client.request_count == 0
    finally:
        controller.close()


def test_display_worker_handles_deep_json_and_recovers(
    headless, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,  # noqa: F811
) -> None:
    import sys

    path = tmp_path / "Assertions.json"
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", path)
    monkeypatch.setattr(focus_sync, "active_focus_mode_identifiers", _ACTUAL_NAMED_READER)
    headless.applicationDidFinishLaunching_(None)
    command = status_bar.RuntimeWorkCommand(
        domain=status_bar.RuntimeWorkerDomain.OS_POLL,
        key="display-environment", generation=1, deadline=10.0,
        payload=status_bar.DisplayEnvironmentRequest(
            read_brightness=False, read_focus=True, read_accessibility=False,
        ),
    )
    depth = sys.getrecursionlimit() + 100
    path.write_text("[" * depth + "{}" + "]" * depth)
    result = headless._execute_os_poll_command(command)
    assert result.focus_available is False
    assert result.active_focus_ids == ()
    headless._apply_display_environment_result(result)
    assert headless._core_build_state()["focus"]["named_readable"] is False
    _write_assertions(path, [_KNOWN_ROW])
    recovered = headless._execute_os_poll_command(command)
    assert recovered.focus_available is True
    assert recovered.active_focus_ids == ("synthetic.work",)
    headless._apply_display_environment_result(recovered)
    assert headless._core_build_state()["focus"]["named_readable"] is True


@pytest.mark.parametrize("broken_file", ["assertions", "configurations"])
def test_list_focuses_handles_deep_json_and_recovers(
    headless, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, broken_file: str,  # noqa: F811
) -> None:
    import sys

    from jrbar import core_runtime

    assertions = tmp_path / "Assertions.json"
    configurations = tmp_path / "ModeConfigurations.json"
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", assertions)
    monkeypatch.setattr(focus_sync, "MODE_CONFIGURATIONS_PATH", configurations)
    monkeypatch.setattr(focus_sync, "active_focus_mode_identifiers", _ACTUAL_NAMED_READER)
    _write_assertions(assertions, [_KNOWN_ROW])
    roster = '{"modeIdentifier":"synthetic.work","name":"Work"}'
    configurations.write_text(roster)
    depth = sys.getrecursionlimit() + 100
    broken = assertions if broken_file == "assertions" else configurations
    broken.write_text("[" * depth + "{}" + "]" * depth)
    reply = core_runtime._cmd_list_focuses(headless, {})
    assert reply["available"] is (broken_file == "assertions")
    assert reply["active_available"] is False
    assert reply["active"] == []
    assert reply["active_reason"] == "Active Focus mode names unavailable"
    assert reply["focuses"] == (
        [{"id": "synthetic.work", "name": "Work"}] if broken_file == "assertions" else []
    )
    _write_assertions(assertions, [_KNOWN_ROW])
    configurations.write_text(roster)
    recovered = core_runtime._cmd_list_focuses(headless, {})
    assert recovered["available"] is True
    assert recovered["active_available"] is True
    assert recovered["active"] == ["synthetic.work"]
    assert recovered["focuses"] == [{"id": "synthetic.work", "name": "Work"}]
    assert recovered["reason"] is None and recovered["active_reason"] is None
