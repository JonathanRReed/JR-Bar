"""``answer_ask`` after a refused send: the next press is a fresh verdict.

The command runs the real answer controller, the real runtime worker and the
real ``LocalAnswerSurface``. Only the delivery underneath is scripted, so the
first press refuses the way a terminal that is behind another window does and
the second one gets through. Synthetic sessions only.
"""

from __future__ import annotations

from threading import Event
from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar.announcer_stack import announcer_alert_identity
from jrbar.answer_controller import AnswerController
from jrbar.answer_in_place import AnswerAttemptState
from jrbar.answer_local import (
    AnswerDeliveryOutcome,
    AnswerRefusal,
    LocalAnswerSurface,
    LocalAnswerTarget,
)
from jrbar.capacity_types import SourceKey
from jrbar.command_journal import CommandJournal
from jrbar.core_server import CommandError
from jrbar.models import AgentMode, AgentStatus
from jrbar.operator_state import (
    BootIdentifier,
    ClockSample,
    empty_operator_state,
    reduce_operator_state,
)
from jrbar.provider_contracts import (
    AdapterIdentifier,
    ContractStatus,
    LocalRuntimeSurfaceIdentifier,
    NegotiatedProviderContract,
    ProductCapability,
    ProductCapabilityBinding,
    ProductCapabilityDeclaration,
    ProviderIdentifier,
    SchemaVersion,
    SourceInstanceIdentifier,
)
from jrbar.provider_facts import (
    EventToken,
    NextActor,
    ObservationAuthority,
    ProviderFactBatch,
    ProviderRequestFact,
    ProviderRequestState,
    ProviderWatermark,
    ProviderWorkFact,
    RequestIdentifier,
    RequestKey,
    RequestKind,
    SourceFreshness,
    SourceHealth,
    WatermarkBasis,
    WorkIdentifier,
    WorkKey,
    WorkLifecycle,
)


def _live_permission_ask():
    source = SourceKey("codex", "hooks", "local:retry", "live_agent_events")
    work_key = WorkKey(source, WorkIdentifier("work:retry"))
    request_key = RequestKey(work_key, RequestIdentifier("request:retry"))
    watermark = ProviderWatermark(
        source,
        WatermarkBasis.PROVIDER_EVENT_ID,
        1_800_000_000.0,
        EventToken("event:retry"),
        None,
        10,
    )
    batch = ProviderFactBatch(
        source_key=source,
        observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
        source_health=SourceHealth.HEALTHY,
        source_freshness=SourceFreshness.FRESH,
        observed_at_epoch=1_800_000_000.0,
        watermark=watermark,
        work_facts=(
            ProviderWorkFact(
                key=work_key,
                lifecycle=WorkLifecycle.WAITING,
                watermark=watermark,
                safe_label="Codex work:retry",
                parent_key=None,
                next_actor=NextActor.USER,
            ),
        ),
        request_facts=(
            ProviderRequestFact(
                key=request_key,
                state=ProviderRequestState.LIVE,
                request_kind=RequestKind.PERMISSION,
                next_actor=NextActor.USER,
                watermark=watermark,
            ),
        ),
        diagnostics=(),
    )
    state = reduce_operator_state(
        empty_operator_state(),
        batch,
        clock=ClockSample(1_800_000_000.0, 100.0, BootIdentifier("boot:retry")),
    ).state
    status = AgentStatus(
        provider="codex",
        agent_id="codex:session:work:retry",
        display_name="Codex work:retry",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=None,
        event_name="PermissionRequest",
        session_id="work:retry",
        work_key=work_key,
        request_key=request_key,
    )
    return source, state, status, request_key


def _contract(source: SourceKey) -> NegotiatedProviderContract:
    return NegotiatedProviderContract(
        schema_version=SchemaVersion(1, 0),
        provider_id=ProviderIdentifier(source.provider_id),
        adapter_id=AdapterIdentifier(source.adapter_id),
        source_instance_id=SourceInstanceIdentifier(source.source_instance_id),
        status=ContractStatus.SUPPORTED,
        product_capabilities=(
            ProductCapabilityDeclaration(
                ProductCapability.ANSWERING,
                supported=True,
                binding=ProductCapabilityBinding.local(
                    LocalRuntimeSurfaceIdentifier("local.answer_in_place")
                ),
            ),
        ),
    )


class _RefusesOnceDelivery:
    """The terminal is behind another window on the first press only."""

    def __init__(self, refusals: int = 1) -> None:
        self.refusals = refusals
        self.decisions: list[str] = []

    def deliver(self, *, decision: str, **_facts) -> AnswerDeliveryOutcome:
        self.decisions.append(decision)
        if len(self.decisions) <= self.refusals:
            raise AnswerRefusal(
                "not_frontmost",
                "The session's terminal is not in front.",
                "frontmost_is:com.example.other",
            )
        return AnswerDeliveryOutcome(
            delivered=True,
            code="sent",
            message="ok",
            plan=None,
        )


