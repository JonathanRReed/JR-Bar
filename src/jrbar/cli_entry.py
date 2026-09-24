"""Public JR-Bar CLI router."""

from __future__ import annotations

import sys

from .cli import jrbar_main as _legacy_jrbar_main
from .integration_cli import main as integration_main
from .provider_usage_cli_router import main as provider_main


def jrbar_main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args[:1] == ["integrations"]:
        return integration_main(args[1:])
    if args[:1] == ["providers"]:
        return provider_main(args[1:])
    if args[:1] == ["agent-monitor"] and args[2:3] == ["claude-statusline"]:
        from .claude_statusline_source import main as statusline_main

        return statusline_main(args[1:])
    if args[:2] == ["agent-monitor", "uninstall"] and _uninstalls_claude(args[2:]):
        # Claude's hooks and its status line go together: the uninstaller
        # runs `uninstall all` before it deletes the app the line points at.
        code = _legacy_jrbar_main(args)
        from .claude_statusline_source import uninstall_with_claude_hooks

        return uninstall_with_claude_hooks(dry_run="--dry-run" in args) or code
    if args[:1] == ["usage"]:
        from .usage_cli import main as usage_main

        return usage_main(args[1:])
    if args[:1] == ["usage-hooks"]:
        from .usage_hooks_cli import main as usage_hooks_main

        return usage_hooks_main(args[1:])
    # The control verbs drive the running monitor and app (status, quiet,
    # snooze, set, get over core.sock; toggle, awake, open as jrbar://
    # links) -- one small module, loaded only when asked for.
    from .cli_control import VERBS as control_verbs

    if args[:1] and args[0] in control_verbs:
        from .cli_control import main as control_main

        return control_main(args)
    return _legacy_jrbar_main(args)


def _uninstalls_claude(rest: list[str]) -> bool:
    """Whether ``agent-monitor uninstall`` with these arguments removes
    Claude's hooks: ``all`` (also the default) or ``claude``."""
    if "-h" in rest or "--help" in rest:
        return False
    positional = [
        token
        for index, token in enumerate(rest)
        if not token.startswith("-")
        and not (index > 0 and rest[index - 1].startswith("--") and rest[index - 1].endswith("-log"))
    ]
    return (positional[0] if positional else "all") in ("all", "claude")


__all__ = ["jrbar_main"]
