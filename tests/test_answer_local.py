"""The local answer surface: which key, and every reason not to send it."""

from __future__ import annotations

import pytest

from jrbar.answer_local import (
    ACCESSIBILITY_SETTINGS_PATH,
    ANSWER_KEYS,
    ANSWER_REFUSAL_CODES,
    AnswerDeliveryOutcome,
    AnswerHostFacts,
    AnswerRefusal,
    LocalAnswerDelivery,
    LocalAnswerSurface,
    LocalAnswerTarget,
    answer_keys_for_provider,
    plan_local_answer,
)
from jrbar.answer_runtime import _failure_text
from jrbar.provider_contracts import ProductCapability
from jrbar.providers import negotiated_provider_sources


def facts(**overrides) -> AnswerHostFacts:
    base = dict(
        session_pid=4242,
        session_alive=True,
        session_tty="/dev/ttys008",
        expected_bundle_ids=frozenset({"com.mitchellh.ghostty"}),
        frontmost_bundle_id="com.mitchellh.ghostty",
        frontmost_pid=4200,
        frontmost_ancestor_of_session=True,
        focused_tab_tty=None,
        accessibility_trusted=True,
    )
    base.update(overrides)
    return AnswerHostFacts(**base)


def target(**overrides) -> LocalAnswerTarget:
    base = dict(
        provider="claude",
        session_id="claude:session:abc",
        session_pid=4242,
        session_tty="/dev/ttys008",
        expected_bundle_ids=frozenset({"com.mitchellh.ghostty"}),
        is_live=lambda: True,
    )
    base.update(overrides)
    return LocalAnswerTarget(**base)


# --- the measured keys --------------------------------------------------------


def test_the_two_providers_that_can_be_answered_carry_measured_keys():
    assert set(ANSWER_KEYS) == {"claude", "codex"}
    claude = answer_keys_for_provider("claude")
    codex = answer_keys_for_provider("Codex")
    # Claude Code's list always starts with "1. Yes" and advertises
    # "Esc to cancel"; the "No" row's number moves with the tool.
    assert (claude.approve.label, claude.approve.key_code) == ("1", 18)
    assert (claude.deny.label, claude.deny.key_code) == ("esc", 53)
    # Codex numbers its three rows fixed and labels row one "(y)".
    assert (codex.approve.label, codex.approve.key_code) == ("y", 16)
    assert (codex.deny.label, codex.deny.key_code) == ("3", 20)


def test_a_provider_with_no_recipe_has_no_keys():
    assert answer_keys_for_provider("gemini") is None
    assert answer_keys_for_provider(None) is None


# --- the contract gate --------------------------------------------------------


def test_only_codex_and_claude_hooks_declare_answering():
    declared = {
        (source.source_key.provider_id, source.source_key.adapter_id)
        for source in negotiated_provider_sources()
        if source.contract.product_capability(ProductCapability.ANSWERING).supported
    }
    assert declared == {("codex", "hooks"), ("claude", "hooks")}


def test_the_declared_binding_is_the_reviewed_local_surface():
    for source in negotiated_provider_sources():
        declaration = source.contract.product_capability(ProductCapability.ANSWERING)
        if not declaration.supported:
            continue
        invocation = source.contract.product_invocation_for(ProductCapability.ANSWERING)
        assert invocation.local_runtime_surface.value == "local.answer_in_place"
        assert invocation.capability_id is None
        assert invocation.capability_version is None


# --- the decision -------------------------------------------------------------


def test_an_approved_plan_names_the_key_and_the_frontmost_process():
    plan = plan_local_answer(
        provider="codex", decision="approve", ask_live=True, facts=facts()
    )
    assert plan.key.label == "y"
    assert plan.target_pid == 4200
    assert plan.mechanism == "synthetic_keystroke"
    assert plan.facts.window_evidence() == "host_process_ancestry"


def test_deny_is_planned_exactly_like_approve():
    plan = plan_local_answer(
        provider="claude", decision="deny", ask_live=True, facts=facts()
    )
    assert plan.key.label == "esc"
    assert plan.target_pid == 4200