class _Command:
    """The pieces ``_cmd_answer_ask`` reads, around a real controller."""

    def __init__(self, delivery: _RefusesOnceDelivery) -> None:
        source, state, status, request_key = _live_permission_ask()
        self.status = status
        self.request_key = request_key
        self.delivery = delivery
        self.changed = Event()
        self.answer_controller = AnswerController(
            contracts_by_source={source: _contract(source)},
            dispatch_main=self._dispatch_main,
            on_refresh=lambda _presentation: None,
            open_route=lambda _route: None,
        )
        target = LocalAnswerTarget(
            provider="codex",
            session_id=status.agent_id,
            session_pid=None,
            session_tty=None,
            expected_bundle_ids=frozenset({"com.example.terminal"}),
            is_live=lambda: True,
        )
        self.surface = LocalAnswerSurface(
            resolve_target=lambda _decision: target,
            delivery=delivery,
        )
        invocation = _contract(source).product_invocation_for(
            ProductCapability.ANSWERING
        )
        self.surface.register(self.answer_controller.handler_registry, [invocation])
        self.stub = SimpleNamespace(
            last_snapshot=SimpleNamespace(statuses=(status,), stale_statuses=()),
            current_operator_state=state,
            local_answer_surface=self.surface,
            answer_controller=self.answer_controller,
            refresh_=lambda *_: None,
            _jrbar_command_journal=CommandJournal(),
        )

    def _dispatch_main(self, callback) -> None:
        callback()
        self.changed.set()

    def press(self, decision: str = "approve") -> dict:
        # only_if_frontmost stays true: the terminal is never raised from here.
        return core_runtime._cmd_answer_ask(
            self.stub,
            {
                "session": self.status.agent_id,
                "decision": decision,
                "only_if_frontmost": True,
                "request": str(announcer_alert_identity(self.request_key).value),
            },
        )

    def await_state(self, state: AnswerAttemptState) -> None:
        # The state lands before the change event is set, so a signal cleared
        # between the check and the wait is never the only evidence.
        key = self.answer_controller.attempt_key
        assert key is not None
        for _ in range(20):
            attempt = self.answer_controller.runtime.snapshot(
                key.request_identity, key.generation
            )
            if attempt is not None and attempt.state is state:
                return
            self.changed.wait(0.5)
            self.changed.clear()
        raise AssertionError(f"attempt never reached {state}")

    def close(self) -> None:
        self.answer_controller.runtime.close(timeout_seconds=1.0)


def test_an_answer_refused_as_not_frontmost_is_answered_by_the_next_press__and_2_more() -> None:
    # --- scenario: the_second_press_answers_instead_of_saying_it_cannot_be_answered
    command = _Command(_RefusesOnceDelivery())
    try:
        with pytest.raises(CommandError) as refused:
            command.press()
        assert refused.value.code == "not_frontmost"
        assert command.delivery.decisions == ["approve"]
        command.await_state(AnswerAttemptState.FAILED)

        reply = command.press()

        assert reply["answered"] is True
        assert reply["delivered"] is True
        assert reply["code"] == "sent"
        assert command.delivery.decisions == ["approve", "approve"]
        command.await_state(AnswerAttemptState.SENT)
    finally:
        command.close()

    # --- scenario: an_answer_the_agent_already_has_is_never_typed_twice
    command = _Command(_RefusesOnceDelivery())
    try:
        with pytest.raises(CommandError):
            command.press()
        command.await_state(AnswerAttemptState.FAILED)
        command.press()
        command.await_state(AnswerAttemptState.SENT)

        with pytest.raises(CommandError) as again:
            command.press()

        assert again.value.code == "unsupported"
        assert command.delivery.decisions == ["approve", "approve"]
    finally:
        command.close()

    # --- scenario: a_deny_after_a_refused_approve_sends_a_deny
    command = _Command(_RefusesOnceDelivery())
    try:
        with pytest.raises(CommandError):
            command.press("approve")
        command.await_state(AnswerAttemptState.FAILED)

        reply = command.press("deny")

        assert reply["decision"] == "deny"
        assert command.delivery.decisions == ["approve", "deny"]
        command.await_state(AnswerAttemptState.SENT)
    finally:
        command.close()


def test_every_refusal_in_a_row_keeps_the_next_press_open() -> None:
    command = _Command(_RefusesOnceDelivery(refusals=3))
    try:
        for expected_presses in (1, 2, 3):
            with pytest.raises(CommandError) as refused:
                command.press()
            assert refused.value.code == "not_frontmost"
            assert len(command.delivery.decisions) == expected_presses
            command.await_state(AnswerAttemptState.FAILED)

        reply = command.press()

        assert reply["answered"] is True
        assert len(command.delivery.decisions) == 4
        command.await_state(AnswerAttemptState.SENT)
    finally:
        command.close()
