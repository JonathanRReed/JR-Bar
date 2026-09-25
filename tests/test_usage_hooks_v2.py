"""Usage hooks v2: rules, a small environment, JSON on stdin, limits.

The first version inherited the daemon's whole environment, passed four
positional words and nothing else, and had one path per install. These
tests pin the new contract, including the parts that protect the person:
an API key in the daemon's environment never reaches a hook, a relative
path never runs, and a hung hook is killed.
"""

from __future__ import annotations

import json
import os
import stat
import threading
from pathlib import Path

from jrbar.settings import load_settings
from jrbar.usage_event_hooks import (
    MAX_ARGUMENTS,
    MAX_RULES,
    UsageHookConfig,
    UsageHookEvent,
    UsageHookLimiter,
    UsageHookResults,
    UsageHookRule,
    config_for_settings,
    dispatch_usage_hooks,
    encode_payload,
    hook_argv,
    load_usage_hook_config,
    rule_problem,
    run_rule,
)

EVENT = UsageHookEvent(
    "quota_low",
    "claude",
    "five-hour",
    "18",
    remaining_percent=18.0,
    reset_at=1_790_010_800.0,
    state="ready",
    threshold_percent=20.0,
    label="5-hour",
    occurred_at=1_790_000_000.0,
)


def _script(path: Path, body: str) -> Path:
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(stat.S_IRWXU)
    return path


def _rule(executable: str, **changes) -> UsageHookRule:
    raw = {
        "id": "test",
        "enabled": True,
        "event": "*",
        "provider": None,
        "threshold_remaining": None,
        "executable": executable,
        "arguments": [],
        "timeout_seconds": 10.0,
        "argv": "json",
    }
    raw.update(changes)
    return UsageHookRule.from_dict(raw)


def test_a_planted_api_key_never_reaches_the_hook(tmp_path: Path) -> None:
    dump = tmp_path / "env.txt"
    script = _script(tmp_path / "hook.sh", f'/usr/bin/env > "{dump}"\n')
    daemon_env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(tmp_path),
        "LANG": "en_US.UTF-8",
        "OPENAI_API_KEY": "sk-planted-never-share-0000",
        "ANTHROPIC_API_KEY": "sk-ant-planted",
        "JRBAR_EVENT": "forged-by-the-parent",
    }

    result = run_rule(_rule(str(script)), EVENT, environ=daemon_env)

    assert result.outcome == "ok", result
    seen = dict(line.split("=", 1) for line in dump.read_text().splitlines() if "=" in line)
    assert "OPENAI_API_KEY" not in seen
    assert "ANTHROPIC_API_KEY" not in seen
    assert seen["PATH"] == "/usr/bin:/bin"
    assert seen["LANG"] == "en_US.UTF-8"
    assert seen["JRBAR_EVENT"] == "quota_low"
    assert seen["JRBAR_PROVIDER"] == "claude"
    assert seen["JRBAR_INSTANCE"] == "default"
    assert seen["JRBAR_LANE"] == "five-hour"
    assert seen["JRBAR_REMAINING_PERCENT"] == "18.00"
    assert seen["JRBAR_RESET_AT"] == "1790010800"
    assert seen["JRBAR_STATE"] == "ready"
    assert seen["JRBAR_TIMESTAMP"] == "1790000000"


#: Sorted keys, compact, optional fields left out (no event_id here), and
#: never an account label.
GOLDEN = (
    '{"event":"quota_low","instance":"default","label":"5-hour","lane":"five-hour",'
    '"provider":"claude","remaining_percent":18.0,"reset_at":1790010800.0,"state":"ready",'
    '"threshold_percent":20.0,"timestamp":1790000000.0,"v":1}\n'
)


def test_the_stdin_document_is_golden(tmp_path: Path) -> None:
    captured = tmp_path / "stdin.json"
    script = _script(tmp_path / "hook.sh", f'/bin/cat > "{captured}"\n')

    result = run_rule(_rule(str(script)), EVENT, environ={"PATH": "/usr/bin:/bin"})

    assert result.outcome == "ok"
    assert captured.read_text() == GOLDEN
    assert encode_payload(EVENT).decode() == GOLDEN


