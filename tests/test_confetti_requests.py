"""``confetti`` from outside JR-Bar: which session the caller means, whose
colours the burst wears, and the journal's guard against a loop."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from jrbar.confetti_requests import (
    CONFETTI_COALESCE_SECONDS,
    MAX_CONFETTI_REASON,
    ConfettiGate,
    match_session,
    resolve_confetti_request,
)


def _status(agent_id: str, provider: str, session_id: str, name: str) -> SimpleNamespace:
    return SimpleNamespace(agent_id=agent_id, provider=provider, session_id=session_id, display_name=name)


MAIN = _status("claude:session:abc", "claude", "abc", "jr-bar-b7")
WORKER = _status("claude:agent:w1", "claude", "abc", "Explore")
CODEX = _status("codex:session:xyz", "codex", "xyz", "sidepulse-core")
STATUSES = (WORKER, MAIN, CODEX)


def test_the_daemons_own_id_names_the_row_exactly() -> None:
    assert match_session("claude:agent:w1", STATUSES) is WORKER
    assert match_session("codex:session:xyz", STATUSES) is CODEX


def test_a_hooks_session_id_names_its_main_row_before_any_worker() -> None:
    # A Stop hook carries the agent's own session_id: the run that stopped
    # is the session, even though its worker shares the id and comes first.
    assert match_session("abc", STATUSES) is MAIN
    orphan = _status("claude:agent:w2", "claude", "lonely", "worker")
    assert match_session("lonely", (orphan,)) is orphan
    assert match_session("nobody", STATUSES) is None


def test_the_burst_wears_the_sessions_provider_unless_one_is_named() -> None:
    request = resolve_confetti_request({"session": "abc", "reason": "  tests   passed "}, STATUSES)
    assert request.session == "claude:session:abc"
    assert request.provider == "claude"
    assert request.event_fields() == {
        "session": "claude:session:abc",
        "provider": "claude",
        "label": "jr-bar-b7",
        "detail": "tests passed",
    }
    named = resolve_confetti_request({"session": "abc", "provider": " Codex "}, STATUSES)
    assert named.provider == "codex" and named.session == "claude:session:abc"


def test_a_session_nobody_watches_still_celebrates_in_the_toys_colour() -> None:
    request = resolve_confetti_request({"session": "ghost"}, STATUSES)
    assert request.session is None and request.provider is None
    assert request.unmatched == "ghost"
    assert request.event_fields() == {}


def test_a_bare_ask_and_a_provider_only_ask() -> None:
    assert resolve_confetti_request({}, ()).event_fields() == {}
    assert resolve_confetti_request({"provider": "gemini"}, ()).event_fields() == {"provider": "gemini"}
    assert resolve_confetti_request({"provider": "", "session": "  "}, STATUSES).event_fields() == {}


def test_bad_arguments_are_refused_whole() -> None:
    for args in (
        {"provider": "not a provider"},
        {"provider": 3},
        {"session": ["abc"]},
        {"session": "x" * 600},
        {"reason": 7},
        {"reason": "bell\x07"},
    ):
        with pytest.raises(ValueError):
            resolve_confetti_request(args, STATUSES)
    long = resolve_confetti_request({"reason": "y" * 500}, ())
    assert len(long.reason) == MAX_CONFETTI_REASON


def test_the_gate_lets_one_burst_through_per_window() -> None:
    gate = ConfettiGate()
    assert gate.admit(100.0)
    assert not gate.admit(100.5)
    assert not gate.admit(100.0 + CONFETTI_COALESCE_SECONDS - 0.01)
    assert gate.admit(100.0 + CONFETTI_COALESCE_SECONDS)
    # A clock that runs backwards (a test harness, a reset) never wedges it.
    assert gate.admit(50.0)
