"""The OpenCode plugin file: its generations, and what the bridge tells the daemon.

JR-Bar proves it owns an installed plugin by comparing the file with the exact
text of the generation its marker names. Editing the template therefore
strands every installed file unless the older generation stays recognised, so
the file is versioned: v2 is the current template, v1 is frozen, and an install
of either is detected, replaced by v2 and removed like any other. Nothing here
runs an install against a real ``~/.config/opencode``: every test takes a
temporary home.
"""

from __future__ import annotations

import json
import re
import shutil
import stat
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

import pytest

from jrbar._collector_legacy import _registered_hook_source
from jrbar.hook import _normalized_hook_record, routed_hook_payload
from jrbar.install import (
    install_opencode_plugin,
    opencode_plugin_source,
    refresh_managed_hooks,
    uninstall_opencode_plugin,
)
from jrbar.operator_state import (
    BootIdentifier,
    ClockSample,
    RequestPhase,
    TransitionKind,
    empty_operator_state,
    reduce_operator_state,
)
from jrbar.provider_adapters import (
    _NOTIFICATION_KIND_FIELDS,
    _REQUEST_ID_FIELDS,
    NormalizedProviderRecord,
    NotificationKind,
    provider_facts_for_record,
)
from jrbar.provider_facts import (
    NextActor,
    ProviderRequestState,
    RequestKind,
    SourceFreshness,
    SourceHealth,
    WorkLifecycle,
)
from jrbar.providers import (
    OPENCODE_EVENTS,
    OPENCODE_PLUGIN_MARKER,
    _opencode_plugin_v1_source_for_arguments,
    default_opencode_plugin_path,
    detect_opencode_plugin,
    legacy_opencode_plugin_source_for_arguments,
    managed_opencode_plugin_log_path,
    opencode_plugin_source_for_arguments,
)

_FIXTURES = Path(__file__).parent / "fixtures" / "opencode"
_V1_MARKER = "jrbar-opencode-plugin-v1"


def _arguments(log: Path) -> list[str]:
    """The exact argv the installer registers, with a synthetic log path."""
    return [sys.executable, "-m", "jrbar.hook_client", "--provider", "opencode", "--log", str(log)]


def _v1(log: Path) -> str:
    return _opencode_plugin_v1_source_for_arguments(_arguments(log))


@pytest.fixture
def home(tmp_path: Path) -> Path:
    plugin = default_opencode_plugin_path(tmp_path)
    plugin.parent.mkdir(parents=True)
    return tmp_path


# --- the generations ---------------------------------------------------------


def test_the_current_template_carries_the_v2_marker() -> None:
    assert OPENCODE_PLUGIN_MARKER == "jrbar-opencode-plugin-v2"
    source = opencode_plugin_source_for_arguments(_arguments(Path("/synthetic/opencode.jsonl")))
    assert source.startswith(f"// {OPENCODE_PLUGIN_MARKER}\nconst JRBAR_HOOK_ARGS = Object.freeze(")


def test_the_frozen_v1_generator_equals_the_checked_in_copy() -> None:
    """A later template edit cannot silently redefine what v1 means."""
    arguments = _arguments(Path("/synthetic/state/opencode.jsonl"))
    literal = (_FIXTURES / "plugin-v1.js.template").read_text(encoding="utf-8")
    expected = literal.replace("__HOOK_ARGS__", json.dumps(arguments, separators=(",", ":")))

    assert _opencode_plugin_v1_source_for_arguments(arguments) == expected
    assert expected.startswith(f"// {_V1_MARKER}\n")


def test_the_v1_and_v2_bodies_differ_so_an_install_can_be_told_apart() -> None:
    log = Path("/synthetic/opencode.jsonl")
    assert _v1(log) != opencode_plugin_source(log, python_executable=sys.executable)