def test_provider_event_and_threshold_filters() -> None:
    assert _rule("/bin/true").matches(EVENT)
    assert _rule("/bin/true", event="quota_low").matches(EVENT)
    assert not _rule("/bin/true", event="quota_reached").matches(EVENT)
    assert _rule("/bin/true", provider="claude").matches(EVENT)
    assert not _rule("/bin/true", provider="codex").matches(EVENT)
    assert _rule("/bin/true", threshold_remaining=20.0).matches(EVENT)
    assert not _rule("/bin/true", threshold_remaining=10.0).matches(EVENT)
    assert not _rule("/bin/true", enabled=False).matches(EVENT)
    # A threshold only matches an event that states a remaining percent.
    unavailable = UsageHookEvent("provider_unavailable", "claude", "", "error")
    assert not _rule("/bin/true", threshold_remaining=50.0).matches(unavailable)


def test_the_chatty_events_are_limited_to_one_run_per_ten_minutes() -> None:
    limiter = UsageHookLimiter()
    rule = _rule("/bin/true")
    update = UsageHookEvent("usage_updated", "claude", "five-hour", "57", remaining_percent=57.0)
    other_lane = UsageHookEvent("usage_updated", "claude", "weekly", "80", remaining_percent=80.0)

    assert limiter.admit(rule, update, 1_000.0)
    assert not limiter.admit(rule, update, 1_599.0)
    assert limiter.admit(rule, other_lane, 1_100.0)
    assert limiter.admit(rule, update, 1_600.0)
    # The edges are never limited.
    assert limiter.admit(rule, EVENT, 1_000.0)
    assert limiter.admit(rule, EVENT, 1_001.0)
    failed = UsageHookEvent("refresh_failed", "claude", "", "network_unavailable")
    assert limiter.admit(rule, failed, 1_000.0)
    assert not limiter.admit(rule, failed, 1_300.0)


def test_limits_fail_closed(tmp_path: Path) -> None:
    rules = [
        {"id": f"r{index}", "enabled": True, "event": "*", "executable": "/bin/true"}
        for index in range(MAX_RULES + 1)
    ]
    crowded = load_usage_hook_config({"enabled": True, "rules": rules})
    assert crowded.problem is not None
    assert crowded.runnable() == ()

    assert rule_problem(_rule("/bin/true", arguments=["x"] * (MAX_ARGUMENTS + 1))) is not None
    assert rule_problem(_rule("/bin/true", arguments=["x" * 5000])) is not None
    assert rule_problem(_rule("/bin/true", event="quota_exploded")) is not None
    assert rule_problem(_rule("/bin/true")) is None

    huge = UsageHookEvent("quota_low", "claude", "five-hour", "1", label="x" * 5000)
    ran = tmp_path / "ran"
    script = _script(tmp_path / "hook.sh", f'/usr/bin/touch "{ran}"\n')
    result = run_rule(_rule(str(script)), huge, environ={"PATH": "/usr/bin:/bin"})
    assert result.outcome == "refused"
    assert not ran.exists()


def test_a_relative_executable_is_refused(tmp_path: Path) -> None:
    script = _script(tmp_path / "hook.sh", "exit 0\n")
    relative = os.path.relpath(script)

    assert rule_problem(_rule(relative)) == "the executable must be an absolute path"
    assert rule_problem(_rule("hook.sh")) == "the executable must be an absolute path"
    result = run_rule(_rule("hook.sh"), EVENT, environ={"PATH": str(tmp_path)})
    assert result.outcome == "refused"


def test_a_legacy_hook_path_migrates_and_keeps_its_argv(tmp_path: Path) -> None:
    record = tmp_path / "argv.txt"
    script = _script(tmp_path / "hook.sh", f'echo "$#:$1|$2|$3|$4" > "{record}"\n')
    settings_file = tmp_path / "settings.json"
    settings_file.write_text(json.dumps({"usage_event_hook_path": str(script)}), encoding="utf-8")

    settings = load_settings(settings_file)
    config = config_for_settings(settings)

    assert settings.usage_hooks["enabled"] is True
    [rule] = config.rules
    assert (rule.id, rule.argv, rule.event) == ("legacy", "legacy", "*")
    assert hook_argv(rule, EVENT) == [str(script), "quota_low", "claude", "five-hour", "18"]
    result = run_rule(rule, EVENT, environ={"PATH": "/usr/bin:/bin"})
    assert result.outcome == "ok"
    assert record.read_text().strip() == "4:quota_low|claude|five-hour|18"
    # The legacy rule keeps the first version's five events.
    assert not rule.matches(UsageHookEvent("usage_updated", "claude", "five-hour", "57"))
    # Saving and loading again keeps the one rule (no second migration).
    again = load_settings(settings_file)
    assert len(config_for_settings(again).rules) == 1


