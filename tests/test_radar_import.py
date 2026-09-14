"""radar_import: bounded, version-checked, data-only reports (S7.5/T38)."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from jrbar.core_runtime import CommandError, _cmd_import_radar_report
from jrbar.radar_import import (
    RadarImportError,
    import_radar_report,
    list_radar_reports,
    load_radar_report,
    validate_radar_document,
)


def _report(**meta):
    return {
        "analyzer": "agentic-radar",
        "version": "0.4.1",
        "repository": "JR-Bar",
        "revision": "abc123",
        "nodes": [
            {"id": "codex-agent", "type": "agent", "name": "Codex"},
            {"id": "shell-tool", "type": "tool", "name": "shell"},
            "loose-node",
        ],
        "edges": [
            {"source": "codex-agent", "target": "shell-tool",
             "kind": "uses"},
        ],
        **meta,
    }


def test_validate_normalizes_and_labels_static():
    doc = validate_radar_document(_report())
    assert doc["meta"]["analyzer_version"] == "0.4.1"
    assert doc["meta"]["repository"] == "JR-Bar"
    kinds = {node["id"]: node["kind"] for node in doc["nodes"]}
    assert kinds["codex-agent"] == "agent"
    assert kinds["shell-tool"] == "tool"
    assert kinds["loose-node"] == "other"
    edge = doc["edges"][0]
    # T38: an imported edge is statically detected — never observed.
    assert edge["evidence"] == "static"
    assert edge["dangling"] is False


def test_validate_refuses_non_object_and_missing_nodes():
    with pytest.raises(RadarImportError) as e:
        validate_radar_document(["not", "a", "dict"])
    assert e.value.code == "invalid_report"
    with pytest.raises(RadarImportError) as e:
        validate_radar_document({"meta": {}})
    assert e.value.code == "invalid_report"


def test_validate_caps_nodes(tmp_path, monkeypatch):
    monkeypatch.setattr("jrbar.radar_import.RADAR_MAX_NODES", 3)
    with pytest.raises(RadarImportError) as e:
        validate_radar_document({"nodes": ["a", "b", "c", "d"]})
    assert e.value.code == "too_large"


def test_dangling_edges_are_labeled():
    doc = validate_radar_document({
        "nodes": ["a"],
        "edges": [{"source": "a", "target": "ghost"}],
    })
    assert doc["edges"][0]["dangling"] is True


def test_import_stores_and_indexes(tmp_path):
    report = tmp_path / "report.json"
    report.write_text(json.dumps(_report()))
    summary = import_radar_report(report, state_dir=tmp_path / "state")
    assert summary["analyzer"] == "agentic-radar"
    assert summary["nodes"] == 3 and summary["edges"] == 1

    listed = list_radar_reports(state_dir=tmp_path / "state")
    assert [r["id"] for r in listed] == [summary["id"]]

    loaded = load_radar_report(summary["id"], state_dir=tmp_path / "state")
    assert loaded["meta"]["revision"] == "abc123"
    assert loaded["edges"][0]["evidence"] == "static"


def test_import_rejects_oversized_and_unreadable(tmp_path, monkeypatch):
    big = tmp_path / "big.json"
    big.write_text("{}")
    monkeypatch.setattr("jrbar.radar_import.RADAR_MAX_BYTES", 1)
    with pytest.raises(RadarImportError) as e:
        import_radar_report(big, state_dir=tmp_path)
    assert e.value.code == "too_large"
    monkeypatch.setattr("jrbar.radar_import.RADAR_MAX_BYTES", 4 * 1024 * 1024)

    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    with pytest.raises(RadarImportError) as e:
        import_radar_report(bad, state_dir=tmp_path)
    assert e.value.code == "invalid_report"

    with pytest.raises(RadarImportError) as e:
        import_radar_report(tmp_path / "missing.json", state_dir=tmp_path)
    assert e.value.code == "not_found"


def test_load_report_id_is_path_cleaned(tmp_path):
    assert load_radar_report("../escape", state_dir=tmp_path) is None
    assert load_radar_report("a/b", state_dir=tmp_path) is None


def test_command_errors_carry_codes(tmp_path):
    controller = SimpleNamespace()
    with pytest.raises(CommandError) as e:
        _cmd_import_radar_report(controller, {"path": str(tmp_path / "x.json")})
    assert e.value.code == "not_found"
    with pytest.raises(CommandError) as e:
        _cmd_import_radar_report(controller, {})
    assert e.value.code == "invalid_value"