def test_the_pre_rename_generator_derives_from_the_frozen_v1_body() -> None:
    arguments = _arguments(Path("/synthetic/old-state/opencode.jsonl"))
    legacy = legacy_opencode_plugin_source_for_arguments(arguments)
    expected = (
        _opencode_plugin_v1_source_for_arguments(arguments)
        .replace(f"// {_V1_MARKER}\n", "// sidepulse-opencode-plugin-v1\n", 1)
        .replace("JRBAR_", "SIDEPULSE_")
        .replace("JRBarPlugin", "SidePulsePlugin")
    )

    assert legacy == expected
    assert legacy.startswith("// sidepulse-opencode-plugin-v1\nconst SIDEPULSE_HOOK_ARGS = Object.freeze(")
    assert "JRBAR" not in legacy and "JRBar" not in legacy
    assert managed_opencode_plugin_log_path(legacy) == Path("/synthetic/old-state/opencode.jsonl")


# --- an install of the frozen v1 generation keeps working --------------------


def test_a_v1_plugin_is_still_detected_as_installed(home: Path) -> None:
    log = home / ".local" / "state" / "jrbar" / "opencode.jsonl"
    default_opencode_plugin_path(home).write_text(_v1(log))

    detected = detect_opencode_plugin(home)

    assert detected.exists and detected.hooks_enabled
    assert detected.hook_events == OPENCODE_EVENTS
    assert detected.log_paths == (log,)
    assert managed_opencode_plugin_log_path(_v1(log)) == log


def test_installing_over_v1_leaves_exactly_the_v2_source(home: Path) -> None:
    plugin = default_opencode_plugin_path(home)
    log = home / "state" / "opencode.jsonl"
    plugin.write_text(_v1(log))

    first = install_opencode_plugin(log, plugin_path=plugin, python_executable=sys.executable)

    assert first.changed
    assert plugin.read_text() == opencode_plugin_source(log, python_executable=sys.executable)
    assert plugin.read_text().startswith(f"// {OPENCODE_PLUGIN_MARKER}\n")
    assert stat.S_IMODE(plugin.stat().st_mode) == 0o600
    assert detect_opencode_plugin(home).log_paths == (log,)

    second = install_opencode_plugin(log, plugin_path=plugin, python_executable=sys.executable)

    assert not second.changed


def test_the_upgrade_refresh_replaces_a_v1_plugin_with_v2(home: Path) -> None:
    """A later app upgrade rewrites only detector-proven plugins, and v1 is proven."""
    plugin = default_opencode_plugin_path(home)
    log = home / ".local" / "state" / "jrbar" / "opencode.jsonl"
    plugin.write_text(_v1(log))

    results = refresh_managed_hooks(
        home=home,
        state_dir=home / ".local" / "state" / "jrbar",
        python_executable=sys.executable,
    )

    result = results["opencode"]
    assert not isinstance(result, Exception), result
    assert result.changed
    assert plugin.read_text() == opencode_plugin_source(log, python_executable=sys.executable)
    assert detect_opencode_plugin(home).log_paths == (log,)


def test_uninstall_removes_either_generation(home: Path) -> None:
    plugin = default_opencode_plugin_path(home)
    log = home / "state" / "opencode.jsonl"
    plugin.write_text(_v1(log))

    removed_v1 = uninstall_opencode_plugin(log, plugin_path=plugin)

    assert removed_v1.changed and not plugin.exists()

    plugin.write_text(opencode_plugin_source(log, python_executable=sys.executable))
    removed_v2 = uninstall_opencode_plugin(log, plugin_path=plugin)

    assert removed_v2.changed and not plugin.exists()


def test_a_v1_file_with_one_edited_byte_is_refused_as_unowned(home: Path) -> None:
    plugin = default_opencode_plugin_path(home)
    log = home / "state" / "opencode.jsonl"
    edited = _v1(log) + "// arbitrary edit\n"
    plugin.write_text(edited)

    assert not detect_opencode_plugin(home).exists
    assert managed_opencode_plugin_log_path(edited) is None
    with pytest.raises(OSError):
        install_opencode_plugin(log, plugin_path=plugin, python_executable=sys.executable)
    with pytest.raises(OSError):
        uninstall_opencode_plugin(log, plugin_path=plugin)
    assert plugin.read_text() == edited


