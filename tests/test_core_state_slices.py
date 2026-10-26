from __future__ import annotations

import json
from types import SimpleNamespace

from jrbar.core_server import CoreServer, _Client, encode_frame
from jrbar.core_state_slices import StateSlices


def test_slices_compare_the_last_sent_state_and_keep_independent_generations():
    slices = StateSlices()
    base = {"generation": 1, "now": 100, "sessions": [], "asks": [], "usage": {"providers": []}}
    first = slices.delta(base)
    assert first["slices"]["sessions"] == {"generation": 1, "value": []}
    changed = slices.delta({**base, "generation": 4, "now": 104, "asks": [{"id": "ask"}]})
    assert changed["slices"] == {"asks": {"generation": 2, "value": [{"id": "ask"}]}}
    cleared = slices.delta({**base, "generation": 6})
    assert cleared["slices"] == {"asks": {"generation": 3, "value": []}}
    assert slices.generations["sessions"] == 1


def test_write_counters_leave_the_devices_slice_and_volatile_ages_do_not_churn():
    slices = StateSlices()
    def state(writes, age):
        return {"devices": [{"id": "fake", "write_health": {"writes": writes}}],
                "health": {"sources": {"claude": {"heard_age_seconds": age, "fresh": True}}}}
    first = slices.delta(state(1, 1))
    assert first["slices"]["devices"]["value"] == [{"id": "fake"}]
    assert slices.delta(state(2, 2))["slices"] == {}


def test_socket_fanout_sends_deltas_only_to_subscribers_and_preserves_full_clients():
    legacy, modern = [], []
    server = CoreServer(dispatch=lambda *_: {}, initial_documents=lambda: [])
    old = _Client(SimpleNamespace(sendall=lambda value: legacy.append(json.loads(value))), 1)
    new = _Client(SimpleNamespace(sendall=lambda value: modern.append(json.loads(value))), 2)
    old._held = new._held = None
    new.state_slices = True
    server._clients = [old, new]
    server._fan_out(encode_frame({"t": "state", "v": 1, "generation": 1, "sessions": [], "asks": []}))
    server._fan_out(encode_frame({"t": "state", "v": 1, "generation": 2, "sessions": [], "asks": [{"id": "ask"}]}))
    assert legacy[-1]["t"] == "state"
    assert legacy[-1]["sessions"] == []
    assert modern[-1]["t"] == "state_delta"
    assert modern[-1]["slices"] == {"asks": {"generation": 2, "value": [{"id": "ask"}]}}


def test_delayed_greeting_and_other_clients_never_supply_a_delta_baseline():
    frames = []
    client = _Client(SimpleNamespace(sendall=lambda value: frames.append(json.loads(value))), 1)
    client.state_slices = True
    # The greeting's snapshot overtook a pending coalesced state.
    client.send(encode_frame({"t": "state", "generation": 3, "asks": [{"id": "new"}]}))
    client.send(encode_frame({"t": "state", "generation": 2, "asks": []}))
    client.send(encode_frame({"t": "state", "generation": 4, "asks": []}))
    assert len(frames) == 2
    assert frames[0]["t"] == "state"
    assert frames[1]["slices"]["asks"]["value"] == []


def test_roster_changes_send_only_changed_fields_and_explicit_order():
    slices = StateSlices()
    rows = [{"id": "a", "mode": "working", "provider": "claude"},
            {"id": "b", "mode": "working", "provider": "codex"}]
    slices.delta({"sessions": rows})
    update = slices.delta({"sessions": [{**rows[1], "mode": "idle"}, rows[0]]})
    assert update["slices"]["sessions"] == {
        "generation": 2, "changes": {"b": {"mode": "idle"}}, "removed": [], "order": ["b", "a"]}
