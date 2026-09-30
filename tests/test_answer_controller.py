from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from threading import Event

from jrbar.announcer_stack import (
    AnnouncerStackAction,
    AnnouncerStackIntent,
    announcer_alert_identity,
    empty_announcer_stack_state,
    project_announcer_stack,
    reconcile_announcer_stack,
)
from jrbar.answer_controller import AnswerBrowserCommand, AnswerController
from jrbar.answer_in_place import AnswerActionKind, AnswerAttemptState
from jrbar.answer_runtime import AnswerRuntime
from jrbar.attention import LifecycleMode, ProjectedAgentRow
from jrbar.capacity_types import SourceKey
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

NOW = datetime(2026, 8, 30, tzinfo=timezone.utc)


def _truth(request_kind: RequestKind = RequestKind.PERMISSION):
    source = SourceKey("codex", "hook", "source:main", "agent")
    work = WorkKey(source, WorkIdentifier("work:one"))
    request = RequestKey(work, RequestIdentifier("request:one"))
    watermark = ProviderWatermark(
        source,
        WatermarkBasis.PROVIDER_EVENT_ID,
        1_800_000_000,
        EventToken("event:one"),
        None,
        0,
    )
    batch = ProviderFactBatch(
        source_key=source,
        observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
        source_health=SourceHealth.HEALTHY,
        source_freshness=SourceFreshness.FRESH,
        observed_at_epoch=1_800_000_000,
        watermark=watermark,
        work_facts=(
            ProviderWorkFact(
                key=work,
                lifecycle=WorkLifecycle.WAITING,
                watermark=watermark,
                safe_label="Codex work:one",
                parent_key=None,
                next_actor=NextActor.USER,
            ),
        ),
        request_facts=(
            ProviderRequestFact(
                key=request,
                state=ProviderRequestState.LIVE,
                request_kind=request_kind,
                next_actor=NextActor.USER,
                watermark=watermark,
            ),
        ),
        diagnostics=(),
    )
    state = reduce_operator_state(
        empty_operator_state(),
        batch,
        clock=ClockSample(1_800_000_000, 1, BootIdentifier("boot:one")),
    ).state
    status = AgentStatus(
        provider="codex",
        agent_id="codex:session:one",
        display_name="Codex one",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=NOW,
        event_name="PermissionRequest",
        session_id="one",
        tool_name=None,
        message="Approve access?",
        work_key=work,
        request_key=request,
    )
    row = ProjectedAgentRow(
        agent_id=status.agent_id,
        provider=status.provider,
        display_name=status.display_name,
        lifecycle_mode=LifecycleMode.WAITING,
        actionable=True,
        is_subagent=False,
        updated_at=status.updated_at,
        source_status=status,
        work_key=work,
        request_key=request,
    )
    return source, work, request, state, status, row


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


