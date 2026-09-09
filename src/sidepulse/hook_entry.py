"""Forwarder kept for hooks registered as ``python -m sidepulse.hook_entry``."""

from jrbar.hook_entry import main

if __name__ == "__main__":
    raise SystemExit(main())