def test_a_v1_file_with_forged_arguments_is_refused(home: Path) -> None:
    plugin = default_opencode_plugin_path(home)
    log = home / "state" / "opencode.jsonl"
    source = _v1(log)
    forged_variants = (
        source.replace(sys.executable, "/tmp/forged-executable", 1),
        source.replace(
            "const JRBAR_HOOK_ARGS = Object.freeze([",
            'const JRBAR_HOOK_ARGS = Object.freeze(["/tmp/forged-prefix",',
            1,
        ),
    )

    for forged in forged_variants:
        plugin.write_text(forged)
        assert not detect_opencode_plugin(home).exists
        with pytest.raises(OSError):
            install_opencode_plugin(log, plugin_path=plugin, python_executable=sys.executable)
        with pytest.raises(OSError):
            uninstall_opencode_plugin(log, plugin_path=plugin)


def test_a_marker_never_vouches_for_another_generations_body(home: Path) -> None:
    """Exact text per generation: a v2 marker on the v1 body, or the reverse, is not ours."""
    log = home / "state" / "opencode.jsonl"
    v2 = opencode_plugin_source(log, python_executable=sys.executable)
    v1 = _v1(log)

    assert managed_opencode_plugin_log_path(v1) == log
    assert managed_opencode_plugin_log_path(v2) == log
    assert managed_opencode_plugin_log_path(v1.replace(_V1_MARKER, OPENCODE_PLUGIN_MARKER, 1)) is None
    assert managed_opencode_plugin_log_path(v2.replace(OPENCODE_PLUGIN_MARKER, _V1_MARKER, 1)) is None


def test_a_pre_rename_stub_still_reads_as_not_installed(home: Path) -> None:
    default_opencode_plugin_path(home).write_text(
        "// sidepulse-opencode-plugin-v1\nconst SIDEPULSE_HOOK_ARGS = Object.freeze([]);\n"
    )

    assert not detect_opencode_plugin(home).exists



# --- what the bridge tells the daemon ----------------------------------------
#
# Real OpenCode event shapes, with synthetic ids. An ask carries its request id
# as ``properties.id``; only the replied and rejected events carry
# ``requestID``. Words like "secret" sit in every field the bridge must never
# forward, so the exact-payload assertions also prove nothing leaks.

_SESSION = "ses_test0000000000000000000001"
_PERMISSION = "per_test0000000000000000000001"
_PERMISSION_2 = "per_test0000000000000000000002"
_QUESTION = "que_test0000000000000000000001"

_PERMISSION_ASKED = {
    "type": "permission.asked",
    "properties": {
        "id": _PERMISSION,
        "sessionID": _SESSION,
        "permission": "bash",
        "patterns": ["secret command pattern"],
        "metadata": {"command": "secret command"},
        "always": ["secret always pattern"],
        "tool": {"messageID": "msg_test0000000000000000000001", "callID": "call_test0000000000000000000001"},
    },
}
_QUESTION_ASKED = {
    "type": "question.asked",
    "properties": {
        "id": _QUESTION,
        "sessionID": _SESSION,
        "questions": [
            {
                "question": "secret question text",
                "header": "secret header",
                "options": [{"label": "secret option", "description": "secret description"}],
            }
        ],
    },
}
_PERMISSION_REPLIED = {
    "type": "permission.replied",
    "properties": {"sessionID": _SESSION, "requestID": _PERMISSION, "reply": "once"},
}
_QUESTION_REPLIED = {
    "type": "question.replied",
    "properties": {"sessionID": _SESSION, "requestID": _QUESTION, "answers": [["secret answer"]]},
}
_QUESTION_REJECTED = {
    "type": "question.rejected",
    "properties": {"sessionID": _SESSION, "requestID": _QUESTION},
}
_SESSION_BUSY = {
    "type": "session.status",
    "properties": {"sessionID": _SESSION, "status": {"type": "busy"}},
}
_SESSION_IDLE = {"type": "session.idle", "properties": {"sessionID": _SESSION}}
_SESSION_ERROR = {
    "type": "session.error",
    "properties": {
        "sessionID": _SESSION,
        "error": {"name": "UnknownError", "data": {"message": "secret provider error"}},
    },
}

