"""W01 upgrade regressions: in-place answering must refuse unless every fact
is affirmative -- proven liveness, proven window ownership, and the terminal's
own word that its focused tab is the session's. A ``None`` is never proof.
"""

from __future__ import annotations

from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar.answer_local import (
    AnswerHostFacts,
    AnswerRefusal,
    host_offers_focused_tab_proof,
    plan_local_answer,
    plan_local_reply,
)


def proven_terminal_facts() -> AnswerHostFacts:
    return AnswerHostFacts(
        session_pid=101,
        session_alive=True,
        session_tty="/dev/ttys099",
        expected_bundle_ids=frozenset({"com.apple.Terminal"}),
        frontmost_bundle_id="com.apple.Terminal",
        frontmost_pid=10,
        frontmost_ancestor_of_session=True,
        focused_tab_tty="/dev/ttys099",
        accessibility_trusted=True,
    )


@pytest.mark.parametrize(
    "change",
    [
        {"session_alive": None},
        {"frontmost_ancestor_of_session": None},
        {"focused_tab_tty": None},
        {"focused_tab_tty": "/dev/ttys098"},
    ],
)
def test_approval_refuses_unproven_or_wrong_target(change):
    facts = replace(proven_terminal_facts(), **change)
    with pytest.raises(AnswerRefusal):
        plan_local_answer(provider="codex", decision="approve", ask_live=True, facts=facts)


def test_approval_refuses_resolved_request():
    with pytest.raises(AnswerRefusal):
        plan_local_answer(
            provider="codex",
            decision="approve",
            ask_live=False,
            facts=proven_terminal_facts(),
        )


def test_approval_refuses_a_terminal_that_cannot_prove_focus():
    """Ghostty shares one process across windows and has no focused-tab call:
    ancestry + frontmost can never pick the right tab, so the honest answer is
    a refusal and Open-in-terminal, not a key into an unproven window."""
    facts = replace(
        proven_terminal_facts(),
        expected_bundle_ids=frozenset({"com.mitchellh.ghostty"}),
        frontmost_bundle_id="com.mitchellh.ghostty",
        focused_tab_tty=None,
    )
    with pytest.raises(AnswerRefusal) as raised:
        plan_local_answer(provider="claude", decision="approve", ask_live=True, facts=facts)
    assert raised.value.code == "not_frontmost"
    assert raised.value.reason == "focused_tab_unproven"


def test_approval_refuses_when_the_sessions_own_tty_is_unknown():
    facts = replace(proven_terminal_facts(), session_tty=None)
    with pytest.raises(AnswerRefusal) as raised:
        plan_local_answer(provider="claude", decision="approve", ask_live=True, facts=facts)
    assert raised.value.code == "not_frontmost"
    assert raised.value.reason == "session_tty_unknown"


def test_refusal_reasons_name_the_missing_evidence():
    for change, code, reason in [
        ({"session_alive": None}, "session_gone", "liveness_unproven"),
        ({"frontmost_ancestor_of_session": None}, "not_frontmost", "ownership_unproven"),
        ({"focused_tab_tty": None}, "not_frontmost", "focused_tab_unproven"),
        ({"focused_tab_tty": "/dev/ttys098"}, "not_frontmost", "other_tab:/dev/ttys098"),
    ]:
        with pytest.raises(AnswerRefusal) as raised:
            plan_local_answer(
                provider="claude",
                decision="approve",
                ask_live=True,
                facts=replace(proven_terminal_facts(), **change),
            )
        assert (raised.value.code, raised.value.reason) == (code, reason)


def test_reply_delivery_obeys_the_same_fences():
    facts = replace(proven_terminal_facts(), focused_tab_tty=None)
    with pytest.raises(AnswerRefusal) as raised:
        plan_local_reply(
            provider="claude", reply_text="yes", ask_live=True, facts=facts
        )
    assert raised.value.code == "not_frontmost"


def test_a_fully_proven_plan_still_ships_the_measured_key():
    plan = plan_local_answer(
        provider="codex",
        decision="approve",
        ask_live=True,
        facts=proven_terminal_facts(),
    )
    assert plan.key.label == "y" and plan.target_pid == 10
    assert plan.mechanism == "synthetic_keystroke"
    assert plan.facts.window_evidence() == "focused_tab_tty"


def test_a_posted_key_reports_attempt_not_confirmation():
    """A posted key is an attempted delivery, not a confirmed approval: the
    wire document must say so instead of letting ``delivered`` read as
    "resolved" (provider confirmation is what closes the request)."""
    from jrbar.answer_local import LocalAnswerDelivery

    sent = []
    delivery = LocalAnswerDelivery(
        sender=lambda pid, code: sent.append((pid, code)),
        observer=lambda **kwargs: proven_terminal_facts(),
    )
    outcome = delivery.deliver(
        provider="codex",
        decision="approve",
        session_pid=101,
        expected_bundle_ids=frozenset({"com.apple.Terminal"}),
        session_tty="/dev/ttys099",
        is_live=lambda: True,
    )
    assert outcome.delivered and sent == [(10, 16)]
    document = outcome.document()
    assert document["confirmation"] == "provider_pending"
    assert document["mechanism"] == "synthetic_keystroke"
    assert document["host"]["window_evidence"] == "focused_tab_tty"


def test_answerable_display_follows_the_provable_host():
    """``answerable`` in the state document must agree with the route that
    can actually execute: a contract-supported ask on a Ghostty-hosted (or
    host-unknown, or remote) session reports False so the UI offers Open
    instead of a button that could only refuse."""
    from jrbar.core_projection import _answer_flags
    from jrbar.providers import negotiated_provider_sources

    source = next(
        candidate
        for candidate in negotiated_provider_sources()
        if candidate.source_key.provider_id == "codex"
        and candidate.source_key.adapter_id == "hooks"
    )
    from jrbar.provider_facts import RequestKind

    request = SimpleNamespace(
        key=SimpleNamespace(
            work_key=SimpleNamespace(source_key=source.source_key)
        ),
        request_kind=RequestKind.PERMISSION,
    )
    contracts = {source.source_key: source.contract}
    handler = lambda _invocation: True

    assert _answer_flags(request, contracts, handler, {"com.apple.Terminal"}) == (
        True,
        False,
    )
    assert _answer_flags(request, contracts, handler, {"com.googlecode.iterm2"}) == (
        True,
        False,
    )
    for bundles in (
        {"com.mitchellh.ghostty"},
        frozenset(),
        None,
        {"com.apple.Terminal", "com.mitchellh.ghostty"},
    ):
        expected = bundles is not None and "com.apple.Terminal" in bundles
        assert _answer_flags(request, contracts, handler, bundles) == (
            expected,
            False,
        )


def test_host_proof_helper_covers_exactly_the_scriptable_terminals():
    assert host_offers_focused_tab_proof({"com.apple.Terminal"})
    assert host_offers_focused_tab_proof({"com.googlecode.iterm2"})
    assert host_offers_focused_tab_proof(
        frozenset({"com.mitchellh.ghostty", "com.apple.Terminal"})
    )
    assert not host_offers_focused_tab_proof({"com.mitchellh.ghostty"})
    assert not host_offers_focused_tab_proof(frozenset())
    assert not host_offers_focused_tab_proof(None)
    assert not host_offers_focused_tab_proof("com.apple.Terminal")
