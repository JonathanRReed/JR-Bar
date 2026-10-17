"""Dismissing a stale ask: local, bounded, and never an answer.

An ask that has waited past the "may be stale" mark stays on every surface and
offers one Dismiss. Dismissing it takes that one ask off the Mac's surfaces; it
sends nothing to the agent, because nothing answers an agent on its own. These
tests run the store, the canonical view, the monitor and the ``dismiss_ask``
command on injected clocks.
"""

from __future__ import annotations

import json
import stat
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from jrbar.ask_dismissals import (
    DISMISSAL_RETENTION_SECONDS,
    MAX_DISMISSED_ASKS,
    AskDismissals,
    default_ask_dismissals_path,
    load_ask_dismissals,
    save_ask_dismissals,
)
from jrbar.ask_lifetime import ask_dismissal_key
from jrbar.capacity_types import SourceKey
from jrbar.core_server import CommandError
from jrbar.mailbox import project_canonical_mailbox
from jrbar.models import AgentMode, AgentStatus
from jrbar.operator_state import RequestPhase, apply_ask_dismissals
from jrbar.provider_facts import WorkIdentifier, WorkKey
from tests.test_ask_stays_visible import HOUR, SESSION, _asking_session
from tests.test_core_runtime import _visibility_snapshot, cleared, headless  # noqa: F401

OPENED = 1_800_000_000.0
STALE_AGE = 7 * HOUR


# --- the store --------------------------------------------------------------------


def test_the_store_remembers_a_dismissal_by_session_and_opening_time() -> None:
    store = AskDismissals()
    assert store.add("claude:session:a", OPENED + 0.0004, at=OPENED + 5)
    assert store.keys() == frozenset({("claude:session:a", 1_800_000_000_000)})
    # A later ask on the same session is a different identity.
    assert ask_dismissal_key("claude:session:a", OPENED + 90) not in store.keys()
    assert store.forget("claude:session:a", OPENED)
    assert store.keys() == frozenset()


def test_the_store_refuses_what_it_cannot_key() -> None:
    store = AskDismissals()
    assert not store.add("", OPENED, at=OPENED)
    assert not store.add("claude:session:a", None, at=OPENED)  # type: ignore[arg-type]
    assert not store.add("claude:session:a", OPENED, at=float("nan"))
    assert not store.mark_expired("", "s", at=OPENED)
    assert len(store) == 0


def test_the_store_is_bounded_and_forgets_the_oldest_first() -> None:
    store = AskDismissals()
    for index in range(MAX_DISMISSED_ASKS + 20):
        store.add(f"claude:session:{index}", OPENED + index, at=OPENED + index)
    assert len(store) == MAX_DISMISSED_ASKS
    assert ("claude:session:0", int(OPENED * 1000)) not in store.keys()
    newest = MAX_DISMISSED_ASKS + 19
    assert ask_dismissal_key(f"claude:session:{newest}", OPENED + newest) in store.keys()


def test_old_dismissals_and_expired_marks_age_out() -> None:
    store = AskDismissals()
    store.add("claude:session:a", OPENED, at=OPENED)
    store.mark_expired("claude", "a", at=OPENED)
    assert not store.prune(now=OPENED + DISMISSAL_RETENTION_SECONDS - 1)
    assert store.was_expired("claude", "a")
    assert store.prune(now=OPENED + DISMISSAL_RETENTION_SECONDS + 1)
    assert len(store) == 0 and not store.was_expired("claude", "a")


def test_the_record_survives_a_restart_privately_and_without_content(tmp_path: Path) -> None:
    path = default_ask_dismissals_path(tmp_path / "state")
    store = AskDismissals()
    store.add("claude:session:a", OPENED, at=OPENED + 3)
    store.mark_expired("codex", "b", at=OPENED + 4)
    save_ask_dismissals(path, store)

    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    document = json.loads(path.read_text())
    assert set(document) == {"version", "dismissed", "expired"}
    assert set(document["dismissed"][0]) == {"session", "opened_ms", "dismissed_at"}

    restored = load_ask_dismissals(path)
    assert restored.keys() == store.keys()
    assert restored.was_expired("codex", "b")


