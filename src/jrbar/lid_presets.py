"""Lid animation presets -- pure data, extracted from settings_window for
its size ratchet (2026-08-26). Five looks per lid transition kind; every
program is firmware-parsed by tests.

Most looks are one program that plays the same on every device. The Iris
looks (upstream sidepulse #38's lid-open and lid-close programs,
reimplemented) are SHAPES instead: they open from the centre pair outward
or close from the edges inward, which only works if they are drawn for the
device's own LED count, so each is rendered per device when it plays -- the
Dot gets the two-LED form, as upstream's ``-2.LED`` files do. Their preset
tuples still carry the eight-LED program, so anything that reads presets as
plain programs keeps working.
"""

from __future__ import annotations

from . import motion_shapes as shapes
from .settings import (
    LID_ANIMATION_CLOSED,
    LID_ANIMATION_CLOSED_ACTIVE,
    LID_ANIMATION_OPEN,
    LID_ANIMATION_OPEN_ACTIVE,
)

#: The lid shapes a preset can name.
LID_SHAPE_IRIS_OPEN = "iris_open"
LID_SHAPE_IRIS_CLOSE = "iris_close"
LID_SHAPE_IRIS_OPEN_ACTIVE = "iris_open_active"
LID_SHAPE_IRIS_CLOSE_ACTIVE = "iris_close_active"
LID_SHAPES: tuple[str, ...] = (
    LID_SHAPE_IRIS_OPEN,
    LID_SHAPE_IRIS_CLOSE,
    LID_SHAPE_IRIS_OPEN_ACTIVE,
    LID_SHAPE_IRIS_CLOSE_ACTIVE,
)
#: The colour an Iris (active) look is drawn in when no agent's colour is
#: known yet: the working cyan.
DEFAULT_LID_ACCENT = "#00E5FF"
#: How much of the agent's colour an Iris (active) close keeps glowing:
#: the lid is shut, the work is not.
ACTIVE_CLOSE_EMBER = 0.12


def render_lid_shape(shape: str, *, led_count: int = 8, accent: str | None = None) -> str | None:
    """One lid shape as a finite program for a device with ``led_count``
    LEDs, or None for a name this build does not know.

    ``accent`` is the colour of the agent that is still working; only the
    Iris (active) looks use it.
    """
    count = max(2, int(led_count))
    color = accent or DEFAULT_LID_ACCENT
    if shape == LID_SHAPE_IRIS_OPEN:
        lines = shapes.iris_open(led_count=count)
    elif shape == LID_SHAPE_IRIS_CLOSE:
        # Drawn shut from the working cyan, so the look is the same every
        # time it is previewed; on the desk it closes on whatever was lit.
        lines = [f"{shapes.IRIS_OPEN_START} 200ms cosine", *shapes.iris_close(led_count=count)]
    elif shape == LID_SHAPE_IRIS_OPEN_ACTIVE:
        lines = shapes.iris_open(color, shapes.mix(color, "#FFFFFF", 0.3), led_count=count)
    elif shape == LID_SHAPE_IRIS_CLOSE_ACTIVE:
        lines = [
            f"{color} 200ms cosine",
            *shapes.iris_close(
                led_count=count, to=shapes.shade(color, ACTIVE_CLOSE_EMBER)
            ),
        ]
    else:
        return None
    return "\n".join(lines)


def _iris(shape: str) -> str:
    program = render_lid_shape(shape, led_count=8)
    assert program is not None
    return program


