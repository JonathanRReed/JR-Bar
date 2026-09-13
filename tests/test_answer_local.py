"""The local answer surface: which key, and every reason not to send it."""

from __future__ import annotations

import pytest

from jrbar.answer_in_place import MAX_ANSWER_REPLY_LENGTH
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
    _unicode_chunks,
    answer_keys_for_provider,
    plan_local_answer,
    plan_local_reply,
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


# --- typed replies ------------------------------------------------------------


def test_a_reply_plan_targets_the_same_checked_process():
    plan = plan_local_reply(
        provider="claude", reply_text="yes, ship it", ask_live=True, facts=facts()
    )
    assert plan.text == "yes, ship it"
    assert plan.target_pid == 4200
    assert plan.mechanism == "synthetic_text"


def test_reply_text_normalizes_to_one_bounded_printable_line():
    plan = plan_local_reply(
        provider="codex",
        reply_text="  ship\n it\tnow  ",
        ask_live=True,
        facts=facts(),
    )
    assert plan.text == "ship it now"
    assert len(plan.text) <= MAX_ANSWER_REPLY_LENGTH
    with pytest.raises(ValueError):
        plan_local_reply(
            provider="codex", reply_text="  \n\t ", ask_live=True, facts=facts()
        )
    with pytest.raises(ValueError):
        plan_local_reply(
            provider="codex", reply_text=42, ask_live=True, facts=facts()
        )


def test_reply_planning_runs_every_fence_before_text_is_sent():
    with pytest.raises(AnswerRefusal) as raised:
        plan_local_reply(
            provider="claude",
            reply_text="go",
            ask_live=False,
            facts=facts(),
        )
    assert raised.value.code == "stale_ask"
    with pytest.raises(AnswerRefusal) as raised:
        plan_local_reply(
            provider="claude",
            reply_text="go",
            ask_live=True,
            facts=facts(accessibility_trusted=False),
        )
    assert raised.value.code == "accessibility_required"


def test_unicode_chunks_never_exceed_the_event_unit_limit():
    text = "0123456789" * 5 + " \U0001f600 tail"  # one astral char = 2 units
    chunks = list(_unicode_chunks(text))
    assert "".join(chunks) == text
    assert all(
        len(chunk.encode("utf-16-le")) // 2 <= 20 for chunk in chunks
    )
    assert len(chunks) > 1


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


def _surface(**kwargs) -> tuple[LocalAnswerSurface, list, list]:
    sent: list = []
    typed: list = []
    delivery = LocalAnswerDelivery(
        sender=lambda pid, code: sent.append((pid, code)),
        text_sender=lambda pid, text: typed.append((pid, text)),
        observer=lambda **_: facts(),
    )
    surface = LocalAnswerSurface(delivery=delivery, **kwargs)
    return surface, sent, typed


def test_the_handler_answers_and_records_the_outcome():
    surface, sent, _typed = _surface(resolve_target=lambda decision: target())
    surface.arm()
    surface.handle(object(), request_kind=None, answer_kind=_Action("approve"), reply_text=None)
    assert sent == [(4200, 18)]
    assert surface.completed.is_set()
    assert surface.last_outcome.delivered


