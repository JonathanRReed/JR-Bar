"""An ask that has waited a long time says so, and the strip calms down.

Past the "may be stale" mark (6 hours by default, from a session silent for as
long) an ask is still an ask on every surface: the row stays WAITING, the card
stays answerable where it was, the header still counts it. What changes is that
it says it may be stale, with its age, and the strip keeps the Ask colour but
pulses more slowly. These tests drive the real hook pipeline on an injected
clock and read the projections the surfaces read.
"""

from __future__ import annotations

import re
from dataclasses import replace
from pathlib import Path

import pytest

from jrbar.ask_lifetime import ASK_MAY_BE_STALE_SECONDS, STALE_ASK_PULSE_STRETCH
from jrbar.attention import (
    LifecycleMode,
    mark_stale_asks,
    project_attention,
    regate_actionable_attention,
)
from jrbar.colors import ColorSettings, program_for_projection
from jrbar.core_projection import ask_document, session_document
from jrbar.led_status import LedDisplayState
from jrbar.operator_state import RequestPhase
from jrbar.settings import AgentMonitorSettings, settings_from_data
from tests.test_ask_stays_visible import HOUR, MINUTE, NEIGHBOUR, SESSION, START, _asking_session

ASKED_AT = START.timestamp() + 3.0


def _projection(session, now_offset: float):
    session.at(now_offset)
    snapshot = session.snapshot()
    live = frozenset(
        request.key
        for request in snapshot.operator_state.requests
        if request.phase in {RequestPhase.LIVE_UNACKNOWLEDGED, RequestPhase.LIVE_ACKNOWLEDGED}
    )
    return snapshot, regate_actionable_attention(
        project_attention(snapshot, AgentMonitorSettings()), live
    )


def _stale_marked(projection, now_epoch: float, **kwargs):
    return mark_stale_asks(projection, now_epoch=now_epoch, **kwargs)


def _hex_tokens(program: str) -> list[str]:
    return re.findall(r"#[0-9A-Fa-f]{6}", program)


def _durations(program: str) -> list[float]:
    values = []
    for number, unit in re.findall(r"(?<![0-9A-Za-z.#])(\d+(?:\.\d+)?)(ms|s)\b", program):
        values.append(float(number) / (1000.0 if unit == "ms" else 1.0))
    return values