# (bus event, the exact payload the bridge hands the hook)
_BRIDGE_CASES = (
    (_SESSION_BUSY, {"hook_event_name": "UserPromptSubmit", "session_id": _SESSION}),
    (
        _PERMISSION_ASKED,
        {"hook_event_name": "PermissionRequest", "session_id": _SESSION, "request_id": _PERMISSION},
    ),
    (
        _QUESTION_ASKED,
        {
            "hook_event_name": "Notification",
            "session_id": _SESSION,
            "request_id": _QUESTION,
            "notification_type": "input_required",
        },
    ),
    (
        _PERMISSION_REPLIED,
        {"hook_event_name": "PostToolUse", "session_id": _SESSION, "request_id": _PERMISSION},
    ),
    (
        _QUESTION_REPLIED,
        {"hook_event_name": "PostToolUse", "session_id": _SESSION, "request_id": _QUESTION},
    ),
    (
        _QUESTION_REJECTED,
        {"hook_event_name": "PostToolUse", "session_id": _SESSION, "request_id": _QUESTION},
    ),
    (_SESSION_IDLE, {"hook_event_name": "Stop", "session_id": _SESSION}),
    (_SESSION_ERROR, {"hook_event_name": "StopFailure", "session_id": _SESSION}),
)

_EPOCH = 1_800_000_000.0


def _record(payload: dict[str, object], *, at: float = 0.0) -> NormalizedProviderRecord:
    """The record the hook writes for a bridge payload, at a fixed stamp."""
    stamp = datetime.fromtimestamp(_EPOCH + at, UTC).isoformat().replace("+00:00", "Z")
    actual, _, line = routed_hook_payload(
        "opencode",
        Path("/synthetic/opencode.jsonl"),
        json.dumps(payload),
        logged_at=stamp,
    )
    assert actual == "opencode"
    record = _normalized_hook_record(actual, line)
    assert type(record) is NormalizedProviderRecord
    return record


def _batch(record: NormalizedProviderRecord):
    source = _registered_hook_source("opencode")
    assert source is not None
    return provider_facts_for_record(
        record,
        contract=source.contract,
        observation_authority=source.registration.observation_authority,
        observed_at_epoch=record.occurred_at_epoch + 0.25,
    )


def _feed(state, payload: dict[str, object], *, at: float):
    record = _record(payload, at=at)
    clock = ClockSample(_EPOCH + at + 0.5, 100.0 + at, BootIdentifier("boot:01"))
    result = reduce_operator_state(state, _batch(record), clock=clock)
    return result.state, result


def _request_phases(state) -> dict[str, RequestPhase]:
    return {item.key.request_id.value: item.phase for item in state.requests}


def _payload(case: dict[str, object]) -> dict[str, object]:
    return next(expected for event, expected in _BRIDGE_CASES if event is case)


def test_a_question_ask_reaches_needs_you_as_a_live_input_request() -> None:
    record = _record(_payload(_QUESTION_ASKED))
    batch = _batch(record)

    assert record.notification_kind is NotificationKind.INPUT_REQUIRED
    (work,) = batch.work_facts
    assert work.lifecycle is WorkLifecycle.WAITING and work.next_actor is NextActor.USER
    (request,) = batch.request_facts
    assert request.state is ProviderRequestState.LIVE
    assert request.request_kind is RequestKind.INPUT
    assert request.key.request_id.value == _QUESTION
    assert batch.diagnostics == ()
    assert batch.source_health is SourceHealth.HEALTHY


def test_a_permission_ask_is_keyed_by_the_id_the_ask_carries() -> None:
    batch = _batch(_record(_payload(_PERMISSION_ASKED)))

    (request,) = batch.request_facts
    assert request.state is ProviderRequestState.LIVE
    assert request.request_kind is RequestKind.PERMISSION
    assert request.key.request_id.value == _PERMISSION
    assert batch.diagnostics == ()
    assert batch.source_health is SourceHealth.HEALTHY


