# Examples

Small, local-only things built on JR-Bar's public surfaces. Each prints
numbers and words, never a meter made of block characters.

| file | what it is | uses |
| --- | --- | --- |
| [`usage-hooks/notify.sh`](usage-hooks/notify.sh) | a usage hook that shows a macOS notification | [usage hooks](../docs/user/usage-hooks.md), `JRBAR_*` variables |
| [`usage-hooks/log-jsonl.py`](usage-hooks/log-jsonl.py) | a usage hook that appends each event's JSON to a file | [usage hooks](../docs/user/usage-hooks.md), JSON on stdin |
| [`xbar/jrbar.30s.sh`](xbar/jrbar.30s.sh) | an xbar / SwiftBar plugin: agents in the title, quota underneath | [`jrbar serve`](../docs/user/scripts-and-status.md) |
| [`raycast/jrbar-status.sh`](raycast/jrbar-status.sh) | a Raycast script command that prints `jrbar status` and `jrbar usage` | [the command line](../docs/user/cli.md) |
| [`audio_monitor.py`](audio_monitor.py) | a microphone-level monitor from an earlier wave | — |
