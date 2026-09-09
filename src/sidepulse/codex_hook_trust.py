"""Compute Codex's hook trust hashes locally.

Codex (0.150+) refuses to run a hook from ``config.toml`` unless
``[hooks.state."<config>:<event>:<group>:<handler>"].trusted_hash`` matches
a hash of the hook's normalized identity. The app-server ``hooks/list`` RPC
reports that hash, but spawning an app-server costs seconds and fails
when Codex is busy. The algorithm is small, so this module reproduces it:

    identity = {"event_name": <snake event>, "matcher"?: ..., "hooks": [handler]}
    handler  = {"type": "command", "command", "timeout", "async", ...}
    hash     = "sha256:" + sha256(canonical_json(identity))

verified byte-for-byte against hashes Codex itself wrote. Events that take
no matcher (UserPromptSubmit, Stop, Interrupt) drop it from the identity.
"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10
    tomllib = None  # type: ignore[assignment]

EVENT_KEYS: Mapping[str, str] = {
    "PreToolUse": "pre_tool_use",
    "PermissionRequest": "permission_request",
    "PostToolUse": "post_tool_use",
    "PreCompact": "pre_compact",
    "PostCompact": "post_compact",
    "SessionStart": "session_start",
    "SessionEnd": "session_end",
    "UserPromptSubmit": "user_prompt_submit",
    "SubagentStart": "subagent_start",
    "SubagentStop": "subagent_stop",
    "Stop": "stop",
    "Interrupt": "interrupt",
}
MATCHERLESS_EVENTS = frozenset({"UserPromptSubmit", "Stop", "Interrupt"})
# SessionEnd and Interrupt default to one second and clamp at three; every
# other hook defaults to ten minutes.
SHORT_TIMEOUT_EVENTS = frozenset({"SessionEnd", "Interrupt"})
SHORT_TIMEOUT_DEFAULT = 1
SHORT_TIMEOUT_MAX = 3
DEFAULT_TIMEOUT = 600


def normalized_timeout(event_name: str, timeout: int | None) -> int:
    if event_name in SHORT_TIMEOUT_EVENTS:
        value = SHORT_TIMEOUT_DEFAULT if timeout is None else int(timeout)
        return max(1, min(value, SHORT_TIMEOUT_MAX))
    return max(1, DEFAULT_TIMEOUT if timeout is None else int(timeout))


def hook_identity_hash(
    event_name: str,
    *,
    command: str,
    matcher: str | None,
    timeout: int | None = None,
    run_async: bool = False,
    status_message: str | None = None,
    additional_context_limit: int | None = None,
) -> str:
    handler: dict[str, Any] = {
        "type": "command",
        "command": command,
        "timeout": normalized_timeout(event_name, timeout),
        "async": bool(run_async),
    }
    if status_message is not None:
        handler["statusMessage"] = status_message
    if additional_context_limit is not None and additional_context_limit != 2500:
        handler["additionalContextLimit"] = int(additional_context_limit)
    identity: dict[str, Any] = {"event_name": EVENT_KEYS[event_name], "hooks": [handler]}
    if matcher is not None and event_name not in MATCHERLESS_EVENTS:
        identity["matcher"] = matcher
    serialized = json.dumps(
        identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(serialized).hexdigest()


def hook_state_key(config_path: Path, event_name: str, group_index: int, handler_index: int) -> str:
    return f"{config_path}:{EVENT_KEYS[event_name]}:{group_index}:{handler_index}"


def trusted_hashes_for_config(
    config_text: str,
    config_path: Path,
    *,
    is_ours: Callable[[str], bool],
) -> dict[str, str]:
    """Map ``hooks.state`` keys to the hash Codex expects, for our hooks only."""
    if tomllib is None:
        return {}
    try:
        document = tomllib.loads(config_text)
    except (ValueError, TypeError):
        return {}
    hooks = document.get("hooks")
    if not isinstance(hooks, dict):
        return {}
    result: dict[str, str] = {}
    for event_name, key in EVENT_KEYS.items():
        groups = hooks.get(event_name)
        if not isinstance(groups, list):
            continue
        for group_index, group in enumerate(groups):
            if not isinstance(group, dict):
                continue
            handlers = group.get("hooks")
            if not isinstance(handlers, list):
                continue
            matcher = group.get("matcher")
            for handler_index, handler in enumerate(handlers):
                if not isinstance(handler, dict) or handler.get("type", "command") != "command":
                    continue
                command = handler.get("command")
                if not isinstance(command, str) or not is_ours(command):
                    continue
                timeout = handler.get("timeout")
                acl = handler.get("additionalContextLimit", handler.get("additional_context_limit"))
                result[f"{config_path}:{key}:{group_index}:{handler_index}"] = hook_identity_hash(
                    event_name,
                    command=command,
                    matcher=str(matcher) if isinstance(matcher, str) else None,
                    timeout=int(timeout) if isinstance(timeout, int) else None,
                    run_async=bool(handler.get("async", False)),
                    status_message=(
                        handler.get("statusMessage")
                        if isinstance(handler.get("statusMessage"), str)
                        else None
                    ),
                    additional_context_limit=int(acl) if isinstance(acl, int) else None,
                )
    return result


__all__ = [
    "EVENT_KEYS",
    "MATCHERLESS_EVENTS",
    "hook_identity_hash",
    "hook_state_key",
    "normalized_timeout",
    "trusted_hashes_for_config",
]
