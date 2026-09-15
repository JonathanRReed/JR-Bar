"""Bounded utility generation: the policy half of W24.

Utility work — generated session titles, a "summarise this run" helper —
is allowed to be *useful* but never authoritative: the provider's own
title always outranks a generated one, the user-named title outranks
both, and a generation that fails, times out or produces nothing leaves
the deterministic label in place. Nothing downstream may depend on a
generated string to function.

This module is the decision layer an adapter drives: it answers
*should we generate?*, *what evidence may we send?* and *does the result
earn the slot?* — the model call itself lives behind the W19/W20
execution contract and is not this module's business.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

# A title longer than this is a paragraph, not a label.
MAX_TITLE_CHARS = 80
# Evidence sent to the model is bounded: the first user message, the
# last assistant message, and the current label — each truncated so a
# pasted log can never flood a request.
MAX_EVIDENCE_CHARS = 500
# How many sessions' worth of generated titles the cache keeps before
# the oldest drop.
MAX_CACHE_ENTRIES = 200


@dataclass(frozen=True, slots=True)
class GenerationRequest:
    """The bounded ask an adapter turns into a model call."""

    session_id: str
    provider: str
    evidence: dict[str, str]
    reason: str  # "missing_label" | "explicit_regeneration"


def _clean(value: object, limit: int) -> str:
    if not isinstance(value, str):
        return ""
    text = " ".join(value.split())
    return text[:limit]


def collect_evidence(
    session_id: str,
    provider: str,
    *,
    first_user_message: object = None,
    last_assistant_message: object = None,
    current_label: object = None,
) -> dict[str, str]:
    """The three facts a title needs and nothing else — a message body
    is evidence for the *title*, never a command, and the bound keeps a
    pasted log out of the request."""
    evidence: dict[str, str] = {}
    user = _clean(first_user_message, MAX_EVIDENCE_CHARS)
    assistant = _clean(last_assistant_message, MAX_EVIDENCE_CHARS)
    label = _clean(current_label, MAX_TITLE_CHARS)
    if user:
        evidence["first_user_message"] = user
    if assistant:
        evidence["last_assistant_message"] = assistant
    if label:
        evidence["current_label"] = label
    return evidence


def should_generate(
    session_id: str,
    provider: str,
    *,
    has_user_title: bool,
    has_source_title: bool,
    generated_before: bool,
    explicit: bool,
    evidence: Mapping[str, str],
) -> GenerationRequest | None:
    """The precedence gate: user title > provider title > generated.

    A session that already has either real title never gets a generated
    one (W24's "source/user title precedence"); a session that already
    generated one only regenerates on an explicit ask. With no evidence
    at all there is nothing to name it from — the deterministic label
    stands.
    """
    if has_user_title or has_source_title:
        return None
    if generated_before and not explicit:
        return None
    if not evidence:
        return None
    return GenerationRequest(
        session_id=session_id,
        provider=provider,
        evidence=dict(evidence),
        reason="explicit_regeneration" if explicit else "missing_label",
    )


def accept_title(generated: object, *, had_label: bool) -> str | None:
    """The result gate: a generated title earns the slot only if it is
    non-empty printable text within the bound. A model's refusal, empty
    string or control noise returns None — the deterministic label wins.
    """
    text = _clean(generated, MAX_TITLE_CHARS)
    if not text or not text.isprintable():
        return None
    return text


class TitleCache:
    """Once-per-session memory. A hit means no second generation; the
    bound keeps the map from growing across a long uptime."""

    def __init__(self, max_entries: int = MAX_CACHE_ENTRIES) -> None:
        self._max = max_entries
        self._titles: dict[str, str] = {}

    def get(self, session_id: str) -> str | None:
        return self._titles.get(session_id)

    def put(self, session_id: str, title: str) -> None:
        if len(self._titles) >= self._max and session_id not in self._titles:
            # dict preserves insertion order — the oldest title drops.
            oldest = next(iter(self._titles))
            del self._titles[oldest]
        self._titles[session_id] = title

    def clear(self, session_id: str) -> None:
        self._titles.pop(session_id, None)

    def __len__(self) -> int:
        return len(self._titles)
