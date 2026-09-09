"""Entry point for the self-contained macOS SidePulse application."""

import sys

from jrbar.cli_entry import jrbar_main


def main() -> int:
    if len(sys.argv) > 1:
        return jrbar_main()
    from jrbar.provider_usage_status_bar import main as status_bar_main

    return status_bar_main()

if __name__ == "__main__":
    # Finder launches the app without arguments. The same executable is exposed
    # as /usr/local/bin/sidepulse by the installer for command-line use.
    raise SystemExit(main())
