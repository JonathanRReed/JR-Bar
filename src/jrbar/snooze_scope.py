"""One snooze rule for every surface beyond the dropdown.

Snoozing a session from the mailbox used to filter ONLY the dropdown:
the same session kept claiming the LEDs and kept delivering completion
banners. Decision (2026-08-26): a snoozed session is silent everywhere
-- lights and notification delivery included -- EXCEPT a genuine ask
(WAITING_FOR_INPUT with PermissionRequest/Notification, the raised
hand that already wakes the dropdown), which breaks through every
surface. The Agent Browser window deliberately keeps showing snoozed
sessions; the mailbox keeps its own richer wake semantics in
mailbox_preferences. This module owns only the lights/notifications
scope, so the rule lives once for both consumers.

A snooze has a scope (``MailboxSnoozeScope``). The mailbox's own snooze is
the family's: it sits on the root key and quiets every run in it. "Quiet
this run" is one row's: it sits on that run's exact key -- a main session
or one worker -- and quiets that run alone, so quieting a sub-agent never
silences the session that spawned it (nor the other way round).
"""

from __future__ import annotations

import math
from dataclasses import replace

from .mailbox_preferences import (
    LegacyMailboxPreference,
    MailboxPreference,
    MailboxPreferenceMode,
    MailboxSnoozeScope,
)
from .provider_facts import WorkKey


def _active_snooze(preference, now: float) -> bool:
    snoozed_at = preference.snoozed_at
    snoozed_until = preference.snoozed_until
    for value in (snoozed_at, snoozed_until):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return False
        if not math.isfinite(float(value)):
            return False
    return float(snoozed_at) < float(snoozed_until) and float(snoozed_until) > now


def _snoozed_scopes(
    preferences,
    now: float,
) -> tuple[frozenset[WorkKey], frozenset[tuple[str, str]], frozenset[str]]:
    """Currently snoozed (work keys, (provider, family id) pairs, agent
    ids). The family pair covers live-path statuses whose own work key is a
    child of (or older than) the snoozed family key: a status's session_id
    is its family's work id. A run's own snooze adds only its exact key and
    the agent ids that run's row can carry -- never the family pair."""
    try:
        values = tuple(preferences)
    except TypeError:
        return frozenset(), frozenset(), frozenset()
    work_keys: set[WorkKey] = set()
    family_ids: set[tuple[str, str]] = set()
    agent_ids: set[str] = set()
    for preference in values:
        if isinstance(preference, MailboxPreference):
            if type(preference.work_key) is WorkKey and _active_snooze(preference, now):
                work_keys.add(preference.work_key)
                if preference.snooze_scope is MailboxSnoozeScope.RUN:
                    agent_ids.update(run_agent_ids(preference.work_key))
                    continue
                family_ids.add(
                    (
                        preference.work_key.source_key.provider_id,
                        preference.work_key.work_id.value,
                    )
                )
        elif isinstance(preference, LegacyMailboxPreference):
            if isinstance(preference.agent_id, str) and _active_snooze(preference, now):
                agent_ids.add(preference.agent_id)
    return frozenset(work_keys), frozenset(family_ids), frozenset(agent_ids)


def _status_covered(status, work_keys, family_ids, agent_ids) -> bool:
    if getattr(status, "is_hard_ask", False):
        # The raised-hand override: a live ask outranks any snooze on
        # every surface, exactly as it already wakes the dropdown.
        return False
    work_key = getattr(status, "work_key", None)
    if type(work_key) is WorkKey and work_key in work_keys:
        return True
    provider = getattr(status, "provider", None)
    session_id = getattr(status, "session_id", None)
    if (
        isinstance(provider, str)
        and isinstance(session_id, str)
        and (provider, session_id) in family_ids
    ):
        return True
    return getattr(status, "agent_id", None) in agent_ids


def run_agent_ids(work_key: WorkKey) -> tuple[str, str]:
    """The row ids one run's key can surface as: ``<provider>:session:<id>``
    for a main session, ``<provider>:agent:<id>`` for a worker -- so a run's
    snooze also covers a legacy-path row of the same run that carries no
    work key."""
    provider = work_key.source_key.provider_id
    work_id = work_key.work_id.value
    return (f"{provider}:session:{work_id}", f"{provider}:agent:{work_id}")


