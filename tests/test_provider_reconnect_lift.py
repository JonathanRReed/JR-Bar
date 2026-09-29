"""A signed-out Gemini card lifts by itself once the CLI saves its sign-in."""

from __future__ import annotations

import json

from jrbar.provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot
from jrbar.provider_usage_runtime import ProviderUsageService
from jrbar.provider_usage_settings import default_provider_usage_settings


def _signed_out(observed: float) -> ProviderUsageSnapshot:
    return ProviderUsageSnapshot(
        provider_id="gemini",
        account_label=None,
        observed_at=observed,
        state=ProviderSourceState.NEEDS_SIGN_IN,
        reason_code="network_unavailable",
        action_label="Retry",
        lanes=(),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
        account_discriminator=None,
    )


def test_gemini_terminal_gate_lifts_when_the_cli_saves_its_sign_in(tmp_path) -> None:
    settings = default_provider_usage_settings()
    calls: list[float] = []
    clock = {"now": 1000.0}

    def collector(_pref, _home, observed, _credentials):
        calls.append(observed)
        return _signed_out(observed)

    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={"gemini": collector},
        credentials=object(),
        home=tmp_path,
        clock=lambda: clock["now"],
    )

    service.refresh_now(providers=("gemini",))
    assert len(calls) == 1
    clock["now"] = 1200.0
    service.refresh_now(providers=("gemini",))
    assert len(calls) == 1, "a signed-out Gemini was re-collected with no change"

    creds = tmp_path / ".gemini" / "oauth_creds.json"
    creds.parent.mkdir()
    creds.write_text(json.dumps({"access_token": "x" * 24}), encoding="utf-8")
    clock["now"] = 1300.0
    service.refresh_now(providers=("gemini",))
    assert len(calls) == 2, "the CLI saving its sign-in must lift the gate"

    # Still failing, so the gate re-arms against the new file and stays put.
    clock["now"] = 1400.0
    service.refresh_now(providers=("gemini",))
    assert len(calls) == 2
