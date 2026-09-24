from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from jrbar.capacity_types import SourceKey
from jrbar.clear_agents import (
    ClearAgentsState,
    CompletionPresentationReceipt,
    completion_presentation_key,
)
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import WorkIdentifier, WorkKey
from tests.test_jrbar import isolate_controller


class ClearAgentsControllerIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        isolate_controller(self)

    @staticmethod
    def _completion(
        session: str,
        *,
        provider: str = "claude",
        source_instance: str = "global",
        updated_at: datetime | None = None,
    ) -> AgentStatus:
        return AgentStatus(
            provider=provider,
            agent_id=f"{provider}:session:{session}",
            display_name=f"{provider.title()} {session}",
            mode=AgentMode.COMPLETED,
            updated_at=updated_at or datetime.now(timezone.utc),
            event_name="Stop",
            session_id=session,
            work_key=WorkKey(
                SourceKey(provider, "hooks", source_instance, "live_agent_events"),
                WorkIdentifier(f"work:{session}"),
            ),
        )

    @staticmethod
    def _snapshot(*statuses: AgentStatus) -> SimpleNamespace:
        return SimpleNamespace(
            statuses=tuple(statuses),
            stale_statuses=(),
            collected_at=datetime.now(timezone.utc),
        )

    @staticmethod
    def _state_for(completed: AgentStatus) -> ClearAgentsState:
        key = completion_presentation_key(completed)
        assert key is not None
        return ClearAgentsState(
            generation=1,
            receipts=(
                CompletionPresentationReceipt(
                    key=key,
                    acknowledged_at_epoch=completed.updated_at.timestamp() + 1.0,
                ),
            ),
        )


    def test_exact_receipt_suppresses_only_the_acknowledged_mailbox_event(self) -> None:
        initial_time = datetime.now(timezone.utc) - timedelta(seconds=2)
        completed = self._completion("same-agent", updated_at=initial_time)
        self.controller.clear_agents_state = self._state_for(completed)

        self.controller.update_attention_projection(self._snapshot(completed))
        visible = {
            row.agent_id
            for section in self.controller.current_mailbox_projection.sections
            for row in section.rows
        }
        self.assertNotIn(completed.agent_id, visible)

        newer = replace(completed, updated_at=initial_time + timedelta(seconds=1))
        self.controller.update_attention_projection(self._snapshot(newer))
        visible = {
            row.agent_id
            for section in self.controller.current_mailbox_projection.sections
            for row in section.rows
        }
        self.assertIn(newer.agent_id, visible)


if __name__ == "__main__":
    unittest.main()
