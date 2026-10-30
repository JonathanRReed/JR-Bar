"""Synthetic Open origins crossed with every session-opening entry point."""
from __future__ import annotations

import json
import sqlite3
from dataclasses import replace
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from jrbar import core_runtime, daemon_controller, session_actions
from jrbar.collector import _merged_status_candidates
from jrbar.core_projection import project_session_rows
from jrbar.lineage_adapters import t3_parent_links
from jrbar.models import AgentMode, AgentStatus, ParentLink
from jrbar.navigation_policy import NavigationCandidate
from jrbar.provider_facts import SourceFreshness, SourceKey, WorkIdentifier, WorkKey
from jrbar.session_navigation import T3_BUNDLE_ID, resolve_open_navigation, t3_open_targets, valid_t3_url
from jrbar.settings import AgentMonitorSettings
from jrbar.t3_compat import _deep_link, read_t3_snapshot
from tests.test_t3_v2_compat import _run, _thread, _v2

NOW = datetime(2026, 10, 7, 12, tzinfo=timezone.utc)
ORIGINS = ("codex-cli", "codex-app", "codex-t3", "claude-t3", "t3-native", "unproven-worker", "t3-no-env")
SURFACES = ("notch", "panel", "status-menu", "notification", "overview", "history", "stream-deck", "jrbar-link")


def row(provider="codex", native="native-session", **kwargs):
    return AgentStatus(provider, f"{provider}:session:{native}", "Synthetic task", AgentMode.WAITING_FOR_INPUT,
                       NOW, "Notification", session_id=native, cwd="/repo/synthetic", **kwargs)


def origin_rows(origin):
    provider = "claude" if origin == "claude-t3" else "codex"
    status = row(provider, origin="CLI" if origin in {"codex-cli", "unproven-worker"} else "App")
    if origin in {"codex-t3", "claude-t3", "t3-native", "t3-no-env"}:
        status = replace(status, t3_thread_id="thread-1", t3_open_url=_deep_link(
            None if origin == "t3-no-env" else "env-1", "thread-1"))
    if origin == "t3-native":
        status = replace(status, session_id=None)
    if origin == "unproven-worker":
        status = replace(status, parent_links=(ParentLink(status.agent_id, None, provider, NOW.timestamp()),))
    key = WorkKey(SourceKey(provider, "hook", "default", "sessions"), WorkIdentifier(origin))
    return (replace(status, work_key=key),)


def expected(origin):
    if origin == "t3-no-env":
        return "app", T3_BUNDLE_ID
    if origin in {"codex-t3", "claude-t3", "t3-native"}:
        return "url", "t3code://threads/env-1/thread-1"
    if origin in {"codex-cli", "unproven-worker"}:
        return "terminal", "cd /repo/synthetic && codex resume native-session"
    return "url", "codex://threads/native-session"


@pytest.mark.parametrize("origin", ORIGINS)
@pytest.mark.parametrize("surface", SURFACES)
def test_open_surface_origin_matrix(monkeypatch, origin, surface):
    statuses = origin_rows(origin)
    status = statuses[0]
    calls = []
    monkeypatch.setattr(daemon_controller, "open_url", lambda value: calls.append(("url", value)))
    monkeypatch.setattr(daemon_controller, "open_application", lambda value: calls.append(("app", value)))
    monkeypatch.setattr(daemon_controller, "open_terminal_command", lambda value: calls.append(("terminal", value)))
    monkeypatch.setattr("jrbar.answer_surfaces.open_session_surface", lambda *a, **k: None)
    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(statuses=statuses, stale_statuses=(), collected_at=NOW),
        current_operator_state=SimpleNamespace(generation=4), settings=AgentMonitorSettings(),
        _core_extras_for=lambda status: None,
        set_settings_message=lambda message: pytest.fail(message),
    )
    controller.open_session = lambda status, action, remember: daemon_controller.StatusBarController.open_session(
        controller, status, action, remember=remember)
    own = session_actions.session_open_target(status, session_actions.default_session_open_action(status))
    controller.navigation_candidates_by_work_key = {status.work_key: (
        (NavigationCandidate(status.work_key, 4, "open:primary", *own, SourceFreshness.FRESH, True),) if own else ()
    )}
    if surface == "status-menu":
        controller.open_session(status, "terminal" if status.t3_thread_id else None, remember=False)
    elif surface == "stream-deck":
        resolution = resolve_open_navigation(controller, status.work_key)
        assert session_actions.activate_navigation_resolution(
            resolution, open_url=daemon_controller.open_url,
            open_terminal_command=daemon_controller.open_terminal_command,
            open_application=daemon_controller.open_application)
    elif surface == "history":
        core_runtime._cmd_resume_session(controller, {"session": status.agent_id})
    else:
        reply = core_runtime._cmd_open_session(controller, {"session": status.agent_id})
        if status.t3_thread_id:
            assert (reply["open_target"]["kind"], reply["open_target"]["value"]) == expected(origin)
            assert reply["activated"] == "T3 Code"
    assert calls == [expected(origin)]
    rows, _ = project_session_rows(controller.last_snapshot, ask_statuses=statuses, now=NOW.timestamp())
    projected = rows[0]
    if status.t3_thread_id:
        target = projected["open_target"]
        assert (target["kind"], target["value"]) == expected(origin)
    elif origin == "unproven-worker":
        assert projected["open_target"] is None
        assert projected["open_target_reason"] == "unproven_worker_provider_route"


