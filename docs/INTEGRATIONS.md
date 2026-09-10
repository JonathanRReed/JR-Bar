# Integrations

Neighbours JR-Bar reads from without ever writing to them. Providers (the
agents whose hooks JR-Bar installs) are a different thing:
[NATIVE-PROVIDERS.md](NATIVE-PROVIDERS.md). Compatibility windows for
everything here are in [COMPATIBILITY.md](COMPATIBILITY.md).

## T3 Code

JR-Bar projects T3 Code's local threads into its own session list, read
only, off by default, configured outside the main settings document. The
commands run through the bundled binary:

```sh
alias jrbar='~/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core'
jrbar integrations status            # configuration and the packaged compatibility window
jrbar integrations status --json
jrbar integrations enable t3code
jrbar integrations disable t3code
jrbar integrations probe t3code      # a bounded compatibility probe
jrbar integrations probe t3code --json
```

The daemon reads `integrations.json` on its next refresh; if a change does
not show up, quit and relaunch JR-Bar (the app restarts its daemon). A
source checkout has the same commands as `.venv/bin/jrbar integrations …`
and `jrbar-integrations …`.

### What is read

From `userdata/state.sqlite` under `~/.t3` (override with
`jrbar integrations configure t3code --base-dir <dir>`; clear with
`--clear-base-dir`): project and thread ids and titles, the underlying
provider and instance, the provider thread id when present, model and
reasoning effort, runtime and interaction mode, branch and worktree path,
the active or latest turn, session status and failure presence, pending
approval / user-input / actionable-plan flags, and the
`t3code://threads/<environment>/<thread>` deep link when an environment id
is configured (`--environment-id local`, `--clear-environment-id`).

A T3 approval, input request or actionable plan becomes a waiting session;
running and starting sessions are working; a session error is failed;
ready, idle and stopped turns are completed or idle according to the turn
facts. T3 sessions keep their own identity beside native ones and are never
merged with a provider's hook-fed session for the same thread.

### Safety

The database is opened with SQLite URI `mode=ro`, `PRAGMA query_only`, a
short busy timeout, a check of the required tables and columns, and a cap
of 512 active, non-archived threads. JR-Bar never writes the database,
never runs T3 commands, never reads T3 credentials, never changes a thread
and never dispatches a provider action through T3. Additive columns are
accepted; a missing required column fails closed as unsupported. A failed
or busy refresh keeps the previous snapshot and marks its rows stale. T3
exposes no pull-request metadata in its projection, so JR-Bar claims none.

### Files

Settings: `${XDG_CONFIG_HOME:-~/.config}/jrbar/integrations.json`, a
versioned document that preserves unknown fields, refuses concurrent
replacement, becomes read-only when written by a newer JR-Bar, and is
preserved rather than replaced when malformed. The packaged compatibility
manifest is `jrbar/resources/integration_compatibility.json` (reviewed
upstream commit, protocol fingerprint, minimum and maximum tested
versions, fixture version, connection mode); `jrbar integrations status
--json` prints it.

| Integration | Minimum | Maximum tested | Mode |
| --- | ---: | ---: | --- |
| T3 Code | 0.0.33 | 0.0.33 | `sqlite-readonly-v1` |

## Alcove

When [Alcove](https://henrikruscon.com/alcove) is running, the Screen Bar
matches the width of its capsule so an expanded live activity never
outgrows the band (Settings › General › Follow Alcove, on by default). The
daemon reads the capsule from the window list, which needs Screen
Recording permission; without it, or without Alcove, the band keeps the
measured notch geometry. Nothing is sent to Alcove.

## Tailscale and SSH

Remote peers (Settings › Remote) list other Macs running JR-Bar. Tailscale
is used only to discover them; the ledger itself is fetched with `sftp`
over SSH and nothing else is ever run on the peer. Usage sync between Macs
is HMAC-SHA256-signed JSON over the same SSH. Both are off by default and
read-only; see `remote_peers.py` for the five rules the transport keeps.

## Scripts and Stream Deck

`jrbar serve` answers `GET /status.json` on loopback with redacted agent
aggregates and provider quota summaries, for scripts and things like a
Stream Deck. `jrbar --help` lists the rest of the command line.
