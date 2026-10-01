"""A quiet sub-agent is counted on its parent row, and a worker's ask is a real
ask when worker asks are on.

``sessions[].workers_waiting`` is the honest counterpart of the quiet default:
with ``subagent_asks_alert`` off a sub-agent's permission prompt raises no
light, sound, banner or card, so the parent row says in words that a worker is
waiting. It is information only. With the setting on the same request is an
ordinary ask: ``asks`` carries it and ``aggregate.needs_you`` counts it.
Synthetic ids only.
"""

from __future__ import annotations

import re
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

from jrbar import core_runtime
from jrbar.attention import project_attention, quiet_waiting_worker_ids, quiet_worker_request_keys
from jrbar.core_projection import aggregate_counts, aggregate_mode, build_state_document
from jrbar.models import AgentMode
from jrbar.operator_state import RequestPhase
from jrbar.provider_facts import RequestIdentifier, RequestKey, SourceKey, WorkIdentifier, WorkKey
from jrbar.settings import AgentMonitorSettings
from tests.test_attention import _canonical_permission_request_snapshot
from tests.test_core_projection import CLAUDE_ID, CLAUDE_SID, CLAUDE_WORKER_ID, NOW, _at, _status
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)

DOC = Path(__file__).resolve().parents[1] / "docs" / "CORE-PROTOCOL.md"
SECOND_WORKER_ID = f"claude:agent:{CLAUDE_SID}-worker-2"
THIRD_WORKER_ID = f"claude:agent:{CLAUDE_SID}-worker-3"
COLLECTED_AT = datetime.fromtimestamp(NOW, tz=timezone.utc)


def _main(**overrides):
    return _status(**overrides)


def _worker(agent_id: str = CLAUDE_WORKER_ID, *, waiting: bool, **overrides):
    fields = dict(
        agent_id=agent_id,
        display_name="worker",
        mode=AgentMode.WAITING_FOR_INPUT if waiting else AgentMode.WORKING,
        event_name="PermissionRequest" if waiting else "PreToolUse",
        updated_at=_at(2.0),
        message="Run: make build" if waiting else None,
        tool_name=None,
        work_key=f"wk-{agent_id.rsplit(':', 1)[-1]}",
    )
    fields.update(overrides)
    return _status(**fields)


def _snapshot(*statuses, stale=()):
    return SimpleNamespace(
        aggregate=SimpleNamespace(mode=AgentMode.WORKING),
        statuses=tuple(statuses),
        stale_statuses=tuple(stale),
        collected_at=COLLECTED_AT,
    )


def _document(statuses, *, ask_statuses=(), **extra):
    return build_state_document(
        now=NOW,
        generation=1,
        snapshot=_snapshot(*statuses),
        ask_statuses=list(ask_statuses),
        unseen_completion_ids=frozenset(),
        **extra,
    )


def _row(document, session_id):
    return next(row for row in document["sessions"] if row["id"] == session_id)


# --- the fact, from the projection ------------------------------------------


def test_a_main_row_counts_its_workers_that_wait_quietly() -> None:
    statuses = (
        _main(),
        _worker(CLAUDE_WORKER_ID, waiting=True),
        _worker(SECOND_WORKER_ID, waiting=False),
    )

    document = _document(statuses, quiet_worker_ids=frozenset({CLAUDE_WORKER_ID}))

    main = _row(document, CLAUDE_ID)
    assert main["workers"] == 2
    assert main["workers_waiting"] == 1
    # Only a main row carries it.
    assert "workers_waiting" not in _row(document, CLAUDE_WORKER_ID)
    assert "workers_waiting" not in _row(document, SECOND_WORKER_ID)


def test_a_quiet_waiting_worker_earns_no_ask_no_count_and_no_header_word() -> None:
    statuses = (_main(), _worker(CLAUDE_WORKER_ID, waiting=True))

    document = _document(statuses, quiet_worker_ids=frozenset({CLAUDE_WORKER_ID}))

    assert document["asks"] == []
    assert _row(document, CLAUDE_ID)["ask"] is None
    assert _row(document, CLAUDE_WORKER_ID)["ask"] is None
    assert document["aggregate"]["needs_you"] == 0
    assert document["aggregate"]["mode"] == "working"


