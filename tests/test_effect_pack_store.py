from __future__ import annotations

import json
import os
import stat
from pathlib import Path

import pytest

from jrbar.effect_history import (
    EffectEvent,
    EffectHistory,
    EffectOutcome,
    EffectSemanticCategory,
    EffectSurface,
)
from jrbar.effect_history_store import save_effect_history
from jrbar.effect_pack_store import (
    EFFECT_PACK_STORE_DIRECTORY,
    EffectPackStore,
    EffectPackStoreError,
    PackMutationStatus,
    default_effect_pack_store_path,
)
from jrbar.effect_packs import export_pack


def _pack(**overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "id": "calm-pack",
        "name": "Calm Pack",
        "version": 2,
        "effects": [
            {
                "id": "soft-pulse",
                "label": "Soft Pulse",
                "description": "A quiet work pulse.",
                "meaning": "quiet working",
                "surfaces": ["screen_bar", "settings_preview"],
            }
        ],
        "safety": {"data_only": True, "network": False},
        "accessibility": {"reduced_motion": True, "high_contrast": True},
    }
    payload.update(overrides)
    return payload


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.lstat().st_mode)


def test_default_store_uses_the_private_jr_bar_state_directory(
    tmp_path: Path,
) -> None:
    assert default_effect_pack_store_path(tmp_path) == (
        tmp_path
        / ".local"
        / "state"
        / "jrbar"
        / EFFECT_PACK_STORE_DIRECTORY
    )


def test_install_persists_canonical_private_json_and_round_trips(
    tmp_path: Path,
) -> None:
    source = tmp_path / "incoming.json"
    source.write_text(json.dumps(_pack(), indent=2), encoding="utf-8")
    store = EffectPackStore(tmp_path / "store")

    receipt = store.install(source)
    rows = store.list()
    installed = store.inspect("calm-pack")

    assert receipt.status is PackMutationStatus.INSTALLED
    assert receipt.accepted is True
    assert tuple(row.pack_id for row in rows) == ("calm-pack",)
    assert installed.pack_id == "calm-pack"
    target = tmp_path / "store" / "calm-pack.json"
    assert target.read_bytes() == store.canonical_export("calm-pack")
    assert b"\n" not in target.read_bytes()
    assert _mode(target.parent) == 0o700
    assert _mode(target) == 0o600


def test_install_collision_and_explicit_update_have_refusal_receipts(
    tmp_path: Path,
) -> None:
    store = EffectPackStore(tmp_path / "store")
    installed = store.install(_pack())
    collision = store.install(_pack(name="Changed"))
    missing_update = store.update(_pack(id="other-pack"))
    updated = store.update(_pack(name="Changed"))
    unchanged = store.update(_pack(name="Changed"))

    assert installed.status is PackMutationStatus.INSTALLED
    assert collision.status is PackMutationStatus.REFUSED
    assert collision.reason == "already_installed"
    assert missing_update.status is PackMutationStatus.REFUSED
    assert missing_update.reason == "not_installed"
    assert updated.status is PackMutationStatus.UPDATED
    assert store.inspect("calm-pack").name == "Changed"
    assert unchanged.status is PackMutationStatus.REFUSED
    assert unchanged.reason == "already_current"


def test_remove_is_explicit_and_idempotently_refuses_missing_pack(
    tmp_path: Path,
) -> None:
    store = EffectPackStore(tmp_path / "store")
    store.install(_pack())

    removed = store.remove("calm-pack")
    missing = store.remove("calm-pack")

    assert removed.status is PackMutationStatus.REMOVED
    assert removed.accepted is True
    assert missing.status is PackMutationStatus.REFUSED
    assert missing.reason == "not_installed"
    assert store.list() == ()


def test_duplicate_preserves_pack_metadata_under_a_new_identity(
    tmp_path: Path,
) -> None:
    store = EffectPackStore(tmp_path / "store")
    store.install(
        _pack(
            license={
                "spdx_id": "CC-BY-4.0",
                "label": "Creative Commons Attribution 4.0",
                "source_url": "https://example.com/source",
            }
        )
    )

    receipt = store.duplicate("calm-pack", "calm-pack-copy", "Calm Pack Copy")
    original = store.inspect("calm-pack")
    duplicate = store.inspect("calm-pack-copy")

    assert receipt.status is PackMutationStatus.DUPLICATED
    assert duplicate.pack_id == "calm-pack-copy"
    assert duplicate.name == "Calm Pack Copy"
    assert duplicate.effects == original.effects
    assert duplicate.safety == original.safety
    assert duplicate.accessibility == original.accessibility
    assert duplicate.license == original.license
    assert _mode(tmp_path / "store" / "calm-pack-copy.json") == 0o600


