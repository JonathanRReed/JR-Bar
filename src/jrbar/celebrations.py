"""Finite celebration programs: the refill, once, then dark.

The original reset celebration was generic confetti -- eight polychrome
sparks that could have meant anything. The event is "the meter refilled",
so the shape now TELLS that story (2026-08-26, Live Activities grammar:
glanceable meaning): the provider's own color rises LED-by-LED like a
gauge refilling, the strip crests white once, two sparkles wink, then
dark. Three cycles, then the display claim hands back. Indexes past a
2-LED build are parsed and ignored, so the Dot gets a two-LED refill of
the same story for free.
"""

from __future__ import annotations

from .led_status import apply_brightness

#: The neutral refill color when no provider is known (a manual test,
#: a celebration fired before identity resolved).
REFILL_FALLBACK_COLOR = "#FFD700"

def _refill_cycle(color: str) -> str:
    rise = "; ".join(
        f"{index}:{color} 240ms cosine {index * 90}ms" for index in range(8)
    )
    sparkles = f"2:{color} 220ms pulse 60ms; 5:{color} 220ms pulse 200ms"
    return "\n".join(
        [
            "off 120ms cosine",
            rise,
            "#FFFFFF 260ms pulse",
            sparkles,
            "off 400ms ease-out",
        ]
    )


def reset_celebration_program(
    brightness: float,
    led_count: int = 8,
    *,
    color: str | None = None,
) -> str:
    del led_count  # same program bytes on every build; extras no-op
    cycle = _refill_cycle(color or REFILL_FALLBACK_COLOR)
    return apply_brightness(f"{cycle}\nrepeat 3\noff 250ms", brightness)


def _total_runtime_seconds() -> float:
    """The finite program's full runtime: looped section times its count
    plus the coda after the repeat marker. Measured from the parsed
    program so the claim can never drift from the choreography again
    (2026-08-27 audit: a 2070ms cycle against a hand-kept 6.0s claim
    clipped the third cycle's fade)."""
    from .animation import RepeatStep, parse_animation, step_duration_ms

    animation = parse_animation(reset_celebration_program(1.0), led_count=8)
    repeat_at = next(
        (i for i, step in enumerate(animation.steps) if type(step) is RepeatStep),
        None,
    )
    durations = [step_duration_ms(step) for step in animation.steps]
    if repeat_at is None:
        return sum(durations) / 1000.0
    count = animation.steps[repeat_at].count or 1
    loop = sum(durations[:repeat_at])
    coda = sum(durations[repeat_at + 1 :])
    return (loop * count + coda) / 1000.0


#: Three cycles then dark; the display claim window must outlast the
#: program, so it is measured from it (plus a settle cushion).
try:
    RESET_CELEBRATION_SECONDS = _total_runtime_seconds() + 0.25
except Exception:  # pragma: no cover -- parse of our own constant program
    RESET_CELEBRATION_SECONDS = 6.75


# --- The done celebration's other looks -----------------------------------

#: How a finish is celebrated. Bloom is the shipped twinkle-then-bloom
#: (``led_status._done_celebration_program``); Land drops a light to the far
#: end with a splash -- "it arrived"; Ripple sends one ring out from the
#: middle.
DONE_CELEBRATION_BLOOM = "bloom"
DONE_CELEBRATION_LAND = "land"
DONE_CELEBRATION_RIPPLE = "ripple"
DONE_CELEBRATION_STYLES: tuple[str, ...] = (
    DONE_CELEBRATION_BLOOM,
    DONE_CELEBRATION_LAND,
    DONE_CELEBRATION_RIPPLE,
)
DEFAULT_DONE_CELEBRATION_STYLE = DONE_CELEBRATION_BLOOM
#: The one cycle each look is drawn at, and how it lets go afterwards: a
#: short glow in the done colour, then a fade to dark -- a finish is a
#: finite cue, never a held light.
DONE_CELEBRATION_CYCLE_MS = 2400
DONE_CELEBRATION_GLOW_MS = 500
DONE_CELEBRATION_FADE_MS = 900


def normalize_done_celebration_style(value: object) -> str:
    return value if value in DONE_CELEBRATION_STYLES else DEFAULT_DONE_CELEBRATION_STYLE


def done_celebration_program(style: str, color: str, *, led_count: int = 8) -> str | None:
    """A finish, played once in ``color``, ending dark: the Land or Ripple
    look, or None for Bloom (the shipped program draws that one)."""
    from . import motion_shapes as shapes

    count = max(2, int(led_count))
    if style == DONE_CELEBRATION_LAND:
        lines = shapes.land(color, "#000000", led_count=count, cycle_ms=DONE_CELEBRATION_CYCLE_MS)
    elif style == DONE_CELEBRATION_RIPPLE:
        lines = shapes.ripple(color, "#000000", led_count=count, cycle_ms=DONE_CELEBRATION_CYCLE_MS)
    else:
        return None
    # The shape's own resting line is for a loop; a finish glows once
    # where it ended and lets go.
    body = [f"off {DONE_CELEBRATION_SETTLE_MS}ms cosine", *lines[1:-1]]
    body.append(f"{shapes.shade(color, 0.35)} {DONE_CELEBRATION_GLOW_MS}ms cosine")
    body.append(f"off {DONE_CELEBRATION_FADE_MS}ms cosine")
    return "\n".join(body)


#: The ease to dark a finish starts from, as the shipped celebration does.
DONE_CELEBRATION_SETTLE_MS = 90


__all__ = [
    "DEFAULT_DONE_CELEBRATION_STYLE",
    "DONE_CELEBRATION_BLOOM",
    "DONE_CELEBRATION_LAND",
    "DONE_CELEBRATION_RIPPLE",
    "DONE_CELEBRATION_STYLES",
    "REFILL_FALLBACK_COLOR",
    "RESET_CELEBRATION_SECONDS",
    "done_celebration_program",
    "normalize_done_celebration_style",
    "reset_celebration_program",
]
