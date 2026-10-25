"""L1 verifier repros, using scratch devices and the packaged firmware."""
from types import SimpleNamespace

import pytest

from jrbar.ambient_effect_consumer import active_hardware_ambient_presentation
from jrbar.ambient_effect_dispatch import AmbientEffectFamily, AmbientEffectSurface, compile_ambient_effect_dispatch
from jrbar.ambient_effect_runtime import _merge_runtime_dispatch
from jrbar.colors import ColorSettings, program_for_snapshot
from jrbar.led_status import AgentLedController, _steady_state_variant
from jrbar.led_wasm import RawSdLedWasmController
from jrbar.turn_length_ember import plan_turn_length_ember
from tests.test_light_mix import statuses


@pytest.mark.parametrize("family", tuple(AmbientEffectFamily))
def test_only_named_cues_expire_after_two_seconds(monkeypatch, family):
    from dataclasses import replace

    from jrbar.ambient_effect_consumer import active_ambient_presentation
    from jrbar.ambient_layers import is_short_cue
    from jrbar.semantic_effect_router import SemanticEffectCandidate, SemanticEventKind, route_semantic_effects

    dispatch = compile_ambient_effect_dispatch(semantic_selection=route_semantic_effects((
        SemanticEffectCandidate("synthetic:ask", SemanticEventKind.ASK),)))
    output = replace(dispatch.for_surface(AmbientEffectSurface.SCREEN_BAR), family=family)
    owner = SimpleNamespace(_ambient_effect_dispatch=replace(dispatch, outputs=(output,)),
        _ambient_effect_dispatch_started_at=10.0)
    monkeypatch.setattr("jrbar.ambient_effect_runtime.time.monotonic", lambda: 13.0)
    presentation = active_ambient_presentation(owner, AmbientEffectSurface.SCREEN_BAR,
        reduce_motion=False, brightness=255)
    assert (presentation is None) == is_short_cue(output)
    if presentation is not None:
        assert presentation.next_visual_change_at == 18.0


def ember_writes(tmp_path, monkeypatch, *, ambient_enabled=True):
    clock = [1000.0]
    monkeypatch.setattr("jrbar.led_status.time.monotonic", lambda: clock[0])
    colors = ColorSettings.defaults()
    owner = SimpleNamespace(settings=SimpleNamespace(colors=colors),
        last_snapshot=SimpleNamespace(statuses=statuses(1)))
    controller = AgentLedController(device_path=tmp_path)
    writes, epochs = [], []
    for second in range(600):
        clock[0] = 1000.0 + second
        proposed = compile_ambient_effect_dispatch(
            turn_length_ember=plan_turn_length_ember(elapsed_seconds=120 + second))
        dispatch, started = _merge_runtime_dispatch(owner, proposed, now=clock[0])
        owner._ambient_effect_dispatch = dispatch
        owner._ambient_effect_dispatch_started_at_by_surface = started
        epochs.append(started[AmbientEffectSurface.SIDEPULSE_PRO])
        ambient = active_hardware_ambient_presentation(owner, device_id="synthetic:pro",
            led_count=8, reduce_motion=False, brightness=255)
        if controller.sync_snapshot(statuses(1), colors, ambient=ambient if ambient_enabled else None).changed:
            writes.append(second)
    return writes, epochs


def test_ember_renewal_never_replays_the_same_age_band(tmp_path, monkeypatch):
    writes, epochs = ember_writes(tmp_path, monkeypatch)
    assert epochs[:480] == [1000.0] * 480
    assert epochs[480:] == [1480.0] * 120
    assert writes == [0, 2, 240, 480, 482]


def test_ten_minute_ember_write_budget_tracks_base_reasserts(tmp_path, monkeypatch):
    from jrbar.ambient_layers import LAYER_SECONDS

    base = tmp_path / "base"
    ambient = tmp_path / "ambient"
    base.mkdir()
    ambient.mkdir()
    base_writes, _ = ember_writes(base, monkeypatch, ambient_enabled=False)
    writes, epochs = ember_writes(ambient, monkeypatch)
    band_starts = [index for index, epoch in enumerate(epochs)
                   if index == 0 or epoch != epochs[index - 1]]
    assert base_writes == [0, 240, 480]
    assert len(writes) <= len(base_writes) + 2 * len(band_starts)
    assert all(any(0 <= second - start <= LAYER_SECONDS for start in band_starts)
               for second in set(writes) - set(base_writes))