LID_ANIMATION_PRESETS: dict[str, tuple[tuple[str, float, str], ...]] = {
    LID_ANIMATION_CLOSED: (
        ("Fade Out", 1.0, "#8A7CFF 300ms pulse\noff 700ms cosine"),
        ("Blink Out", 0.9, "#FF4F79 150ms pulse\noff 150ms linear\n#FF4F79 150ms pulse\noff 450ms cosine"),
        ("Ember", 1.6, "#FF9F0A 500ms pulse\n#5A3A00 400ms cosine\noff 700ms cosine"),
        ("Cool Down", 1.4, "#00E5FF 350ms pulse\n#0044AA 450ms cosine\noff 600ms cosine"),
        ("Iris", 1.5, _iris(LID_SHAPE_IRIS_CLOSE)),
    ),
    # Every opening ends dark: the live light eases in from rest after it,
    # instead of snapping down from the flourish's last colour.
    LID_ANIMATION_OPEN: (
        ("Rise", 1.3, "off 100ms linear\n#00E5FF 400ms cosine\n#00E5FF 500ms pulse\noff 300ms ease-out"),
        ("Hello", 1.7, "#12E3B0 300ms pulse\n#0FA07C 300ms cosine\n#12E3B0 800ms pulse\noff 300ms ease-out"),
        ("Sunrise", 1.9, "#331A00 300ms cosine\n#FF9F0A 600ms cosine\n#FFD60A 700ms pulse\noff 300ms ease-out"),
        ("Quick Blink", 0.8, "#FFFFFF 150ms pulse\noff 150ms linear\n#FFFFFF 500ms pulse"),
        ("Iris", 1.1, _iris(LID_SHAPE_IRIS_OPEN)),
    ),
    # Agents-running variants: unmistakably different rhythms so the
    # lid itself tells you work is still cooking. The closes settle on an
    # ember rather than black for the same reason.
    LID_ANIMATION_CLOSED_ACTIVE: (
        ("Still Cooking", 1.5, "#FF9F0A 300ms pulse\n#FF9F0A 250ms cosine\n#5A3A00 350ms cosine\n#1A1200 600ms cosine"),
        ("Baton Pass", 1.2, "#00E5FF 250ms pulse\n#8A7CFF 250ms cosine\n#12E3B0 250ms pulse\noff 450ms cosine"),
        ("Ember Watch", 1.8, "#FF6A3D 400ms pulse\n#802000 500ms cosine\n#331000 900ms cosine"),
        # Named for the shape it actually has. Two equal hard-ish thumps
        # and a long rest is a KNOCK; a heartbeat's second thump is dimmer
        # than its first, which is the whole difference between the two in
        # the signal vocabulary. Calling this one "Heartbeat" left the
        # window using one word for two motions.
        ("Knock Out", 1.3, "#FF2D55 150ms pulse\noff 120ms linear\n#FF2D55 150ms pulse\noff 880ms cosine"),
        ("Iris (active)", 1.5, _iris(LID_SHAPE_IRIS_CLOSE_ACTIVE)),
    ),
    LID_ANIMATION_OPEN_ACTIVE: (
        ("Back On It", 1.5, "#12E3B0 200ms pulse\n#00E5FF 300ms cosine\n#00E5FF 700ms pulse\noff 300ms ease-out"),
        ("Status Sweep", 1.7, "#8A7CFF 250ms pulse\n#00E5FF 250ms cosine\n#12E3B0 250ms pulse\n#12E3B0 650ms pulse\noff 300ms ease-out"),
        ("Rekindle", 1.9, "#331000 300ms cosine\n#FF6A3D 500ms cosine\n#FFD60A 800ms pulse\noff 300ms ease-out"),
        ("Double Take", 1.6, "#FFFFFF 170ms pulse\noff 150ms cosine\n#00E5FF 240ms pulse\n#00E5FF 740ms pulse\noff 300ms ease-out"),
        ("Iris (active)", 1.1, _iris(LID_SHAPE_IRIS_OPEN_ACTIVE)),
    ),
}

#: The presets that are drawn per device, by (kind, name).
LID_PRESET_SHAPES: dict[tuple[str, str], str] = {
    (LID_ANIMATION_CLOSED, "Iris"): LID_SHAPE_IRIS_CLOSE,
    (LID_ANIMATION_OPEN, "Iris"): LID_SHAPE_IRIS_OPEN,
    (LID_ANIMATION_CLOSED_ACTIVE, "Iris (active)"): LID_SHAPE_IRIS_CLOSE_ACTIVE,
    (LID_ANIMATION_OPEN_ACTIVE, "Iris (active)"): LID_SHAPE_IRIS_OPEN_ACTIVE,
}

#: Opening looks as they were before 2026-09-24, when they ended on their
#: last colour. A stored copy is read as today's version of the same look,
#: so a person who picked Hello still has Hello picked.
RETIRED_PRESET_PROGRAMS: dict[str, str] = {
    "off 100ms linear\n#00E5FF 400ms cosine\n#00E5FF 500ms pulse": "Rise",
    "#12E3B0 300ms pulse\n#0FA07C 300ms cosine\n#12E3B0 800ms pulse": "Hello",
    "#331A00 300ms cosine\n#FF9F0A 600ms cosine\n#FFD60A 700ms pulse": "Sunrise",
    "#12E3B0 200ms pulse\n#00E5FF 300ms cosine\n#00E5FF 700ms pulse": "Back On It",
    "#8A7CFF 250ms pulse\n#00E5FF 250ms cosine\n#12E3B0 250ms pulse\n#12E3B0 650ms pulse": "Status Sweep",
    "#331000 300ms cosine\n#FF6A3D 500ms cosine\n#FFD60A 800ms pulse": "Rekindle",
    "#FFFFFF 170ms pulse\noff 150ms cosine\n#00E5FF 240ms pulse\n#00E5FF 740ms pulse": "Double Take",
}


