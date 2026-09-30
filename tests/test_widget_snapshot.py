"""The widget snapshot: redacted, bounded, atomic.

Rows here have the shape the daemon really sends in ``state.sessions``
(``core_projection.session_document``): a ``kind`` of ``main`` or
``worker``, and an ``ask`` that is a mapping while a person is being asked
and ``None`` otherwise.  There is no ``axes.attention`` on a real row.
"""

import json

from jrbar.widget_snapshot import widget_snapshot, write_widget_snapshot


def _session(provider="codex", mode="working", stale=False, ask=False, kind="main"):
    row = {"provider": provider, "mode": mode, "stale": stale, "kind": kind,
           "title": "secret title", "message": "secret body",
           "next_actor": "user" if mode == "waiting_for_input" else "provider",
           "ask": None, "axes": {"outcome": "none", "review": "none", "freshness": "fresh"}}
    if ask:
        row["ask"] = {"kind": "permission", "opened_at": 1_700_000_000.0,
                      "summary": "secret summary", "answerable": True}
    return row


def test_snapshot_counts_and_redaction(tmp_path):
    state = {"sessions": [
        _session(mode="working"),
        _session(provider="claude", mode="waiting_for_input"),
        _session(provider="gemini", mode="waiting_for_input", ask=True, stale=True),
    ]}
    snap = widget_snapshot(state, now=1_700_000_000.0)
    # waiting_for_input with no ask counts as live work; a row that carries
    # an ask is counted in waiting, not double-counted in working.
    assert snap["counts"] == {"sessions": 3, "working": 2, "waiting": 1,
                            "stale": 1, "shown": 3}
    assert [entry["waiting"] for entry in snap["entries"]] == [False, False, True]
    # Entries carry provider/mode/flags only — never titles or messages.
    for entry in snap["entries"]:
        assert set(entry) == {"provider", "mode", "waiting", "stale"}
    assert "secret" not in json.dumps(snap)
    assert snap["generated_at"] == 1_700_000_000.0


def test_waiting_comes_from_the_ask_the_daemon_sends():
    """``waiting`` used to read ``axes.attention``, a key the daemon never
    emits, so it was 0 for every main session however many were asking."""
    asking = widget_snapshot({"sessions": [_session(ask=True)]}, now=0.0)
    assert asking["counts"]["waiting"] == 1
    assert asking["counts"]["working"] == 0
    assert asking["entries"][0]["waiting"] is True

    # The invented key is not a second source: a row that only carries it
    # is not being asked anything.
    invented = _session()
    invented["axes"] = {"attention": "waiting"}
    quiet = widget_snapshot({"sessions": [invented]}, now=0.0)
    assert quiet["counts"]["waiting"] == 0
    assert quiet["entries"][0]["waiting"] is False


def test_a_worker_is_not_a_session_the_widget_counts():
    """The menu bar counts main sessions only; a worker with no ask carries
    ``mode: waiting_for_input`` and ``next_actor: user`` and used to land
    in ``working`` (the live-mode set includes waiting_for_input) and in a
    tile.  With sub-agent asks on it carries an ask, and is still not a
    session: the widget agrees with ``state.aggregate``."""
    state = {"sessions": [
        _session(provider="claude", mode="working"),
        _session(provider="claude", mode="waiting_for_input", kind="worker"),
        _session(provider="claude", mode="waiting_for_input", kind="worker", ask=True),
        _session(provider="claude", mode="working", kind="worker", stale=True),
    ]}
    snap = widget_snapshot(state, now=0.0)
    assert snap["counts"] == {"sessions": 1, "working": 1, "waiting": 0,
                            "stale": 0, "shown": 1}
    assert len(snap["entries"]) == 1

    # A main session's ask still counts, beside a quiet worker.
    with_ask = widget_snapshot({"sessions": [
        _session(provider="claude", mode="waiting_for_input", ask=True),
        _session(provider="claude", mode="waiting_for_input", kind="worker"),
    ]}, now=0.0)
    assert with_ask["counts"] == {"sessions": 1, "working": 0, "waiting": 1,
                                  "stale": 0, "shown": 1}


def test_a_row_without_a_kind_is_a_main_session():
    """``aggregate_counts`` reads a missing kind as main; so does the widget."""
    row = _session()
    del row["kind"]
    snap = widget_snapshot({"sessions": [row]}, now=0.0)
    assert snap["counts"]["sessions"] == 1


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
