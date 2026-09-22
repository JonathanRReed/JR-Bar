"""The decide lane (answer_decisions.py): what it parks, what it sends back
to the agent's PermissionRequest hook, and what ends a hold."""

from __future__ import annotations

import json
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar.answer_decisions import (
    DECIDED_TOMBSTONE_SECONDS,
    DENY_MESSAGE,
    DecisionBroker,
    DecisionResult,
    DecisionVerb,
    PermissionFacts,
    always_allow_rules,
    answer_through_decision_lane,
    decision_document,
    parked_decision_for_request,
    permission_facts,
    release_for_open,
    tool_preview,
    tool_risk,
)
from jrbar.core_server import CommandError
from jrbar.hook import _normalized_hook_record, routed_hook_payload

ALLOW_SUGGESTION = {
    "type": "addRules",
    "rules": [{"toolName": "Bash", "ruleContent": "npm test"}],
    "behavior": "allow",
    "destination": "localSettings",
}


def _claude_payload(**overrides) -> str:
    payload = {
        "hook_event_name": "PermissionRequest",
        "session_id": "claude-session-1",
        "cwd": "/Users/me/project",
        "permission_mode": "default",
        "tool_name": "Bash",
        "tool_input": {"command": "npm test", "description": "Run the tests"},
        "permission_suggestions": [ALLOW_SUGGESTION],
    }
    payload.update(overrides)
    return json.dumps(payload)


def _codex_payload(**overrides) -> str:
    payload = {
        "hook_event_name": "PermissionRequest",
        "session_id": "codex-session-1",
        "turn_id": "turn-7",
        "cwd": "/Users/me/project",
        "tool_name": "Bash",
        "tool_input": {"command": "git push --force", "description": "publish"},
    }
    payload.update(overrides)
    return json.dumps(payload)


class _Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def _facts(**overrides) -> PermissionFacts:
    values = {
        "provider": "claude",
        "session_id": "claude-session-1",
        "request_id": "derived:abc",
        "tool_name": "Bash",
        "tool_input": {"command": "npm test"},
        "always_rules": always_allow_rules([ALLOW_SUGGESTION]),
        "cwd": "/Users/me/project",
    }
    values.update(overrides)
    return PermissionFacts(**values)


def _broker(clock: _Clock | None = None, **kwargs) -> DecisionBroker:
    return DecisionBroker(
        clock=clock or _Clock(),
        wall_clock=lambda: 1_788_000_000.0,
        watching=kwargs.pop("watching", lambda _facts, _pid: False),
        **kwargs,
    )


def _park_and_serve(broker: DecisionBroker, facts: PermissionFacts, *, deliver: bool = True):
    """Park like the ingress does, and serve the wait on a thread the way a
    parked connection would: the verdict is 'sent' when one arrives."""
    slot = broker.park(facts, wait_limit_seconds=50.0)
    assert slot is not None
    received: list = []

    def serve() -> None:
        verdict = broker.wait(slot)
        received.append(verdict)
        broker.delivered(slot, deliver and verdict is not None)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    return slot, received, thread


# --- the payload ---------------------------------------------------------------


def test_permission_facts_key_the_request_the_way_canonical_state_does__and_3_more() -> None:
    # --- scenario: the parked id is the one minimize_hook_event writes
    for provider, text in (("claude", _claude_payload()), ("codex", _codex_payload())):
        facts = permission_facts(provider, text)
        assert facts is not None
        actual, _, line = routed_hook_payload(provider, Path("/tmp/jrbar-test.jsonl"), text)
        record = _normalized_hook_record(actual, line)
        assert facts.request_id == record.provider_request_id.value
        assert facts.request_id.startswith("derived:")
        assert facts.tool_name == "Bash"
        assert facts.cwd == "/Users/me/project"

    # --- scenario: Claude offers its own allow rule; Codex never does
    assert permission_facts("claude", _claude_payload()).always_rules == (ALLOW_SUGGESTION,)
    assert permission_facts("codex", _codex_payload(permission_suggestions=[ALLOW_SUGGESTION])).always_rules == ()

    # --- scenario: only a yes/no PermissionRequest from Claude or Codex is parked
    assert permission_facts("claude", _claude_payload(hook_event_name="PreToolUse")) is None
    assert permission_facts("claude", _claude_payload(tool_name="AskUserQuestion")) is None
    assert permission_facts("claude", _claude_payload(tool_name="ExitPlanMode")) is None
    assert permission_facts("claude", _claude_payload(tool_input="not an object")) is None
    assert permission_facts("claude", _claude_payload(session_id="")) is None
    assert permission_facts("gemini", _claude_payload()) is None
    assert permission_facts("claude", "not json") is None

    # --- scenario: the description is not part of the question's identity
    first = permission_facts("codex", _codex_payload())
    reworded = permission_facts(
        "codex", _codex_payload(tool_input={"command": "git push --force", "description": "other"})
    )
    other_turn = permission_facts("codex", _codex_payload(turn_id="turn-8"))
    assert first.request_id == reworded.request_id
    assert first.request_id != other_turn.request_id


