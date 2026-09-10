from __future__ import annotations

from datetime import datetime, timedelta, timezone

from jrbar.capacity_types import SourceKey
from jrbar.clear_agents import CompletionPresentationKey
from jrbar.completion_visibility import (
    HIDDEN,
    VISIBLE_COMPLETION,
    VISIBLE_LIVE,
    acknowledged_epoch_by_session,
    filter_visible_sessions,
    plan_seen_completion_ids,
    select_clearable_completions,
    select_unseen_completions,
    session_visibility,
)
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import WorkIdentifier, WorkKey


def _status(
    agent_id: str,
    *,
    mode: AgentMode = AgentMode.COMPLETED,
    updated_at: datetime,
    event_name: str = "Stop",
    source_instance: str = "local.test",
    keyed: bool = True,
) -> AgentStatus:
    work_key = (
        WorkKey(
            SourceKey(
                "claude",
                "hooks",
                source_instance,
                "live_agent_events",
            ),
            WorkIdentifier(agent_id),
        )
        if keyed
        else None
    )
    return AgentStatus(
        provider="claude",
        agent_id=agent_id,
        display_name=agent_id,
        mode=mode,
        updated_at=updated_at,
        event_name=event_name,
        work_key=work_key,
    )


def test_clearable_completions_current_rows_shadow_stale_duplicates() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    current_completion = _status(
        "claude:session:current",
        updated_at=now - timedelta(minutes=2),
    )
    current_active = _status(
        "claude:session:active",
        mode=AgentMode.WORKING,
        updated_at=now,
    )
    stale_newer_duplicate = _status(
        current_completion.agent_id,
        updated_at=now - timedelta(minutes=1),
    )
    stale_completion_blocked_by_active = _status(
        current_active.agent_id,
        updated_at=now - timedelta(seconds=1),
    )

    selected = select_clearable_completions(
        (current_completion, current_active),
        (stale_newer_duplicate, stale_completion_blocked_by_active),
        collected_at=now,
        within_seconds=20 * 60,
    )

    assert selected == (current_completion,)


def test_clearable_completions_preserve_exclusions_and_newest_first_order() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    latest_b = _status("claude:session:b", updated_at=now - timedelta(seconds=5))
    latest_a = _status("claude:session:a", updated_at=now - timedelta(seconds=5))
    older = _status("claude:session:older", updated_at=now - timedelta(minutes=2))
    subagent = _status("claude:agent:worker", updated_at=now)
    closed = _status(
        "claude:session:closed",
        updated_at=now,
        event_name="SessionEnd",
    )
    expired = _status(
        "claude:session:expired",
        updated_at=now - timedelta(seconds=1_201),
    )

    selected = select_clearable_completions(
        (older, subagent, closed, expired, latest_b, latest_a),
        (),
        collected_at=now,
        within_seconds=1_200,
    )

    assert selected == (latest_a, latest_b, older)
    assert select_clearable_completions(
        (subagent,),
        (),
        collected_at=now,
        within_seconds=1_200,
        include_subagents=True,
    ) == (subagent,)


def test_clearable_completions_keep_same_agent_from_distinct_sources() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    first = _status(
        "claude:session:shared",
        updated_at=now,
        source_instance="local.one",
    )
    second = _status(
        first.agent_id,
        updated_at=now - timedelta(seconds=1),
        source_instance="local.two",
    )

    selected = select_clearable_completions(
        (first, second),
        (),
        collected_at=now,
        within_seconds=300,
    )

    assert selected == (first, second)


