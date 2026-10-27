#!/usr/bin/env python3
"""Run a notary command within the shared monotonic deadline."""

import subprocess
import sys
import time


def run(deadline, command):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        print("Notarization deadline reached; inspect the retained submission receipts.", file=sys.stderr)
        return 124
    try:
        result = subprocess.run(command, timeout=remaining, check=False)
    except subprocess.TimeoutExpired:
        print("Notarization deadline reached; inspect the retained submission receipts.", file=sys.stderr)
        return 124
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == "__main__":
    raise SystemExit(run(float(sys.argv[1]), sys.argv[2:]))
