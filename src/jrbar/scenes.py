"""Pure scene policies for the JR-Bar ambient display.

Scenes are intentionally data only.  Runtime and AppKit layers can consume a
validated :class:`ScenePolicy` without this module knowing about devices,
windows, preferences, or notification APIs.
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum

from .dnd_policy import DisplayAdmission


class Scene(str, Enum):
    FOCUS = "focus"
    CALM = "calm"
    NIGHT = "night"
    DEMO = "demo"
    TRAVEL = "travel"
    DND = "dnd"


DEFAULT_SCENE = Scene.CALM


class SurfaceRole(str, Enum):
    AMBIENT = "ambient"
    STATUS = "status"
    PREVIEW = "preview"


class MotionLevel(str, Enum):
    FULL = "full"
    REDUCED = "reduced"
    STATIC = "static"


class NotificationMode(str, Enum):
    ALL = "all"
    IMPORTANT = "important"
    NONE = "none"


class DeviceSelection(str, Enum):
    ACTIVE = "active"
    ALL = "all"
    NONE = "none"


@dataclass(frozen=True, slots=True)
class ScenePolicy:
    """Complete, serializable presentation policy for one scene."""

    scene: Scene
    surface_role: SurfaceRole
    brightness: float
    motion: MotionLevel
    notifications: NotificationMode
    display_admission: DisplayAdmission
    device_selection: DeviceSelection
    reduce_motion: bool = False

    @property
    def effective_motion(self) -> MotionLevel:
        if self.reduce_motion or self.motion is MotionLevel.STATIC:
            return MotionLevel.STATIC
        if self.motion is MotionLevel.FULL:
            return MotionLevel.REDUCED if self.reduce_motion else MotionLevel.FULL
        return MotionLevel.STATIC if self.reduce_motion else MotionLevel.REDUCED


SCENE_POLICIES: dict[Scene, ScenePolicy] = {
    Scene.FOCUS: ScenePolicy(
        Scene.FOCUS,
        SurfaceRole.STATUS,
        0.72,
        MotionLevel.REDUCED,
        NotificationMode.IMPORTANT,
        DisplayAdmission.ASKS,
        DeviceSelection.ACTIVE,
    ),
    Scene.CALM: ScenePolicy(
        Scene.CALM,
        SurfaceRole.AMBIENT,
        0.42,
        MotionLevel.REDUCED,
        NotificationMode.IMPORTANT,
        DisplayAdmission.ASKS,
        DeviceSelection.ACTIVE,
    ),
    Scene.NIGHT: ScenePolicy(
        Scene.NIGHT,
        SurfaceRole.AMBIENT,
        0.18,
        MotionLevel.STATIC,
        NotificationMode.NONE,
        DisplayAdmission.NONE,
        DeviceSelection.ACTIVE,
    ),
    Scene.DEMO: ScenePolicy(
        Scene.DEMO,
        SurfaceRole.PREVIEW,
        0.8,
        MotionLevel.FULL,
        NotificationMode.ALL,
        DisplayAdmission.ALL,
        DeviceSelection.ALL,
    ),
    Scene.TRAVEL: ScenePolicy(
        Scene.TRAVEL,
        SurfaceRole.STATUS,
        0.62,
        MotionLevel.REDUCED,
        NotificationMode.IMPORTANT,
        DisplayAdmission.CRITICAL,
        DeviceSelection.ACTIVE,
    ),
    Scene.DND: ScenePolicy(
        Scene.DND,
        SurfaceRole.AMBIENT,
        0.28,
        MotionLevel.STATIC,
        NotificationMode.NONE,
        DisplayAdmission.NONE,
        DeviceSelection.NONE,
    ),
}


def scene_from_value(value: object) -> Scene | None:
    """Parse a persisted scene value, returning ``None`` for invalid input."""
    if isinstance(value, Scene):
        return value
    if type(value) is not str:
        return None
    try:
        return Scene(value)
    except ValueError:
        return None


# The ScenePolicy fields an installed Scene pack may restate for a scene.
# ``scene`` itself is deliberately absent: a pack retunes what a scene
# means, it can never rename or reseat the scene the user picked.
# ``reduce_motion`` is likewise absent -- it is a runtime accessibility
# input, not pack data.
_PACK_OVERRIDABLE_FIELDS = (
    "surface_role",
    "brightness",
    "motion",
    "notifications",
    "display_admission",
    "device_selection",
)


def _pack_override_fields(row: object) -> dict[str, object] | None:
    """One override row's fields, or None when the row is unusable.

    ``ScenePackStore.policy_overrides`` hands back already-validated
    ``ScenePolicy`` rows, so the common path is a plain attribute copy.
    A mapping row -- a caller that built the table by hand -- is accepted
    only when every field it names is a known overridable field carrying
    the exact type the field declares; anything else fails closed to the
    base policy rather than smuggling a half-coherent override.
    """
    if type(row) is ScenePolicy:
        return {field: getattr(row, field) for field in _PACK_OVERRIDABLE_FIELDS}
    if not isinstance(row, Mapping):
        return None
    allowed: dict[str, tuple[type, ...]] = {
        "surface_role": (SurfaceRole,),
        "brightness": (int, float),
        "motion": (MotionLevel,),
        "notifications": (NotificationMode,),
        "display_admission": (DisplayAdmission,),
        "device_selection": (DeviceSelection,),
    }
    fields: dict[str, object] = {}
    for field in _PACK_OVERRIDABLE_FIELDS:
        value = row.get(field)
        if value is None:
            continue
        expected = allowed[field]
        if type(value) not in expected:
            return None
        if field == "brightness":
            value = float(value)
            if not math.isfinite(value) or not 0.0 <= value <= 1.0:
                return None
        fields[field] = value
    return fields


def policy_for_scene(
    scene: object,
    *,
    reduce_motion: bool = False,
    overrides: object = None,
) -> ScenePolicy | None:
    """Return an immutable policy, failing closed for malformed input.

    ``overrides`` is the validated ``Scene -> ScenePolicy`` table of the
    active Scene pack (``ScenePackStore.policy_overrides``). A row merges
    over the base policy for that scene only; a scene the pack does not
    name -- and any row that does not decode cleanly -- keeps the built-in
    policy untouched.
    """
    selected = scene_from_value(scene)
    if selected is None or type(reduce_motion) is not bool:
        return None
    policy = SCENE_POLICIES.get(selected)
    if policy is None:
        return None
    values = {
        field: getattr(policy, field) for field in policy.__dataclass_fields__
    }
    if isinstance(overrides, Mapping):
        row = overrides.get(selected)
        if row is None:
            row = overrides.get(selected.value)
        fields = _pack_override_fields(row)
        if fields is not None:
            values.update(fields)
    values["scene"] = selected
    values["reduce_motion"] = reduce_motion
    return ScenePolicy(**values)


def effective_policy_for_scene(
    scene: object,
    *,
    accessibility_preferences: object | None = None,
    overrides: object = None,
) -> ScenePolicy | None:
    """Resolve a scene against an already-read accessibility snapshot.

    This adapter deliberately performs no system preference lookup. Runtime
    owners can pass their existing accessibility snapshot when one is
    available; callers without one retain the scene's normal motion policy.
    ``overrides`` is forwarded to :func:`policy_for_scene` unchanged.
    """
    reduce_motion = False
    if accessibility_preferences is not None:
        reduce_motion = getattr(accessibility_preferences, "reduce_motion", None)
        if type(reduce_motion) is not bool:
            return None
    return policy_for_scene(
        scene,
        reduce_motion=reduce_motion,
        overrides=overrides,
    )


def scene_options() -> tuple[Scene, ...]:
    """Return scenes in stable menu order."""
    return tuple(Scene)


__all__ = [
    "DEFAULT_SCENE",
    "SCENE_POLICIES",
    "DeviceSelection",
    "MotionLevel",
    "NotificationMode",
    "Scene",
    "ScenePolicy",
    "SurfaceRole",
    "effective_policy_for_scene",
    "policy_for_scene",
    "scene_from_value",
    "scene_options",
]