def test_answer_controller_module_is_appkit_free__and_2_more() -> None:
    # --- scenario: answer_controller_module_is_appkit_free
    source = (
        Path(__file__).parents[1] / "src" / "jrbar" / "answer_controller.py"
    ).read_text(encoding="utf-8")

    assert "AppKit" not in source
    assert "import objc" not in source
    assert "agent_browser_window" not in source

    # --- scenario: controller_projects_exact_capability_and_dispatches_exact_handler
    source, _work, _request, operator_state, status, row = _truth()
    refreshes = []
    opened = []
    called = Event()
    received = []
    controller = AnswerController(
        contracts_by_source={source: _contract(source)},
        dispatch_main=lambda callback: callback(),
        on_refresh=refreshes.append,
        open_route=opened.append,
    )
    invocation = _contract(source).product_invocation_for(ProductCapability.ANSWERING)

    def handler(invocation, *, request_kind, answer_kind, reply_text) -> None:
        received.append((invocation, request_kind, answer_kind, reply_text))
        called.set()

    controller.handler_registry.register(invocation, handler)
    stack_state = reconcile_announcer_stack(
        empty_announcer_stack_state(), operator_state, (row,), (status,)
    )
    plan = project_announcer_stack(stack_state, operator_state, (row,), (status,))

    presentation = controller.present(
        stack_state,
        plan,
        operator_state,
        (row,),
        (status,),
    )
    identity = announcer_alert_identity(_request)
    assert presentation.plan.can_open is True
    assert presentation.answer_plan is not None
    assert presentation.answer_plan.capability.invocation == invocation

    controller.handle_answer_intent(
        AnswerActionKind.APPROVE,
        plan.generation,
        identity,
        None,
    )

    assert called.wait(1.0)
    assert received == [
        (invocation, RequestKind.PERMISSION, AnswerActionKind.APPROVE, None)
    ]
    assert refreshes
    assert opened == []
    controller.runtime.close(timeout_seconds=1.0)

    # --- scenario: stack_and_browser_jump_return_or_open_only_the_exact_route
    source, work, request, operator_state, status, row = _truth()
    opened = []
    controller = AnswerController(
        contracts_by_source={source: _contract(source)},
        dispatch_main=lambda callback: callback(),
        on_refresh=lambda _presentation: None,
        open_route=opened.append,
    )
    stack_state = reconcile_announcer_stack(
        empty_announcer_stack_state(), operator_state, (row,), (status,)
    )
    plan = project_announcer_stack(stack_state, operator_state, (row,), (status,))
    controller.present(stack_state, plan, operator_state, (row,), (status,))
    identity = announcer_alert_identity(request)

    update = controller.handle_stack_intent(
        AnnouncerStackIntent(AnnouncerStackAction.OPEN, plan.generation, identity)
    )

    assert update is not None
    assert update.open_route is status
    assert opened == []
    assert controller.perform_browser_answer(
        AnswerBrowserCommand(
            work_key=work,
            generation=operator_state.generation,
            request_identity=identity,
            action=AnswerActionKind.JUMP,
            reply_text=None,
        ),
        operator_state,
        (status,),
    ) is True
    assert opened == [status]
    controller.runtime.close(timeout_seconds=1.0)



def test_request_attempt_survives_ui_generation_changes_across_surfaces() -> None:
    source, work, request, operator_state, status, row = _truth()
    started = Event()
    release = Event()
    controller = AnswerController(
        contracts_by_source={source: _contract(source)},
        dispatch_main=lambda callback: callback(),
        on_refresh=lambda _presentation: None,
        open_route=lambda _route: None,
    )
    invocation = _contract(source).product_invocation_for(ProductCapability.ANSWERING)

    def handler(*_args, **_kwargs) -> None:
        started.set()
        release.wait(1.0)

    controller.handler_registry.register(invocation, handler)
    first_state = reconcile_announcer_stack(
        empty_announcer_stack_state(), operator_state, (row,), (status,)
    )
    first_plan = project_announcer_stack(
        first_state, operator_state, (row,), (status,)
    )
    first = controller.present(
        first_state, first_plan, operator_state, (row,), (status,)
    )
    identity = announcer_alert_identity(request)
    controller.handle_answer_intent(
        AnswerActionKind.APPROVE,
        first.plan.generation,
        identity,
        None,
    )
    assert started.wait(1.0)
    attempt_key = controller.attempt_key

    second_state = reconcile_announcer_stack(
        first_state, operator_state, (row,), (status,)
    )
    second_plan = project_announcer_stack(
        second_state, operator_state, (row,), (status,)
    )
    second = controller.present(
        second_state, second_plan, operator_state, (row,), (status,)
    )

    assert second.plan.generation != first.plan.generation
    assert second.answer_plan is not None
    assert second.answer_plan.generation == second.plan.generation
    assert second.answer_plan.state is AnswerAttemptState.SENDING
    assert controller.attempt_key == attempt_key
    controller.handle_answer_intent(
        AnswerActionKind.CANCEL,
        first.plan.generation,
        identity,
        None,
    )
    assert controller.runtime.snapshot(
        attempt_key.request_identity,
        attempt_key.generation,
    ).state is AnswerAttemptState.SENDING

    assert controller.perform_browser_answer(
        AnswerBrowserCommand(
            work_key=work,
            generation=operator_state.generation,
            request_identity=identity,
            action=AnswerActionKind.CANCEL,
            reply_text=None,
        ),
        operator_state,
        (status,),
    ) is True
    assert controller.runtime.snapshot(
        attempt_key.request_identity,
        attempt_key.generation,
    ).state is AnswerAttemptState.CANCELLED

    release.set()
    controller.runtime.close(timeout_seconds=1.0)