@pytest.mark.parametrize("provider,driver", [("codex", "codex"), ("claude", "claudeAgent")])
@pytest.mark.parametrize("environment", [None, "env-1"])
def test_read_binding_survives_provider_ask_merge(tmp_path, provider, driver, environment):
    database = _v2(tmp_path)
    _thread(database, "thread-1", provider=driver, active_provider_thread_id="binding-1")
    _run(database, "thread-1", 1, "running", provider=driver, provider_thread="binding-1")
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE orchestration_v2_projection_provider_threads "
                           "(provider_thread_id TEXT, thread_id TEXT, driver TEXT, provider_instance_id TEXT, payload_json TEXT)")
        native = {"nativeThreadRef": {"driver": driver, "nativeId": "native-session"}}
        connection.execute("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?)",
                           ("binding-1", "thread-1", driver, "default", json.dumps(native)))
    before = database.read_bytes()
    snapshot = read_t3_snapshot(base_dir=tmp_path, environment_id=environment, now=lambda: NOW)
    observed = snapshot.agent_statuses()[0]
    hook = row(provider, origin="CLI")
    merged = _merged_status_candidates((observed, hook))
    status = next(status for status in merged if status.agent_id == hook.agent_id)
    assert status.mode is AgentMode.WAITING_FOR_INPUT
    assert status.t3_thread_id == "thread-1"
    assert status.t3_open_url == _deep_link(environment, "thread-1")
    assert database.read_bytes() == before


@pytest.mark.parametrize("rejection", ["accepted", "missing", "stale", "conflict", "cycle"])
def test_worker_uses_only_proven_host_chain(rejection):
    root = row("claude", "parent", t3_thread_id="parent-thread",
               t3_open_url=_deep_link("env-1", "parent-thread"))
    child = row("codex", "worker")
    stamp = NOW.timestamp() - (100_000 if rejection == "stale" else 0)
    link = ParentLink(child.agent_id, "claude:session:missing" if rejection == "missing" else root.agent_id,
                      "t3code", stamp)
    links = (link,)
    if rejection == "conflict":
        links += (replace(link, parent=None),)
    if rejection == "cycle":
        root = replace(root, parent_links=(ParentLink(root.agent_id, child.agent_id, "t3code", stamp),))
    child = replace(child, parent_links=links)
    targets = t3_open_targets((root, child), now=NOW.timestamp())
    if rejection == "accepted":
        assert targets[child.agent_id].value == root.t3_open_url
    else:
        assert child.agent_id not in targets


def test_conflicting_native_hosts_do_not_pick_a_thread():
    first = row(t3_thread_id="first", t3_open_url=_deep_link("env", "first"))
    second = replace(first, t3_thread_id="second", t3_open_url=_deep_link("env", "second"))
    merged = _merged_status_candidates((first, second))
    assert t3_open_targets(merged, now=NOW.timestamp()) == {}


def test_t3_open_skips_terminal_probe_and_answer_lane(monkeypatch):
    status = origin_rows("codex-t3")[0]
    calls = []
    monkeypatch.setattr("jrbar.answer_surfaces.open_session_surface", lambda *a, **k: pytest.fail("terminal probe"))
    monkeypatch.setattr("jrbar.answer_decisions.release_for_open", lambda *a, **k: pytest.fail("answer lane"))
    controller = SimpleNamespace(last_snapshot=SimpleNamespace(statuses=(status,), collected_at=NOW),
                                 open_session=lambda *a, **k: calls.append(a), _core_extras_for=lambda status: None)
    core_runtime._cmd_open_session(controller, {"session": status.agent_id, "action": "raise"})
    assert len(calls) == 1