@pytest.mark.parametrize(
    ("asked", "answered"),
    [
        (_PERMISSION_ASKED, _PERMISSION_REPLIED),
        (_QUESTION_ASKED, _QUESTION_REPLIED),
        (_QUESTION_ASKED, _QUESTION_REJECTED),
    ],
)
def test_the_reply_resolves_the_request_its_ask_opened(
    asked: dict[str, object],
    answered: dict[str, object],
) -> None:
    (opened,) = _batch(_record(_payload(asked))).request_facts
    (resolved,) = _batch(_record(_payload(answered), at=5.0)).request_facts

    assert resolved.key == opened.key
    assert resolved.state is ProviderRequestState.RESOLVED


def test_ask_then_reply_opens_then_resolves_and_ends_active() -> None:
    state = empty_operator_state()
    state, _ = _feed(state, _payload(_SESSION_BUSY), at=0.0)
    state, opened = _feed(state, _payload(_PERMISSION_ASKED), at=1.0)

    assert TransitionKind.REQUEST_OPENED in {event.kind for event in opened.events}
    assert _request_phases(state) == {_PERMISSION: RequestPhase.LIVE_UNACKNOWLEDGED}

    state, resolved = _feed(state, _payload(_PERMISSION_REPLIED), at=2.0)

    assert TransitionKind.REQUEST_RESOLVED in {event.kind for event in resolved.events}
    assert _request_phases(state) == {_PERMISSION: RequestPhase.RESOLVED}
    (work,) = state.works
    assert work.lifecycle is WorkLifecycle.ACTIVE


def test_two_asks_in_one_session_stay_two_requests() -> None:
    second = {
        "hook_event_name": "PermissionRequest",
        "session_id": _SESSION,
        "request_id": _PERMISSION_2,
    }
    state = empty_operator_state()
    state, _ = _feed(state, _payload(_SESSION_BUSY), at=0.0)
    state, _ = _feed(state, _payload(_PERMISSION_ASKED), at=1.0)
    state, _ = _feed(state, second, at=2.0)

    assert _request_phases(state) == {
        _PERMISSION: RequestPhase.LIVE_UNACKNOWLEDGED,
        _PERMISSION_2: RequestPhase.LIVE_UNACKNOWLEDGED,
    }

    state, _ = _feed(state, _payload(_PERMISSION_REPLIED), at=3.0)

    assert _request_phases(state) == {
        _PERMISSION: RequestPhase.RESOLVED,
        _PERMISSION_2: RequestPhase.LIVE_UNACKNOWLEDGED,
    }


def test_an_ask_followed_by_the_turn_ending_closes_the_request() -> None:
    state = empty_operator_state()
    state, _ = _feed(state, _payload(_SESSION_BUSY), at=0.0)
    state, _ = _feed(state, _payload(_QUESTION_ASKED), at=1.0)
    state, ended = _feed(state, _payload(_SESSION_IDLE), at=2.0)

    kinds = {event.kind for event in ended.events}
    assert TransitionKind.REQUEST_RESOLVED in kinds and TransitionKind.COMPLETED in kinds
    assert _request_phases(state) == {_QUESTION: RequestPhase.RESOLVED}


def test_an_ask_with_no_id_is_waiting_and_says_so() -> None:
    """A keyless ask is reported honestly, never an empty healthy batch."""
    payload = {
        "hook_event_name": "Notification",
        "session_id": _SESSION,
        "notification_type": "input_required",
    }
    batch = _batch(_record(payload))

    (work,) = batch.work_facts
    assert work.lifecycle is WorkLifecycle.WAITING
    assert batch.request_facts == ()
    assert tuple(item.identifier.value for item in batch.diagnostics) == ("missing_request_identity",)
    assert batch.source_freshness is SourceFreshness.FRESH


def test_the_retired_notification_kind_spelling_carries_no_lifecycle() -> None:
    """The adapter reads notification_type only, so the old key names nothing."""
    payload = {
        "hook_event_name": "Notification",
        "session_id": _SESSION,
        "notification_kind": "input_required",
    }
    record = _record(payload)
    batch = _batch(record)

    assert record.notification_kind is None
    assert batch.work_facts == () and batch.request_facts == ()