class _Refused(Exception):
    """A handler refusal that already knows the sentence to show."""

    answer_status_text = "Its terminal tab has to be in front."


class _Fixture:
    """A real controller on a real worker, with a handler the test scripts."""

    def __init__(self, handler, request_kind: RequestKind = RequestKind.PERMISSION) -> None:
        source, work, request, operator_state, status, row = _truth(request_kind)
        self.work = work
        self.operator_state = operator_state
        self.status = status
        self.row = row
        self.identity = announcer_alert_identity(request)
        self.changed = Event()
        self.refreshes: list[object] = []
        self.controller = AnswerController(
            contracts_by_source={source: _contract(source)},
            dispatch_main=self._dispatch_main,
            on_refresh=self.refreshes.append,
            open_route=lambda _route: None,
        )
        invocation = _contract(source).product_invocation_for(
            ProductCapability.ANSWERING
        )
        self.controller.handler_registry.register(invocation, handler)
        self.stack_state = empty_announcer_stack_state()
        self.plan = None

    def _dispatch_main(self, callback) -> None:
        callback()
        self.changed.set()

    def present(self):
        self.stack_state = reconcile_announcer_stack(
            self.stack_state, self.operator_state, (self.row,), (self.status,)
        )
        self.plan = project_announcer_stack(
            self.stack_state, self.operator_state, (self.row,), (self.status,)
        )
        return self.controller.present(
            self.stack_state,
            self.plan,
            self.operator_state,
            (self.row,),
            (self.status,),
        )

    def answer(self, action: AnswerActionKind, reply_text: str | None = None) -> bool:
        return self.controller.perform_browser_answer(
            AnswerBrowserCommand(
                work_key=self.work,
                generation=self.operator_state.generation,
                request_identity=self.identity,
                action=action,
                reply_text=reply_text,
            ),
            self.operator_state,
            (self.status,),
        )

    def attempt(self):
        key = self.controller.attempt_key
        assert key is not None
        return self.controller.runtime.snapshot(key.request_identity, key.generation)

    def await_state(self, state: AnswerAttemptState):
        # The state lands before the change event is set, so a signal cleared
        # between the check and the wait is never the only evidence.
        for _ in range(20):
            attempt = self.attempt()
            if attempt is not None and attempt.state is state:
                return attempt
            self.changed.wait(0.5)
            self.changed.clear()
        raise AssertionError(f"attempt never reached {state}: {self.attempt()}")

    def close(self) -> None:
        self.controller.runtime.close(timeout_seconds=1.0)


