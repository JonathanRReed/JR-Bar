"""What an ask adds when the person expands it (answer_decisions.tool_detail):
the whole command, a file edit's size and a plan, capped and masked, and
nothing for an ask the one-line preview already says completely."""

from __future__ import annotations

import json
from types import SimpleNamespace

from jrbar.answer_decisions import (
    DETAIL_TEXT_LIMIT,
    AskPreviews,
    _request_identity,
    ask_detail_for_request,
    tool_detail,
)
from jrbar.provider_adapters import hook_request_identity


def _payload(tool_name: str, tool_input: dict, **extra) -> str:
    return json.dumps(
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session-detail",
            "cwd": "/Users/me/project",
            "tool_name": tool_name,
            "tool_input": tool_input,
            **extra,
        }
    )


def _request_id(provider: str, text: str) -> str:
    routed = _request_identity(provider, text)
    assert routed is not None
    request_id = hook_request_identity(routed[1])
    assert request_id is not None
    return request_id


def test_a_command_the_line_says_whole_has_no_detail__and_4_more() -> None:
    # --- scenario: a short one-line command is complete in the preview
    assert tool_detail("Bash", {"command": "npm test"}) is None
    assert tool_detail("Bash", {}) is None
    assert tool_detail(None, {"command": "x"}) is None
    assert tool_detail("Bash", "nope") is None

    # --- scenario: a multi-line command is flattened in the line, so the full text is offered
    detail = tool_detail("Bash", {"command": "set -e\nnpm ci\nnpm test"})
    assert detail == {"command": "set -e\nnpm ci\nnpm test", "truncated": False}

    # --- scenario: a long command is capped, flagged, and never past the cap
    long_command = "echo " + "word " * 1000
    detail = tool_detail("Bash", {"command": long_command})
    assert detail is not None and detail["truncated"] is True
    assert len(detail["command"]) <= DETAIL_TEXT_LIMIT
    assert detail["command"].startswith("echo word word")

    # --- scenario: a token-shaped run is masked, even one straddling the cap
    token = "ghp_" + "a1B2" * 10
    detail = tool_detail("Bash", {"command": "x " * (DETAIL_TEXT_LIMIT // 2 - 3) + token + "\nmore"})
    assert detail is not None
    assert token not in detail["command"] and token[:20] not in detail["command"]
    detail = tool_detail("Bash", {"command": f"curl -H 'Authorization: {token}'\napi"})
    assert detail is not None and "[redacted]" in detail["command"] and token not in detail["command"]

    # --- scenario: a list command (Codex) is joined like the line joins it
    detail = tool_detail("shell", {"command": ["bash", "-lc", "line one\nline two"]})
    assert detail == {"command": "bash -lc line one\nline two", "truncated": False}


def test_a_file_edit_counts_lines_and_ships_no_contents__and_4_more() -> None:
    secret_body = "def private():\n    return 'do not ship this body'\n"

    # --- scenario: Edit counts old and new lines
    detail = tool_detail(
        "Edit",
        {"file_path": "/src/a.py", "old_string": "a\nb\nc", "new_string": "x\ny"},
    )
    assert detail == {
        "edit": {"verb": "edit", "files": 1, "added": 2, "removed": 3, "paths": ["/src/a.py"]},
        "truncated": False,
    }

    # --- scenario: MultiEdit sums every edit of its one file
    detail = tool_detail(
        "MultiEdit",
        {
            "file_path": "/src/b.py",
            "edits": [
                {"old_string": "a", "new_string": "b\nc"},
                {"old_string": "d\ne", "new_string": "f"},
                "not an edit",
            ],
        },
    )
    assert detail["edit"] == {"verb": "edit", "files": 1, "added": 3, "removed": 3, "paths": ["/src/b.py"]}

    # --- scenario: Write counts lines added and sends none of them
    detail = tool_detail("Write", {"file_path": "/src/new.py", "content": secret_body})
    assert detail["edit"] == {"verb": "write", "files": 1, "added": 2, "removed": 0, "paths": ["/src/new.py"]}
    assert "do not ship" not in json.dumps(detail)
    assert "command" not in detail and "plan" not in detail

    # --- scenario: apply_patch counts files and +/- lines, not the hunk text
    patch = (
        "*** Begin Patch\n*** Update File: src/a.py\n@@\n-old one\n-old two\n+new one\n"
        "*** Add File: src/b.py\n+line\n+line two\n*** End Patch"
    )
    detail = tool_detail("apply_patch", {"command": patch})
    assert detail["edit"] == {
        "verb": "patch",
        "files": 2,
        "added": 3,
        "removed": 2,
        "paths": ["src/a.py", "src/b.py"],
    }
    assert "command" not in detail and "old one" not in json.dumps(detail)

    # --- scenario: an edit with no file names nothing to summarise
    assert tool_detail("Edit", {"old_string": "a", "new_string": "b"}) is None


def test_a_plan_is_carried_capped_and_masked__and_2_more() -> None:
    # --- scenario: ExitPlanMode's plan
    assert tool_detail("ExitPlanMode", {"plan": "1. Read\n2. Change\n3. Test"}) == {
        "plan": "1. Read\n2. Change\n3. Test",
        "truncated": False,
    }
    assert tool_detail("ExitPlanMode", {"plan": "   "}) is None
    assert tool_detail("ExitPlanMode", {}) is None

    # --- scenario: a long plan is cut at the cap and says so; a token in it is masked
    token = "sk-" + "Z9y8" * 12
    detail = tool_detail("ExitPlanMode", {"plan": f"use {token}\n" + "step\n" * 2000})
    assert detail["truncated"] is True and len(detail["plan"]) <= DETAIL_TEXT_LIMIT
    assert token not in detail["plan"] and "[redacted]" in detail["plan"]

    # --- scenario: a question is not expanded: its options are the answer
    assert tool_detail("AskUserQuestion", {"plan": "x", "questions": []}) is None


def test_the_ingress_notes_the_detail_for_the_card__and_2_more() -> None:
    previews = AskPreviews()

    # --- scenario: a plan approval, which the lane cannot decide, still reaches its card
    plan_text = _payload("ExitPlanMode", {"plan": "1. One\n2. Two"})
    assert previews.note("claude", plan_text)
    plan_id = _request_id("claude", plan_text)
    assert previews.lookup_detail("claude", plan_id) == {"plan": "1. One\n2. Two", "truncated": False}

    # --- scenario: the lookup is a copy; the card cannot edit the stored row
    previews.lookup_detail("claude", plan_id)["plan"] = "changed"
    assert previews.lookup_detail("claude", plan_id)["plan"] == "1. One\n2. Two"

    # --- scenario: an ask with a short command has a line and no detail
    short = _payload("Bash", {"command": "npm test"})
    assert previews.note("claude", short)
    assert previews.lookup_detail("claude", _request_id("claude", short)) is None
    assert previews.lookup_detail("claude", "unknown") is None
    assert ask_detail_for_request(SimpleNamespace(key=None), previews) is None
