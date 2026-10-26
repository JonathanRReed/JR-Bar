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
from jrbar.light_mix import MIX_LABELS
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


@pytest.mark.parametrize("leds", (2, 8))
@pytest.mark.parametrize("counts", ((1, 1), (2, 1, 1)))
def test_audit_plays_the_selected_library_mix(leds, counts):
    variant = next(v for v in catalogue() if v.name == "kitt.default")
    result = inspect(Case(variant, "effect", counts, leds, "working"), Firmware())
    assert result.played == "effect", result.warnings
    assert not result.warnings
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
        for mix in MIX_LABELS:
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
        # The CLI checks Swift pixels against the delivered firmware corpus.
        # This checks the live publication path even for a mirror
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


def mutated_mix(tmp_path, monkeypatch, old, new):
    """Load the real production module with one defect restored in a scratch file."""
    import importlib.util

    import jrbar.light_mix as production

    text = Path(production.__file__).read_text()
    assert old in text
    path = tmp_path / "light_mix.py"
    path.write_text(text.replace(old, new, 1))
    spec = importlib.util.spec_from_file_location("jrbar._audit_mutant", path)
    module = importlib.util.module_from_spec(spec)
    # Dataclasses resolve their defining module during import.
    import sys
    monkeypatch.setitem(sys.modules, spec.name, module)
    spec.loader.exec_module(module)
    monkeypatch.setattr(production, "_shares", module._shares)
    monkeypatch.setattr(production, "_has_sweep", module._has_sweep)


@pytest.mark.parametrize("motion", ("kitt", "scanner", "pendulum"))
@pytest.mark.parametrize("mix", ("round_robin", "spatial_split"))
@pytest.mark.parametrize("glow", (0, 20))
def test_inspect_rejects_original_broken_automatic_follower(tmp_path, monkeypatch, motion, mix, glow):
    mutated_mix(tmp_path, monkeypatch, '''                leader = agents[explicit[0]]
                if (settings.agent_animation(leader.provider) in {"kitt", "scanner", "pendulum"}
                        and settings.animation_style("working") == "roll"):
                    tracks[index] = _follow_sweep(agent, leader, settings, share, chosen_spans)
                    continue
''', "")
    variant = next(v for v in catalogue() if v.name == f"{motion}.follow-glow{glow}")
    result = inspect(Case(variant, mix, (3, 2), 8, "working"), Firmware())
    assert "sweep_path" in result.failures, result.failures
    assert "claude" in result.failures["sweep_path"]
    assert "share_fidelity" in result.failures


@pytest.mark.parametrize("motion", ("kitt", "scanner", "pendulum"))
def test_inspect_rejects_shared_sweep_predicate_regression(tmp_path, monkeypatch, motion):
    mutated_mix(tmp_path, monkeypatch,
                'return any(settings.agent_animation(agent.provider) in {"kitt", "scanner", "pendulum"}\n'
                '               for agent in agents)', 'return False')
    variant = next(v for v in catalogue() if v.name == motion + ".default")
    result = inspect(Case(variant, "round_robin", (3, 2), 8, "working"), Firmware())
    assert {"sweep_path", "share_fidelity"} <= result.failures.keys(), result.failures


@pytest.fixture(scope="module")
def swift_sampler(tmp_path_factory):
    from swift_light_audit import build_sampler

    return build_sampler(tmp_path_factory.mktemp("swift-light-audit"))


def test_swift_mirror_matches_firmware(swift_sampler):
    from swift_light_audit import mirror_failures

    from jrbar.presentation_compiler import compile_presentation_program

    rows = []
    for row in bank():
        compiled = compile_presentation_program(row["program"], led_count=row["leds"])
        assert compiled.accepted
        rows.append(dict(row, program=compiled.program))
    assert not mirror_failures(swift_sampler, rows)


def test_swift_mirror_rejects_wrong_source_canvas(tmp_path):
    from swift_light_audit import REPO, build_sampler, mirror_failures

    sources = []
    for source in sorted((REPO / "app/Sources/JRBarLEDS").glob("*.swift")):
        path = tmp_path / source.name
        text = source.read_text()
        if source.name == "LEDSSampler.swift":
            old = "let ledCount = LEDSProgram.normalizedLedCount(requestedLedCount)"
            assert old in text
            text = text.replace(old, "let ledCount = LEDSProgram.normalizedLedCount(outputLedCount ?? requestedLedCount)", 1)
        path.write_text(text)
        sources.append(path)
    executable = build_sampler(tmp_path, sources=sources)
    rows = [{"case": "wrong-canvas", "leds": 2,
             "program": "brightness 128\n#FF0000 #00FF00 500ms none\nroll 2s\nrepeat"}]
    assert mirror_failures(executable, rows)


@pytest.mark.parametrize("motion,period", (("kitt", 2217), ("scanner", 1865), ("pendulum", 2217)))
def test_firmware_period_includes_seed_frame(motion, period):
    from jrbar.motion_shapes import render_motion

    lines = render_motion(motion, "#804020", "#000000", led_count=4, cycle_ms=2200, compact=True,
                          params={"beam_width": 3, "overlap": 0.5})
    # Map indexed local paints to the eight-LED emulator without changing time.
    program = "\n".join([*lines, "repeat"])
    firmware = Firmware()
    trace = firmware.trace(program, 8)
    assert trace.period == period
    controller = firmware.controllers[8]
    controller.reset(0)
    assert controller.parse(program, 0).ok
    frames = controller.step_batch(0, 1, period * 4)
    # Independently find the exact repeating lag from firmware playback.
    losses = {lag: sum(abs(a - b) for t in range(period, 2 * period)
                      for left, right in zip(frames[t], frames[t + lag])
                      for a, b in zip(left, right)) for lag in range(period - 20, period + 21)}
    assert min(losses, key=losses.get) == period
    assert losses[period] == 0
    assert losses[period - 17] > 0


def test_inspect_does_not_claim_python_mirror_pixel_verification():
    result = inspect(Case(catalogue()[0], "round_robin", (1,), 2, "working"), Firmware())
    assert "mirror_pixels" not in result.checks


def test_source_locations_survive_removed_source_needles():
    import importlib.util

    path = Path(__file__).resolve().parents[1] / "scripts/audit_lights.py"
    spec = importlib.util.spec_from_file_location("audit_lights_cli", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.source_location("src/jrbar/light_mix.py", "removed_source_needle") == "src/jrbar/light_mix.py"
    assert module.source_location("removed-source.py", "anything") == "removed-source.py"


def test_loop_seam_rejects_an_added_zero_span_seed_frame():
    firmware = Firmware()
    smooth = "#FF0000 1000ms linear\n#00FF00 1000ms linear\nrepeat"
    broken = "#FF0000 0ms\n" + smooth
    assert firmware.seam_error(smooth, 2) <= 41
    assert firmware.trace(broken, 2).period == 2017
    assert firmware.seam_error(broken, 2) > 41