def test_a_refused_send_does_not_block_the_next_verdict__and_4_more() -> None:
    # --- scenario: a_refused_approve_is_followed_by_a_deny_that_reaches_the_handler
    calls: list[AnswerActionKind] = []

    def handler(_invocation, *, request_kind, answer_kind, reply_text) -> None:
        calls.append(answer_kind)
        if len(calls) == 1:
            raise _Refused()

    fixture = _Fixture(handler)
    fixture.present()

    assert fixture.answer(AnswerActionKind.APPROVE) is True
    failed = fixture.await_state(AnswerAttemptState.FAILED)
    assert failed.last_error == "Its terminal tab has to be in front."

    # The new press carries its own verb. Nothing replays the stored approve.
    assert fixture.answer(AnswerActionKind.DENY) is True
    fixture.await_state(AnswerAttemptState.SENT)
    assert calls == [AnswerActionKind.APPROVE, AnswerActionKind.DENY]

    # A send the agent already has stays sent: no second key into the terminal.
    assert fixture.answer(AnswerActionKind.APPROVE) is False
    assert fixture.answer(AnswerActionKind.DENY) is False
    assert calls == [AnswerActionKind.APPROVE, AnswerActionKind.DENY]
    fixture.close()

    # --- scenario: a_send_in_flight_still_refuses_a_second_verdict
    started = Event()
    release = Event()
    blocked_calls: list[AnswerActionKind] = []

    def blocked_handler(_invocation, *, request_kind, answer_kind, reply_text) -> None:
        blocked_calls.append(answer_kind)
        started.set()
        release.wait(5.0)

    fixture = _Fixture(blocked_handler)
    fixture.present()
    try:
        assert fixture.answer(AnswerActionKind.APPROVE) is True
        assert started.wait(2.0)
        assert fixture.attempt().state is AnswerAttemptState.SENDING

        assert fixture.answer(AnswerActionKind.DENY) is False
        assert blocked_calls == [AnswerActionKind.APPROVE]
    finally:
        release.set()
    fixture.await_state(AnswerAttemptState.SENT)
    fixture.close()

    # --- scenario: a_failed_send_is_never_retried_by_a_refresh
    calls = []

    def refusing_handler(_invocation, *, request_kind, answer_kind, reply_text) -> None:
        calls.append(answer_kind)
        raise _Refused()

    fixture = _Fixture(refusing_handler)
    fixture.present()
    assert fixture.answer(AnswerActionKind.APPROVE) is True
    fixture.await_state(AnswerAttemptState.FAILED)

    fixture.present()
    fixture.controller._emit_current()
    fixture.present()

    assert calls == [AnswerActionKind.APPROVE]
    assert fixture.attempt().state is AnswerAttemptState.FAILED
    assert fixture.controller.runtime.has_active_work() is False
    fixture.close()

    # --- scenario: the_projected_controls_keep_failed_as_retry_and_jump
    calls = []

    def flaky_handler(_invocation, *, request_kind, answer_kind, reply_text) -> None:
        calls.append(answer_kind)
        if len(calls) == 1:
            raise _Refused()

    fixture = _Fixture(flaky_handler)
    presentation = fixture.present()
    assert fixture.answer(AnswerActionKind.APPROVE) is True
    fixture.await_state(AnswerAttemptState.FAILED)
    generation = fixture.plan.generation

    # Approve from a projected-control surface is still refused: it offers Retry.
    fixture.controller.handle_answer_intent(
        AnswerActionKind.APPROVE, generation, fixture.identity, None
    )
    assert fixture.attempt().state is AnswerAttemptState.FAILED
    assert fixture.controller.runtime.has_active_work() is False
    assert calls == [AnswerActionKind.APPROVE]

    # Retry replays the stored verdict, exactly as before.
    fixture.controller.handle_answer_intent(
        AnswerActionKind.RETRY, generation, fixture.identity, None
    )
    fixture.await_state(AnswerAttemptState.SENT)
    assert calls == [AnswerActionKind.APPROVE, AnswerActionKind.APPROVE]
    fixture.close()
    assert presentation.answer_plan is not None

    # --- scenario: a_reply_to_a_permission_ask_keeps_the_failure_text
    calls = []

    def permission_handler(_invocation, *, request_kind, answer_kind, reply_text) -> None:
        calls.append(answer_kind)
        raise _Refused()

    fixture = _Fixture(permission_handler)
    fixture.present()
    assert fixture.answer(AnswerActionKind.APPROVE) is True
    before = fixture.await_state(AnswerAttemptState.FAILED)

    assert fixture.answer(AnswerActionKind.REPLY, "yes please") is False

    after = fixture.attempt()
    assert after.state is AnswerAttemptState.FAILED
    assert after.last_error == before.last_error == "Its terminal tab has to be in front."
    assert after.draft_text == before.draft_text
    assert calls == [AnswerActionKind.APPROVE]
    fixture.close()