def test_a_hung_hook_is_killed_with_its_children(tmp_path: Path) -> None:
    pids = tmp_path / "pids"
    script = _script(
        tmp_path / "hook.sh",
        f'/bin/sleep 30 &\necho "$$ $!" > "{pids}"\nwait\n',
    )

    # The kill must be what ends the run, so the shell has to get as far
    # as starting its child first. A loaded Mac can take longer than two
    # seconds to start a shell; then the run is repeated with more time,
    # still well short of the child's 30 s.
    for timeout in (2.0, 6.0, 15.0):
        result = run_rule(_rule(str(script), timeout_seconds=timeout), EVENT, environ={"PATH": "/usr/bin:/bin"})
        assert result.outcome == "timeout"
        if pids.exists():
            break
    assert pids.exists(), "the hook's shell never started, even with 15 s"
    shell_pid, child_pid = (int(value) for value in pids.read_text().split())
    gone = threading.Event()
    for _ in range(200):
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            gone.set()
            break
        gone.wait(0.05)
    assert gone.is_set(), "the hook's own child outlived the timeout"
    try:
        os.kill(shell_pid, 0)
        alive = True
    except ProcessLookupError:
        alive = False
    assert not alive


def test_a_new_first_version_path_changes_the_program_the_legacy_rule_runs(tmp_path: Path) -> None:
    from jrbar.core_runtime import settings_from_document

    old = _script(tmp_path / "old.sh", "exit 0\n")
    new = _script(tmp_path / "new.sh", "exit 0\n")
    settings_file = tmp_path / "settings.json"
    settings_file.write_text(json.dumps({"usage_event_hook_path": str(old)}), encoding="utf-8")
    migrated = load_settings(settings_file)
    document = migrated.to_dict()
    assert document["usage_hooks"]["rules"][0]["executable"] == str(old)

    # set_setting (or a hand edit) changes only the first version's key;
    # the saved usage_hooks still names the old program.
    document["usage_event_hook_path"] = str(new)
    moved = settings_from_document(document, scratch_dir=tmp_path)
    [rule] = config_for_settings(moved).rules
    assert (rule.id, rule.executable, rule.argv, rule.enabled) == ("legacy", str(new), "legacy", True)
    assert moved.usage_hooks["enabled"] is True

    # An empty path removes the rule, as the legacy window's field does.
    cleared = moved.to_dict()
    cleared["usage_event_hook_path"] = ""
    gone = settings_from_document(cleared, scratch_dir=tmp_path)
    assert config_for_settings(gone).rules == ()
    assert gone.usage_hooks["enabled"] is False

    # A path set where no legacy rule is left adds it back.
    again = gone.to_dict()
    again["usage_event_hook_path"] = str(old)
    back = settings_from_document(again, scratch_dir=tmp_path)
    assert [rule.executable for rule in config_for_settings(back).rules] == [str(old)]


def test_a_legacy_rule_the_person_turned_off_stays_off_while_the_path_is_unchanged(tmp_path: Path) -> None:
    from jrbar.core_runtime import settings_from_document

    script = _script(tmp_path / "chime.sh", "exit 0\n")
    settings_file = tmp_path / "settings.json"
    settings_file.write_text(json.dumps({"usage_event_hook_path": str(script)}), encoding="utf-8")
    document = load_settings(settings_file).to_dict()
    document["usage_hooks"]["rules"][0]["enabled"] = False

    kept = settings_from_document(document, scratch_dir=tmp_path)

    assert kept.usage_hooks["rules"][0]["enabled"] is False
    # A file with no first-version key at all leaves the rules alone.
    del document["usage_event_hook_path"]
    assert settings_from_document(document, scratch_dir=tmp_path).usage_hooks["rules"][0]["executable"] == str(script)