def test_duplicate_refuses_collisions_without_mutating_either_pack(
    tmp_path: Path,
) -> None:
    store = EffectPackStore(tmp_path / "store")
    store.install(_pack())
    store.install(_pack(id="other-pack", name="Other Pack"))
    before = store.canonical_export("other-pack")

    receipt = store.duplicate("calm-pack", "other-pack", "Replacement")

    assert receipt.status is PackMutationStatus.REFUSED
    assert receipt.reason == "already_installed"
    assert store.canonical_export("other-pack") == before
    assert tuple(pack.pack_id for pack in store.list()) == (
        "calm-pack",
        "other-pack",
    )


def test_rename_refuses_collisions_without_mutating_either_pack(
    tmp_path: Path,
) -> None:
    store = EffectPackStore(tmp_path / "store")
    store.install(_pack())
    store.install(_pack(id="other-pack", name="Other Pack"))
    original = store.canonical_export("calm-pack")
    other = store.canonical_export("other-pack")

    receipt = store.rename("calm-pack", "other-pack", "Replacement")

    assert receipt.status is PackMutationStatus.REFUSED
    assert receipt.reason == "already_installed"
    assert store.canonical_export("calm-pack") == original
    assert store.canonical_export("other-pack") == other


def test_rename_replaces_the_identity_and_preserves_metadata(tmp_path: Path) -> None:
    store = EffectPackStore(tmp_path / "store")
    store.install(_pack())
    original = store.inspect("calm-pack")

    receipt = store.rename("calm-pack", "focused-pack", "Focused Pack")
    renamed = store.inspect("focused-pack")

    assert receipt.status is PackMutationStatus.RENAMED
    assert tuple(pack.pack_id for pack in store.list()) == ("focused-pack",)
    assert not (tmp_path / "store" / "calm-pack.json").exists()
    assert renamed.name == "Focused Pack"
    assert renamed.effects == original.effects
    assert renamed.safety == original.safety
    assert renamed.accessibility == original.accessibility
    assert renamed.license == original.license


def test_rename_rolls_back_the_new_pack_when_source_removal_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import jrbar.effect_pack_store as pack_store

    store = EffectPackStore(tmp_path / "store")
    store.install(_pack())
    original = store.canonical_export("calm-pack")

    def fail_remove(*_args: object, **_kwargs: object) -> bool:
        raise OSError("injected removal failure")

    monkeypatch.setattr(pack_store, "unlink_private_file_if_unchanged", fail_remove)

    with pytest.raises(EffectPackStoreError, match="rename failed"):
        store.rename("calm-pack", "focused-pack", "Focused Pack")

    assert store.canonical_export("calm-pack") == original
    assert not (tmp_path / "store" / "focused-pack.json").exists()


@pytest.mark.parametrize(
    ("operation", "new_pack_id", "new_name"),
    (
        ("duplicate", "../outside", "Valid Name"),
        ("duplicate", "valid-id", "   "),
        ("rename", "../outside", "Valid Name"),
        ("rename", "valid-id", "   "),
    ),
)
def test_pack_management_refuses_invalid_new_identity(
    tmp_path: Path,
    operation: str,
    new_pack_id: str,
    new_name: str,
) -> None:
    store = EffectPackStore(tmp_path / "store")
    store.install(_pack())

    with pytest.raises(EffectPackStoreError, match=r"identifier|name"):
        getattr(store, operation)("calm-pack", new_pack_id, new_name)

    assert tuple(pack.pack_id for pack in store.list()) == ("calm-pack",)


@pytest.mark.parametrize("pack_id", ("../outside", "a/b", "/absolute", ".."))
def test_pack_identifiers_cannot_traverse_the_store(
    tmp_path: Path,
    pack_id: str,
) -> None:
    store = EffectPackStore(tmp_path / "store")

    with pytest.raises(EffectPackStoreError, match="identifier"):
        store.inspect(pack_id)
    with pytest.raises(EffectPackStoreError, match="identifier"):
        store.remove(pack_id)


