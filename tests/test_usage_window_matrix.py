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
from jrbar.provider_usage_parsers import (
    parse_antigravity_usage,
    parse_claude_usage,
    parse_codex_usage,
    parse_devin_usage,
)
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    failure_snapshot,
    provider_descriptors,
    select_authoritative_snapshot,
)

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

# One headline per column. Other pools remain in tooltips and Usage Center.
PANEL_WINDOWS = {
    "antigravity-quota.json": ("gemini-five-hour", "claude-gpt-weekly"),
    "claude-usage-max.json": ("five-hour", "weekly"),
    "codex-app-server-rate-limits-plus.json": ("five-hour", "weekly"),
    "codex-app-server-rate-limits-pro.json": ("spark-five-hour", "weekly"),
    "codex-rollout-rate-limits-spark.json": ("spark-five-hour", "spark-weekly"),
    "cursor-usage-summary.json": (None, "auto-composer"),
    "devin-usage.json": ("daily", "weekly"),
    "gemini-code-assist-quota.json": (None, "model-gemini-3-pro"),
    "grok-billing.json": (None, "credits"),
    "openai-api-usage.json": (None, None),
    "opencode-go-usage.json": ("go-rolling", "go-weekly"),
    "factory-pools": ("standard-5h", "standard-7d"),
    "factory-legacy": (None, "premium-billing"),
    "kiro-credits": (None, "monthly"),
    "kimi-windows": ("five-hour", "weekly"),
    "kilo-credits-pass": (None, "credits"),
    "claude-model-caps": (None, "weekly-sonnet"),
    "antigravity-all-pools": ("gemini-five-hour", "gemini-weekly"),
    "codex-unknown-five-hour": ("five-hour", "weekly"),
    "codex-last-good": ("five-hour", "weekly"),
    "codex-weekly-only": (None, "weekly"),
    "codex-all-unknown": ("five-hour", "weekly"),
    "codex-five-hour-only": ("five-hour", None),
    "devin-daily-only": ("daily", None),
    "devin-unknown-daily": ("daily", "weekly"),
}


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
    unknown_codex = parse_codex_usage(windows=[
        {"label": "5-hour", "used_percent": None},
        {"label": "Weekly", "used_percent": 23}], observed_at=CLOCK)
    missing_reading = failure_snapshot("codex", observed_at=CLOCK, state=ProviderSourceState.UNAVAILABLE,
                                      reason="reading_evidence_missing", action="Retry")
    snapshots += [
        ("codex-unknown-five-hour", unknown_codex),
        ("codex-last-good", select_authoritative_snapshot((missing_reading,), last_known_good=unknown_codex)),
        ("codex-weekly-only", parse_codex_usage(windows=[
            {"label": "Weekly", "used_percent": 23}], observed_at=CLOCK)),
        ("codex-all-unknown", parse_codex_usage(windows=[
            {"label": "5-hour", "used_percent": None},
            {"label": "Weekly", "used_percent": None}], observed_at=CLOCK)),
        ("codex-five-hour-only", parse_codex_usage(windows=[
            {"label": "5-hour", "used_percent": 30}], observed_at=CLOCK)),
        ("devin-daily-only", parse_devin_usage({"daily_percentage": 0}, observed_at=CLOCK)),
        ("devin-unknown-daily", parse_devin_usage({
            "daily_percentage": None, "weekly_percentage": 71}, observed_at=CLOCK)),
    ]
    cases = []
    for name, snapshot in snapshots:
        document = usage_document(SimpleNamespace(snapshots=(snapshot,)))
        provider = document["providers"][0]
        placements = {}
        for window in provider["windows"]:
            key = window["id"]
            assert key in FIVE_HOUR | WEEKLY | LABELLED, f"add an explicit placement for {key}"
            placements[key] = "5h" if key in FIVE_HOUR else "7d" if key in WEEKLY else "labelled"
        panel_windows = dict(zip(("short", "cycle"), PANEL_WINDOWS[name]))
        by_id = {w["id"]: w for w in provider["windows"]}
        panel_cells = {
            column: "empty" if key is None else "dash" if by_id[key]["used_pct"] is None else "reading"
            for column, key in panel_windows.items()
        }
        cases.append({"name": name, "provider": provider, "placements": placements,
                      "panel_windows": panel_windows, "panel_cells": panel_cells})
    return {"now": CLOCK - 3600, "cases": cases}


def test_matrix_matches_real_parsers_and_every_registered_provider():
    generated = matrix()
    assert {case["provider"]["id"] for case in generated["cases"]} == {
        descriptor.provider_id for descriptor in provider_descriptors()}
    assert json.loads(FIXTURE.read_text()) == generated
    covered = {key for case in generated["cases"] for key in case["placements"]}
    assert covered == FIVE_HOUR | WEEKLY | LABELLED
    by_name = {case["name"]: case for case in generated["cases"]}
    assert set(by_name) == set(PANEL_WINDOWS)
    assert by_name["grok-billing.json"]["panel_cells"] == {"short": "empty", "cycle": "reading"}
    assert by_name["devin-usage.json"]["panel_cells"] == {"short": "reading", "cycle": "reading"}
    assert by_name["codex-unknown-five-hour"]["panel_cells"] == {"short": "dash", "cycle": "reading"}
    assert by_name["codex-last-good"]["panel_cells"] == {"short": "dash", "cycle": "reading"}
    assert by_name["codex-weekly-only"]["panel_cells"] == {"short": "empty", "cycle": "reading"}
    assert by_name["codex-all-unknown"]["panel_cells"] == {"short": "dash", "cycle": "dash"}
    assert by_name["codex-five-hour-only"]["panel_cells"] == {"short": "reading", "cycle": "empty"}
    assert by_name["devin-daily-only"]["panel_cells"] == {"short": "reading", "cycle": "empty"}
    assert by_name["devin-unknown-daily"]["panel_cells"] == {"short": "dash", "cycle": "reading"}


if __name__ == "__main__":
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(json.dumps(matrix(), indent=2) + "\n")
