"""Session provenance comes from validated work identity, not display labels."""

from jrbar.core_projection import session_document
from jrbar.provider_facts import SourceKey, WorkIdentifier, WorkKey
from tests.test_core_projection import _status


def test_t3_source_keeps_the_actual_provider_and_original_timestamp():
    status = _status(
        provider="codex", agent_id="codex:session:fixture", session_id="fixture",
        display_name="Fixture", cwd="/synthetic/project", origin="Unrelated title",
        work_key=WorkKey(SourceKey("codex", "t3code", "example-source", "threads"), WorkIdentifier("fixture")),
    )
    row = session_document(status, operator_state=None, ask_ids=frozenset(), extras=None, workers=0)
    assert row["provider"] == "codex"
    assert row["source_integration"] == "t3code"
    assert row["updated_at"] == status.updated_at.timestamp()


def test_origin_label_cannot_manufacture_t3_source_provenance():
    status = _status(
        provider="codex", agent_id="codex:session:fixture", session_id="fixture",
        display_name="Fixture", cwd="/synthetic/project", origin="T3 Code",
        work_key=WorkKey(SourceKey("codex", "native", "example-source", "threads"), WorkIdentifier("fixture")),
    )
    row = session_document(status, operator_state=None, ask_ids=frozenset(), extras=None, workers=0)
    assert row["provider"] == "codex"
    assert "source_integration" not in row
