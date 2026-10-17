# Integrations

JR-Bar integrates with T3 Code and Alcove only. Provider accounting is
native. CodexBar is a reference, never required at runtime.

Neighbours JR-Bar reads from without ever writing to them. Providers (the
agents whose hooks JR-Bar installs) are a different thing:
[NATIVE-PROVIDERS.md](NATIVE-PROVIDERS.md). Compatibility windows for
everything here are in [COMPATIBILITY.md](COMPATIBILITY.md).

## T3 Code

Pending internal tool calls and authentication refreshes do not ask for your
approval. Actual approval and user-input requests remain visible in T3 Code.
A freshly read database is not proof that an old running turn is still alive;
JR-Bar keeps its original activity time and existing freshness rules.

JR-Bar projects T3 Code's local threads into its own session list, read
only, off by default, configured outside the main settings document. The
switch is **Read T3 Code** on the T3 Code row in Settings › Agents & Usage ›
Providers, which shows once T3's database is on this Mac. With the command
line installed ([install](user/install.md#the-command-line)), the same
control is:

```sh
jrbar integrations status            # configuration and the packaged compatibility window
jrbar integrations status --json
jrbar integrations enable t3code
jrbar integrations disable t3code
jrbar integrations probe t3code      # a bounded compatibility probe
jrbar integrations probe t3code --json
```

Without the link, run the bundled binary:

```sh
alias jrbar='~/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core'
```

The daemon reads `integrations.json` on its next refresh; if a change does
not show up, quit and relaunch JR-Bar (the app restarts its daemon). A
source checkout has the same commands as `.venv/bin/jrbar integrations …`
and `jrbar-integrations …`. The same file also holds the Creator Micro
pad's approval (`creator-micro` is accepted by `enable`, `disable` and
`status`); set the pad up from the app, since it needs the device's serial.

### What is read

From `userdata/statev2.sqlite` or `userdata/state.sqlite` under `~/.t3`
(override with `jrbar integrations configure t3code --base-dir <dir>`; clear
with `--clear-base-dir`; `T3CODE_HOME` moves the default): project and thread
ids and titles, the underlying
provider and instance, the provider thread id when present, model and
reasoning effort, runtime and interaction mode, branch and worktree path,
the active or latest turn, session status and failure presence, pending
approval / user-input / actionable-plan flags, and the
`t3code://threads/<environment>/<thread>` deep link when an environment id
is configured (`--environment-id local`, `--clear-environment-id`).
`jrbar integrations configure t3code --activity-statistics` also adds
bounded task-completion counts to the usage history; it is off until you
turn it on (`--no-activity-statistics` turns it off again).

Which file is live: a 0.0.46 nightly keeps its threads, runs, requests and
plans in `statev2.sqlite` (T3's orchestrator v2) and leaves `state.sqlite` as
a frozen copy, while stable 0.0.45 still writes `state.sqlite`. The one that
changed last, counting its write-ahead log, is read, so going back from the
nightly to stable reads the right file. In the v2 file a run is the unit of
work: a preparing, starting, running or waiting run is working; the latest
run that is not a held queued follow-up says completed, failed or interrupted;
a pending command, file or permission request is an approval and a pending
`user_input` request is an input request; an active proposed plan is a plan.
Provider-native subagent threads are not listed.

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
or busy refresh keeps the previous snapshot and marks its rows stale. T3's
0.0.46 threads do carry linked pull requests in their payload, but JR-Bar
reads none of it and claims no pull-request metadata.

The observer preserves T3's event timestamps. A successful database read
or a live T3 server process does not prove that a provider still owns a
turn. A quiet, long-running turn can therefore become stale until T3
publishes another event. Fresh runtime ownership needs an independent
thread-specific source; the SQLite observer does not invent it.

### Files

Settings: `${XDG_CONFIG_HOME:-~/.config}/jrbar/integrations.json`, a
versioned document that preserves unknown fields, refuses concurrent
replacement, becomes read-only when written by a newer JR-Bar, and is
preserved rather than replaced when malformed. The packaged compatibility
manifest is `jrbar/resources/integration_compatibility.json` (reviewed
upstream commit, protocol fingerprint, minimum and maximum tested
versions, fixture version, connection mode); `jrbar integrations status
--json` prints the version window and connection mode from it.

| Integration | Minimum | Maximum tested | Mode |
| --- | ---: | ---: | --- |
| T3 Code | 0.0.33 | 0.0.46 | `sqlite-readonly-v1` |

Re-pinned 2026-10-07: T3 Code Nightly 0.0.46 (source `611132c1`) moved live
threads to `statev2.sqlite` (upstream `de343914`, #2829) and froze the
`projection_*` tables in `state.sqlite`. JR-Bar read only the frozen file, so
its T3 list on a nightly install was days old and a stale actionable plan
stayed "Plan ready". The reader now prefers the v2 file when it is the fresher
one (`tests/test_t3_v2_compat.py`, fixture version 4), and the optional
activity statistics read each finished provider turn's token usage from it.
Migrations 054 to 058 only add tables or drop indexes. A read-only run of the
reader against the owner's `0.0.46-nightly.20261006.2752` data found every
required column in both files and 26 live threads.

Re-pinned 2026-09-24: T3 Code Nightly 0.0.43 (source `cb1a3f34`) adds
migrations 050-053 (`projection_thread_pull_requests`,
`projection_thread_messages.context_json`, `projection_threads.title_state_json`
and `pull_request_files_viewed`). All four only add, and a read-only probe of
the owner's 0.0.43 database found every column JR-Bar reads, so the
projection is unchanged. `tests/test_t3_compat.py` keeps a 0.0.43-shaped
schema (fixture version 3).

## Alcove

When [Alcove](https://henrikruscon.com/alcove) is running, the Screen Bar
matches the width of its capsule so an expanded live activity never
outgrows the band (Settings › Devices & Lighting › Screen Bar › Follow Alcove,
on by default). The
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

Inside the app the same endpoint is the **Serve status** switch (Settings
› Remote, mirrored on the Devices & Lighting page's Stream Deck card):
`GET http://127.0.0.1:8737/status.json` with
`Authorization: Bearer <token>`, the token at
`~/.local/state/jrbar/serve-token` (0600) — the card's Copy token button
hands it over. JR-Bar ships no Stream Deck plugin; an "API request" key
with that header does the job.