@pytest.mark.parametrize(
    ("age", "stale"),
    [
        (5 * MINUTE, False),
        (59 * MINUTE, False),
        (61 * MINUTE, False),
        (6 * HOUR - 60, False),
        (6 * HOUR + 60, True),
        (3 * 86_400.0, True),
    ],
)
def test_a_row_is_flagged_past_the_mark_and_still_an_ask(age: float, stale: bool, tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    snapshot, projection = _projection(session, 3.0 + age)
    marked = _stale_marked(projection, ASKED_AT + age)

    (row,) = [r for r in marked.actionable_attention if r.agent_id.endswith(SESSION)]
    assert row.ask_may_be_stale is stale
    # Whatever its age: still WAITING, still actionable, still counted.
    assert row.actionable and row.lifecycle_mode is LifecycleMode.WAITING
    assert marked.lifecycle_mode is LifecycleMode.WAITING
    (visible,) = [r for r in marked.visible_rows if r.agent_id.endswith(SESSION)]
    assert visible.ask_may_be_stale is stale


def test_flagging_changes_nothing_when_nothing_is_stale(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    _snapshot, projection = _projection(session, 3.0 + 10 * MINUTE)
    assert _stale_marked(projection, ASKED_AT + 10 * MINUTE) is projection
    assert mark_stale_asks(object(), now_epoch=ASKED_AT) is not None  # type: ignore[arg-type]


def test_the_mark_is_configurable(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    _snapshot, projection = _projection(session, 3.0 + 2 * HOUR)
    default = _stale_marked(projection, ASKED_AT + 2 * HOUR)
    assert not any(r.ask_may_be_stale for r in default.visible_rows)
    sooner = _stale_marked(projection, ASKED_AT + 2 * HOUR, stale_after_seconds=HOUR)
    assert any(r.ask_may_be_stale for r in sooner.visible_rows)


def test_an_ask_document_says_it_may_be_stale_and_offers_dismiss(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    snapshot, _projection_ = _projection(session, 3.0 + 7 * HOUR)
    (status,) = [s for s in snapshot.statuses if s.agent_id.endswith(SESSION)]

    def document(age: float, **kwargs) -> dict:
        return ask_document(
            status,
            snapshot.operator_state,
            with_session=True,
            now=ASKED_AT + age,
            **kwargs,
        )

    fresh = document(30 * MINUTE)
    assert (fresh["stale"], fresh["dismissible"]) == (False, False)
    stale = document(7 * HOUR)
    assert (stale["stale"], stale["dismissible"]) == (True, True)
    assert stale["opened_at"] == pytest.approx(ASKED_AT)
    assert stale["last_activity_at"] == pytest.approx(ASKED_AT)
    # A running process does not un-stale it; it only stops it being closed.
    assert document(7 * HOUR, process_alive=True)["stale"] is True
    # The configured mark applies.
    assert document(2 * HOUR, stale_after_seconds=HOUR)["stale"] is True
    # A caller with no clock says nothing is stale rather than guessing.
    unclocked = ask_document(status, snapshot.operator_state, with_session=True)
    assert unclocked["stale"] is False and unclocked["dismissible"] is False
    # It is still answerable where it was, however old.
    assert stale["kind"] == fresh["kind"] and stale["answerable"] == fresh["answerable"]


def test_the_session_row_carries_the_same_word_as_the_ask_list(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    snapshot, _p = _projection(session, 3.0 + 7 * HOUR)
    (status,) = [s for s in snapshot.statuses if s.agent_id.endswith(SESSION)]
    row = session_document(
        status,
        operator_state=snapshot.operator_state,
        ask_ids=frozenset({status.agent_id}),
        extras=None,
        workers=0,
        now=ASKED_AT + 7 * HOUR,
    )
    listed = ask_document(status, snapshot.operator_state, with_session=True, now=ASKED_AT + 7 * HOUR)
    assert row["ask"]["stale"] is True and listed["stale"] is True
    assert row["ask"]["opened_at"] == listed["opened_at"]
    assert row["mode"] == "waiting_for_input"


# --- the strip ---------------------------------------------------------------------


def _strip(projection):
    return program_for_projection(projection, colors=ColorSettings.defaults(), led_count=8)


def test_a_stale_ask_keeps_the_ask_colour_and_pulses_more_calmly(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    _snapshot, projection = _projection(session, 3.0 + 7 * HOUR)
    # The neighbour's UserPromptSubmit is not in this session: only the ask lights.
    fresh_state, fresh_program = _strip(projection)
    stale_state, stale_program = _strip(_stale_marked(projection, ASKED_AT + 7 * HOUR))

    assert fresh_state is stale_state is LedDisplayState.ASK
    assert _hex_tokens(stale_program) == _hex_tokens(fresh_program)
    assert _hex_tokens(fresh_program), "the ask program has a colour"
    slower = [
        pytest.approx(old * STALE_ASK_PULSE_STRETCH, rel=0.01)
        for old in _durations(fresh_program)
    ]
    assert _durations(stale_program) == slower
    assert stale_program != fresh_program


def test_a_fresh_ask_alongside_a_stale_one_keeps_the_normal_tempo(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    session.at(3.0 + 7 * HOUR)
    session.send("UserPromptSubmit", session=NEIGHBOUR, prompt="hello")
    session.send("PermissionRequest", session=NEIGHBOUR, tool_name="Bash", tool_input={"command": "ls"})
    _snapshot, projection = _projection(session, 3.0 + 7 * HOUR)
    marked = _stale_marked(projection, ASKED_AT + 7 * HOUR)
    flags = {row.agent_id.rsplit(":", 1)[-1]: row.ask_may_be_stale for row in marked.visible_rows}
    assert flags == {SESSION: True, NEIGHBOUR: False}

    _state, calm = _strip(marked)
    _state, normal = _strip(replace(marked, visible_rows=tuple(replace(r, ask_may_be_stale=False) for r in marked.visible_rows)))
    assert calm == normal


def test_working_agents_beside_a_stale_ask_keep_their_tempo(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    session.at(3.0 + 7 * HOUR)
    session.send("UserPromptSubmit", session=NEIGHBOUR, prompt="hello")
    _snapshot, projection = _projection(session, 3.0 + 7 * HOUR)
    marked = _stale_marked(projection, ASKED_AT + 7 * HOUR)
    unmarked = replace(
        marked, visible_rows=tuple(replace(r, ask_may_be_stale=False) for r in marked.visible_rows)
    )
    assert _strip(marked) == _strip(unmarked)


# --- the settings -------------------------------------------------------------------


def test_the_two_clocks_are_settings_with_the_documented_defaults() -> None:
    document = AgentMonitorSettings().to_dict()
    assert document["ask_stale_after_hours"] == ASK_MAY_BE_STALE_SECONDS / 3600.0 == 6.0
    assert document["ask_expire_after_days"] == 7.0


def test_the_settings_round_trip_and_are_held_to_their_bounds() -> None:
    document = AgentMonitorSettings().to_dict()
    loaded = settings_from_data({**document, "ask_stale_after_hours": 12, "ask_expire_after_days": 14})
    assert (loaded.ask_stale_after_hours, loaded.ask_expire_after_days) == (12.0, 14.0)
    assert loaded.to_dict()["ask_stale_after_hours"] == 12.0

    silly = settings_from_data({**document, "ask_stale_after_hours": -3, "ask_expire_after_days": "never"})
    assert silly.ask_stale_after_hours == 0.25  # a pause is not stale
    assert silly.ask_expire_after_days == 7.0

    # The expiry is never before the mark.
    odd = settings_from_data({**document, "ask_stale_after_hours": 72, "ask_expire_after_days": 1})
    assert odd.ask_expire_after_days >= odd.ask_stale_after_hours / 24.0
