"""``jrbar usage-hooks``: list, add, enable, disable, test and remove the
usage hooks (usage_event_hooks).

Changes go through the running monitor when it answers (``set_setting``
on ``usage_hooks``), so the app's Settings page moves with them; without
a monitor they are written to settings.json directly. ``test`` runs the
matching rules right here, with a made-up event marked ``state: test``,
and prints what each one did.

The daemon's two commands for the app's Hooks section live here too:
``usage_hooks_status`` (the rules, why any of them will not run, and each
rule's last result) and ``usage_hooks_test`` (the Test button).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, TextIO

from .usage_event_hooks import (
    MAX_RULES,
    SHARED_RESULTS,
    UsageHookConfig,
    UsageHookResult,
    UsageHookResults,
    UsageHookRule,
    config_for_settings,
    load_usage_hook_config,
    rule_problem,
    run_rule,
    sample_event,
)
from .usage_source_settings import (
    DEFAULT_USAGE_HOOK_TIMEOUT_SECONDS,
    USAGE_HOOK_ANY_EVENT,
    USAGE_HOOK_EVENTS,
    normalize_usage_hooks,
)

#: The Test button waits at most this long: the app gives a command ten.
DAEMON_TEST_TIMEOUT_SECONDS = 8.0


# --- documents shared by the CLI and the daemon ---------------------------


def status_document(config: UsageHookConfig, results: UsageHookResults = SHARED_RESULTS) -> dict[str, Any]:
    """Every rule with the reason it will not run and its last result."""
    last = results.snapshot()
    rows = []
    for rule in config.rules:
        row = rule.to_dict()
        row["problem"] = rule_problem(rule)
        result = last.get(rule.id)
        row["last_result"] = None if result is None else {**result.to_dict(), "sentence": result.sentence()}
        rows.append(row)
    return {
        "enabled": config.enabled,
        "problem": config.problem,
        "events": list(USAGE_HOOK_EVENTS),
        "rules": rows,
    }


def run_test(
    config: UsageHookConfig,
    *,
    event_name: str,
    provider_id: str,
    rule_id: str | None = None,
    timeout: float | None = None,
    results: UsageHookResults = SHARED_RESULTS,
    environ=None,
) -> list[UsageHookResult]:
    """Run the rules a made-up event would match (or just ``rule_id``),
    whatever the master switch says, and record each result."""
    if event_name not in USAGE_HOOK_EVENTS:
        raise ValueError(f"unknown event {event_name!r}; one of {', '.join(USAGE_HOOK_EVENTS)}")
    event = sample_event(event_name, provider_id)
    if rule_id is not None:
        chosen = [rule for rule in config.rules if rule.id == rule_id]
        if not chosen:
            raise ValueError(f"no usage hook rule {rule_id!r}")
    else:
        chosen = [rule for rule in config.rules if rule.matches(event)]
    outcomes = []
    for rule in chosen:
        result = run_rule(rule, event, environ=environ, timeout=timeout)
        results.record(result)
        outcomes.append(result)
    return outcomes


# --- daemon commands (registered in core_runtime) --------------------------


def core_status_command(controller, _args: dict[str, Any]) -> dict[str, Any]:
    return status_document(config_for_settings(getattr(controller, "settings", None)))


def core_test_command(controller, args: dict[str, Any]) -> dict[str, Any]:
    from .core_server import CommandError

    event_name = str(args.get("event") or "quota_low")
    provider_id = str(args.get("provider") or "claude")
    rule_id = args.get("rule") if isinstance(args.get("rule"), str) else None
    config = config_for_settings(getattr(controller, "settings", None))
    try:
        outcomes = run_test(
            config,
            event_name=event_name,
            provider_id=provider_id,
            rule_id=rule_id,
            timeout=DAEMON_TEST_TIMEOUT_SECONDS,
        )
    except ValueError as error:
        raise CommandError("invalid_args", str(error)) from error
    return {
        "event": event_name,
        "provider": provider_id,
        "results": [{**result.to_dict(), "sentence": result.sentence()} for result in outcomes],
        "status": status_document(config),
    }


# --- the CLI ---------------------------------------------------------------


class _Store:
    """The settings document, through the monitor when it answers."""

    def __init__(self) -> None:
        self.via_core = False

    def load(self) -> dict[str, Any]:
        try:
            from .cli_control import CoreConnection, default_socket_path

            with CoreConnection(default_socket_path(), timeout=2.0) as core:
                document = core.document("settings").get("document") or {}
                self.via_core = True
                return normalize_usage_hooks(document.get("usage_hooks"))
        except Exception:
            from .settings import load_settings

            self.via_core = False
            return normalize_usage_hooks(load_settings().usage_hooks)

    def save(self, hooks: dict[str, Any]) -> None:
        hooks = normalize_usage_hooks(hooks)
        if self.via_core:
            from .cli_control import CoreConnection, default_socket_path

            with CoreConnection(default_socket_path(), timeout=5.0) as core:
                core.command("set_setting", {"path": "usage_hooks", "value": hooks})
            return
        from .settings import load_settings, save_settings

        save_settings(load_settings().with_usage_hooks(hooks))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="jrbar usage-hooks",
        description="Run your own program when a usage event happens (no shell, a small environment, JSON on stdin).",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="Show the rules, why any will not run, and each one's last result")
    listing.add_argument("--json", action="store_true")
    for name in ("enable", "disable"):
        item = commands.add_parser(name, help=f"{name.title()} usage hooks, or one rule")
        item.add_argument("rule", nargs="?", help="a rule id; without one, the master switch")
    add = commands.add_parser("add", help="Add a rule")
    add.add_argument("--event", default=USAGE_HOOK_ANY_EVENT, choices=[USAGE_HOOK_ANY_EVENT, *USAGE_HOOK_EVENTS])
    add.add_argument("--provider", default=None)
    add.add_argument("--threshold", type=float, default=None, help="only when remaining is at or below this percent")
    add.add_argument("--timeout", type=float, default=DEFAULT_USAGE_HOOK_TIMEOUT_SECONDS)
    add.add_argument("--id", dest="rule_id", default=None)
    add.add_argument("executable", help="an absolute path; it runs directly, never through a shell")
    add.add_argument("arguments", nargs=argparse.REMAINDER)
    remove = commands.add_parser("remove", help="Remove a rule")
    remove.add_argument("rule")
    test = commands.add_parser("test", help="Run the matching rules once with a made-up event")
    test.add_argument("event", choices=USAGE_HOOK_EVENTS)
    test.add_argument("--provider", default="claude")
    test.add_argument("--rule", default=None)
    test.add_argument("--json", action="store_true")
    return parser


def _render_list(document: dict[str, Any]) -> str:
    lines = [f"Usage hooks: {'on' if document['enabled'] else 'off'}"]
    if document.get("problem"):
        lines.append(f"  ! {document['problem']}")
    if not document["rules"]:
        lines.append("  no rules (add one with: jrbar usage-hooks add --event quota_low /path/to/script)")
    for rule in document["rules"]:
        scope = rule["event"] if rule["event"] != USAGE_HOOK_ANY_EVENT else "every event"
        if rule.get("provider"):
            scope += f" · {rule['provider']}"
        if rule.get("threshold_remaining") is not None:
            scope += f" · at or below {rule['threshold_remaining']:g}% left"
        state = "on" if rule["enabled"] else "off"
        lines.append(f"  {rule['id']:<12} {state:<4} {scope}")
        command = " ".join([rule["executable"], *rule["arguments"]])
        style = " (first-version argv)" if rule["argv"] == "legacy" else ""
        lines.append(f"      runs {command}{style}, stops after {rule['timeout_seconds']:g} s")
        if rule.get("problem"):
            lines.append(f"      ! will not run: {rule['problem']}")
        last = rule.get("last_result")
        if last:
            lines.append(f"      last: {last['sentence']}")
    return "\n".join(lines)


def main(argv: list[str] | None = None, *, stdout: TextIO = sys.stdout, stderr: TextIO = sys.stderr) -> int:
    options = build_parser().parse_args(argv)
    store = _Store()
    hooks = store.load()
    if options.command == "list":
        document = status_document(load_usage_hook_config(hooks))
        if not store.via_core:
            document["note"] = "the monitor is not running; last results are only kept while it runs"
        if options.json:
            print(json.dumps(document, indent=2, sort_keys=True), file=stdout)
        else:
            print(_render_list(document), file=stdout)
        return 0
    if options.command in ("enable", "disable"):
        value = options.command == "enable"
        if options.rule is None:
            hooks["enabled"] = value
        else:
            matched = [rule for rule in hooks["rules"] if rule["id"] == options.rule]
            if not matched:
                print(f"no usage hook rule {options.rule!r}", file=stderr)
                return 1
            matched[0]["enabled"] = value
        store.save(hooks)
        target = "usage hooks" if options.rule is None else f"rule {options.rule}"
        print(f"{target} {'on' if value else 'off'}", file=stdout)
        return 0
    if options.command == "add":
        if not os.path.isabs(options.executable):
            print("the executable must be an absolute path (hooks never run through a shell)", file=stderr)
            return 2
        if len(hooks["rules"]) >= MAX_RULES:
            print(f"at most {MAX_RULES} rules", file=stderr)
            return 2
        taken = {rule["id"] for rule in hooks["rules"]}
        rule_id = options.rule_id or next(
            f"rule-{index}" for index in range(1, MAX_RULES + 2) if f"rule-{index}" not in taken
        )
        if rule_id in taken:
            print(f"a rule {rule_id!r} already exists", file=stderr)
            return 2
        arguments = [item for item in options.arguments if item != "--"]
        hooks["rules"].append(
            {
                "id": rule_id,
                "enabled": True,
                "event": options.event,
                "provider": options.provider,
                "threshold_remaining": options.threshold,
                "executable": options.executable,
                "arguments": arguments,
                "timeout_seconds": options.timeout,
                "argv": "json",
            }
        )
        store.save(hooks)
        problem = rule_problem(UsageHookRule.from_dict(normalize_usage_hooks(hooks)["rules"][-1]))
        print(f"added rule {rule_id}" + ("" if hooks["enabled"] else " (usage hooks are off: jrbar usage-hooks enable)"), file=stdout)
        if problem:
            print(f"  ! it will not run: {problem}", file=stderr)
        return 0
    if options.command == "remove":
        kept = [rule for rule in hooks["rules"] if rule["id"] != options.rule]
        if len(kept) == len(hooks["rules"]):
            print(f"no usage hook rule {options.rule!r}", file=stderr)
            return 1
        hooks["rules"] = kept
        store.save(hooks)
        print(f"removed rule {options.rule}", file=stdout)
        return 0
    # test
    config = load_usage_hook_config(hooks)
    try:
        outcomes = run_test(config, event_name=options.event, provider_id=options.provider, rule_id=options.rule)
    except ValueError as error:
        print(str(error), file=stderr)
        return 1
    if options.json:
        print(json.dumps([result.to_dict() for result in outcomes], indent=2, sort_keys=True), file=stdout)
    elif not outcomes:
        print(f"no rule matches {options.event} for {options.provider}", file=stdout)
    else:
        for result in outcomes:
            print(f"{result.rule_id}: {result.sentence()}", file=stdout)
        if not config.enabled:
            print("(usage hooks are off, so real events do not run these yet)", file=stdout)
    return 0 if all(result.outcome == "ok" for result in outcomes) else 1


__all__ = [
    "core_status_command",
    "core_test_command",
    "main",
    "run_test",
    "status_document",
]
