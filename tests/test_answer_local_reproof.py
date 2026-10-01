"""The window proof is taken again right before the key goes out.

``LocalAnswerDelivery.deliver`` used to observe the frontmost application, the
focused tab's tty and Ghostty's focused surface once, at its start, and only
re-asked ``is_live`` before posting. The delivery budget allows about four
seconds between that proof and the post, so the owner could switch tabs in
between and a binary key (or a typed reply) landed in the wrong terminal. The
whole proof now runs again immediately before the post, on the same rules: an
answer that is not affirmatively proven refuses, and unknown refuses.

Everything here uses fakes. No event is ever posted.
"""

from __future__ import annotations

from dataclasses import replace

import pytest

from jrbar.answer_local import AnswerHostFacts, LocalAnswerDelivery
from tests.test_answer_local import facts

TERMINAL = frozenset({"com.apple.Terminal"})
GHOSTTY = frozenset({"com.mitchellh.ghostty"})


class _Scene:
    """A fake Mac the delivery observes: a script of facts, one per look, and a
    log of every call the delivery makes, in order."""

    def __init__(self, *looks: AnswerHostFacts, live: list[bool] | None = None, tick: float = 0.0) -> None:
        self.looks = list(looks)
        self.live = list(live) if live is not None else [True, True]
        self.log: list[str] = []
        self.sent: list[tuple[int, int]] = []
        self.typed: list[tuple[int, str]] = []
        self.now = 0.0
        self.tick = tick
        self.observer_cost = 0.0

    def observer(self, **kwargs: object) -> AnswerHostFacts:
        self.log.append("observe")
        self.now += self.observer_cost
        index = min(self.log.count("observe") - 1, len(self.looks) - 1)
        return self.looks[index]

    def is_live(self) -> bool:
        self.log.append("live")
        return self.live.pop(0) if self.live else True

    def delivery(self) -> LocalAnswerDelivery:
        def send(pid: int, code: int) -> None:
            self.log.append("send")
            self.sent.append((pid, code))

        def type_text(pid: int, text: str) -> None:
            self.log.append("type")
            self.typed.append((pid, text))

        return LocalAnswerDelivery(
            sender=send, text_sender=type_text, observer=self.observer, clock=lambda: self.now
        )

    def answer(self, *, reply: str | None = None, expected: frozenset[str] = TERMINAL):
        kwargs: dict[str, object] = {"reply_text": reply} if reply is not None else {"decision": "approve"}
        return self.delivery().deliver(
            provider="claude",
            session_pid=4242,
            expected_bundle_ids=expected,
            session_tty="/dev/ttys008",
            is_live=self.is_live,
            agent_id="claude:session:abc",
            **kwargs,
        )


def test_the_proof_is_taken_twice_and_the_second_is_the_last_thing_before_the_post() -> None:
    scene = _Scene(facts(), facts())
    outcome = scene.answer()
    assert (outcome.delivered, outcome.code) == (True, "sent")
    # observe, ask is_live while planning, observe again, the last is_live, post.
    assert scene.log == ["observe", "live", "observe", "live", "send"]
    assert scene.sent == [(4200, 18)]


def test_a_tab_switched_during_the_delivery_refuses_and_sends_nothing() -> None:
    scene = _Scene(facts(), facts(focused_tab_tty="/dev/ttys009"))
    outcome = scene.answer()
    assert (outcome.delivered, outcome.code) == (False, "not_frontmost")
    assert "other_tab:/dev/ttys009" in outcome.message
    assert scene.sent == [] and scene.typed == []


@pytest.mark.parametrize(
    ("second", "code", "reason"),
    [
        (facts(frontmost_bundle_id="com.apple.TextEdit"), "not_frontmost", "frontmost_is:com.apple.TextEdit"),
        (facts(frontmost_bundle_id=None, frontmost_pid=None), "not_frontmost", "no_frontmost_app"),
        (facts(frontmost_ancestor_of_session=False), "not_frontmost", "other_window"),
        (facts(frontmost_ancestor_of_session=None), "not_frontmost", "ownership_unproven"),
        (facts(focused_tab_tty=None), "not_frontmost", "focused_tab_unproven"),
        (facts(session_tty=None), "not_frontmost", "session_tty_unknown"),
        (facts(accessibility_trusted=False), "accessibility_required", "ax_not_trusted"),
        (facts(session_alive=False), "session_gone", "no_live_process"),
        (facts(session_alive=None), "session_gone", "liveness_unproven"),
        (facts(session_stopped=True), "session_gone", "process_stopped"),
    ],
)
def test_anything_the_second_look_cannot_prove_refuses_with_the_same_codes(
    second: AnswerHostFacts, code: str, reason: str
) -> None:
    scene = _Scene(facts(), second)
    outcome = scene.answer()
    assert (outcome.delivered, outcome.code) == (False, code)
    assert reason in outcome.message
    assert scene.sent == []


