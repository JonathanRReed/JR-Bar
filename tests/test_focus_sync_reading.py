from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar import focus_sync


@pytest.fixture
def assertions_path(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    path = tmp_path / "Assertions.json"
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", path)
    return path


@pytest.mark.parametrize(
    "record",
    [
        {"unrecognizedModeIdentifier": "synthetic.work"},
        {"assertionDetailsModeIdentifier": ""},
        {"assertionDetailsModeIdentifier": " \t\n"},
        {"assertionDetailsModeIdentifier": 7},
        {"assertionDetailsModeIdentifier": None},
        "unrecognized assertion",
    ],
)
def test_unknown_active_assertion_is_unavailable(assertions_path: Path, record: object) -> None:
    assertions_path.write_text(json.dumps({"storeAssertionRecords": [record]}))
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        focus_sync.active_focus_mode_identifiers()


def test_mixed_active_assertions_do_not_export_a_partial_reading(assertions_path: Path) -> None:
    assertions_path.write_text(json.dumps({"storeAssertionRecords": [
        {"assertionDetailsModeIdentifier": "synthetic.work"},
        {"unrecognizedModeIdentifier": "synthetic.sleep"},
    ]}))
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        focus_sync.active_focus_mode_identifiers()


def test_nested_active_identifiers_are_sorted_and_deduplicated(assertions_path: Path) -> None:
    assertions_path.write_text(json.dumps({
        "configured": {"assertionDetailsModeIdentifier": "synthetic.inactive"},
        "nested": [{"storeAssertionRecords": [
            {"details": {"assertionDetailsModeIdentifier": "synthetic.work"}},
            {"assertionDetailsModeIdentifier": "synthetic.sleep"},
            {"assertionDetailsModeIdentifier": "synthetic.work"},
        ]}],
    }))
    assert focus_sync.active_focus_mode_identifiers() == ["synthetic.sleep", "synthetic.work"]


@pytest.mark.parametrize("document", [{}, {"storeAssertionRecords": []}, {
    "configured": {"assertionDetailsModeIdentifier": "synthetic.inactive"},
}])
def test_no_active_assertions_is_a_known_empty_reading(assertions_path: Path, document: object) -> None:
    assertions_path.write_text(json.dumps(document))
    assert focus_sync.active_focus_mode_identifiers() == []


def test_invalid_unicode_assertions_are_unavailable(assertions_path: Path) -> None:
    assertions_path.write_bytes(b"\xff\xfe")
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        focus_sync.active_focus_mode_identifiers()


def test_usable_active_identifier_keeps_its_original_content(assertions_path: Path) -> None:
    identifier = " Synthetic.Work "
    assertions_path.write_text(json.dumps({
        "storeAssertionRecords": [{"assertionDetailsModeIdentifier": identifier}],
    }))
    assert focus_sync.active_focus_mode_identifiers() == [identifier]


@pytest.mark.parametrize("identifier", ["x" * 257, "é" * 129, "\ud800"])
def test_active_identifier_outside_display_contract_is_unavailable(
    assertions_path: Path, identifier: str,
) -> None:
    assertions_path.write_text(json.dumps({
        "storeAssertionRecords": [{"assertionDetailsModeIdentifier": identifier}],
    }))
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        focus_sync.active_focus_mode_identifiers()


def test_more_than_64_distinct_active_identifiers_is_unavailable(assertions_path: Path) -> None:
    assertions_path.write_text(json.dumps({"storeAssertionRecords": [
        {"assertionDetailsModeIdentifier": f"synthetic.mode.{index:02d}"}
        for index in range(65)
    ]}))
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        focus_sync.active_focus_mode_identifiers()


@pytest.mark.parametrize("identifier", ["x" * 256, "é" * 128])
def test_active_identifier_at_256_utf8_bytes_keeps_its_content(
    assertions_path: Path, identifier: str,
) -> None:
    assertions_path.write_text(json.dumps({
        "storeAssertionRecords": [{"assertionDetailsModeIdentifier": identifier}],
    }))
    assert focus_sync.active_focus_mode_identifiers() == [identifier]


def test_64_distinct_active_identifiers_are_sorted(assertions_path: Path) -> None:
    identifiers = [f"synthetic.mode.{index:02d}" for index in reversed(range(64))]
    assertions_path.write_text(json.dumps({"storeAssertionRecords": [
        {"assertionDetailsModeIdentifier": identifier} for identifier in identifiers
    ]}))
    assert focus_sync.active_focus_mode_identifiers() == sorted(identifiers)


@pytest.mark.parametrize("records", [None, {}, "unexpected", 1])
def test_present_malformed_active_assertion_collection_is_unavailable(
    assertions_path: Path, records: object,
) -> None:
    assertions_path.write_text(json.dumps({"nested": {"storeAssertionRecords": records}}))
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        focus_sync.active_focus_mode_identifiers()


def test_more_than_64_rows_with_64_distinct_identifiers_are_deduplicated(
    assertions_path: Path,
) -> None:
    identifiers = [f"synthetic.mode.{index:02d}" for index in range(64)]
    assertions_path.write_text(json.dumps({"storeAssertionRecords": [
        {"assertionDetailsModeIdentifier": identifier}
        for identifier in identifiers + identifiers
    ]}))
    assert focus_sync.active_focus_mode_identifiers() == identifiers


def test_separated_assertion_lists_share_the_complete_identifier_limit(
    assertions_path: Path,
) -> None:
    assertions_path.write_text(json.dumps({"nested": [
        {"storeAssertionRecords": [
            {"assertionDetailsModeIdentifier": f"synthetic.mode.{index:02d}"}
            for index in range(32)
        ]},
        {"storeAssertionRecords": [
            {"assertionDetailsModeIdentifier": f"synthetic.mode.{index:02d}"}
            for index in range(32, 65)
        ]},
    ]}))
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        focus_sync.active_focus_mode_identifiers()


@pytest.mark.parametrize("reader", [
    focus_sync.active_focus_mode_identifiers,
    focus_sync.configured_focus_modes,
    focus_sync.is_focus_active,
])
def test_deep_json_parse_is_reported_as_unavailable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, reader,
) -> None:
    import sys

    path = tmp_path / "Focus.json"
    depth = sys.getrecursionlimit() + 100
    path.write_text("[" * depth + "{}" + "]" * depth)
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", path)
    monkeypatch.setattr(focus_sync, "MODE_CONFIGURATIONS_PATH", path)
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        reader()


