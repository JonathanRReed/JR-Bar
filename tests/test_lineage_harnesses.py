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
    assert orphan.agent_id == 'hermes:session:nested-worker'


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
    matched, = match_opencode_roster((child,), observed)
    assert matched.parent_links[0].parent is None


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