def test_the_count_is_zero_for_a_known_quiet_set_with_no_waiters_and_absent_when_unknown() -> None:
    statuses = (_main(), _worker(CLAUDE_WORKER_ID, waiting=False))

    known = _document(statuses, quiet_worker_ids=frozenset())
    unknown = _document(statuses)

    assert _row(known, CLAUDE_ID)["workers_waiting"] == 0
    # Absent means the caller could not say; a client shows nothing for it.
    assert "workers_waiting" not in _row(unknown, CLAUDE_ID)


def test_a_stale_worker_is_not_waiting_and_a_waiter_never_exceeds_the_workers() -> None:
    live = _worker(CLAUDE_WORKER_ID, waiting=True)
    gone = _worker(SECOND_WORKER_ID, waiting=True, stale=True)
    snapshot = _snapshot(_main(), live, stale=(gone,))

    document = build_state_document(
        now=NOW,
        generation=1,
        snapshot=snapshot,
        ask_statuses=[],
        unseen_completion_ids=frozenset(),
        quiet_worker_ids=frozenset({CLAUDE_WORKER_ID, SECOND_WORKER_ID}),
    )

    main = _row(document, CLAUDE_ID)
    assert (main["workers"], main["workers_waiting"]) == (1, 1)
    assert main["workers_waiting"] <= main["workers"]


def test_two_builds_of_the_same_quiet_world_are_one_frame() -> None:
    statuses = (_main(), _worker(CLAUDE_WORKER_ID, waiting=True))
    quiet = frozenset({CLAUDE_WORKER_ID})

    first = _document(statuses, quiet_worker_ids=quiet)
    later = build_state_document(
        now=NOW + 15.0,
        generation=2,
        snapshot=_snapshot(*statuses),
        ask_statuses=[],
        unseen_completion_ids=frozenset(),
        quiet_worker_ids=quiet,
    )

    assert core_runtime.doc_significant_equal("state", first, later)
    # A worker's request opening is the one change that earns a frame.
    opened = _document((_main(), _worker(CLAUDE_WORKER_ID, waiting=True)), quiet_worker_ids=frozenset())
    assert not core_runtime.doc_significant_equal("state", first, opened)


# --- which workers are quiet -------------------------------------------------


def test_only_a_worker_with_a_hard_ask_is_quiet_and_only_while_the_setting_is_off() -> None:
    waiting = _worker(CLAUDE_WORKER_ID, waiting=True)
    busy = _worker(SECOND_WORKER_ID, waiting=False)
    main_asking = _main(mode=AgentMode.WAITING_FOR_INPUT, event_name="PermissionRequest")
    off = AgentMonitorSettings()
    on = replace(off, subagent_asks_alert=True)

    assert quiet_waiting_worker_ids((main_asking, waiting, busy), off) == frozenset({CLAUDE_WORKER_ID})
    assert quiet_waiting_worker_ids((main_asking, waiting, busy), on) == frozenset()


def test_a_stale_worker_or_one_the_state_no_longer_holds_live_is_not_quiet_waiting() -> None:
    settings = AgentMonitorSettings()
    request = RequestKey(
        WorkKey(SourceKey("claude", "native", "account-a", "threads"), WorkIdentifier("worker-1")),
        RequestIdentifier("request-1"),
    )
    keyed = _worker(CLAUDE_WORKER_ID, waiting=True, request_key=request)
    stale = _worker(SECOND_WORKER_ID, waiting=True, stale=True)

    # No canonical state yet (None): the status's own word stands.
    assert quiet_waiting_worker_ids((keyed, stale), settings, live_request_keys=None) == frozenset({CLAUDE_WORKER_ID})
    # The state holds the request live: still quiet.
    assert quiet_waiting_worker_ids((keyed,), settings, live_request_keys=frozenset({request})) == frozenset({CLAUDE_WORKER_ID})
    # The state moved the request on (resolved, stale hold): nothing is waiting.
    assert quiet_waiting_worker_ids((keyed,), settings, live_request_keys=frozenset()) == frozenset()