def test_always_allow_keeps_only_the_agents_own_allow_rules__and_1_more() -> None:
    # --- scenario: modes, directories, deny rules and junk are dropped
    suggestions = [
        {"type": "setMode", "mode": "bypassPermissions", "destination": "session"},
        {"type": "addDirectories", "directories": ["/"], "destination": "session"},
        {"type": "addRules", "rules": [{"toolName": "Bash"}], "behavior": "deny", "destination": "session"},
        {"type": "addRules", "rules": [{"toolName": "Bash"}], "behavior": "allow", "destination": "elsewhere"},
        {"type": "addRules", "rules": [{"toolName": 7}], "behavior": "allow", "destination": "session"},
        "not a dict",
        {
            "type": "addRules",
            "rules": [{"toolName": "Edit", "ruleContent": "src/**", "extra": "dropped"}, {"toolName": "Read"}],
            "behavior": "allow",
            "destination": "projectSettings",
            "sneaky": True,
        },
    ]
    assert always_allow_rules(suggestions) == (
        {
            "type": "addRules",
            "rules": [{"toolName": "Edit", "ruleContent": "src/**"}, {"toolName": "Read"}],
            "behavior": "allow",
            "destination": "projectSettings",
        },
    )

    # --- scenario: nothing usable is nothing to offer
    assert always_allow_rules(None) == ()
    assert always_allow_rules([{"type": "addRules", "rules": [], "behavior": "allow", "destination": "session"}]) == ()
    assert always_allow_rules([{"type": "addRules", "rules": [{"toolName": "x" * 600}], "behavior": "allow", "destination": "session"}]) == ()


def test_decision_documents_are_each_agents_documented_verdict__and_2_more() -> None:
    # --- scenario: allow and deny for Claude; a deny stops the turn like Esc
    assert decision_document("claude", DecisionVerb.ALLOW) == {
        "hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}
    }
    assert decision_document("claude", DecisionVerb.DENY) == {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {"behavior": "deny", "message": DENY_MESSAGE, "interrupt": True},
        }
    }

    # --- scenario: Codex takes no interrupt (reserved, fails closed today)
    assert decision_document("codex", DecisionVerb.DENY)["hookSpecificOutput"]["decision"] == {
        "behavior": "deny",
        "message": DENY_MESSAGE,
    }

    # --- scenario: always allow echoes the rules, and only for Claude
    always = decision_document("claude", DecisionVerb.ALWAYS, always_rules=[ALLOW_SUGGESTION])
    assert always["hookSpecificOutput"]["decision"] == {
        "behavior": "allow",
        "updatedPermissions": [ALLOW_SUGGESTION],
    }
    with pytest.raises(ValueError):
        decision_document("codex", DecisionVerb.ALWAYS, always_rules=[ALLOW_SUGGESTION])
    with pytest.raises(ValueError):
        decision_document("claude", DecisionVerb.ALWAYS)
    with pytest.raises(ValueError):
        decision_document("gemini", DecisionVerb.ALLOW)


