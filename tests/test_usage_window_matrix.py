"""Parser-to-Swift placement fixtures use synthetic provider payloads only."""

import json
from pathlib import Path
from types import SimpleNamespace

from test_factory_usage import billing
from test_provider_usage_fixture_contract import CLOCK, PARSERS
from test_provider_usage_kilo import batch
from test_provider_usage_kiro import payload as kiro_payload

from jrbar.core_projection import usage_document
from jrbar.provider_usage_factory import parse_factory_usage
from jrbar.provider_usage_kilo import parse_kilo_usage
from jrbar.provider_usage_kimi import parse_kimi_usage
from jrbar.provider_usage_kiro import parse_kiro_usage
from jrbar.provider_usage_parsers import parse_antigravity_usage, parse_claude_usage
from jrbar.provider_usage_platform import provider_descriptors

FIXTURE = Path(__file__).resolve().parents[1] / "app/Tests/JRBarAppTests/Fixtures/usage-window-matrix.json"

# Explicit expectations, independent of the Swift placement implementation.
FIVE_HOUR = {"five-hour", "spark-five-hour", "gemini-five-hour", "claude-gpt-five-hour",
             "gemini-argon-five-hour", "standard-5h", "core-5h", "go-rolling"}
WEEKLY = {"weekly", "spark-weekly", "fable-only", "weekly-opus", "weekly-sonnet",
          "gemini-weekly", "claude-gpt-weekly", "gemini-argon-weekly",
          "standard-7d", "core-7d", "go-weekly"}
LABELLED = {"daily", "monthly", "credits", "overage", "pass", "go-monthly",
            "included-plan", "auto-composer", "api-models", "standard-30d", "core-30d",
            "standard-billing", "premium-billing", "gemini-session", "claude-gpt-session",
            "model-gemini-3-pro", "model-gemini-3-flash", "model-gemini-2-5-flash-lite"}


def matrix():
    snapshots = [(name, parser()) for name, parser in sorted(PARSERS.items())]
    factory = billing(True)
    for pool in factory["limits"].values():
        pool["weekly"]["windowEnd"] = CLOCK + 86400
    snapshots += [
        ("factory-pools", parse_factory_usage(factory, observed_at=CLOCK)),
        ("factory-legacy", parse_factory_usage({"usesTokenRateLimitsBilling": False, "usage": {
            "standard": {"usedRatio": .2}, "premium": {"usedRatio": .4}}}, observed_at=CLOCK)),
        ("kiro-credits", parse_kiro_usage(kiro_payload(), observed_at=CLOCK)),
        ("kimi-windows", parse_kimi_usage({"usages": {
            key: {"used_ratio": .3} for key in ("limit_5h", "limit_7d", "limit_month_total")
        }}, observed_at=CLOCK)),
        ("kilo-credits-pass", parse_kilo_usage(batch(subscription={
            "currentPeriodUsageUsd": 4, "currentPeriodBaseCreditsUsd": 10,
            "currentPeriodBonusCreditsUsd": 6}), observed_at=CLOCK)),
        ("claude-model-caps", parse_claude_usage(windows=[
            {"label": "weekly-opus", "used_percent": 20},
            {"label": "weekly-sonnet", "used_percent": 30}], observed_at=CLOCK)),
    ]
    groups = []
    for group in ("Gemini models", "Claude and GPT models", "Gemini Argon"):
        buckets = [{"window": cadence, "displayName": cadence, "remainingFraction": .72}
                   for cadence in ("5h", "weekly")]
        if group != "Gemini Argon":
            buckets.append({"displayName": "Session", "remainingFraction": .8})
        groups.append({"displayName": group, "buckets": buckets})
    snapshots.append(("antigravity-all-pools", parse_antigravity_usage(
        {"response": {"groups": groups}}, observed_at=CLOCK)))
    cases = []
    for name, snapshot in snapshots:
        document = usage_document(SimpleNamespace(snapshots=(snapshot,)))
        provider = document["providers"][0]
        placements = {}
        for window in provider["windows"]:
            key = window["id"]
            assert key in FIVE_HOUR | WEEKLY | LABELLED, f"add an explicit placement for {key}"
            placements[key] = "5h" if key in FIVE_HOUR else "7d" if key in WEEKLY else "labelled"
        cases.append({"name": name, "provider": provider, "placements": placements})
    return {"now": CLOCK - 3600, "cases": cases}


def test_matrix_matches_real_parsers_and_every_registered_provider():
    generated = matrix()
    assert {case["provider"]["id"] for case in generated["cases"]} == {
        descriptor.provider_id for descriptor in provider_descriptors()}
    assert json.loads(FIXTURE.read_text()) == generated
    covered = {key for case in generated["cases"] for key in case["placements"]}
    assert covered == FIVE_HOUR | WEEKLY | LABELLED


if __name__ == "__main__":
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(json.dumps(matrix(), indent=2) + "\n")
