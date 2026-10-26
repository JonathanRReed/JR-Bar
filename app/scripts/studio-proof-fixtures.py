#!/usr/bin/env python3
"""Render synthetic Studio programs through the daemon's production renderers."""

import json
import sys
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

from jrbar.colors import ColorSettings, preview_statuses_for_scenario, provider_motion_preview_program
from jrbar.core_effects import catalog_document
from jrbar.core_lights import list_cues, preview_fleet
from jrbar.effect_registry import EFFECT_REGISTRY
from jrbar.light_mix import explain_what_plays, mix_catalog
from jrbar.providers import PROVIDER_SPECS
from jrbar.settings import AgentMonitorSettings

colors = ColorSettings.defaults().with_blend_mode("weave")
colors = colors.with_agent_animation("codex", "comet").with_agent_animation("claude", "breathe")
controller = SimpleNamespace(settings=replace(AgentMonitorSettings(), colors=colors))
scenarios = ["one_working", "pair", "fleet", "one_needs_you"]
previews = {
    f"{scenario}|{mix['id']}": preview_fleet(controller, dict(scenario=scenario, blend_mode=mix["id"], led_count=8))
    for scenario in scenarios
    for mix in mix_catalog()
}
devices = [
    dict(device=device, **explain_what_plays(preview_statuses_for_scenario("fleet"), colors, led_count=count))
    for device, count in [("proof-strip", 8), ("virtual:status-bar", 8), ("proof-dot", 2)]
]
document = dict(
    plan=dict(mixes=mix_catalog(), devices=devices),
    previews=previews,
    settings=controller.settings.to_dict(),
    catalog=catalog_document(EFFECT_REGISTRY, []),
    cues=list_cues(controller, {})["cues"],
    providers={
        provider: provider_motion_preview_program(provider, colors.agent_color(provider), colors, led_count=8)
        for provider in (spec.provider for spec in PROVIDER_SPECS)
    },
)
Path(sys.argv[1]).write_text(json.dumps(document, indent=2) + "\n")