def test_duplicate_rule_ids_that_already_end_in_a_number_settle(tmp_path: Path) -> None:
    from jrbar.usage_source_settings import normalize_usage_hooks

    long_id = "a" * 56 + "-2"
    raw = {"enabled": True, "rules": [
        {"id": long_id, "executable": "/bin/true"},
        {"id": long_id, "executable": "/bin/true"},
        {"id": long_id, "executable": "/bin/true"},
    ]}
    answer: dict = {}
    done = threading.Event()

    def normalize() -> None:
        answer["hooks"] = normalize_usage_hooks(raw)
        done.set()

    threading.Thread(target=normalize, daemon=True).start()
    assert done.wait(5.0), "renaming a duplicate id never finished"
    ids = [rule["id"] for rule in answer["hooks"]["rules"]]
    assert ids == [long_id, "a" * 56 + "-3", "a" * 56 + "-4"]
    assert len(set(ids)) == 3


def test_one_thread_runs_the_whole_batch_and_records_results(tmp_path: Path) -> None:
    record = tmp_path / "events.txt"
    script = _script(tmp_path / "hook.sh", f'/bin/cat >> "{record}"\n')
    results = UsageHookResults()
    second = UsageHookEvent("provider_recovered", "codex", "", "ready", state="ready")
    config = UsageHookConfig(True, (_rule(str(script)),))

    worker = dispatch_usage_hooks(
        config,
        (EVENT, second),
        limiter=UsageHookLimiter(),
        results=results,
        environ={"PATH": "/usr/bin:/bin"},
        log=lambda _message: None,
    )

    assert worker is not None and worker.name == "JRBarUsageHooks"
    worker.join(timeout=10.0)
    assert not worker.is_alive()
    lines = [json.loads(line) for line in record.read_text().splitlines()]
    assert [line["event"] for line in lines] == ["quota_low", "provider_recovered"]
    assert results.get("test").outcome == "ok"


def test_nothing_runs_while_hooks_are_off(tmp_path: Path) -> None:
    ran = tmp_path / "ran"
    script = _script(tmp_path / "hook.sh", f'/usr/bin/touch "{ran}"\n')

    off = UsageHookConfig(False, (_rule(str(script)),))

    assert dispatch_usage_hooks(off, (EVENT,), log=lambda _message: None) is None
    assert not ran.exists()


def test_the_cli_adds_enables_lists_and_tests_a_rule(tmp_path: Path, monkeypatch) -> None:
    import io

    from jrbar.cli_entry import jrbar_main
    from jrbar.usage_hooks_cli import main

    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    captured = tmp_path / "stdin.json"
    script = _script(tmp_path / "hook.sh", f'/bin/cat > "{captured}"\n')

    def run(*args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        code = main(list(args), stdout=out, stderr=err)
        return code, out.getvalue(), err.getvalue()

    assert run("add", "--event", "quota_low", "relative.sh")[0] == 2
    code, out, _ = run("add", "--event", "quota_low", "--provider", "claude", "--id", "chime", str(script))
    assert code == 0 and "added rule chime" in out and "usage hooks are off" in out
    assert run("enable")[1].strip() == "usage hooks on"
    code, out, _ = run("list")
    assert "Usage hooks: on" in out and "chime" in out and "quota_low · claude" in out

    code, out, _ = run("test", "quota_low", "--provider", "claude")
    assert code == 0 and out.startswith("chime: Quota low: exit 0")
    assert json.loads(captured.read_text())["state"] == "test"
    # A provider the rule does not name matches nothing.
    assert "no rule matches" in run("test", "quota_low", "--provider", "codex")[1]

    assert run("disable", "chime")[0] == 0
    listed = json.loads(run("list", "--json")[1])
    assert listed["rules"][0]["enabled"] is False
    assert run("remove", "chime")[0] == 0
    assert json.loads(run("list", "--json")[1])["rules"] == []
    # The top-level router reaches it.
    assert jrbar_main(["usage-hooks", "list", "--json"]) == 0