def preset(kind: str, name: str) -> tuple[str, float, str] | None:
    """The preset called ``name`` for this lid transition, or None."""
    return next(
        (entry for entry in LID_ANIMATION_PRESETS.get(kind, ()) if entry[0] == name),
        None,
    )


def current_preset_name(kind: str, program: str, shape: str | None = None) -> str | None:
    """Which preset a stored lid animation is, or None for a custom one."""
    if shape:
        return next(
            (name for (preset_kind, name), known in LID_PRESET_SHAPES.items()
             if preset_kind == kind and known == shape),
            None,
        )
    text = (program or "").strip()
    text = _current_text(kind, text)
    return next(
        (name for name, _seconds, known in LID_ANIMATION_PRESETS.get(kind, ())
         if known.strip() == text and (kind, name) not in LID_PRESET_SHAPES),
        None,
    )


def _current_text(kind: str, text: str) -> str:
    retired = RETIRED_PRESET_PROGRAMS.get(text)
    if retired is None:
        return text
    entry = preset(kind, retired)
    return entry[2].strip() if entry is not None else text


def upgraded_program(program: str, duration_seconds: float) -> tuple[str, float]:
    """A stored copy of a retired opening look, brought up to today's
    version (program and length); anything else comes back as it was.

    Retired looks are named uniquely across the four transitions, so the
    name alone finds today's version."""
    name = RETIRED_PRESET_PROGRAMS.get((program or "").strip())
    if name is None:
        return program, duration_seconds
    for kind in LID_ANIMATION_PRESETS:
        entry = preset(kind, name)
        if entry is not None:
            return entry[2], entry[1]
    return program, duration_seconds


def lid_program(program: str, shape: str | None, *, led_count: int, accent: str | None = None) -> str:
    """What a lid animation plays on one device: its shape drawn for that
    device when it has one this build knows, else its stored program."""
    if shape:
        rendered = render_lid_shape(shape, led_count=led_count, accent=accent)
        if rendered is not None:
            return rendered
    return program


#: The four lid transitions in the order the app lists them, with what
#: each is called and the setting that holds its look.
LID_KINDS: tuple[tuple[str, str, str], ...] = (
    (LID_ANIMATION_OPEN, "Lid opens", "lid_open_animation"),
    (LID_ANIMATION_CLOSED, "Lid closes", "lid_closed_animation"),
    (LID_ANIMATION_OPEN_ACTIVE, "Lid opens while agents run", "lid_open_active_animation"),
    (LID_ANIMATION_CLOSED_ACTIVE, "Lid closes while agents run", "lid_closed_active_animation"),
)


def lid_presets_document(settings, *, accent: str | None = None) -> dict:
    """``list_lid_presets``: every lid look, drawn for the Pro and the Dot,
    and which one each transition plays now (None for a custom program).

    ``setting`` is the value a client writes back through ``set_setting``
    to pick a look. ``shipped`` says the transition still plays the look it
    came with (the open and close defaults are not in the preset list).
    """
    from .settings import AgentMonitorSettings

    shipped_settings = AgentMonitorSettings()
    kinds = []
    for kind, label, path in LID_KINDS:
        current = settings.lid_animation(kind)
        shipped = shipped_settings.lid_animation(kind)
        presets = []
        for name, seconds, program in LID_ANIMATION_PRESETS[kind]:
            shape = LID_PRESET_SHAPES.get((kind, name))
            presets.append(
                {
                    "name": name,
                    "duration_seconds": seconds,
                    "shape": shape,
                    "program": lid_program(program, shape, led_count=8, accent=accent),
                    "dot_program": lid_program(program, shape, led_count=2, accent=accent),
                    "setting": {"program": program, "duration_seconds": seconds, "shape": shape},
                }
            )
        kinds.append(
            {
                "kind": kind,
                "label": label,
                "path": path,
                "current": current_preset_name(kind, current.program, current.shape),
                "shipped": current.program.strip() == shipped.program.strip()
                and current.shape == shipped.shape,
                "shipped_program": shipped.program,
                "presets": presets,
            }
        )
    return {"kinds": kinds}


__all__ = [
    "LID_KINDS",
    "lid_presets_document",
    "ACTIVE_CLOSE_EMBER",
    "DEFAULT_LID_ACCENT",
    "LID_ANIMATION_PRESETS",
    "LID_PRESET_SHAPES",
    "LID_SHAPES",
    "LID_SHAPE_IRIS_CLOSE",
    "LID_SHAPE_IRIS_CLOSE_ACTIVE",
    "LID_SHAPE_IRIS_OPEN",
    "LID_SHAPE_IRIS_OPEN_ACTIVE",
    "RETIRED_PRESET_PROGRAMS",
    "current_preset_name",
    "lid_program",
    "preset",
    "render_lid_shape",
    "upgraded_program",
]