def test_a_typed_reply_is_fenced_by_the_second_look_too() -> None:
    scene = _Scene(facts(), facts(focused_tab_tty="/dev/ttys009"))
    outcome = scene.answer(reply="yes, ship it")
    assert (outcome.delivered, outcome.code) == (False, "not_frontmost")
    assert scene.typed == [] and scene.sent == []

    scene = _Scene(facts(), facts())
    outcome = scene.answer(reply="yes, ship it")
    assert outcome.delivered and scene.typed == [(4200, "yes, ship it")]


def test_a_different_ghostty_surface_on_the_second_look_refuses() -> None:
    proven = facts(
        expected_bundle_ids=GHOSTTY,
        frontmost_bundle_id="com.mitchellh.ghostty",
        focused_tab_tty=None,
        focused_surface_proven=True,
    )
    scene = _Scene(proven, replace(proven, focused_surface_proven=False))
    outcome = scene.answer(expected=GHOSTTY)
    assert (outcome.delivered, outcome.code) == (False, "not_frontmost")
    assert "other_surface" in outcome.message
    assert scene.sent == []

    scene = _Scene(proven, replace(proven, focused_surface_proven=None))
    assert scene.answer(expected=GHOSTTY).delivered is False

    scene = _Scene(proven, proven)
    assert scene.answer(expected=GHOSTTY).delivered is True


def test_a_host_that_moved_to_another_process_between_the_looks_refuses() -> None:
    """The key goes to the pid that was proven. A second look that names a
    different frontmost process is not the window the first one proved."""
    scene = _Scene(facts(), facts(frontmost_pid=4300))
    outcome = scene.answer()
    assert (outcome.delivered, outcome.code) == (False, "not_frontmost")
    assert "changed_while_sending" in outcome.message
    assert scene.sent == []


def test_the_key_goes_to_the_process_the_second_look_proved_and_names_its_evidence() -> None:
    scene = _Scene(facts(), facts(accessibility_app_name="JR-Bar"))
    outcome = scene.answer()
    assert outcome.delivered
    assert outcome.plan.facts.accessibility_app_name == "JR-Bar"
    assert scene.sent == [(4200, 18)]


def test_an_ask_resolved_after_the_second_look_still_sends_nothing() -> None:
    scene = _Scene(facts(), facts(), live=[True, False])
    outcome = scene.answer()
    assert (outcome.delivered, outcome.code) == (False, "stale_ask")
    assert "resolved_while_sending" in outcome.message
    assert scene.log == ["observe", "live", "observe", "live"]


def test_a_slow_second_look_runs_into_the_delivery_budget() -> None:
    """The budget still runs from the start of the delivery to the post: a
    proof that took seconds to take again is not fresh enough to send on."""
    scene = _Scene(facts(), facts())
    scene.observer_cost = 3.0
    outcome = scene.answer()
    assert (outcome.delivered, outcome.code) == (False, "stale_ask")
    assert "budget_exceeded" in outcome.message
    assert scene.sent == []


def test_a_second_look_that_raises_sends_nothing() -> None:
    sent: list[tuple[int, int]] = []
    looks = iter([facts()])

    def observer(**kwargs: object) -> AnswerHostFacts:
        return next(looks)  # the second look finds nothing to return

    delivery = LocalAnswerDelivery(sender=lambda pid, code: sent.append((pid, code)), observer=observer)
    with pytest.raises(StopIteration):
        delivery.deliver(
            provider="claude",
            decision="approve",
            session_pid=4242,
            expected_bundle_ids=TERMINAL,
            session_tty="/dev/ttys008",
            is_live=lambda: True,
        )
    assert sent == []
