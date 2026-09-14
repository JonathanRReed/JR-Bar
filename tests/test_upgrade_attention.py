"""W04 upgrade regressions: one attention episode, exact request identity.

An ask's canonical request key is the episode: ``state.asks[].request``
carries it, ``ask_opened``/``ask_resolved`` carry it, and ``answer_ask``
verifies a caller-supplied one BEFORE arming the surface — a card pinned
to a request the provider already replaced refuses ``stale_request`` and
types nothing. The ask diff is keyed on that identity, so a replaced
request emits resolved+opened rather than silently reusing the session's
slot. ``state.asks`` order is pointer-stable: opened_at order, so a
provider re-emitting a pending prompt cannot shuffle a card out from
under the pointer.
"""

from __future__ import annotations

import threading
from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar.core_projection import _pointer_stable_ask_key, ask_document
from jrbar.core_server import CommandError


def _live_ask_state():
    """One canonical work holding one live ask, reduced for real."""
    from jrbar.capacity_types import SourceKey
    from jrbar.operator_state import (
        BootIdentifier,
        ClockSample,
        empty_operator_state,
        reduce_operator_state,
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

    source = SourceKey("codex", "hooks", "local:01", "live_agent_events")
    work_key = WorkKey(source, WorkIdentifier("work:01"))
    request_key = RequestKey(work_key, RequestIdentifier("request:01"))
    watermark = ProviderWatermark(
        source, WatermarkBasis.PROVIDER_EVENT_ID, 1_800_000_000.0,
        EventToken("event:001"), None, 10,
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
                key=work_key, lifecycle=WorkLifecycle.WAITING,
                watermark=watermark, safe_label="Codex work:01",
                parent_key=None, next_actor=NextActor.USER,
            ),
        ),
        request_facts=(
            ProviderRequestFact(
                key=request_key, state=ProviderRequestState.LIVE,
                request_kind=RequestKind.PERMISSION,
                next_actor=NextActor.USER, watermark=watermark,
            ),
        ),
        diagnostics=(),
    )
    state = reduce_operator_state(
        empty_operator_state(),
        batch,
        clock=ClockSample(1_800_000_000.0, 100.0, BootIdentifier("boot:01")),
    ).state
    return state, work_key, request_key


def _status(work_key, request_key):
    from jrbar.models import AgentMode, AgentStatus

    return AgentStatus(
        provider="codex",
        agent_id="codex:session:work:01",
        display_name="Codex work:01",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=None,
        event_name="PermissionRequest",
        session_id="work:01",
        work_key=work_key,
        request_key=request_key,
    )


def _identity(request_key) -> str:
    from jrbar.announcer_stack import announcer_alert_identity

    return str(announcer_alert_identity(request_key).value)


def _controller_for_answer(state, status):
    """The command's minimal controller: snapshot + operator state + the
    dispatch seam, with arming/dispatch observed for the refusal tests."""
    from jrbar.answer_local import AnswerDeliveryOutcome

    surface = SimpleNamespace(
        armed=False,
        completed=threading.Event(),
        last_outcome=None,
        arm=lambda: setattr(surface, "armed", True),
    )
    captured = []

    def fake_answer(command, operator_state, statuses):
        captured.append(command)
        surface.last_outcome = AnswerDeliveryOutcome(
            delivered=True, code="sent", message="ok", plan=None
        )
        surface.completed.set()
        return True

    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(statuses=(status,), stale_statuses=()),
        current_operator_state=state,
        local_answer_surface=surface,
        answer_controller=SimpleNamespace(perform_browser_answer=fake_answer),
        refresh_=lambda *_: None,
    )
    return controller, surface, captured


def test_ask_document_carries_the_episode_identity():
    state, work_key, request_key = _live_ask_state()
    document = ask_document(_status(work_key, request_key), state, with_session=True)
    assert document["request"] == _identity(request_key)
    assert document["request"].startswith("request:v1:")


def test_ask_document_without_canonical_request_says_so():
    state, work_key, request_key = _live_ask_state()
    status = _status(work_key, request_key)
    document = ask_document(status, None, with_session=True)
    assert document["request"] is None  # unmodelled ask: no provable episode


