"""The Effect Studio's "Try a situation" answers the way the daemon does.

``EffectSituationResolver`` in the app mirrors ``resolve_effect_assignment``
so the Studio can say which assignment wins before anything happens. This
table is the same one ``EffectStudioSituationTests.swift`` checks the Swift
mirror against; a change to either resolver breaks one of the two.
"""

from __future__ import annotations

import pytest

from jrbar.effect_assignment_store import (
    AssignmentScope,
    EffectAssignmentContext,
    EffectAssignmentDocument,
    EffectAssignmentRecord,
    resolve_effect_assignment,
)
from jrbar.scenes import Scene
from jrbar.semantic_effect_router import SemanticEventKind

DOCUMENT = EffectAssignmentDocument(
    (
        EffectAssignmentRecord("pulse", AssignmentScope.GLOBAL, None),
        EffectAssignmentRecord("comet", AssignmentScope.SEMANTIC, "completion"),
        EffectAssignmentRecord("ember", AssignmentScope.SCENE, "night"),
        EffectAssignmentRecord("aurora", AssignmentScope.PROVIDER, "codex"),
        EffectAssignmentRecord("tide", AssignmentScope.PROVIDER_INSTANCE, "codex:work"),
        EffectAssignmentRecord("bloom", AssignmentScope.PROJECT, "Claude in VS Code"),
        EffectAssignmentRecord("glint", AssignmentScope.DEVICE, "pro-1"),
        EffectAssignmentRecord("alert", AssignmentScope.SEMANTIC, "asking"),
    )
)

# (event, scene, provider, instance, project, device) -> winning effect,
# or "reserved" for the urgent events the Studio calls reserved.
CASES = [
    (("completion", "calm", "claude", None, None, None), "comet"),
    (("completion", "night", "claude", None, None, None), "ember"),
    (("completion", "night", "codex", None, None, None), "aurora"),
    (("completion", "calm", "codex", "codex:work", None, None), "tide"),
    (("completion", "calm", "codex", None, "Claude in VS Code", None), "bloom"),
    (("completion", "night", "codex", None, None, "pro-1"), "glint"),
    (("notification", "calm", "claude", None, None, None), "pulse"),
    (("ask", "night", "codex", None, None, "pro-1"), "reserved"),
    (("failure", "calm", "codex", None, None, None), "reserved"),
]


@pytest.mark.parametrize(("situation", "expected"), CASES)
def test_the_studio_table_matches_the_daemon(situation, expected) -> None:
    event, scene, provider, instance, project, device = situation
    context = EffectAssignmentContext(
        semantic=SemanticEventKind(event),
        scene=Scene(scene),
        provider_id=provider,
        provider_instance_id=instance,
        project_id=project,
        device_id=device,
    )
    record = resolve_effect_assignment(DOCUMENT, context)
    if expected == "reserved":
        # Urgent events only ever see the state scope, where the alert
        # safeguard is the one effect allowed.
        assert record is None or record.effect_id == "alert"
    else:
        assert record is not None and record.effect_id == expected
