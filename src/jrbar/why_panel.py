"""The words the Why explanation is made of.

The Swift app shows the explanation; the daemon only builds its text from
facts it already holds.
"""

from __future__ import annotations

import time

from .decision_trace import capacity_detail_text, decision_trace_text
from .why_light_context import format_why_light_context

__all__ = ["panel_body"]


def panel_body(controller: object, *, why_context: object | None = None) -> str:
    """Build the complete current-light explanation from cached facts."""
    context = (
        controller.current_why_light_context()
        if why_context is None
        else why_context
    )
    parts = [
        decision_trace_text(controller.current_decision_trace()),
        format_why_light_context(context),
    ]
    try:
        capacity = capacity_detail_text(controller.capacity_detail_models(now=time.time()))
    except (TypeError, ValueError):
        capacity = ""
    if capacity:
        parts.append(capacity)
    return "\n\n".join(parts)
