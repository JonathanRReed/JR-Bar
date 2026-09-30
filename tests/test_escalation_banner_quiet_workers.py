"""The stage-three escalation banner never picks a quiet worker's request.

With sub-agent asks off, a worker's permission request stays in canonical
state (the reducer keeps it honest), and it is a live request that waits on
the user. The escalation banner took the first live request in
``state.requests`` with no worker filter, so a quiet worker's request could
raise the banner. It skips the keys ``quiet_worker_request_keys`` names.
A main session's request, and a worker's request with the setting on, still
raise it.
"""

from __future__ import annotations

import time
import unittest
from dataclasses import replace
from unittest.mock import patch

from test_attention import _canonical_permission_request_snapshot
from test_jrbar import isolate_controller

from jrbar import signals


class EscalationBannerQuietWorkerTests(unittest.TestCase):
    def setUp(self) -> None:
        isolate_controller(self)

    def _banner_requests(self, snapshot, *, subagent_asks_alert: bool) -> list:
        """The request keys the stage-three banner tried to deliver."""
        controller = self.controller
        controller.settings = replace(
            controller.settings.with_escalation_tier(signals.ESCALATION_TIER_CHIME),
            subagent_asks_alert=subagent_asks_alert,
        )
        controller.current_operator_state = snapshot.operator_state
        # An old enough episode is stage three, the stage that raises the banner.
        controller.ask_blocked_since = time.monotonic() - 10_000.0
        controller.escalation_last_stage = 0
        controller.escalation_chimed = False
        delivered: list = []
        real_grant = type(controller).interrupt_grant

        def silent_grant(target, kind):
            # The banner is allowed; no sound is played from a test.
            return replace(real_grant(target, kind), audible=False, banner_allowed=True)

        with (
            patch.object(type(controller), "interrupt_grant", silent_grant),
            patch.object(type(controller), "fire_escalation_webhook", lambda *_a: None),
            patch.object(
                type(controller),
                "_deliver_semantic_notification",
                lambda _self, _event_key, _klass, **kwargs: delivered.append(
                    kwargs.get("request_key")
                ),
            ),
        ):
            controller.apply_escalation()
        return delivered

    def test_the_fixture_is_a_live_request_that_waits_on_the_user(self) -> None:
        # If the canonical path stops producing a live, fresh, user-owned
        # request, the tests below would pass for the wrong reason.
        from jrbar.operator_state import RequestPhase
        from jrbar.provider_facts import NextActor, SourceFreshness

        main = _canonical_permission_request_snapshot(
            session_id="session:main", agent_id=None
        )
        (request,) = main.operator_state.requests
        self.assertIs(request.phase, RequestPhase.LIVE_UNACKNOWLEDGED)
        self.assertIs(request.next_actor, NextActor.USER)
        self.assertIs(request.source_freshness, SourceFreshness.FRESH)

    def test_a_workers_request_alone_raises_no_banner(self) -> None:
        worker = _canonical_permission_request_snapshot(
            session_id="session:main", agent_id="agent:worker"
        )
        self.assertEqual(len(worker.operator_state.requests), 1)

        delivered = self._banner_requests(worker, subagent_asks_alert=False)

        self.assertEqual(delivered, [])
        # The request is canonical truth either way.
        self.assertEqual(len(self.controller.current_operator_state.requests), 1)

    def test_a_main_sessions_request_still_raises_the_banner(self) -> None:
        main = _canonical_permission_request_snapshot(
            session_id="session:main", agent_id=None
        )

        delivered = self._banner_requests(main, subagent_asks_alert=False)

        self.assertEqual(delivered, [main.operator_state.requests[0].key])

    def test_a_worker_request_raises_the_banner_when_the_setting_is_on(self) -> None:
        worker = _canonical_permission_request_snapshot(
            session_id="session:main", agent_id="agent:worker"
        )

        delivered = self._banner_requests(worker, subagent_asks_alert=True)

        self.assertEqual(delivered, [worker.operator_state.requests[0].key])

    def test_a_quiet_worker_request_is_skipped_for_the_main_one_behind_it(self) -> None:
        """The first live request in canonical order may be the worker's:
        the banner moves on to the main session's request instead of
        stopping at the first."""
        worker = _canonical_permission_request_snapshot(
            session_id="session:main", agent_id="agent:worker"
        )
        main = _canonical_permission_request_snapshot(
            session_id="session:main", agent_id=None
        )
        worker_request = worker.operator_state.requests[0]
        main_request = main.operator_state.requests[0]
        combined = replace(
            main,
            operator_state=replace(
                main.operator_state,
                works=(*worker.operator_state.works, *main.operator_state.works),
                requests=(worker_request, main_request),
            ),
        )

        quiet = self._banner_requests(combined, subagent_asks_alert=False)
        loud = self._banner_requests(combined, subagent_asks_alert=True)

        self.assertEqual(quiet, [main_request.key])
        self.assertEqual(loud, [worker_request.key])


if __name__ == "__main__":
    unittest.main()