def active_snooze_until(preference, now: float) -> float | None:
    """The preference's snooze deadline while it is in force, else None."""
    if preference is None or not _active_snooze(preference, now):
        return None
    return float(preference.snoozed_until)


def _lapsed_run(preference: MailboxPreference, now: float) -> bool:
    return (
        preference.snooze_scope is MailboxSnoozeScope.RUN
        and not _active_snooze(preference, now)
    )


def _lifted(preference: MailboxPreference) -> MailboxPreference | None:
    """A run's snooze taken off: nothing is left on a key with no pin, watch
    or visit to keep (a worker's, usually), else the plain family preference
    that remains (a root's pin or watch)."""
    if (
        preference.mode is MailboxPreferenceMode.DEFAULT
        and preference.pin_order is None
        and preference.last_visited_at is None
    ):
        return None
    return replace(
        preference,
        snoozed_at=None,
        snoozed_until=None,
        snooze_scope=MailboxSnoozeScope.FAMILY,
    )


def _without_lapsed_runs(preferences, now: float) -> list[MailboxPreference]:
    """The preferences with every run snooze that has run out lifted."""
    kept: list[MailboxPreference] = []
    for preference in preferences:
        if type(preference) is not MailboxPreference:
            continue
        if _lapsed_run(preference, now):
            preference = _lifted(preference)
            if preference is None:
                continue
        kept.append(preference)
    return kept


def with_run_snooze(preferences, work_key: WorkKey, *, now: float, until: float):
    """``preferences`` with ``work_key``'s run quiet until ``until``.

    A family snooze in force on the same key is kept as it is: it already
    quiets this run, and trading it for a run's would wake the rest of the
    family. Returns a new tuple.
    """
    if type(work_key) is not WorkKey or not until > now:
        raise ValueError("a run snooze needs a work key and a deadline after now")
    kept = _without_lapsed_runs(preferences, now)
    existing = next((item for item in kept if item.work_key == work_key), None)
    if (
        existing is not None
        and existing.snooze_scope is MailboxSnoozeScope.FAMILY
        and active_snooze_until(existing, now) is not None
    ):
        return tuple(kept)
    updated = replace(
        existing or MailboxPreference(work_key),
        snoozed_at=now,
        snoozed_until=until,
        snooze_scope=MailboxSnoozeScope.RUN,
    )
    return tuple((*(item for item in kept if item.work_key != work_key), updated))


def without_run_snooze(preferences, work_key: WorkKey, *, now: float):
    """``preferences`` with any run snooze on ``work_key`` lifted (a family
    snooze on the same key is the family's to lift). Returns a new tuple."""
    kept = []
    for preference in _without_lapsed_runs(preferences, now):
        if preference.work_key == work_key and preference.snooze_scope is MailboxSnoozeScope.RUN:
            preference = _lifted(preference)
            if preference is None:
                continue
        kept.append(preference)
    return tuple(kept)


def status_snoozed(status, preferences, *, now: float) -> bool:
    """Whether this status is silenced for lights and notifications."""
    scopes = _snoozed_scopes(preferences, float(now))
    if not any(scopes):
        return False
    return _status_covered(status, *scopes)


def filter_snoozed_statuses(statuses, preferences, *, now: float):
    """Statuses minus currently snoozed sessions; asks break through.

    Returns the ORIGINAL tuple object when nothing is snoozed, so
    callers can cheaply detect "no filtering happened" by identity.
    """
    values = statuses if type(statuses) is tuple else tuple(statuses)
    scopes = _snoozed_scopes(preferences, float(now))
    if not any(scopes):
        return values
    kept = tuple(
        status for status in values if not _status_covered(status, *scopes)
    )
    return values if len(kept) == len(values) else kept


__all__ = [
    "active_snooze_until",
    "filter_snoozed_statuses",
    "run_agent_ids",
    "status_snoozed",
    "with_run_snooze",
    "without_run_snooze",
]