def test_automatic_reassert_jump_matches_base_and_breath_keeps_both_halves():
    _state, program = program_for_snapshot(statuses(1), colors=ColorSettings.defaults())
    written = _steady_state_variant(program, single_track=True)
    assert written != program
    firmware = [RawSdLedWasmController(8), RawSdLedWasmController(8)]
    jumps = []
    for at_ms in (1300, 3700, 5100, 9100):
        for engine in firmware:
            engine.reset(0)
            assert engine.parse(program, 0).ok
            engine.step_batch(0, 20, at_ms // 20)
        baseline = firmware[0].step_batch(at_ms, 20, 30)
        assert firmware[1].parse(written, at_ms).ok
        reasserted = firmware[1].step_batch(at_ms, 20, 30)
        jumps.append(max(abs(a - b) for left, right in zip(baseline, reasserted)
            for lp, rp in zip(left, right) for a, b in zip(lp, rp)))
    assert max(jumps) <= 45
    halves = "#050505 3s cosine\n#808080 3s cosine\nrepeat"
    assert _steady_state_variant(halves) == halves
    breath = ColorSettings.defaults().with_agent_animation("codex", "breathe")
    _state, program = program_for_snapshot(statuses(1), colors=breath)
    assert len(_steady_state_variant(program, single_track=True).splitlines()) == 3


@pytest.mark.parametrize("cue", ("completion", "all_clear", "reset_celebration"))
def test_legacy_celebrations_layer_briefly_while_an_agent_works(monkeypatch, cue):
    from jrbar.ambient_effect_consumer import active_ambient_presentation
    from jrbar.ambient_layers import compose_ambient_layer
    from jrbar.attention import LifecycleMode
    from jrbar.celebrations import RESET_CELEBRATION_SECONDS

    now = [100.0]
    monkeypatch.setattr("jrbar.ambient_effect_runtime.time.monotonic", lambda: now[0])
    owner = SimpleNamespace(settings=SimpleNamespace(completion_sweep_enabled=True),
        current_attention_projection=SimpleNamespace(light_rows=(SimpleNamespace(lifecycle_mode=LifecycleMode.ACTIVE),)),
        may_interrupt=lambda _signal: True, interrupt_hold_seconds=lambda _signal: 5.0,
        completion_sweep_until=104.0 if cue == "completion" else 0.0,
        all_clear_until=102.6 if cue == "all_clear" else 0.0,
        quota_reset_celebration_until=99.0 + RESET_CELEBRATION_SECONDS if cue == "reset_celebration" else 0.0)
    presentation = active_ambient_presentation(owner, AmbientEffectSurface.SCREEN_BAR,
        reduce_motion=False, brightness=255)
    assert presentation is not None
    expected_color = {"completion": "#00FF66", "all_clear": "#F5EDE0", "reset_celebration": "#FFD700"}[cue]
    assert presentation.nominal_static_fallback_program == expected_color
    assert presentation.next_visual_change_at == 101.0
    state, base = program_for_snapshot(statuses(1), colors=ColorSettings.defaults())
    assert compose_ambient_layer(base, state, presentation) != base
    now[0] = 101.1
    assert active_ambient_presentation(owner, AmbientEffectSurface.SCREEN_BAR,
        reduce_motion=False, brightness=255) is None
    now[0] = 100.0
    owner.may_interrupt = lambda _signal: False
    assert active_ambient_presentation(owner, AmbientEffectSurface.SCREEN_BAR,
        reduce_motion=False, brightness=255) is None


@pytest.mark.parametrize("animation", ("auto", "kitt", "breathe", "chase"))
def test_one_at_a_time_turns_stay_four_seconds_across_reasserts(tmp_path, monkeypatch, animation):
    from itertools import groupby

    clock = [1000.0]
    monkeypatch.setattr("jrbar.led_status.time.monotonic", lambda: clock[0])
    settings = ColorSettings.defaults().with_blend_mode("cycle")
    for provider in ("codex", "claude"):
        settings = settings.with_agent_animation(provider, animation)
    controller = AgentLedController(device_path=tmp_path)
    raw = RawSdLedWasmController(8)
    for second in (0, 240, 480):
        clock[0] = 1000.0 + second
        write = controller.sync_snapshot(statuses(2), settings)
        assert write.changed
        assert raw.parse(write.nominal_program, second * 1000).ok
        frames = raw.step_batch(second * 1000, 20, 1250)
        owners = [sum(b for r, g, b in frame) > sum(r for r, g, b in frame) for frame in frames]
        turns = [len(tuple(turn)) * 20 for _, turn in groupby(owners)]
        assert len(turns) >= 6
        assert all(abs(turn - 4000) <= 100 for turn in turns[2:-1]), turns
        assert _steady_state_variant(write.nominal_program) == write.nominal_program


def test_a_new_turn_in_the_same_ember_band_gets_a_new_layer(monkeypatch):
    colors = ColorSettings.defaults()
    owner = SimpleNamespace(settings=SimpleNamespace(colors=colors), _ambient_turn_starts={"synthetic:turn": 1.0})
    proposed = compile_ambient_effect_dispatch(turn_length_ember=plan_turn_length_ember(elapsed_seconds=1))
    first, starts = _merge_runtime_dispatch(owner, proposed, now=1000.0)
    owner._ambient_effect_dispatch = first
    owner._ambient_effect_dispatch_started_at_by_surface = starts
    owner._ambient_turn_starts = {"synthetic:turn": 5.0}
    second, renewed = _merge_runtime_dispatch(owner, proposed, now=1005.0)
    assert second.outputs == first.outputs
    assert all(epoch == 1005.0 for epoch in renewed.values())
