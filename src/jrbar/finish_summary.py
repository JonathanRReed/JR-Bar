"""The one line a finish banner says about what the agent just did.

The agent's last message is free text from a provider. Before any of it
reaches a banner it is cut to its first real line, stripped of markdown, run
through the same scrubber that cleans provider command output (so a token,
a key or any long unbroken run reads ``[removed]``) and capped. Pure: text
in, text out. The line is carried on the live ``completed`` event only; it is
never written to the activity ledger, the settings or a log.
"""

from __future__ import annotations

import re
from typing import Final

from .provider_cli import scrub

#: The longest line a banner is given, in characters.
SUMMARY_LIMIT: Final = 140

_FENCE = re.compile(r"^\s*(```|~~~)")
_RULE = re.compile(r"^\s*([-*_=]\s*){3,}$")
_TABLE_RULE = re.compile(r"^\s*\|?[\s:|-]+\|?\s*$")
_LEADING = re.compile(r"^\s*(?:#{1,6}\s+|>+\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d{1,3}[.)]\s+)+")
_IMAGE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
# Bold and strike-through pairs and backticks only: a lone ``_`` or ``*``,
# and a name like ``__init__``, belong to the sentence.
_EMPHASIS = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*|~~(?=\S)(.+?)(?<=\S)~~|`")
_REMOVED_RUN = re.compile(r"(?:\[removed\]\s*){2,}")


def finish_summary(message: object, *, limit: int = SUMMARY_LIMIT) -> str | None:
    """The first line of ``message`` as plain words, or ``None``.

    Skips blank lines, code fences (and what is inside them), rules and
    table scaffolding; drops heading, quote, bullet and number markers,
    emphasis and backticks; keeps a link's text and drops its address;
    scrubs token-shaped runs; collapses whitespace; and cuts to ``limit``
    characters on a word boundary with an ellipsis.
    """
    if not isinstance(message, str) or not message.strip():
        return None
    in_fence = False
    for raw_line in message.splitlines():
        if _FENCE.match(raw_line):
            in_fence = not in_fence
            continue
        if in_fence or not raw_line.strip():
            continue
        if _RULE.match(raw_line) or _TABLE_RULE.match(raw_line):
            continue
        text = _plain(raw_line)
        if text:
            return _cap(text, limit)
    return None


def summaries_for_finished(statuses) -> dict[str, str]:
    """``{agent id: summary}`` for the finished statuses that ended on a
    ``Stop`` carrying a message. Any other ending (a session end, an idle
    notice) has no last message of the agent's to quote."""
    out: dict[str, str] = {}
    for status in statuses:
        if getattr(status, "event_name", None) != "Stop":
            continue
        summary = finish_summary(getattr(status, "message", None))
        if summary is not None:
            out[status.agent_id] = summary
    return out


def _plain(line: str) -> str:
    text = _IMAGE.sub(r"\1", line)
    text = _LINK.sub(r"\1", text)
    text = _LEADING.sub("", text)
    text = scrub(text)
    text = _EMPHASIS.sub(lambda m: m.group(1) or m.group(2) or "", text)
    text = "".join(ch if ch.isprintable() else " " for ch in text)
    text = " ".join(text.split())
    text = _REMOVED_RUN.sub("[removed] ", text).strip()
    # A line that is nothing but scrubbed material says nothing.
    if not text or text.replace("[removed]", "").strip(" .,:;|-") == "":
        return ""
    return text


def _cap(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text[: max(1, limit - 1)]
    space = cut.rfind(" ")
    if space >= limit // 2:
        cut = cut[:space]
    return cut.rstrip(" .,;:-") + "…"
