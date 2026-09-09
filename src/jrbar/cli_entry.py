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
    # The source-checkout LaunchAgent and `jrbar status-bar --foreground`
    # both enter through this router. Load the native provider wrapper before
    # starting AppKit so the menu, Usage Center, reset cues, and background
    # accounting service are present in development as well as packaged runs.
    if args[:1] == ["status-bar"] and "--foreground" in args:
        from .provider_usage_status_bar import main as status_bar_main

        return status_bar_main()
    return _legacy_jrbar_main(args)


__all__ = ["jrbar_main"]
