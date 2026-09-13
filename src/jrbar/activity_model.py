"""The canonical record vocabulary the upgrade's packages share (spec §14.2).

"Canonical" here means the *vocabulary* is fixed and each named record has
exactly one carrier — not that every record was retyped. Where an existing
type already carries the record faithfully this module names it; where the
record is new, the module that owns it is named. Downstream packages
(attention inbox, transport, Overview, audit) build on these names, and the
frozen wire shapes are pinned by ``tests/test_upgrade_roster.py`` and the
protocol fixtures.

Record carriers (spec §14.2 names → this tree):

* ``connection``      -- ``provider_facts.ProviderFactBatch`` /
  ``capacity_types`` account+source identity; health via
  ``SourceHealth``/``SourceFreshness``.
* ``session``         -- ``models.AgentStatus`` reduced to the
  ``session_document`` row (``core_projection``): stable JR-Bar id
  (provider-namespaced), native ``session_id``, parent link, source
  label. Axes added by this module below.
* ``run``             -- the session's ``event``/``lifecycle`` pair plus
  the ``Run`` facts providers attach through ``work_key``;
  attempt/turn identity is provider-native and preserved un-normalised.
* ``activity_event``  -- ``activity_ledger.ActivityEntry`` (bounded,
  identity-deduped, no prompt content).
* ``tool_invocation`` -- the row's ``tool`` field; full invocation
  detail is a transport-layer (W03) concern.
* ``attention_episode`` -- ``ask_episodes``/attention projection; the
  roster exposes episodes through the row's ``ask`` block.
* ``quota_lane``      -- ``capacity_types`` usage windows/lanes.
* ``command``         -- ``clear_agents`` receipts and the answer
  contract documents (W01); durable command/effect store is W19.
* ``context_manifest`` -- context/evidence selection is W21+; nothing
  here fabricates one.
* ``visual_identity`` -- ``PanelStore``/toy mapping; cosmetic only.

The five axes §14.2 requires stay separate: ``lifecycle`` (is the run
over), ``activity`` (what is it doing — the row's ``mode``),
``freshness`` (is the source still delivering), ``outcome`` (what the
provider reported), ``review`` (has a person looked). A row may
legitimately be ``lifecycle=active, activity=tool_running,
freshness=delayed`` — a flattened colour cannot say that.
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from enum import Enum
from typing import Any, Final

#: Serialized-contract version for every roster/record document this
#: module's vocabulary shapes. Bump on any field rename or removal;
#: additions may stay on the same version.
RECORD_SCHEMA_VERSION: Final = 1


class Outcome(str, Enum):
    """What the provider reported about how the run ended — NOT whether
    it ended (``lifecycle``) and NOT whether anyone reviewed it."""

    #: Not finished; no outcome exists to report.
    NONE = "none"
    #: The provider's own end event reported a clean stop.
    SUCCEEDED = "succeeded"
    #: The provider reported failure (blocked-error lifecycle).
    FAILED = "failed"
    #: The run ended but the provider never reported how — the liveness
    #: sweep closed the record, or the session simply stopped.
    UNREPORTED = "unreported"
    #: Inputs were too thin to classify (unknown lifecycle).
    UNKNOWN = "unknown"


class Review(str, Enum):
    """Whether a person has reviewed the finished result — the Clear
    Agents acknowledgement is the review receipt."""

    #: Still running; there is nothing to review yet.
    PENDING = "pending"
    #: Finished and never acknowledged — the inbox's "look at me" state.
    UNREVIEWED = "unreviewed"
    #: Acknowledged (cleared) or the row aged past review relevance.
    REVIEWED = "reviewed"


class Freshness(str, Enum):
    """Is the source still delivering for this record? Independent of
    what the record says — a delayed working session is still working,
    as far as anyone knows."""

    #: The source is delivering (or ended on its own say-so).
    LIVE = "live"
    #: The source stopped delivering (``stale``) — the record may still
    #: be true, it just has no current witness.
    DELAYED = "delayed"
    #: No observation clock at all (no ``updated_at``).
    UNKNOWN = "unknown"


OUTCOME_VALUES: Final = frozenset(member.value for member in Outcome)
REVIEW_VALUES: Final = frozenset(member.value for member in Review)
FRESHNESS_VALUES: Final = frozenset(member.value for member in Freshness)

_FINISHED_LIFECYCLES: Final = frozenset({"completed", "ended", "failed"})


def session_axes(
    *,
    lifecycle: object,
    stale: object,
    updated_at: object,
    acknowledged: bool,
) -> dict[str, str]:
    """The outcome/review/freshness axes for one projected session row.

    Pure: every input is a value already on the ``session_document`` row
    (``lifecycle``, ``stale``, ``updated_at``) plus the Clear Agents
    acknowledgement verdict for the row's id. Unknowns stay explicit —
    a missing ``updated_at`` is ``freshness: unknown``, not a guess.
    """
    lifecycle_word = str(lifecycle or "active")
    finished = lifecycle_word in _FINISHED_LIFECYCLES
    if lifecycle_word == "completed":
        outcome = Outcome.SUCCEEDED.value
    elif lifecycle_word == "failed":
        outcome = Outcome.FAILED.value
    elif lifecycle_word == "ended":
        outcome = Outcome.UNREPORTED.value
    elif lifecycle_word in ("active", "stale"):
        outcome = Outcome.NONE.value
    else:
        outcome = Outcome.UNKNOWN.value
    review = (
        Review.PENDING.value
        if not finished
        else Review.REVIEWED.value if acknowledged else Review.UNREVIEWED.value
    )
    known_clock = (
        type(updated_at) in {int, float}
        and not isinstance(updated_at, bool)
        and math.isfinite(float(updated_at))
    )
    freshness = (
        Freshness.UNKNOWN.value
        if not known_clock
        else Freshness.DELAYED.value if bool(stale) else Freshness.LIVE.value
    )
    return {"outcome": outcome, "review": review, "freshness": freshness}


def row_has_open_ask(row: Mapping[str, Any]) -> bool:
    """The roster's pin rule, read off the projected row: an ``ask``
    block the daemon attached. (``ask`` is absent/None otherwise.)"""
    return isinstance(row.get("ask"), Mapping)


__all__ = [
    "FRESHNESS_VALUES",
    "OUTCOME_VALUES",
    "RECORD_SCHEMA_VERSION",
    "REVIEW_VALUES",
    "Freshness",
    "Outcome",
    "Review",
    "row_has_open_ask",
    "session_axes",
]
