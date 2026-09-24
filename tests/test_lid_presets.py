"""The lid looks, played through the real firmware on both devices.

A lid look is a finite moment: it plays once, then the live light takes the
strip back. So every look must parse on the Pro's eight LEDs and the Dot's
two, finish inside the time it claims, and leave the strip where the live
light expects it -- dark after an opening, black after a close (an ember of
the working agent's colour when agents are still running).
"""

from __future__ import annotations

import pytest

from jrbar import lid_presets
from jrbar._led_wasm_legacy import LedWasmUnavailableError, SdLedWasmController
from jrbar.animation import animation_duration_ms, loop_duration_ms, parse_animation
from jrbar.flash_analysis import relative_luminance
from jrbar.settings import (
    LID_ANIMATION_CLOSED,
    LID_ANIMATION_CLOSED_ACTIVE,
    LID_ANIMATION_OPEN,
    LID_ANIMATION_OPEN_ACTIVE,
    AgentMonitorSettings,
    LedAnimationSetting,
)

ACCENT = "#D97757"


def _drawn(kind: str, name: str, program: str, led_count: int) -> str:
    shape = lid_presets.LID_PRESET_SHAPES.get((kind, name))
    return lid_presets.lid_program(program, shape, led_count=led_count, accent=ACCENT)


def _last_frame(program: str, led_count: int, at_ms: int):
    try:
        controller = SdLedWasmController(led_count)
    except LedWasmUnavailableError as error:  # pragma: no cover - macOS only
        pytest.skip(f"firmware engine unavailable: {error}")
    controller.reset(0)
    result = controller.parse(program, 0)
    assert result.ok, f"firmware rejected {program!r}: {result.error_name}"
    return controller.step_batch(int(at_ms), 17, 1)[0]


def _presets():
    for kind, presets in lid_presets.LID_ANIMATION_PRESETS.items():
        for name, seconds, program in presets:
            for led_count in (8, 2):
                yield kind, name, seconds, program, led_count


def test_every_look_parses_on_both_devices_and_fits_its_time() -> None:
    for kind, name, seconds, program, led_count in _presets():
        drawn = _drawn(kind, name, program, led_count)
        animation = parse_animation(drawn, led_count=led_count)
        assert loop_duration_ms(animation) is None, f"{kind}/{name} loops"
        runtime = animation_duration_ms(animation)
        assert runtime <= seconds * 1000, (kind, name, led_count, runtime, seconds)
        _last_frame(drawn, led_count, 0)


def test_a_close_ends_black_and_an_opening_ends_dark() -> None:
    for kind, name, seconds, program, led_count in _presets():
        drawn = _drawn(kind, name, program, led_count)
        end = animation_duration_ms(parse_animation(drawn, led_count=led_count)) + 60
        frame = _last_frame(drawn, led_count, end)
        light = max(relative_luminance(pixel) for pixel in frame)
        if kind == LID_ANIMATION_CLOSED:
            assert all(pixel == (0, 0, 0) for pixel in frame), (kind, name, led_count, frame)
        elif kind == LID_ANIMATION_CLOSED_ACTIVE:
            # Still cooking: the lid shuts on an ember, never a lit strip.
            assert light <= 0.02, (kind, name, led_count, frame)
        else:
            assert light <= 0.001, (kind, name, led_count, frame)


def test_iris_is_drawn_for_each_device() -> None:
    """Upstream's lid programs came as an eight-LED and a two-LED file; the
    Iris looks are drawn for the device they play on instead."""
    opened_8 = lid_presets.render_lid_shape(lid_presets.LID_SHAPE_IRIS_OPEN, led_count=8)
    opened_2 = lid_presets.render_lid_shape(lid_presets.LID_SHAPE_IRIS_OPEN, led_count=2)
    assert opened_8 != opened_2
    assert "7:" in opened_8 and "7:" not in opened_2
    # The centre pair opens first; the rim follows.
    rise = opened_8.splitlines()[1]
    assert "3:#00E5FF 180ms ease;" in rise and "0:#00FF66 180ms ease 240ms" in rise
    closed = lid_presets.render_lid_shape(lid_presets.LID_SHAPE_IRIS_CLOSE, led_count=8)
    assert "0:#000000 75ms ease;" in closed and "3:#000000 75ms ease 225ms" in closed
    # The active looks take the working agent's colour.
    active = lid_presets.render_lid_shape(
        lid_presets.LID_SHAPE_IRIS_CLOSE_ACTIVE, led_count=8, accent=ACCENT
    )
    assert active.startswith(ACCENT)
    assert lid_presets.render_lid_shape("wormhole", led_count=8) is None


