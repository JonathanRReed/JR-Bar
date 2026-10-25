"""Reset delivery state and delivery for the provider usage controller."""

from __future__ import annotations


def reset_delivery_state(controller):
    """The controller's reset delivery state, read from disk the first time
    anything asks for it.

    ``refresh_`` delivers pending resets on every tick, long before the
    first usage reading lands. Loading here, in the one place both paths
    read from, means that early tick sees the saved deliveries and the
    jumps still waiting for confirmation, instead of starting from an
    empty state and saving it over them.
    """
    from .provider_reset_events import ResetDeliveryState

    state = getattr(controller, "_jrbar_reset_delivery_state", None)
    if type(state) is ResetDeliveryState:
        return state
    try:
        from .provider_usage_event_store import load_reset_delivery_state

        state = load_reset_delivery_state()
    except Exception:
        state = ResetDeliveryState()
    controller._jrbar_reset_delivery_state = state
    return state


def note_reset_candidates(controller, candidates) -> None:
    """Ask the usage service for a confirming read while jumps wait."""
    from .provider_usage_qol import reset_confirm_deadline

    service = getattr(controller, "_jrbar_provider_usage_service", None)
    note = getattr(service, "note_reset_candidates", None)
    if not callable(note):
        return
    try:
        note(reset_confirm_deadline(tuple(candidates)))
    except Exception:
        pass


__all__ = ["note_reset_candidates", "reset_delivery_state"]


def deliver_pending_reset_events(controller, *, legacy) -> None:
    import time

    from .provider_reset_events import (
        apply_reset_channel_receipt,
        pending_reset_channels,
    )
    from .provider_usage_feedback import deliver_reset_channels

    state = reset_delivery_state(controller)
    original = state
    epoch_now = time.time()
    monotonic_now = time.monotonic()
    for event in tuple(state.events):
        state, channels = pending_reset_channels(
            state,
            event.event_id,
            now=epoch_now,
            record_discards=True,
        )
        if not channels:
            continue
        receipts = deliver_reset_channels(
            controller,
            event,
            channels,
            now=epoch_now,
            monotonic_now=monotonic_now,
            log=legacy.log_status_bar,
        )
        for receipt in receipts:
            state = apply_reset_channel_receipt(
                state,
                event.event_id,
                receipt.channel,
                receipt.outcome,
                reason=receipt.reason,
                now=receipt.recorded_at,
            )
    controller._jrbar_reset_delivery_state = state
    if state != original:
        controller._persist_reset_delivery_state()
    controller._schedule_reset_delivery_retry(epoch_now)


__all__.append("deliver_pending_reset_events")


def reset_replay_documents(controller, *, now: float | None = None) -> list[dict]:
    """Persisted reset events a connecting app may still celebrate —
    the durable half of the greet's ``quota_reset`` replay
    (docs/CORE-PROTOCOL.md). The journal's short tail covers socket
    churn; this covers the app being away longer than that, up to
    ``RESET_APP_FRESHNESS_SECONDS``, and survives a daemon restart the
    journal cannot. Each document is the same shape a live publish puts
    on the wire, with the reset's stable ``event_id`` repeated as the
    frame ``id`` so the app can dedup by fact, not by stream position.
    """
    import time as _time

    from .provider_reset_events import reset_events_pending_app

    current = _time.time() if now is None else now
    return [
        {
            "kind": "quota_reset",
            "provider": event.provider_id,
            "instance": event.account_id,
            "lane": event.window_id,
            "event_id": event.event_id,
            "id": event.event_id,
            "at": event.opened_at,
            "notify": False,
        }
        for event in reset_events_pending_app(reset_delivery_state(controller), now=current)
    ]


__all__.append("reset_replay_documents")


def apply_app_reset_receipt(controller, event_id, outcome, reason, *, now=None) -> dict:
    """Record the app's ``reset_receipt`` verdict and persist it.

    Propagates ``KeyError`` (the store has no such event) and
    ``ValueError`` (a bad outcome or empty reason) for the command to
    translate; a persisted receipt is the whole point of the call, so a
    state that cannot be written is returned anyway — the next tick's
    deliveries persist it with theirs.
    """
    import time as _time

    from .provider_reset_events import apply_app_receipt

    current = _time.time() if now is None else now
    state = apply_app_receipt(
        reset_delivery_state(controller),
        event_id,
        outcome,
        reason,
        now=current,
    )
    controller._jrbar_reset_delivery_state = state
    persist = getattr(controller, "_persist_reset_delivery_state", None)
    persistence = persist() if callable(persist) else None
    return {"recorded": True, "persistence": persistence}


__all__.append("apply_app_reset_receipt")
