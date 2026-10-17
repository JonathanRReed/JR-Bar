from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import usage_event_hooks as hooks
from jrbar.usage_hooks_cli import run_test, status_document


@pytest.mark.parametrize("field", ["executable", "arguments"])
def test_invalid_utf8_hook_rule_is_visible_and_does_not_block_valid_rules(field: str, monkeypatch) -> None:
    bad = {"id": "bad", "enabled": True, "event": "*", "executable": "/synthetic/hook", "arguments": []}
    bad[field] = "/synthetic/\ud800" if field == "executable" else ["\ud800"]
    config = hooks.load_usage_hook_config({"enabled": True, "rules": [
        bad, {"id": "good", "enabled": True, "event": "*", "executable": "/synthetic/good"},
    ]})

    def forbidden(*_args, **_kwargs):
        pytest.fail("An invalid hook rule must not launch a process")

    monkeypatch.setattr(hooks.subprocess, "Popen", forbidden)
    assert [rule.id for rule in config.runnable()] == ["good"]
    status = status_document(config, hooks.UsageHookResults())
    assert status["rules"][0]["problem"] == "a string is not valid UTF-8"
    assert status["rules"][1]["problem"] is None
    results = hooks.UsageHookResults()
    refused = run_test(config, event_name="quota_low", provider_id="codex", rule_id="bad", results=results)
    assert len(refused) == 1 and refused[0].outcome == "refused"
    assert results.get("bad") == refused[0]


def test_hook_process_value_error_becomes_a_result(tmp_path: Path) -> None:
    script = tmp_path / "synthetic-hook.sh"
    script.write_text("#!/bin/sh\nexit 0\n")
    script.chmod(0o700)
    rule = hooks.load_usage_hook_config({"rules": [{"id": "test", "executable": str(script)}]}).rules[0]
    result = hooks.run_rule(rule, hooks.sample_event("quota_low", "codex", now=1800000000.0),
                            environ={"HOME": "synthetic\x00invalid"}, clock=lambda: 1800000000.0)
    assert result.outcome == "error"
    assert result.detail is not None and result.detail.startswith("could not start:")
    assert result.at == 1800000000.0 and result.exit_code is None


def test_hook_start_refusal_does_not_abort_following_rule(monkeypatch) -> None:
    config = hooks.load_usage_hook_config({"enabled": True, "rules": [
        {"id": "first", "executable": "/synthetic/first"},
        {"id": "second", "executable": "/synthetic/second"},
    ]})
    seen = []

    def popen(argv, **_kwargs):
        seen.append(argv)
        if len(seen) == 1:
            raise ValueError("synthetic process refusal")
        return SimpleNamespace(returncode=0, communicate=lambda **_kwargs: None)

    monkeypatch.setattr(hooks.subprocess, "Popen", popen)
    results = hooks.UsageHookResults()
    logged = []
    event = hooks.sample_event("quota_reset", "codex", now=1800000000.0)
    worker = hooks.dispatch_usage_hooks(config, (event,), results=results, limiter=hooks.UsageHookLimiter(),
                                        environ={}, clock=lambda: 1800000000.0, log=logged.append)
    assert worker is not None
    worker.join(timeout=5.0)
    assert not worker.is_alive()
    assert seen == [["/synthetic/first"], ["/synthetic/second"]]
    assert results.get("first").outcome == "error"
    assert results.get("second").outcome == "ok"
    assert len(logged) == 1 and "synthetic process refusal" in logged[0]



def test_hook_argument_budget_counts_utf8_bytes_without_rejecting_unicode() -> None:
    def rule(argument: str) -> hooks.UsageHookRule:
        return hooks.load_usage_hook_config({"rules": [{
            "id": "unicode", "executable": "/synthetic/café", "arguments": [argument],
        }]}).rules[0]

    assert hooks.rule_problem(rule("é" * 2048)) is None
    assert hooks.rule_problem(rule("é" * 2049)) == "a string is over 4 KiB"
