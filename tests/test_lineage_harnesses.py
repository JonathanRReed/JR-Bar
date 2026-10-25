"""Synthetic provider schemas and durable hook lineage."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from jrbar.agent_groups import resolve_agent_groups
from jrbar.collector import status_from_event
from jrbar.hook import _normalized_hook_record
from jrbar.lineage_adapters import cursor_native_id, t3_parent_links
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_adapters import normalized_provider_record_from_payload, normalized_provider_record_to_payload
from jrbar.providers import parse_log_line

NOW = 1_790_000_000.0
FIXTURES = Path(__file__).parent / 'fixtures' / 'lineage' / 'v1'


def fixture(name):
    return json.loads((FIXTURES / name).read_text())


def row(key, links=()):
    return AgentStatus(key.split(':')[0], key, 'Synthetic agent', AgentMode.WORKING,
                       datetime.fromtimestamp(NOW, timezone.utc), 'PreToolUse', parent_links=links)


def replay(provider, payload):
    payload = dict(payload, logged_at=datetime.fromtimestamp(NOW, timezone.utc).isoformat())
    normalized = _normalized_hook_record(provider, payload)
    encoded = normalized_provider_record_to_payload(normalized)
    assert normalized_provider_record_from_payload(encoded) == normalized
    event = parse_log_line(provider, json.dumps(encoded))
    return status_from_event(event), encoded


def test_cursor_child_identity_and_parent_survive_normalization():
    data = fixture('cursor-docs-2026-10-25.json')
    child, encoded = replay('cursor', data)
    root = row('cursor:session:' + cursor_native_id('cursor-parent'))
    assert child.agent_id == 'cursor:session:' + cursor_native_id('cursor-worker')
    group, = resolve_agent_groups([root, child], now=NOW).groups
    assert group.members == tuple(sorted([root.agent_id, child.agent_id]))
    assert 'synthetic content' not in json.dumps(encoded)


def test_cursor_missing_parent_is_unlinked():
    data = fixture('cursor-docs-2026-10-25.json')
    data.pop('parent_conversation_id')
    child, _ = replay('cursor', data)
    result = resolve_agent_groups([child], now=NOW)
    assert result.unlinked_workers == {child.agent_id}
    assert result.groups == ()


def test_t3_cursor_child_with_native_worker_resolves_one_group():
    threads = [dict(thread_id='root', default_provider='codex', active_provider_thread_id='p-root'),
               dict(thread_id='cursor-child', default_provider='cursor', active_provider_thread_id='p-child',
                    payload_json={'lineage': {'relationshipToParent': 'subagent', 'parentThreadId': 'root'}})]
    bindings = [dict(thread_id=tid, provider_thread_id=pid, driver=provider,
                     payload_json={'nativeThreadRef': {'driver': provider, 'nativeId': native}})
                for tid, pid, provider, native in [('root', 'p-root', 'codex', 'root-native'),
                                                   ('cursor-child', 'p-child', 'cursor', 'cursor-parent')]]
    keys, links = t3_parent_links(threads, bindings, observed_at=NOW)
    worker, _ = replay('cursor', fixture('cursor-docs-2026-10-25.json'))
    rows = [row(key, tuple(link for link in links if link.child == key)) for key in keys.values()]
    group, = resolve_agent_groups([*rows, worker], now=NOW).groups
    assert group.root_work_key == keys['root']
    assert len(group.members) == 3


def test_hermes_hook_and_database_use_the_same_session_identity(tmp_path):
    import sqlite3

    from jrbar.lineage_adapters import LocalLineageReader, read_hermes_links

    data = fixture('hermes-state-db-v0-docs-2026-10-25.json')
    child, encoded = replay('hermes', data)
    database = tmp_path / '.hermes/state.db'
    database.parent.mkdir()
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE sessions(id TEXT, parent_session_id TEXT, started_at REAL, system_prompt TEXT)')
        connection.execute('INSERT INTO sessions VALUES (?, ?, ?, ?)',
                           ('hermes-child-session', 'hermes-root', NOW, 'synthetic content'))
    before = database.read_bytes()
    assert read_hermes_links(database, observed_at=NOW) == child.parent_links
    providers = frozenset({'hermes'})
    recovered = LocalLineageReader(tmp_path).read(providers, now=NOW)
    assert recovered == LocalLineageReader(tmp_path).read(providers, now=NOW)
    group, = resolve_agent_groups([row('hermes:session:hermes-root'), *recovered], now=NOW).groups
    assert child.agent_id in group.members
    assert database.read_bytes() == before
    assert 'synthetic content' not in json.dumps(encoded)


def test_hermes_missing_parent_is_unlinked():
    data = fixture('hermes-state-db-v0-docs-2026-10-25.json')
    data['parent_session_id'] = None
    child, _ = replay('hermes', data)
    assert resolve_agent_groups([child], now=NOW).unlinked_workers == {child.agent_id}


def test_hermes_nested_hook_and_agent_only_fallback():
    data = fixture('hermes-state-db-v0-docs-2026-10-25.json')
    parent, _ = replay('hermes', data)
    data.update(child_session_id='nested-session', parent_session_id='hermes-child-session',
                parent_subagent_id='hermes-worker', child_subagent_id='nested-worker')
    child, _ = replay('hermes', data)
    group, = resolve_agent_groups([row('hermes:session:hermes-root'), parent, child], now=NOW).groups
    assert len(group.members) == 3
    data['child_session_id'] = None
    orphan, _ = replay('hermes', data)
    assert orphan.agent_id == 'hermes:session:nested-session'


def test_opencode_restart_backfills_parent_ids_without_content(tmp_path):
    import sqlite3

    from jrbar.lineage_adapters import LocalLineageReader, match_opencode_roster, opencode_parent_links

    info = fixture('opencode-1.19.3.json')['properties']['info']
    expected = opencode_parent_links(info, observed_at=NOW)
    database = tmp_path / '.local/share/opencode/opencode.db'
    database.parent.mkdir(parents=True)
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE session(id TEXT, parent_id TEXT, time_updated INTEGER, title TEXT)')
        connection.executemany('INSERT INTO session VALUES (?, ?, ?, ?)',
                               [(info['id'], info['parentID'], int(NOW * 1000), 'synthetic content'),
                                ('nested', info['id'], int(NOW * 1000), 'synthetic content')])
    before = database.read_bytes()
    providers = frozenset({'opencode'})
    recovered = LocalLineageReader(tmp_path).read(providers, now=NOW)
    assert recovered == LocalLineageReader(tmp_path).read(providers, now=NOW)
    assert next(r for r in recovered if r.agent_id.endswith('opencode-child')).parent_links == expected
    root = row('opencode:session:opencode-root')
    child = row('opencode:agent:opencode-child')
    nested = row('opencode:agent:nested')
    recovered = match_opencode_roster(recovered, frozenset(r.agent_id for r in [root, child, nested]))
    from jrbar.collector import _merged_status_candidates
    merged = _merged_status_candidates([root, child, nested, *recovered])
    group, = resolve_agent_groups(merged, now=NOW).groups
    assert len(group.members) == 3
    assert database.read_bytes() == before


def test_opencode_missing_parent_and_ambiguous_roster_stay_unlinked():
    from jrbar.lineage_adapters import match_opencode_roster, opencode_parent_links

    info = fixture('opencode-1.19.3.json')['properties']['info']
    info['parentID'] = ''
    links = opencode_parent_links(info, observed_at=NOW)
    child = row(links[0].child, links)
    assert resolve_agent_groups([child], now=NOW).unlinked_workers == {child.agent_id}
    observed = frozenset({child.agent_id, child.agent_id.replace(':session:', ':agent:')})
    matched = match_opencode_roster((child,), observed)
    assert len(matched) == 2
    assert all(r.parent_links[0].parent is None for r in matched)
    assert resolve_agent_groups(matched, now=NOW).unlinked_workers == observed


def test_openclaw_registry_recovers_newer_native_parent_id(tmp_path):
    from jrbar.lineage_adapters import LocalLineageReader

    path = tmp_path / '.openclaw/agents/synthetic/sessions/sessions.json'
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps(fixture('openclaw-nesting-docs-2026-10-25.json')))
    before = path.read_bytes()
    providers = frozenset({'openclaw'})
    rows = LocalLineageReader(tmp_path).read(providers, now=NOW)
    assert rows == LocalLineageReader(tmp_path).read(providers, now=NOW)
    group, = resolve_agent_groups([row('openclaw:session:agent:synthetic:main'), *rows], now=NOW).groups
    assert len(group.members) == 2
    assert path.read_bytes() == before


def test_openclaw_missing_parent_is_unlinked():
    child, _ = replay('openclaw', {'hook_event_name': 'UserPromptSubmit',
                                 'session_id': 'agent:synthetic:subagent:worker', 'spawnedBy': ''})
    assert resolve_agent_groups([child], now=NOW).unlinked_workers == {child.agent_id}


def test_openclaw_bridge_forwards_only_bounded_parent_fields(tmp_path):
    import shutil
    import subprocess
    import sys

    import pytest

    from jrbar.providers import (
        _openclaw_handler_v2_source_for_arguments,
        legacy_openclaw_handler_source_for_arguments,
        managed_openclaw_handler_log_path,
        openclaw_handler_source_for_arguments,
    )

    node = shutil.which('node')
    if not node:
        pytest.skip('node unavailable')
    target = tmp_path / 'forwarded.json'
    script = tmp_path / 'capture.py'
    script.write_text('import sys\nfrom pathlib import Path\nPath(sys.argv[1]).write_text(sys.stdin.read())\n')
    # Hook argv validation requires the normal command shape; replace spawn
    # only in this test runner to capture the bridge's actual outgoing bytes.
    log = tmp_path / 'openclaw.jsonl'
    args = [sys.executable, '-m', 'jrbar.hook_client', '--provider', 'openclaw', '--log', str(log)]
    source = openclaw_handler_source_for_arguments(args)
    for version in (source, _openclaw_handler_v2_source_for_arguments(args), legacy_openclaw_handler_source_for_arguments(args)):
        assert managed_openclaw_handler_log_path(version) == log
        assert managed_openclaw_handler_log_path(version + '// changed') is None
    source = source.replace('JRBAR_HOOK_ARGS[0],\n        JRBAR_HOOK_ARGS.slice(1),',
                            json.dumps(sys.executable) + ',\n        ' + json.dumps([str(script), str(target)]) + ',')
    event = fixture('openclaw-2026.3.2.json')
    event['context']['sessionEntry']['spawnedBySessionId'] = 'openclaw-root-native'
    source = source.replace('export default handler;', 'await handler(' + json.dumps(event) + ');')
    runner = tmp_path / 'bridge.mjs'
    runner.write_text(source)
    subprocess.run([node, str(runner)], check=True, capture_output=True, timeout=10)
    payload = json.loads(target.read_text())
    assert payload['spawnedBy'] == 'agent:synthetic:main'
    assert payload['spawnedBySessionId'] == 'openclaw-root-native'
    child, encoded = replay('openclaw', payload)
    group, = resolve_agent_groups([row('openclaw:session:agent:synthetic:main'), child], now=NOW).groups
    assert len(group.members) == 2
    assert 'synthetic content' not in json.dumps(encoded)


def test_gemini_recording_layout_recovers_after_restart(tmp_path):
    import os

    from jrbar.lineage_adapters import LocalLineageReader

    path = tmp_path / '.gemini/tmp/synthetic-project/chats/gemini-root/gemini-child.jsonl'
    path.parent.mkdir(parents=True)
    path.write_bytes((FIXTURES / 'gemini-cli-0.46.0.jsonl').read_bytes())
    os.utime(path, (NOW, NOW))
    providers = frozenset({'gemini'})
    recovered = LocalLineageReader(tmp_path).read(providers, now=NOW)
    assert recovered == LocalLineageReader(tmp_path).read(providers, now=NOW)
    group, = resolve_agent_groups([row('gemini:session:gemini-root'), *recovered], now=NOW).groups
    assert group.members == ('gemini:session:gemini-child', 'gemini:session:gemini-root')
    assert all('synthetic content' not in str(r) for r in recovered)
    assert LocalLineageReader(tmp_path).read(providers, now=NOW + 86_401) == ()


def test_gemini_child_recording_without_parent_directory_is_unlinked(tmp_path):
    import os

    from jrbar.lineage_adapters import LocalLineageReader

    path = tmp_path / '.gemini/tmp/synthetic-project/chats/gemini-child.jsonl'
    path.parent.mkdir(parents=True)
    path.write_bytes((FIXTURES / 'gemini-cli-0.46.0.jsonl').read_bytes())
    os.utime(path, (NOW, NOW))
    child, = LocalLineageReader(tmp_path).read(frozenset({'gemini'}), now=NOW)
    assert resolve_agent_groups([child], now=NOW).unlinked_workers == {child.agent_id}


def test_gemini_layout_never_groups_ordinary_sessions_by_project():
    from jrbar.lineage_adapters import gemini_parent_links
    assert gemini_parent_links({'kind': 'main', 'sessionId': 'ordinary'},
                               observed_at=NOW, parent_session_id='shared-folder') == ()


def test_grok_recovers_parent_before_a_childs_next_event(tmp_path, monkeypatch):
    import time

    from jrbar.grok_children import GROK_CHILD_LINKS, GrokChildLinks
    from jrbar.hook import process_hook_payload, routed_hook_payload
    from jrbar.lineage_adapters import LocalLineageReader

    monkeypatch.setattr(time, 'time', lambda: NOW)
    GROK_CHILD_LINKS.clear()
    log = tmp_path / '.local/state/jrbar/grok.jsonl'
    data = fixture('grok-1.0.70.json')
    stamp = datetime.fromtimestamp(NOW, timezone.utc).isoformat()
    process_hook_payload('grok', log, json.dumps(data), logged_at=stamp, refresh=False)
    restored = GrokChildLinks(clock=lambda: NOW)
    restored.recover(log, now=NOW)  # The background reader runs before the next event.
    _, _, stamped = routed_hook_payload('grok', log, json.dumps({
        'hook_event_name': 'PreToolUse', 'sessionId': 'grok-child', 'subagentType': 'general-purpose'
    }), logged_at=stamp, child_links=restored)
    assert stamped['agent_id'] == 'grok-child'
    assert stamped['session_id'] == 'grok-root'
    assert stamped['lineage_observed_at'] == NOW
    recovered = LocalLineageReader(tmp_path).read(frozenset({'grok'}), now=NOW)
    group, = resolve_agent_groups([row('grok:session:grok-root'), *recovered], now=NOW).groups
    assert len(group.members) == 2
    assert recovered == LocalLineageReader(tmp_path).read(frozenset({'grok'}), now=NOW)
    stale = GrokChildLinks()
    stale.recover(log, now=NOW + 86_401)
    assert stale.root_of('grok-child') is None
    GROK_CHILD_LINKS.clear()


def test_grok_missing_parent_is_dim_and_live_links_are_refreshed():
    from jrbar.grok_children import GrokChildLinks, stamp_child_identity

    unknown, _ = replay('grok', {'hook_event_name': 'PreToolUse', 'sessionId': 'unseen-child',
                               'subagentType': 'general-purpose'})
    assert resolve_agent_groups([unknown], now=NOW).unlinked_workers == {unknown.agent_id}
    links = GrokChildLinks()
    links.remember('old-child', 'old-root', observed_at=NOW - 86_401)
    stamped = stamp_child_identity({'hook_event_name': 'PreToolUse', 'sessionId': 'old-child'}, links, now=NOW)
    child, _ = replay('grok', stamped)
    assert child.parent_links[0].observed_at == NOW
    assert not resolve_agent_groups([row('grok:session:old-root'), child], now=NOW).unlinked_workers


def test_cursor_and_hermes_links_survive_later_parentless_hooks_and_restart(tmp_path):
    from jrbar.hook import process_hook_payload
    from jrbar.lineage_adapters import LocalLineageReader

    for provider, name, root_id in [('cursor', 'cursor-docs-2026-10-25.json', cursor_native_id('cursor-parent')),
                                    ('hermes', 'hermes-state-db-v0-docs-2026-10-25.json', 'hermes-root')]:
        log = tmp_path / f'.local/state/jrbar/{provider}.jsonl'
        stamp = datetime.fromtimestamp(NOW, timezone.utc).isoformat()
        process_hook_payload(provider, log, json.dumps(fixture(name)), logged_at=stamp, refresh=False)
        progress = ({'hook_event_name': 'preToolUse', 'conversation_id': 'cursor-worker'} if provider == 'cursor'
                    else {'hook_event_name': 'pre_tool_call', 'session_id': 'hermes-child-session'})
        process_hook_payload(provider, log, json.dumps(progress), logged_at=stamp, refresh=False)
        recovered = LocalLineageReader(tmp_path).read(frozenset({provider}), now=NOW)
        assert len(recovered) == 1
        assert recovered == LocalLineageReader(tmp_path).read(frozenset({provider}), now=NOW)
        group, = resolve_agent_groups([row(f'{provider}:session:{root_id}'), *recovered], now=NOW).groups
        assert len(group.members) == 2


def test_kiro_and_antigravity_workers_with_no_parent_stay_unlinked():
    for provider in ('kiro', 'antigravity'):
        child = row(f'{provider}:agent:synthetic-worker')
        assert resolve_agent_groups([child], now=NOW).unlinked_workers == {child.agent_id}


def test_live_hint_preserves_cursor_lineage_after_a_parentless_progress_event(tmp_path):
    from jrbar.collector import LiveAgentMonitor
    from jrbar.hook import process_hook_payload
    from jrbar.operator_state import BootIdentifier, ClockSample

    clock = ClockSample(NOW, 100.0, BootIdentifier('synthetic-boot'))
    monitor = LiveAgentMonitor(clock_sampler=lambda: clock)
    log = tmp_path / 'cursor.jsonl'
    stamp = datetime.fromtimestamp(NOW, timezone.utc).isoformat()
    def feed(payload):
        process_hook_payload('cursor', log, json.dumps(payload), logged_at=stamp,
                             refresh_hint_handler=lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log))
    feed({'hook_event_name': 'beforeSubmitPrompt', 'conversation_id': 'cursor-parent'})
    feed(fixture('cursor-docs-2026-10-25.json'))
    feed({'hook_event_name': 'preToolUse', 'conversation_id': 'cursor-worker'})
    snapshot = monitor.snapshot()
    result = resolve_agent_groups((*snapshot.statuses, *snapshot.stale_statuses), now=NOW)
    group, = result.groups
    assert len(group.members) == 2
    assert not result.unlinked_workers


def test_live_grok_worker_keeps_its_group_after_twenty_four_hours(tmp_path, monkeypatch):
    import time

    from jrbar.collector import LiveAgentMonitor
    from jrbar.grok_children import GROK_CHILD_LINKS
    from jrbar.hook import process_hook_payload
    from jrbar.operator_state import BootIdentifier, ClockSample

    monkeypatch.setattr(time, 'time', lambda: NOW)
    GROK_CHILD_LINKS.clear()
    GROK_CHILD_LINKS.remember('grok-child', 'grok-root', observed_at=NOW - 86_401)
    clock = ClockSample(NOW, 100.0, BootIdentifier('synthetic-boot'))
    monitor = LiveAgentMonitor(clock_sampler=lambda: clock)
    log = tmp_path / 'grok.jsonl'
    stamp = datetime.fromtimestamp(NOW, timezone.utc).isoformat()
    for payload in [{'hook_event_name': 'UserPromptSubmit', 'sessionId': 'grok-root'},
                    {'hook_event_name': 'PreToolUse', 'sessionId': 'grok-child', 'subagentType': 'general-purpose'}]:
        process_hook_payload('grok', log, json.dumps(payload), logged_at=stamp,
                             refresh_hint_handler=lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log))
    snapshot = monitor.snapshot()
    result = resolve_agent_groups((*snapshot.statuses, *snapshot.stale_statuses), now=NOW)
    assert not result.unlinked_workers
    assert result.groups[0].members == ('grok:agent:grok-child', 'grok:session:grok-root')
    GROK_CHILD_LINKS.clear()


def test_malformed_hook_lineage_extension_is_rejected():
    from copy import deepcopy
    _, encoded = replay('cursor', fixture('cursor-docs-2026-10-25.json'))
    for bad in (None, [], [{}], [{'child': 'cursor:session:child', 'parent': 'grok:session:parent',
                                 'harness': 'cursor', 'observed_at': NOW}]):
        payload = deepcopy(encoded)
        payload['parent_links'] = bad
        assert normalized_provider_record_from_payload(payload) is None
    for field, value in [('observed_at', float('nan')), ('parent', '/private/path'), ('harness', 't3code')]:
        payload = deepcopy(encoded)
        payload['parent_links'][0][field] = value
        assert normalized_provider_record_from_payload(payload) is None


def test_t3_native_cursor_task_ref_uses_the_same_identity_as_its_hooks():
    threads = [dict(thread_id='root', default_provider='codex', active_provider_thread_id='p-root')]
    bindings = [dict(thread_id='root', provider_thread_id='p-root', driver='codex',
                     payload_json={'nativeThreadRef': {'driver': 'codex', 'nativeId': 'root-native'}})]
    _, links = t3_parent_links(threads, bindings, observed_at=NOW, subagents=[{
        'thread_id': 'root', 'status': 'running', 'native_task_ref': {'driver': 'cursor', 'nativeId': 'cursor-parent'}}])
    assert links[0].child == 'cursor:session:' + cursor_native_id('cursor-parent')


def test_session_database_schema_drift_fails_closed(tmp_path):
    import sqlite3

    from jrbar.lineage_adapters import read_hermes_links, read_opencode_links
    database = tmp_path / 'unsupported.db'
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE unrelated(id TEXT)')
    before = database.read_bytes()
    assert read_hermes_links(database, observed_at=NOW) == ()
    assert read_opencode_links(database, observed_at=NOW) == ()
    assert database.read_bytes() == before


def test_openclaw_conflicting_parent_fields_are_rejected():
    from jrbar.lineage_adapters import openclaw_parent_links
    links = openclaw_parent_links({'session_id': 'child', 'spawnedBy': 'root-a',
                                   'spawnedBySessionId': 'native-b'},
                                  observed_at=NOW, session_keys={'native-b': 'root-b'})
    child = row('openclaw:session:child', links)
    result = resolve_agent_groups([row('openclaw:session:root-a'), row('openclaw:session:root-b'), child], now=NOW)
    assert child.agent_id in result.unlinked_workers


def test_grok_recovers_older_normalized_logs_without_the_lineage_extension(tmp_path):
    from jrbar.grok_children import GrokChildLinks
    child, encoded = replay('grok', {'hook_event_name': 'SubagentStart', 'agent_id': 'legacy-child',
                                    'session_id': 'legacy-root'})
    assert child.parent_links
    encoded.pop('parent_links')
    log = tmp_path / 'grok.jsonl'
    log.write_text(json.dumps(encoded) + '\n')
    restored = GrokChildLinks()
    restored.recover(log, now=NOW)
    assert restored.root_of('legacy-child') == 'legacy-root'


def test_raw_parent_links_cannot_forge_groups_or_drop_events():
    for provider, identity in [('cursor', {'conversation_id': 'synthetic-root'}),
                               ('grok', {'session_id': 'synthetic-root'}),
                               ('hermes', {'session_id': 'synthetic-root'})]:
        for bad in ('bad', [{'child': f'{provider}:session:forged', 'parent': f'{provider}:session:root',
                            'harness': provider, 'observed_at': NOW}]):
            status, encoded = replay(provider, dict(hook_event_name='PreToolUse' if provider != 'hermes' else 'pre_tool_call',
                                                   **identity, parent_links=bad))
            assert not status.parent_links
            assert 'parent_links' not in encoded


def test_hook_log_reads_only_appends_and_handles_partial_rotation_and_rewrite(tmp_path, monkeypatch):
    from jrbar import lineage_adapters as adapters
    reader = adapters.HookLineageReader()
    log = tmp_path / 'grok.jsonl'
    def encoded(child):
        return replay('grok', {'hook_event_name': 'PreToolUse', 'session_id': 'root',
                              'agent_id': child})[1]
    first = json.dumps(encoded('child-a')) + '\n'
    log.write_text(first)
    original = adapters.json.loads
    parsed = []
    def capture(raw):
        parsed.append(raw)
        return original(raw)
    monkeypatch.setattr(adapters.json, 'loads', capture)
    assert len(reader.read(log, 'grok', now=NOW)) == 1
    assert len(parsed) == 1
    assert len(reader.read(log, 'grok', now=NOW)) == 1
    assert len(parsed) == 1
    second = json.dumps(encoded('child-b'))
    parsed.clear()
    with log.open('a') as stream:
        stream.write(second[:100])
    assert len(reader.read(log, 'grok', now=NOW)) == 1
    assert not parsed
    with log.open('a') as stream:
        stream.write(second[100:] + '\n')
    assert {link.child for link in reader.read(log, 'grok', now=NOW)} == {'grok:agent:child-a', 'grok:agent:child-b'}
    assert len(parsed) == 1
    replacement = tmp_path / 'rotated'
    replacement.write_text(first)
    replacement.replace(log)
    assert [link.child for link in reader.read(log, 'grok', now=NOW)] == ['grok:agent:child-a']
    log.write_text(first.replace('child-a', 'child-c'))
    assert [link.child for link in reader.read(log, 'grok', now=NOW)] == ['grok:agent:child-c']
    assert reader.read(log, 'grok', now=NOW + 86_401) == ()


def test_grok_recovery_never_holds_hook_intake_and_unknown_child_is_searched_once(tmp_path, monkeypatch):
    import threading

    from jrbar.grok_children import GrokChildLinks
    from jrbar.hook import routed_hook_payload

    entered, release, finished = threading.Event(), threading.Event(), threading.Event()
    links = GrokChildLinks(clock=lambda: NOW)
    calls = []
    def blocked(path, *, now):
        calls.append((path, now))
        entered.set()
        assert release.wait(5)
        finished.set()
    monkeypatch.setattr(links, 'recover', blocked)
    payload = json.dumps({'hook_event_name': 'PreToolUse', 'sessionId': 'unknown', 'subagentType': 'worker'})
    stamp = datetime.fromtimestamp(NOW, timezone.utc).isoformat()
    try:
        result = routed_hook_payload('grok', tmp_path / 'grok.jsonl', payload, logged_at=stamp,
                                     child_links=links, clock=lambda: NOW)
        assert entered.wait(5)
        assert result[2]['sessionId'] == 'unknown'
        other = routed_hook_payload('claude', tmp_path / 'claude.jsonl',
                                    '{"hook_event_name":"PermissionRequest","session_id":"root"}', logged_at=stamp)
        assert other[2]['hook_event_name'] == 'PermissionRequest'
        routed_hook_payload('grok', tmp_path / 'grok.jsonl', payload, logged_at=stamp, child_links=links)
        assert len(calls) == 1
    finally:
        release.set()
        assert finished.wait(5)


def test_openclaw_large_registry_keeps_newest_entries_and_caches_parse(tmp_path, monkeypatch):
    from jrbar import lineage_adapters as adapters
    path = tmp_path / '.openclaw/agents/synthetic/sessions/sessions.json'
    path.parent.mkdir(parents=True)
    entries = {f'agent:synthetic:subagent:w-{i}': dict(sessionId=f'worker-{i}',
               spawnedBySessionId='root-native', updatedAt=(NOW + i / 1000) * 1000,
               history='synthetic content' * 100) for i in range(600)}
    entries['agent:synthetic:main'] = dict(sessionId='root-native', updatedAt=0)
    path.write_text(json.dumps(entries))
    assert path.stat().st_size > 512 * 1024
    original = adapters.json.loads
    parsed = []
    monkeypatch.setattr(adapters.json, 'loads', lambda raw: parsed.append(len(raw)) or original(raw))
    rows = adapters.read_openclaw_links(tmp_path)
    assert len(rows) == 512
    assert {link.parent for link in rows} == {'openclaw:session:agent:synthetic:main'}
    assert all(link.child.startswith('openclaw:agent:') for link in rows)
    assert 'openclaw:agent:agent:synthetic:subagent:w-0' not in {link.child for link in rows}
    assert rows == adapters.read_openclaw_links(tmp_path)
    assert len(parsed) == 1
    assert len(adapters.read_openclaw_links(tmp_path, active_ids={'agent:synthetic:subagent:w-599'})) == 1
    assert len(parsed) == 1


def test_openclaw_parentless_worker_kind_can_receive_registry_evidence():
    from jrbar.collector import _merged_status_candidates
    from jrbar.lineage_adapters import openclaw_parent_links
    key = 'agent:synthetic:subagent:orphan'
    child, _ = replay('openclaw', {'hook_event_name': 'UserPromptSubmit', 'session_id': key})
    assert child.agent_id == 'openclaw:agent:' + key
    assert child.is_subagent
    assert not child.parent_links
    assert resolve_agent_groups([child], now=NOW).unlinked_workers == {child.agent_id}
    links = openclaw_parent_links({'session_id': key, 'spawnedBySessionId': 'root-native'},
                                  observed_at=NOW, session_keys={'root-native': 'root'})
    evidence = AgentStatus('openclaw', child.agent_id, 'Worker', AgentMode.UNKNOWN,
                           child.updated_at, 'LineageObserved', parent_links=links)
    group, = resolve_agent_groups(_merged_status_candidates([row('openclaw:session:root'), child, evidence]), now=NOW).groups
    assert len(group.members) == 2
    raw, _ = replay('openclaw', {'hook_event_name': 'UserPromptSubmit', 'session_id': key,
                                'spawnedBySessionId': 'only-native-root'})
    assert raw.parent_links[0].parent == 'openclaw:session:only-native-root'


def test_active_file_paths_do_not_discover_inactive_sessions(tmp_path, monkeypatch):
    from jrbar.lineage_adapters import LocalLineageReader
    path = tmp_path / '.gemini/tmp/project/chats/root/child.jsonl'
    path.parent.mkdir(parents=True)
    path.write_text('{"kind":"subagent","sessionId":"child"}\n')
    import os
    os.utime(path, (NOW, NOW))
    reader = LocalLineageReader(tmp_path)
    monkeypatch.setattr(reader, '_changed_paths', lambda *a, **k: (_ for _ in ()).throw(AssertionError('full scan')))
    assert reader.read(frozenset({'gemini'}), now=NOW, active_paths=()) == ()
    child, = reader.read(frozenset({'gemini'}), now=NOW, active_paths=(path,))
    assert child.agent_id == 'gemini:session:child'
    assert reader.read(frozenset({'gemini'}), now=NOW, active_paths=()) == ()


def test_database_window_active_ids_and_finished_workers_never_create_roster_rows(tmp_path):
    import sqlite3

    from jrbar.collector import LiveAgentMonitor
    from jrbar.lineage_adapters import LocalLineageReader, read_hermes_links, read_opencode_links
    from jrbar.operator_state import BootIdentifier, ClockSample
    for provider, relative, schema, insert, scale, reader in [
        ('hermes', '.hermes/state.db', 'sessions(id TEXT, parent_session_id TEXT, started_at REAL)',
         'sessions', 1, read_hermes_links),
        ('opencode', '.local/share/opencode/opencode.db', 'session(id TEXT, parent_id TEXT, time_updated INTEGER)',
         'session', 1000, read_opencode_links),
    ]:
        path = tmp_path / relative
        path.parent.mkdir(parents=True)
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE ' + schema)
            db.executemany('INSERT INTO ' + insert + ' VALUES (?,?,?)', [
                ('old', 'root', (NOW - 86_401) * scale), ('active', 'root', NOW * scale),
                ('finished', 'root', (NOW - 100) * scale)])
        assert {link.child.split(':', 2)[2] for link in reader(path, observed_at=NOW)} == {'active', 'finished'}
        assert {link.child.split(':', 2)[2] for link in reader(path, observed_at=NOW, active_ids={'active'})} == {'active'}
        assert reader(path, observed_at=NOW, active_ids=()) == ()
        rows = LocalLineageReader(tmp_path).read(frozenset({provider}), now=NOW)
        monitor = LiveAgentMonitor(clock_sampler=lambda: ClockSample(NOW, 100, BootIdentifier('synthetic')))
        monitor.replace_external_statuses('lineage', rows)
        snapshot = monitor.snapshot()
        assert not (*snapshot.statuses, *snapshot.stale_statuses)


def test_restart_recovery_uses_configured_hook_path(tmp_path, monkeypatch):
    from jrbar import providers
    from jrbar.hook import process_hook_payload
    from jrbar.lineage_adapters import LocalLineageReader
    path = tmp_path / 'custom-log/cursor-events.jsonl'
    process_hook_payload('cursor', path, json.dumps(fixture('cursor-docs-2026-10-25.json')),
                         logged_at=datetime.fromtimestamp(NOW, timezone.utc).isoformat(), refresh=False)
    seen = []
    monkeypatch.setattr(providers, 'detect_log_path', lambda provider, home: seen.append((provider, home)) or path)
    child, = LocalLineageReader(tmp_path).read(frozenset({'cursor'}), now=NOW)
    assert child.parent_links[0].parent == 'cursor:session:' + cursor_native_id('cursor-parent')
    assert seen == [('cursor', tmp_path)]


def test_t3_native_opencode_and_grok_workers_match_hook_agent_keys():
    threads = [dict(thread_id='root', default_provider='codex', active_provider_thread_id='p-root')]
    bindings = [dict(thread_id='root', provider_thread_id='p-root', driver='codex',
                     payload_json={'nativeThreadRef': {'driver': 'codex', 'nativeId': 'root-native'}})]
    for provider in ('opencode', 'grok'):
        _, links = t3_parent_links(threads, bindings, observed_at=NOW, subagents=[{
            'thread_id': 'root', 'status': 'running', 'native_task_ref': {'driver': provider, 'nativeId': 'worker'}}])
        assert links[0].child == provider + ':agent:worker'


def test_hermes_explicit_aliases_reconcile_hooks_database_and_restart(tmp_path):
    from jrbar import lineage_adapters as adapters
    from jrbar.collector import _merged_status_candidates
    from jrbar.hook import process_hook_payload
    adapters._HERMES_ALIASES.clear()
    stamp = datetime.fromtimestamp(NOW, timezone.utc).isoformat()
    log = tmp_path / 'hermes.jsonl'
    for child, session, parent, parent_session in [('alias-parent', 'session-parent', None, 'root'),
                                                  ('alias-child', 'session-child', 'alias-parent', 'session-parent')]:
        process_hook_payload('hermes', log, json.dumps(dict(hook_event_name='subagent_start',
            child_subagent_id=child, child_session_id=session, parent_subagent_id=parent,
            parent_session_id=parent_session)), logged_at=stamp, refresh=False)
    child, encoded = replay('hermes', dict(hook_event_name='subagent_start', child_subagent_id='alias-child',
                                           parent_subagent_id='alias-parent'))
    assert encoded['provider_work_id'] == 'session-child'
    assert child.parent_links[0].parent == 'hermes:session:session-parent'
    # A DB session relationship supplies the parent when the subagent alias is unavailable.
    unknown, _ = replay('hermes', dict(hook_event_name='subagent_start', child_session_id='session-child',
                                      parent_subagent_id='unseen-alias'))
    evidence = adapters.hermes_parent_links({'child_session_id': 'session-child', 'parent_session_id': 'session-parent'}, observed_at=NOW)
    dbrow = AgentStatus('hermes', child.agent_id, 'Worker', AgentMode.UNKNOWN, child.updated_at,
                         'LineageObserved', parent_links=evidence)
    merged = _merged_status_candidates([row('hermes:session:session-parent'), unknown, dbrow])
    assert len(resolve_agent_groups(merged, now=NOW).groups[0].members) == 2
    adapters._HERMES_ALIASES.clear()
    recovered = adapters.HookLineageReader().read(log, 'hermes', now=NOW)
    assert recovered
    restored, _ = replay('hermes', dict(hook_event_name='subagent_start', child_subagent_id='alias-child',
                                       parent_subagent_id='alias-parent'))
    assert restored.agent_id == 'hermes:session:session-child'
    assert restored.parent_links[0].parent == 'hermes:session:session-parent'


def test_hook_lineage_read_modify_replace_keeps_the_monitor_lock(tmp_path, monkeypatch):
    from jrbar.collector import LiveAgentMonitor
    from jrbar.hook import process_hook_payload
    from jrbar.operator_state import BootIdentifier, ClockSample
    monitor = LiveAgentMonitor(clock_sampler=lambda: ClockSample(NOW, 100, BootIdentifier('synthetic')))
    original = monitor.replace_external_statuses
    checked = []
    def replace(source, rows):
        if source.startswith('hook-lineage-'):
            assert monitor.lock._is_owned()
            checked.append(source)
        original(source, rows)
    monkeypatch.setattr(monitor, 'replace_external_statuses', replace)
    log = tmp_path / 'cursor.jsonl'
    for child in ('first', 'second'):
        process_hook_payload('cursor', log, json.dumps(dict(hook_event_name='subagentStart', subagent_id=child,
            conversation_id='root', parent_conversation_id='root')),
            logged_at=datetime.fromtimestamp(NOW, timezone.utc).isoformat(),
            refresh_hint_handler=lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log))
    assert len(checked) == 2
    assert len(monitor._external_statuses_by_source['hook-lineage-cursor']) == 2


def test_background_grok_recovery_links_the_live_unknown_worker_without_a_new_hook(tmp_path):
    from jrbar.collector import LiveAgentMonitor
    from jrbar.grok_children import GROK_CHILD_LINKS
    from jrbar.hook import process_hook_payload
    from jrbar.lineage_adapters import grok_parent_links, hook_lineage_statuses
    from jrbar.operator_state import BootIdentifier, ClockSample
    GROK_CHILD_LINKS.clear()
    monitor = LiveAgentMonitor(clock_sampler=lambda: ClockSample(NOW, 100, BootIdentifier('synthetic')))
    log = tmp_path / 'grok.jsonl'
    for data in [{'hook_event_name': 'UserPromptSubmit', 'sessionId': 'root'},
                 {'hook_event_name': 'PreToolUse', 'sessionId': 'worker', 'subagentType': 'general-purpose'}]:
        process_hook_payload('grok', log, json.dumps(data), logged_at=datetime.fromtimestamp(NOW, timezone.utc).isoformat(),
                             refresh_hint_handler=lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log))
    links = grok_parent_links({'agent_id': 'worker', 'session_id': 'root'}, observed_at=NOW)
    monitor.replace_external_statuses('lineage', hook_lineage_statuses(links, now=NOW))
    snapshot = monitor.snapshot()
    assert snapshot.agent_group_resolution.groups[0].members == ('grok:agent:worker', 'grok:session:root')
    assert not snapshot.agent_group_resolution.unlinked_workers
    assert len((*snapshot.statuses, *snapshot.stale_statuses)) == 2
    GROK_CHILD_LINKS.clear()


def test_fresh_live_link_replaces_an_older_copy_from_background_recovery():
    from jrbar.collector import _merged_status_candidates
    from jrbar.lineage_adapters import grok_parent_links
    child = row('grok:agent:worker', grok_parent_links({'agent_id': 'worker', 'session_id': 'root'}, observed_at=NOW))
    old = AgentStatus('grok', child.agent_id, 'Worker', AgentMode.UNKNOWN,
                       datetime.fromtimestamp(NOW - 86_401, timezone.utc), 'LineageObserved',
                       parent_links=grok_parent_links({'agent_id': 'worker', 'session_id': 'root'}, observed_at=NOW - 86_401))
    merged = _merged_status_candidates([row('grok:session:root'), child, old])
    assert not resolve_agent_groups(merged, now=NOW).unlinked_workers


def test_legacy_shortened_cursor_record_keeps_the_hashed_work_id():
    _, normal = replay('cursor', {'hook_event_name': 'postToolUse', 'conversation_id': 'legacy-conversation'})
    _, shortened = replay('cursor', {'hook_event_name': 'postToolUse', 'session_id': 'legacy-conversation',
                                     'payload_truncated': True})
    assert shortened['provider_work_id'] == normal['provider_work_id']
    assert 'legacy-conversation' not in json.dumps(shortened)


def test_hermes_equal_subagent_and_session_ids_still_resolve_parent_aliases():
    from jrbar.lineage_adapters import hermes_identity_aliases
    hermes_identity_aliases({'child_subagent_id': 'same-parent-id', 'child_session_id': 'same-parent-id'})
    child, _ = replay('hermes', {'hook_event_name': 'subagent_start', 'child_session_id': 'equal-alias-child',
                                 'parent_subagent_id': 'same-parent-id'})
    assert child.parent_links[0].parent == 'hermes:session:same-parent-id'


def test_normalized_hermes_aliases_reject_malformed_or_foreign_extensions():
    from copy import deepcopy
    _, encoded = replay('hermes', fixture('hermes-state-db-v0-docs-2026-10-25.json'))
    assert encoded['identity_aliases'] == [['hermes-worker', 'hermes-child-session']]
    for bad in (None, [], ['alias', 'session'], [[None, 'session']], [['alias', '/private/path']],
                [['alias', 'session', 'extra']], [['a', 'b']] * 3):
        altered = deepcopy(encoded)
        altered['identity_aliases'] = bad
        assert normalized_provider_record_from_payload(altered) is None
    _, cursor = replay('cursor', fixture('cursor-docs-2026-10-25.json'))
    cursor['identity_aliases'] = [['alias', 'session']]
    assert normalized_provider_record_from_payload(cursor) is None
