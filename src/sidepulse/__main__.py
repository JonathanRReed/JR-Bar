"""Forwarder kept for ``python -m sidepulse``; the CLI now lives in ``jrbar``."""

from jrbar.cli_entry import jrbar_main

if __name__ == "__main__":
    raise SystemExit(jrbar_main())
