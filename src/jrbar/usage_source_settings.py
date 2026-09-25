"""Tolerant decoding for the usage-hook and usage-source settings.

Each function here takes whatever a settings file holds (a hand edit, an
older version's shape, a wrong type) and returns the value the daemon
keeps: missing or mistyped fields fall back to their defaults, numbers are
clamped, and nothing raises. The settings loader calls these, so one bad
field never costs the rest of the file.

Validation that decides whether something may RUN (an absolute path, the
hook limits) is not done here: a rule the runner refuses stays in the
file, visible in Settings and ``jrbar usage-hooks list`` with the reason,
instead of vanishing.
"""

from __future__ import annotations

import math
import os
import re
from typing import Any

from .provider_homes import normalized_extra_homes

# --- Usage hooks ---------------------------------------------------------

#: The seven usage-hook events (CodexBar's set, which we reimplement).
USAGE_HOOK_EVENTS = (
    "quota_low",
    "quota_reached",
    "quota_reset",
    "usage_updated",
    "provider_unavailable",
    "provider_recovered",
    "refresh_failed",
)
#: A rule for every event.
USAGE_HOOK_ANY_EVENT = "*"
#: ``json``: argv is ``executable arguments...`` and the event arrives as
#: JSON on stdin. ``legacy``: the first version's positional argv,
#: ``executable EVENT PROVIDER LANE DETAIL``, kept for a migrated path.
USAGE_HOOK_ARGV_STYLES = ("json", "legacy")
DEFAULT_USAGE_HOOK_TIMEOUT_SECONDS = 15.0
MIN_USAGE_HOOK_TIMEOUT_SECONDS = 0.1
MAX_USAGE_HOOK_TIMEOUT_SECONDS = 300.0
#: How much of a hand-written file is kept at all. The runner's own
#: limits (32 rules, 32 arguments, 4 KiB strings) are stricter and refuse
#: to run past them; these only bound what is stored.
_STORED_RULES = 64
_STORED_ARGUMENTS = 64
_STORED_STRING = 8192
_RULE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")


def _text(value: object, default: str = "") -> str:
    if not isinstance(value, str) or len(value) > _STORED_STRING or "\x00" in value:
        return default
    return value