@pytest.mark.parametrize(
    ("label", "overrides", "live", "code", "reason"),
    [
        ("resolved elsewhere", {}, False, "stale_ask", "resolved_elsewhere"),
        ("dead session", {"session_alive": False}, True, "session_gone", "no_live_process"),
        ("no pid", {"session_pid": None}, True, "session_gone", "no_live_process"),
        (
            "nothing frontmost",
            {"frontmost_bundle_id": None},
            True,
            "not_frontmost",
            "no_frontmost_app",
        ),
        (
            "unknown host",
            {"expected_bundle_ids": frozenset()},
            True,
            "not_frontmost",
            "unknown_host",
        ),
        (
            "another app",
            {"frontmost_bundle_id": "com.apple.Terminal"},
            True,
            "not_frontmost",
            "frontmost_is:com.apple.Terminal",
        ),
        (
            "another window",
            {"frontmost_ancestor_of_session": False},
            True,
            "not_frontmost",
            "other_window",
        ),
        (
            "another tab",
            {"focused_tab_tty": "/dev/ttys099"},
            True,
            "not_frontmost",
            "other_tab:/dev/ttys099",
        ),
        (
            "no accessibility",
            {"accessibility_trusted": False},
            True,
            "accessibility_required",
            "ax_not_trusted",
        ),
    ],
)
def test_every_failed_check_refuses_with_its_own_reason(label, overrides, live, code, reason):
    with pytest.raises(AnswerRefusal) as raised:
        plan_local_answer(
            provider="claude", decision="approve", ask_live=live, facts=facts(**overrides)
        )
    assert raised.value.code == code
    assert raised.value.reason == reason
    assert raised.value.code in ANSWER_REFUSAL_CODES


def test_accessibility_refusal_names_the_exact_settings_path():
    with pytest.raises(AnswerRefusal) as raised:
        plan_local_answer(
            provider="claude",
            decision="approve",
            ask_live=True,
            facts=facts(accessibility_trusted=False),
        )
    assert ACCESSIBILITY_SETTINGS_PATH in raised.value.message


def test_a_provider_without_a_recipe_is_unsupported_not_refused_as_a_window():
    with pytest.raises(AnswerRefusal) as raised:
        plan_local_answer(
            provider="gemini", decision="approve", ask_live=True, facts=facts()
        )
    assert raised.value.code == "unsupported"


def test_undeterminable_window_evidence_does_not_refuse():
    # Ghostty exposes neither a scripting tty nor a usable window title; the
    # ancestry walk is what carries the check, and an ancestry that could not
    # be read is "not determined", never "mismatch".
    plan = plan_local_answer(
        provider="claude",
        decision="approve",
        ask_live=True,
        facts=facts(frontmost_ancestor_of_session=None),
    )
    assert plan.facts.window_evidence() == "frontmost_application_only"


def test_a_matching_focused_tab_is_the_strongest_evidence():
    plan = plan_local_answer(
        provider="claude",
        decision="approve",
        ask_live=True,
        facts=facts(focused_tab_tty="/dev/ttys008"),
    )
    assert plan.facts.window_evidence() == "focused_tab_tty"


# --- delivery -----------------------------------------------------------------


def test_delivery_posts_the_key_once_to_the_frontmost_process():
    sent = []
    delivery = LocalAnswerDelivery(
        sender=lambda pid, code: sent.append((pid, code)),
        observer=lambda **kwargs: facts(),
    )
    outcome = delivery.deliver(
        provider="codex",
        decision="approve",
        session_pid=4242,
        expected_bundle_ids=frozenset({"com.mitchellh.ghostty"}),
        session_tty="/dev/ttys008",
        is_live=lambda: True,
    )
    assert outcome.delivered and outcome.code == "sent"
    assert sent == [(4200, 16)]


def test_an_ask_resolved_between_plan_and_post_sends_nothing():
    sent = []
    answers = iter([True, False])
    delivery = LocalAnswerDelivery(
        sender=lambda pid, code: sent.append((pid, code)),
        observer=lambda **kwargs: facts(),
    )
    outcome = delivery.deliver(
        provider="claude",
        decision="deny",
        session_pid=4242,
        expected_bundle_ids=frozenset({"com.mitchellh.ghostty"}),
        session_tty="/dev/ttys008",
        is_live=lambda: next(answers),
    )
    assert sent == []
    assert (outcome.delivered, outcome.code) == (False, "stale_ask")
    assert "resolved_while_sending" in outcome.message


def test_a_delivery_that_overruns_its_budget_sends_nothing():
    sent = []
    ticks = iter([0.0, 99.0, 99.0, 99.0])
    delivery = LocalAnswerDelivery(
        sender=lambda pid, code: sent.append((pid, code)),
        observer=lambda **kwargs: facts(),
        clock=lambda: next(ticks),
    )
    outcome = delivery.deliver(
        provider="claude",
        decision="approve",
        session_pid=4242,
        expected_bundle_ids=frozenset({"com.mitchellh.ghostty"}),
        session_tty="/dev/ttys008",
        is_live=lambda: True,
    )
    assert sent == []
    assert (outcome.delivered, outcome.code) == (False, "stale_ask")
    assert "budget_exceeded" in outcome.message


