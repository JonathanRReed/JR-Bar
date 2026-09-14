"""The widget snapshot: redacted, bounded, atomic."""

import json

from jrbar.widget_snapshot import widget_snapshot, write_widget_snapshot


def _session(provider="codex", mode="working", stale=False, attention=None):
    row = {"provider": provider, "mode": mode, "stale": stale,
           "title": "secret title", "message": "secret body"}
    if attention:
        row["axes"] = {"attention": attention}
    return row


def test_snapshot_counts_and_redaction(tmp_path):
    state = {"sessions": [
        _session(mode="working"),
        _session(provider="claude", mode="waiting_for_input"),
        _session(provider="gemini", mode="working", attention="waiting", stale=True),
    ]}
    snap = widget_snapshot(state, now=1_700_000_000.0)
    # waiting_for_input counts as live work; the "waiting" attention row
    # is counted in waiting, not double-counted in working.
    assert snap["counts"] == {"sessions": 3, "working": 2, "waiting": 1,
                            "stale": 1, "shown": 3}
    # Entries carry provider/mode/flags only — never titles or messages.
    for entry in snap["entries"]:
        assert set(entry) == {"provider", "mode", "waiting", "stale"}
    assert snap["generated_at"] == 1_700_000_000.0


def test_snapshot_bounds_entries(tmp_path):
    state = {"sessions": [_session() for _ in range(40)]}
    snap = widget_snapshot(state, now=0.0)
    assert snap["counts"]["shown"] == 24
    assert snap["counts"]["sessions"] == 40
    assert len(snap["entries"]) == 24


def test_snapshot_tolerates_missing_and_malformed():
    assert widget_snapshot({}, now=0.0)["counts"]["sessions"] == 0
    snap = widget_snapshot({"sessions": ["junk", {"provider": "codex"}]},
                           now=0.0)
    # A non-mapping row is not a session at all; it can't even miscount.
    assert snap["counts"]["sessions"] == 1
    assert len(snap["entries"]) == 1  # the junk row can't project


def test_write_is_atomic_and_valid_json(tmp_path):
    state = {"sessions": [_session()]}
    target = write_widget_snapshot(state, tmp_path, now=1.0)
    assert target.name == "widget-snapshot.json"
    loaded = json.loads(target.read_text())
    assert loaded["schema"] == 1
    assert loaded["counts"]["working"] == 1
    # No tmp files left behind after the rename.
    assert not list(tmp_path.glob(".*.tmp"))
