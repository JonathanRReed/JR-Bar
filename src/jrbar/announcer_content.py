"""Text bounds the Screen Bar announcer shares, and the one-line normaliser."""

from __future__ import annotations

ANNOUNCER_NAME_CAP = 40
ANNOUNCER_QUESTION_CAP = 80
ANNOUNCER_TEXT_CAP = 140


def _single_line(value: object) -> str:
    return " ".join(str(value or "").split())


__all__ = [
    "ANNOUNCER_NAME_CAP",
    "ANNOUNCER_QUESTION_CAP",
    "ANNOUNCER_TEXT_CAP",
]
