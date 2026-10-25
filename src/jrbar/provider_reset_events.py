"""Pure, durable delivery planning for provider-evidenced reset events."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, replace
from enum import Enum
from typing import Any

from .provider_usage_qol import ResetCandidate, ResetEvent

RESET_DELIVERY_WINDOW_SECONDS = 300.0
#: How long a confirmed reset stays newsworthy to the app. The journal's
#: delivery window covers socket churn; a client that was away longer is
#: re-offered the ``quota_reset`` it missed on greet, up to this bound —
#: the app either celebrates it once or records why it could not. Older
#: resets are genuinely old facts: a restart never re-fires them.
RESET_APP_FRESHNESS_SECONDS = 24 * 60 * 60
#: What the app may report through ``reset_receipt``. ``delivered`` and
#: ``dropped`` close the loop — the reset is never replayed to the app
#: again. Every other word leaves it replayable, so a burst held for a
#: hushed room that lapsed, or a toy the person switched off and back on,
#: still gets its one moment on a later connection.
APP_RECEIPT_OUTCOMES = frozenset(
    {"delivered", "held", "dropped", "expired", "suppressed"}
)
APP_RECEIPT_TERMINAL = frozenset({"delivered", "dropped"})
#: App receipts are advisory bookkeeping; the cap only guards the file
#: against a client that reports without end.
MAX_APP_RECEIPTS = 16
RESET_DELIVERY_PRIORITY = {
    "idle": 10,
    "quota_warning": 20,
    "completion": 30,
    "reset": 40,
    "quota_exhaustion": 50,
    "failure": 60,
    "input": 70,
}


class ResetChannel(str, Enum):
    OVERLAY = "overlay"
    HARDWARE = "hardware"
    NOTIFICATION = "notification"
    SOUND = "sound"


class ResetChannelOutcome(str, Enum):
    DELIVERED = "delivered"
    SUPPRESSED = "suppressed"
    FAILED = "failed"
    DISCARDED = "discarded"


@dataclass(frozen=True, slots=True)
class ResetDeliverySettings:
    overlay: bool = True
    hardware: bool = True
    notification: bool = True
    sound: bool = True

    def enabled(self, channel: ResetChannel) -> bool:
        return bool(getattr(self, channel.value))


@dataclass(frozen=True, slots=True)
class ResetChannelReceipt:
    channel: ResetChannel
    outcome: ResetChannelOutcome
    reason: str
    recorded_at: float


@dataclass(frozen=True, slots=True)
class AppDeliveryReceipt:
    """The app's account of what happened to a ``quota_reset`` it was
    sent: the Confetti toy's verdict, reported back through
    ``reset_receipt``. The daemon's own channel receipts only prove it
    scheduled its own effect; these are the record of whether the
    celebration a person can see ever happened (or why not)."""

    outcome: str
    reason: str
    recorded_at: float


@dataclass(frozen=True, slots=True)
class ResetDeliveryEvent:
    event_id: str
    provider_id: str
    account_id: str
    window_id: str
    reset_boundary: float
    opened_at: float
    settings: ResetDeliverySettings
    receipts: tuple[ResetChannelReceipt, ...] = ()
    app_receipts: tuple[AppDeliveryReceipt, ...] = ()
    account_discriminator: str | None = None

    @property
    def identity(self) -> tuple[str, str, str, float, str | None]:
        return (
            self.provider_id,
            self.account_id,
            self.window_id,
            self.reset_boundary,
            self.account_discriminator,
        )


#: Jumps waiting for a confirming read are few by nature; the cap only
#: guards the file against a runaway.
MAX_RESET_CANDIDATES = 64
#: Finished deliveries kept for the history and for dedup. Open ones (still
#: inside the delivery window, or still owed to the app) are never counted
#: against this, so a retention pass can never lose a reset that is owed.
MAX_SETTLED_RESET_EVENTS = 48


@dataclass(frozen=True, slots=True)
class ResetDeliveryState:
    events: tuple[ResetDeliveryEvent, ...] = ()
    #: Jumps waiting for a confirming read (``confirm_reset_events``). Kept
    #: here so they survive a restart with the deliveries they lead to.
    candidates: tuple[ResetCandidate, ...] = ()


def with_reset_candidates(
    state: ResetDeliveryState,
    candidates: tuple[ResetCandidate, ...],
) -> ResetDeliveryState:
    """``state`` holding exactly ``candidates`` (newest kept past the cap)."""
    if type(state) is not ResetDeliveryState:
        raise TypeError("typed reset delivery state required")
    if not all(type(candidate) is ResetCandidate for candidate in candidates):
        raise TypeError("typed reset candidates required")
    return replace(state, candidates=tuple(candidates)[-MAX_RESET_CANDIDATES:])


def _event_is_open(event: ResetDeliveryEvent, now: float) -> bool:
    """True while a reset is still owed: channels inside the delivery
    window, or an app celebration that is fresh and not yet closed."""
    age = now - event.opened_at
    if age < 0:
        return True
    if age < RESET_DELIVERY_WINDOW_SECONDS and _pending(event):
        return True
    return age < RESET_APP_FRESHNESS_SECONDS and not _app_terminal(event)


def prune_reset_delivery_state(
    state: ResetDeliveryState,
    *,
    now: float,
    keep_settled: int = MAX_SETTLED_RESET_EVENTS,
) -> ResetDeliveryState:
    """``state`` without its oldest finished deliveries.

    Every open delivery and every waiting candidate is kept; only events
    that are done (delivered, dropped, expired or discarded) are trimmed,
    oldest first, down to ``keep_settled``. The file therefore stays small
    no matter how long the daemon runs.
    """
    current = _finite(now)
    settled = [
        index
        for index, event in enumerate(state.events)
        if not _event_is_open(event, current)
    ]
    excess = len(settled) - max(0, keep_settled)
    if excess <= 0:
        return state
    ranked = sorted(settled, key=lambda index: (state.events[index].opened_at, index))
    drop = set(ranked[:excess])
    kept = tuple(event for index, event in enumerate(state.events) if index not in drop)
    return replace(state, events=kept)


def _finite(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("time must be finite")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError("time must be finite")
    return result


def begin_reset_delivery(
    state: ResetDeliveryState,
    event: ResetEvent,
    settings: ResetDeliverySettings,
    *,
    now: float,
) -> ResetDeliveryState:
    if type(state) is not ResetDeliveryState or type(event) is not ResetEvent:
        raise TypeError("typed reset delivery state and event required")
    if type(settings) is not ResetDeliverySettings:
        raise TypeError("typed reset delivery settings required")
    opened_at = _finite(now)
    if event.reset_boundary is None:
        raise ValueError("provider reset boundary evidence is required")
    boundary = _finite(event.reset_boundary)
    identity = (
        event.provider_id,
        event.source_instance_id,
        event.lane_id,
        boundary,
        event.account_discriminator,
    )
    # Legacy records omit account scope, but their stable fact IDs still
    # prevent reopening an already recorded reset after an upgrade.
    if any(item.event_id == event.event_id or item.identity == identity for item in state.events):
        return state
    receipts = tuple(
        ResetChannelReceipt(channel, ResetChannelOutcome.SUPPRESSED, "disabled", opened_at)
        for channel in ResetChannel
        if not settings.enabled(channel)
    )
    delivery = ResetDeliveryEvent(
        event.event_id,
        event.provider_id,
        event.source_instance_id,
        event.lane_id,
        boundary,
        opened_at,
        settings,
        receipts,
        account_discriminator=event.account_discriminator,
    )
    grown = replace(state, events=(*state.events, delivery))
    return prune_reset_delivery_state(grown, now=opened_at)


def _latest(event: ResetDeliveryEvent, channel: ResetChannel) -> ResetChannelReceipt | None:
    return next(
        (receipt for receipt in reversed(event.receipts) if receipt.channel is channel),
        None,
    )


def _channel_terminal(event: ResetDeliveryEvent, channel: ResetChannel) -> bool:
    receipt = _latest(event, channel)
    if receipt is None:
        return False
    if receipt.outcome in {ResetChannelOutcome.DELIVERED, ResetChannelOutcome.DISCARDED}:
        return True
    return receipt.outcome is ResetChannelOutcome.SUPPRESSED and receipt.reason == "disabled"


def apply_reset_channel_receipt(
    state: ResetDeliveryState,
    event_id: str,
    channel: ResetChannel,
    outcome: ResetChannelOutcome,
    *,
    reason: str,
    now: float,
) -> ResetDeliveryState:
    recorded_at = _finite(now)
    if type(reason) is not str or not reason:
        raise ValueError("receipt reason is required")
    updated = []
    found = False
    for event in state.events:
        if event.event_id != event_id:
            updated.append(event)
            continue
        found = True
        if _channel_terminal(event, channel):
            updated.append(event)
            continue
        receipt = ResetChannelReceipt(channel, outcome, reason, recorded_at)
        updated.append(
            ResetDeliveryEvent(
                event.event_id,
                event.provider_id,
                event.account_id,
                event.window_id,
                event.reset_boundary,
                event.opened_at,
                event.settings,
                (*event.receipts, receipt),
                event.app_receipts,
                event.account_discriminator,
            )
        )
    if not found:
        raise KeyError(event_id)
    return replace(state, events=tuple(updated))


def apply_app_receipt(
    state: ResetDeliveryState,
    event_id: str,
    outcome: str,
    reason: str,
    *,
    now: float,
) -> ResetDeliveryState:
    """Record the app's verdict on a reset it was sent (``reset_receipt``).

    ``delivered`` and ``dropped`` close the event to further replays; the
    softer words (``held``, ``expired``, ``suppressed``) are kept so the
    history is honest while leaving the reset re-offerable. Raises
    ``KeyError`` for an event the store does not know and ``ValueError``
    for an outcome outside ``APP_RECEIPT_OUTCOMES`` — a receipt about
    nothing is worse than none.
    """
    recorded_at = _finite(now)
    if outcome not in APP_RECEIPT_OUTCOMES:
        raise ValueError(f"unknown app receipt outcome: {outcome!r}")
    if type(reason) is not str or not reason:
        raise ValueError("receipt reason is required")
    updated = []
    found = False
    for event in state.events:
        if event.event_id != event_id:
            updated.append(event)
            continue
        found = True
        delivered = any(receipt.outcome == "delivered" for receipt in event.app_receipts)
        if delivered or (_app_terminal(event) and outcome != "delivered"):
            updated.append(event)
            continue
        receipt = AppDeliveryReceipt(outcome, reason, recorded_at)
        updated.append(replace(event, app_receipts=(*event.app_receipts, receipt)[-MAX_APP_RECEIPTS:]))
    if not found:
        raise KeyError(event_id)
    return prune_reset_delivery_state(replace(state, events=tuple(updated)), now=recorded_at)


def _app_terminal(event: ResetDeliveryEvent) -> bool:
    return any(receipt.outcome in APP_RECEIPT_TERMINAL for receipt in event.app_receipts)


def reset_events_pending_app(
    state: ResetDeliveryState,
    *,
    now: float,
) -> tuple[ResetDeliveryEvent, ...]:
    """Confirmed resets a connecting app may still celebrate: fresh
    enough to be worth confetti (``RESET_APP_FRESHNESS_SECONDS``) and
    not yet closed by a ``delivered`` or ``dropped`` app receipt. In
    ``opened_at`` order, oldest first, so the oldest debt is paid first.
    """
    current = _finite(now)
    return tuple(
        event
        for event in state.events
        if 0 <= current - event.opened_at < RESET_APP_FRESHNESS_SECONDS
        and not _app_terminal(event)
    )


def _pending(event: ResetDeliveryEvent) -> tuple[ResetChannel, ...]:
    return tuple(channel for channel in ResetChannel if not _channel_terminal(event, channel))


def pending_reset_channels(
    state: ResetDeliveryState,
    event_id: str,
    *,
    now: float,
    record_discards: bool = False,
):
    current = _finite(now)
    event = next((item for item in state.events if item.event_id == event_id), None)
    if event is None:
        return (state, ()) if record_discards else ()
    pending = _pending(event)
    if current - event.opened_at < RESET_DELIVERY_WINDOW_SECONDS:
        return (state, pending) if record_discards else pending
    if not record_discards:
        return ()
    for channel in pending:
        state = apply_reset_channel_receipt(
            state,
            event_id,
            channel,
            ResetChannelOutcome.DISCARDED,
            reason="delivery_window_expired",
            now=current,
        )
    return state, ()


def reset_event_is_terminal(state: ResetDeliveryState, event_id: str) -> bool:
    event = next((item for item in state.events if item.event_id == event_id), None)
    return event is not None and not _pending(event)


def next_reset_retry_delay(
    state: ResetDeliveryState,
    *,
    now: float,
    interval_seconds: float = 15.0,
) -> float | None:
    current = _finite(now)
    interval = _finite(interval_seconds)
    if interval <= 0:
        raise ValueError("retry interval must be positive")
    remaining = tuple(
        event.opened_at + RESET_DELIVERY_WINDOW_SECONDS - current
        for event in state.events
        if _pending(event)
        and event.opened_at + RESET_DELIVERY_WINDOW_SECONDS > current
    )
    if not remaining:
        return None
    return min(interval, min(remaining))


def encode_reset_delivery_state(state: ResetDeliveryState) -> str:
    events = []
    for event in state.events:
        item: dict[str, Any] = {
            "event_id": event.event_id,
            "provider_id": event.provider_id,
            "account_id": event.account_id,
            "window_id": event.window_id,
            "reset_boundary": event.reset_boundary,
            "opened_at": event.opened_at,
            "settings": {
                channel.value: event.settings.enabled(channel)
                for channel in ResetChannel
            },
            "receipts": [
                {
                    "channel": receipt.channel.value,
                    "outcome": receipt.outcome.value,
                    "reason": receipt.reason,
                    "recorded_at": receipt.recorded_at,
                }
                for receipt in event.receipts
            ],
        }
        if event.account_discriminator is not None:
            item["account_discriminator"] = event.account_discriminator
        # Additive: a build from before app receipts ignores the key on
        # read and simply re-saves without it; nothing here is dedup
        # state, so losing a diagnostic on downgrade is safe.
        if event.app_receipts:
            item["app_receipts"] = [
                {
                    "outcome": receipt.outcome,
                    "reason": receipt.reason,
                    "recorded_at": receipt.recorded_at,
                }
                for receipt in event.app_receipts
            ]
        events.append(item)
    document = {
        "version": 1,
        "events": events,
    }
    if state.candidates:
        document["candidates"] = [candidate.to_dict() for candidate in state.candidates]
    return json.dumps(document, sort_keys=True, separators=(",", ":"))


def decode_reset_delivery_state(payload: str) -> ResetDeliveryState:
    document = json.loads(payload)
    if type(document) is not dict or document.get("version") != 1:
        raise ValueError("unsupported reset delivery document")
    events = []
    for item in document.get("events", ()):
        settings = ResetDeliverySettings(**item["settings"])
        receipts = tuple(
            ResetChannelReceipt(
                ResetChannel(receipt["channel"]),
                ResetChannelOutcome(receipt["outcome"]),
                receipt["reason"],
                _finite(receipt["recorded_at"]),
            )
            for receipt in item["receipts"]
        )
        app_receipts = tuple(
            AppDeliveryReceipt(
                str(receipt["outcome"]),
                str(receipt["reason"]),
                _finite(receipt["recorded_at"]),
            )
            for receipt in item.get("app_receipts", ())
            if isinstance(receipt, dict)
            and receipt.get("outcome") in APP_RECEIPT_OUTCOMES
            and isinstance(receipt.get("reason"), str)
            and isinstance(receipt.get("recorded_at"), (int, float))
        )[-MAX_APP_RECEIPTS:]
        events.append(
            ResetDeliveryEvent(
                item["event_id"],
                item["provider_id"],
                item["account_id"],
                item["window_id"],
                _finite(item["reset_boundary"]),
                _finite(item["opened_at"]),
                settings,
                receipts,
                app_receipts,
                account_discriminator=item.get("account_discriminator"),
            )
        )
    # Additive in version 1: a file without candidates simply has none
    # waiting, and an unreadable candidate is dropped, never fatal.
    raw_candidates = document.get("candidates", ())
    candidates = tuple(
        candidate
        for candidate in (
            ResetCandidate.from_dict(item)
            for item in (raw_candidates if isinstance(raw_candidates, list) else ())
        )
        if candidate is not None
    )[-MAX_RESET_CANDIDATES:]
    return ResetDeliveryState(tuple(events), candidates)


__all__ = [
    "APP_RECEIPT_OUTCOMES",
    "APP_RECEIPT_TERMINAL",
    "MAX_APP_RECEIPTS",
    "MAX_RESET_CANDIDATES",
    "MAX_SETTLED_RESET_EVENTS",
    "RESET_APP_FRESHNESS_SECONDS",
    "RESET_DELIVERY_PRIORITY",
    "RESET_DELIVERY_WINDOW_SECONDS",
    "AppDeliveryReceipt",
    "ResetChannel",
    "ResetChannelOutcome",
    "ResetChannelReceipt",
    "ResetDeliveryEvent",
    "ResetDeliverySettings",
    "ResetDeliveryState",
    "apply_app_receipt",
    "apply_reset_channel_receipt",
    "begin_reset_delivery",
    "decode_reset_delivery_state",
    "encode_reset_delivery_state",
    "next_reset_retry_delay",
    "pending_reset_channels",
    "prune_reset_delivery_state",
    "reset_event_is_terminal",
    "reset_events_pending_app",
    "with_reset_candidates",
]