def test_unseen_completions_apply_every_acknowledgement_exclusion() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    eligible = _status("claude:session:eligible", updated_at=now)
    subagent = _status("claude:agent:worker", updated_at=now)
    closed = _status(
        "claude:session:closed",
        updated_at=now,
        event_name="SessionEnd",
    )
    expired = _status(
        "claude:session:expired",
        updated_at=now - timedelta(seconds=301),
    )
    cleared = _status("claude:session:cleared", updated_at=now)
    visited = _status(
        "claude:session:visited",
        updated_at=now - timedelta(seconds=30),
    )
    attended = _status("claude:session:attended", updated_at=now)

    selected = select_unseen_completions(
        (eligible, subagent, closed, expired, cleared, visited, attended),
        (),
        collected_at=now,
        within_seconds=300,
        menu_last_opened_at=now - timedelta(seconds=15),
        acknowledged_keys={
            CompletionPresentationKey(
                source_key=SourceKey(
                    "claude",
                    "hooks",
                    "local.test",
                    "live_agent_events",
                ),
                agent_id=cleared.agent_id,
                event_name="Stop",
                completed_at_epoch=now.timestamp(),
            )
        },
        attended_prompt_monotonic={attended.agent_id: 900.0},
        now_monotonic=1_020.0,
        attended_quiet_seconds=120.0,
    )

    assert selected == (eligible,)


def test_unseen_completions_deduplicate_with_current_rows_winning_and_keep_order() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    first = _status("claude:session:first", updated_at=now - timedelta(seconds=20))
    second = _status("claude:session:second", updated_at=now - timedelta(seconds=10))
    active = _status(
        "claude:session:active",
        mode=AgentMode.WORKING,
        updated_at=now,
    )
    stale_duplicate = _status(first.agent_id, updated_at=now)
    stale_blocked = _status(active.agent_id, updated_at=now)
    stale_only = _status("claude:session:stale", updated_at=now)

    selected = select_unseen_completions(
        (first, second, active),
        (stale_duplicate, stale_blocked, stale_only),
        collected_at=now,
        within_seconds=300,
        menu_last_opened_at=None,
        acknowledged_keys=frozenset(),
        attended_prompt_monotonic={},
        now_monotonic=10_000.0,
        attended_quiet_seconds=120.0,
    )

    assert selected == (first, second, stale_only)


def test_unseen_completion_becomes_eligible_after_attended_window() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    completion = _status("claude:session:done", updated_at=now)

    selected = select_unseen_completions(
        (completion,),
        (),
        collected_at=now,
        within_seconds=300,
        menu_last_opened_at=None,
        acknowledged_keys=set(),
        attended_prompt_monotonic={completion.agent_id: 900.0},
        now_monotonic=1_020.001,
        attended_quiet_seconds=120.0,
    )

    assert selected == (completion,)


def test_unseen_completion_receipts_are_exact_to_event_time_and_source() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    agent_id = "claude:session:reused"
    earlier = now - timedelta(minutes=1)
    current = _status(agent_id, updated_at=now)
    old_event_receipt = CompletionPresentationKey(
        source_key=SourceKey(
            "claude",
            "hooks",
            "local.test",
            "live_agent_events",
        ),
        agent_id=agent_id,
        event_name="Stop",
        completed_at_epoch=earlier.timestamp(),
    )
    other_source_receipt = CompletionPresentationKey(
        source_key=SourceKey(
            "claude",
            "hooks",
            "other.mac",
            "live_agent_events",
        ),
        agent_id=agent_id,
        event_name="Stop",
        completed_at_epoch=now.timestamp(),
    )

    selected = select_unseen_completions(
        (current,),
        (),
        collected_at=now,
        within_seconds=300,
        menu_last_opened_at=None,
        acknowledged_keys={old_event_receipt, other_source_receipt},
        attended_prompt_monotonic={},
        now_monotonic=10_000.0,
        attended_quiet_seconds=120.0,
    )

    assert selected == (current,)


def test_unseen_completions_keep_same_agent_from_distinct_sources() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    first = _status(
        "claude:session:shared",
        updated_at=now,
        source_instance="local.one",
    )
    second = _status(
        first.agent_id,
        updated_at=now - timedelta(seconds=1),
        source_instance="local.two",
    )

    selected = select_unseen_completions(
        (first, second),
        (),
        collected_at=now,
        within_seconds=300,
        menu_last_opened_at=None,
        acknowledged_keys=frozenset(),
        attended_prompt_monotonic={},
        now_monotonic=10_000.0,
        attended_quiet_seconds=120.0,
    )

    assert selected == (first, second)


