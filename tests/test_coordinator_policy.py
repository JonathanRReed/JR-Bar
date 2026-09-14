"""Coordinator policy: bounded evidence, typed proposals, refusal."""

import pytest

from jrbar.coordinator_policy import (
    ProposalRefused,
    bounded_evidence,
    evidence_for_question,
    parse_proposal,
    parse_proposal_json,
    requires_confirmation,
)


def test_bounded_evidence_redacts_to_glance_fields():
    row = {
        "provider": "codex", "mode": "working", "stale": False,
        "label": "fix the bug", "cwd": "/repo",
        "axes": {"attention": "working", "outcome": "none",
                 "secret": "drop me"},
        "message": "raw transcript text stays out",
        "token_key": "must-not-leak",
    }
    evidence = bounded_evidence(row)
    assert evidence == {
        "provider": "codex", "mode": "working", "stale": False,
        "label": "fix the bug", "cwd": "/repo",
        "attention": "working", "outcome": "none",
    }
    assert "message" not in evidence
    assert "token_key" not in evidence
    assert "secret" not in evidence


def test_evidence_bound_caps_sessions():
    rows = [{"provider": "codex", "mode": "working"} for _ in range(20)]
    assert len(evidence_for_question(rows)) == 12


def test_parse_proposal_accepts_allowed_actions():
    proposal = parse_proposal({
        "action": "open_session", "session": "codex:abc",
        "preview": "Open the codex session"})
    assert proposal.action == "open_session"
    assert proposal.requires_confirmation is False
    answer = parse_proposal({
        "action": "answer_ask", "session": "codex:abc",
        "arguments": {"decision": "approve"}})
    assert answer.requires_confirmation is True


def test_parse_proposal_refuses_unknown_and_missing():
    with pytest.raises(ProposalRefused, match="action must be"):
        parse_proposal({"action": "rm -rf /", "session": "s"})
    with pytest.raises(ProposalRefused, match="needs a session"):
        parse_proposal({"action": "open_session"})
    with pytest.raises(ProposalRefused, match="must be an object"):
        parse_proposal("just a string")
    with pytest.raises(ProposalRefused, match="scalar"):
        parse_proposal({"action": "open_session", "session": "s",
                        "arguments": {"nested": {"no": "objects"}}})


def test_parse_proposal_json_refuses_prose_and_bad_json():
    with pytest.raises(ProposalRefused, match="not prose"):
        parse_proposal_json("Sure! I'll open that for you.")
    with pytest.raises(ProposalRefused, match="JSON text"):
        parse_proposal_json(42)
    with pytest.raises(ProposalRefused, match="invalid proposal JSON"):
        parse_proposal_json("{not json}")
    good = parse_proposal_json('{"action": "open_session", "session": "s1"}')
    assert good.action == "open_session"


def test_confirmation_policy_is_closed():
    assert requires_confirmation("answer_ask") is True
    assert requires_confirmation("open_session") is False
    assert requires_confirmation("anything-else") is False
