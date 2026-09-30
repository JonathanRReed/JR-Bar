"""An incident is looked up only for a provider whose source was found on this Mac.

A Mac with only Codex asks about OpenAI and no one else; a Mac with none of
the providers asks no one. A source that is there but failing still gets
incident context, because that is when "the provider is down" is worth saying.
"""

from __future__ import annotations

from dataclasses import replace as dataclass_replace

import pytest

from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
)
from jrbar.provider_usage_runtime import ProviderUsageService
from jrbar.provider_usage_settings import default_provider_usage_settings


def snapshot_for(
    provider_id: str,
    *,
    state: ProviderSourceState = ProviderSourceState.READY,
    observed_at: float = 1000.0,
    incident: str | None = None,
) -> ProviderUsageSnapshot:
    lanes = ()
    if state in {ProviderSourceState.READY, ProviderSourceState.STALE}:
        lanes = (
            UsageLane(
                provider_id=provider_id,
                lane_id="weekly",
                label="Weekly",
                remaining_percent=50.0,
                reset_at=3000.0,
                scope="all",
                model=None,
                feature=None,
                bindable=True,
                source_id="fixture",
            ),
        )
    return ProviderUsageSnapshot(
        provider_id=provider_id,
        account_label=None,
        observed_at=observed_at,
        state=state,
        reason_code=None if state is ProviderSourceState.READY else "network_unavailable",
        action_label=None if state is ProviderSourceState.READY else "Retry",
        lanes=lanes,
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=incident,
    )


def service_with(tmp_path, collectors, incident_lookup=None, settings=None) -> ProviderUsageService:
    chosen = default_provider_usage_settings() if settings is None else settings
    kwargs = {} if incident_lookup is None else {"incident_lookup": incident_lookup}
    return ProviderUsageService(
        settings_loader=lambda: chosen,
        collectors=collectors,
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        **kwargs,
    )


def collector_for(provider_id: str, **kwargs):
    return lambda _preference, _home, observed_at, _credentials: snapshot_for(
        provider_id, observed_at=observed_at, **kwargs
    )


# --- only a provider that was found is looked up ----------------------------------


def test_a_provider_whose_source_is_not_found_is_not_looked_up(tmp_path) -> None:
    asked: list[str] = []

    def lookup(provider_id: str, _observed_at: float) -> str | None:
        asked.append(provider_id)
        return None

    service = service_with(
        tmp_path,
        {
            "claude": collector_for("claude", state=ProviderSourceState.SOURCE_NOT_FOUND),
            "codex": collector_for("codex"),
            "cursor": collector_for("cursor", state=ProviderSourceState.SOURCE_NOT_FOUND),
        },
        incident_lookup=lookup,
    )

    result = service.refresh_now(providers=("claude", "codex", "cursor"), force=True)

    assert asked == ["codex"]
    assert result.by_provider("claude").state is ProviderSourceState.SOURCE_NOT_FOUND


def test_a_machine_with_none_of_the_providers_asks_no_one(tmp_path) -> None:
    # Recorded, not raised: the refresh loop swallows a lookup that raises.
    asked: list[str] = []

    service = service_with(
        tmp_path,
        {
            provider_id: collector_for(provider_id, state=ProviderSourceState.SOURCE_NOT_FOUND)
            for provider_id in ("claude", "codex", "cursor")
        },
        incident_lookup=lambda provider_id, _observed: asked.append(provider_id),
    )

    service.refresh_now(providers=("claude", "codex", "cursor"), force=True)

    assert asked == []


@pytest.mark.parametrize(
    "state",
    [
        ProviderSourceState.ERROR,
        ProviderSourceState.UNAVAILABLE,
        ProviderSourceState.RATE_LIMITED,
        ProviderSourceState.NEEDS_SIGN_IN,
        ProviderSourceState.STALE,
    ],
)
def test_a_provider_that_was_found_but_failed_still_gets_incident_context(tmp_path, state) -> None:
    # "The provider is down" is exactly what a failing fetch needs to say, so a
    # source that is there but not answering is still looked up.
    service = service_with(
        tmp_path,
        {"codex": collector_for("codex", state=state)},
        incident_lookup=lambda _provider, _observed: "OpenAI: API errors",
    )

    result = service.refresh_now(providers=("codex",), force=True)

    assert result.by_provider("codex").state is state
    assert result.by_provider("codex").incident == "OpenAI: API errors"


def test_a_source_not_found_keeps_the_collectors_own_incident_note(tmp_path) -> None:
    asked: list[str] = []
    service = service_with(
        tmp_path,
        {
            "codex": collector_for(
                "codex",
                state=ProviderSourceState.SOURCE_NOT_FOUND,
                incident="a note the collector wrote",
            )
        },
        incident_lookup=lambda provider_id, _observed: asked.append(provider_id),
    )

    result = service.refresh_now(providers=("codex",), force=True)

    assert asked == []
    assert result.by_provider("codex").incident == "a note the collector wrote"


def test_one_found_instance_is_enough_to_look_the_provider_up(tmp_path) -> None:
    settings = default_provider_usage_settings()
    settings = settings.with_instance(
        dataclass_replace(settings.preference("claude"), source_instance_id="work")
    )
    asked: list[str] = []

    def collect(preference, _home, observed_at, _credentials):
        state = (
            ProviderSourceState.READY
            if preference.source_instance_id == "default"
            else ProviderSourceState.SOURCE_NOT_FOUND
        )
        return dataclass_replace(
            snapshot_for("claude", state=state, observed_at=observed_at),
            source_instance_id=preference.source_instance_id,
        )

    service = service_with(
        tmp_path,
        {"claude": collect},
        incident_lookup=lambda provider_id, _observed: asked.append(provider_id),
        settings=settings,
    )

    service.refresh_now(providers=("claude",), force=True)

    assert asked == ["claude"]