@pytest.mark.parametrize("url,allowed", [
    ("t3code://threads/env-1/thread-1", True),
    ("t3code://threads/env%20one/thread%2Fone", True),
    ("t3code://threads/thread-1", False),
    ("t3code://threads/env-1/thread-1?prompt=answer", False),
    ("t3code://new?prompt=answer", False),
    ("https://example.invalid/threads/env/thread", False),
])
def test_t3_url_allowlist(url, allowed):
    assert valid_t3_url(url) is allowed


def test_unproven_binding_never_joins_a_provider():
    threads = [{"thread_id": "a", "default_provider": "codex", "active_provider_thread_id": "binding"},
               {"thread_id": "b", "default_provider": "codex", "active_provider_thread_id": "binding"}]
    bindings = [{"thread_id": tid, "provider_thread_id": "binding", "driver": "codex",
                 "payload_json": {"nativeThreadRef": {"driver": "codex", "nativeId": "native-session"}}}
                for tid in ("a", "b")]
    keys, _ = t3_parent_links(threads, bindings, observed_at=NOW.timestamp())
    assert "codex:session:native-session" not in keys.values()


@pytest.mark.parametrize("origin", ["codex-t3", "claude-t3", "t3-native", "t3-no-env"])
def test_operator_and_physical_deck_reveal_use_host_binding(monkeypatch, origin):
    from jrbar.agent_browser_payloads import AgentBrowserActionPayload
    from jrbar.daemon_controller import _canonical_operator_actions
    from jrbar.deck_control_center import reveal_deck_session
    from jrbar.navigation_policy import OperatorActionKind
    from tests.test_navigation_policy import _work_truth

    status = origin_rows(origin)[0]
    work = _work_truth(status.work_key)
    state = SimpleNamespace(generation=4, works=(work,), requests=())
    calls = []
    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(statuses=(status,), stale_statuses=(), collected_at=NOW),
        current_operator_state=state,
    )
    controller.performAgentBrowserPayload_ = lambda payload: daemon_controller.StatusBarController.performAgentBrowserPayload_(
        controller, payload)
    monkeypatch.setattr(daemon_controller, "open_url", lambda value: calls.append(("url", value)))
    monkeypatch.setattr(daemon_controller, "open_application", lambda value: calls.append(("app", value)))
    actions = _canonical_operator_actions(state, controller)[status.work_key]
    assert next(action for action in actions if action.kind is OperatorActionKind.OPEN).enabled
    payload = AgentBrowserActionPayload(status.work_key, 4, OperatorActionKind.OPEN)
    assert controller.performAgentBrowserPayload_(payload)
    assert not controller.performAgentBrowserPayload_(replace(payload, generation=3))
    board = SimpleNamespace(navigation_target=lambda identity, revision: status if revision == 7 else None)
    monkeypatch.setattr("jrbar.deck_control_center.ensure_deck_board", lambda controller: board)
    assert reveal_deck_session(controller, "synthetic-key", 7).success
    assert not reveal_deck_session(controller, "synthetic-key", 6).success
    assert calls == [expected(origin), expected(origin)]


def test_history_outside_roster_uses_current_t3_observation(monkeypatch):
    status = origin_rows("codex-t3")[0]
    observation = SimpleNamespace(available=True, reason=None, statuses=(status,))
    calls = []
    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(statuses=(), stale_statuses=(), collected_at=NOW),
        _t3_snapshot_service=SimpleNamespace(observation=lambda: observation),
        settings=AgentMonitorSettings(), _core_extras_for=lambda status: None,
    )
    controller.open_session = lambda status, action, remember: daemon_controller.StatusBarController.open_session(
        controller, status, action, remember=remember)
    monkeypatch.setattr(daemon_controller, "open_url", calls.append)
    monkeypatch.setattr("jrbar.answer_surfaces.resume_ended_session", lambda *a, **k: pytest.fail("provider resume"))
    core_runtime._cmd_resume_session(controller, {"session": status.agent_id})
    assert calls == [status.t3_open_url]


def test_t3_app_fallback_launches_only_the_registered_bundle(monkeypatch):
    commands = []
    monkeypatch.setattr(daemon_controller.subprocess, "Popen", lambda command, **kwargs: commands.append(command))
    status = origin_rows("t3-no-env")[0]
    controller = SimpleNamespace(last_snapshot=SimpleNamespace(statuses=(status,), collected_at=NOW))
    daemon_controller.StatusBarController.open_session(controller, status, "terminal", remember=True)
    assert commands == [["/usr/bin/open", "-b", T3_BUNDLE_ID]]


