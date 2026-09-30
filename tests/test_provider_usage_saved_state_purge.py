"""A saved invented Antigravity lane is dropped by every reader of the file.

Older builds saved a READY "Antigravity CLI 100% left" lane that nothing ever
measured. The daemon dropped it when it restored state, but ``jrbar usage``,
``jrbar providers status``, the sync CLI and the status endpoint read the saved
file without the daemon, and showed or synced the old lane until the daemon next
saved. The purge now lives in the one function that reads the file.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import pytest

from jrbar import provider_usage_cli, provider_usage_sync_cli, serve, usage_cli
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
    is_invented_antigravity_reading,
)
from jrbar.provider_usage_runtime import ProviderUsageState
from jrbar.provider_usage_store import (
    default_provider_usage_state_path,
    load_provider_usage_state,
    save_provider_usage_state,
)

NOW = 1_787_000_000.0


def _snapshot(provider_id: str, *, lane_id: str, source_id: str, remaining: float, tokens: int = 0):
    return ProviderUsageSnapshot(
        provider_id=provider_id,
        account_label=None,
        observed_at=NOW - 60.0,
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=(
            UsageLane(
                provider_id=provider_id,
                lane_id=lane_id,
                label="Fixture",
                remaining_percent=remaining,
                reset_at=NOW + 3_600.0,
                scope="all",
                model=None,
                feature=None,
                bindable=True,
                source_id=source_id,
            ),
        ),
        input_tokens=tokens,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
    )


def _invented():
    return _snapshot(
        "antigravity", lane_id="cli", source_id="antigravity-oauth", remaining=100.0, tokens=3_500
    )


def _real_antigravity():
    return _snapshot(
        "antigravity", lane_id="gemini-weekly", source_id="antigravity-app", remaining=30.0
    )


def _claude():
    return _snapshot("claude", lane_id="five_hour", source_id="official", remaining=60.0)


def _save(home: Path, *snapshots: ProviderUsageSnapshot) -> Path:
    path = default_provider_usage_state_path(home)
    save_provider_usage_state(
        ProviderUsageState(tuple(snapshots), NOW - 60.0, NOW + 600.0, False), path
    )
    return path


@pytest.fixture
def temporary_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("HOME", str(tmp_path))
    return tmp_path


def test_the_helper_names_only_the_lane_no_server_measured() -> None:
    assert is_invented_antigravity_reading(_invented())
    assert not is_invented_antigravity_reading(_real_antigravity())
    assert not is_invented_antigravity_reading(_claude())
    # The same lane ids on another provider are not this fabrication.
    assert not is_invented_antigravity_reading(
        _snapshot("claude", lane_id="cli", source_id="antigravity-oauth", remaining=50.0)
    )


def test_reading_the_saved_file_drops_the_invented_lane_and_asks_for_a_fresh_read(
    tmp_path: Path,
) -> None:
    path = _save(tmp_path, _claude(), _invented())

    state = load_provider_usage_state(path)

    assert [snapshot.provider_id for snapshot in state.snapshots] == ["claude"]
    assert state.refreshed_at == NOW - 60.0
    # A dropped reading is a gap the next refresh should fill, not wait out.
    assert state.next_refresh_at is None


def test_reading_the_saved_file_keeps_a_real_antigravity_reading(tmp_path: Path) -> None:
    path = _save(tmp_path, _real_antigravity(), _claude())

    state = load_provider_usage_state(path)

    assert [snapshot.provider_id for snapshot in state.snapshots] == ["antigravity", "claude"]
    assert state.next_refresh_at == NOW + 600.0


def test_jrbar_usage_does_not_show_the_invented_lane_from_the_saved_file(
    temporary_home: Path,
) -> None:
    _save(temporary_home, _claude(), _invented())

    providers = usage_cli._from_store(now=NOW)["providers"]

    assert [row["id"] for row in providers] == ["claude"]


def test_jrbar_providers_status_does_not_show_the_invented_lane(tmp_path: Path) -> None:
    _save(tmp_path, _claude(), _invented())
    out = io.StringIO()

    code = provider_usage_cli.main(
        ["status", "--json"], stdout=out, home=tmp_path, credentials=object()
    )

    assert code == 0
    text = out.getvalue()
    assert "antigravity-oauth" not in text
    assert "Antigravity CLI" not in text
    document = json.loads(text)
    assert [row["provider_id"] for row in document["providers"]] == ["claude"]


def test_the_sync_cli_does_not_send_the_invented_lane_to_a_peer(tmp_path: Path) -> None:
    _save(tmp_path, _claude(), _invented())
    sent: list[ProviderUsageState] = []

    class Service:
        def refresh_now(self, state):
            sent.append(state)
            raise RuntimeError("stop after the first call")

        def close(self) -> None:
            pass

    with pytest.raises(RuntimeError):
        provider_usage_sync_cli.main(
            ["refresh", "--json"],
            stdout=io.StringIO(),
            home=tmp_path,
            credentials=object(),
            service_factory=lambda **_kwargs: Service(),
        )

    [state] = sent
    assert [snapshot.provider_id for snapshot in state.snapshots] == ["claude"]


def test_the_status_endpoint_publishes_no_quota_for_the_invented_lane() -> None:
    lanes = [
        {
            "provider_id": "antigravity",
            "lane_id": "cli",
            "remaining_percent": 100.0,
            "reset_at": None,
            "source_id": "antigravity-oauth",
        }
    ]

    summary = serve._quota_summary(lanes, provider_id="antigravity", now=NOW)

    assert summary == {"window_count": 0, "remaining_percent": None, "next_reset_at": None}


def test_the_status_endpoint_keeps_a_real_antigravity_quota() -> None:
    lanes = [
        {
            "provider_id": "antigravity",
            "lane_id": "gemini-weekly",
            "remaining_percent": 30.0,
            "reset_at": NOW + 3_600.0,
            "source_id": "antigravity-app",
        }
    ]

    summary = serve._quota_summary(lanes, provider_id="antigravity", now=NOW)

    assert summary["window_count"] == 1
    assert summary["remaining_percent"] == 30.0
