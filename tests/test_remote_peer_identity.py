"""Connected peer identity is distinct from its friendly machine name."""
import json

import pytest

from jrbar import remote_peers
from tests.test_remote_peers import Clock, document, peer, reader_returning


def test_same_machine_name_and_source_id_do_not_collapse_distinct_hosts():
    result = remote_peers.refresh_peers(
        (peer("desk-one", "Same Desk"), peer("desk-two", "Same Desk")),
        reader=reader_returning(document()), now_monotonic=Clock(),
    )
    rows = [row for ledger in result.ledgers for row in ledger.rows]
    assert len(rows) == 2
    assert len({row.key for row in rows}) == 2
    assert {row.machine for row in rows} == {"Same Desk"}
    assert len({row.source_agent_id for row in rows}) == 1


def test_connected_host_suffix_is_stable_and_preserves_native_id_segments():
    result = remote_peers.refresh_peers(
        (peer("desk-one", "Same Desk"),), reader=reader_returning(document()), now_monotonic=Clock(),
    )
    row = result.ledgers[0].rows[0]
    assert row.key.split(":")[1] == "Same Desk"
    assert row.key.split(":")[2] == row.status.provider
    assert row.key.startswith(f"remote:Same Desk:{row.source_agent_id}~")
    assert len(row.key.rsplit("~", 1)[1]) == 32
    again = remote_peers.refresh_peers(
        (peer("desk-one", "Same Desk"),), reader=reader_returning(document()), now_monotonic=Clock(),
    )
    assert again.ledgers[0].rows[0].key == row.key


def test_direct_parser_retains_legacy_ids_without_channel_namespace():
    ledger = remote_peers.parse_remote_ledger_document(document(), machine="Same Desk")
    row = ledger.rows[0]
    assert row.key == f"remote:Same Desk:{row.source_agent_id}"


def test_document_cannot_supply_its_own_channel_namespace():
    payload = json.loads(document())
    payload["source_namespace"] = "desk-two"
    with pytest.raises(remote_peers.RemotePeerError):
        remote_peers.parse_remote_ledger_document(json.dumps(payload), source_namespace="desk-one")


def test_unsafe_channel_namespace_is_rejected():
    for namespace in ["", "-unsafe", "bad host", "line\nbreak"]:
        with pytest.raises(remote_peers.RemotePeerError):
            remote_peers.parse_remote_ledger_document(document(), source_namespace=namespace)
