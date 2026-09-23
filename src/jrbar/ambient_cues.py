"""The semantic ambient cues by name, with a meaning and a switch each.

The daemon plans eleven finite, content-free cues over the base light --
a firefly when an agent finishes, a baton when one agent hands to another,
an ember as a turn runs long -- and until now nobody could say what a
"baton" or an "ember" was, or turn one off. Hue Sync and Nanoleaf list
every event effect they play and let each be switched off; this is that
list for JR-Bar.

Two cues (Rainstick and the Milestone Odometer) were already opt-in and
keep their own settings flags; the rest default on and are switched off
through ``ambient_cues_disabled``. The Dot's binary heartbeat and the
assigned semantic effects are displays, not cues, and are not listed.

Pure: no controller, no clock.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Final

from .ambient_effect_dispatch import AMBIENT_EFFECT_PRIORITY, AmbientEffectFamily


@dataclass(frozen=True, slots=True)
class AmbientCue:
    id: str
    name: str
    meaning: str
    #: The settings flag that owns this cue's switch, when it is one of the
    #: older opt-in cues; None means ``ambient_cues_disabled`` owns it.
    setting: str | None = None
    default_enabled: bool = True


AMBIENT_CUES: Final[tuple[AmbientCue, ...]] = (
    AmbientCue(
        AmbientEffectFamily.FIREFLY_COMPLETION.value,
        "Firefly",
        "When an agent finishes, its own stretch of light flickers once where it was working.",
    ),
    AmbientCue(
        AmbientEffectFamily.COMPLETION_MENISCUS.value,
        "Meniscus",
        "A finished run you have not looked at yet ripples out once from the middle of the Screen Bar.",
    ),
    AmbientCue(
        AmbientEffectFamily.HANDOFF_BATON.value,
        "Handoff baton",
        "When one agent finishes and another starts on the same task, a light travels from the first to the second.",
    ),
    AmbientCue(
        AmbientEffectFamily.RECOVERY_GRACE.value,
        "Recovery grace note",
        "An agent source that went quiet and came back plays one soft note.",
    ),
    AmbientCue(
        AmbientEffectFamily.ASK_HEARTBEAT.value,
        "Ask heartbeat",
        "Asks that arrive together pulse in step instead of out of phase.",
    ),
    AmbientCue(
        AmbientEffectFamily.TURN_LENGTH_EMBER.value,
        "Turn-length ember",
        "A turn that runs long warms slowly through four broad bands of age. It is age, not progress.",
    ),
    AmbientCue(
        AmbientEffectFamily.FLEET_ARRIVAL_DEPARTURE.value,
        "Fleet arrival",
        "A remote Mac joining or leaving your fleet shows one quiet cue at the edge.",
    ),
    AmbientCue(
        AmbientEffectFamily.COURTESY_SIGNATURE.value,
        "Courtesy signatures",
        "Completions, notifications and other courtesies each get their own short shape, not just a colour.",
    ),
    AmbientCue(
        AmbientEffectFamily.GLANCE_LIGHT.value,
        "Glance light",
        "A notification you have not seen leaves a small steady glow until you look.",
    ),
    AmbientCue(
        AmbientEffectFamily.RAINSTICK_IDLE.value,
        "Rainstick",
        "While nothing else owns the strip, one dim pixel drips along it: JR-Bar is alive and watching.",
        setting="rainstick_idle_enabled",
        default_enabled=False,
    ),
    AmbientCue(
        AmbientEffectFamily.MILESTONE_ODOMETER.value,
        "Milestone odometer",
        "A short cue when the number of finished runs crosses one of your steps.",
        setting="milestone_odometer_enabled",
        default_enabled=False,
    ),
)
AMBIENT_CUE_IDS: Final = frozenset(cue.id for cue in AMBIENT_CUES)
#: The cues ``ambient_cues_disabled`` can switch off (the rest own a flag).
SWITCHABLE_CUE_IDS: Final = frozenset(cue.id for cue in AMBIENT_CUES if cue.setting is None)


def cue_for_id(cue_id: object) -> AmbientCue | None:
    return next((cue for cue in AMBIENT_CUES if cue.id == cue_id), None)


def normalize_disabled_cues(value: object) -> tuple[str, ...]:
    """Stored or wire value -> the sorted, known, switchable ids."""
    if value is None or isinstance(value, (str, bytes)) or not isinstance(value, Iterable):
        return ()
    return tuple(sorted({str(item) for item in value if str(item) in SWITCHABLE_CUE_IDS}))


def disabled_cue_families(settings: object) -> frozenset[AmbientEffectFamily]:
    """The families the dispatch must not play, from ``settings``."""
    return frozenset(
        AmbientEffectFamily(cue_id)
        for cue_id in normalize_disabled_cues(getattr(settings, "ambient_cues_disabled", ()))
    )


def cue_enabled(cue: AmbientCue, settings: object) -> bool:
    if cue.setting is not None:
        return bool(getattr(settings, cue.setting, cue.default_enabled))
    return cue.id not in normalize_disabled_cues(getattr(settings, "ambient_cues_disabled", ()))


def cue_documents(settings: object) -> list[dict[str, object]]:
    """``list_cues`` rows, in the order the dispatch ranks them."""
    rows = [
        {
            "id": cue.id,
            "name": cue.name,
            "meaning": cue.meaning,
            "enabled": cue_enabled(cue, settings),
            "default_enabled": cue.default_enabled,
            "setting": cue.setting or "ambient_cues_disabled",
            "priority": int(AMBIENT_EFFECT_PRIORITY[AmbientEffectFamily(cue.id)]),
        }
        for cue in AMBIENT_CUES
    ]
    rows.sort(key=lambda row: -int(row["priority"]))  # type: ignore[arg-type]
    return rows


__all__ = [
    "AMBIENT_CUES",
    "AMBIENT_CUE_IDS",
    "SWITCHABLE_CUE_IDS",
    "AmbientCue",
    "cue_documents",
    "cue_enabled",
    "cue_for_id",
    "disabled_cue_families",
    "normalize_disabled_cues",
]