def test_unseen_completion_without_exact_work_key_cannot_be_receipt_suppressed() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    unkeyed = _status(
        "claude:session:unkeyed",
        updated_at=now,
        keyed=False,
    )
    unrelated_receipt = CompletionPresentationKey(
        source_key=SourceKey(
            "claude",
            "hooks",
            "local.test",
            "live_agent_events",
        ),
        agent_id=unkeyed.agent_id,
        event_name="Stop",
        completed_at_epoch=now.timestamp(),
    )

    selected = select_unseen_completions(
        (unkeyed,),
        (),
        collected_at=now,
        within_seconds=300,
        menu_last_opened_at=None,
        acknowledged_keys={unrelated_receipt},
        attended_prompt_monotonic={},
        now_monotonic=10_000.0,
        attended_quiet_seconds=120.0,
    )

    assert selected == (unkeyed,)


def test_seen_id_plan_prioritizes_sorted_visible_completions_then_retained_ids() -> None:
    now = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)
    newest = _status("claude:session:newest", updated_at=now)
    tie_b = _status("claude:session:b", updated_at=now - timedelta(seconds=1))
    tie_a = _status("claude:session:a", updated_at=now - timedelta(seconds=1))
    duplicate_newest = _status(
        newest.agent_id,
        updated_at=now - timedelta(minutes=1),
    )
    closed = _status(
        "claude:session:closed",
        updated_at=now,
        event_name="SessionEnd",
    )
    active = _status(
        "claude:session:active",
        mode=AgentMode.WORKING,
        updated_at=now,
    )

    planned = plan_seen_completion_ids(
        (tie_b, duplicate_newest, closed, newest, active, tie_a),
        {tie_a.agent_id, "retained-z", "retained-a"},
        limit=4,
    )

    assert planned == (
        newest.agent_id,
        tie_a.agent_id,
        tie_b.agent_id,
        "retained-a",
    )
    assert plan_seen_completion_ids((newest,), {"retained"}, limit=0) == ()


# --- the list's own visibility policy ---------------------------------------
#
# ``state.sessions`` is what the panel is looking at, not everything the
# collector remembers: live sessions plus finished ones nobody has
# acknowledged. The owner's report was 15 rows, most "Done · stale" from
# 49-55 minutes ago; every case below is one of those rows.


def _row(
    agent_id: str,
    *,
    lifecycle: str = "active",
    updated_at: float,
    stale: bool = False,
    kind: str = "main",
    parent: str | None = None,
) -> dict:
    return {
        "id": agent_id,
        "kind": kind,
        "parent": parent,
        "lifecycle": lifecycle,
        "updated_at": updated_at,
        "stale": stale,
    }


NOW = 1_789_000_000.0


def test_a_live_session_stays_listed_and_a_quiet_one_drops_out_after_ten_minutes() -> None:
    working = _row("claude:session:working", updated_at=NOW - 30.0)
    waiting = _row("claude:session:waiting", updated_at=NOW - 300.0)
    just_quiet = _row("claude:session:quiet", lifecycle="stale", stale=True, updated_at=NOW - 9 * 60.0)
    long_quiet = _row("claude:session:gone", lifecycle="stale", stale=True, updated_at=NOW - 11 * 60.0)
    ancient = _row("claude:session:ancient", lifecycle="stale", stale=True, updated_at=NOW - 54 * 60.0)

    assert session_visibility(working, now=NOW) == VISIBLE_LIVE
    assert session_visibility(waiting, now=NOW) == VISIBLE_LIVE
    assert session_visibility(just_quiet, now=NOW) == VISIBLE_LIVE
    assert session_visibility(long_quiet, now=NOW) == HIDDEN
    assert session_visibility(ancient, now=NOW) == HIDDEN