@pytest.mark.parametrize("reader", [
    focus_sync.active_focus_mode_identifiers,
    focus_sync.configured_focus_modes,
    focus_sync.is_focus_active,
])
def test_deep_decoded_tree_walk_is_reported_as_unavailable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, reader,
) -> None:
    import sys

    path = tmp_path / "Focus.json"
    path.write_text("{}")
    node: object = {}
    for _ in range(sys.getrecursionlimit() + 100):
        node = [node]
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", path)
    monkeypatch.setattr(focus_sync, "MODE_CONFIGURATIONS_PATH", path)
    monkeypatch.setattr(focus_sync.json, "loads", lambda _raw: node)
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        reader()


def test_compat_active_reader_invalid_utf8_is_unavailable(assertions_path: Path) -> None:
    assertions_path.write_bytes(b"\xff\xfe")
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        focus_sync.is_focus_active()


@pytest.mark.parametrize("reader", [
    focus_sync.active_focus_mode_identifiers,
    focus_sync.configured_focus_modes,
    focus_sync.is_focus_active,
])
def test_all_focus_readers_reject_invalid_utf8(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, reader,
) -> None:
    path = tmp_path / "Focus.json"
    path.write_bytes(b"\xff\xfe")
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", path)
    monkeypatch.setattr(focus_sync, "MODE_CONFIGURATIONS_PATH", path)
    with pytest.raises(focus_sync.FocusSyncUnavailableError):
        reader()


@pytest.mark.parametrize("reader, expected", [
    (focus_sync.active_focus_mode_identifiers, []),
    (focus_sync.configured_focus_modes, []),
    (focus_sync.is_focus_active, False),
])
def test_focus_json_exact_read_limit_accepts_padded_empty_document(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, reader, expected,
) -> None:
    path = tmp_path / "Focus.json"
    path.write_bytes(b"{}" + b" " * (focus_sync.MAX_FOCUS_JSON_BYTES - 2))
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", path)
    monkeypatch.setattr(focus_sync, "MODE_CONFIGURATIONS_PATH", path)
    assert reader() == expected


@pytest.mark.parametrize("reader", [
    focus_sync.active_focus_mode_identifiers,
    focus_sync.configured_focus_modes,
    focus_sync.is_focus_active,
])
def test_focus_json_one_byte_over_read_limit_is_unavailable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, reader,
) -> None:
    path = tmp_path / "Focus.json"
    path.write_bytes(b"{}" + b" " * (focus_sync.MAX_FOCUS_JSON_BYTES - 1))
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", path)
    monkeypatch.setattr(focus_sync, "MODE_CONFIGURATIONS_PATH", path)
    with pytest.raises(focus_sync.FocusSyncUnavailableError, match="read limit"):
        reader()


def test_focus_loader_uses_one_bounded_read_without_permission_writes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    import io

    calls: list[tuple[str, object]] = []

    class ReadSpy(io.BytesIO):
        def read(self, size: int = -1) -> bytes:
            calls.append(("read", size))
            return super().read(size)

    def open_spy(self: Path, mode: str):
        calls.append(("open", mode))
        return ReadSpy(b"{}")

    def forbidden(*_args, **_kwargs):
        pytest.fail("reading OS-managed Focus data must not mutate permissions or directories")

    monkeypatch.setattr(Path, "open", open_spy)
    monkeypatch.setattr(Path, "chmod", forbidden)
    monkeypatch.setattr(Path, "mkdir", forbidden)
    assert focus_sync._load_focus_json(tmp_path / "missing-parent" / "Focus.json") == {}
    assert calls == [("open", "rb"), ("read", focus_sync.MAX_FOCUS_JSON_BYTES + 1)]
