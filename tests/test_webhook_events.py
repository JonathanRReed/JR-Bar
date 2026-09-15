"""Every ticked webhook moment must actually deliver -- and only then.

The bridge has one outbound seam (``post_webhook``: URL set, DND/webhook
grant, one JSON POST, never retried). ``record_activity_entries`` is where
the ask/failure/quota edges are already produced for the ledger, so each
ticked event rides the same edge: one entry, one POST.
"""

from __future__ import annotations

import unittest

from test_jrbar import isolate_controller

from jrbar.activity_ledger import ActivityEntry, ActivityKind


def _entry(kind: ActivityKind, **overrides) -> ActivityEntry:
    base = dict(
        kind=kind,
        occurred_at_epoch=1_800_000_000.0,
        label="Codex work:01",
        provider="codex",
        subject_id="codex:session:work:01",
        detail=None,
    )
    base.update(overrides)
    return ActivityEntry(**base)


class WebhookMomentEventTests(unittest.TestCase):
    def setUp(self) -> None:
        isolate_controller(self)
        self.controller.leds_enabled = False
        self.posted: list[dict] = []
        self.controller.post_webhook = self.posted.append
        self.controller.settings = (
            self.controller.settings.with_escalation_webhook_url(
                "https://example.invalid/hook"
            )
        )

    def _enable(self, *keys: str) -> None:
        for key in keys:
            self.controller.settings = self.controller.settings.with_webhook_event(
                key, True
            )

    def test_ask_opened_posts_once_when_enabled(self) -> None:
        self._enable("ask_opened")
        self.controller.record_activity_entries(
            (_entry(ActivityKind.ASKED),)
        )
        self.assertEqual(len(self.posted), 1)
        payload = self.posted[0]
        self.assertEqual(payload["event"], "jrbar.ask_opened")
        self.assertEqual(payload["provider"], "codex")
        self.assertEqual(payload["label"], "Codex work:01")
        self.assertEqual(payload["session"], "codex:session:work:01")

    def test_ask_opened_posts_nothing_when_disabled(self) -> None:
        self.controller.record_activity_entries(
            (_entry(ActivityKind.ASKED),)
        )
        self.assertEqual(self.posted, [])

    def test_failed_posts_once_when_enabled(self) -> None:
        self._enable("failed")
        self.controller.record_activity_entries(
            (_entry(ActivityKind.BLOCKED),)
        )
        self.assertEqual(
            [payload["event"] for payload in self.posted],
            ["jrbar.failed"],
        )

    def test_failed_posts_nothing_when_disabled(self) -> None:
        self._enable("ask_opened", "quota_crossed")
        self.controller.record_activity_entries(
            (_entry(ActivityKind.BLOCKED),)
        )
        self.assertEqual(self.posted, [])

    def test_quota_crossed_posts_once_when_enabled(self) -> None:
        self._enable("quota_crossed")
        self.controller.record_activity_entries(
            (
                _entry(
                    ActivityKind.THRESHOLD_CROSSED,
                    label="Claude weekly",
                    provider="claude",
                    subject_id=None,
                    detail="80%",
                ),
            )
        )
        self.assertEqual(len(self.posted), 1)
        payload = self.posted[0]
        self.assertEqual(payload["event"], "jrbar.quota_crossed")
        self.assertEqual(payload["detail"], "80%")

    def test_quota_crossed_posts_nothing_when_disabled(self) -> None:
        self.controller.record_activity_entries(
            (
                _entry(
                    ActivityKind.THRESHOLD_CROSSED,
                    label="Claude weekly",
                    provider="claude",
                    subject_id=None,
                    detail="80%",
                ),
            )
        )
        self.assertEqual(self.posted, [])

    def test_completion_stays_on_its_own_edge(self) -> None:
        # The ledger row must not double-post: track_completions owns the
        # "whole family finished" edge and already sends jrbar.completion.
        self._enable("completion", "ask_opened", "failed", "quota_crossed")
        self.controller.record_activity_entries(
            (_entry(ActivityKind.COMPLETED),)
        )
        self.assertEqual(self.posted, [])

    def test_a_refused_batch_posts_nothing(self) -> None:
        from jrbar import status_bar_legacy
        from jrbar.activity_ledger import ActivityValidationError

        self._enable("ask_opened")

        def _raise(*_args, **_kwargs):
            raise ActivityValidationError("ledger refused")

        original = status_bar_legacy.record_activities
        status_bar_legacy.record_activities = _raise
        try:
            self.controller.record_activity_entries(
                (_entry(ActivityKind.ASKED),)
            )
        finally:
            status_bar_legacy.record_activities = original
        self.assertEqual(self.posted, [])

    def test_the_grant_gate_knows_every_new_event(self) -> None:
        # Fix the DND-derived budget so the test exercises the event ->
        # interrupt-kind mapping, not ambient DND state.
        from jrbar import signals as signals_module

        self.controller.interrupt_budget = lambda: signals_module.InterruptBudget(
            burst=1,
            outbound_admission=True,
            banner_allowed=True,
            audible_allowed=True,
            webhook_allowed=True,
        )
        self.assertTrue(
            self.controller.webhook_effect_allowed({"event": "jrbar.ask_opened"})
        )
        self.assertTrue(
            self.controller.webhook_effect_allowed({"event": "jrbar.failed"})
        )
        self.assertTrue(
            self.controller.webhook_effect_allowed({"event": "jrbar.quota_crossed"})
        )
        self.assertFalse(
            self.controller.webhook_effect_allowed({"event": "jrbar.unknown"})
        )
        self.assertFalse(self.controller.webhook_effect_allowed("nope"))