def test_a_completion_is_listed_for_twenty_minutes_and_then_only_in_history() -> None:
    fresh = _row("claude:session:fresh", lifecycle="completed", stale=True, updated_at=NOW - 3.5 * 60.0)
    edge = _row("claude:session:edge", lifecycle="completed", stale=True, updated_at=NOW - 18 * 60.0)
    aged = _row("claude:session:aged", lifecycle="completed", stale=True, updated_at=NOW - 41 * 60.0)
    ended = _row("claude:session:ended", lifecycle="ended", stale=True, updated_at=NOW - 60.0)

    assert session_visibility(fresh, now=NOW) == VISIBLE_COMPLETION
    assert session_visibility(edge, now=NOW) == VISIBLE_COMPLETION
    assert session_visibility(aged, now=NOW) == HIDDEN
    # Ended is over too, and gets the same twenty minutes.
    assert session_visibility(ended, now=NOW) == VISIBLE_COMPLETION
    assert (
        session_visibility(
            _row("claude:session:old-end", lifecycle="ended", stale=True, updated_at=NOW - 25 * 60.0),
            now=NOW,
        )
        == HIDDEN
    )


def test_the_twenty_minute_drop_out_needs_only_a_test_clock() -> None:
    """No waiting: the windows are arguments, so `now` does the ageing."""
    row = _row("claude:session:one", lifecycle="completed", stale=True, updated_at=NOW)
    assert session_visibility(row, now=NOW + 19 * 60.0) == VISIBLE_COMPLETION
    assert session_visibility(row, now=NOW + 21 * 60.0) == HIDDEN
    live = _row("claude:session:two", lifecycle="stale", stale=True, updated_at=NOW)
    assert session_visibility(live, now=NOW + 9 * 60.0) == VISIBLE_LIVE
    assert session_visibility(live, now=NOW + 11 * 60.0) == HIDDEN


def test_acknowledgement_hides_a_row_until_that_session_speaks_again() -> None:
    finished_at = NOW - 120.0
    row = _row("claude:session:done", lifecycle="completed", stale=True, updated_at=finished_at)
    acknowledged = {"claude:session:done": finished_at}

    assert session_visibility(row, now=NOW, acknowledged_at_by_id=acknowledged) == HIDDEN
    # The same session picks the work back up: its clock moves past the
    # receipt and it is listed again, without any undo.
    resumed = _row("claude:session:done", updated_at=NOW - 5.0)
    assert session_visibility(resumed, now=NOW, acknowledged_at_by_id=acknowledged) == VISIBLE_LIVE
    # A stale row a widened clear acknowledged goes too.
    stale_row = _row("claude:session:quiet", lifecycle="stale", stale=True, updated_at=NOW - 60.0)
    assert (
        session_visibility(stale_row, now=NOW, acknowledged_at_by_id={"claude:session:quiet": NOW - 60.0})
        == HIDDEN
    )


def test_acknowledged_epoch_by_session_keeps_the_newest_receipt_per_session() -> None:
    source = SourceKey("claude", "hooks", "local.test", "live_agent_events")
    keys = (
        CompletionPresentationKey(source, "claude:session:a", "Stop", NOW - 500.0),
        CompletionPresentationKey(source, "claude:session:a", "SessionEnd", NOW - 100.0),
        CompletionPresentationKey(source, "claude:session:b", "Stop", NOW - 900.0),
    )
    assert acknowledged_epoch_by_session(keys) == {
        "claude:session:a": NOW - 100.0,
        "claude:session:b": NOW - 900.0,
    }


def test_the_list_holds_live_rows_and_hidden_count_names_the_rest() -> None:
    """The owner's screenshot, as data: 15 rows, 7 of them long over."""
    rows = [
        _row("claude:agent:w1", kind="worker", parent="claude:session:live", updated_at=NOW - 12.0),
        _row("claude:session:live", updated_at=NOW - 24.0),
        _row("devin:session:done-now", lifecycle="completed", stale=True, updated_at=NOW - 3.5 * 60.0),
        _row("devin:session:done-18", lifecycle="completed", stale=True, updated_at=NOW - 18.1 * 60.0),
        _row("codex:session:done-41", lifecycle="completed", stale=True, updated_at=NOW - 41.1 * 60.0),
        _row("claude:session:done-49", lifecycle="completed", stale=True, updated_at=NOW - 49.9 * 60.0),
        _row("devin:session:idle-49", lifecycle="stale", stale=True, updated_at=NOW - 49.4 * 60.0),
        _row("devin:session:idle-53", lifecycle="stale", stale=True, updated_at=NOW - 53.0 * 60.0),
        _row("devin:session:idle-54", lifecycle="stale", stale=True, updated_at=NOW - 54.4 * 60.0),
    ]

    listed, hidden, completions = filter_visible_sessions(rows, now=NOW)

    assert [row["id"] for row in listed] == [
        "claude:agent:w1",
        "claude:session:live",
        "devin:session:done-now",
        "devin:session:done-18",
    ]
    # Five main rows are only in History; the worker is not counted, it is listed.
    assert hidden == 5
    assert completions == ("devin:session:done-now", "devin:session:done-18")