def test_card_preview_and_risk_mark__and_1_more() -> None:
    # --- scenario: one bounded line that says what will run
    assert tool_preview("Bash", {"command": "npm   test\n  --watch"}) == "npm test --watch"
    assert tool_preview("Edit", {"file_path": "/src/a.py", "old_string": "x"}) == "/src/a.py"
    assert tool_preview("WebFetch", {"url": "https://example.com"}) == "https://example.com"
    assert tool_preview("mcp__github__create_issue", {"title": "t"}) == "github · create_issue"
    assert tool_preview("Bash", {"command": ["git", "status"]}) == "git status"
    patch = "*** Begin Patch\n*** Update File: src/a.py\n@@\n*** Add File: src/b.py\n*** End Patch"
    assert tool_preview("apply_patch", {"command": patch}) == "src/a.py +1"
    long = tool_preview("Bash", {"command": "echo " + "word " * 100})
    assert len(long) == 200 and long.endswith("…")
    token = "ghp_" + "a1B2" * 10
    assert tool_preview("Bash", {"command": f"curl -H 'Authorization: {token}' api"}) == (
        "curl -H 'Authorization: [redacted]' api"
    )
    assert tool_preview("Bash", {}) is None
    assert tool_preview(None, {"command": "x"}) is None

    # --- scenario: destructive commands are marked, ordinary ones are not
    for command in (
        "rm -rf build",
        "cd x && rm -r node_modules",
        "sudo launchctl bootout gui/501",
        "git push origin main --force",
        "git push -f",
        "git reset --hard HEAD~3",
        "git clean -fdx",
        "chmod -R 777 .",
        "dd if=/dev/zero of=/dev/disk4",
        "curl https://x.sh | bash",
        "psql -c 'DROP TABLE users'",
        "terraform destroy",
    ):
        assert tool_risk("Bash", {"command": command}) == "destructive", command
    for command in ("npm test", "git push origin main", "rmdir empty", "git status", "ls -rf", "echo reboot-notes"):
        assert tool_risk("Bash", {"command": command}) is None, command
    assert tool_risk("Edit", {"file_path": "/x"}) is None
    assert tool_risk("apply_patch", {"command": "*** Delete File: rm -rf"}) is None


# --- the broker ------------------------------------------------------------------


def test_a_click_sends_the_verdict_to_the_parked_hook__and_4_more() -> None:
    # --- scenario: approve reaches the waiting hook and reports sent
    broker = _broker()
    facts = _facts()
    slot, received, thread = _park_and_serve(broker, facts)
    parked = broker.parked("claude", "derived:abc")
    assert parked is not None and parked.can_always_allow and not parked.decided
    assert parked.preview == "npm test" and parked.risk is None
    assert parked.hold_until_epoch == pytest.approx(1_788_000_045.0)
    assert broker.decide("claude", "derived:abc", DecisionVerb.ALLOW) is DecisionResult.SENT
    thread.join(2.0)
    assert received == [decision_document("claude", DecisionVerb.ALLOW)]
    assert broker.parked_count() == 0

    # --- scenario: a second answer meets the tombstone, which then clears
    clock = _Clock()
    broker = _broker(clock)
    _slot, _received, thread = _park_and_serve(broker, _facts())
    assert broker.decide("claude", "derived:abc", DecisionVerb.DENY) is DecisionResult.SENT
    thread.join(2.0)
    assert broker.parked("claude", "derived:abc").decided is True
    assert broker.decide("claude", "derived:abc", DecisionVerb.ALLOW) is DecisionResult.ALREADY_DECIDED
    clock.now += DECIDED_TOMBSTONE_SECONDS + 1
    assert broker.parked("claude", "derived:abc") is None
    assert broker.decide("claude", "derived:abc", DecisionVerb.ALLOW) is DecisionResult.NOT_PARKED

    # --- scenario: always allow needs the agent's own rule
    broker = _broker()
    _slot, received, thread = _park_and_serve(broker, _facts(always_rules=()))
    assert broker.parked("claude", "derived:abc").can_always_allow is False
    assert broker.decide("claude", "derived:abc", DecisionVerb.ALWAYS) is DecisionResult.UNSUPPORTED
    assert broker.parked_count() == 1
    broker.release_all()
    thread.join(2.0)
    assert received == [None]

    # --- scenario: a hook that could not write the line is not 'sent'
    broker = _broker()
    _slot, _received, thread = _park_and_serve(broker, _facts(), deliver=False)
    assert broker.decide("claude", "derived:abc", DecisionVerb.ALLOW) is DecisionResult.NOT_DELIVERED
    thread.join(2.0)

    # --- scenario: two identical calls answer oldest first
    broker = _broker()
    first, first_received, first_thread = _park_and_serve(broker, _facts())
    second, second_received, second_thread = _park_and_serve(broker, _facts())
    assert broker.decide("claude", "derived:abc", DecisionVerb.DENY) is DecisionResult.SENT
    first_thread.join(2.0)
    assert first_received and first_received[0]["hookSpecificOutput"]["decision"]["behavior"] == "deny"
    assert second_thread.is_alive()
    broker.release_all()
    second_thread.join(2.0)
    assert second_received == [None]


