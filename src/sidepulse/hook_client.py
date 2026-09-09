"""Forwarder kept for hooks registered as ``python -m sidepulse.hook_client``."""

from jrbar.hook_client import main

if __name__ == "__main__":
    raise SystemExit(main())
