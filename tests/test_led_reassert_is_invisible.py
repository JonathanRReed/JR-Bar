"""A reassert refreshes device state without replaying the bright
transition frame -- the flash that read as an agent asking a question."""

from __future__ import annotations

from pathlib import Path

import pytest

from jrbar.led_status import (
    AgentLedController,
    LedDisplayState,
    _steady_state_variant,
)


def test_steady_state_variant_drops_only_the_approach_frame__and_1_more() -> None:
    # --- scenario: steady_state_variant_drops_only_the_approach_frame
    program = (
        "brightness 18\n"
        "// approach\n"
        "0:#F87C5F 160ms none; 1:#260C06 160ms none\n"
        "0:#010101 1600ms pulse 0ms; 1:#020305 1600ms pulse 200ms\n"
        "repeat"
    )
    assert _steady_state_variant(program) == (
        "brightness 18\n"
        "0:#010101 1600ms pulse 0ms; 1:#020305 1600ms pulse 200ms\n"
        "repeat"
    )

    # --- scenario: steady_state_variant_keeps_short_programs_intact
    for program in ("off", "#00FF00 1s", "brightness 40\n#00FF00 1s\nrepeat"):
        assert _steady_state_variant(program) == program



@pytest.mark.parametrize("program", [
    "#163A58 700ms linear\n#603A16 900ms cosine\nrepeat",
    "#163A58\n#603A16 900ms cosine\n#163A58 700ms linear\nrepeat",
    "0:#164880 1:#603A16\n#603A16 900ms cosine\n#164880 700ms linear\nrepeat",
])
def test_reassert_preserves_phase_across_repeated_device_writes(tmp_path, monkeypatch, program):
    from jrbar.led_wasm import RawSdLedWasmController

    clock = [100.0]
    monkeypatch.setattr("jrbar.led_status.time.monotonic", lambda: clock[0])
    controller = AgentLedController(device_path=tmp_path)
    first = controller.sync_program(program, LedDisplayState.IDLE)
    assert first.changed
    continuous = RawSdLedWasmController(8)
    restarted = RawSdLedWasmController(8)
    for engine in (continuous, restarted):
        engine.reset(0)
        assert engine.parse(first.program, 0).ok
    previous = 0
    for elapsed in (240736, 481472):
        for engine in (continuous, restarted):
            engine.step_batch(previous, 16, (elapsed - previous) // 16)
        clock[0] = 100.0 + elapsed / 1000
        update = controller.sync_program(program, LedDisplayState.IDLE)
        assert update.error is None
        if update.changed:
            assert update.timed.rotation == "exact"
            assert update.target.read_text() == update.program
            assert controller.last_program == update.program
            assert controller.last_applied_monotonic == clock[0]
            assert restarted.parse(update.program, elapsed).ok
        expected = continuous.step_batch(elapsed, 16, 100)
        actual = restarted.step_batch(elapsed, 16, 100)
        error = max(abs(a - b) for x, y in zip(expected, actual)
                    for p, q in zip(x, y) for a, b in zip(p, q))
        assert error <= 3
        previous = elapsed + 1600


def test_full_budget_reassert_keeps_running_when_a_phase_cut_cannot_fit(tmp_path, monkeypatch):
    from jrbar.linked_sync import PhaseRotationUnavailable

    clock = [100.0]
    monkeypatch.setattr("jrbar.led_status.time.monotonic", lambda: clock[0])
    controller = AgentLedController(device_path=tmp_path)
    program = "#163A58 700ms linear\n#603A16 900ms cosine\nrepeat"
    first = controller.sync_program(program, LedDisplayState.IDLE)
    before = first.target.read_bytes()

    def no_room(*args, **kwargs):
        raise PhaseRotationUnavailable("no room for a phase cut")

    monkeypatch.setattr("jrbar.linked_sync.apply_device_timing", no_room)
    clock[0] += 241
    update = controller.sync_program(program, LedDisplayState.IDLE)
    assert not update.changed
    assert update.error is None
    assert first.target.read_bytes() == before
    assert controller.last_applied_monotonic == 100.0


def test_the_strip_keeps_its_phase_free_dedupe(tmp_path: Path) -> None:
    """The strip's firmware loops the program, so phase must NOT write.

    A text compare here differs on essentially every call, the 60s reassert
    never engages, and the device is rewritten every refresh at about 30
    syscalls plus an fsync and a readback, to USB mass storage.
    """
    from datetime import datetime, timezone

    from jrbar.colors import BLEND_MODE_RELAY, ColorSettings
    from jrbar.models import AgentMode, AgentStatus

    statuses = tuple(
        AgentStatus(
            provider=provider,
            agent_id=f"{provider}:session:{provider}",
            display_name=provider,
            mode=AgentMode.WORKING,
            updated_at=datetime(2026, 8, 14, tzinfo=timezone.utc),
            event_name="PreToolUse",
            session_id=provider,
        )
        for provider in ("claude", "codex")
    )
    colors = ColorSettings.defaults().with_blend_mode(BLEND_MODE_RELAY)
    controller = AgentLedController(device_path=tmp_path, file_name="LEDS.LED")

    first = controller.sync_snapshot(statuses, colors, relay_elapsed_seconds=0.0)
    later = controller.sync_snapshot(statuses, colors, relay_elapsed_seconds=0.37)

    assert first.changed is True
    assert later.changed is False


def test_a_done_agent_rests_dark_beside_a_working_one() -> None:
    """The completion sweep is the celebration; a done agent's LEDs must
    not hold bright for the 20-minute visibility window afterwards."""
    from datetime import datetime, timezone
    from types import SimpleNamespace

    from jrbar.attention import project_attention
    from jrbar.colors import ColorSettings, program_for_projection
    from jrbar.led_wasm import LedWasmUnavailableError, SdLedWasmController
    from jrbar.models import AgentMode, AgentStatus
    from jrbar.settings import AgentMonitorSettings

    def status(provider, sid, mode, event):
        return AgentStatus(
            provider=provider,
            agent_id=f"{provider}:session:{sid}",
            display_name=sid,
            mode=mode,
            updated_at=datetime.now(timezone.utc),
            event_name=event,
            session_id=sid,
        )

    snap = SimpleNamespace(
        statuses=(
            status("claude", "a", AgentMode.COMPLETED, "Stop"),
            status("grok", "b", AgentMode.WORKING, "PostToolUse"),
        ),
        stale_statuses=(),
        collected_at=datetime.now(timezone.utc),
    )
    projection = project_attention(snap, AgentMonitorSettings())
    _state, program = program_for_projection(
        projection, led_count=8, colors=ColorSettings(), relay_elapsed_seconds=0.3
    )
    try:
        controller = SdLedWasmController(led_count=8)
    except LedWasmUnavailableError:
        import pytest

        pytest.skip("JavaScriptCore unavailable")
    assert controller.parse(program, 0).ok
    # The done agent's LEDs (alternating assignment) must never sit at a
    # held bright level across a full loop; sample generously.
    max_seen = [0] * 8
    for t in range(0, 8000, 40):
        pixels = controller.step(t)
        for index in range(8):
            max_seen[index] = max(max_seen[index], sum(pixels[index]))
    bright_leds = [index for index, value in enumerate(max_seen) if value > 400]
    # Only the WORKING agent's pulses may get bright; a steady-held done
    # peak lit half the strip before this rule.
    assert len(bright_leds) <= 4, (bright_leds, max_seen)


def test_calibrated_reassert_never_publishes_drive_bytes_as_nominal(tmp_path, monkeypatch):
    from jrbar.animation import read_program
    from jrbar.linked_sync import fits_budget, playback_loop_ms

    clock = [100.0]
    monkeypatch.setattr("jrbar.led_status.time.monotonic", lambda: clock[0])
    controller = AgentLedController(device_path=tmp_path, channel_gains=(1, 0.38, 1))
    program = '#164880 #040E1A #040E1A #040E1A #040E1A #040E1A #040E1A #040E1A 300ms cosine\nroll-right 2200ms linear\n#160C09 #160C09 #160C09 #160C09 #160C09 #160C09 #160C09 #6C3C2C 300ms cosine\nroll-left 2200ms linear\n#2E4258 #090D12 #090D12 #090D12 #090D12 #090D12 #090D12 #090D12 300ms cosine\nroll-right 2200ms linear\nrepeat'
    first = controller.sync_program(program, LedDisplayState.IDLE)
    assert first.changed
    lap = playback_loop_ms(read_program(first.program)[0])
    clock[0] += (int(241000 / lap) + 1.37) * lap / 1000
    update = controller.sync_program(program, LedDisplayState.IDLE)
    if update.changed:
        assert update.nominal_program != update.program
        assert fits_budget(update.nominal_program)
        assert update.nominal_program == update.timed.nominal_program
    else:
        assert first.target.read_text() == first.program
        assert controller.last_nominal_program == first.nominal_program
    assert controller.last_error is None
