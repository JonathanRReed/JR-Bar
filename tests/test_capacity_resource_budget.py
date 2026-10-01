from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

import pytest

from jrbar import usage_stats
from jrbar.capacity_refresh import RefreshStatusKind
from jrbar.capacity_types import SourceKey
from jrbar.providers import negotiated_provider_sources
from tests.test_jrbar import isolate_controller

CODEX_QUOTA = SourceKey(
    "codex",
    "quota",
    "local",
    "remote_quota_windows",
)
CLAUDE_QUOTA = SourceKey(
    "claude",
    "quota",
    "experimental-remote",
    "remote_quota_windows",
)
CODEX_TRANSCRIPTS = SourceKey(
    "codex",
    "transcripts",
    "local",
    "transcript_usage",
)
CLAUDE_TRANSCRIPTS = SourceKey(
    "claude",
    "transcripts",
    "local",
    "transcript_usage",
)


def scan_provider_usage(source, root, cache_path, *, since_epoch):
    """Local oracle over the live scanner (the thin public wrapper was
    deleted 2026-08-26: tests were its only callers)."""
    result, _totals = usage_stats._scan_provider_usage_with_totals(
        source, root, cache_path, since_epoch=since_epoch
    )
    return result



@pytest.fixture
def controller(request):
    class ControllerCase:
        def __init__(self) -> None:
            self._cleanups = []

        def addCleanup(self, callback) -> None:
            self._cleanups.append(callback)

        def skipTest(self, reason: str) -> None:
            pytest.skip(reason)

        def close(self) -> None:
            for callback in reversed(self._cleanups):
                callback()

    case = ControllerCase()
    isolate_controller(case)
    request.addfinalizer(case.close)
    return case.controller, case.status_bar


def test_disabled_remote_capacity_never_owns_a_timer_or_healthy_state(
    controller,
) -> None:
    target, _status_bar = controller
    rows = {
        row.key.source: row
        for row in target._capacity_refresh_coordinator.snapshot_state(100.0).sources
    }

    assert rows[CODEX_QUOTA].enabled is True
    assert rows[CODEX_QUOTA].status is RefreshStatusKind.IDLE
    assert CLAUDE_QUOTA not in rows

    with (
        patch("jrbar.status_bar.threading.Thread") as thread_type,
    ):
        assert target.request_usage_refresh((CLAUDE_QUOTA,), reason="menu-open") == ()

    assert target._capacity_refresh_deadline_timers == {}
    thread_type.assert_not_called()


def test_no_capacity_timer_exists_without_due_or_visible_reason(controller) -> None:
    target, _status_bar = controller
    target._usage_provider_states = {
        provider_id: state.__class__(
            source_key=state.source_key,
            enabled=False,
            visible=False,
        )
        for provider_id, state in target._usage_provider_states.items()
    }
    target._usage_provider_models = {}

    with patch.object(target, "_schedule_capacity_timer") as schedule:
        target.schedule_capacity_timers(epoch_now=1_000.0)

    schedule.assert_not_called()
    assert target._capacity_reset_timer is None


def test_duplicate_exact_sources_create_one_generation_and_one_batch_worker(
    controller,
) -> None:
    target, status_bar = controller
    timer_api = MagicMock()
    timer_api.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_.return_value = (
        MagicMock()
    )

    with (
        patch.object(status_bar, "NSTimer", timer_api),
        patch("jrbar.status_bar.threading.Thread") as thread_type,
    ):
        started = target.request_usage_refresh(
            (
                CODEX_TRANSCRIPTS,
                CODEX_TRANSCRIPTS,
                CODEX_QUOTA,
                CODEX_QUOTA,
            ),
            reason="menu-open",
        )

    assert started == (CODEX_TRANSCRIPTS, CODEX_QUOTA)
    thread_type.assert_called_once()
    assert thread_type.call_args.kwargs["args"][0] == {
        CODEX_TRANSCRIPTS: 1,
        CODEX_QUOTA: 1,
    }
    schedule = (
        timer_api.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_
    )
    assert schedule.call_count == 1


def test_warm_unchanged_exact_usage_source_performs_zero_disk_writes(
    tmp_path,
) -> None:
    root = tmp_path / "claude"
    root.mkdir()
    row = {
        "type": "assistant",
        "timestamp": "2026-08-12T12:00:00Z",
        "message": {
            "id": "message-1",
            "model": "claude-sonnet-5",
            "usage": {
                "input_tokens": 17,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
                "output_tokens": 0,
            },
        },
    }
    (root / "usage.jsonl").write_text(json.dumps(row) + "\n")
    cache = tmp_path / "state" / "usage.json"
    source = next(
        candidate
        for candidate in negotiated_provider_sources()
        if candidate.source_key == CLAUDE_TRANSCRIPTS
    )

    cold = scan_provider_usage(source, root, cache, since_epoch=0.0)
    with patch("jrbar.usage_stats.atomic_private_write") as write:
        warm = scan_provider_usage(source, root, cache, since_epoch=0.0)

    assert warm.input_tokens == cold.input_tokens == 17
    assert warm.coverage.cache_hits == 1
    write.assert_not_called()