def test_a_store_that_does_not_read_is_set_aside_not_trusted(tmp_path: Path) -> None:
    path = tmp_path / "dismissed-asks.json"
    path.write_text("{not json", encoding="utf-8")
    path.chmod(0o600)
    assert len(load_ask_dismissals(path)) == 0
    assert list(tmp_path.glob("dismissed-asks.json.corrupt-*"))
    # And a missing file is simply empty.
    assert len(load_ask_dismissals(tmp_path / "absent.json")) == 0


def test_rows_that_do_not_read_are_left_out_without_costing_the_rest(tmp_path: Path) -> None:
    path = tmp_path / "dismissed-asks.json"
    path.write_text(
        json.dumps(
            {
                "version": 1,
                "dismissed": [
                    {"session": "claude:session:a", "opened_ms": 5, "dismissed_at": 9.0},
                    {"session": "", "opened_ms": 5, "dismissed_at": 9.0},
                    {"session": "claude:session:b", "opened_ms": "soon", "dismissed_at": 9.0},
                    "nonsense",
                ],
            }
        ),
        encoding="utf-8",
    )
    path.chmod(0o600)
    assert load_ask_dismissals(path).keys() == frozenset({("claude:session:a", 5)})


# --- the canonical view and the monitor --------------------------------------------


def _live_dismissal(session) -> frozenset[tuple[str, int]]:
    snapshot = session.snapshot()
    (status,) = [s for s in snapshot.statuses if s.agent_id.endswith(SESSION)]
    (request,) = snapshot.operator_state.requests
    return frozenset({ask_dismissal_key(status.agent_id, request.opened_at_epoch)})


