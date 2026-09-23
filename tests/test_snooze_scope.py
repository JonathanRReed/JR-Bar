"""Snooze scope: lights and notifications, with the raised-hand override."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from jrbar.capacity_types import SourceKey
from jrbar.mailbox_preferences import (
    LegacyMailboxPreference,
    MailboxPreference,
    MailboxPreferenceMode,
    MailboxSnoozeScope,
)
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import WorkIdentifier, WorkKey
from jrbar.snooze_scope import (
    active_snooze_until,
    filter_snoozed_statuses,
    run_agent_ids,
    status_snoozed,
    with_run_snooze,
    without_run_snooze,
)

NOW = 1_787_000_000.0


def _work_key(provider: str, work_id: str) -> WorkKey:
    return WorkKey(
        SourceKey(provider, "hooks", "default", "live_agent_events"),
        WorkIdentifier(work_id),
    )


def _status(
    agent_id: str,
    mode: AgentMode,
    *,
    event_name: str = "PostToolUse",
    work_key: WorkKey | None = None,
    session_id: str | None = None,
    provider: str = "codex",
) -> AgentStatus:
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name=agent_id,
        mode=mode,
        updated_at=datetime.fromtimestamp(NOW, timezone.utc),
        event_name=event_name,
        session_id=session_id,
        work_key=work_key,
    )


def _snooze(work_key: WorkKey, *, until: float = NOW + 900.0) -> MailboxPreference:
    return MailboxPreference(work_key, snoozed_at=NOW - 60.0, snoozed_until=until)


def test_snoozed_working_session_is_filtered__and_2_more() -> None:
    # --- scenario: snoozed_working_session_is_filtered
    key = _work_key("codex", "main")
    working = _status("codex:session:main", AgentMode.WORKING, work_key=key, session_id="main")
    other = _status("claude:session:other", AgentMode.WORKING, provider="claude", session_id="other")

    kept = filter_snoozed_statuses((working, other), (_snooze(key),), now=NOW)
    assert kept == (other,)
    assert status_snoozed(working, (_snooze(key),), now=NOW)
    assert not status_snoozed(other, (_snooze(key),), now=NOW)

    # --- scenario: live_hard_ask_breaks_through_a_snooze
    key = _work_key("codex", "main")
    ask = _status(
        "codex:session:main",
        AgentMode.WAITING_FOR_INPUT,
        event_name="PermissionRequest",
        work_key=key,
        session_id="main",
    )
    kept = filter_snoozed_statuses((ask,), (_snooze(key),), now=NOW)
    assert kept == (ask,)
    assert not status_snoozed(ask, (_snooze(key),), now=NOW)

    # --- scenario: expired_snooze_no_longer_silences
    key = _work_key("codex", "main")
    working = _status("codex:session:main", AgentMode.WORKING, work_key=key, session_id="main")
    expired = MailboxPreference(key, snoozed_at=NOW - 7_200.0, snoozed_until=NOW - 3_600.0)
    kept = filter_snoozed_statuses((working,), (expired,), now=NOW)
    assert kept == (working,)



def test_family_snooze_covers_a_worker_via_its_session_id__and_2_more() -> None:
    # --- scenario: family_snooze_covers_a_worker_via_its_session_id
    family = _work_key("codex", "main")
    worker = _status(
        "codex:agent:w1",
        AgentMode.WORKING,
        work_key=_work_key("codex", "w1"),
        session_id="main",
    )
    kept = filter_snoozed_statuses((worker,), (_snooze(family),), now=NOW)
    assert kept == ()

    # --- scenario: legacy_agent_id_preferences_still_silence
    working = _status("codex:session:main", AgentMode.WORKING, session_id="main")
    legacy = LegacyMailboxPreference(
        "codex:session:main",
        snoozed_at=NOW - 60.0,
        snoozed_until=NOW + 600.0,
    )
    assert filter_snoozed_statuses((working,), (legacy,), now=NOW) == ()

    # --- scenario: unfiltered_input_returns_the_original_tuple_object
    statuses = (_status("codex:session:main", AgentMode.WORKING, session_id="main"),)
    assert filter_snoozed_statuses(statuses, (), now=NOW) is statuses
    other = _snooze(_work_key("claude", "elsewhere"))
    assert filter_snoozed_statuses(statuses, (other,), now=NOW) is statuses


def _run_snooze(work_key: WorkKey, *, until: float = NOW + 900.0) -> MailboxPreference:
    return MailboxPreference(
        work_key, snoozed_at=NOW - 60.0, snoozed_until=until, snooze_scope=MailboxSnoozeScope.RUN
    )


def _family() -> tuple[WorkKey, WorkKey, AgentStatus, AgentStatus, AgentStatus]:
    root, w1 = _work_key("claude", "main"), _work_key("claude", "w1")
    main = _status("claude:session:main", AgentMode.WORKING, work_key=root, session_id="main", provider="claude")
    worker = _status("claude:agent:w1", AgentMode.WORKING, work_key=w1, session_id="main", provider="claude")
    sibling = _status(
        "claude:agent:w2", AgentMode.WORKING, work_key=_work_key("claude", "w2"), session_id="main", provider="claude"
    )
    return root, w1, main, worker, sibling


def test_quieting_one_worker_leaves_its_session_and_siblings_speaking() -> None:
    _root, w1, main, worker, sibling = _family()
    quiet = (_run_snooze(w1),)
    assert filter_snoozed_statuses((main, worker, sibling), quiet, now=NOW) == (main, sibling)
    assert status_snoozed(worker, quiet, now=NOW)
    assert not status_snoozed(main, quiet, now=NOW)


def test_quieting_the_main_run_leaves_its_workers_speaking() -> None:
    root, _w1, main, worker, sibling = _family()
    # The family snooze on the same key covers the lot; the run's covers one.
    assert filter_snoozed_statuses((main, worker, sibling), (_snooze(root),), now=NOW) == ()
    assert filter_snoozed_statuses((main, worker, sibling), (_run_snooze(root),), now=NOW) == (worker, sibling)


def test_a_run_snooze_covers_a_keyless_row_of_the_same_run_and_lets_an_ask_through() -> None:
    _root, w1, _main, _worker, _sibling = _family()
    assert run_agent_ids(w1) == ("claude:session:w1", "claude:agent:w1")
    legacy_row = _status("claude:agent:w1", AgentMode.WORKING, session_id="main", provider="claude")
    assert status_snoozed(legacy_row, (_run_snooze(w1),), now=NOW)
    asking = _status(
        "claude:agent:w1", AgentMode.WAITING_FOR_INPUT, event_name="PermissionRequest",
        work_key=w1, session_id="main", provider="claude",
    )
    assert not status_snoozed(asking, (_run_snooze(w1),), now=NOW)
    assert not status_snoozed(legacy_row, (_run_snooze(w1, until=NOW - 1.0),), now=NOW)


def test_with_run_snooze_sets_one_rows_quiet_and_prunes_lapsed_runs() -> None:
    root, w1, *_ = _family()
    stale_worker = MailboxPreference(
        _work_key("claude", "gone"), snoozed_at=NOW - 7_200.0, snoozed_until=NOW - 60.0,
        snooze_scope=MailboxSnoozeScope.RUN,
    )
    pinned_root = MailboxPreference(
        root, MailboxPreferenceMode.PINNED, 0, NOW - 7_200.0, NOW - 60.0, None, MailboxSnoozeScope.RUN
    )
    updated = with_run_snooze((stale_worker, pinned_root), w1, now=NOW, until=NOW + 3_600.0)
    by_key = {item.work_key: item for item in updated}
    assert _work_key("claude", "gone") not in by_key, "a lapsed worker quiet keeps nothing"
    assert by_key[root] == MailboxPreference(root, MailboxPreferenceMode.PINNED, 0), "the pin outlives it"
    assert by_key[w1].snooze_scope is MailboxSnoozeScope.RUN
    assert active_snooze_until(by_key[w1], NOW) == NOW + 3_600.0
    with pytest.raises(ValueError):
        with_run_snooze((), w1, now=NOW, until=NOW)


def test_a_family_snooze_on_the_key_is_never_traded_for_a_narrower_one() -> None:
    root, *_ = _family()
    family = (_snooze(root, until=NOW + 7_200.0),)
    assert with_run_snooze(family, root, now=NOW, until=NOW + 900.0) == family
    # Even for longer: the run's quiet would wake the rest of the family.
    assert with_run_snooze(family, root, now=NOW, until=NOW + 9_000.0) == family
    lapsed = (_snooze(root, until=NOW - 1.0),)
    assert with_run_snooze(lapsed, root, now=NOW, until=NOW + 900.0)[0].snooze_scope is MailboxSnoozeScope.RUN


def test_without_run_snooze_lifts_only_a_runs_own_quiet() -> None:
    root, w1, *_ = _family()
    family = _snooze(root)
    assert without_run_snooze((family, _run_snooze(w1)), w1, now=NOW) == (family,)
    assert without_run_snooze((family,), root, now=NOW) == (family,), "the family's to lift"
    watched = MailboxPreference(
        root, MailboxPreferenceMode.WATCHED, None, NOW - 60.0, NOW + 900.0, None, MailboxSnoozeScope.RUN
    )
    assert without_run_snooze((watched,), root, now=NOW) == (
        MailboxPreference(root, MailboxPreferenceMode.WATCHED),
    )

