"""The typed payloads the app's Agent Browser sends the daemon.

The Swift app owns the Agent Browser window. When a person acts on a row it
sends the daemon one of these two frozen payloads, and the daemon refuses
anything that does not validate: a stale generation, an action kind the
payload cannot carry, a reply that is not one printable line.  This module
holds no windows and imports no AppKit.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final

from .announcer_content import _single_line
from .answer_in_place import MAX_ANSWER_REPLY_LENGTH, AnswerActionKind
from .navigation_policy import OperatorActionKind
from .provider_facts import WorkKey

# The snooze presets a payload may name. core_runtime maps a snooze length in
# seconds onto one of them and status_bar_legacy turns it into a wake time.
_SNOOZE_PRESET_KEYS: Final = frozenset({"15-minutes", "1-hour", "tomorrow"})


@dataclass(frozen=True, slots=True)
class AgentBrowserActionPayload:
    work_key: WorkKey
    generation: int
    kind: OperatorActionKind
    snooze_preset: str | None = None

    def __post_init__(self) -> None:
        if not (
            type(self.work_key) is WorkKey
            and type(self.generation) is int
            and self.generation >= 0
            and type(self.kind) is OperatorActionKind
            and (
                self.snooze_preset is None
                or (self.kind is OperatorActionKind.SNOOZE and self.snooze_preset in _SNOOZE_PRESET_KEYS)
            )
        ):
            raise ValueError("invalid agent browser action payload")


@dataclass(frozen=True, slots=True)
class AgentBrowserAnswerPayload:
    work_key: WorkKey
    generation: int
    request_identity: str
    action: AnswerActionKind
    reply_text: str | None = None

    def __post_init__(self) -> None:
        reply_valid = (
            self.reply_text is None
            or (
                type(self.reply_text) is str
                and 1 <= len(self.reply_text) <= MAX_ANSWER_REPLY_LENGTH
                and self.reply_text == _single_line(self.reply_text)
                and self.reply_text.isprintable()
            )
        )
        if not (
            type(self.work_key) is WorkKey
            and type(self.generation) is int
            and self.generation >= 0
            and type(self.request_identity) is str
            and 1 <= len(self.request_identity) <= 4096
            and self.request_identity.isprintable()
            and type(self.action) is AnswerActionKind
            and reply_valid
            and (
                (self.action is AnswerActionKind.REPLY and self.reply_text is not None)
                or (self.action is not AnswerActionKind.REPLY and self.reply_text is None)
            )
        ):
            raise ValueError("invalid agent browser answer payload")