def test_the_player_draws_a_shape_look_per_device() -> None:
    from jrbar.status_bar_legacy import program_for_lid_animation

    name, seconds, program = lid_presets.preset(LID_ANIMATION_OPEN, "Iris")
    animation = LedAnimationSetting(program, seconds, shape=lid_presets.LID_SHAPE_IRIS_OPEN)
    pro = program_for_lid_animation(animation, led_count=8)
    dot = program_for_lid_animation(animation, led_count=2)
    assert "7:" in pro and "7:" not in dot
    # A program look plays the same everywhere, as before.
    hello = lid_presets.preset(LID_ANIMATION_OPEN, "Hello")
    plain = LedAnimationSetting(hello[2], hello[1])
    assert program_for_lid_animation(plain, led_count=2) == program_for_lid_animation(plain, led_count=8)


def test_jonathans_hello_and_cool_down_stay_picked() -> None:
    """His settings file holds the Hello text from before the openings all
    ended dark; it loads as today's Hello, still picked. Cool Down never
    changed. Iris is offered, not imposed."""
    import json
    import tempfile
    from pathlib import Path

    from jrbar.settings import load_settings

    old_hello = "#12E3B0 300ms pulse\n#0FA07C 300ms cosine\n#12E3B0 800ms pulse"
    cool_down = lid_presets.preset(LID_ANIMATION_CLOSED, "Cool Down")
    with tempfile.TemporaryDirectory() as folder:
        target = Path(folder) / "settings.json"
        target.write_text(
            json.dumps(
                {
                    "lid_open_animation": {"program": old_hello, "duration_seconds": 1.4},
                    "lid_closed_animation": {"program": cool_down[2], "duration_seconds": cool_down[1]},
                }
            )
        )
        settings = load_settings(target)
    opened = settings.lid_animation(LID_ANIMATION_OPEN)
    closed = settings.lid_animation(LID_ANIMATION_CLOSED)
    assert lid_presets.current_preset_name(LID_ANIMATION_OPEN, opened.program, opened.shape) == "Hello"
    assert opened.duration_seconds == 1.7
    assert lid_presets.current_preset_name(LID_ANIMATION_CLOSED, closed.program, closed.shape) == "Cool Down"
    assert closed.shape is None


def test_a_shape_round_trips_and_an_unknown_one_is_dropped() -> None:
    settings = AgentMonitorSettings().with_lid_animation(
        LID_ANIMATION_CLOSED_ACTIVE,
        program=lid_presets.preset(LID_ANIMATION_CLOSED_ACTIVE, "Iris (active)")[2],
        duration_seconds=1.5,
        shape=lid_presets.LID_SHAPE_IRIS_CLOSE_ACTIVE,
    )
    document = settings.to_dict()
    assert document["lid_closed_active_animation"]["shape"] == "iris_close_active"
    unknown = AgentMonitorSettings().with_lid_animation(
        LID_ANIMATION_OPEN_ACTIVE, program="#FFFFFF 200ms pulse", duration_seconds=1.0, shape="wormhole"
    )
    assert unknown.lid_animation(LID_ANIMATION_OPEN_ACTIVE).shape is None
    # Every Iris look is named once per transition, and each transition has one.
    kinds = {kind for kind, _name in lid_presets.LID_PRESET_SHAPES}
    assert kinds == {
        LID_ANIMATION_OPEN,
        LID_ANIMATION_CLOSED,
        LID_ANIMATION_OPEN_ACTIVE,
        LID_ANIMATION_CLOSED_ACTIVE,
    }


def test_the_lid_document_names_what_each_transition_plays() -> None:
    settings = AgentMonitorSettings()
    hello = lid_presets.preset(LID_ANIMATION_OPEN, "Hello")
    settings = settings.with_lid_animation(LID_ANIMATION_OPEN, program=hello[2], duration_seconds=hello[1])
    document = lid_presets.lid_presets_document(settings, accent=ACCENT)
    by_kind = {entry["kind"]: entry for entry in document["kinds"]}
    assert [entry["kind"] for entry in document["kinds"]] == [
        LID_ANIMATION_OPEN,
        LID_ANIMATION_CLOSED,
        LID_ANIMATION_OPEN_ACTIVE,
        LID_ANIMATION_CLOSED_ACTIVE,
    ]
    assert by_kind[LID_ANIMATION_OPEN]["current"] == "Hello"
    assert by_kind[LID_ANIMATION_CLOSED]["current"] is None
    assert by_kind[LID_ANIMATION_CLOSED]["shipped"] is True
    iris = next(p for p in by_kind[LID_ANIMATION_CLOSED_ACTIVE]["presets"] if p["name"] == "Iris (active)")
    assert iris["program"].startswith(ACCENT) and "7:" in iris["program"]
    assert "7:" not in iris["dot_program"]
    assert iris["setting"]["shape"] == lid_presets.LID_SHAPE_IRIS_CLOSE_ACTIVE