def test_the_monitor_holds_a_dismissed_ask_and_leaves_the_others(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    session.at(3.0 + STALE_AGE)
    session.neighbour_speaks()
    assert len(session.asks()) == 1

    dismissed = _live_dismissal(session)
    session.monitor.dismissed_asks_supplier = lambda: dismissed
    log_before = session.log.read_text()

    assert session.asks() == []
    snapshot = session.snapshot()
    assert [request.phase for request in snapshot.operator_state.requests] == [RequestPhase.STALE_HOLD]
    # The session no longer asks. A quiet row a day-old-hour cold is history
    # like any other idle one, so it leaves the live list with its ask.
    assert not any(
        s.is_hard_ask and s.agent_id.endswith(SESSION)
        for s in (*snapshot.statuses, *snapshot.stale_statuses)
    )
    # The mailbox stops calling it Needs You.
    assert project_canonical_mailbox(snapshot.operator_state).needs_you_count == 0
    # Nothing was written to the agent's side.
    assert session.log.read_text() == log_before

    # A NEW ask on the same session is a different ask and shows.
    session.at(3.0 + STALE_AGE + 60)
    session.ask("pwd")
    assert len(session.asks()) == 1


def test_dismissing_is_pure_a_state_without_the_ask_is_untouched() -> None:
    from jrbar.operator_state import empty_operator_state

    empty = empty_operator_state()
    assert apply_ask_dismissals(empty, frozenset({("claude:session:a", 1)})) is empty
    assert apply_ask_dismissals(empty, frozenset()) is empty


def test_an_ask_that_names_no_request_is_dismissed_by_its_session_and_time() -> None:
    from jrbar.collector import _status_without_dismissed_ask

    asked_at = datetime(2026, 9, 30, 12, 0, tzinfo=timezone.utc)
    status = AgentStatus(
        provider="claude",
        agent_id="claude:session:keyless",
        display_name="keyless",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=asked_at,
        event_name="Elicitation",
        session_id="keyless",
    )
    key = ask_dismissal_key(status.agent_id, asked_at.timestamp())
    assert status.is_hard_ask and status.request_key is None
    quiet = _status_without_dismissed_ask(status, {}, frozenset({key}))
    assert not quiet.is_hard_ask and quiet.mode is AgentMode.IDLE_READY
    # A dismissal for another time, or another session, does not cover it.
    other = frozenset({ask_dismissal_key(status.agent_id, asked_at.timestamp() + 5)})
    assert _status_without_dismissed_ask(status, {}, other) is status
    assert _status_without_dismissed_ask(status, {}, frozenset()) is status


# --- the command -------------------------------------------------------------------


def _ask_status(*, agent_id: str, minutes_ago: float, event_name: str = "PermissionRequest"):
    collected_at = datetime.fromtimestamp(time.time(), tz=timezone.utc)
    return AgentStatus(
        provider="claude",
        agent_id=agent_id,
        display_name=agent_id.rsplit(":", 1)[-1],
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=collected_at - timedelta(minutes=minutes_ago),
        event_name=event_name,
        session_id=agent_id.rsplit(":", 1)[-1],
        work_key=WorkKey(
            SourceKey("claude", "hooks", "local", "agent_events"),
            WorkIdentifier(agent_id.replace(":", ".")),
        ),
    )


@pytest.fixture()
def asking(cleared):  # noqa: F811
    controller = cleared
    old = _ask_status(agent_id="claude:session:old", minutes_ago=7 * 60)
    fresh = _ask_status(agent_id="claude:session:fresh", minutes_ago=5)
    remote = _ask_status(agent_id="remote:studio:claude:session:far", minutes_ago=7 * 60)
    snapshot = _visibility_snapshot(time.time())
    snapshot.statuses = (*snapshot.statuses, old, fresh, remote)
    controller.last_snapshot = snapshot
    controller._core_ask_statuses = lambda: [old, fresh, remote]
    # Anything that could answer an agent: it must never be touched.
    controller.local_answer_surface = MagicMock(name="local_answer_surface")
    controller.answer_handler_registry = MagicMock(name="answer_handler_registry")
    controller._core_publish_state()
    return controller


def _asks(controller) -> list[dict]:
    with controller._core_lock:
        return list((controller._core_documents["state"] or {})["asks"])


def test_a_stale_ask_says_so_and_a_fresh_one_does_not(asking) -> None:
    by_session = {ask["session"]: ask for ask in _asks(asking)}
    assert by_session["claude:session:old"]["stale"] is True
    assert by_session["claude:session:old"]["dismissible"] is True
    assert by_session["claude:session:fresh"]["stale"] is False
    assert by_session["claude:session:fresh"]["dismissible"] is False
    # A mirrored ask is the peer's: stale, but never dismissible here.
    assert by_session["remote:studio:claude:session:far"]["stale"] is True
    assert by_session["remote:studio:claude:session:far"]["dismissible"] is False
    # Stale or not, each is still counted as needing the person.
    with asking._core_lock:
        assert asking._core_documents["state"]["aggregate"]["needs_you"] >= 2


def test_dismiss_ask_records_it_and_answers_nothing(asking, tmp_path: Path) -> None:
    reply = asking._core_dispatch("dismiss_ask", {"session": "claude:session:old"})

    assert reply["session"] == "claude:session:old" and reply["dismissed"] is True
    assert ask_dismissal_key("claude:session:old", reply["opened_at"]) in asking.ask_dismissals.keys()
    assert asking.ask_dismissals_path.exists()
    assert stat.S_IMODE(asking.ask_dismissals_path.stat().st_mode) == 0o600
    # Not an answer: no surface that types, clicks or replies was used.
    assert asking.local_answer_surface.mock_calls == []
    assert asking.answer_handler_registry.mock_calls == []
    # And it survives a restart.
    assert load_ask_dismissals(asking.ask_dismissals_path).keys() == asking.ask_dismissals.keys()


def test_dismiss_ask_refuses_a_fresh_ask_a_remote_ask_and_a_stranger(asking) -> None:
    with pytest.raises(CommandError) as fresh:
        asking._core_dispatch("dismiss_ask", {"session": "claude:session:fresh"})
    assert fresh.value.code == "refused" and "stale" in str(fresh.value)
    with pytest.raises(CommandError) as remote:
        asking._core_dispatch("dismiss_ask", {"session": "remote:studio:claude:session:far"})
    assert remote.value.code == "refused"
    with pytest.raises(CommandError) as stranger:
        asking._core_dispatch("dismiss_ask", {"session": "nope"})
    assert stranger.value.code == "not_found"
    with pytest.raises(CommandError) as quiet:
        asking._core_dispatch("dismiss_ask", {"session": "claude:session:live"})
    assert quiet.value.code == "not_found"
    with pytest.raises(CommandError) as missing:
        asking._core_dispatch("dismiss_ask", {})
    assert missing.value.code == "invalid_args"
    assert len(asking.ask_dismissals) == 0


def test_dismiss_ask_pinned_to_a_replaced_request_is_refused(asking) -> None:
    with pytest.raises(CommandError) as replaced:
        asking._core_dispatch(
            "dismiss_ask", {"session": "claude:session:old", "request": "request:v1:{replaced}"}
        )
    assert replaced.value.code == "stale_request"