def test_a_refused_reply_is_followed_by_a_reply_with_the_new_text() -> None:
    replies: list[str | None] = []

    def handler(_invocation, *, request_kind, answer_kind, reply_text) -> None:
        replies.append(reply_text)
        if len(replies) == 1:
            raise _Refused()

    fixture = _Fixture(handler, RequestKind.INPUT)
    fixture.present()

    assert fixture.answer(AnswerActionKind.REPLY, "first words") is True
    fixture.await_state(AnswerAttemptState.FAILED)

    assert fixture.answer(AnswerActionKind.REPLY, "second words") is True
    sent = fixture.await_state(AnswerAttemptState.SENT)

    assert replies == ["first words", "second words"]
    assert sent.draft_text == "second words"
    assert fixture.answer(AnswerActionKind.REPLY, "third words") is False
    assert replies == ["first words", "second words"]
    fixture.close()


class _RunningFuture:
    """A queued send whose executor thread has already picked it up."""

    def __init__(self, operation) -> None:
        self.operation = operation
        self.callbacks: list[object] = []
        self._done = False

    def add_done_callback(self, callback) -> None:
        self.callbacks.append(callback)

    def cancel(self) -> bool:
        return False

    def done(self) -> bool:
        return self._done

    def result(self) -> None:
        return None

    def run(self) -> None:
        try:
            self.operation()
        finally:
            self._done = True
        for callback in tuple(self.callbacks):
            callback(self)


class _ManualExecutor:
    def __init__(self) -> None:
        self.futures: list[_RunningFuture] = []

    def submit(self, operation) -> _RunningFuture:
        future = _RunningFuture(operation)
        self.futures.append(future)
        return future

    def shutdown(self, *, wait: bool, cancel_futures: bool) -> None:
        return None


class _ManualTimer:
    def __init__(self, callback) -> None:
        self.callback = callback
        self.cancelled = False

    def start(self) -> None:
        return None

    def cancel(self) -> None:
        self.cancelled = True

    def fire(self) -> None:
        if not self.cancelled:
            self.callback()


def test_a_timed_out_send_is_replaced_only_once_its_handler_has_ended() -> None:
    calls: list[AnswerActionKind] = []

    def handler(_invocation, *, request_kind, answer_kind, reply_text) -> None:
        calls.append(answer_kind)

    fixture = _Fixture(handler)
    executor = _ManualExecutor()
    timers: list[_ManualTimer] = []

    def timer_factory(_delay, callback) -> _ManualTimer:
        timer = _ManualTimer(callback)
        timers.append(timer)
        return timer

    fixture.controller.runtime = AnswerRuntime(
        registry=fixture.controller.handler_registry,
        executor=executor,
        timer_factory=timer_factory,
        dispatch_main=lambda callback: callback(),
        on_change=fixture.controller._runtime_changed,
    )
    fixture.present()

    assert fixture.answer(AnswerActionKind.APPROVE) is True
    timers[0].fire()
    assert fixture.attempt().state is AnswerAttemptState.TIMED_OUT

    # The first handler is still running, so a second key would queue behind it
    # and could double-type. The verdict is refused until that handler ends.
    assert fixture.answer(AnswerActionKind.DENY) is False
    assert len(executor.futures) == 1
    assert fixture.attempt().state is AnswerAttemptState.TIMED_OUT

    executor.futures[0].run()
    assert calls == [AnswerActionKind.APPROVE]
    assert fixture.attempt().state is AnswerAttemptState.TIMED_OUT

    assert fixture.answer(AnswerActionKind.DENY) is True
    assert len(executor.futures) == 2
    executor.futures[1].run()

    assert calls == [AnswerActionKind.APPROVE, AnswerActionKind.DENY]
    assert fixture.attempt().state is AnswerAttemptState.SENT