def _finite(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def normalize_usage_hook_rule(raw: object, index: int) -> dict[str, Any] | None:
    """One stored rule, or None when it is not a rule at all."""
    if not isinstance(raw, dict):
        return None
    rule_id = raw.get("id")
    if not isinstance(rule_id, str) or _RULE_ID.fullmatch(rule_id) is None:
        rule_id = f"rule-{index + 1}"
    event = _text(raw.get("event"), USAGE_HOOK_ANY_EVENT).strip() or USAGE_HOOK_ANY_EVENT
    provider = raw.get("provider")
    provider = provider.strip() if isinstance(provider, str) and provider.strip() else None
    if provider is not None and len(provider) > 64:
        provider = None
    threshold = _finite(raw.get("threshold_remaining"))
    if threshold is not None:
        threshold = max(0.0, min(100.0, threshold))
    timeout = _finite(raw.get("timeout_seconds"))
    timeout = (
        DEFAULT_USAGE_HOOK_TIMEOUT_SECONDS
        if timeout is None
        else max(MIN_USAGE_HOOK_TIMEOUT_SECONDS, min(MAX_USAGE_HOOK_TIMEOUT_SECONDS, timeout))
    )
    arguments = raw.get("arguments")
    arguments = [
        item for item in (arguments if isinstance(arguments, list) else [])[:_STORED_ARGUMENTS]
        if isinstance(item, str) and len(item) <= _STORED_STRING and "\x00" not in item
    ]
    argv = raw.get("argv")
    return {
        "id": rule_id,
        "enabled": raw.get("enabled") if type(raw.get("enabled")) is bool else True,
        "event": event,
        "provider": provider,
        "threshold_remaining": threshold,
        "executable": _text(raw.get("executable")).strip(),
        "arguments": arguments,
        "timeout_seconds": timeout,
        "argv": argv if argv in USAGE_HOOK_ARGV_STYLES else "json",
    }


def normalize_usage_hooks(raw: object, *, legacy_path: str = "") -> dict[str, Any]:
    """``usage_hooks`` as saved: ``{"enabled": bool, "rules": [...]}``.

    A settings file from before hooks v2 has no ``usage_hooks`` but may
    have ``usage_event_hook_path``. That path becomes one rule, id
    ``legacy``, for every event, with the old positional argv, so an
    existing script keeps receiving exactly what it did.
    """
    if not isinstance(raw, dict):
        if legacy_path.strip():
            return {"enabled": True, "rules": [legacy_usage_hook_rule(legacy_path)]}
        return {"enabled": False, "rules": []}
    rules_raw = raw.get("rules")
    rules: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, item in enumerate((rules_raw if isinstance(rules_raw, list) else [])[:_STORED_RULES]):
        rule = normalize_usage_hook_rule(item, index)
        if rule is None:
            continue
        rule["id"] = _unique_rule_id(rule["id"], seen)
        seen.add(rule["id"])
        rules.append(rule)
    enabled = raw.get("enabled")
    return {"enabled": enabled if type(enabled) is bool else False, "rules": rules}


def _unique_rule_id(rule_id: str, seen: set[str]) -> str:
    """``rule_id`` itself, or, when an earlier rule already has it, its
    first 56 characters plus the first free ``-2``, ``-3`` and so on. The
    count only climbs, so two rules that both end in ``-2`` still settle."""
    if rule_id not in seen:
        return rule_id
    base = rule_id[:56]
    number = 2
    while f"{base}-{number}" in seen:
        number += 1
    return f"{base}-{number}"


#: The id the first version's ``usage_event_hook_path`` rule goes by.
LEGACY_RULE_ID = "legacy"


def sync_legacy_usage_hook(hooks: dict[str, Any], path: str | None) -> dict[str, Any]:
    """Keep the ``legacy`` rule in step with ``usage_event_hook_path``.

    The first version's key still works after the migration. A new path
    there (from ``set_setting`` or a hand edit) changes the program the
    ``legacy`` rule runs and turns the rule and hooks on, the way the
    legacy window's path field always did; an empty path removes the rule;
    a path with no ``legacy`` rule left adds it back. ``None`` means the
    file has no such key, and the rules stay as they are.
    """
    if path is None:
        return hooks
    cleaned = path.strip()
    rules = list(hooks["rules"])
    index = next((i for i, rule in enumerate(rules) if rule["id"] == LEGACY_RULE_ID), None)
    if not cleaned:
        if index is None:
            return hooks
        del rules[index]
        return {"enabled": bool(hooks["enabled"]) and bool(rules), "rules": rules}
    wanted = os.path.expanduser(cleaned)
    if index is not None and rules[index]["executable"] == wanted:
        return hooks
    if index is None:
        rules.insert(0, legacy_usage_hook_rule(cleaned))
    else:
        rules[index] = {**rules[index], "executable": wanted, "enabled": True}
    return {"enabled": True, "rules": rules}


def legacy_usage_hook_rule(path: str) -> dict[str, Any]:
    """The rule a v1 ``usage_event_hook_path`` migrates to. The first
    version expanded a leading ``~``, so the rule does too; kept as typed,
    ``~/bin/chime.sh`` would count as a relative path and never run."""
    return {
        "id": LEGACY_RULE_ID,
        "enabled": True,
        "event": USAGE_HOOK_ANY_EVENT,
        "provider": None,
        "threshold_remaining": None,
        "executable": os.path.expanduser(path.strip()),
        "arguments": [],
        "timeout_seconds": DEFAULT_USAGE_HOOK_TIMEOUT_SECONDS,
        "argv": "legacy",
    }


# --- CLIProxyAPI hub ------------------------------------------------------

DEFAULT_CLIPROXY_HUB_URL = "http://127.0.0.1:8317"
DEFAULT_CLIPROXY_MIN_INTERVAL_SECONDS = 300
MIN_CLIPROXY_INTERVAL_SECONDS = 300
MAX_CLIPROXY_INTERVAL_SECONDS = 3600


def normalize_cliproxy_hub(raw: object) -> dict[str, Any]:
    """``cliproxy_hub``: ``{"enabled", "url", "min_interval_seconds"}``.

    Off by default. The URL is kept as typed (the hub refuses anything but
    loopback when it runs, and says so); the interval never drops below
    five minutes, so the proxy is not asked to spend its accounts' usage
    endpoints faster than JR-Bar's own collectors would.
    """
    source = raw if isinstance(raw, dict) else {}
    enabled = source.get("enabled")
    url = _text(source.get("url"), DEFAULT_CLIPROXY_HUB_URL).strip() or DEFAULT_CLIPROXY_HUB_URL
    interval = _finite(source.get("min_interval_seconds"))
    interval_value = (
        DEFAULT_CLIPROXY_MIN_INTERVAL_SECONDS
        if interval is None
        else int(max(MIN_CLIPROXY_INTERVAL_SECONDS, min(MAX_CLIPROXY_INTERVAL_SECONDS, interval)))
    )
    return {
        "enabled": enabled if type(enabled) is bool else False,
        "url": url[:512],
        "min_interval_seconds": interval_value,
    }


# --- Account homes --------------------------------------------------------


def normalize_provider_extra_homes(raw: object) -> dict[str, list[str]]:
    """``provider_extra_homes``: absolute folders per provider (claude, codex)."""
    return {provider: list(paths) for provider, paths in normalized_extra_homes(raw).items()}


# --- Pricing overrides ----------------------------------------------------

PRICING_OVERRIDE_FIELDS = ("input", "output", "cache_read", "cache_write")
_MAX_PRICING_OVERRIDES = 64
_MODEL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}\Z")
#: USD per million tokens. Nothing real costs more than this; a typo that
#: does is dropped rather than priced.
_MAX_PRICE_PER_MTOK = 10_000.0


