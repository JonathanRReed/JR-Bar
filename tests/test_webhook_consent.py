from __future__ import annotations

import threading
from types import SimpleNamespace

import pytest

from jrbar import _status_bar_production as production
from jrbar import signals
from jrbar.dnd_policy import (
    DndMode,
    DndSource,
    compose_dnd_contributions,
    contribution_for_mode,
)
from jrbar.settings import AgentMonitorSettings
from jrbar.webhook_delivery import (
    WebhookDeliveryService,
    WebhookEndpoint,
    WebhookReason,
    WebhookResult,
)


@pytest.mark.parametrize("waiting", ["queued", "dns"])
@pytest.mark.parametrize("revocation", ["url", "changed_url", "event", "privacy", "unchanged"])
def test_production_rechecks_webhook_consent_before_transport(waiting: str, revocation: str) -> None:
    blocked = threading.Event()
    release = threading.Event()
    finished = threading.Event()
    delivered = []
    resolved = []
    receipts = []
    url = "https://example.invalid/synthetic-hook"
    target = SimpleNamespace(
        settings=AgentMonitorSettings().with_escalation_webhook_url(url).with_webhook_event("completion", True),
        dnd=compose_dnd_contributions((), next_transition_epoch=None),
    )

    def interrupt_grant(kind):
        return signals.grant_interrupt(
            kind,
            budget=signals.InterruptBudget(
                burst=1,
                outbound_admission=target.dnd.outbound_admission,
                banner_allowed=target.dnd.banner_allowed,
                audible_allowed=target.dnd.audible_allowed,
                webhook_allowed=target.dnd.webhook_allowed,
            ),
        )

    target.interrupt_grant = interrupt_grant
    target.webhook_interrupt_kind = production.JRStatusBarController.webhook_interrupt_kind
    target.webhook_effect_allowed = lambda payload: production.JRStatusBarController.webhook_effect_allowed(target, payload)
    target.webhook_event_enabled = lambda key: key in target.settings.webhook_events

    def validate(endpoint_url):
        resolved.append(endpoint_url)
        if waiting == "dns":
            blocked.set()
            assert release.wait(2.0)
        return WebhookEndpoint(endpoint_url, "example.invalid", 443, "/synthetic-hook", ("93.184.216.34",))

    def deliver(_endpoint, payload):
        if payload["event"] == "blocker":
            blocked.set()
            assert release.wait(2.0)
        delivered.append(payload["event"])
        return WebhookResult(WebhookReason.DELIVERED, 204)

    def receipt(value):
        receipts.append(value)
        finished.set()

    service = WebhookDeliveryService(validator=validate, deliver=deliver)
    target._webhook_service = lambda: service
    target._webhook_delivery_finished = receipt
    try:
        if waiting == "queued":
            assert service.submit(url, {"event": "blocker"}) is None
            assert blocked.wait(2.0)
        production.JRStatusBarController.post_webhook(target, {"event": "jrbar.completion"})
        if waiting == "dns":
            assert blocked.wait(2.0)

        if revocation == "url":
            target.settings = target.settings.with_escalation_webhook_url("")
        elif revocation == "changed_url":
            target.settings = target.settings.with_escalation_webhook_url("https://other.invalid/synthetic-hook")
        elif revocation == "event":
            target.settings = target.settings.with_webhook_event("completion", False)
        elif revocation == "privacy":
            target.dnd = compose_dnd_contributions(
                (contribution_for_mode(DndSource.MANUAL, DndMode.DARK),), next_transition_epoch=None,
            )
        release.set()
        assert finished.wait(2.0)
        if revocation == "unchanged":
            assert delivered.count("jrbar.completion") == 1
            assert receipts[0].result.delivered
            assert len(resolved) == (2 if waiting == "queued" else 1)
        else:
            assert "jrbar.completion" not in delivered
            assert receipts[0].result.reason is WebhookReason.CONSENT_REVOKED
            assert len(resolved) == 1
    finally:
        release.set()
        service.close()