def test_a_refused_delivery_reports_the_code_and_sends_nothing():
    sent = []
    delivery = LocalAnswerDelivery(
        sender=lambda pid, code: sent.append((pid, code)),
        observer=lambda **kwargs: facts(frontmost_bundle_id="com.apple.Terminal"),
    )
    outcome = delivery.deliver(
        provider="claude",
        decision="approve",
        session_pid=4242,
        expected_bundle_ids=frozenset({"com.mitchellh.ghostty"}),
        session_tty="/dev/ttys008",
        is_live=lambda: True,
    )
    assert sent == []
    assert (outcome.delivered, outcome.code) == (False, "not_frontmost")


# --- the registered handler ---------------------------------------------------


class _Action:
    def __init__(self, value: str) -> None:
        self.value = value


def _surface(**kwargs) -> tuple[LocalAnswerSurface, list]:
    sent: list = []
    delivery = LocalAnswerDelivery(
        sender=lambda pid, code: sent.append((pid, code)),
        observer=lambda **_: facts(),
    )
    surface = LocalAnswerSurface(delivery=delivery, **kwargs)
    return surface, sent


def test_the_handler_answers_and_records_the_outcome():
    surface, sent = _surface(resolve_target=lambda decision: target())
    surface.arm()
    surface.handle(object(), request_kind=None, answer_kind=_Action("approve"), reply_text=None)
    assert sent == [(4200, 18)]
    assert surface.completed.is_set()
    assert surface.last_outcome.delivered


def test_the_handler_raises_the_refusal_the_owner_should_read():
    surface, sent = _surface(
        resolve_target=lambda decision: (_ for _ in ()).throw(
            AnswerRefusal("stale_ask", "That ask is no longer live.", "gone")
        )
    )
    surface.arm()
    with pytest.raises(AnswerRefusal) as raised:
        surface.handle(
            object(), request_kind=None, answer_kind=_Action("deny"), reply_text=None
        )
    assert raised.value.code == "stale_ask"
    assert sent == []
    assert surface.last_outcome.code == "stale_ask"
    assert surface.completed.is_set()


def test_a_typed_reply_is_not_something_this_surface_can_send():
    surface, sent = _surface(resolve_target=lambda decision: target())
    surface.arm()
    with pytest.raises(AnswerRefusal) as raised:
        surface.handle(
            object(), request_kind=None, answer_kind=_Action("reply"), reply_text="hello"
        )
    assert raised.value.code == "unsupported"
    assert sent == []


def test_arming_forgets_the_previous_outcome():
    surface, _ = _surface(resolve_target=lambda decision: target())
    surface.arm()
    surface.handle(object(), request_kind=None, answer_kind=_Action("approve"), reply_text=None)
    assert surface.last_outcome is not None
    surface.arm()
    assert surface.last_outcome is None and not surface.completed.is_set()


def test_the_registry_receives_one_handler_per_invocation():
    registered: list = []

    class _Registry:
        def register(self, invocation, handler):
            registered.append((invocation, handler))

    surface, _ = _surface(resolve_target=lambda decision: target())
    invocations = ("a", "b")
    assert surface.register(_Registry(), invocations) == invocations
    assert [row[0] for row in registered] == ["a", "b"]
    assert all(row[1] == surface.handle for row in registered)


# --- what the panel shows -----------------------------------------------------


def test_a_refusal_reaches_the_panel_as_its_own_sentence():
    refusal = AnswerRefusal("not_frontmost", "The session's terminal is not in front.")
    assert _failure_text(refusal) == "The session's terminal is not in front."
    assert _failure_text(RuntimeError("boom")) == "Send failed: RuntimeError"


def test_an_outcome_document_carries_the_mechanism_and_the_key():
    delivery = LocalAnswerDelivery(sender=lambda pid, code: None, observer=lambda **_: facts())
    outcome = delivery.deliver(
        provider="codex",
        decision="deny",
        session_pid=4242,
        expected_bundle_ids=frozenset({"com.mitchellh.ghostty"}),
        session_tty="/dev/ttys008",
        is_live=lambda: True,
    )
    document = outcome.document()
    assert document["mechanism"] == "synthetic_keystroke"
    assert document["key"] == "3"
    assert document["key_code"] == 20
    assert document["host"]["tty"] == "/dev/ttys008"
    assert document["host"]["app"] == "com.mitchellh.ghostty"
    assert document["host"]["window_evidence"] == "host_process_ancestry"


def test_an_unknown_refusal_code_is_not_expressible():
    with pytest.raises(ValueError):
        AnswerRefusal("made_up", "no")
    assert isinstance(
        AnswerDeliveryOutcome(delivered=False, code="stale_ask", message="x", plan=None),
        AnswerDeliveryOutcome,
    )
