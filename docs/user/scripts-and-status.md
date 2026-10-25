# Scripts, status bars and launchers

JR-Bar has three surfaces that other tools can read. All three are local
only.

## `jrbar serve`: a status endpoint

Turn on **Settings › Remote › Serve status**. The daemon then serves
`http://127.0.0.1:8737/status.json`:

- agent counts (working, waiting, failed) for your main sessions; sub-agents
  are a number of their own under `agents.workers`, so a sub-agent waiting on
  its own prompt never moves the waiting count;
- each provider's quota, redacted: no account names, no tokens;
- the timestamps that say how fresh each number is.

Every request needs the bearer token from
`~/.local/state/jrbar/serve-token`:

```sh
curl -s -H "Authorization: Bearer $(cat ~/.local/state/jrbar/serve-token)" \
    http://127.0.0.1:8737/status.json
```

The endpoint listens on loopback only and is read-only. The app also serves
`GET /asks.json` and `POST /answer` for a Stream Deck key, but they answer
only while their own switch, `serve_answer_enabled`, is on. It is off by
default and separate from Serve status (`jrbar set serve_answer_enabled
true` turns it on). Both routes need the token, and an answer is a press by
a person, never a rule. A Stream Deck "API request" key and the xbar example below
are built on this endpoint.

### Running it by hand

`jrbar serve` also runs on its own, outside the app:

```sh
JRBAR_SERVE_ACCESS_TOKEN=<24 or more characters> jrbar serve --port 8737
```

It refuses to start without that token, unless you pass
`--allow-anonymous-status` for a legacy client that cannot send one. `--port`
takes 0 to 65535 and defaults to 8737; a taken port is named with an exit of
1. `--allow-answers` adds the two answering routes above, reaching the
running monitor over its socket, and they still act only while
`serve_answer_enabled` is on and never without the token. If the monitor is
unreachable or consent is off, serve prints a warning and keeps serving
status. Each answering request checks consent again and refuses while it
is off.

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
