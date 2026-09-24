from __future__ import annotations

import json
import os
import random
import sqlite3
import zlib
from pathlib import Path

import pytest

from jrbar.usage_file_index import UsageFileIndex

SOURCE = {"provider": "claude", "root": "projects-v1"}
SECRET = "ab" * 32


def _document(value: int = 1) -> dict:
    return {
        "entry": {"stat": [1, 2, 3, 4], "records": [[value, "model"]]},
        "sessions": [f"session-{value}"],
        "models": ["claude-opus-4"],
        "dedupes": [f"dedupe-{value}"],
    }


def _open(path: Path, *, source: dict = SOURCE, secret: str = SECRET):
    return UsageFileIndex.open(
        path,
        source_key=source,
        cache_version=7,
        seed_secret=secret,
    )


def test_reopens_and_reads_committed_documents(tmp_path: Path) -> None:
    path = tmp_path / "cache" / "usage.sqlite"
    index = _open(path)
    assert index is not None
    assert index.put("file-a", _document())
    index.close()

    reopened = _open(path)
    assert reopened is not None
    assert reopened.get("file-a") == _document()
    assert reopened.dedupe_secret == SECRET
    reopened.close()
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700


def test_repeated_usage_metadata_fits_bounded_disk_and_round_trips(tmp_path, monkeypatch):
    from jrbar import usage_file_index

    monkeypatch.setattr(usage_file_index, "MAX_DATABASE_BYTES", 64 * 1024)
    path = tmp_path / "usage.sqlite"
    document = {"records": [["opaque-session", "model", 100, 20, 5, 1]] * 400}
    index = _open(path)
    assert index is not None
    for number in range(16):
        assert index.put(f"file-{number}", document)
    index.close()
    reopened = _open(path)
    assert reopened is not None
    for number in range(16):
        assert reopened.get(f"file-{number}") == document
    reopened.close()
    assert path.stat().st_size <= 64 * 1024


@pytest.mark.parametrize("damage", ["oversize", "truncated", "trailing", "invalid_json"])
def test_compressed_corruption_is_a_bounded_per_row_miss(tmp_path, monkeypatch, damage):
    from jrbar import usage_file_index

    path = tmp_path / "usage.sqlite"
    index = _open(path)
    assert index is not None
    assert index.put("valid", _document())
    index.close()
    raw = b'{"value":"' + b'x' * 4096 + b'"}'
    encoded = zlib.compress(raw)
    if damage == "truncated":
        encoded = encoded[:-2]
    elif damage == "trailing":
        encoded += b"extra"
    elif damage == "invalid_json":
        encoded = zlib.compress(b"not json")
    if damage == "oversize":
        monkeypatch.setattr(usage_file_index, "MAX_DOCUMENT_BYTES", 1024)
    with sqlite3.connect(path) as connection:
        connection.execute(
            "INSERT INTO files(file_key, document, sequence) VALUES (?, ?, ?)",
            ("damaged", b"JRZ1" + encoded, 2),
        )
    reopened = _open(path)
    assert reopened is not None
    assert reopened.get("damaged") is None
    assert reopened.get("valid") == _document()
    reopened.close()


def test_source_or_version_change_discards_old_rows_but_keeps_secret__and_1_more(tmp_path: Path) -> None:
    # --- scenario: source_or_version_change_discards_old_rows_but_keeps_secret
    path = tmp_path / "usage.sqlite"
    index = _open(path)
    assert index is not None
    assert index.put("old", _document())
    index.close()

    other = UsageFileIndex.open(
        path,
        source_key={"provider": "claude", "root": "different"},
        cache_version=8,
        seed_secret="cd" * 32,
    )
    assert other is not None
    assert other.get("old") is None
    assert other.dedupe_secret == SECRET
    other.close()

    # --- scenario: prune_retains_only_live_keys
    path = tmp_path / "usage.sqlite"
    index = _open(path)
    assert index is not None
    for key in ("a", "b", "c"):
        assert index.put(key, _document(ord(key)))
    index.prune({"a", "c"})
    index.close()

    reopened = _open(path)
    assert reopened is not None
    assert reopened.get("a") is not None
    assert reopened.get("b") is None
    assert reopened.get("c") is not None
    reopened.close()