@pytest.mark.parametrize("operation", ("inspect", "list", "update", "remove", "fingerprint"))
def test_store_refuses_symlinked_pack_leaf_without_touching_target(
    tmp_path: Path,
    operation: str,
) -> None:
    outside = tmp_path / "outside.json"
    outside.write_text("outside remains unchanged", encoding="utf-8")
    root = tmp_path / "store"
    root.mkdir()
    (root / "calm-pack.json").symlink_to(outside)
    store = EffectPackStore(root)

    with pytest.raises(EffectPackStoreError):
        if operation == "inspect":
            store.inspect("calm-pack")
        elif operation == "list":
            store.list()
        elif operation == "update":
            store.update(_pack())
        elif operation == "fingerprint":
            # An unsafe store never yields a value a caller could cache.
            store.fingerprint()
        else:
            store.remove("calm-pack")

    assert outside.read_text(encoding="utf-8") == "outside remains unchanged"


def test_legacy_pack_is_migrated_and_license_survives_gallery_projection(
    tmp_path: Path,
) -> None:
    store = EffectPackStore(tmp_path / "store")
    legacy = {
        "id": "legacy-pack",
        "name": "Legacy Pack",
        "version": 1,
        "effects": [{"id": "steady", "label": "Steady"}],
        "license": {
            "spdx_id": "CC-BY-4.0",
            "label": "Creative Commons Attribution 4.0",
            "source_url": "https://example.com/source",
            "attribution_url": "https://example.com/credit",
        },
    }

    store.install(legacy)
    projection = store.gallery_index()[0]
    document = json.loads(store.canonical_export("legacy-pack"))

    assert document["version"] == 2
    assert projection.pack_id == "legacy-pack"
    assert projection.license_spdx_id == "CC-BY-4.0"
    assert projection.source_url == "https://example.com/source"
    assert projection.attribution_url == "https://example.com/credit"


def test_builtin_gallery_uses_existing_studio_projection(tmp_path: Path) -> None:
    rows = EffectPackStore(tmp_path / "store").built_in_gallery(query="pulse")

    assert "pulse" in tuple(row.effect_id for row in rows)
    assert next(row for row in rows if row.effect_id == "pulse").label == "Pulse"


def test_history_projection_is_content_free_and_preserves_restore_health(
    tmp_path: Path,
) -> None:
    history_path = tmp_path / "effect-history.json"
    save_effect_history(
        history_path,
        EffectHistory(
            (
                EffectEvent(
                    event_id="effect-event:one",
                    occurred_at_epoch=1_800_000_000.0,
                    effect_id="pulse",
                    semantic_category=EffectSemanticCategory.AMBIENT,
                    surface=EffectSurface.SCREEN_BAR,
                    outcome=EffectOutcome.SHOWN,
                ),
            )
        ),
    )

    projection = EffectPackStore(tmp_path / "store").effect_history(history_path)

    assert projection.health.value == "healthy"
    assert projection.rows[0].effect_id == "pulse"
    serialized = repr(projection).casefold()
    for forbidden in (
        "prompt",
        "transcript",
        "session",
        "person@example.com",
        "/users/private",
        "https://private.example",
    ):
        assert forbidden not in serialized