def test_holds_end_on_their_own_without_ever_deciding__and_4_more() -> None:
    # --- scenario: a lapsed hold prints nothing
    clock = _Clock()
    broker = _broker(clock, hold_seconds=5.0)
    slot = broker.park(_facts(), wait_limit_seconds=50.0)
    clock.now += 6.0
    assert broker.wait(slot) is None
    assert broker.parked("claude", "derived:abc") is None

    # --- scenario: the matching PostToolUse proves it was answered in the terminal
    broker = _broker()
    text = _claude_payload()
    facts = permission_facts("claude", text)
    _slot, received, thread = _park_and_serve(broker, facts)
    ran = json.loads(text)
    ran.update({"hook_event_name": "PostToolUse", "tool_response": {"stdout": "ok"}})
    assert broker.observe("claude", json.dumps(ran)) == 1
    thread.join(2.0)
    assert received == [None]

    # --- scenario: a different call's PostToolUse leaves it alone; the turn ending releases it
    broker = _broker()
    _slot, received, thread = _park_and_serve(broker, facts)
    other = json.loads(text)
    other.update({"hook_event_name": "PostToolUse", "tool_input": {"command": "ls"}})
    assert broker.observe("claude", json.dumps(other)) == 0
    assert broker.observe("codex", json.dumps({"hook_event_name": "Stop", "session_id": "claude-session-1"})) == 0
    assert broker.observe("claude", json.dumps({"hook_event_name": "Stop", "session_id": "someone-else"})) == 0
    assert broker.observe("claude", json.dumps({"hook_event_name": "Stop", "session_id": "claude-session-1"})) == 1
    thread.join(2.0)
    assert received == [None]

    # --- scenario: a hook process that is gone stops looking answerable
    broker = _broker()
    slot = broker.park(_facts(), wait_limit_seconds=50.0)
    assert broker.wait(slot, alive=lambda: False, check_seconds=0.01) is None
    assert broker.parked("claude", "derived:abc") is None

    # --- scenario: opening the session lets its held prompts go
    broker = _broker()
    _slot, received, thread = _park_and_serve(broker, _facts())
    status = SimpleNamespace(provider="claude", session_id="claude-session-1")
    assert release_for_open(status, broker) == 1
    thread.join(2.0)
    assert received == [None]


def test_what_is_never_parked__and_2_more() -> None:
    # --- scenario: too short a wait, or a full broker
    broker = _broker(capacity=1)
    assert broker.park(_facts(), wait_limit_seconds=2.0) is None
    assert broker.park(_facts(), wait_limit_seconds=50.0) is not None
    assert broker.park(_facts(request_id="derived:other"), wait_limit_seconds=50.0) is None

    # --- scenario: the hold never outlasts the hook's own wait
    clock = _Clock()
    broker = _broker(clock)
    slot = broker.park(_facts(), wait_limit_seconds=10.0)
    assert slot.deadline == pytest.approx(clock.now + 10.0 - 1.5)

    # --- scenario: a Codex prompt the owner is watching is not held
    seen: list = []

    def watching(facts, pid):
        seen.append((facts.provider, pid))
        return True

    broker = _broker(watching=watching)
    assert broker.park(_facts(provider="codex"), wait_limit_seconds=50.0, host_pid=4321) is None
    assert seen == [("codex", 4321)]


