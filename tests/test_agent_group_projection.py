"""Agent groups reach the protocol, light programs and quiet-ask policy."""
from __future__ import annotations

import json
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

import pytest

from jrbar.agent_groups import active_agent_groups, resolve_agent_groups
from jrbar.attention import project_attention
from jrbar.colors import ColorSettings, plan_fleet_projection, program_for_projection
from jrbar.core_projection import build_state_document
from jrbar.models import AgentMode, ParentLink
from jrbar.settings import AgentMonitorSettings
from tests.test_agent_groups import NOW, seven_members, snapshot, status


def test_t3_cross_provider_native_children_resolve_seven_members_one_claude_group():
    rows = seven_members()
    result = resolve_agent_groups(rows, now=NOW)
    assert not result.unlinked_workers
    assert len(result.groups) == 1
    group = result.groups[0]
    assert group.root_work_key == "claude:session:native-root"
    assert group.root_provider == "claude"
    assert len(group.members) == 7
    assert len(group.lineage_evidence) == 6
    assert active_agent_groups(snapshot(rows)) == result.groups
    projection = project_attention(snapshot(rows), AgentMonitorSettings())
    assert [row.agent_id for row in projection.light_rows] == [group.root_work_key]
    assert active_agent_groups(projection) == result.groups
    assert len(plan_fleet_projection(projection).member_slots) == 1
    expected = project_attention(snapshot([status(group.root_work_key)]), AgentMonitorSettings())
    assert program_for_projection(projection, colors=ColorSettings.defaults()) == program_for_projection(expected, colors=ColorSettings.defaults())
    published = build_state_document(now=NOW, generation=1, snapshot=snapshot(rows), ask_statuses=(), unseen_completion_ids=())
    assert published["agent_groups"] == [group.to_dict()]
    by_id = {row["id"]: row for row in published["sessions"]}
    assert by_id[group.root_work_key]["workers"] == 6
    assert all(row["parent"] == group.root_work_key and row["kind"] == "worker"
               for key, row in by_id.items() if key != group.root_work_key)


@pytest.mark.parametrize("problem", ["cycle", "missing", "conflict", "stale", "future"])
def test_unproved_worker_never_gets_a_share(problem):
    root, child = "claude:session:root", "codex:session:child"
    links = [ParentLink(child, root, "t3code", NOW)]
    root_links = ()
    if problem == "cycle":
        root_links = (ParentLink(root, child, "t3code", NOW),)
    elif problem == "missing":
        links = [replace(links[0], parent="claude:session:absent")]
    elif problem == "conflict":
        links += [replace(links[0], parent="claude:session:absent")]
    elif problem == "stale":
        links = [replace(links[0], observed_at=NOW-86_401)]
    elif problem == "future":
        links = [replace(links[0], observed_at=NOW+6)]
    rows = [status(root, links=root_links), status(child, links=links)]
    result = resolve_agent_groups(rows, now=NOW)
    assert child in result.unlinked_workers
    projection = project_attention(snapshot(rows), AgentMonitorSettings())
    assert child not in {row.agent_id for row in projection.light_rows}
    document = build_state_document(now=NOW, generation=1, snapshot=snapshot(rows), ask_statuses=(), unseen_completion_ids=())
    assert next(row for row in document["sessions"] if row["id"] == child)["unlinked_worker"]


def test_unlinked_native_worker_has_no_share_but_asks_stay_individual():
    child = status("claude:agent:orphan")
    quiet = project_attention(snapshot([child]), AgentMonitorSettings())
    assert quiet.light_rows == ()
    asking = replace(child, mode=AgentMode.WAITING_FOR_INPUT, event_name="PermissionRequest")
    assert [row.agent_id for row in project_attention(snapshot([asking]), AgentMonitorSettings()).light_rows] == [child.agent_id]
    loud = project_attention(snapshot([asking]), replace(AgentMonitorSettings(), subagent_asks_alert=True))
    assert [row.agent_id for row in loud.light_rows] == [child.agent_id]
    assert len(loud.actionable_attention) == 1


def test_grouped_asks_keep_their_provider_and_identity():
    rows = seven_members()
    worker = "codex:session:native-codex-worker"
    rows = tuple(replace(s, mode=AgentMode.WAITING_FOR_INPUT, event_name="PermissionRequest")
                 if s.agent_id == worker else s for s in rows)
    quiet = project_attention(snapshot(rows), AgentMonitorSettings())
    assert not quiet.actionable_attention
    loud = project_attention(snapshot(rows), replace(AgentMonitorSettings(), subagent_asks_alert=True))
    assert ("codex", worker) in [(row.provider, row.agent_id) for row in loud.light_rows]