# --- the template names only fields the adapter reads ------------------------


def _template() -> str:
    return opencode_plugin_source_for_arguments(_arguments(Path("/synthetic/opencode.jsonl")))


def test_the_template_only_sends_notification_and_request_names_the_adapter_reads() -> None:
    """The guard that would have caught notification_kind: it runs without bun."""
    source = _template()
    assigned = set(re.findall(r"payload\.([A-Za-z_]+)\s*=", source))

    assert "notification_kind" not in source
    assert {name for name in assigned if "notification" in name} <= set(_NOTIFICATION_KIND_FIELDS)
    assert {name for name in assigned if "request" in name} <= set(_REQUEST_ID_FIELDS)
    assert "notification_type" in assigned and "request_id" in assigned


def test_the_template_keys_an_ask_on_properties_id() -> None:
    source = _template()

    assert '"permission.asked"' in source and '"question.asked"' in source
    assert "properties.id" in source
    assert "properties.requestID" in source


# --- the bridge itself, under bun --------------------------------------------

_RUNNER = """
const captured = [];
Bun.spawn = (_args, _options) => ({
  stdin: { write(text) { captured.push(String(text)); }, end() {} },
  exited: Promise.resolve(0),
});
const { default: plugin } = await import("./jrbar.js");
const events = await Bun.file("./events.json").json();
for (const event of events) {
  await plugin.event({ event });
}
console.log(JSON.stringify(captured));
"""