# --- answer_ask through the lane -----------------------------------------------


class _Journal:
    def __init__(self) -> None:
        self.begun: list = []
        self.settled: list = []

    def begin(self, name, payload, command_id=None):
        self.begun.append((name, payload))
        return SimpleNamespace(status="accepted", command_id="cmd-1", receipt=None, error=None)

    def settle(self, command_id, **outcome):
        self.settled.append(outcome)


def _request_key(provider: str, request_id: str):
    return SimpleNamespace(
        work_key=SimpleNamespace(source_key=SimpleNamespace(provider_id=provider)),
        request_id=SimpleNamespace(value=request_id),
    )


def _controller(provider: str = "claude", request_id: str = "derived:abc"):
    work_key = object()
    key = _request_key(provider, request_id)
    key.work_key = work_key
    key.work_key = SimpleNamespace(source_key=SimpleNamespace(provider_id=provider))
    request = SimpleNamespace(key=key, phase=SimpleNamespace(value="live_waiting"))
    status = SimpleNamespace(agent_id="claude:session:1", work_key=key.work_key)
    refreshed: list = []
    controller = SimpleNamespace(
        current_operator_state=SimpleNamespace(requests=(request,)),
        refresh_=lambda sender: refreshed.append(sender),
    )
    return controller, status, request, refreshed


def test_answer_ask_answers_a_held_request_by_its_hook__and_4_more() -> None:
    journal = _Journal()

    def call(controller, status, args, broker):
        return answer_through_decision_lane(
            controller, status, args, journal_for=lambda _c: journal, on_main=lambda fn: fn(), broker=broker
        )

    # --- scenario: approve is sent, journaled and refreshed
    broker = _broker()
    controller, status, request, refreshed = _controller()
    _slot, received, thread = _park_and_serve(broker, _facts())
    assert parked_decision_for_request(request, broker) is not None
    result = call(controller, status, {"session": status.agent_id, "decision": "approve"}, broker)
    thread.join(2.0)
    assert result["answered"] is True and result["mechanism"] == "permission_hook"
    assert result["decision"] == "approve" and result["confirmation"] == "provider_pending"
    assert received == [decision_document("claude", DecisionVerb.ALLOW)]
    assert journal.begun[-1][1]["decision"] == "approve"
    assert journal.settled[-1]["receipt"] == result
    assert refreshed == [None]

    # --- scenario: nothing held, so the keystroke path takes it; always refuses
    broker = _broker()
    controller, status, _request, _ = _controller()
    assert call(controller, status, {"decision": "approve"}, broker) is None
    with pytest.raises(CommandError) as error:
        call(controller, status, {"decision": "always"}, broker)
    assert error.value.code == "unsupported"

    # --- scenario: a typed reply is never a decision
    _slot, _received, thread = _park_and_serve(broker, _facts())
    assert call(controller, status, {"decision": "approve", "reply_text": "yes"}, broker) is None
    broker.release_all()
    thread.join(2.0)

    # --- scenario: a card pinned to another request refuses before anything is sent
    broker = _broker()
    controller, status, _request, _ = _controller()
    _slot, received, thread = _park_and_serve(broker, _facts())
    with pytest.raises(CommandError) as error:
        call(controller, status, {"decision": "approve", "request": "request:v1:someone-else"}, broker)
    assert error.value.code == "stale_request"
    assert broker.parked_count() == 1
    broker.release_all()
    thread.join(2.0)
    assert received == [None]

    # --- scenario: a lapsed hook is a stale ask, settled as such
    broker = _broker()
    controller, status, _request, _ = _controller()
    _slot, _received, thread = _park_and_serve(broker, _facts(), deliver=False)
    with pytest.raises(CommandError) as error:
        call(controller, status, {"decision": "deny"}, broker)
    thread.join(2.0)
    assert error.value.code == "stale_ask"
    assert journal.settled[-1]["error"]["code"] == "stale_ask"
