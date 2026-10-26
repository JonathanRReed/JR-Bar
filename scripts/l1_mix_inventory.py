"""Report the L1 grid's played programs. This does not set test expectations."""
import itertools
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from jrbar.colors import BLEND_MODE_CHOICES, _active_agents
from jrbar.light_mix import plan_agent_mix
from tests.test_l1_mix_grid import CASES, case_key, settings_for_case
from tests.test_light_mix import FAMILIES, settings_for, statuses

FIXTURE = Path("tests/fixtures/l1_mix_fallbacks.json")

def main():
    # A report only. Test expectations are maintained independently.
    fallbacks = {}
    reasons = {}
    safety = {}
    for case in CASES:
        mix, animation, variant, providers, count = case
        settings = settings_for_case(mix, animation, variant)
        plan = plan_agent_mix(_active_agents(statuses(providers), settings), settings, led_count=count)
        expected = animation if providers == 1 else mix
        if plan.played != expected:
            if any("at this speed" in warning or "too fast" in warning for warning in plan.warnings):
                safety[case_key(case)] = plan.played
            else:
                fallbacks[case_key(case)] = plan.played
                reasons[case_key(case)] = next(warning for warning in plan.warnings if "cannot play exactly" in warning)
    custom = {}
    for mix, family, count, providers in itertools.product(BLEND_MODE_CHOICES, FAMILIES, (2, 8), (1, 2, 3)):
        settings = settings_for(mix, family)
        plan = plan_agent_mix(_active_agents(statuses(providers), settings), settings, led_count=count)
        expected = family if providers == 1 else mix
        if plan.played != expected:
            custom[f"{mix}/{family}/{count}/{providers}"] = plan.played
    categories = Counter()
    for warning in reasons.values():
        if "LED shares" in warning:
            category = "shares > LEDs"
        elif "more than one LED" in warning:
            category = "animation needs >1 LED"
        elif "scanner beam" in warning:
            category = "Relay <4 LEDs"
        elif "stripe width" in warning:
            category = "Weave stripes"
        elif "two endpoints" in warning:
            category = "Tide endpoints on Dot"
        elif "losing their motion" in warning:
            category = "keyframes lose motion"
        elif "different durations" in warning:
            category = "different Studio periods"
        elif "512 bytes or 20 lines" in warning:
            category = ">512 bytes / 20 lines"
        else:
            raise ValueError(f"Unreviewed fallback: {warning}")
        categories[category] += 1
    FIXTURE.write_text(json.dumps({"fallbacks": fallbacks, "custom_parameters": custom,
        "safety_substitutions": safety, "reason_counts": dict(categories)}, indent=2) + "\n")



if __name__ == "__main__":
    main()