def test_the_two_definitions_of_quiet_agree_on_a_real_canonical_snapshot() -> None:
    """``quiet_waiting_worker_ids`` reads the status (``is_subagent``) and
    ``quiet_worker_request_keys`` reads the canonical work (``parent_key``).
    Carried through the real ingest path they name the same request."""
    worker = _canonical_permission_request_snapshot(session_id="session:main", agent_id="agent:worker")
    main = _canonical_permission_request_snapshot(session_id="session:main", agent_id=None)

    for name, snapshot in (("worker", worker), ("main", main)):
        live = frozenset(request.key for request in snapshot.operator_state.requests)
        for alert in (False, True):
            settings = replace(AgentMonitorSettings(), subagent_asks_alert=alert)
            ids = quiet_waiting_worker_ids(snapshot.statuses, settings, live_request_keys=live)
            keys = quiet_worker_request_keys(snapshot.operator_state, subagent_asks_alert=alert)
            expected = name == "worker" and not alert
            label = f"{name}, worker asks {'on' if alert else 'off'}"

            assert bool(ids) == expected, label
            assert bool(keys) == expected, label
            # The same request: each quiet status holds one of the quiet keys.
            held = {status.request_key for status in snapshot.statuses if status.agent_id in ids}
            assert held == set(keys), label
            # Without the canonical live set the status's own word gives the same answer.
            assert quiet_waiting_worker_ids(snapshot.statuses, settings) == ids, label


# --- the setting on: a worker's ask is a real ask ----------------------------


def test_a_workers_ask_counts_as_needs_you_when_worker_asks_are_on() -> None:
    worker = _worker(CLAUDE_WORKER_ID, waiting=True)
    statuses = (_main(), worker)

    document = _document(statuses, ask_statuses=[worker], quiet_worker_ids=frozenset())

    assert [ask["session"] for ask in document["asks"]] == [CLAUDE_WORKER_ID]
    assert document["aggregate"]["needs_you"] == 1
    assert document["aggregate"]["mode"] == "needs_you"
    # The worker's row is listed with its ask, so the count has a row behind it.
    assert _row(document, CLAUDE_WORKER_ID)["ask"]["kind"] in {"permission", "approval"}
    # The parent row still says nothing is quietly waiting.
    assert _row(document, CLAUDE_ID)["workers_waiting"] == 0
    # `total` stays a count of main sessions.
    assert document["aggregate"]["total"] == 1


def test_needs_you_counts_every_ask_whichever_listed_session_it_names() -> None:
    sessions = [
        {"id": "claude:session:a", "kind": "main", "mode": "waiting_for_input"},
        {"id": "claude:agent:b", "kind": "worker", "parent": "claude:session:a", "mode": "waiting_for_input"},
    ]
    asks = [{"session": "claude:session:a"}, {"session": "claude:agent:b"}, {"session": "claude:session:gone"}]

    counts = aggregate_counts(sessions, asks=asks)

    assert counts["needs_you"] == 2
    assert counts["total"] == 1
    assert aggregate_mode(counts) == "needs_you"


# --- the daemon wires both ---------------------------------------------------


def _feed(controller, *statuses) -> None:
    controller.last_snapshot = _snapshot(*statuses)
    controller.current_attention_projection = project_attention(controller.last_snapshot, controller.settings)