def test_store_refuses_more_than_the_bounded_pack_count(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import jrbar.effect_pack_store as pack_store

    monkeypatch.setattr(pack_store, "MAX_STORED_EFFECT_PACKS", 1)
    store = EffectPackStore(tmp_path / "store")
    assert store.install(_pack()).accepted is True

    receipt = store.install(_pack(id="other-pack", name="Other Pack"))

    assert receipt.status is PackMutationStatus.REFUSED
    assert receipt.reason == "pack_count_limit"
    assert store.list()[0].pack_id == "calm-pack"


def test_store_refuses_a_write_that_would_exceed_total_size(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import jrbar.effect_pack_store as pack_store

    first = _pack()
    monkeypatch.setattr(
        pack_store,
        "MAX_EFFECT_PACK_STORE_BYTES",
        len(export_pack(first)),
    )
    store = EffectPackStore(tmp_path / "store")
    assert store.install(first).accepted is True

    receipt = store.install(_pack(id="other-pack", name="Other Pack"))

    assert receipt.status is PackMutationStatus.REFUSED
    assert receipt.reason == "total_size_limit"


@pytest.mark.parametrize(
    "changes",
    (
        {"effects": [{"id": "unsafe", "label": "Unsafe", "script": "run()"}]},
        {"safety": {"data_only": True, "network": True}},
    ),
)
def test_store_never_accepts_executable_or_network_enabled_plugins(
    tmp_path: Path,
    changes: dict[str, object],
) -> None:
    with pytest.raises(EffectPackStoreError, match="source is invalid"):
        EffectPackStore(tmp_path / "store").install(_pack(**changes))


def test_import_refuses_hard_linked_source(tmp_path: Path) -> None:
    original = tmp_path / "original.json"
    source = tmp_path / "source.json"
    original.write_text(json.dumps(_pack()), encoding="utf-8")
    os.link(original, source)

    with pytest.raises(EffectPackStoreError):
        EffectPackStore(tmp_path / "store").install(source)


def test_fingerprint_is_stable_and_moves_with_every_kind_of_change(tmp_path: Path) -> None:
    store = EffectPackStore(tmp_path / "store")
    absent = store.fingerprint()
    assert store.fingerprint() == absent

    assert store.install(_pack()).status is PackMutationStatus.INSTALLED
    installed = store.fingerprint()
    assert installed != absent
    # Reading the store, which re-tightens what it reads, does not move it.
    store.list()
    assert store.fingerprint() == installed
    assert store.fingerprint() == installed

    leaf = tmp_path / "store" / "calm-pack.json"
    updated = _pack(name="Calm Pack, Revised")
    assert store.update(updated).status is PackMutationStatus.UPDATED
    after_update = store.fingerprint()
    assert after_update != installed

    # A new modification time alone moves it (a same-size replace, or a
    # copy that restored the bytes).
    stat_result = leaf.stat()
    os.utime(leaf, ns=(stat_result.st_atime_ns, stat_result.st_mtime_ns + 5_000_000_000))
    after_utime = store.fingerprint()
    assert after_utime != after_update

    # A loosened mode moves it, so the read that tightens it runs again.
    leaf.chmod(0o666)
    loosened = store.fingerprint()
    assert loosened != after_utime
    store.list()
    assert _mode(leaf) == 0o600
    tightened = store.fingerprint()
    assert tightened != loosened
    assert store.fingerprint() == tightened

    assert store.rename("calm-pack", "calm-pack-two", "Calm Pack Two").accepted
    renamed = store.fingerprint()
    assert renamed != tightened
    assert store.install(_pack(id="second-pack", name="Second")).accepted
    assert store.fingerprint() != renamed
    assert store.remove("second-pack").status is PackMutationStatus.REMOVED
    # The same packs again; the directory itself was touched twice since.
    assert store.fingerprint()[1] == renamed[1]

    assert store.remove("calm-pack-two").status is PackMutationStatus.REMOVED
    assert store.fingerprint() not in (absent, renamed)


def test_fingerprint_of_an_absent_root_is_one_stable_value(tmp_path: Path) -> None:
    first = EffectPackStore(tmp_path / "none").fingerprint()
    assert EffectPackStore(tmp_path / "none").fingerprint() == first
    assert EffectPackStore(tmp_path / "other").fingerprint() == first
    assert not (tmp_path / "none").exists()


def test_fingerprint_refuses_an_unsafe_root_like_list_does(tmp_path: Path) -> None:
    target = tmp_path / "elsewhere"
    target.mkdir()
    (tmp_path / "store").symlink_to(target)
    store = EffectPackStore(tmp_path / "store")
    with pytest.raises(EffectPackStoreError):
        store.list()
    with pytest.raises(EffectPackStoreError):
        store.fingerprint()


# --- a file that is not a pack never takes the pack list down ---

_DAY = 24 * 60 * 60.0


def _scratch_name(pack_id: str = "calm-pack", *, tail: str | None = None) -> str:
    """A scratch file an interrupted write leaves behind: the pack's file
    name, then pid, thread id and a random token."""
    return f"{pack_id}.json.4242.140234.{tail or 'a' * 32}.tmp"


def _foreign_store(tmp_path: Path, **kwargs) -> tuple[EffectPackStore, Path, list[str]]:
    lines: list[str] = []
    root = tmp_path / "store"
    store = EffectPackStore(root, log=lines.append, **kwargs)
    assert store.install(_pack()).status is PackMutationStatus.INSTALLED
    return store, root, lines


def test_a_stray_file_in_the_pack_folder_does_not_break_any_pack_operation(
    tmp_path: Path,
) -> None:
    store, root, lines = _foreign_store(tmp_path)
    (root / ".DS_Store").write_bytes(b"\x00\x00\x00\x01Bud1")
    (root / "notes.txt").write_text("not a pack")
    (root / "Bad Name.json").write_text("{}")
    (root / "a-folder").mkdir()

    assert [pack.pack_id for pack in store.list()] == ["calm-pack"]
    assert store.inspect("calm-pack").pack_id == "calm-pack"
    assert isinstance(store.fingerprint(), tuple)
    assert store.install(_pack(id="second-pack", name="Second")).accepted
    assert store.duplicate("second-pack", "third-pack", "Third").accepted
    assert store.rename("third-pack", "fourth-pack", "Fourth").accepted
    assert store.remove("fourth-pack").status is PackMutationStatus.REMOVED
    assert [pack.pack_id for pack in store.list()] == ["calm-pack", "second-pack"]
    # None of the strays was touched.
    assert sorted(path.name for path in root.iterdir() if path.name != ".store.lock") == [
        ".DS_Store",
        "Bad Name.json",
        "a-folder",
        "calm-pack.json",
        "notes.txt",
        "second-pack.json",
    ]


def test_a_stray_file_is_named_in_the_log_once_not_once_per_read(tmp_path: Path) -> None:
    store, root, lines = _foreign_store(tmp_path)
    (root / ".DS_Store").write_bytes(b"\x00")

    for _ in range(3):
        store.list()
        store.fingerprint()

    assert len(lines) == 1
    assert ".DS_Store" in lines[0] and str(tmp_path) not in lines[0]
    # A second stray gets its own line.
    (root / "notes.txt").write_text("x")
    store.list()
    assert len(lines) == 2 and "notes.txt" in lines[1]


def test_a_fresh_scratch_file_is_left_alone_and_an_old_orphan_is_removed(
    tmp_path: Path,
) -> None:
    now = [1_800_000_000.0]
    store, root, lines = _foreign_store(tmp_path, clock=lambda: now[0])
    scratch = root / _scratch_name()
    scratch.write_text("{")
    scratch.chmod(0o600)
    os.utime(scratch, (now[0] - 3_600, now[0] - 3_600))

    assert [pack.pack_id for pack in store.list()] == ["calm-pack"]
    assert scratch.exists(), "a write may still be using it"

    now[0] += _DAY
    assert [pack.pack_id for pack in store.list()] == ["calm-pack"]
    assert not scratch.exists()
    assert any("orphaned scratch" in line and _scratch_name() in line for line in lines)
    assert (root / "calm-pack.json").exists()


def test_only_a_scratch_file_shaped_like_ours_is_ever_removed(tmp_path: Path) -> None:
    now = [1_800_000_000.0]
    store, root, _lines = _foreign_store(tmp_path, clock=lambda: now[0])
    keep = [
        root / ".DS_Store",
        root / "notes.tmp",
        root / "calm-pack.json.tmp",
        root / _scratch_name().replace("4242", "pid"),
        root / _scratch_name(tail="g" * 32),
    ]
    for path in keep:
        path.write_text("keep me")
        os.utime(path, (now[0] - 30 * _DAY, now[0] - 30 * _DAY))
    # A link that looks like a scratch file is not followed or removed.
    outside = tmp_path / "outside.txt"
    outside.write_text("outside")
    link = root / _scratch_name(tail="b" * 32)
    link.symlink_to(outside)

    store.list()

    assert all(path.read_text() == "keep me" for path in keep)
    assert link.is_symlink() and outside.read_text() == "outside"


def test_a_pack_shaped_entry_that_is_unsafe_still_refuses_the_store(tmp_path: Path) -> None:
    store, root, _lines = _foreign_store(tmp_path)
    outside = tmp_path / "outside.json"
    outside.write_text("{}")
    (root / "linked-pack.json").symlink_to(outside)

    with pytest.raises(EffectPackStoreError):
        store.list()
    with pytest.raises(EffectPackStoreError):
        store.fingerprint()
