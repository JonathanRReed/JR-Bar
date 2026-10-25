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