def _seed_stale_rows(path: Path, count: int) -> None:
    """Rows keyed the way a changed device number leaves them: all stale."""
    with sqlite3.connect(path) as connection:
        connection.executemany(
            "INSERT INTO files(file_key, document, sequence) VALUES (?, ?, ?)",
            [(f"codex:16777231:{1_000_000_000 + n}", json.dumps(_document(n)), n + 1) for n in range(count)],
        )
    connection.close()


def _row_keys(path: Path) -> set[str]:
    connection = sqlite3.connect(path)
    try:
        return {row[0] for row in connection.execute("SELECT file_key FROM files")}
    finally:
        connection.close()


def test_prune_clears_thousands_of_stale_rows_and_the_scan_still_saves(tmp_path: Path) -> None:
    """The live Codex index sat unsaved from Sep 13: one progress budget over
    5,419 stale rows interrupted the prune, which refused every put after it."""
    path = tmp_path / "usage.sqlite"
    created = _open(path)
    assert created is not None
    created.close()
    _seed_stale_rows(path, 6000)

    index = _open(path)
    assert index is not None
    index.prune({"codex:16777234:1"})
    assert index.put("codex:16777234:1", _document(1))
    index.close()

    assert _row_keys(path) == {"codex:16777234:1"}
    reopened = _open(path)
    assert reopened is not None
    assert reopened.get("codex:16777234:1") == _document(1)
    assert reopened.put("codex:16777234:2", _document(2)), "the row count was left wrong"
    reopened.close()


class _DeleteFailsAfterFirstChunk:
    """A connection whose second DELETE chunk fails, as an interrupt would."""

    def __init__(self, connection: sqlite3.Connection) -> None:
        self._connection = connection
        self.deletes = 0

    def executemany(self, sql: str, rows):
        if sql.startswith("DELETE"):
            self.deletes += 1
            if self.deletes == 2:
                raise sqlite3.OperationalError("interrupted")
        return self._connection.executemany(sql, rows)

    def __getattr__(self, name: str):
        return getattr(self._connection, name)


def test_a_failed_prune_is_undone_on_its_own_and_the_puts_still_commit(tmp_path: Path) -> None:
    path = tmp_path / "usage.sqlite"
    created = _open(path)
    assert created is not None
    assert created.put("kept-before", _document(1))
    created.close()
    _seed_stale_rows(path, 1000)

    index = _open(path)
    assert index is not None
    failing = _DeleteFailsAfterFirstChunk(index._connection)
    index._connection = failing
    index.prune({"kept-before", "live"})
    assert failing.deletes == 2, "the prune never reached a second chunk"
    assert index.put("live", _document(2)), "a failed prune refused the scan's writes"
    index.close()

    keys = _row_keys(path)
    assert {"kept-before", "live"} <= keys
    assert len(keys) == 1002, "the first chunk's deletes were not rolled back with the rest"