def test_a_worker_is_never_listed_without_its_parent() -> None:
    rows = [
        _row("claude:session:gone", lifecycle="stale", stale=True, updated_at=NOW - 40 * 60.0),
        # A worker whose own clock is fresh, under a parent that is long over.
        _row("claude:agent:orphan", kind="worker", parent="claude:session:gone", updated_at=NOW - 5.0),
    ]

    listed, hidden, _completions = filter_visible_sessions(rows, now=NOW)

    assert listed == []
    # One main hidden; the worker went with it and is not counted again.
    assert hidden == 1


def test_clearing_every_listed_row_leaves_only_live_sessions() -> None:
    live = _row("claude:session:live", updated_at=NOW - 10.0)
    rows = [
        live,
        _row("devin:session:done", lifecycle="completed", stale=True, updated_at=NOW - 60.0),
        _row("devin:session:ended", lifecycle="ended", stale=True, updated_at=NOW - 90.0),
        _row("devin:session:quiet", lifecycle="stale", stale=True, updated_at=NOW - 120.0),
    ]
    acknowledged = {
        "devin:session:done": NOW - 60.0,
        "devin:session:ended": NOW - 90.0,
        "devin:session:quiet": NOW - 120.0,
    }

    listed, hidden, completions = filter_visible_sessions(
        rows, now=NOW, acknowledged_at_by_id=acknowledged
    )

    assert listed == [live]
    assert hidden == 3 and completions == ()


def test_an_open_ask_pins_its_session_into_the_list() -> None:
    """Visibility may not evict a session the daemon is still asking about.

    Live, ``state.asks`` carried an ask for a session ``state.sessions``
    had already dropped: the header counted it and the strip pulsed amber
    while the panel had no row to show.
    """

    ancient = _row("claude:session:5facd783", lifecycle="stale", stale=True, updated_at=NOW - 54 * 60.0)
    aged_completion = _row("claude:session:done", lifecycle="completed", stale=True, updated_at=NOW - 41 * 60.0)

    assert session_visibility(ancient, now=NOW) == HIDDEN
    assert session_visibility(ancient, now=NOW, pinned_ids=("claude:session:5facd783",)) == VISIBLE_LIVE
    # Age is not the only eviction: a receipt is one too, and an ask still wins.
    assert (
        session_visibility(
            aged_completion,
            now=NOW,
            acknowledged_at_by_id={"claude:session:done": NOW},
            pinned_ids=("claude:session:done",),
        )
        == VISIBLE_LIVE
    )
    # Pinning is exact: another session's ask does not rescue this row.
    assert session_visibility(ancient, now=NOW, pinned_ids=("claude:session:other",)) == HIDDEN


def test_pinning_carries_a_worker_and_its_parent_together() -> None:
    parent = _row("claude:session:parent", lifecycle="stale", stale=True, updated_at=NOW - 40 * 60.0)
    worker = _row(
        "claude:agent:asking",
        kind="worker",
        parent="claude:session:parent",
        lifecycle="stale",
        stale=True,
        updated_at=NOW - 40 * 60.0,
    )

    listed, hidden, completions = filter_visible_sessions(
        [parent, worker], now=NOW, pinned_ids=("claude:agent:asking",)
    )

    assert listed == [parent, worker]
    assert hidden == 0 and completions == ()

    # With no ask, both are history, and the worker is not counted twice.
    dropped, hidden_without, _ = filter_visible_sessions([parent, worker], now=NOW)
    assert dropped == [] and hidden_without == 1