def test_answer_ask_with_the_live_request_proceeds():
    state, work_key, request_key = _live_ask_state()
    status = _status(work_key, request_key)
    controller, surface, captured = _controller_for_answer(state, status)
    reply = core_runtime._cmd_answer_ask(
        controller,
        {"session": status.agent_id, "decision": "approve",
         "request": _identity(request_key)},
    )
    assert reply["answered"] is True
    assert surface.armed and captured  # the surface really ran


def test_answer_ask_refuses_a_replaced_request_before_arming():
    """T07: a stale card must not apply to the newer request — the refusal
    lands before the surface is armed, so nothing is typed anywhere."""
    state, work_key, request_key = _live_ask_state()
    status = _status(work_key, request_key)
    controller, surface, captured = _controller_for_answer(state, status)
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_answer_ask(
            controller,
            {"session": status.agent_id, "decision": "approve",
             "request": "request:v1:{\"request_id\":\"request:OLD\"}"},
        )
    assert error.value.code == "stale_request"
    assert surface.armed is False and captured == []  # nothing dispatched


def test_answer_ask_without_a_request_arg_keeps_protocol_compat():
    state, work_key, request_key = _live_ask_state()
    status = _status(work_key, request_key)
    controller, _surface, captured = _controller_for_answer(state, status)
    reply = core_runtime._cmd_answer_ask(
        controller, {"session": status.agent_id, "decision": "deny"}
    )
    assert reply["answered"] is True and captured


def test_ask_diff_sees_a_replaced_request_as_resolved_then_opened():
    """Same session, new request identity: the episode boundary is real —
    the old ask closes and the new one opens, never a silent swap."""
    from jrbar.provider_facts import RequestIdentifier, RequestKey

    _, work_key, request_key = _live_ask_state()
    replaced = RequestKey(work_key, RequestIdentifier("request:02"))
    old_status = _status(work_key, request_key)
    new_status = _status(work_key, replaced)
    previous = {old_status.agent_id: (old_status, _identity(request_key))}
    current = {new_status.agent_id: (new_status, _identity(replaced))}
    events = core_runtime._diff_ask_episodes(previous, current)
    assert [(kind, agent) for kind, agent, _, _ in events] == [
        ("ask_resolved", "codex:session:work:01"),
        ("ask_opened", "codex:session:work:01"),
    ]
    assert events[0][3] == _identity(request_key)   # resolved closes A
    assert events[1][3] == _identity(replaced)      # opened carries B


def test_ask_diff_unmodelled_identities_never_fabricate_replacement():
    status = SimpleNamespace(agent_id="s1", request_key=None)
    previous = {"s1": (status, None)}
    current = {"s1": (status, None)}
    assert core_runtime._diff_ask_episodes(previous, current) == []
    # A None identity cannot prove replacement — but a brand-new or
    # vanished session still reports through presence alone.
    assert [
        kind for kind, *_ in core_runtime._diff_ask_episodes({}, current)
    ] == ["ask_opened"]
    assert [
        kind for kind, *_ in core_runtime._diff_ask_episodes(previous, {})
    ] == ["ask_resolved"]


def test_asks_order_is_opened_at_not_updated_at():
    """T41: provider re-emits bump updated_at; the card order must not."""
    asks = [
        {"session": "s:late", "opened_at": 200.0},
        {"session": "s:early", "opened_at": 50.0},
        {"session": "s:middle", "opened_at": 100.0},
        {"session": "s:unstamped", "opened_at": None},
    ]
    ordered = [ask["session"] for ask in sorted(asks, key=_pointer_stable_ask_key)]
    assert ordered == ["s:early", "s:middle", "s:late", "s:unstamped"]
    # And the sort is stable under a re-emit: same opened_at, newer
    # updated_at on the row — the key does not read updated_at at all.
    bumped = [dict(ask, updated_at=9_999.0) for ask in asks]
    assert [ask["session"] for ask in sorted(bumped, key=_pointer_stable_ask_key)] == ordered


def test_review_watermark_is_monotonic_and_only_moves_on_review():
    """T43: ``last_seen`` never steps backward, so focus churn or a clock
    hiccup cannot resurrect rows the owner already read."""
    from jrbar.activity_ledger import (
        ActivityLedger,
        mark_activity_seen,
    )

    ledger = ActivityLedger((), 1_000.0)
    assert mark_activity_seen(ledger, 500.0).last_seen_epoch == 1_000.0
    assert mark_activity_seen(ledger, 1_500.0).last_seen_epoch == 1_500.0