def test_the_handler_raises_the_refusal_the_owner_should_read():
    surface, sent, _typed = _surface(
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


def test_a_typed_reply_is_typed_into_the_same_checked_target():
    surface, sent, typed = _surface(resolve_target=lambda decision: target())
    surface.arm()
    surface.handle(
        object(),
        request_kind=None,
        answer_kind=_Action("reply"),
        reply_text="yes, ship it",
    )
    # The text rides the unicode payload of one synthetic keyboard event
    # chain to the frontmost pid; no provider key recipe fires for it.
    assert typed == [(4200, "yes, ship it")]
    assert sent == []
    assert surface.completed.is_set()
    assert surface.last_outcome.delivered
    assert surface.last_outcome.plan.mechanism == "synthetic_text"


def test_a_reply_that_fails_the_same_fences_sends_nothing():
    sent: list = []
    typed: list = []
    delivery = LocalAnswerDelivery(
        sender=lambda pid, code: sent.append((pid, code)),
        text_sender=lambda pid, text: typed.append((pid, text)),
        observer=lambda **kwargs: facts(frontmost_bundle_id="com.apple.Terminal"),
    )
    outcome = delivery.deliver(
        provider="claude",
        reply_text="go ahead",
        session_pid=4242,
        expected_bundle_ids=frozenset({"com.mitchellh.ghostty"}),
        session_tty="/dev/ttys008",
        is_live=lambda: True,
    )
    assert (outcome.delivered, outcome.code) == (False, "not_frontmost")
    assert typed == [] and sent == []


def test_an_empty_reply_is_refused_before_any_delivery():
    surface, sent, typed = _surface(resolve_target=lambda decision: target())
    surface.arm()
    with pytest.raises(AnswerRefusal) as raised:
        surface.handle(
            object(), request_kind=None, answer_kind=_Action("reply"), reply_text="   "
        )
    assert raised.value.code == "unsupported"
    assert raised.value.reason == "invalid_reply_text"
    assert sent == [] and typed == []


def test_reply_text_on_a_decision_action_is_rejected():
    surface, sent, typed = _surface(resolve_target=lambda decision: target())
    surface.arm()
    with pytest.raises(AnswerRefusal) as raised:
        surface.handle(
            object(),
            request_kind=None,
            answer_kind=_Action("approve"),
            reply_text="yes",
        )
    assert raised.value.reason == "reply_text_on_decision"
    assert sent == [] and typed == []


def test_arming_forgets_the_previous_outcome():
    surface, _sent, _typed = _surface(resolve_target=lambda decision: target())
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

    surface, _sent, _typed = _surface(resolve_target=lambda decision: target())
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


# --- resolving the host -------------------------------------------------------


class _Entry:
    def __init__(self, ppid: int, command: str) -> None:
        self.ppid = ppid
        self.command = command


def test_the_host_walk_starts_at_the_parent_not_the_cli_itself(monkeypatch):
    # The CLI's own executable is named after its provider, and
    # terminal_from_command reads "claude" as the Claude DESKTOP app. Walking
    # from the session itself would therefore decide every Claude Code session
    # is hosted by Claude.app and refuse the terminal that really owns it.
    import jrbar.answer_local as module

    table = {
        900: _Entry(800, "/Users/x/.local/bin/claude"),
        800: _Entry(700, "/bin/zsh"),
        700: _Entry(1, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
    }
    monkeypatch.setattr("jrbar.process_registry.list_processes", lambda: table)
    monkeypatch.setattr("jrbar.process_registry.load_record", lambda p, s: None)
    monkeypatch.setattr(module, "process_alive", lambda pid: True)
    monkeypatch.setattr(module, "tty_for_pid", lambda pid: "/dev/ttys008")

    class _Record:
        pid = 900
        ended_at_epoch = None
        cwd = None

    monkeypatch.setattr("jrbar.process_registry.load_record", lambda p, s: _Record())
    host = module.session_host("claude", "session-1")
    assert host.pid == 900
    assert host.bundle_ids == frozenset({"com.mitchellh.ghostty"})
    assert host.app_name == "Ghostty"


def test_the_accessibility_row_named_is_the_process_that_posts_the_key():
    from jrbar.answer_local import accessibility_refusal_message

    # On an installed deployment the daemon is the jrbar-core helper, not
    # JR-Bar.app, and that is the row System Settings shows.
    assert "Accessibility > jrbar-core." in accessibility_refusal_message("jrbar-core")
    assert "Accessibility > JR-Bar." in accessibility_refusal_message(None)
    with pytest.raises(AnswerRefusal) as raised:
        plan_local_answer(
            provider="codex",
            decision="approve",
            ask_live=True,
            facts=facts(accessibility_trusted=False, accessibility_app_name="jrbar-core"),
        )
    assert "jrbar-core" in raised.value.message