def test_row_and_document_caps_reject_new_rows_without_evicting(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import usage_file_index

    monkeypatch.setattr(usage_file_index, "MAX_ROWS", 2)
    monkeypatch.setattr(usage_file_index, "MAX_DOCUMENT_BYTES", 180)
    index = _open(tmp_path / "usage.sqlite")
    assert index is not None
    assert not index.put("huge", {"entry": {"records": []}, "blob": "x" * 500})
    assert index.put("a", _document(1))
    assert index.put("b", _document(2))
    assert not index.put("c", _document(3))
    assert index.put("a", _document(4))
    assert index.get("a") == _document(4)
    assert index.get("b") == _document(2)
    assert index.get("c") is None
    index.close()


def test_disk_cap_rejects_growth(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import usage_file_index

    monkeypatch.setattr(usage_file_index, "MAX_DATABASE_BYTES", 1)
    index = _open(tmp_path / "usage.sqlite")
    assert index is None
    assert (tmp_path / "usage.sqlite").stat().st_size <= 1


def test_disk_full_does_not_rollback_earlier_successful_rows(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from jrbar import usage_file_index

    path = tmp_path / "usage.sqlite"
    initial = _open(path)
    assert initial is not None
    initial.close()
    with sqlite3.connect(path) as connection:
        page_size = connection.execute("PRAGMA page_size").fetchone()[0]
    monkeypatch.setattr(
        usage_file_index,
        "MAX_DATABASE_BYTES",
        path.stat().st_size + page_size,
    )
    index = _open(path)
    assert index is not None
    assert index.put("small", _document())
    assert not index.put("large", {"blob": random.Random(0).randbytes(page_size * 4).hex()})
    index.close()

    reopened = _open(path)
    assert reopened is not None
    assert reopened.get("small") == _document()
    assert reopened.get("large") is None
    reopened.close()
    assert path.stat().st_size <= usage_file_index.MAX_DATABASE_BYTES


def test_compatible_warm_open_reads_while_another_index_has_pending_writes(tmp_path: Path) -> None:
    path = tmp_path / "usage.sqlite"
    initial = _open(path)
    assert initial is not None
    assert initial.put("committed", _document(1))
    initial.close()

    writer = _open(path)
    assert writer is not None
    assert writer.put("pending", _document(2))
    reader = _open(path)
    assert reader is not None
    assert reader.get("committed") == _document(1)
    assert reader.get("pending") is None
    reader.close()
    writer.close()


def test_two_open_writers_recheck_row_capacity_after_other_writer_commits__and_1_more(tmp_path, monkeypatch) -> None:
    # --- scenario: two_open_writers_recheck_row_capacity_after_other_writer_commits
    from jrbar import usage_file_index

    monkeypatch.setattr(usage_file_index, "MAX_ROWS", 2)
    path = tmp_path / "usage.sqlite"
    initial = _open(path)
    assert initial.put("initial", _document())
    initial.close()
    first = _open(path)
    second = _open(path)
    assert first.put("first", _document(1))
    first.close()
    assert not second.put("second", _document(2))
    assert second.get("first") == _document(1)
    second.close()

    # --- scenario: compressed_size_boundary_and_concatenated_members
    monkeypatch.undo()
    from jrbar import usage_file_index

    monkeypatch.setattr(usage_file_index, "MAX_DOCUMENT_BYTES", 8192)
    path = tmp_path / "usage.sqlite"
    index = _open(path)
    # Compact JSON contributes 12 bytes around the string.
    document = {"value": "x" * (8192 - 12)}
    assert index.put("exact", document)
    assert not index.put("too-big", {"value": "x" * (8192 - 11)})
    index.close()
    with sqlite3.connect(path) as connection:
        connection.execute(
            "INSERT INTO files(file_key, document, sequence) VALUES (?, ?, ?)",
            ("concatenated", b"JRZ1" + zlib.compress(b'{}') + zlib.compress(b'{}'), 2),
        )
    reopened = _open(path)
    assert reopened.get("exact") == document
    assert reopened.get("concatenated") is None
    reopened.close()



def test_get_rejects_payload_larger_than_document_cap(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import usage_file_index

    path = tmp_path / "usage.sqlite"
    index = _open(path)
    assert index is not None
    index.close()
    connection = sqlite3.connect(path)
    connection.execute(
        "INSERT INTO files(file_key, document, sequence) VALUES (?, ?, ?)",
        ("large", json.dumps({"blob": "x" * 1000}), 1),
    )
    connection.commit()
    connection.close()
    monkeypatch.setattr(usage_file_index, "MAX_DOCUMENT_BYTES", 100)

    reopened = _open(path)
    assert reopened is not None
    assert reopened.get("large") is None
    reopened.close()


def test_invalid_json_is_a_repairable_per_row_miss(tmp_path: Path) -> None:
    path = tmp_path / "usage.sqlite"
    index = _open(path)
    assert index is not None
    assert index.put("valid", _document(1))
    assert index.put("damaged", _document(2))
    index.close()
    with sqlite3.connect(path) as connection:
        connection.execute(
            "UPDATE files SET document = ? WHERE file_key = ?",
            ("{invalid", "damaged"),
        )

    reopened = _open(path)
    assert reopened is not None
    assert reopened.get("damaged") is None
    assert reopened.get("valid") == _document(1)
    assert reopened.put("damaged", _document(3))
    reopened.close()

    repaired = _open(path)
    assert repaired is not None
    assert repaired.get("valid") == _document(1)
    assert repaired.get("damaged") == _document(3)
    repaired.close()


def test_rejects_database_with_triggers_or_views(tmp_path: Path) -> None:
    path = tmp_path / "usage.sqlite"
    index = _open(path)
    assert index is not None
    index.close()
    connection = sqlite3.connect(path)
    connection.execute(
        "CREATE TRIGGER hostile AFTER INSERT ON files BEGIN DELETE FROM files; END"
    )
    connection.commit()
    connection.close()

    assert _open(path) is None


@pytest.mark.parametrize("kind", ["symlink", "hardlink"])
def test_refuses_linked_database(tmp_path: Path, kind: str) -> None:
    victim = tmp_path / "victim"
    victim.write_bytes(b"unchanged")
    path = tmp_path / "usage.sqlite"
    if kind == "symlink":
        path.symlink_to(victim)
    else:
        os.link(victim, path)

    assert _open(path) is None
    assert victim.read_bytes() == b"unchanged"


@pytest.mark.parametrize("suffix", ["-journal", "-wal", "-shm"])
@pytest.mark.parametrize("kind", ["symlink", "hardlink"])
def test_refuses_linked_sqlite_sidecars(tmp_path: Path, suffix: str, kind: str) -> None:
    path = tmp_path / "usage.sqlite"
    index = _open(path)
    assert index is not None
    index.close()
    victim = tmp_path / f"victim-{suffix[1:]}"
    victim.write_bytes(b"unchanged")
    sidecar = Path(f"{path}{suffix}")
    if kind == "symlink":
        sidecar.symlink_to(victim)
    else:
        os.link(victim, sidecar)

    assert _open(path) is None
    assert victim.read_bytes() == b"unchanged"


def test_corrupt_database_is_a_cache_miss(tmp_path: Path) -> None:
    path = tmp_path / "usage.sqlite"
    path.write_bytes(b"not sqlite")
    assert _open(path) is None


def test_locked_database_is_a_cache_miss(tmp_path: Path) -> None:
    path = tmp_path / "usage.sqlite"
    index = _open(path)
    assert index is not None
    index.close()
    blocker = sqlite3.connect(path)
    blocker.execute("BEGIN EXCLUSIVE")
    try:
        assert _open(path) is None
    finally:
        blocker.rollback()
        blocker.close()


def test_invalid_seed_secret_is_rejected_without_creating_database__and_1_more(tmp_path: Path) -> None:
    # --- scenario: invalid_seed_secret_is_rejected_without_creating_database
    path = tmp_path / "usage.sqlite"
    assert _open(path, secret="not-a-secret") is None
    assert not path.exists()

    # --- scenario: payload_is_json_and_contains_no_key_or_metadata_copy
    path = tmp_path / "usage.sqlite"
    index = _open(path)
    assert index is not None
    assert index.put("opaque-key", _document())
    index.close()
    connection = sqlite3.connect(path)
    try:
        payload = connection.execute("SELECT document FROM files").fetchone()[0]
    finally:
        connection.close()
    assert json.loads(payload) == _document()

