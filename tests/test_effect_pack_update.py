"""``import_effect_pack`` with ``update: true`` replaces an installed pack.

The Studio offers "Update pack" after a conflict, and "Save as Effect…"
grows the Yours pack the same way. The flag used to be dropped, so the
explicit retry met the same conflict it was offered to resolve.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar.core_server import CommandError
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)


def test_update_replaces_an_installed_pack(headless, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:  # noqa: F811
    from jrbar import core_effects, effect_assignment_store, effect_pack_store
    from jrbar.effect_assignment_store import EffectAssignmentCache
    from jrbar.effect_registry import EFFECT_REGISTRY

    monkeypatch.setattr(effect_assignment_store, "default_effect_assignment_path", lambda home=None: tmp_path / "assignments.json")
    monkeypatch.setattr(effect_pack_store, "default_effect_pack_store_path", lambda home=None: tmp_path / "packs")
    monkeypatch.setattr(core_effects, "default_state_dir", lambda *_: tmp_path)
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    monkeypatch.setattr(type(controller), "_effect_assignment_cache", EffectAssignmentCache(registry=EFFECT_REGISTRY), raising=False)

    first = controller._core_dispatch("export_effect_pack", {"ids": ["aurora"], "path": str(tmp_path / "yours.json"), "name": "Yours"})
    installed = controller._core_dispatch("import_effect_pack", {"path": first["path"]})
    assert installed["imported"]["effects"] == 1

    # Updating a pack that is not installed is refused, not installed.
    other = controller._core_dispatch("export_effect_pack", {"ids": ["pulse"], "path": str(tmp_path / "other.json"), "name": "Other"})
    with pytest.raises(CommandError) as missing:
        controller._core_dispatch("import_effect_pack", {"path": other["path"], "update": True})
    assert missing.value.code == "refused" and "not_installed" in str(missing.value)

    # A second effect in the same pack id: a plain import conflicts,
    # the explicit update replaces.
    grown = json.loads(Path(first["path"]).read_text())
    row = dict(grown["effects"][0], id="aurora-slow", label="Slow aurora")
    grown["effects"].append(row)
    Path(first["path"]).write_text(json.dumps(grown))
    with pytest.raises(CommandError) as conflict:
        controller._core_dispatch("import_effect_pack", {"path": first["path"]})
    assert conflict.value.code == "conflict"
    updated = controller._core_dispatch("import_effect_pack", {"path": first["path"], "update": True})
    assert updated["imported"] == {"id": "yours", "name": "Yours", "effects": 2}
    assert {"pack:yours:aurora", "pack:yours:aurora-slow"} <= {effect["id"] for effect in updated["effects"]}

    # Only a real true updates: a truthy string is still a plain import.
    with pytest.raises(CommandError) as stringly:
        controller._core_dispatch("import_effect_pack", {"path": first["path"], "update": "yes"})
    assert stringly.value.code == "conflict"