def test_t3_open_observation_does_not_expand_answer_lookup():
    from jrbar.core_server import CommandError

    status = origin_rows("codex-t3")[0]
    observation = SimpleNamespace(available=True, reason=None, statuses=(status,))
    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(statuses=(), stale_statuses=(), collected_at=NOW),
        _t3_snapshot_service=SimpleNamespace(observation=lambda: observation),
    )
    assert core_runtime._find_open_status(controller, status.agent_id) == status
    with pytest.raises(CommandError, match="no such session"):
        core_runtime._find_status(controller, status.agent_id)


@pytest.mark.parametrize("stale", [False, True])
def test_canonical_hook_ask_keeps_external_t3_binding(stale):
    from jrbar.collector import LiveAgentMonitor
    from jrbar.provider_facts import WorkLifecycle
    from tests.test_canonical_collector import _batch, _clock

    monitor = LiveAgentMonitor(clock_sampler=_clock)
    monitor.ingest_batch(_batch(WorkLifecycle.WAITING, 1, work_id="native-session", request_live=True), clock=_clock())
    observed = replace(origin_rows("codex-t3")[0], stale=stale,
                       updated_at=NOW if stale else datetime.fromtimestamp(_clock().wall_epoch, timezone.utc))
    monitor.replace_external_statuses("t3code", (observed,))
    snapshot = monitor.snapshot()
    status = next(status for status in snapshot.statuses if status.agent_id == observed.agent_id)
    assert status.is_hard_ask
    assert not status.stale
    assert status.t3_thread_id == observed.t3_thread_id
    assert t3_open_targets(snapshot.statuses, now=snapshot.collected_at.timestamp())[status.agent_id].value == observed.t3_open_url


@pytest.mark.parametrize("provider", session_actions.provider_session_opener_providers())
@pytest.mark.parametrize("environment", [None, "env-1"])
def test_host_precedence_does_not_depend_on_provider(provider, environment):
    status = row(provider, t3_thread_id="thread-1", t3_open_url=_deep_link(environment, "thread-1"))
    target = t3_open_targets((status,), now=NOW.timestamp())[status.agent_id]
    assert (target.kind, target.value) == (
        ("app", T3_BUNDLE_ID) if environment is None else ("url", "t3code://threads/env-1/thread-1")
    )


def test_direct_menu_hook_row_uses_current_roster_host(monkeypatch):
    hosted = origin_rows("codex-t3")[0]
    raw_hook = replace(hosted, t3_thread_id=None, t3_open_url=None, origin="CLI")
    calls = []
    controller = SimpleNamespace(last_snapshot=SimpleNamespace(statuses=(hosted,), collected_at=NOW))
    monkeypatch.setattr(daemon_controller, "open_url", calls.append)
    daemon_controller.StatusBarController.open_session(controller, raw_hook, "terminal", remember=False)
    assert calls == [hosted.t3_open_url]


@pytest.mark.parametrize("listed", [False, True])
@pytest.mark.parametrize("environment", [None, "env-1"])
def test_stopped_t3_keeps_navigation_without_phantom_activity(monkeypatch, listed, environment):
    from jrbar.collector import LiveAgentMonitor
    from jrbar.provider_facts import WorkLifecycle
    from tests.test_canonical_collector import _batch, _clock

    monitor = LiveAgentMonitor(clock_sampler=_clock)
    observed = replace(origin_rows("codex-t3")[0], t3_open_url=_deep_link(environment, "thread-1"))
    monitor.replace_external_statuses("t3code", (observed,))
    if listed:
        monitor.ingest_batch(_batch(WorkLifecycle.WAITING, 1, work_id="native-session", request_live=True), clock=_clock())
    monitor.replace_external_statuses("t3code", ())
    snapshot = monitor.snapshot()
    assert len(snapshot.statuses) == int(listed)
    calls = []
    controller = SimpleNamespace(last_snapshot=snapshot, monitor=monitor, _core_extras_for=lambda status: None)
    controller.open_session = lambda status, action, remember: daemon_controller.StatusBarController.open_session(
        controller, status, action, remember=remember)
    monkeypatch.setattr(daemon_controller, "open_url", lambda value: calls.append(("url", value)))
    monkeypatch.setattr(daemon_controller, "open_application", lambda value: calls.append(("app", value)))
    monkeypatch.setattr("jrbar.answer_surfaces.resume_ended_session", lambda *a, **k: pytest.fail("provider resume"))
    monkeypatch.setattr("jrbar.answer_surfaces.open_session_surface", lambda *a, **k: pytest.fail("terminal probe"))
    core_runtime._cmd_resume_session(controller, {"session": observed.agent_id})
    assert calls == [("url", _deep_link(environment, "thread-1")) if environment else ("app", T3_BUNDLE_ID)]
    monitor.replace_external_statuses("t3code", ())
    assert len(monitor.snapshot().statuses) == int(listed)
