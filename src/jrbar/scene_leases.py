"""Short-lived automatic scenes leave the person's saved scene alone."""
from __future__ import annotations

import time
import uuid
from collections import deque
from collections.abc import Callable
from typing import Any

from .core_server import CommandError
from .scenes import DEFAULT_SCENE, scene_from_value

LEASE_SECONDS = 30.0
SCENE_SETTINGS = frozenset({"active_scene", "active_scene_pack"})


class SceneLeases:
    def __init__(self, *, clock: Callable[[], float] = time.monotonic,
                 epoch: Callable[[], float] = time.time) -> None:
        self.clock = clock
        self.epoch = epoch
        self.instance = uuid.uuid4().hex
        self.counter = 0
        self.lease_id: str | None = None
        self.scene: str | None = None
        self.deadline: float | None = None
        self.until_epoch: float | None = None
        self.acquisition_revision: str | None = None
        self.retired: deque[str] = deque(maxlen=256)

    @property
    def revision(self) -> str:
        return f"{self.instance}:{self.counter}"

    def retire(self, lease_id: str) -> None:
        if lease_id in self.retired:
            return
        if len(self.retired) == self.retired.maxlen:
            # An evicted ID's old compare token must never become valid again.
            self.counter += 1
        self.retired.append(lease_id)

    def clear(self, *, retire: bool) -> None:
        if retire and self.lease_id is not None:
            self.retire(self.lease_id)
        self.lease_id = None
        self.scene = None
        self.deadline = None
        self.until_epoch = None
        self.acquisition_revision = None

    def invalidate(self) -> None:
        self.clear(retire=True)
        self.counter += 1

    def expire(self) -> bool:
        if self.deadline is None or self.clock() < self.deadline:
            return False
        self.clear(retire=False)
        return True

    def effective(self, selected: str) -> str:
        if self.deadline is not None and self.clock() < self.deadline:
            return self.scene or selected
        return selected

    def document(self, selected: str) -> dict[str, Any]:
        live = self.deadline is not None and self.clock() < self.deadline
        return {"revision": self.revision, "selected_scene": selected,
                "effective_scene": self.effective(selected),
                "lease_id": self.lease_id if live else None,
                "until": self.until_epoch if live else None}

    def apply(self, args: dict[str, Any], selected: str) -> dict[str, Any]:
        self.expire()
        lease_id = args.get("lease_id")
        action = args.get("action")
        if not isinstance(lease_id, str) or not lease_id or len(lease_id) > 128 or not lease_id.isascii():
            raise CommandError("invalid_args", "lease_id must be 1 to 128 ASCII characters")
        if action not in ("acquire", "release"):
            raise CommandError("invalid_args", "action must be acquire or release")
        if action == "acquire":
            revision = args.get("expected_revision")
            scene = scene_from_value(args.get("scene"))
            if not isinstance(revision, str) or not revision or len(revision) > 128 or scene is None:
                raise CommandError("invalid_args", "acquire requires expected_revision and a valid scene")
            replay = self.lease_id == lease_id and revision == self.acquisition_revision
            if (revision != self.revision and not replay) or lease_id in self.retired:
                raise CommandError("conflict", "the scene choice changed")
            if self.lease_id == lease_id:
                if scene.value != self.scene:
                    raise CommandError("conflict", "a scene lease cannot change its scene")
            elif self.lease_id is not None:
                raise CommandError("conflict", "another scene lease is active")
            else:
                self.acquisition_revision = self.revision
                self.lease_id = lease_id
                self.scene = scene.value
            self.deadline = self.clock() + LEASE_SECONDS
            self.until_epoch = self.epoch() + LEASE_SECONDS
        elif self.lease_id == lease_id:
            self.clear(retire=True)
        elif lease_id not in self.retired:
            # A release can precede a delayed acquisition. Retire that ID
            # without changing another owner's overlay.
            self.retire(lease_id)
        state = self.document(selected)
        return {"status": "acquired" if action == "acquire" else "released",
                "revision": state["revision"], "scene": state["effective_scene"], "until": state["until"]}


def leases(controller: object) -> SceneLeases:
    current = getattr(controller, "_core_scene_leases", None)
    if current is None:
        current = SceneLeases()
        setattr(controller, "_core_scene_leases", current)
    return current


def selected_scene(controller: object) -> str:
    scene = scene_from_value(getattr(getattr(controller, "settings", None), "active_scene", None))
    return (scene or DEFAULT_SCENE).value


def effective_scene(controller: object) -> str:
    return leases(controller).effective(selected_scene(controller))


def scene_state(controller: object) -> dict[str, Any]:
    return leases(controller).document(selected_scene(controller))


def settings_changed(controller: object, previous: object, candidate: object, *, touched: list[str] = ()) -> None:
    changed = any(getattr(previous, key, None) != getattr(candidate, key, None) for key in SCENE_SETTINGS)
    if changed or any(path.split(".")[0] in SCENE_SETTINGS for path in touched):
        leases(controller).invalidate()