def test_unrelated_sessions_never_merge_by_folder_origin_or_machine():
    rows = [status("claude:session:a", cwd="/synthetic/repo", origin="same"),
            status("claude:session:b", cwd="/synthetic/repo", origin="same")]
    assert len(resolve_agent_groups(rows, now=NOW).groups) == 2
    assert len(plan_fleet_projection(project_attention(snapshot(rows), AgentMonitorSettings())).member_slots) == 2


def test_swift_group_fixture_is_the_daemons_current_document():
    document = build_state_document(now=NOW, generation=1, snapshot=snapshot(seven_members()),
                                    ask_statuses=(), unseen_completion_ids=())
    saved = json.loads((Path(__file__).parents[1] / "app/Tests/JRBarCoreTests/Fixtures/python-agent-groups.json").read_text())
    assert saved["agent_groups"] == document["agent_groups"]
    assert saved["sessions"] == document["sessions"]


def test_cross_provider_lineage_keeps_canonical_worker_requests_quiet():
    from jrbar.attention import quiet_worker_request_keys
    from tests.test_attention import _canonical_permission_request_snapshot

    canonical = _canonical_permission_request_snapshot(session_id="child", agent_id=None)
    native = canonical.statuses[0]
    linked = replace(native, parent_links=(ParentLink(native.agent_id, "codex:session:root", "t3code", NOW),))
    assert quiet_worker_request_keys(canonical.operator_state, subagent_asks_alert=False) == frozenset()
    assert quiet_worker_request_keys(canonical.operator_state, subagent_asks_alert=False, statuses=[linked, status("codex:session:root")], collected_at=datetime.fromtimestamp(NOW, timezone.utc)) == {native.request_key}
    assert quiet_worker_request_keys(canonical.operator_state, subagent_asks_alert=True, statuses=[linked]) == frozenset()


def test_provider_pin_follows_group_root_colour_and_keeps_child_activity():
    from jrbar.device_projection import light_rows_for_provider, projection_for_provider

    rows = tuple(replace(s, mode=AgentMode.IDLE_READY) if s.provider == "claude" else s for s in seven_members())
    projection = project_attention(snapshot(rows), AgentMonitorSettings())
    assert light_rows_for_provider(projection, "codex") == ()
    pinned = projection_for_provider(projection, "claude")
    assert [(row.provider, row.agent_id, row.lifecycle_mode.value) for row in pinned.light_rows] == [
        ("claude", "claude:session:native-root", "active"),
    ]


def test_rejected_link_cannot_promote_an_idle_root_but_failure_stays_named():
    from jrbar.delegation import _reconcile_delegating_parents

    root = status("claude:session:root", mode=AgentMode.IDLE_READY)
    child = status("codex:session:child", links=[ParentLink("codex:session:child", root.agent_id, "t3code", NOW-86_401)])
    reconciled = _reconcile_delegating_parents((root, child), datetime.fromtimestamp(NOW, timezone.utc))
    assert reconciled[0].mode is AgentMode.IDLE_READY
    projection = project_attention(snapshot([root, child]), AgentMonitorSettings())
    assert projection.light_rows[0].lifecycle_mode.value == "idle"
    failed = replace(child, mode=AgentMode.BLOCKED_ERROR, event_name="StopFailure")
    assert project_attention(snapshot([failed]), AgentMonitorSettings()).transient_signals == ()


def test_header_only_metadata_never_promotes_a_parent_to_working():
    from jrbar.delegation import _reconcile_delegating_parents

    root = status("factory:session:root", mode=AgentMode.IDLE_READY)
    child = status("factory:session:child", mode=AgentMode.UNKNOWN,
                   links=[ParentLink("factory:session:child", root.agent_id, "factory", NOW)])
    reconciled = _reconcile_delegating_parents((root, child), datetime.fromtimestamp(NOW, timezone.utc))
    assert reconciled[0].mode is AgentMode.IDLE_READY



