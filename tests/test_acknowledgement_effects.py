"""The "I'm on It" acknowledgement must reach every effect that reads the
reduced truth: the canonical request phase, the escalation clock, the chime
and the escalation webhook -- and "Resume Escalation" must put it all back.
"""

from __future__ import annotations

import time
import unittest
from datetime import datetime, timezone
from unittest.mock import MagicMock

from jrbar.attention import AttentionProjection, LifecycleMode, ProjectedAgentRow
from jrbar.agent_browser_window import AgentBrowserActionPayload
from jrbar.capacity_types import SourceKey
from jrbar.local_triage import LocalAcknowledgement, LocalTriageState
from jrbar.models import AgentMode, AgentStatus
from jrbar.navigation_policy import OperatorActionKind
from jrbar.operator_state import (
    AcknowledgementEligibility,
    BootIdentifier,
    ClockSample,
    RequestPhase,
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

from test_jrbar import isolate_controller

NOW = 1_800_000_000.0


def _source() -> SourceKey:
    return SourceKey("codex", "hooks", "local:01", "live_agent_events")


def _watermark(token: str = "event:001") -> ProviderWatermark:
    return ProviderWatermark(
        source_key=_source(),
        basis=WatermarkBasis.PROVIDER_EVENT_ID,
        occurred_at_epoch=NOW,
        event_token=EventToken(token),
        sequence=None,
        tie_break_rank=10,
    )


def _clock() -> ClockSample:
    return ClockSample(NOW, 100.0, BootIdentifier("boot:01"))


def _state_with_live_ask():
    """One canonical work holding one live, answerable ask."""
    work_key = WorkKey(_source(), WorkIdentifier("work:01"))
    request_key = RequestKey(work_key, RequestIdentifier("request:01"))
    watermark = _watermark()
    batch = ProviderFactBatch(
        source_key=_source(),
        observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
        source_health=SourceHealth.HEALTHY,
        source_freshness=SourceFreshness.FRESH,
        observed_at_epoch=NOW,
        watermark=watermark,
        work_facts=(
            ProviderWorkFact(
                key=work_key,
                lifecycle=WorkLifecycle.ACTIVE,
                watermark=watermark,
                safe_label="Codex work:01",
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
    result = reduce_operator_state(empty_operator_state(), batch, clock=_clock())
    return result.state, work_key, request_key


def _status(request_key: RequestKey) -> AgentStatus:
    return AgentStatus(
        provider="codex",
        agent_id="codex:session:work:01",
        display_name="Codex work:01",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=datetime.now(timezone.utc),
        event_name="PermissionRequest",
        session_id="work:01",
        work_key=request_key.work_key,
        request_key=request_key,
    )


def _row(status: AgentStatus) -> ProjectedAgentRow:
    return ProjectedAgentRow(
        agent_id=status.agent_id,
        provider=status.provider,
        display_name=status.display_name,
        lifecycle_mode=LifecycleMode.WAITING,
        actionable=True,
        is_subagent=False,
        updated_at=status.updated_at,
        source_status=status,
        work_key=status.work_key,
        request_key=status.request_key,
    )


def _projection(row: ProjectedAgentRow) -> AttentionProjection:
    return AttentionProjection(
        lifecycle_mode=LifecycleMode.WAITING,
        actionable_attention=(row,),
        visible_rows=(row,),
        transient_signals=(),
        dominant_provider=row.provider,
        click_target_agent_id=row.agent_id,
    )


class AcknowledgementEscalationTests(unittest.TestCase):
    """The projection keeps an acknowledged ask visible, but the escalation
    drivers must not count it."""

    def setUp(self) -> None:
        isolate_controller(self)
        self.controller.leds_enabled = False
        self.state, self.work_key, self.request_key = _state_with_live_ask()
        self.row = _row(_status(self.request_key))
        self.projection = _projection(self.row)
        self.controller.current_attention_projection = self.projection
        self.controller.local_triage_state = LocalTriageState(())
        self.controller.operator_triage_saver = MagicMock()
        self.controller.observe_operator_history_triage = MagicMock()
        self.controller.fire_escalation_webhook = MagicMock()
        self.posted = []
        self.controller.post_webhook = self.posted.append

    def _acknowledge(self) -> None:
        payload = AgentBrowserActionPayload(
            self.work_key, self.state.generation, OperatorActionKind.ACKNOWLEDGE
        )
        self.assertTrue(self.controller._apply_triage_action(payload, self.state))

    def _resume(self) -> None:
        payload = AgentBrowserActionPayload(
            self.work_key,
            self.state.generation,
            OperatorActionKind.RESUME_ESCALATION,
        )
        self.assertTrue(self.controller._apply_triage_action(payload, self.state))

    def test_an_asked_row_still_escalates_without_an_acknowledgement(self) -> None:
        self.controller.track_ask_blocked(self.projection)
        self.assertIsNotNone(self.controller.ask_blocked_since)

    def test_acknowledged_ask_earns_no_escalation_clock(self) -> None:
        self.controller.local_triage_state = LocalTriageState(
            (LocalAcknowledgement(self.request_key, NOW),)
        )
        self.controller.track_ask_blocked(self.projection)
        self.assertIsNone(self.controller.ask_blocked_since)
        self.assertEqual(self.controller.current_escalation_stage(), 0)

    def test_im_on_it_stops_the_running_episode_immediately(self) -> None:
        self.controller.track_ask_blocked(self.projection)
        self.controller.ask_blocked_by_agent = {
            self.row.agent_id: time.monotonic() - 400.0
        }
        self.controller.ask_blocked_since = time.monotonic() - 400.0

        self._acknowledge()

        self.assertIsNone(self.controller.ask_blocked_since)
        self.assertEqual(self.controller.current_escalation_stage(), 0)
        self.assertFalse(self.controller.escalation_chimed)
        self.controller.fire_escalation_webhook.assert_not_called()
        self.assertEqual(self.posted, [])

    def test_resume_escalation_starts_a_fresh_interval(self) -> None:
        self._acknowledge()
        self.assertIsNone(self.controller.ask_blocked_since)

        before = time.monotonic()
        self._resume()

        self.assertIsNotNone(self.controller.ask_blocked_since)
        # The resumed interval starts now -- it does not inherit the time
        # the ask already spent acknowledged (or before it).
        self.assertGreaterEqual(self.controller.ask_blocked_since, before)
        self.assertEqual(self.controller.ask_blocked_by_agent.get(self.row.agent_id),
                         self.controller.ask_blocked_since)


class MonitorAcknowledgementTests(unittest.TestCase):
    """The reduced truth itself: monitors must re-derive live request phases
    when the acknowledgement set changes, even with no new fact batch."""

    def test_live_monitor_rederives_phase_on_snapshot(self) -> None:
        from jrbar._collector_legacy import LiveAgentMonitor

        state, _work_key, request_key = _state_with_live_ask()
        keys: list[frozenset] = [frozenset()]
        monitor = LiveAgentMonitor(
            sources=(),
            acknowledged_requests_supplier=lambda: keys[0],
        )
        # Seed the monitor with the same facts the reducer produced.
        work_fact_watermark = _watermark()
        monitor.operator_state = state

        self.assertEqual(
            monitor.snapshot().operator_state.requests[0].phase,
            RequestPhase.LIVE_UNACKNOWLEDGED,
        )

        keys[0] = frozenset({request_key})
        self.assertEqual(
            monitor.snapshot().operator_state.requests[0].phase,
            RequestPhase.LIVE_ACKNOWLEDGED,
        )

        keys[0] = frozenset()
        self.assertEqual(
            monitor.snapshot().operator_state.requests[0].phase,
            RequestPhase.LIVE_UNACKNOWLEDGED,
        )

    def test_live_monitor_ingest_carries_the_current_set(self) -> None:
        from jrbar._collector_legacy import LiveAgentMonitor

        keys: list[frozenset] = [frozenset()]
        monitor = LiveAgentMonitor(
            sources=(),
            acknowledged_requests_supplier=lambda: keys[0],
        )
        monitor.ingest_batch(
            ProviderFactBatch(
                source_key=_source(),
                observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
                source_health=SourceHealth.HEALTHY,
                source_freshness=SourceFreshness.FRESH,
                observed_at_epoch=NOW,
                watermark=_watermark(),
                work_facts=(
                    ProviderWorkFact(
                        key=WorkKey(_source(), WorkIdentifier("work:01")),
                        lifecycle=WorkLifecycle.ACTIVE,
                        watermark=_watermark(),
                        safe_label="Codex work:01",
                        parent_key=None,
                        next_actor=NextActor.USER,
                    ),
                ),
                request_facts=(
                    ProviderRequestFact(
                        key=RequestKey(
                            WorkKey(_source(), WorkIdentifier("work:01")),
                            RequestIdentifier("request:01"),
                        ),
                        state=ProviderRequestState.LIVE,
                        request_kind=RequestKind.PERMISSION,
                        next_actor=NextActor.USER,
                        watermark=_watermark(),
                    ),
                ),
                diagnostics=(),
            ),
            clock=_clock(),
        )
        self.assertEqual(
            monitor.operator_state.requests[0].phase,
            RequestPhase.LIVE_UNACKNOWLEDGED,
        )
        request_key = monitor.operator_state.requests[0].key
        keys[0] = frozenset({request_key})
        # A second batch with the set now covering the ask flips the phase.
        monitor.ingest_batch(
            ProviderFactBatch(
                source_key=_source(),
                observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
                source_health=SourceHealth.HEALTHY,
                source_freshness=SourceFreshness.FRESH,
                observed_at_epoch=NOW + 1,
                watermark=_watermark("event:002"),
                work_facts=(),
                request_facts=(),
                diagnostics=(),
            ),
            clock=ClockSample(NOW + 1, 101.0, BootIdentifier("boot:01")),
        )
        self.assertEqual(
            monitor.operator_state.requests[0].phase,
            RequestPhase.LIVE_ACKNOWLEDGED,
        )

    def test_transcript_monitor_signature_carries_the_acknowledgement_set(self) -> None:
        from jrbar._collector_legacy import AgentMonitor

        keys: list[frozenset] = [frozenset()]
        monitor = AgentMonitor(
            sources=(), acknowledged_requests_supplier=lambda: keys[0]
        )
        _state, _work_key, request_key = _state_with_live_ask()

        monitor.snapshot()
        first = monitor._canonical_signature
        keys[0] = frozenset({request_key})
        monitor.snapshot()
        self.assertNotEqual(monitor._canonical_signature, first)

    def test_a_malformed_supplier_fails_closed_to_nothing_acknowledged(self) -> None:
        from jrbar._collector_legacy import LiveAgentMonitor

        monitor = LiveAgentMonitor(
            sources=(),
            acknowledged_requests_supplier=lambda: {"not", "request", "keys"},
        )
        self.assertEqual(monitor._acknowledged_request_keys(), frozenset())
        monitor.acknowledged_requests_supplier = lambda: (_ for _ in ()).throw(
            RuntimeError("boom")
        )
        self.assertEqual(monitor._acknowledged_request_keys(), frozenset())