def normalize_pricing_overrides(raw: object) -> dict[str, dict[str, float]]:
    """``pricing_overrides``: model id -> ``{input, output, cache_read,
    cache_write}`` in USD per million tokens. A model needs at least an
    input and an output price; a bad field drops only that field."""
    if not isinstance(raw, dict):
        return {}
    result: dict[str, dict[str, float]] = {}
    for model, prices in list(raw.items())[:_MAX_PRICING_OVERRIDES]:
        if not isinstance(model, str) or _MODEL_ID.fullmatch(model.strip()) is None:
            continue
        if not isinstance(prices, dict):
            continue
        kept: dict[str, float] = {}
        for field in PRICING_OVERRIDE_FIELDS:
            value = _finite(prices.get(field))
            if value is not None and 0.0 <= value <= _MAX_PRICE_PER_MTOK:
                kept[field] = value
        if "input" in kept and "output" in kept:
            result[model.strip().lower()] = kept
    return dict(sorted(result.items()))


__all__ = [
    "DEFAULT_CLIPROXY_HUB_URL",
    "DEFAULT_USAGE_HOOK_TIMEOUT_SECONDS",
    "MAX_USAGE_HOOK_TIMEOUT_SECONDS",
    "PRICING_OVERRIDE_FIELDS",
    "USAGE_HOOK_ANY_EVENT",
    "USAGE_HOOK_ARGV_STYLES",
    "USAGE_HOOK_EVENTS",
    "legacy_usage_hook_rule",
    "normalize_cliproxy_hub",
    "normalize_pricing_overrides",
    "normalize_provider_extra_homes",
    "normalize_usage_hook_rule",
    "normalize_usage_hooks",
]
