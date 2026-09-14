"""Coordinator policy: read-only questions, typed proposals (W25).

The conversational coordinator is an *assistant layer*, not an executor:
it may read the same bounded evidence the panel lists and *propose* an
action, but the proposal lands in the W19 command journal as an ordinary
command — the coordinator has no privileged path to an effect.

This module is the contract an LLM front-end must satisfy:

* ``bounded_evidence`` — the only facts a question may cite; a prompt
  asking for anything outside the roster projection gets nothing.
* ``parse_proposal`` — a model's JSON proposal becomes a typed
  ``ActionProposal`` only if the action is on the allowlist and its
  arguments survive the command's own schema; anything else is a refusal.
* ``requires_confirmation`` — which proposals a UI must confirm before
  the command id is even minted.

Prompt-injection is not a special case: an instruction smuggled inside
a transcript can only produce a proposal, and a proposal still dies at
``parse_proposal`` if it names an action outside the allowlist.
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

# The actions a proposal may name. ``open_session`` is read-safe;
# ``answer_ask`` is the one real effect, and the UI must confirm it —
# the coordinator never answers an ask on its own.
ALLOWED_ACTIONS: frozenset[str] = frozenset({"open_session", "answer_ask"})

# Which proposals need an explicit confirm before the command runs.
CONFIRM_REQUIRED: frozenset[str] = frozenset({"answer_ask"})

# The bounded facts a question may cite — the roster projection, nothing
# deeper. ``message``/``title`` fields are the transcript-era strings the
# panel itself already shows; they are evidence, never instructions.
EVIDENCE_FIELDS: frozenset[str] = frozenset(
    {"provider", "mode", "stale", "label", "cwd", "attention", "outcome"}
)

# How many sessions' evidence one question may cite — the bound keeps a
# "summarise everything" ask from becoming a transcript dump.
MAX_EVIDENCE_SESSIONS = 12
# A proposal argument beyond this is noise.
MAX_ARG_CHARS = 500


class ProposalRefused(ValueError):
    """The coordinator produced something the contract cannot carry."""


@dataclass(frozen=True, slots=True)
class ActionProposal:
    """A typed, previewable intent — the UI shows it, the user confirms
    it, the command journal runs it. Never executed here."""

    action: str
    session: str
    arguments: dict[str, Any]
    preview: str
    requires_confirmation: bool


def bounded_evidence(session: Mapping[str, Any]) -> dict[str, Any]:
    """The facts a question may cite about one session — the roster's
    own projection, redacted to the fields a glance answers with."""
    out: dict[str, Any] = {}
    axes = session.get("axes")
    if isinstance(axes, Mapping):
        for key in ("attention", "outcome"):
            if key in axes:
                out[key] = axes[key]
    for field in ("provider", "mode", "stale", "label", "cwd"):
        if field in session and field in EVIDENCE_FIELDS:
            out[field] = session[field]
    return out


def evidence_for_question(sessions: list[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """The roster-wide bound: at most ``MAX_EVIDENCE_SESSIONS`` rows,
    each already redacted."""
    return [bounded_evidence(s) for s in sessions[:MAX_EVIDENCE_SESSIONS]]


def requires_confirmation(action: str) -> bool:
    return action in CONFIRM_REQUIRED


def parse_proposal(payload: object) -> ActionProposal:
    """Turn a model's proposal into a typed intent — or refuse.

    The only accepted shape is ``{"action": str, "session": str,
    "arguments"?: object, "preview"?: str}``. An action outside the
    allowlist, a missing session, or a malformed argument dict is a
    refusal the caller surfaces — the coordinator cannot produce a
    command the runtime would reject anyway.
    """
    if not isinstance(payload, Mapping):
        raise ProposalRefused("a proposal must be an object")
    action = payload.get("action")
    if action not in ALLOWED_ACTIONS:
        raise ProposalRefused(f"action must be one of {sorted(ALLOWED_ACTIONS)}")
    session = payload.get("session")
    if not isinstance(session, str) or not session.strip():
        raise ProposalRefused("a proposal needs a session")
    arguments = payload.get("arguments")
    if arguments is None:
        arguments = {}
    if not isinstance(arguments, Mapping):
        raise ProposalRefused("arguments must be an object")
    cleaned: dict[str, Any] = {}
    for key, value in arguments.items():
        if not isinstance(key, str):
            raise ProposalRefused("argument names must be strings")
        if isinstance(value, str):
            cleaned[key] = value[:MAX_ARG_CHARS]
        elif isinstance(value, (int, float, bool)):
            cleaned[key] = value
        else:
            raise ProposalRefused(f"argument {key!r} must be a scalar")
    preview = payload.get("preview")
    preview_text = preview.strip()[:200] if isinstance(preview, str) else ""
    return ActionProposal(
        action=str(action),
        session=session.strip(),
        arguments=cleaned,
        preview=preview_text or f"{action} {session.strip()}",
        requires_confirmation=requires_confirmation(str(action)),
    )


def parse_proposal_json(text: object) -> ActionProposal:
    """The wire form: a model answers with JSON text; parse it here so
    a prose reply or a markdown-fenced block is a refusal, not a crash."""
    if not isinstance(text, str):
        raise ProposalRefused("a proposal must be JSON text")
    stripped = text.strip()
    if not stripped.startswith("{"):
        raise ProposalRefused("a proposal is a JSON object, not prose")
    try:
        payload = json.loads(stripped)
    except ValueError as error:
        raise ProposalRefused(f"invalid proposal JSON: {error}") from error
    return parse_proposal(payload)