def _run_bridge(directory: Path, events: list[dict[str, object]]) -> list[dict[str, object]]:
    """Feed bus events to the generated plugin; return each payload it forwards."""
    (directory / "jrbar.js").write_text(
        opencode_plugin_source(directory / "opencode.jsonl", python_executable=sys.executable)
    )
    (directory / "events.json").write_text(json.dumps(events))
    (directory / "runner.mjs").write_text(_RUNNER)
    result = subprocess.run(
        ["bun", "runner.mjs"],
        cwd=directory,
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr
    encoded = json.loads(result.stdout)
    for text in encoded:
        assert len(text) <= 1024
        assert "secret" not in text
        assert "/private" not in text
    return [json.loads(text) for text in encoded]


needs_bun = pytest.mark.skipif(shutil.which("bun") is None, reason="the OpenCode plugin runs under bun")


@needs_bun
def test_the_bridge_forwards_the_exact_payloads_the_adapter_reads(tmp_path: Path) -> None:
    events = [event for event, _expected in _BRIDGE_CASES]

    forwarded = _run_bridge(tmp_path, events)

    assert forwarded == [expected for _event, expected in _BRIDGE_CASES]
    assert all("notification_kind" not in payload for payload in forwarded)


@needs_bun
def test_a_malformed_ask_id_is_forwarded_keyless_and_a_malformed_reply_id_is_dropped(
    tmp_path: Path,
) -> None:
    """A dropped ask is worse than a keyless one; a reply that names nothing valid resolves nothing."""
    bad_ids = ["/private/project", "token_sk_live_1", "a" * 129, "control\nvalue", 7]
    events: list[dict[str, object]] = []
    for bad in bad_ids:
        asked = json.loads(json.dumps(_PERMISSION_ASKED))
        asked["properties"]["id"] = bad
        events.append(asked)
    for bad in bad_ids:
        replied = json.loads(json.dumps(_PERMISSION_REPLIED))
        replied["properties"]["requestID"] = bad
        events.append(replied)

    forwarded = _run_bridge(tmp_path, events)

    keyless = {"hook_event_name": "PermissionRequest", "session_id": _SESSION}
    assert forwarded == [keyless] * len(bad_ids)


@needs_bun
def test_an_ask_without_a_session_is_still_dropped(tmp_path: Path) -> None:
    asked = json.loads(json.dumps(_QUESTION_ASKED))
    asked["properties"]["sessionID"] = "/private/project"

    assert _run_bridge(tmp_path, [asked]) == []


# --- a Task subagent's child session -----------------------------------------
#
# OpenCode's Task tool makes a child session whose events carry the child's own
# session id. The plugin keeps a bounded child-to-parent map, filled from
# session.created and session.updated before the forwarding gate (session.updated
# is never forwarded), and stamps a child's events with Claude's worker shape:
# agent_id the child, session_id the ROOT session. Nothing but the two ids is
# ever read from ``info``.

_ROOT = "ses_root0000000000000000000001"
_CHILD = "ses_child000000000000000000001"
_GRANDCHILD = "ses_grand000000000000000000001"
_OTHER = "ses_other00000000000000000001"


def _created(session: str, parent: str | None, *, name: str = "session.created") -> dict[str, object]:
    info: dict[str, object] = {
        "id": session,
        "title": "secret title",
        "directory": "/private/project",
        "summary": {"diffs": [{"file": "/private/project/secret.txt"}]},
    }
    if parent is not None:
        info["parentID"] = parent
    return {"type": name, "properties": {"sessionID": session, "info": info}}


def _busy(session: str) -> dict[str, object]:
    return {
        "type": "session.status",
        "properties": {"sessionID": session, "status": {"type": "busy"}},
    }


def _asked(session: str, request: str = _PERMISSION) -> dict[str, object]:
    return {
        "type": "permission.asked",
        "properties": {"id": request, "sessionID": session, "patterns": ["secret pattern"]},
    }


def _idle(session: str) -> dict[str, object]:
    return {"type": "session.idle", "properties": {"sessionID": session}}


def _stamped(name: str, root: str, child: str, **extra: object) -> dict[str, object]:
    return {"hook_event_name": name, "session_id": root, "agent_id": child, **extra}


@needs_bun
def test_a_childs_events_carry_the_child_as_agent_and_the_root_as_session(tmp_path: Path) -> None:
    events = [
        _created(_CHILD, _ROOT),
        _busy(_CHILD),
        _asked(_CHILD),
        _idle(_CHILD),
    ]

    forwarded = _run_bridge(tmp_path, events)

    assert forwarded == [
        _stamped("SessionStart", _ROOT, _CHILD),
        _stamped("UserPromptSubmit", _ROOT, _CHILD),
        _stamped("PermissionRequest", _ROOT, _CHILD, request_id=_PERMISSION),
        _stamped("Stop", _ROOT, _CHILD),
    ]


@needs_bun
def test_an_unrelated_session_gets_no_agent_id(tmp_path: Path) -> None:
    events = [
        _created(_ROOT, None),
        _busy(_ROOT),
        _created(_CHILD, _ROOT),
        _busy(_CHILD),
        _busy(_OTHER),
        _idle(_ROOT),
    ]

    forwarded = _run_bridge(tmp_path, events)

    assert forwarded == [
        {"hook_event_name": "SessionStart", "session_id": _ROOT},
        {"hook_event_name": "UserPromptSubmit", "session_id": _ROOT},
        _stamped("SessionStart", _ROOT, _CHILD),
        _stamped("UserPromptSubmit", _ROOT, _CHILD),
        {"hook_event_name": "UserPromptSubmit", "session_id": _OTHER},
        {"hook_event_name": "Stop", "session_id": _ROOT},
    ]


@needs_bun
def test_a_grandchild_resolves_to_the_root_not_its_parent(tmp_path: Path) -> None:
    """Claude's worker identity is flat under the main session, so nesting flattens."""
    events = [
        _created(_CHILD, _ROOT),
        _created(_GRANDCHILD, _CHILD),
        _asked(_GRANDCHILD),
    ]

    forwarded = _run_bridge(tmp_path, events)

    assert forwarded[-1] == _stamped("PermissionRequest", _ROOT, _GRANDCHILD, request_id=_PERMISSION)
    assert forwarded[1] == _stamped("SessionStart", _ROOT, _GRANDCHILD)


@needs_bun
def test_session_updated_fills_the_map_but_is_never_forwarded(tmp_path: Path) -> None:
    events = [_created(_CHILD, _ROOT, name="session.updated"), _busy(_CHILD)]

    forwarded = _run_bridge(tmp_path, events)

    assert forwarded == [_stamped("UserPromptSubmit", _ROOT, _CHILD)]


@needs_bun
def test_a_deleted_session_is_forgotten(tmp_path: Path) -> None:
    events = [
        _created(_CHILD, _ROOT),
        _created(_CHILD, _ROOT, name="session.deleted"),
        _busy(_CHILD),
    ]

    forwarded = _run_bridge(tmp_path, events)

    assert forwarded[-1] == {"hook_event_name": "UserPromptSubmit", "session_id": _CHILD}


@needs_bun
@pytest.mark.parametrize(
    "bad_parent",
    ["a" * 129, "/private/project", "token_sk_live_1", "control\nvalue", 7, ["ses_a"], {"id": "x"}, ""],
)
def test_an_invalid_parent_leaves_the_child_top_level(tmp_path: Path, bad_parent: object) -> None:
    bad = _created(_CHILD, _ROOT)
    bad["properties"]["info"]["parentID"] = bad_parent  # type: ignore[index]

    forwarded = _run_bridge(tmp_path, [bad, _busy(_CHILD)])

    assert forwarded[-1] == {"hook_event_name": "UserPromptSubmit", "session_id": _CHILD}


@needs_bun
def test_a_message_parent_is_never_read_as_a_session_parent(tmp_path: Path) -> None:
    """message.updated also carries info.parentID, but that names a message."""
    message = {
        "type": "message.updated",
        "properties": {
            "sessionID": _OTHER,
            "info": {"id": "msg_test0000000000000000000002", "sessionID": _OTHER, "parentID": "msg_test0000000000000000000001"},
        },
    }

    forwarded = _run_bridge(tmp_path, [message, _busy("msg_test0000000000000000000002")])

    assert forwarded == [{"hook_event_name": "UserPromptSubmit", "session_id": "msg_test0000000000000000000002"}]


@needs_bun
def test_a_cycle_falls_back_to_top_level_and_does_not_hang(tmp_path: Path) -> None:
    events = [_created(_CHILD, _GRANDCHILD), _created(_GRANDCHILD, _CHILD), _busy(_CHILD)]

    forwarded = _run_bridge(tmp_path, events)

    assert forwarded[-1] == {"hook_event_name": "UserPromptSubmit", "session_id": _CHILD}


@needs_bun
def test_a_session_that_names_itself_as_parent_stays_top_level(tmp_path: Path) -> None:
    forwarded = _run_bridge(tmp_path, [_created(_CHILD, _CHILD), _busy(_CHILD)])

    assert forwarded[-1] == {"hook_event_name": "UserPromptSubmit", "session_id": _CHILD}


def _wide(index: int) -> str:
    """A distinct, maximum-length (128 character) session id."""
    return f"ses_{index:08d}".ljust(128, "x")


@needs_bun
def test_the_map_is_bounded_evicts_the_oldest_and_keeps_an_active_child(tmp_path: Path) -> None:
    active = _wide(0)
    root = _wide(999_999)
    events: list[dict[str, object]] = [_created(active, root)]
    for index in range(1, 601):
        events.append(_created(_wide(index), root))
        if index % 100 == 0:
            # An active child is seen again and again, so it is never the oldest.
            events.append(_busy(active))
    events.extend([_busy(active), _busy(_wide(1)), _busy(_wide(600)), _asked(active, "p" * 128)])

    forwarded = _run_bridge(tmp_path, events)

    active_busy, oldest_busy, newest_busy, widest_ask = forwarded[-4:]
    assert active_busy == _stamped("UserPromptSubmit", root, active)
    # The oldest child was evicted, so it reads as top-level again.
    assert oldest_busy == {"hook_event_name": "UserPromptSubmit", "session_id": _wide(1)}
    assert newest_busy == _stamped("UserPromptSubmit", root, _wide(600))
    # Four maximum-length ids plus the fixed fields stay inside the 1024-byte cap.
    assert widest_ask == _stamped("PermissionRequest", root, active, request_id="p" * 128)
    assert len(json.dumps(widest_ask, separators=(",", ":"))) <= 1024