def test_the_daemon_publishes_the_quiet_count_and_the_on_state_ask(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    main = _main()
    worker = _worker(CLAUDE_WORKER_ID, waiting=True)
    other = _worker(SECOND_WORKER_ID, waiting=False)

    # Off, the default: the worker is counted on its parent, and nowhere else.
    assert controller.settings.subagent_asks_alert is False
    _feed(controller, main, worker, other)
    off = controller._core_build_state()
    assert _row(off, CLAUDE_ID)["workers"] == 2
    assert _row(off, CLAUDE_ID)["workers_waiting"] == 1
    assert off["asks"] == []
    assert off["aggregate"]["needs_you"] == 0
    assert off["aggregate"]["mode"] == "working"

    # On: the same request is an ordinary ask, counted and listed.
    controller.settings = replace(controller.settings, subagent_asks_alert=True)
    _feed(controller, main, worker, other)
    on = controller._core_build_state()
    assert _row(on, CLAUDE_ID)["workers_waiting"] == 0
    assert [ask["session"] for ask in on["asks"]] == [CLAUDE_WORKER_ID]
    assert on["aggregate"]["needs_you"] == 1
    assert on["aggregate"]["mode"] == "needs_you"


def test_a_request_the_state_has_resolved_is_no_longer_a_waiting_worker(headless) -> None:  # noqa: F811
    """The runtime hands the helper the canonical live request keys, so a
    worker whose request the reducer resolved stops counting even while its
    status still reads waiting."""
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    canonical = _canonical_permission_request_snapshot(session_id="session:main", agent_id="agent:worker")
    worker = canonical.statuses[0]
    assert worker.is_subagent and worker.is_hard_ask and worker.request_key is not None
    parent = _main(agent_id=worker.parent_agent_id, session_id="session:main", work_key="wk-parent")
    state = canonical.operator_state

    def count() -> int:
        return _row(controller._core_build_state(), parent.agent_id)["workers_waiting"]

    _feed(controller, parent, worker)
    # No canonical state yet: the status's own word stands.
    controller.current_operator_state = None
    assert count() == 1
    # The state holds the request live: still waiting, quietly.
    controller.current_operator_state = state
    assert count() == 1
    # The state resolved it; the status has not caught up.
    resolved = replace(
        state,
        requests=tuple(replace(request, phase=RequestPhase.RESOLVED) for request in state.requests),
    )
    controller.current_operator_state = resolved
    assert count() == 0


def test_a_failure_to_count_is_logged_once_and_leaves_the_rows_without_a_count(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    lines: list[str] = []
    controller._core_log = lines.append
    _feed(controller, _main(), _worker(CLAUDE_WORKER_ID, waiting=True))

    def broken():
        raise RuntimeError("synthetic failure")

    controller._live_actionable_request_keys = broken
    for _ in range(2):
        document = controller._core_build_state()
        # Unknown, not zero: the key is absent.
        assert "workers_waiting" not in _row(document, CLAUDE_ID)
        assert document["asks"] == []
    assert [line for line in lines if "workers_waiting" in line] == [
        "core: workers_waiting unavailable: RuntimeError"
    ]

    # Recovered: the count is back, and a later failure is logged again.
    controller._live_actionable_request_keys = lambda: None
    assert _row(controller._core_build_state(), CLAUDE_ID)["workers_waiting"] == 1
    controller._live_actionable_request_keys = broken
    controller._core_build_state()
    assert len([line for line in lines if "workers_waiting" in line]) == 2


def test_the_roster_rows_carry_the_same_quiet_count(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    _feed(controller, _main(), _worker(CLAUDE_WORKER_ID, waiting=True))

    roster = core_runtime._roster_document(
        controller, scope="all", provider=None, parent=None, since=None, limit=50
    )
    rows = {row["id"]: row for row in roster["sessions"]}
    assert rows[CLAUDE_ID]["workers_waiting"] == 1
    assert "workers_waiting" not in rows[CLAUDE_WORKER_ID]


# --- the contract names it ---------------------------------------------------


def test_the_protocol_doc_names_the_new_key_and_the_worker_ask_rule() -> None:
    doc = DOC.read_text(encoding="utf-8")
    state = doc[doc.index("### state (full)"):]
    state = state[: state.find("\n### ", 10)]

    assert re.search(r"`workers_waiting`", state), "the state section never names workers_waiting"
    assert '"workers_waiting":0' in state, "the state example carries no workers_waiting"
    assert "never makes a state frame differ on its own" in state
    assert "`needs_you` is the number of asks in `asks`" in state
