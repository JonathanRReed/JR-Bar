"""One contract over every provider usage fixture.

Each file in ``tests/fixtures/provider_usage/`` goes through its provider's
real parser, and every snapshot must keep the same promises: lane ids are
unique, a remaining percent is 0-100 or honestly unknown, a reset is in the
future of the fixture's clock (or unknown), no secret reaches any field,
and only the lanes a provider's own catalog knows may drive the lights.
CodexBar's ProviderQuotaFixtureContractTests (MIT) is the idea; this is our
own suite.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from jrbar import claude_quota, usage_stats
from jrbar.provider_reconnect import codex_app_server_probe
from jrbar.provider_usage_parsers import (
    parse_antigravity_usage,
    parse_claude_usage,
    parse_codex_usage,
    parse_cursor_usage,
    parse_devin_usage,
    parse_gemini_usage,
    parse_grok_usage,
    parse_openai_api_usage,
    parse_opencode_go_usage,
)
from jrbar.provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot

FIXTURES = Path(__file__).parent / "fixtures" / "provider_usage"
#: The fixtures' clock: the moment the Codex and Claude captures were taken.
CLOCK = 1_789_073_144.0

#: The lanes each provider's own catalog knows: the only ones allowed to
#: be bindable. Everything else is evidence, shown as detail.
CATALOG = {
    "claude": {"five-hour", "weekly", "weekly-opus", "weekly-sonnet"},
    "codex": {"five-hour", "weekly"},
    "cursor": {"included-plan", "auto-composer", "api-models"},
    "devin": {"daily", "weekly"},
    "grok": {"credits"},
    "gemini": set(),
    "antigravity": {
        "gemini-five-hour",
        "gemini-weekly",
        "gemini-session",
        "claude-gpt-five-hour",
        "claude-gpt-weekly",
        "claude-gpt-session",
    },
    "openai-api": set(),
    "opencode": {"go-rolling", "go-weekly"},
}

_SECRETS = (
    re.compile(r"(?i)\bbearer\s+\S{8,}"),
    re.compile(r"\beyJ[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}"),
    re.compile(r"(?i)(?:^|[^a-z0-9])(?:sk|pk)[-_][a-z0-9]{6,}"),
    re.compile(r"(?i)\b(?:access|refresh)_?token\b"),
    re.compile(r"(?i)\bapi[_-]?key\b"),
)


def _load(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def _codex_app_server(name: str) -> ProviderUsageSnapshot:
    lines = [
        json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"userAgent": "codex/0.153.4 mac"}}),
        json.dumps({"jsonrpc": "2.0", "id": 2, "result": _load(name)}),
        json.dumps({"jsonrpc": "2.0", "id": 3, "result": {"account": {"email": "user@example.com"}}}),
    ]
    probe = codex_app_server_probe(runner=lambda: "\n".join(lines))
    return parse_codex_usage(
        windows=probe["windows"], observed_at=CLOCK, account_plan=probe["plan"], source_id="codex-app-server"
    )


PARSERS = {
    "claude-usage-max.json": lambda: parse_claude_usage(
        windows=claude_quota.windows_from_payload(_load("claude-usage-max.json")), observed_at=CLOCK
    ),
    "codex-app-server-rate-limits-plus.json": lambda: _codex_app_server("codex-app-server-rate-limits-plus.json"),
    "codex-app-server-rate-limits-pro.json": lambda: _codex_app_server("codex-app-server-rate-limits-pro.json"),
    "codex-rollout-rate-limits-spark.json": lambda: parse_codex_usage(
        windows=usage_stats.codex_windows_from_limits(_load("codex-rollout-rate-limits-spark.json")),
        observed_at=CLOCK,
    ),
    "cursor-usage-summary.json": lambda: parse_cursor_usage(_load("cursor-usage-summary.json"), observed_at=CLOCK),
    "devin-usage.json": lambda: parse_devin_usage(_load("devin-usage.json"), observed_at=CLOCK),
    "grok-billing.json": lambda: parse_grok_usage(_load("grok-billing.json"), observed_at=CLOCK),
    "gemini-code-assist-quota.json": lambda: parse_gemini_usage(
        _load("gemini-code-assist-quota.json"), observed_at=CLOCK
    ),
    "antigravity-quota.json": lambda: parse_antigravity_usage(_load("antigravity-quota.json"), observed_at=CLOCK),
    "openai-api-usage.json": lambda: parse_openai_api_usage(_load("openai-api-usage.json"), observed_at=CLOCK),
    "opencode-go-usage.json": lambda: parse_opencode_go_usage(_load("opencode-go-usage.json"), observed_at=CLOCK),
}


def test_every_fixture_has_a_parser_and_every_provider_a_fixture() -> None:
    on_disk = {path.name for path in FIXTURES.glob("*.json")}
    assert on_disk == set(PARSERS), "a fixture without a contract entry, or an entry without a file"
    covered = {PARSERS[name]().provider_id for name in PARSERS}
    assert covered == set(CATALOG)


@pytest.mark.parametrize("name", sorted(PARSERS))
def test_the_contract_holds(name: str) -> None:
    snapshot = PARSERS[name]()

    assert type(snapshot) is ProviderUsageSnapshot
    assert snapshot.state is ProviderSourceState.READY
    ids = [lane.lane_id for lane in snapshot.lanes]
    assert len(ids) == len(set(ids)), "lane ids are unique"
    for lane in snapshot.lanes:
        assert lane.provider_id == snapshot.provider_id
        assert lane.remaining_percent is None or 0.0 <= lane.remaining_percent <= 100.0
        assert lane.reset_at is None or lane.reset_at > CLOCK, f"{lane.lane_id} resets in the fixture's past"
        if lane.bindable:
            assert lane.lane_id in CATALOG[snapshot.provider_id], f"{lane.lane_id} is not a catalog lane"
    text = repr(snapshot) + json.dumps((FIXTURES / name).read_text(encoding="utf-8"))
    for pattern in _SECRETS:
        assert pattern.search(text) is None, f"{name} carries something secret-shaped: {pattern.pattern}"


def test_an_unknown_window_is_unknown_not_zero() -> None:
    gemini = PARSERS["gemini-code-assist-quota.json"]()
    lanes = {lane.label: lane for lane in gemini.lanes}
    assert lanes["gemini-2.5-flash-lite"].remaining_percent is None
    assert all(not lane.bindable for lane in gemini.lanes)


def test_every_fixture_says_whether_it_was_captured_or_shaped() -> None:
    readme = (FIXTURES / "README.md").read_text(encoding="utf-8")
    for path in sorted(FIXTURES.glob("*.json")):
        assert f"| `{path.name}` |" in readme, f"{path.name} has no row in README.md saying where it came from"
