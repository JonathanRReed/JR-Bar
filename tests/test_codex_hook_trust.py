from __future__ import annotations

from pathlib import Path

from jrbar.codex_hook_trust import (
    hook_identity_hash,
    hook_state_key,
    normalized_timeout,
    trusted_hashes_for_config,
)

# Hashes Codex 0.153.4 itself wrote into a real config.toml for this exact
# command (a pre-rename install; the literal is a fixture and must not be
# modernised). The algorithm must reproduce them byte for byte.
COMMAND = (
    "/Users/jonathanreed/Downloads/sidepulse-JR-Fork/.venv/bin/python "
    "/Users/jonathanreed/Downloads/sidepulse-JR-Fork/src/sidepulse/hook_entry.py "
    "--provider codex --log /Users/jonathanreed/.local/state/sidepulse/agent-monitor/codex.jsonl"
)
KNOWN = {
    "SessionStart": "sha256:50d208423ba289319dd21dc390163ef9af2188f703c3c824ddde924edcb3b208",
    "PreToolUse": "sha256:f5c5056e9ce099f7a4bbb62021357346b86044e21f0d4ec9b8aa7007a317431a",
    "Stop": "sha256:188d617d8db44a845989694f346f905d3a447afffe5019af363f45411910c930",
}


def test_hash_matches_codex_for_matcher_events():
    assert hook_identity_hash("SessionStart", command=COMMAND, matcher="*") == KNOWN["SessionStart"]
    assert hook_identity_hash("PreToolUse", command=COMMAND, matcher="*") == KNOWN["PreToolUse"]


def test_hash_drops_matcher_for_matcherless_events():
    assert hook_identity_hash("Stop", command=COMMAND, matcher="*") == KNOWN["Stop"]
    assert hook_identity_hash("Stop", command=COMMAND, matcher=None) == KNOWN["Stop"]


def test_timeout_normalization():
    assert normalized_timeout("PreToolUse", None) == 600
    assert normalized_timeout("PreToolUse", 30) == 30
    assert normalized_timeout("SessionEnd", None) == 1
    assert normalized_timeout("SessionEnd", 10) == 3
    assert normalized_timeout("Interrupt", 2) == 2


def test_trusted_hashes_for_config_keys_by_group_and_handler():
    config = f"""
[[hooks.SessionStart]]
matcher = "*"
[[hooks.SessionStart.hooks]]
type = "command"
command = '''{COMMAND}'''

[[hooks.Stop]]
matcher = "*"
[[hooks.Stop.hooks]]
type = "command"
command = "echo not ours"
[[hooks.Stop.hooks]]
type = "command"
command = '''{COMMAND}'''

[[hooks.SessionEnd]]
matcher = "*"
[[hooks.SessionEnd.hooks]]
type = "command"
command = '''{COMMAND}'''
timeout = 3
"""
    path = Path("/Users/jonathanreed/.codex/config.toml")
    hashes = trusted_hashes_for_config(config, path, is_ours=lambda c: "hook_entry.py" in c)
    assert hashes[hook_state_key(path, "SessionStart", 0, 0)] == KNOWN["SessionStart"]
    assert hashes[hook_state_key(path, "Stop", 0, 1)] == KNOWN["Stop"]
    assert hook_state_key(path, "Stop", 0, 0) not in hashes
    assert hashes[hook_state_key(path, "SessionEnd", 0, 0)] == hook_identity_hash(
        "SessionEnd", command=COMMAND, matcher="*", timeout=3
    )


def test_trusted_hashes_for_config_tolerates_bad_toml():
    assert trusted_hashes_for_config("[[hooks", Path("/x"), is_ours=lambda c: True) == {}