def test_the_app_can_list_lid_looks_finishes_and_a_providers_light() -> None:
    """The three read-only documents Effect Studio and Settings draw from."""
    from types import SimpleNamespace

    from jrbar import core_runtime

    settings = AgentMonitorSettings()
    settings = settings.with_colors(settings.colors.with_done_celebration_style("land"))
    host = SimpleNamespace(
        settings=settings,
        last_snapshot=None,
        agent_render_colors=lambda: settings.colors,
    )
    lids = core_runtime._cmd_list_lid_presets(host, {})
    assert [entry["kind"] for entry in lids["kinds"]] == ["open", "closed", "open_active", "closed_active"]
    finishes = core_runtime._cmd_list_finish_looks(host, {})
    assert finishes["current"] == "land"
    assert [look["style"] for look in finishes["looks"]] == ["bloom", "land", "ripple"]
    assert all(look["program"] and look["dot_program"] for look in finishes["looks"])
    light = core_runtime._cmd_preview_provider_motion(host, {"provider": "opencode", "led_count": 2})
    assert light["motion"] == "pendulum" and light["led_count"] == 2
    assert "repeat" in light["program"]


def test_iris_closes_on_what_was_lit_and_only_a_thumbnail_starts_cyan() -> None:
    """On the desk the Iris close starts from whatever the strip shows --
    never a flash of cyan first, even from idle-dark. A thumbnail starts
    dark, so only the drawings Effect Studio shows get the lead-in."""
    from jrbar.status_bar_legacy import program_for_lid_animation

    seed = f"{lid_presets.DEFAULT_LID_ACCENT} 200ms cosine"
    _name, seconds, program = lid_presets.preset(LID_ANIMATION_CLOSED, "Iris")
    assert not program.startswith(seed), "the stored program is the strip's"
    animation = LedAnimationSetting(program, seconds, shape=lid_presets.LID_SHAPE_IRIS_CLOSE)
    for led_count in (8, 2):
        played = program_for_lid_animation(animation, led_count=led_count)
        assert seed not in played, (led_count, played)
        assert played.splitlines()[0].startswith("0:#000000")
    document = lid_presets.lid_presets_document(AgentMonitorSettings(), accent=ACCENT)
    closed = next(entry for entry in document["kinds"] if entry["kind"] == LID_ANIMATION_CLOSED)
    iris = next(look for look in closed["presets"] if look["name"] == "Iris")
    assert iris["program"].startswith(seed) and iris["dot_program"].startswith(seed)
    assert not iris["setting"]["program"].startswith(seed)


def test_play_lid_preset_plays_the_look_drawn_for_each_device() -> None:
    """``play_lid_preset`` hands the lid player the look as a lid change
    would, shape and all; a look it does not know is refused."""
    from types import SimpleNamespace

    from jrbar import core_runtime
    from jrbar.core_server import CommandError

    played: list = []
    host = SimpleNamespace(
        play_lid_animation=lambda kind, animation=None: played.append((kind, animation))
    )
    reply = core_runtime._cmd_play_lid_preset(host, {"kind": LID_ANIMATION_CLOSED, "name": "Iris"})
    assert reply == {"kind": LID_ANIMATION_CLOSED, "name": "Iris", "seconds": 1.5}
    kind, animation = played[-1]
    assert kind == LID_ANIMATION_CLOSED
    assert animation.shape == lid_presets.LID_SHAPE_IRIS_CLOSE
    assert animation.program == lid_presets.preset(LID_ANIMATION_CLOSED, "Iris")[2]
    core_runtime._cmd_play_lid_preset(host, {"kind": LID_ANIMATION_OPEN, "name": "Hello"})
    assert played[-1][1].shape is None and played[-1][1].duration_seconds == 1.7
    with pytest.raises(CommandError) as refused:
        core_runtime._cmd_play_lid_preset(host, {"kind": LID_ANIMATION_OPEN, "name": "Wormhole"})
    assert refused.value.code == "invalid_args"
    assert len(played) == 2
