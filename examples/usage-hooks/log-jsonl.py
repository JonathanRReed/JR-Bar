#!/usr/bin/env python3
"""A JR-Bar usage hook that appends every event to a JSON Lines file.

    jrbar usage-hooks add "$PWD/examples/usage-hooks/log-jsonl.py" ~/usage-events.jsonl
    jrbar usage-hooks enable

The event arrives on stdin as one JSON object ({"v": 1, "event": ..., "provider":
..., "remaining_percent": ..., "reset_at": ...}, sorted keys, no account labels).
The file is the first argument, ~/.local/state/jrbar-usage-events.jsonl by default.
Local only: nothing is sent anywhere.
"""

import json
import sys
from pathlib import Path

target = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path.home() / ".local/state/jrbar-usage-events.jsonl"
event = json.loads(sys.stdin.read() or "{}")
target.parent.mkdir(parents=True, exist_ok=True)
with target.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(event, sort_keys=True) + "\n")