def test_quiet_worker_policy_reuses_snapshot_resolution_at_collection_time(monkeypatch):
    from jrbar.attention import quiet_waiting_worker_ids, quiet_worker_request_keys
    from tests.test_attention import _canonical_permission_request_snapshot

    canonical = _canonical_permission_request_snapshot(session_id='child', agent_id=None)
    native = canonical.statuses[0]
    linked = replace(native, parent_links=(ParentLink(native.agent_id, 'codex:session:root', 't3code', NOW),))
    rows = [linked, status('codex:session:root')]
    collected = replace(canonical, statuses=tuple(rows), stale_statuses=(), collected_at=datetime.fromtimestamp(NOW + 86_401, timezone.utc))
    resolution = collected.agent_group_resolution
    assert native.agent_id in resolution.unlinked_workers
    monkeypatch.setattr('jrbar.agent_groups.resolve_agent_groups', lambda *a, **kw: pytest.fail('resolved twice'))
    assert quiet_worker_request_keys(canonical.operator_state, subagent_asks_alert=False,
                                     statuses=rows, resolution=resolution) == frozenset()
    assert quiet_waiting_worker_ids(rows, AgentMonitorSettings(), resolution=resolution) == frozenset()


def test_ambient_fleet_uses_one_band_and_one_completion_for_cross_provider_group(monkeypatch):
    from types import SimpleNamespace

    from jrbar import ambient_effect_runtime as ambient
    from jrbar.operator_state import TransitionKind
    from jrbar.provider_facts import SourceKey, WorkIdentifier, WorkKey, WorkLifecycle
    from tests.test_ambient_effect_runtime import _canonical_state, _operator_event

    state, root_key, _, watermark = _canonical_state(lifecycle=WorkLifecycle.COMPLETED)
    child_key = WorkKey(SourceKey('claude', 'hooks', 'local:01', 'live_agent_events'), WorkIdentifier('child'))
    state = replace(state, works=(*state.works, replace(state.works[0], key=child_key, watermark=replace(watermark, source_key=child_key.source_key))))
    root = replace(status('codex:session:root'), work_key=root_key)
    child = replace(status('claude:session:child', links=[ParentLink('claude:session:child', root.agent_id, 't3code', NOW)]), work_key=child_key)
    from jrbar.collector import MonitorSnapshot
    from jrbar.models import AggregateStatus
    collected = datetime.fromtimestamp(NOW, timezone.utc)
    roster = MonitorSnapshot(aggregate=AggregateStatus(AgentMode.WORKING, 2, 0, None), statuses=(root, child), stale_statuses=(), sources=(), collected_at=collected)
    controller = SimpleNamespace(last_snapshot=roster)
    fleet = ambient._fleet_plan(controller, state)
    assert len(fleet.member_slots) == 1
    completions = []
    monkeypatch.setattr(ambient, 'plan_firefly_completion', lambda evidence, *a, **kw: completions.append(evidence))
    for key in (child_key, root_key):
        ambient._completion_firefly(controller, _operator_event(key, TransitionKind.COMPLETED, replace(watermark, source_key=key.source_key)),
                                    state, fleet, reduce_motion=False)
    assert len(completions) == 1
    assert completions[0].fleet_identity == ambient._opaque_work_identity(root_key, 'fleet')


@pytest.mark.parametrize("raw_snapshot", [False, True])
@pytest.mark.parametrize("parent_working", [False, True])
def test_everyone_gives_a_t3_group_one_share_beside_a_solo_codex(raw_snapshot, parent_working):
    from jrbar.colors import program_for_snapshot
    from jrbar.led_wasm import RawSdLedWasmController
    from jrbar.light_mix import explain_what_plays

    root = status("claude:session:synthetic-parent",
                  mode=AgentMode.WORKING if parent_working else AgentMode.IDLE_READY)
    workers = tuple(status(key, links=[ParentLink(key, root.agent_id, "t3code", NOW)])
                    for key in ("codex:session:synthetic-worker", "factory:session:synthetic-worker"))
    solo = status("codex:session:synthetic-solo")
    unlinked = status("factory:agent:synthetic-unlinked", session_id="missing")
    rows = (root, *workers, solo, unlinked)
    colors = ColorSettings.defaults().with_blend_mode("round_robin").with_agent_animation("codex", "kitt")
    projection = project_attention(snapshot(rows), AgentMonitorSettings())
    assert len(active_agent_groups(projection)) == 2
    assert {row.agent_id for row in projection.light_rows} == {root.agent_id, solo.agent_id}
    result = explain_what_plays(rows if raw_snapshot else projection, colors, led_count=8)
    assert [(row["provider"], row["animation"]) for row in result["providers"]] == [
        ("codex", "kitt"), ("claude", "auto"),
    ]
    assert result["played"] == "round_robin"
    assert result["warnings"] == []
    expected_rows = (replace(root, mode=AgentMode.WORKING), solo)
    assert result["program"] == program_for_snapshot(expected_rows, colors=colors)[1]
    firmware = RawSdLedWasmController(8)
    assert firmware.parse(result["program"], 0).ok
    assert len({tuple(frame) for frame in firmware.step_batch(0, 40, 120)}) > 4
