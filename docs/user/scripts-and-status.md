# Scripts, status bars and launchers

JR-Bar has three surfaces that other tools can read. All three are local
only.

## `jrbar serve`: a status endpoint

Turn on **Settings › Remote › Serve status**. The daemon then serves
`http://127.0.0.1:8737/status.json`:

- agent counts (working, waiting, failed);
- each provider's quota, redacted: no account names, no tokens;
- the timestamps that say how fresh each number is.

Every request needs the bearer token from
`~/.local/state/jrbar/serve-token`:

```sh
curl -s -H "Authorization: Bearer $(cat ~/.local/state/jrbar/serve-token)" \
    http://127.0.0.1:8737/status.json
```

The endpoint listens on loopback only and is read-only. The routes that
answer an ask exist only while their own switch is on; that switch is off
by default. Stream Deck support and the xbar example below are built on
this endpoint.

## The command line

`jrbar status --json` and `jrbar usage --json` print the same facts for a
script that runs on this Mac. `jrbar usage` exits 1 when a provider is in
error. See [the command line](cli.md).

## Usage hooks

JR-Bar can run your program when a quota runs low or resets. See
[usage hooks](usage-hooks.md).

## Examples

[`examples/`](../../examples/README.md) has small, working starting
points. Each prints numbers and words, never a bar made of block
characters.

- `examples/xbar/jrbar.30s.sh` is an [xbar](https://xbarapp.com) or
  [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin. It puts agent
  counts in the title and each provider's quota in the menu.
- `examples/raycast/jrbar-status.sh` is a Raycast script command that
  prints `jrbar status` and `jrbar usage`.
- `examples/usage-hooks/notify.sh` is a usage hook that shows a macOS
  notification.
- `examples/usage-hooks/log-jsonl.py` is a usage hook that appends each
  event to a JSONL file.
