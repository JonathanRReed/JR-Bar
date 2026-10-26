"""Keep the measured failure baseline separate from the checker's own tests."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from types import SimpleNamespace

import pytest
from light_audit import (
    Case,
    Firmware,
    baseline_delta,
    catalogue,
    inspect,
    settings_for,
    statuses,
    sweep_errors,
    topologies,
)
from test_core_runtime import _pro_and_dot
from test_core_runtime import headless as headless
from test_light_mix import cue_for

from jrbar.ambient_effect_consumer import active_ambient_presentation
from jrbar.ambient_effect_dispatch import AmbientEffectSurface, compile_ambient_effect_dispatch
from jrbar.ambient_layers import compose_ambient_layer
from jrbar.animation import read_program, step_duration_ms
from jrbar.colors import PROVIDER_ANIMATION_CHOICES, program_for_snapshot
from jrbar.dot_role import replace_brightness_line
from jrbar.led_status import AgentLedController, LedDisplayState
from jrbar.semantic_effect_router import SemanticEffectCandidate, SemanticEventKind, route_semantic_effects

BASELINE = Path(__file__).with_name("fixtures") / "light-audit-baseline.json"


def test_catalogue_and_topologies_cover_the_requested_axes():
    variants = catalogue()
    assert {v.motion for v in variants} == set(PROVIDER_ANIMATION_CHOICES)
    for motion in PROVIDER_ANIMATION_CHOICES:
        assert {f"{motion}.{p}" for p in ("default", "low", "high")} <= {v.name for v in variants}
    assert len([v for v in variants if v.name.startswith("custom.")]) == 3
    assert {(sum(counts), len(counts)) for counts in topologies()} == {
        (agents, providers) for agents in range(1, 7) for providers in range(1, min(3, agents) + 1)}
    assert (4, 1, 1) in topologies() and (2, 2, 2) in topologies()


def test_checker_rejects_skipped_and_one_way_bouncing_heads():
    def frames(path):
        return [tuple((100, 0, 0) if i == head else (0, 0, 0) for i in range(4)) for head in path]

    assert not sweep_errors(frames([0, 1, 2, 3, 2, 1, 0]), (0, 1, 2, 3), "kitt")
    assert sweep_errors(frames([0, 3, 0]), (0, 1, 2, 3), "kitt")
    assert "no return pass" in sweep_errors(frames([0, 1, 2, 3]), (0, 1, 2, 3), "scanner")
    assert not sweep_errors(frames([0, 1, 2, 3, 0]), (0, 1, 2, 3), "chase")


@pytest.mark.parametrize("motion", ("kitt", "scanner", "pendulum"))
def test_audit_measures_contiguous_everyone_sweeps(motion):
    variant = next(v for v in catalogue() if v.name == motion + ".default")
    result = inspect(Case(variant, "round_robin", (1, 1), 8, "working"), Firmware())
    assert {"sweep_path", "share_fidelity"} <= result.checks
    assert not result.failures


@pytest.mark.parametrize("motion", ("breathe", "heartbeat", "ember"))
def test_audit_uses_provider_colours_after_collapsing_sessions(motion):
    variant = next(v for v in catalogue() if v.name == motion + ".default")
    result = inspect(Case(variant, "round_robin", (2, 1, 1), 8, "working"), Firmware())
    assert "share_fidelity" in result.checks
    assert not result.failures


def test_baseline_detects_regressions_and_reports_resolved_cases():
    new, resolved = baseline_delta({"sweep_path": ["b"], "budget": ["c"]}, {"sweep_path": ["a", "b"]})
    assert new == {"budget": ["c"]}
    assert resolved == {"sweep_path": ["a"]}


def test_ask_check_allows_ambient_shares_beside_the_full_ask_crest():
    case = Case(catalogue()[0], "color_blend", (1, 1), 8, "ask")
    result = inspect(case, Firmware())
    assert "ask_priority" in result.checks
    assert "ask_priority" not in result.failures


@pytest.mark.parametrize("motion", ("heartbeat", "blink", "ember", "ripple"))
@pytest.mark.parametrize("leds", (2, 8))
def test_solo_darkness_allows_the_motions_own_settle_and_rest(motion, leds):
    variant = next(v for v in catalogue() if v.name == motion + ".default")
    result = inspect(Case(variant, "round_robin", (1,), leds, "working"), Firmware())
    assert "dark_share" in result.checks
    assert "dark_share" not in result.failures


def test_recorded_baseline_has_no_new_failures():
    baseline = json.loads(BASELINE.read_text())
    firmware = Firmware()
    actual = {}
    keys = set()
    # All catalogue families, every mix, both devices. The CLI owns the full
    # 199,584-case run; this bounded test catches baseline regressions in CI.
    variants = [v for v in catalogue() if v.name.endswith(".default")]
    for variant in variants:
        for mix in ("spatial_split", "round_robin", "cycle", "alternate", "relay", "weave", "tide", "classic", "color_blend"):
            for leds in (8, 2):
                case = Case(variant, mix, (1, 1), leds, "working")
                keys.add(case.key)
                result = inspect(case, firmware)
                for code in result.failures:
                    actual.setdefault(code, []).append(case.key)
    expected = {code: [key for key in values if key in keys] for code, values in baseline["failures"].items()}
    new, _resolved = baseline_delta(actual, expected)
    assert not new, new


def bank():
    if path := os.environ.get("JRBAR_AUDIT_PROGRAMS"):
        return json.loads(Path(path).read_text())
    return [{"leds": leds, "program": program_for_snapshot(statuses((1, 1), "working"),
                colors=settings_for(v, "spatial_split"), led_count=leds)[1], "case": v.name}
            for v in catalogue() if v.name.endswith(".default") for leds in (8, 2)]


def test_mirror_publishes_every_audited_program(headless):
    controller = headless
    pro, dot = _pro_and_dot(controller)
    controller.settings = controller.settings.with_link_screen_bar_to_hardware(True).with_dot_role("status")
    for row in bank():
        device = dot if row["leds"] == 2 else pro
        controller.status_bar_devices = lambda *, remember=True, device=device: [device]
        delivery = controller.agent_led_controllers_by_device[device.device_id]
        delivery.last_nominal_program = delivery.last_program = row["program"]
        controller._core_hardware_anchor[device.device_id] = 1000.0
        # A conflicting virtual call must not displace a linked hardware mirror.
        controller.virtual_status_device._live_program_call = ("#FF0000", {"started_at": 2000.0})
        lights = controller._core_build_lights()
        bar = lights["surfaces"]["screen_bar"]
        expected = row["program"]
        assert bar["source_led_count"] == row["leds"], row["case"]
        assert expected is not None, row["case"]
        # Each surface has its own brightness policy; compare motion at 255.
        actual = replace_brightness_line(bar["program"], 255)
        expected = replace_brightness_line(expected, 255)
        assert actual == expected, row["case"]
        assert bar["anchor"] == 1000.0, row["case"]
        # Parse/budget/pixel checks belong to inspect() and its recorded
        # baseline. This checks the live publication path even for a mirror
        # that the display parser will reject.


def test_cue_retains_timeline_and_expires_within_two_seconds(monkeypatch):
    dispatch = compile_ambient_effect_dispatch(semantic_selection=route_semantic_effects((
        SemanticEffectCandidate("synthetic:completion", SemanticEventKind.COMPLETION),)))
    owner = SimpleNamespace(_ambient_effect_dispatch=dispatch, _ambient_effect_dispatch_started_at=10.0)
    monkeypatch.setattr("jrbar.ambient_effect_consumer.time.monotonic", lambda: 11.99)
    cue = active_ambient_presentation(owner, AmbientEffectSurface.SIDEPULSE_PRO,
                                     reduce_motion=False, brightness=255)
    assert cue is not None
    monkeypatch.setattr("jrbar.ambient_effect_consumer.time.monotonic", lambda: 12.0)
    assert active_ambient_presentation(owner, AmbientEffectSurface.SIDEPULSE_PRO,
                                      reduce_motion=False, brightness=255) is None
    firmware = Firmware()
    for row in bank():
        base = row["program"]
        cue = cue_for("celebration", row["leds"])
        layered = compose_ambient_layer(base, LedDisplayState.WORKING, cue)
        assert re.sub(r"#[0-9A-Fa-f]{6}", "COLOR", layered) == re.sub(r"#[0-9A-Fa-f]{6}", "COLOR", base)
        before, _ = read_program(base, led_count=row["leds"])
        after, _ = read_program(layered, led_count=row["leds"])
        assert [step_duration_ms(s) for s in before.steps] == [step_duration_ms(s) for s in after.steps]
        firmware.trace(layered, row["leds"])
        for state in (LedDisplayState.ASK, LedDisplayState.FAILED):
            assert compose_ambient_layer(base, state, cue) == base


def test_controller_reassert_writes_the_bytes_measured_by_the_checker(tmp_path, monkeypatch):
    # The real controller writes only inside pytest's temporary directory.
    clock = [10.0]
    monkeypatch.setattr("jrbar.led_status.time.monotonic", lambda: clock[0])
    controller = AgentLedController(device_path=tmp_path)
    variant = next(v for v in catalogue() if v.name == "kitt.default")
    program = program_for_snapshot(statuses((1, 1), "working"),
                                   colors=settings_for(variant, "spatial_split"))[1]
    first = controller.sync_program(program, LedDisplayState.WORKING)
    assert first.changed
    clock[0] = 299.0
    second = controller.sync_program(program, LedDisplayState.WORKING)
    if second.changed:
        assert second.target is not None
        assert second.target.read_text() == second.program
    else:
        assert controller.last_error is None
        assert first.target.read_text() == first.program
