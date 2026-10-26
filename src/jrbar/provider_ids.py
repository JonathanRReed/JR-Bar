"""Explicit harness identities, shared with the app's generated fallback table."""
from __future__ import annotations

import re

PROVIDER_ALIASES = {
    "claude": ("claude", "claude-code", "claudeAgent", "anthropic", "claude-cli"),
    "codex": ("codex", "openai", "openai-codex", "codex-cli", "codex-app-server"),
    "factory": ("factory", "droid", "factory-droid", "factoryDroid", "factory-cli"),
    "devin": ("devin", "devin-cli", "devinAgent"),
    "cursor": ("cursor", "cursor-agent", "cursor-cli"),
    "gemini": ("gemini", "gemini-cli", "google-gemini", "geminiAgent"),
    "grok": ("grok", "xai", "grok-cli", "grokAgent"),
    "opencode": ("opencode", "open-code", "opencode-cli"),
    "hermes": ("hermes", "hermes-agent", "hermes-cli"),
    "kiro": ("kiro", "kiro-cli", "kiroAgent"),
    "antigravity": ("antigravity", "google-antigravity", "antigravityAgent"),
    "openclaw": ("openclaw", "open-claw", "openclaw-cli"),
    "pi": ("pi", "pi-agent", "pi-coding-agent"),
    "kimi": ("kimi", "kimi-code", "kimi-cli"),
    "kilo": ("kilo", "kilo-code", "kilocode", "kilo-cli"),
    "openai-api": ("openai-api",),
    "t3code": ("t3code", "t3-code"),
    "jrbar": ("jrbar", "jr-bar"),
}


def _alias_key(value: str) -> str:
    return re.sub(r"[\s_-]+", "", value.strip().lower())


ALIAS_IDS = {_alias_key(alias): provider for provider, aliases in PROVIDER_ALIASES.items() for alias in aliases}


def canonical_provider_id(value: str) -> str:
    """Match explicit names only. Custom instance labels and models confer no identity."""
    return ALIAS_IDS.get(_alias_key(value), value.strip().lower())


def canonical_work_id(value: str) -> str:
    provider, separator, rest = value.partition(":")
    return canonical_provider_id(provider) + separator + rest
