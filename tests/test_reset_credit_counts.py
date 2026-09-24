"""Reset credits are shown as counts, read-only.

Codex reports unused limit-reset credits in its own app-server answer, and
the CLIProxyAPI hub can list them for a hub account. JR-Bar counts them for
the card and never redeems one (there is no redeem button this wave).
"""

from __future__ import annotations

import json
from pathlib import Path

from jrbar.core_projection import usage_document
from jrbar.provider_reconnect import codex_app_server_probe
from jrbar.provider_usage_parsers import parse_grok_usage
from jrbar.provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot
from jrbar.provider_usage_runtime import ProviderUsageState
from jrbar.provider_usage_store import load_provider_usage_state, save_provider_usage_state

FIXTURES = Path(__file__).parent / "fixtures" / "provider_usage"


def _probe(payload: dict) -> dict:
    lines = [
        json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"userAgent": "codex/0.153.4 mac"}}),
        json.dumps({"jsonrpc": "2.0", "id": 2, "result": payload}),
        json.dumps({"jsonrpc": "2.0", "id": 3, "result": {"account": {"email": "a@example.com"}}}),
    ]
    return codex_app_server_probe(runner=lambda: "\n".join(lines))


def test_the_codex_probe_counts_available_reset_credits() -> None:
    payload = json.loads((FIXTURES / "codex-app-server-rate-limits-plus.json").read_text())
    assert _probe(payload)["reset_credits"] == 0
    payload["rateLimitResetCredits"] = {"availableCount": 2, "credits": [{"id": "x"}, {"id": "y"}]}
    assert _probe(payload)["reset_credits"] == 2
    payload.pop("rateLimitResetCredits")
    assert _probe(payload)["reset_credits"] is None


def _snapshot(**changes) -> ProviderUsageSnapshot:
    values = dict(
        provider_id="codex",
        account_label=None,
        observed_at=1000.0,
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=(),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
    )
    values.update(changes)
    return ProviderUsageSnapshot(**values)


def test_the_count_reaches_the_wire_and_survives_a_restart(tmp_path: Path) -> None:
    snapshot = _snapshot(reset_credits=1)
    document = usage_document(ProviderUsageState((snapshot,), 1000.0, None, False))
    assert document["providers"][0]["reset_credits"] == 1

    target = tmp_path / "provider-usage.json"
    save_provider_usage_state(ProviderUsageState((snapshot,), 1000.0, None, False), target)
    assert load_provider_usage_state(target).snapshots[0].reset_credits == 1


def test_a_bad_count_is_refused() -> None:
    for bad in (-1, True, 1.5, 10**9):
        try:
            _snapshot(reset_credits=bad)
        except ValueError:
            continue
        raise AssertionError(f"{bad!r} was accepted")


def test_grok_coupons_are_read_only_when_the_billing_payload_carries_them() -> None:
    base = {"config": {"creditUsagePercent": 10, "billingPeriodEnd": "2026-10-01T00:00:00Z"}}
    assert parse_grok_usage(base, observed_at=1_790_000_000.0).reset_credits is None
    with_coupons = {**base, "remainingResets": [{"tokenId": "t1"}, {"tokenId": "t2"}]}
    snapshot = parse_grok_usage(with_coupons, observed_at=1_790_000_000.0)
    assert snapshot.reset_credits == 2
    assert "t1" not in repr(snapshot), "a coupon's token never reaches the snapshot"
