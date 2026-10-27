# JR-Bar core protocol (protocol 1)

The native app (`JR-Bar.app`, Swift) owns every pixel. The core daemon
(`python -m jrbar core`, the production controller run headless) owns every
fact: provider hooks, session truth, usage and quota, device writers,
escalation decisions, power holds, remote peers, cloud ingest. They talk
over one Unix socket.

This document is the contract, written to what the daemon does today.
Both sides are tested against it: `tests/test_core_server.py`,
`tests/test_core_projection.py`, `tests/test_core_runtime.py` on the
Python side, and `tests/test_core_protocol_doc_contract.py`, which fails
when the daemon answers a command this file never names;
`app/Tests/JRBarCoreTests` on the Swift side, including
`Fixtures/python-state.json`, a `state` frame produced by the Python
projection (`JRBAR_UPDATE_FIXTURES=1 pytest tests/test_core_projection.py`
regenerates it) and decoded back by
`app/Tests/JRBarCoreTests/PythonProjectionFixtureTests.swift`. Every shape
the two sides could disagree about belongs in that fixture -- a usage
window with no reading (`used_pct: null`) is there for exactly that reason
-- so the agreement is by construction rather than by two independently
hand-written examples.

## Transport

- Socket: `$XDG_STATE_HOME/jrbar/core.sock` (default
  `~/.local/state/jrbar/core.sock`), mode 0600, parent directory 0700,
  peer UID checked (`getpeereid`); a foreign UID is closed without a byte.
- Framing: newline-delimited JSON (one object per line, UTF-8, `ensure_ascii`
  on the daemon side so no raw newline ever appears). Max frame 1 MiB in
  both directions: an oversize outbound frame is dropped and counted, an
  oversize inbound frame closes that client. A `reply` obeys the same
  limit, but the command it answers must not be left waiting for a frame
  that never arrives, so an oversize reply is replaced by
  `{"ok":false,"error":{"code":"frame_too_large","message":…}}` with the
  command's own `id` (counted with the other oversize drops). The app
  treats a `state` frame it cannot use (over the limit on its side, not
  decodable, or of another protocol `v`) as "not current": the model is not
  live, the status item's tooltip and the panel say the update could not be
  read, and the next good `state` frame clears it.
- Numbers: a number that is not finite (NaN, `+Infinity`, `-Infinity`) is
  never written as a bare token, which is not JSON and would cost the app
  the whole frame. The daemon writes `null` in its place, in every frame
  kind and at any depth, and counts the frame (`sanitized_frames`). `null`
  already means "no reading" wherever the protocol allows it
  (`used_pct: null`), so a consumer needs no new case. The app's decoder
  also reads the quoted strings `"inf"`, `"-inf"` and `"nan"`, but the
  daemon never sends them: the app turns some of these doubles into an
  `Int`, which traps on an infinity, and `null` cannot. A frame that cannot
  be written at all (an object JSON has no form for) is dropped and counted
  (`dropped_unencodable`), and the connection carries on. A reply whose
  result cannot be written is sent with the result's text (`{"repr": ...}`)
  instead; only a reply with nothing writable in it is dropped.
- Clients: up to 4 at once; the fifth is refused. A connection is `unauthenticated` until it proves it is the JR-Bar app (see "Who may send what"); the peer's pid is recorded in the daemon's log lines about it.
- Lifecycle: the app launches the daemon as a child when `JRBAR_CORE_EXEC`
  is set (`CoreSupervisor`), otherwise it connects to whatever listens.
  The daemon refuses to start (exit 2) while another JR-Bar, the old
  Python status bar included, owns the hook event socket. A supervised
  daemon (`JRBAR_SUPERVISED=1`) exits on its own when its parent is gone, and
  is handed a new app secret on its stdin at every start (see "Who may send
  what"). When the app finds that the daemon on the socket will not take its
  proof it restarts the daemon it supervises once, and otherwise logs why and
  shows the same words on a refused change.
  On connect the daemon sends `hello`, then the latest full `state`,
  `lights` and `settings`. Frames published while that greeting is being
  sent are held and follow it, in order: `hello` is always the first frame,
  and a live frame never lands ahead of an older snapshot of its own kind.
  After that it pushes documents as they change.
  When the daemon terminates (`quit`, SIGTERM, its supervisor gone) it
  writes `off` to every mounted strip, Pro and Dot alike, straight to
  each volume after the legacy teardown, past the controllers' dedupe
  and resting glow, so a quit never leaves a strip looping.
  If the socket drops, the app restarts the daemon and reconnects with
  backoff (0.5 s, 1 s, 2 s, 4 s, cap 5 s); on the same event `stream`
  the client replays the missed journal suffix (`replay_events`) so a
  drop costs no events the journal still retains.
- Every message has `"t"` (type) and `"v": 1`.
- Coalescing: `state` at most 20/s, `lights` 30/s, `settings` 10/s, latest
  wins. `event`, `reply` and `log` are never coalesced; the bounded
  dispatch queue (128 frames) sheds its OLDEST frames on overflow and a
  client whose send blocks past the send deadline (1 s) is dropped at once:
  a timed-out send may have put half a frame on the wire, so the stream
  cannot be repaired. The client recovers by reconnecting and replaying,
  because events stay replayable from the journal (512 entries, larger than
  the queue on purpose) until it evicts them, after which `replay_events`
  says so (`cursor_expired`, with the `dropped` count) instead of
  pretending.

## Agent groups

`state.agent_groups` is an additive array. Each entry has `id`,
`root_work_key`, `root_provider`, `members` and `lineage_evidence`.
Work keys here are provider-qualified session or worker IDs, the same IDs
as `state.sessions[].id`. `members` includes the root. The stable group ID
is `group:<root_work_key>`. A root with no children is a one-member group.

Each evidence entry has `child`, `parent`, `harness` and `observed_at`, a
Unix timestamp. Links come from explicit delegation fields, never project
folders or process ancestry. The daemon follows links transitively and
rejects cycles, conflicting parents, ambiguous native bindings, missing
parents and expired evidence. Copied history, including Codex
`forked_from_id`, does not establish delegation. Local readers recover links
after restart. Re-reading an unchanged hook does not renew its timestamp.
A row keeps its own native work-to-parent relationship for its lifetime.
External evidence expires after 24 hours and allows five seconds of clock skew.

Each session also has `group_id` and `unlinked_worker`. A worker without a
provable root has no group and sets `unlinked_worker: true`. The panel can
dim it and name it "Unlinked worker". It gets no strip share unless it has
an actionable ask. An unlinked worker always shows its ask, even when
sub-agent asks are off. That preference applies only to linked workers.
Resolved child sessions have `kind: "worker"` and `parent` set to the root
session ID, including children whose provider differs from their root.
Quota pace counts every non-stale local session under its own provider, including
workers in another provider's group. Optional `quota_working: false` marks a root
whose working state only summarizes its workers. It does not spend its own
provider's quota. When absent, quota readers use the session's activity and
staleness. Group counts and light shares still count the root once.

The root's `workers` counts its live workers, excluding stale members. Asks keep their own
session IDs and remain individually answerable. The group root shows the
most urgent member state and shows Working while any member works, even
when the root itself is stale or finished. Dismissing the root still hides
that session. Local root headers supply link evidence
only, never roster activity.

T3 Code detection runs without a provider toggle. The daemon reads its data
only while the desktop app or a CLI server holds the same database, and its
database, WAL or settings change, with a reconciliation every 3 minutes.
Absent databases are checked every 60 seconds without process scans. Stopped
hosts with a database are checked at most every 30 seconds. Active reads coalesce for 4 seconds;
idle reads coalesce for 12 seconds. Finished workers remain for 10 minutes;
active workers remain until their run settles. Failed reads retry on the next eligible tick.
Existing settings still supply custom paths, environment and statistics consent.

Lights use one representative per group in `root_provider`'s colour.
The Python entry point is `active_agent_groups(state)`, where `state` is a
monitor snapshot or attention projection. It returns immutable groups.
Adapters emit `ParentLink(child, parent, harness, observed_at)` values to
`resolve_agent_groups(statuses, links, now=...)`. A new adapter needs no
resolver changes. It must preserve ambiguous evidence rather than choose
one binding, bound its reads, and emit only provider-qualified IDs.

Normalized hook logs may include `parent_links`, a list of at most four
`ParentLink` objects with provider-qualified child and parent IDs, a provider
name in `harness`, and a finite `observed_at` epoch. A null parent records a
known worker whose parent is missing. Replay preserves the original timestamp.
These records contain identities only, never prompts or tool output. Raw hook
payloads cannot supply this extension. Malformed raw lineage fields do not
drop the event. A live Grok worker renews its link timestamp on each event;
reading a saved record never renews it.

Hermes normalized records may also include `identity_aliases`, up to two
`[subagent_id, session_id]` pairs explicitly named together by a hook.
They reconcile hook worker IDs with the session database after restart.
An unresolved subagent alias cannot override a database session parent.
Local lineage evidence augments observed sessions and creates no activity rows.

## Provider identities

Provider IDs use the explicit alias table in `src/jrbar/provider_ids.py`.
Hooks, transcripts and T3 publish canonical IDs such as `claude`, `codex`
and `factory`. The app uses the generated `ProviderID` table as a fallback
for older daemons. Marks, colours and names use that same identity.
Custom instance labels and model names do not establish a provider.
ACP registry instances use their configured agent ID. Unknown IDs keep
a neutral question mark.

## Failure signals

A failed run keeps `lifecycle: "failed"` in the panel until cleared or newer
activity resumes it. A new turn, tool activity or T3 running state clears
the failure immediately. An ended session no longer signals failure.
Its `failure_signal_until` is a Unix timestamp five seconds after the
failure, or null when it has no signal. Only a fresh top-level failure
signals. Workers, including unlinked workers, never drive failure colours,
counts, notices, banners or sounds. Their failed marks stay inside their
group or dim unlinked row.

The notch, Screen Bar, menu bar dots, LEDs and Stream Deck stop signalling at that
deadline. `aggregate.failed` counts current failure signals, not retained
failed rows. The failure notice names the provider and project and lasts
five seconds. Asks still take priority. Replayed expired failures stay quiet.
T3 uses the failed run's own timestamp. Thread edits, settlement and held
follow-ups cannot renew its signal. Cancellation, interruption and a delegated task stopped by capacity or
transport errors read as `ended`, without a failure signal.

T3 children without a native provider binding keep a stable T3-qualified
identity and their explicit parent link. An absent binding is not an
ambiguous binding. Settled native children retain identity-only lineage
for 24 hours, independently of the ten-minute worker activity window.

## Who may send what

Any process running as you can open `core.sock`: the daemon checks the peer's
uid, and that is all the kernel can tell it. A prompt-injected agent, or
anything an agent runs, is such a process. So the socket does not trust the
user; it trusts the app.

### The app secret

- When `JR-Bar.app` starts the daemon (`CoreSupervisor`) it makes 32 random
  bytes for that launch and hands them over the daemon's **stdin**, a pipe
  that exists only for that child, with `JRBAR_AUTH_STDIN=1` in its
  environment to say so. The secret is in no environment variable and no
  argument, so `ps`, a hook child and a provider CLI the daemon starts never
  see it. The daemon reads exactly 32 bytes from a pipe once at startup,
  then points its stdin at `/dev/null` and removes the variable. The app and
  the daemon each keep the secret in memory only. Every start of the daemon,
  including a restart, makes a new secret.
- The same pipe can carry a second 32 bytes, the **seal key** (see "Protected
  settings"). `JRBAR_AUTH_STDIN=1` says the pipe holds the secret alone (32
  bytes), `2` says it holds the secret and then the seal key (64 bytes) of a
  Mac whose protected settings were sealed before, and `3` says the same of a
  key the app only just made, under which nothing is sealed yet. The seal key is
  read from the Keychain item the app created for it and is never written
  anywhere else, so it is not in an argument, an environment variable or a
  file, and unlike the secret it is the same at every start.
- A daemon started any other way (`python -m jrbar core` by hand, a test, a
  LaunchAgent) has no secret. It still serves every unprivileged command
  below; it refuses every privileged one. The one exception is development:
  `JRBAR_DEV_ALLOW_UNAUTH=1` in the daemon's own environment, read once at
  startup, makes it accept privileged commands from any connection. It is
  ignored by the frozen release daemon (`sys.frozen`), and nothing a hook
  payload says can set it.

### The handshake

After `hello` (which carries the nonce, see above) the app sends

```json
{"t":"command","v":1,"id":"c-1","name":"auth","args":{"proof":"<64 hex characters>"}}
```

where `proof` is `HMAC-SHA256(secret, "jrbar-core-auth-v1\n" + nonce)`, with
the nonce as the 32 hex characters the daemon sent. The secret never crosses
the socket. The daemon compares in constant time. The nonce is good for one
attempt: a wrong proof, a repeated nonce or an `auth` on a daemon with no
secret is answered `auth_failed` / `auth_replayed` / `auth_unavailable`, and
a wrong proof also closes the connection after a short delay that grows with
the failures so far (so guessing is slow and no one is locked out). A right
proof answers `{"ok":true,"result":{"authenticated":true}}` and the
connection is authenticated for the rest of its life. The app also checks,
before it sends a proof, that the socket's peer pid is the daemon it started.
Commands on one connection run in order, so the app sends nothing else until
the `auth` reply is in.

### Privilege

Each command is **privileged** (the app's authenticated connection only) or
**open** (any connection). A command that is not in the daemon's table
(`core_auth.COMMAND_PRIVILEGE`) is privileged, and
`tests/test_core_auth.py` fails when a registered command has no row. A
refusal is the error `unauthenticated` with a plain sentence that says the app
has to do it (open JR-Bar and use Settings), is logged without any content
("refused privileged command X from an unauthenticated connection"), and
leaves the connection open.

Open commands: `ping`, `list_commands`, `replay_events`, `doctor`,
`hooks_doctor`, `list_history`, `list_roster`, `list_providers`,
`list_effects`, `list_assignments`, `list_lid_presets`, `list_finish_looks`,
`list_scene_packs`, `list_cues`, `what_plays`, `list_focuses`, `list_light_log`,
`usage_history`, `usage_graph`, `usage_hooks_status`, `session_energy`,
`session_timeline`, `compare_sessions`, `session_usage`, `firmware_status`,
`quiet`, `quiet_lease`, `scene_lease`, `snooze`, `confetti`, `hold_awake`, `release_awake`, `refresh_usage`, `set_brightness`,
and `set_setting` / `reset_settings` for display preferences only. Every
connection also receives the `hello`, `state`, `lights`, `settings`, `event`
and `log` frames, so reading status needs no proof.

A display preference, for `set_setting` and `reset_settings`, is the top-level
setting `global_brightness_scale`, `active_scene`, `colors`, `led_display`,
`idle_dim_enabled`, `idle_dim_after_minutes`, `idle_dim_fraction`,
`sleep_dim_enabled`, `sleep_dim_fraction`, `auto_dim`, `screen_bar_gap_width`,
`screen_bar_wing_length`, `screen_bar_notch_profile`,
`screen_bar_notch_corner`, `screen_bar_notch_wings`,
`screen_bar_bracket_style`, `screen_bar_min_glow`,
`screen_bar_phase_offset_ms`, `screen_bar_gauges_enabled`,
`screen_bar_show_in_full_screen`, `menu_bar_icon_style`, `tips_enabled`,
`usage_graph_days` or `usage_display_mode`, or `devices.<n>.<field>` for
`led_display`, `brightness`, `auto_brightness_enabled`, `red_gain`,
`green_gain`, `blue_gain`, `resting_glow`, `blend_mode`, `provider_pin`,
`signal_policy`, `led_direction` or `dot_travel_style`. Every other setting
path is privileged, in particular the consent, egress and program-bearing
ones: `serve_enabled`, `serve_answer_enabled`, the serve and access tokens,
`escalation_webhook_url`, `webhook_events`, `ntfy_*`, `cloud_ingest_*`, `remote_peers`,
`usage_hooks`, `usage_event_hook_path`, `cliproxy_hub`,
`provider_extra_homes`, `claude_plan_limits_*`, `claude_statusline_source`,
`closed_lid_*`, `global_action_shortcuts`, anything that names a path, and a
setting added after this was written. A `reset_settings` whose `paths` include
any privileged path is privileged.

Privileged commands: everything else. That is every command that answers,
approves, denies or types into an agent (`answer_ask`, `deck_answer`,
`deck_press`, `open_session`, `new_session`, `resume_session`,
`session_in_front`), `serve_token`, `install_hooks`, `uninstall_hooks`,
`refresh_hooks`, `claude_statusline_install`, `claude_statusline_uninstall`,
`usage_hooks_test`, the provider and consent commands (`set_provider_enabled`,
`provider_consent`, `provider_add_instance`, `provider_action`,
`provider_sign_in`, `provider_update`, `provider_update_check`),
`set_closed_lid_policy`, `presence`, `clear_completed`, `undo_clear`,
`dismiss_session`, `mark_history_seen`, `reset_receipt`, `reset_status`, `audit_export`,
`t3code_integration`, `adopt_seal`, `keep_protected_change`, `quit`, the LED,
calibration, effect, scene-pack and cue writers, the SidePulse protection
commands and every `deck_*` command.

### What stays outside the socket

The daemon's own `jrbar serve` server (`serve_answer_enabled`, the bearer
token, the `Host` check) answers an ask through the daemon's in-process
dispatch, not through `core.sock`, so it is not affected by the privilege
table. A standalone `jrbar serve` has no such path and its answers are
refused. The hook shim talks to `hook-ingress.sock`, which carries data and
never a command. A same-user process can still read `serve-token` and
edit `settings.json`, but an edit to a protected setting there changes nothing
(next section); `SECURITY.md` says what that leaves.

### Protected settings

`core.sock` is not the only way into the daemon's settings: the daemon takes an
outside edit of `settings.json` (a restart reads the file, and a save that finds
the file changed takes it). Without more, any process running as you could
switch on `serve_answer_enabled` there, read the serve token and answer an agent
through `jrbar serve`, or set a webhook. So the settings that grant a
capability are **sealed**.

- **The sealed keys** (`jrbar.settings_seal.SEALED_KEYS`; a test fails when a
  setting is added without being sorted into sealed, a display preference or a
  reviewed "privileged but grants nothing" list): `serve_enabled`,
  `serve_answer_enabled`, `escalation_webhook_url`, `webhook_events`,
  `ntfy_enabled`, `ntfy_topic`, `ntfy_only_when_away`, `cloud_ingest_enabled`, `remote_peers`, `usage_hooks`,
  `usage_event_hook_path`, `claude_plan_limits_enabled`,
  `claude_plan_limits_consent_version`, `claude_statusline_source`,
  `provider_status_feeds_enabled`, `provider_update_checks_enabled`,
  `cliproxy_hub`, `provider_extra_homes`, `closed_lid_awake_policy`,
  `closed_lid_grace_minutes`, `global_action_shortcuts` and
  `companion_seals` (the consent files' seals, below). None of them is a
  display preference (`OPEN_SETTING_ROOTS`), so an unauthenticated
  `set_setting` never reaches them either. The serve and cloud-ingest access
  tokens are not settings; they reach the daemon through its environment and the
  token files, and neither opens anything while its switch is off.
- **The seal** is the member `_seal` of `settings.json`:
  `{"v":1,"keys":[…],"mac":"<64 hex>"}`, plus an advisory `notice` (below). `mac`
  is `HMAC-SHA256(seal key, "jrbar-settings-seal-v1\n" + canonical)`, where
  `canonical` is the JSON text (sorted keys, no spaces, ASCII, no NaN) of
  `{"keys": [the covered names], "values": {name: the file's value, for the
  names present}}`. A name in `keys` and missing from `values` is sealed as
  absent. Only the daemon writes it, on a save, from the settings it holds in
  memory: those change only through an authenticated command, so sealing what
  is in memory seals only what the app asked for.
- **The key** is 32 random bytes in a macOS Keychain item the app creates
  (service `com.jonathanreed.jrbar.settings-seal`) with an access control list
  that trusts the app's own code signature alone. A process that is not the app
  gets a prompt or a refusal, not the key. The app hands it to the daemon it
  starts over the stdin pipe above, so it never crosses a socket or a file. The
  daemon needs no round trip to the app to check a file, which also means it can
  check one before any client has connected.
- **A load checks the seal.** On startup, on taking an outside edit and on a
  once-a-second look at the file's size and time, the daemon recomputes the MAC
  over the file. If it matches, the file's values are the daemon's own. If it
  does not (or is missing from a Mac that has sealed before), the file's values
  for the sealed keys are **ignored**: the daemon keeps the values it held, or
  at startup the defaults (all off), and every other setting is taken from the
  file as it always was. The daemon logs `settings.json changed a protected
  setting outside JR-Bar; ignored` once per distinct edit (no values), keeps the
  file it found as `settings.json.rejected` (private, one copy), writes the
  held values back on its next save and puts the names of the keys into
  `settings_seal.changed`.
- **Consent files** (`jrbar.companion_seal`). Three more files hold a
  consent the daemon acts on: `provider-usage.json` (each provider's usage
  consent version, source and time), `browser-consent.json` (browser profiles,
  sites and fields) and `integrations.json` (the integrations switches and the
  folder and device they read). Each has a seal made by the same key: an
  HMAC-SHA256 over `"jrbar-companion-seal-v1\n" + name + "\n" + canonical`, where
  `canonical` is the JSON text of just the consent in that file. The three
  digests are the sealed setting `companion_seals` (`{"provider_usage": hex,
  "browser_consent": hex, "integrations": hex}`), so they change only as a
  protected setting does; a copy of the sealed consent sits beside each file
  as `<file>.sealed`. Every read of one of these files in the daemon goes
  through the check, and every save the daemon makes seals what it wrote. A
  file whose consent does not hash to its seal is read as follows: a change
  that only takes consent away is accepted and sealed; a change that grants
  more is **ignored**, the file is put back from the sealed copy (to nothing
  consented if there is none), what was found is kept as `<file>.rejected`, and
  `settings_seal.changed` names it (`provider_usage_consent`, `browser_consent`
  or `integrations`) with `can_keep` true. `keep_protected_change` takes the
  file's consent and seals it; `adopt_seal` seals the files as they are. A file
  with no seal yet (the first start after an upgrade) is adopted as it is. A
  process with no seal key, such as the `jrbar` command line, reads and writes
  these files as before; while the daemon is sealed, what it grants there is
  ignored until the person keeps it in Settings.
- **No seal key** (a daemon the app did not start, or a Keychain that was
  locked, denied or missing): the daemon behaves as it always did, sealed keys
  included, `settings_seal.state` is `unavailable`, and Settings says so. It
  never blocks startup, and the app asks the Keychain once per launch.
- **`settings_seal`** is a read-only member of the `settings` document (like
  `cloud_ingest_token_path`, so `set_setting` on it replies `read_only`):
  `{"state": "sealed" | "not_sealed" | "unavailable", "changed": null | {"keys":
  [name…], "at": epoch seconds, "can_keep": bool}}`. `not_sealed` is a seal key
  under which nothing was sealed yet; the daemon behaves as `unavailable`
  until `adopt_seal`.
- **`adopt_seal`** (privileged, no arguments) records the settings the daemon
  holds now as the sealed baseline, writes them with a fresh seal, clears
  `changed` (so a foreign edit is kept out) and replies `{"state":"sealed"}`. The app
  sends it after it authenticates when the daemon says `not_sealed` (the
  first launch of a build with protection, or a new key) and from Settings >
  General > Advanced > Protected settings. A fresh install seals its defaults the same way.
- **`keep_protected_change`** (privileged, no arguments) takes the values the
  daemon ignored (while it still holds them, otherwise `settings.json.rejected`
  in the same folder), validates them like any `set_setting`, applies them,
  seals them and replies `{"state":"sealed","kept":[name…]}`. It is the
  banner's "Keep the change", the one way a hand edit of a protected setting
  takes effect. With nothing to keep it replies `nothing_to_keep`.

## Daemon → app

### hello
```json
{"t":"hello","v":1,"core_version":"0.9.16","pid":123,
 "capabilities":["sessions","lights","usage","devices","power","effects","calibration","history","peers","ingest","deck","roster","event_replay"],
 "stream":"1234-abc123","cursor":"1234-abc123:ev-42"}
```
When this daemon holds an app secret (it was started by the JR-Bar app, see
"Who may send what"), `hello` also carries `"auth":{"scheme":"hmac-sha256",
"nonce":"<32 hex characters>"}`: a fresh random nonce for this connection
only. A daemon with no secret sends no `auth` member. The app answers it with
the `auth` command before any other command.

`stream` identifies this daemon incarnation's event journal (pid +
start epoch); `cursor` is its current tail — the position a fresh
client anchors at. A reconnecting client that sees the SAME `stream`
may ask `replay_events` with the last `cursor` it saw to recover the
frames the drop ate. A different `stream` means the journal restarted:
anchor at the new `cursor`, never replay the whole journal. After the
initial state, lights and settings, the server sends retained `quota_reset`
events less than five minutes old. They keep their original cursors, so
live delivery and reconnect recovery deduplicate the same reset. It then
offers every confirmed reset from the last 24 hours that the app has not
closed with a `reset_receipt` of `delivered` or `dropped` (read from the
saved reset store, so it survives a daemon restart and an app that was away
longer than the journal remembers). Those frames carry the reset's
`event_id` as their `id`, no `cursor`, and the `at` the daemon confirmed it:
the app dedups by `event_id`, never by stream position. Other event kinds
are not recovered on a fresh connection. The journal is bounded
(512 entries) and in-memory by design — replay survives socket churn,
not a daemon restart.

### state (full)
A state document is built at the end of every controller refresh (a 15 s
timer plus every hook event), on DND changes, on escalation stage changes,
when a client connects, and after commands that change the world. It is
broadcast only when it differs from the last frame sent, ignoring the
fields that move on every build without the document having changed
(`doc_significant_equal`, which reads `_VOLATILE_DOC_PATHS` in
`core_runtime.py`). A quiet daemon therefore sends nothing between changes:
there is no state heartbeat. A client that connects is handed the last
frame that was sent. `now` is the stamp of that last broadcast, not the
current time, and `generation` counts builds, not frames, so gaps in it are
normal. A client that wants the age of what it holds stamps its own arrival
time, as the app's `CoreModel.lastStateAt` does. The app replaces its model
wholesale; there is no partial state message in protocol 1. Timestamps are
Unix epoch seconds.

The app checks an otherwise idle connection with the open `ping` command
every 30 seconds after hello and authentication have settled. It skips
probes while a command is pending. Replay blocks probes for one reply
deadline, measured by a monotonic clock that includes sleep. Its reply ID
remains valid afterward so a late result can still restore missed events.
A silent probe times out under the client's reply deadline and reconnects,
unless a newer request is now pending. These checks establish transport
availability, not a new state reading; a quiet responsive daemon retains
its deduplicated state.

```json
{"t":"state","v":1,"generation":4812,"now":1788982892.4,
 "aggregate":{"mode":"needs_you","needs_you":1,"active":1,"ready":1,"failed":0,"total":3},
 "sessions":[
   {"id":"claude:session:fca1eb06-…","provider":"claude","kind":"main",
    "parent":null,"label":"jr-bar-b7","short_id":"fca1eb06","cwd":"/Users/j/Downloads/JR-Bar",
    "mode":"tool_running","lifecycle":"active","next_actor":"provider",
    "since":1788982891.0,"updated_at":1788982891.0,"stale":false,
    "pid":9170,"origin":{"kind":"claude_app","label":"Claude App","bundle_id":"com.anthropic.claudefordesktop"},
    "ask":null,"remote":false,"terminal":{"app":"Ghostty","bundle_id":"com.mitchellh.ghostty","tty":"/dev/ttys004"},
    "workers":1,"workers_waiting":0,"snoozed_until":null,"event":"PreToolUse","tool":"Bash","message":null,
    "axes":{"outcome":"none","review":"pending","freshness":"live"}}
 ],
 "hidden_count":3,
 "asks":[{"session":"codex:session:…","kind":"permission","opened_at":1788982800.0,"summary":"Run: rm -rf build",
          "answerable":true,"replyable":false,"request":"request:v1:{…}",
          "decision":{"hold_until":1788982845.0,"always":false,"decided":false,"choices":[]},
          "preview":"rm -rf build","risk":"destructive","detail":null}],
 "devices":[{"id":"sidepulse:pro:B293A1","kind":"pro","name":"SidePulse","path":"/Volumes/SidePulse","leds":8,"connected":true,"brightness":79,"linked":true,"last_write":1788982891.31,"error":null},
            {"id":"sidepulse:dot:7F02C4","kind":"dot","leds":2,"connected":false,"error":"volume unmounted"},
            {"id":"screen-bar","kind":"screen_bar","name":"Screen Bar","leds":8,"enabled":true,"brightness":100,"linked":true,"error":null}],
 "usage":{"refreshed_at":…,"next_refresh_at":…,"refreshing":false,
          "providers":[{"id":"claude","instance":"default","account":{"plan":null,"label":"Max","fidelity":"official"},
                        "windows":[{"name":"5h","id":"five_hour","used_pct":42.0,"resets_at":…,"scope":"account","model":null},
                                   {"name":"7d","id":"seven_day","used_pct":61.0,"resets_at":…}],
                        "fidelity":"official","state":"ready","incident":null,"reason":null,"action":null,"observed_at":…,"read_at":…,
                        "tokens":{"input":1200,"cached_input":800,"output":300},"estimated_cost_usd":null,"credits_remaining":null,
                        "forecast":{"window_id":"five_hour","remaining_pct":58.0,"exhausts_at":1789000292.4,"pace":"under","rate_pct_per_hour":12.0,"samples":13}}]},
 "power":{"keep_awake":true,"closed_lid":{"policy":"agents","holding":false,"helper_installed":true}},
 "focus":{"mode":"dim","source":"schedule","until":…,"display":"all","outbound":"all","brightness_factor":0.15,"banner_allowed":true,"audible_allowed":false,"summary":"Dim until 07:00"},
 "escalation":{"stage":"menu_bar","since":1788982800.0},
 "health":{"hooks":{"claude":"ok","codex":"stale","pi":"missing"},
           "managed_hooks":["claude","codex"],
           "detected":{"claude":true,"codex":true,"pi":false},
           "sources":{"claude":{"fresh":true,"heard_age_seconds":1.4,"heard_at":1788982798.6}},
           "intake":{"hook_state":"configured","source_health":"partial","silence_seconds":1.4}},
 "peers":[],
 "unseen_completions":["gemini:session:…"],
 "settings_generation":17,
 "catalog_generation":42,
 "provider_updates":{"grok":{"phase":"updated","from_version":"1.0.44","to_version":"1.0.46","latest_version":null,
                             "message":"Updated 1.0.44 to 1.0.46","finished_at":1788982800.0}},
 "firmware":{"id":"fw-1","device":"SPP-000067","model":"pro","phase":"restarting","outcome":null,…},
 "deck":{…}}
```

Vocabulary:

- `health.managed_hooks` lists provider ids whose current configs contain
  a JR-Bar command or a recognized JR-Bar legacy registration. Ownership
  is separate from activation: an owned integration disabled in its
  provider config remains listed, while `health.hooks` reports `disabled`.
  Foreign hooks never establish ownership. A missing ownership list on
  an older daemon must not authorize an install.
- The daemon's stored usage snapshots may carry `account_discriminator`, an opaque local
  account binding. It is never an email, token or display label. A
  changed binding invalidates cached quota and reset comparisons for
  that source instance. Claude readings without a provable binding
  remain usable as live readings, but cannot establish account-bound
  stale fallback, reset or capacity continuity.
- `sessions[].id` is the existing agent id: `provider:session:<sid>` for a
  main session, `provider:agent:<id>` for a worker (`kind: "worker"`,
  `parent` = the main session's id). `label` is human: the provider's own
  session title when it has one (Claude's `name` from
  `~/.claude/sessions/<pid>.json`, Codex's `thread_name` from
  `~/.codex/session_index.jsonl`), else the collector's derived name with
  its short id stripped (project / first prompt), else the working
  directory's last path component, else `<Provider> session`. A worker
  uses its own title or task. Without one it uses `<head label> worker N`,
  where N is its ordinal among the proven group's workers sorted by id,
  including ended members. State and roster use the same title rule and
  group resolver. Ids belong in help or accessibility text. `short_id` is the first 8
  characters of the session id (of the agent id for a worker); `cwd` comes
  from the hook payload as the process registry recorded it, or the
  provider's session record.
- `mode` is the Python `AgentMode` value (`idle_ready`, `working`,
  `tool_running`, `waiting_for_input`, `long_task_progress`,
  `blocked_error`, `completed`, `ended_unconfirmed`, `unknown`).
  `lifecycle` reduces it to the five words the app renders, and the two
  that mean "over" are not interchangeable:
  - `active` -- working, waiting, or idle-ready, and still being delivered.
  - `completed` -- a run the provider itself said was finished: the last
    event was `Stop`, `SessionEnd` or `SubagentStop`. This is the green
    check, so it is only ever a report, never a guess. **A real terminal
    event wins over a dead process**: `codex exec`, `claude -p` and `pi -p`
    each send a real `Stop` and `SessionEnd` and then exit, and that is the
    normal, expected life of a one-shot run -- it reads `completed`, not
    `ended`.
  - `ended` -- over, but nobody confirmed a success: the session's process
    is **gone** and it never sent a terminal event (the liveness sweep's
    synthetic `SessionEnd`, which the process registry records with
    `end_reason` `process_exited` / `pid_reused` rather than `hook`), or
    the collector *inferred* a completion from something that was not an
    end event. Grey, no check. A row demoted this way also carries
    `mode: "ended_unconfirmed"`, so neither field claims Done.
  - `failed` -- `blocked_error`.

  - `stale` -- a live-shaped session whose source stopped delivering.
    `stale: true` says the same thing on any row, `completed` and `ended`
    included, and is also set when a session's process died without an end
    event.

  A typed usage-limit terminal retains `lifecycle: "failed"` in retained
  roster and history records, with optional `terminal_cause` set to
  `claude_rate_limit` or `codex_usage_limit`. The raw error text is not
  carried. These rows do not claim persistent failure attention and are
  absent from `state.sessions` unless a genuine open ask pins the row.
  A fresh limit episode may give one four-second capacity notice, then
  lighting returns to normal. Repeated attempts do not renew that notice;
  verified positive quota or successful work rearms a later episode.
  Already-spent windows and restored limit events do not announce again
  on startup. Ordinary terminal failures retain their failed outcome but
  leave the live list after the finished-session visibility window.

  Working, tool-running and long-progress rows retain their mode when a
  recent process sweep verifies the matching agent process. Both production
  monitor projections use this evidence. It stays valid for 30 seconds;
  expired or future-dated evidence cannot preserve activity. The timestamp
  and process set are read as one snapshot.
  The sweep keeps an internal candidate list so it can re-verify old work
  after sleep or restart. That list is not exposed as visible activity.
  New or recovered proof requests one refresh; stable repeated proof does
  not generate new progress or repeated refreshes.

  Verified working rows remain present even after an hour of hook silence.
  They are counted as active and remain available to provider marks and
  lighting. `since` still records the last event, so verification does not
  invent new progress. Finished, failed and idle rows keep their existing
  visibility clocks. An open shared host, missing registry record, unreadable
  process table or reused PID does not prove that a session is working.

  `next_actor` preserves canonical operator state (`user`, `provider`,
  `none`, `unknown`). A mode-based fallback applies only when no canonical
  actor is available. `snoozed_until` is the mailbox's active
  snooze epoch for this session (a family `snooze` covers the family, not
  the row; a `scope: "run"` snooze covers this row alone; the later
  deadline wins), null while none is in effect -- the panel reads it to
  say "Snoozed until…" and to offer Unsnooze.
- `workers` is how many of a main session's workers are live and either
  working or waiting. `workers_waiting` (additive, 2026-10-01) is how many
  of those are blocked on a request that stays quiet because
  `subagent_asks_alert` is off, which is the default. A quiet request has no
  light, sound, banner, card, escalation or `needs_you` count, and the
  worker's own agent still shows its prompt. The count exists so the parent
  row can say "1 worker waiting" in plain words instead of passing a stuck
  worker off as a working one. It is information only: it never turns into
  an ask, never offers `answer_ask`, and no surface may light, sound or
  escalate because it is above zero. Only a main session's row carries it. A
  row without it means the daemon did not say (an older daemon, or a row
  that is not a main session), and a client shows nothing for that, never a
  zero. With `subagent_asks_alert` on the count is `0`, because the same
  request is an ordinary ask (next item). It changes only when a worker's
  request opens or closes, so it never makes a state frame differ on its own.
- `axes` is `{outcome, review, freshness}`: three separate facts about a
  row that `lifecycle` alone would run together. `outcome` is what the
  provider reported: `none` while the run is not over, `succeeded`,
  `failed`, `unreported` for a run that ended without saying how, and
  `unknown` when the row is too thin to classify. `review` is `pending`
  while the run is live, `unreviewed` once it finished and nobody has
  cleared it, and `reviewed` once Clear Agents acknowledged it.
  `freshness` is `live` while the source is delivering, `delayed` once it
  stopped (`stale`), and `unknown` when the row has no observation clock.
  A `list_roster` row carries the same three.
- `sessions` is what the panel should be looking at, not everything the
  daemon remembers (`completion_visibility`): live sessions -- working,
  tool running, waiting, blocked, idle-ready -- while they are still being
  delivered or for ten minutes (`LIVE_VISIBLE_SECONDS`) after their last
  event; plus finished sessions (`completed` or `ended`) that no
  `clear_completed` has acknowledged, for twenty minutes
  (`COMPLETED_VISIBLE_SECONDS`) after they ended. Nothing stale older than
  ten minutes is listed. A worker is listed only while its parent is.
  `hidden_count` is how many *main* sessions the policy kept out, which the
  app shows as "n earlier in History"; `list_history` has them all.
  An acknowledgement is bound to the event it acknowledged, so a cleared
  session that starts working again is listed again straight away.
- `ask.kind` is the canonical request kind (`permission`, `input`,
  `approval`, `review`, `dialog`) with a fallback from the hook event;
  `summary` is the hook's message or tool name; `opened_at` the request's
  opening epoch. `dialog` is a form the agent draws that only the owner can
  fill -- Claude Code's MCP `Elicitation` hook (an MCP server asking for
  input, or for a link to be opened), keyed by its `elicitation_id` and
  resolved by the matching `ElicitationResult` (or the turn ending). It
  lights, escalates and holds a card like any ask, and is never
  `answerable` or `replyable`: the panel opens the session instead. Claude's
  `Notification` types `elicitation_dialog`, `elicitation_url_dialog` and
  `agent_needs_input` (a background agent or teammate blocked on the owner,
  a computer-use action to allow) put the session in `waiting` with
  `next_actor: "user"` whatever their words -- they name no request, so
  they carry no card of their own -- and never count as the source going
  quiet.
  `answerable` means the `answer_ask` chain can actually deliver a decision
  to this session -- the provider's negotiated contract declares the
  `answering` capability, the invocation binds the reviewed local surface,
  a handler is registered, AND the session's host can satisfy the delivery
  fence's exact focused-tab proof (Terminal.app and iTerm2 name their
  focused tab's tty; Ghostty names its focused terminal, which must be the
  one recorded when the session started). A provider that only declares `actionable_requests`
  resolves to `false`, and so does a session hosted anywhere else -- kitty,
  WezTerm, an IDE panel, an unresolved or remote host -- so the button is
  never offered for what the daemon could only refuse.
  `replyable` is the narrower "this ask takes free text" (`input` asks
  only). Both are `false` on a remote row's ask. `request` is the
  episode's canonical identity — `request:v1:{…}` from the request key —
  or `null` when the operator state does not model the ask. A surface
  that pins a card to `request` passes it back to `answer_ask` and the
  daemon refuses `stale_request` when the live request has moved on;
  `asks` itself is ordered by `opened_at` so a provider re-emitting a
  pending prompt never shuffles a card out from under the pointer.
- **An unanswered ask stays on every surface until it is settled.** It does
  not expire into idle at an hour (it used to read `Ask` at 59 minutes and
  idle at 61), and no age alone hides it. It leaves `asks` only when:
  a person answers it; the agent settles it itself (its tool's
  `PostToolUse`, a new `UserPromptSubmit`, `Stop`, `SessionEnd`, or the
  decide lane's hold lapsing and the agent carrying on); the session ends
  (its process is gone, or it sent `SessionEnd`); the person dismisses it as
  stale (below); or it expires unanswered (below). The panel row, the
  Overview, the Screen Bar, the strip, the menu bar icon, the deck keys,
  SidePulse Pro and Dot, the notch and History all read the same `asks`, so
  they agree. Two clocks govern an ask nobody has touched, and they are the
  only ones (`ask_lifetime.py`; the older one-hour grace, presence horizon,
  stale window and mailbox section no longer apply to an ask):

  | Constant | Default | Setting | Meaning |
  | --- | --- | --- | --- |
  | `ASK_MAY_BE_STALE_SECONDS` | 6 hours | `ask_stale_after_hours` (0.25–168) | An ask this old, from a session silent for as long, **may be stale**. |
  | `ASK_EXPIRES_UNANSWERED_SECONDS` | 7 days | `ask_expire_after_days` (1–90, never before the mark) | A stale ask this old with **no process vouching for the session** is closed and recorded in History. |

  `ask.stale` is true once an ask passes the first clock: `opened_at` and
  `last_activity_at` (the newest thing its session said, epoch seconds) are
  both older than the mark. The ask is still an ask, still `needs_you`, still
  answerable where it was. Every surface says so in words with the ask's age
  ("may be stale · asked 9 hours ago"): the panel row's subtitle, the Overview
  row, the Screen Bar's tooltip, the notch card. The strip keeps the Ask colour
  and shape but pulses about two and a half times more slowly, and only when
  every light that is doing anything is a stale ask. `ask.dismissible` is true
  for a stale ask on a local session; it is the only ask a surface offers
  **Dismiss** for. `dismiss_ask` takes that one ask off the Mac's surfaces. It
  sends nothing to the agent -- it approves, denies and replies to nothing --
  and the agent's own prompt is untouched. A later ask on the same session is a
  different ask and is not covered. A session with no process behind it is
  ended by the liveness sweep long before any of this; the second clock exists
  for sessions the process table cannot vouch for. An ask whose process is
  still running is never closed by age. When the second clock closes an ask,
  the session is ended through the ordinary hook pipeline (a synthetic
  `SessionEnd` whose `reason` is `jrbar_ask_expired`, so its row reads
  `ended`, never the green check) and `list_history` gets a row of kind
  `ask_expired`: it never vanishes silently. The short rules for things that are
  not asks are unchanged: a completion glows on the strip for 20 seconds and
  keeps its row for 120, the glance light holds 900 seconds, and a finished
  or stale non-ask row leaves `sessions` after the usual ten minutes. An ask
  that names no request (a bare waiting notification) is dismissed by its
  session and opening time, like any other.
- `ask.decision` is non-null while the decide lane holds the request: the
  agent's own `PermissionRequest` hook ran as `jrbar-hook --decide` and is
  waiting on JR-Bar for a verdict (see "The decide lane" under
  `answer_ask`). Such an ask is `answerable` whatever hosts the session --
  Ghostty, an IDE panel, a headless run -- because an answer is the hook's
  own reply and nothing is typed. `hold_until` is the epoch at which the
  hold lapses and the agent's own prompt carries on; `always` says an
  Always allow can be sent (Claude, when its `permission_suggestions`
  carry an allow rule); `decided` is true from the moment an answer is
  delivered to the hook until the agent's own events close the request --
  the tool's `PostToolUse` or `PostToolUseFailure`, a fresh
  `PermissionRequest` for the same request, or the turn ending or moving on
  (`Stop`, `StopFailure`, `SessionEnd`, `UserPromptSubmit`, `Interrupt`) --
  however long the tool runs, with the ask's own outer lifetime (7 days) as the
  cap. While it is true a
  second `answer_ask` for that request is refused `stale_ask` instead of
  typing into a terminal that is busy running the approved tool; an answer
  the hook could not take is not `decided`, so the keystroke path stays
  open. While `decided` is true the ask is `answerable: false` and
  `replyable: false` on every surface, and still carries its `preview` and
  `risk`, since they describe what the person approved. A hold that lapses,
  is let go or is answered republishes `state` at once, not at the next
  refresh.
  `preview` is one bounded
  line of what the agent wants to run (the command, the file, the URL,
  `server · tool` for MCP; token-shaped runs masked) and `risk` is
  `"destructive"` when a shell command matches a pattern that loses work
  if it runs by mistake (`rm -r`, `sudo`, a forced push, `reset --hard`,
  `find … -delete`, `curl … | sh`, …) -- a mark, never a block. `decision` is `null` for an
  ask the lane does not hold; `preview` and `risk` still come from the
  `PermissionRequest` the ingress saw for that exact request id (Claude,
  Codex, Devin, Grok, OpenCode, pi; remembered for as long as the ask can stand), and are `null`
  when there was none.
  `detail` is what the card adds when the person chooses to expand it, and
  `null` when the one-line `preview` already says everything. Only asks
  carry it, and it is read-only context: no answer is built from it. It is
  `{command?, plan?, edit?, truncated}`: `command` is the whole shell
  command when it is longer than the line or spans lines, `plan` is an
  `ExitPlanMode` plan, and `edit` is `{verb, files, added, removed, paths}`
  for `Edit`, `MultiEdit`, `Write`, `NotebookEdit` and `apply_patch`
  (`verb` is `edit`, `write` or `patch`; `added` and `removed` count lines
  in the hook's own input; `paths` names at most five files). Text is
  capped at 2,000 characters with token-shaped runs masked the way
  `preview` masks them (`truncated` says the cap cut something), and file
  contents never leave: a `Write` is its path and a line count. A surface
  never opens it by itself. An `ExitPlanMode` ask is never held by the
  decide lane (a yes/no does not decide a plan, so `decision` is `null`),
  and its `detail.plan` is what the app shows beside an "Answer in the
  session" action.
- `ask.decision.choices` is non-empty while the lane holds a Claude
  `AskUserQuestion`: `[{question, header, options: [label…], multi}]`, one
  entry per question in the agent's order (1–4 questions, 1–8 distinct
  labels each). Such an ask is answered by picking --
  `answer_ask {decision: "answer", answers: {<question>: <label>}}`, a list
  of labels for a `multi` question -- from any terminal. Its `answerable`
  and `replyable` stay what the keystroke path can do, since a bare
  Approve never answers a question. `preview` is the first question's text
  (`+N` for more). `choices` is `[]` for a yes/no hold.
- `pid` is the process registry's live pid for that session (absent when
  the process ended). `origin` is the hook's origin annotation plus the
  bundle id when the kind names an app or IDE; `terminal` is found by
  walking the pid's ancestry for a known terminal or IDE, plus `ps`'s tty.
  `remote` is true for a peer Mac's row (agent id
  `remote:<machine>:provider:…`); nothing local can raise its window or
  type its answer, so it is never offered `open_session`, `answer_ask` or
  `dismiss_session`.
- `aggregate` is a pure function of the rows this document carries, and
  nothing else. The counts are read off `sessions` and `asks` as the app
  receives them -- never off sessions the daemon remembers but did not
  list -- and `mode` is derived from the counts:
  `needs_you` > `failed` > `working` > `done` > `idle`. So the header word
  can never contradict the panel: `working` implies `active > 0`,
  `needs_you` implies an ask with a row to open.
  `ready` counts unseen main-session completions -- unacknowledged, and
  still listed in `sessions`, so a completion that aged out or was cleared
  stops counting; `unseen_completions` lists them.
- Every ask in `asks` names a session listed in `sessions`, and the two
  cannot drift apart. Visibility never evicts a session with an open ask,
  however stale or acknowledged it is (`completion_visibility`'s
  `pinned_ids`), and the parent of a pinned worker is pinned with it. An
  ask whose session the collector no longer carries at all is dropped
  rather than left dangling -- a header that counts an ask and a strip
  that pulses amber for a row the panel cannot show is worse than an ask
  that quietly went away.
- A worker's ask, with `subagent_asks_alert` on, is an ordinary ask. It is
  in `asks` under the worker's own id, the worker's row (`kind: "worker"`,
  `parent` set) is listed beside its parent, and `aggregate.needs_you`
  counts it: `needs_you` is the number of asks in `asks`, whichever listed
  session each names, while `total`, `active` and `failed` stay counts of
  main sessions. A client that lists only main sessions gives such an ask a
  row of its own, carrying the same `ask`, so an alert is never raised for an
  ask the panel cannot show. The ask's `answerable` still says whether
  Approve and Deny are offered: they are only where the provider's hook can
  deliver the answer (Claude and Codex), and the row opens the session
  otherwise. With the
  setting off a worker's request is not in `asks` at all, and
  `workers_waiting` is the only place it shows.
- Device ids are the Python device ids; the Screen Bar row is `screen-bar`
  with `enabled` (the Python `virtual_status_device_enabled` setting).
  Hardware `brightness` is the effective percent after idle/DND dimming.
  `linked` follows the row's `kind`, because two different mechanisms
  share the word: on `screen_bar` it is `link_screen_bar_to_hardware`
  (the bar plays the strip's program); on `pro` and `dot` it is the
  `devices_linked` pairing — true only while the setting is on AND one
  of each is actually connected, so a Dot with no strip never claims to
  be linked.
- `usage.privacy_mode` is the current account-caption privacy choice. Clients
  suppress account aliases when it is true, missing or malformed, including
  aliases previously stored in History. It does not authorize showing the
  collector's account email as a fallback.
- `usage.providers[].windows[].name` is the short form the panel shows:
  `5h`, `7d`, `Daily`, `Weekly`, `Monthly`, `Credits` (a model-scoped lane
  such as Claude's Fable window is `7d Fable`; a lane with no short form
  keeps its label); `id` is the lane id (`five-hour`, `weekly`,
  `fable-only`, …). `used_pct` is `100 - remaining_percent` from the
  provider usage lanes; `resets_at` is the lane's reset epoch whenever the
  lane knows it; `bindable` is false for a lane the provider's own catalog
  does not know — evidence only, never an applicable constraint;
  `fidelity` is `stale` when the source is stale, else
  `official`; `state` is the `ProviderSourceState` value. `source`
  (additive, 2026-09-24) is the lane's source id — `claude-oauth`,
  `claude-statusline` (Claude Code's own statusLine report, standing in
  while OAuth is rate limited or signed out), `cliproxy` (read through the
  CLIProxyAPI hub), `opencode-go-api`, … — so a card can name a stand-in
  source instead of passing it off as a direct read. `detail` (additive,
  2026-09-24) is true for a figure the provider reports only for reference
  (today only OpenCode Go's monthly window, `go-monthly`): the app lists it
  under the rings instead of drawing a ring. A window that is merely not
  `bindable` (a model's own cap such as `7d Fable`, a Codex Spark sub-cap)
  keeps its ring.
- `usage.providers[].constrained` is the window the daemon says is worth
  watching — not the name convention but the least headroom among the
  `bindable` windows that were actually measured: `{id, name, used_pct,
  resets_at, reason, candidates}`, where `reason` is `only_measured` or
  `least_headroom` and `candidates` is how many windows were eligible.
  Null when nothing applicable was measured. The app's card leads with
  this window and explains the pick when it departs from the `5h`
  convention; an unclassified lane cannot win it even at 1 % left. Only a
  window whose `resets_at` is null or after `state.now` is eligible (and
  counted in `candidates`): a window whose reset has passed describes a
  window that no longer exists, so it cannot win `constrained` however full
  it last read. Lapsed windows stay in `windows` unchanged. The quota-runway
  light on the Pro and the Dot and the Screen Bar's quota ember use the same
  rule.
- `usage.providers[].quota_source` is whether this reading can carry a
  quota at all: a quota collector exists for the provider (read off
  `provider_usage_platform`'s descriptors), AND the snapshot is not
  `unsupported` (since 2026-09-24, per snapshot). OpenCode is the case
  that needs the second half: without an OpenCode Go key, or with a Zen
  key that has no Go subscription (`reason` `opencode_no_quota_source` /
  `opencode_go_not_subscribed`), it reports `unsupported` with its token
  totals and no windows. A "show meters" control hides instead of drawing
  dead, and the Usage Center says why in words.
- `usage.providers[].reset_credits` (additive, 2026-09-24) is how many unused
  limit-reset credits the provider reports for this account, or null when no
  source stated a count: Codex's own `account/rateLimits/read`
  (`rateLimitResetCredits.availableCount`), the CLIProxyAPI hub's credit list
  for a hub account, or a Grok billing answer that carries its coupons. A
  count to show; nothing in JR-Bar redeems a credit.
- `usage.providers[].read_at` (additive, 2026-09-30) is when the numbers on
  this row (the windows, the tokens and the cost) were actually read, in epoch
  seconds. `observed_at` stays when the daemon last asked, so a poll that
  failed moves `observed_at` to now and leaves `read_at` where it was: a
  `stale` row that kept its last good reading shows the reading's real age,
  not the age of the failed attempt. On a live reading the two are equal.
  Never later than `observed_at`, and always present when `observed_at` is (a
  daemon that could not say falls back to `observed_at`). An app reads "read
  N ago" from `read_at`, and treats a missing key (an older daemon) as
  `observed_at`.
- `usage.refreshing` (2026-10-01) is true while a refresh is still asking
  providers. A refresh asks up to four at a time, each under a 75 second
  deadline, so one slow provider no longer holds up the rest. While it waits,
  `usage` can arrive more than once with `refreshing: true`: a provider that
  has answered carries its new reading, and one still being asked keeps the
  reading it had (never a gap). The last `usage` of a refresh has
  `refreshing: false`. A provider that has not answered by its deadline is
  given up on for that refresh only: `state` `unavailable`, `reason`
  `response_timed_out`, its last good reading kept as `stale`. Two reasons are
  new: `response_timed_out`, and `usage_permission_missing` (`action` "Reconnect
  Claude"), which is Claude's usage endpoint refusing a sign-in that lacks the
  usage permission (an HTTP 403 whose body is the API's JSON error). Like any
  failure it reads `needs_sign_in` for a provider with no earlier reading, and
  `stale` carrying that same `reason` and `action` for one that has a last
  good reading. Every other status, a 403 with a non-JSON body (a proxy's
  page) and a network failure still read `network_unavailable`.
- `usage.providers[].availability` (additive, 2026-10-25) describes the
  installed source: `source_idle`, `failing`, `missing_recent`, `not_found`,
  `absent`, or `available`. An unknown inventory result never means absent.
  `status_text` names the cause; `last_good_age_seconds`
  is null when there has been no reading. `panel_visible: false` suppresses
  a never-used, absent provider or a row the person explicitly hid. Settings
  still lists it. A removed provider keeps its stale reading for seven days,
  then says "Not found on this Mac" and offers Hide. Nothing hides itself.
  Settings omits "Show in panel" for an `absent` row because it cannot
  restore that row while the provider is absent.
  `action_kind: open_app` opens the provider; `action_kind: hide` hides only
  its panel row. Send `provider_action` with explicit `action: "open_app"`
  or `action: "hide"`. The daemon checks current facts and refuses an action
  that no longer applies. A generic action never hides a row. Settings can
  restore it with `panel_hidden: "false"`.
  A failed installed source keeps its cause, fix and last-good age visible.
- `usage.providers[].windows[].elapsed` is true when the window reset after
  its reading. Its historical percentage moves to `last_used_pct` and
  `used_pct` becomes null. Clients must not present it as current usage.
- Claude's `set_provider_options` accepts `cli_fallback: "true" or "false"`.
  This key is reserved and has no effect in 0.10.0. Settings hides it,
  `list_providers.options` omits it, and the collector never calls the CLI
  probe. The production probe refuses with
  `claude_cli_command_transport_unverified`. The
  [PTY design note](archive/2026-10-25-claude-cli-usage-pty.md) records the
  requirements for a later release. Its synthetic tests do not establish
  installed-CLI compatibility.
  `panel_hidden: "true" or "false"` is accepted for any provider to hide or
  restore its panel row without changing collection or usage consent.
- `usage.providers[].incident` is the provider's status-feed incident as
  one line (`"Anthropic: Elevated errors"`), or null. It is an outage on
  the vendor's side, never a quota verdict. It is null the moment the feed
  goes stale or has not answered, so a present value is current and the
  wire never invents one.
- For Claude and Codex, `usage.providers[].tokens` and `estimated_cost_usd`
  are local totals for the last 30 days (today and the 29 local days before
  it, the days the usage graph's 30-day range draws), read from the usage
  scan cache and never from a scan of their own. Each message or turn is
  counted once (the first sighting wins, and a Codex fork or copied rollout
  counts under its parent), across the primary home and every extra home.
  Every scan, whatever range its caller asked for, reads at least the last
  30 days and writes that month's totals into its cache as `daily`: per local
  day and model key, the record count and the input, cached input,
  cache-creation and output tokens, worked out from the whole stream the
  scan saw, so a month of any size is a few kilobytes and the cache's
  per-file records (capped at 8 MiB, and left to overflow on a busy month)
  are never what the card sums. A Claude reading whose cache has no `daily`
  reaching back to the start of the window shows zero tokens and a null cost
  until one does, not a partial figure (a cache of an older version is
  discarded and rebuilt; so is one that cannot be read, and a `daily` that
  does not parse is never summed); a Codex reading counts only the days its
  caches' `daily` covers, never more. In the rare case that `daily` cannot
  be held (more than 256 distinct model keys, a `daily` past 512 KiB, or a
  timestamp no calendar day holds), or the scan could not list every folder
  (one it has no permission to read), the scan writes none and the Claude
  card stays empty.
  `estimated_cost_usd` is null unless every counted record was priced.
- `usage.providers[].forecast` is the CodexBar reading for the provider's
  primary window (the `5h` one when reported, else the first; `window_id`
  names it): `exhausts_at` (epoch, or null when nothing is burning),
  `pace` (`ahead`: the line through the recent samples crosses 100 %
  before `resets_at`; `on`: within 10 % of the time left until the reset,
  either side; `under`: the reset comes first, or nothing is burning;
  `exhausted`: `used_pct` at or above 99.5), `remaining_pct`,
  `rate_pct_per_hour` and `samples` (how many shaped the line). The
  daemon keeps its own history: one `(at, used_pct)` sample per provider
  window whenever the percentage moves or five minutes pass, at most 48
  per window, in `~/.local/state/jrbar/usage-samples.json` (saved at most
  once a minute and on quit). The pace is a least-squares line over the
  samples of the last 90 minutes after the last reset (a drop of more
  than a point), and needs 30 minutes of spread. A *measured* window
  whose evidence cannot carry a pace is not null and is never left to a
  weaker client-side fit: `pace` is `guarded`, `exhausts_at` is null, and
  `reason` says which guard fired — `insufficient_samples` (no usable
  readings), `insufficient_span` (readings without the 30-minute spread),
  `reset_boundary` (a reset just truncated the history), `stale_samples`
  (the newest reading is over 15 minutes old) or `clock_regressed` (the
  clock moved backwards and the window's samples are future-dated);
  `samples` and `span_seconds` report what survived. `forecast` is null
  only when the window's percentage was never reported at all or the
  sample buffer is absent. Without a known reset a window heading for
  100 % is `ahead`.
  `exhausts_at` (here and in `windows[].forecast`) is rounded to the
  minute (additive precision note, 2026-09-25): the line through the
  samples moves it with every build, so it changes at most once a minute
  instead of in every frame. An exhausted window's `exhausts_at` is the
  build's `now`, rounded the same way.
- `health.sources.<provider>.heard_at` (additive, 2026-09-25) is the epoch
  of the last event the daemon accepted from that provider, or null when
  it never heard one: the moment itself, so a client computes the age on
  its own clock instead of reading `heard_age_seconds`, which ticks in
  every frame. `heard_age_seconds` stays, with the same meaning, for now.
- `focus` is the quiet state in the words a client reads: `mode` is the
  active quiet mode (`mute`, `dim`, `pause`, `asks_only`, `dark`) or the
  literal `off` -- never null -- while nothing quiet is in effect.
  `override_revision` identifies the daemon's current override slot, even
  when quiet is off. It changes after every accepted override edit,
  including identical edits and cancellation, and after a daemon restart.
  Natural expiry and unrelated quiet settings leave it unchanged.
  `source` is `override` (a `quiet` command's manual override),
  `schedule`, `focus` (a macOS or named Focus), or null under `off`.
  `until` is when *this* quiet ends: the override's own expiry for a
  manual quiet, the schedule interval's end for a scheduled or Focus
  quiet, and null while nothing is in effect -- a merely upcoming quiet
  period never surfaces as an end time. `display` is the lights' axis
  (which kinds may light up) and `outbound` is the admission for banners,
  sounds and webhooks by kind class: `all`, `critical` (asks, failures and
  the escalation ladder), `asks` (asks and the escalation ladder only) or
  `none`. The two can disagree -- a Dim schedule under a Mute Focus lights
  everything and admits nothing outbound -- so a client reads each for its
  own job. `mode` is only the first contribution's word, so a client
  gates on `banner_allowed`, `audible_allowed` and `outbound`, and falls
  back to `mode` only when the axes are absent.
- `escalation.stage`: `none`, `ramp`, `menu_bar`, `final` (0…3);
  `since` is when the oldest unanswered ask started blocking, a wall-clock
  epoch fixed for the episode: it does not move from build to build or
  across a sleep. A new oldest ask, a Resume Escalation and a daemon
  restart each start a new episode.
- `power` says why the Mac is (or is not) held awake. `keep_awake` is true
  while anybody wants it awake -- the agents (working, or in the grace
  after) or the person's lease -- and nothing has made the holds yield.
  `hold` is the one keep-awake hold: `state` is `off`, `agents` (the
  agents hold it; `agents` counts the main sessions working) or `manual`
  (a lease is in force; `lease` is `{kind: duration|agents|indefinite,
  started_at, until, sessions[], display, source}`, `until` being the
  countdown's end for `duration` and the backstop for `agents`); `active`
  is whether the assertion is actually held right now (the app draws a
  `state` of `agents` or `manual` with `active: false` and no `suspended`
  as "Not held", never as "Awake"); `display` whether
  the screen is held too; `grace_until` the end of the post-work grace
  while the agents' hold is in it; `suspended` names a yield that took the
  hold away while the demand stands -- `thermal` (the thermal state
  reached `serious` with the lid shut or `critical` with it open, released
  until five cool minutes pass), `battery` (the low-battery floor) or
  `low_power` (macOS Low Power Mode is on, read from
  `NSProcessInfo.isLowPowerModeEnabled`, or from `pmset -g`'s `powermode`
  or `lowpowermode` line when Foundation can't answer, at most once a
  minute, while `keep_awake_yield_low_power_mode` is on, the default; heat
  and the battery floor outrank it);
  `thermal` is `nominal`/`fair`/`serious`/`critical` or null.
  Optional `release_failed` is true when the owned Keep Awake process could
  not be stopped. `active` stays true while that process lives, even if
  `state` is `off` or `suspended` is set. `display` describes the surviving
  process's policy. The daemon retains its handle and retries release;
  it does not start a replacement before the old process exits.
  Optional `persistence_error` is `save_failed` when a new lease could not
  be saved, or `clear_failed` when cancellation could not be saved or a
  failed start left uncertain saved data while no manual lease was active. It is
  null or absent after a successful save or cleanup. This warning is
  separate from assertion process errors and survives process recovery.
  A failed save preserves the current lease in memory and any pending cleanup
  warning. A write can publish before reporting failure. The daemon reads
  back the bounded file and, if it matches the attempted lease, makes one
  rollback attempt to the previous lease or a null cancellation marker.
  Saved data may remain uncertain if readback or rollback fails. A
  `save_failed` warning does not guarantee unchanged data on disk. Check
  the current hold and retry before restarting the monitor.
  Cancellation always ends the current manual lease. If deleting its file
  fails, the daemon writes a JSON null cancellation marker instead. If both
  operations fail, cancellation is not guaranteed across a restart.
  Repeating `release_awake` retries cleanup even when no manual lease remains.
  A successful new lease save replaces any pending cancellation.
  `closed_lid` adds `lid_closed` (the daemon's last reading, null while it
  has none or while nothing watches the lid -- the lid is polled only
  under a closed-lid policy, a hold or a lid animation, and a reading the
  poll no longer keeps is not reported), `sleeps_on_release` (the daemon asks for sleep -- an
  unprivileged `pmset sleepnow` -- when the closed-lid hold drops with the
  lid shut and `AppleClamshellCausesSleep` says no external display is
  keeping clamshell mode; heat and the battery floor release even the
  `always` policy), `last_sleep_at` and `sleep_error`. Optional `error`
  reports a closed-lid assertion, watchdog or helper failure, and clears
  after recovery. `holding` remains true while an owned assertion or
  system sleep-disable setting remains active after a failed release.
  Release history and automatic sleep wait until those holds are released;
  retries retain the original held stretch. Watchdog cleanup alone does
  not count as an active power hold. `last_release` is
  the newest release worth reading, `{kind, reason, at, duration,
  finished, slept_at}`: `kind` `lease_ended` (`reason`
  `expired`/`finished`), `suspended` (`thermal`/`battery`/`low_power`),
  `lid_hold_ended` (`duration` the held stretch, `finished` how many runs
  the activity ledger saw finish during it) or `slept` (carrying the
  stretch it closed, so one row reads "ran 2 h 40 m closed, 3 finished,
  slept at 02:14"); a lease the person cancelled is not one. The same log backs
  the `power` rows in `list_history` and the `power` event. `battery`
  (null on a Mac with no battery) is the daemon's reading: `{percent,
  charging, plugged, minutes_left, minutes_to_full, health_percent,
  cycle_count, temperature_c, condition, draw_watts, adapter_watts,
  runway}`, every estimate null while macOS is still estimating;
  `runway` is `{agents, minutes_left, short, adapter_short,
  full_speed_watts}` and `short` is true only on battery, with agents
  working and a hold keeping the Mac up, when fewer than 30 minutes remain.
  `adapter_short` is true while the charger is in, agents are working and
  the battery still falls by 1.5 W or more (it clears under 0.5 W, so a
  spike at the edge does not flap it): the charger cannot carry the run.
  `full_speed_watts` is then the adapter this Mac charges at full speed on,
  else null. The estimates, the draw and the temperature move on every read
  and alone never re-broadcast `state`.
- `presence` is the one presence fact from the app's `presence` reports:
  `{on_call, mic, camera, screen_shared, since, in_meeting, meeting_until,
  away, fresh, quiet, escalation_ceiling, celebrations_held}`. `on_call`,
  the three sensor flags and `away` read false once the report is stale
  (`fresh` false, 180 s without a renewal); `since` is when the current
  call began, carried across renewals; `quiet` is what the daemon did about
  it (`sounds`, a quiet-mode word, or `off` -- `call_quiet_mode` while on a
  call, else `meeting_quiet_mode` while in a meeting); `escalation_ceiling`
  is 1 while a call holds the ladder at the light, else null;
  `celebrations_held` is true for the whole call, whatever the quiet mode.
  While a call's quiet is in force `focus.source` is `call` (`calendar` for
  a meeting, `away` for an empty desk under `away_quiet_mode`), and a
  `sounds` quiet leaves `focus.mode` at `off` with
  `focus.audible_allowed` false -- the one test for "no sounds right now".
  `quiet` takes the first that applies: the call, then the meeting, then
  the empty desk. `focus.named_readable` says whether the daemon's helper
  can itself read which Focus is on (Full Disk Access is granted per
  binary, so the app's own probe can say "granted" while the helper still
  cannot see); null until it has tried. False also covers unreadable mode
  identifiers or a malformed assertions file. A complete named reading
  fits at most 64 distinct identifiers, each at most 256 UTF-8 bytes;
  identifiers retain their exact spelling. DND named-detail callbacks take
  at most 64 entries from this canonical reading, deduplicate them without
  changing identifiers, and reject an invalid set as a whole under the
  same UTF-8 bound.
  The private assertion and configuration files are read without changing
  their permissions, with an 8 MiB JSON-document budget. Invalid encoding,
  parsing or traversal recursion failures and exceeded budgets are
  unavailable readings. Unavailable named detail does not mean that the
  public Focus activity reading is inactive.
- `devices[].write_health` (a hardware device, once the daemon has tried
  to write it) says why a strip looks wrong instead of only "Connected":
  `{latency_ms, writes, transformed, refused, last_refusal,
  last_refusal_at, failing}` -- how long the last write took, how many
  programs reached it, how many of those the safety compiler had to
  change (a clamped cadence, a slowed flash; not mere spelling), how many
  never reached it and the last one's reason, and whether the latest
  attempt was one of those (`failing`). Counts run since the daemon
  started; no program text is kept. The latency, the counts and the
  refusal stamp move with every attempt and alone never re-broadcast
  `state`; starting or stopping failing, or a new reason, does -- a dead
  device's retry every few seconds is the same news each time.
- `health.hooks[provider]`: `ok` (installed and delivering), `stale`
  (installed, running, nothing arriving), `missing` (not installed).
  `health.detected[provider]` is whether the provider's CLI/surface was
  actually found on this Mac (the installed-agent inventory), so the app
  can say "not installed" instead of implying a dead hook. The key is
  omitted while the daemon cannot yet answer for that provider: a CLI that
  is found by searching PATH stays unanswered until the login-shell PATH
  probe has finished (it runs off the state build and is retried after a
  failure), so a missing key means unknown and is never read as "not
  installed". An explicit `false` means the daemon looked and found nothing.
- `catalog_generation` is the effect catalog's content-derived generation
  (the same derivation as `list_effects`' `generation`): it moves when the
  registry, installed packs or assignments change, so a client can decide
  to reload its catalog without reconnecting. Absent until the catalog has
  been built once.
- `provider_updates` is what each agent CLI's updater last did, keyed by
  provider id (`claude`, `codex`, `grok`, `devin`, `opencode`, `gemini`):
  `{phase, from_version, to_version, latest_version, up_to_date_version, message, finished_at, updatable, update_advice}`.
  `phase` is `idle` (nothing has run; the entry exists only to carry
  `latest_version` or installation capability), `running`, `updated`, `unchanged`, `failed` or
  `needs_terminal` (the updater requires a terminal; the message names the opened terminal or the manual step).
  `from_version` and `to_version` are the CLI's own `--version` before and
  after (null where it could not be read). `latest_version` is set only
  while update checks are on (`provider_update_checks_enabled`) and only
  when the npm registry offers a version newer than the installed one, so
  a non-null value means "an update is available"; it is null otherwise
  and always null while the setting is off. `up_to_date_version` is the installed
  version for which a successful registry check found no newer release. Both
  versions must be readable dotted versions; an installed version newer than the
  registry also qualifies. This optional fact is null while checks are off and
  cleared when an updater starts. It never changes the last updater outcome.
  Clients use it only when it matches the doctor's current installed version,
  retaining progress and retries for running, failed or terminal-required updates.
  `message` is one plain
  sentence, the one the app shows. `finished_at` is when the last run
  ended and is null while `running` or `idle`. A provider with no entry has
  never been updated, checked or assessed since the daemon started; a client reads
  that as unknown and an unrecognised `phase` as `idle`. `updatable` is true
  when the installed CLI has a supported update command, false when it is
  missing or its installer is unsupported, and null or absent when not assessed.
  `update_advice` explains a false capability without replacing the last run's result.
  The existing off-main `hooks_doctor` refresh assesses capability using local
  installation paths and the same update-command resolver as an explicit update.
  It launches no command and makes no outbound request. Serialization reads cached
  facts only. An explicit update also records its capability preflight. A later
  doctor refresh reassesses installations changed outside JR-Bar. Clients hide Update
  for false capability or a confirmed current version without a newer offer, retain
  running progress, and allow explicit retries when capability or version is unknown.
  Only a change of phase, version, message or capability moves the document. A running update publishes
  bounded stage messages for checking the installed version, running the updater
  and verifying its result. The known installed version is retained if a later
  stage fails. There are no invented percentages or raw output streams.
- `firmware` is the firmware update job, present only while one exists: running,
  or finished less than ten minutes ago. Its fields and meaning are under
  "Firmware updates" below. It moves with every phase and with download
  progress; a client that is not showing the job ignores it.

#### The Creator Micro 2 deck (`state.deck`)

The pad as the daemon drives it, built by `core_deck.build_deck_document`
from the session board (`deck_session_board.py`), `deck-controls.json`,
`integrations.json`, a background HID enumerate every 10 s, the output
service's receipts and the private keymap backup. Always present; every
field is one the Control Center and the Rail decode.

```json
"deck":{
 "device":{"serial":"A1B2C3D4E5F6","name":"Creator Micro 2","transport":"bluetooth","connected":true,"approved":true,
           "firmware":null,"layer":0,"profile":0,"conflict":null,
           "receipt":{"code":"ready","message":"Creator Micro 2 ready.","at":1788982862.4}},
 "slots":[{"index":0,"identity":"<sha256 of the work key>","session":"codex:session:…","label":"sidepulse-core","provider":"codex",
           "state":"input_required","pinned":true,"navigable":true,"color":"#FF3A00"}, …13 rows…],
 "aux":[{"index":13,"label":"Encoder 1 input 1","mapping":"previous_bank"}, …AG13..AG19…],
 "scope":"automatic","scopes":["codex","claude"],
 "banks":{"index":0,"count":1},
 "rail":{"edge":"left"},
 "keymap":{"state":"applied","backup_at":1788896492.4,"generation":3,
           "layers":[{"profile":0,"layer":0,"label":"Profile 1 / Layer 1: Base","scope":"automatic","owner":"jrbar"}]},
 "input_check":false,
 "last_input":{"index":1,"kind":"press","at":1788982888.4},
 "settings":{"enabled":true,"session_mode":true,"analog_enabled":false,
             "bindings":[],"layer_map":[{"layer":1,"scope":"codex"},{"layer":2,"scope":"claude"}],"scopes":[],
             "ownership":"hold","layer_owners":[]}}
```

- `device` is `null` when no pad is known (nothing approved, nothing
  enumerated). `serial` is the approved serial (`integrations.json`), else
  the first pad the HID probe sees; `transport` is `usb` or `bluetooth`
  from the probe (USB preferred when both); `connected` when the probe
  lists it or the output service holds it; `approved` when
  `creator_micro_enabled` names this serial; `profile` / `layer` are the
  device's active position (0-based, as the keymap indexes them; the
  firmware reports the layer 1-based), live from the output service's
  `device.status` polls while it runs and from the last inspection until
  the pad has answered; `firmware`
  is not read yet; `conflict` is `foreign_responses` while the output
  service's last receipt is `device_conflict` (another app answered on the
  report stream; the daemon stopped writing); `receipt` is the last
  `deck_receipt`.
- `slots[]` are the current bank's 13 keys (`SLOTS_PER_BANK`), in the
  board's stable positions: `identity` is the board's digest of the work
  key (null when unassigned), `session` the live agent id (null when the
  identity is remembered but not observed: "Reserved"), `label` the
  `sessions[].label`, `state` the board word (`input_required`, `failure`,
  `active`, `completed`, `idle`, `stale`, `unavailable`, `unknown`,
  `ended_unconfirmed`), `navigable` whether the navigation resolver has a
  verified target, `color` the solid per-key colour the lighting layer
  writes (`creator_micro_lighting`: ask `#FF3A00`, error `#B00020`, working
  `#00E5FF`, done `#00FF66`, dark `#020204`) or `#000000` while the pad is
  not driven (no output service ready, or session mode off). `failure` and
  `quota_exhausted` take the error colour, `input_required` and
  `quota_warning` the ask one -- a key you can answer and a key you cannot
  are never the same colour.
- `aux[]` are AG13..AG19 (one encoder, three inputs; four joystick
  sectors) and, only while `settings.analog_enabled` is on, the four
  calibrated analog joystick sectors AG20..AG23 (labeled `Joystick
  sector N (analog)`), with the explicit `deck-controls.json` mapping
  kind bound to each (`next_bank`, `next_scope`, `open_usage`, …) or
  null; labels come from the inspected keymap when there is one.
- `scope` is the board's provider scope: `automatic` admits every
  session, a provider id admits only live sessions reporting that
  provider. The output service's `device.status` polls resolve it through
  `settings.layer_map` (input reports carry no layer field, so the layer
  is learned by polling); the `next_scope` / `previous_scope` actions
  step it through `automatic` plus `scopes`. A scope change restarts
  banking at zero and revokes queued input. `scopes` is the cycle order:
  the non-automatic `layer_map` scopes by layer, then `settings.scopes`.
- `keymap.state`: `stock` (no private backup, or the recovery journal
  says the original is back), `applied` (a verified JR-Bar write),
  `recovering` (an interrupted transfer: Restore is the way forward),
  `unknown` (files that do not parse); `backup_at` is the backup file's
  mtime; `generation` counts setup results since the daemon started;
  `layers` lists the editable profile/layer pairs of the inspected (or
  backed-up) keymap, each with the `scope` the layer map assigns it and
  the `owner` `settings.layer_owners` gives it (`jrbar` for every layer not
  handed to an external writer).
- `input_check`: inputs are shown as `deck_input` events and every
  bound action is paused (also turned on by a verified keymap write, as
  the Python app did). `last_input` is the last observed control
  (`kind`: `press` for a key, `dial` for AG13..15, `joystick` for
  AG16..19, `analog` for the calibrated sectors 20..23).
- `settings` mirrors `deck-controls.json` (`enabled`, `session_mode`,
  `analog_enabled`, the explicit aux `bindings`, the `layer_map` from
  hardware layer to board scope, extra `scopes`, `ownership` and
  `layer_owners`; the Python defaults are all off, with layers 1 and 2
  mapped to `codex` and `claude` on a fresh install). `ownership` is `yield`
  or `hold` and says how the pad answers another app writing to it: `yield`
  pauses JR-Bar's output while the adapter waits out its conflict retry,
  `hold` absorbs the accusation on a layer JR-Bar owns and writes its
  latest frame back. It is `hold` on a fresh install and for a file written
  before the field existed. `layer_owners` is `[{layer, owner}]`, who may
  paint each hardware layer: `jrbar` (the auto layer, painted from the
  session board and what any layer not listed is), `everything`, or a
  provider id, which hands the layer to that external writer so JR-Bar
  leaves it alone while the pad sits there. Layer 0 is always `jrbar`.
  `deck_set_settings` writes both.

### lights
The presentation program for each surface, exactly the LEDS DSL text the
hardware receives, plus the anchor the app needs to phase-lock the Screen
Bar to the strip. Sent whenever a program changes on any surface (every
Screen Bar sync, every completed hardware write, every preview start and
end), and at the end of a refresh when anything in it moved beyond the
volatile fields: `lights` follows the same `doc_significant_equal` rule as
`state`, so an unchanged frame is not re-sent.

```json
{"t":"lights","v":1,
 "surfaces":{
   "hardware":{"program":"#000000 160ms cosine\n0:#1D050A 420ms pulse 0ms; …\nrepeat","led_count":8,"anchor":1788982891.31,"brightness":0.79,
               "why":"waiting","why_detail":{"session":"codex:session:…","label":"sidepulse-core","provider":"codex","seconds_in_state":92.4,"brightness_factor":1.0,"dimming":[]}},
   "screen_bar":{"program":"…","led_count":8,"anchor":1788982891.31,"motion":"continuous","static_fallback":"…","brightness":1.0,"why":"waiting","why_detail":{…},"override":"focus"},
   "dot":{"program":"…","led_count":2,"anchor":1788982891.31,"why":"waiting","why_detail":{…}}
 },
 "linked":true,"devices_linked":true,"linked_skew_ms":11.0,"linked_skew_at":1788982891.31,
 "dot_link":{"state":"linked","role":"extend","error":null}}
```

- `hardware` is the first connected 8-LED strip (a second one is
  `hardware:<device id>`), `dot` the connected 2-LED device, `screen_bar`
  the program the Screen Bar plays (calibration and resting
  glow applied). The `screen_bar` surface mirrors `hardware` only while
  the bar is linked (`link_screen_bar_to_hardware`) and a strip is
  connected; unlinked it publishes nothing unless a live bar program is
  playing. When linked, `screen_bar.program` is the strip's NOMINAL
  program — the text the strip was asked to play, before the write
  boundary's die gains and light-domain brightness decode — with each
  `#rrggbb` token below the display legibility knee lifted on a
  continuous power curve (`colors.lift_program_luminance`,
  `floor * (Y / floor) ** 0.5`): hue, saturation and timing pass
  through untouched, near-black stays near-black, and `#000000` stays
  black — a dark beat never gains a resting glow the strip does not
  have. Its one `brightness N` is the Screen Bar device's own, never the
  strip's. While the strip shows an ambient kind (agent, battery, studio,
  quota runway) or a preview, that is the bar's ambient plan
  (`screen_bar_min_glow` floor included), because the strip's ambient N
  starts from the display backlight the bar is already dimmed by. While
  the strip plays a signal (completion, failure, calendar, ...), it is
  the bar's signal plan, which cuts through idle, sleep and night dims,
  at the signal's own intensity (the strip's N over the strip's signal
  plan). The strip's drive bytes are never replayed on a display that
  has no die to calibrate.
- On a linked mirrored-strip `screen_bar` surface, optional
  `strip_transfer` describes how to read sampled strip drive colors on the
  display: `{"channel_gains":[r,g,b],"display_channel_gains":[r,g,b],
  "code_to_light_exponent":e}`. When present, `program` contains the
  delivered strip-drive colors. The app samples those colors at the strip's
  shared anchor and timing, decodes each normalized channel to emitted light
  with `code_to_light_exponent`, removes the strip's `channel_gains`, then
  applies `display_channel_gains` and sRGB encoding. The Screen Bar's own
  `brightness N` remains independent of the strip's control and is applied
  once after that conversion. Without this metadata, including legacy
  daemons, unlinked programs, and surfaces that do not mirror a strip, the
  existing color path is unchanged.
- `source_led_count`, optional on `screen_bar`, is the program's source
  canvas, either 2 or 8. Without it the canvas is eight LEDs. When mirroring
  a lone Dot it is 2: parse and sample the original two-LED program, then
  repeat each sampled pixel over four display LEDs. Expand after sampling,
  including rolls, brightness and initial state. The program stays within
  the firmware's 512-byte and 20-line limits. `led_count` remains the display
  output size.
- `cue` (on `screen_bar`, `hardware` or `dot`, only while one is staged
  there) names the semantic ambient cue on that surface, `{id, name}` --
  `{"id":"handoff_baton","name":"Handoff baton"}` -- so Why this light can
  say "Handoff baton" instead of an unexplained sweep. The ids are
  `list_cues`'; the Dot's binary heartbeat is a display and never named.
- `anchor` is epoch seconds: the strip's write-completion moment for
  hardware, the presentation's playback anchor for the Screen Bar; when
  `linked` (the `link_screen_bar_to_hardware` setting) and a strip is
  connected the Screen Bar carries the strip's anchor, because the strip
  loops from its write and never re-anchors on a Screen Bar re-sync
  (`core_runtime.screen_bar_anchor`). A finite, positive past anchor remains valid
  regardless of age. Initial playback, same-program updates and wake map
  that epoch onto the current media clock without restarting the loop.
  `screen_bar_phase_offset_ms`
  (settings document, `set_setting`, ±1000 ms, default 0) shifts that
  anchor on the Screen Bar only: positive values hold the bar back, for
  when the two are visibly out of step.
- `brightness` is what the DEVICE is driven at: the `brightness N` in the
  bytes on the device, over 255. `brightness_policy`, present only when it
  differs, is the percentage the brightness policy asked for. The two are
  not the same number and never were -- the firmware scales drive bytes, so
  a perceptual 51% is 23% of full drive -- and reporting the policy figure
  as if it were the hardware's is how "the Dot says 100% and looks dead"
  went unexplained (2026-09-10).
- `motion` is `static`, `finite` or `continuous`; `static_fallback` is the
  reduced-motion program.
- `why` is a stable enum the app maps to words and colours
  (`core_projection.WHY_VALUES`):

  | why | meaning |
  | --- | --- |
  | `idle` | nothing to do; the resting glow |
  | `working` | an agent is working (glance `active`) |
  | `waiting` | an agent is waiting on you (glance `attention`) |
  | `completed` | a fresh, unseen completion (glance `fresh_completion`, or the completion sweep / all-clear display) |
  | `failed` | a fresh or unresolved failure (glance, or the failure display) |
  | `capacity` | a quota window is the story: the capacity glance, the quota alert / runway displays, a reset celebration |
  | `quiet` | DND shows nothing (display admission `none`, brightness factor 0, or the Fully Dark display); also an idle light dimmed by DND |
  | `sleep_dim` | idle and dimmed because the display is asleep |
  | `idle_dim` | idle and dimmed by the idle-dim timer |
  | `battery` | the battery display (selected, previewed, or the low-battery takeover) |
  | `calendar` | a calendar glow |
  | `reminder` | a reminders glow |
  | `escalation` | the escalation takeover for an ignored ask |
  | `preview` | a `preview_program`, a signal test or a peek holds the surface |
  | `studio` | an Effect Studio pin owns the device |
  | `unknown` | no glance yet |

  Precedence: preview, then a device display kind that names the reason
  (battery, calendar, reminder, escalation, studio, quota, failure,
  completion, dark), then DND showing nothing, then the glance semantic;
  an idle light that is merely dimmed says why (`idle_dim`, `sleep_dim`,
  `quiet`), a working light stays `working` and reports its dimming in
  `why_detail`. `why_detail` is `{session, label, provider,
  seconds_in_state, brightness_factor, dimming}`: the session the light is
  about (the oldest open ask for `waiting` / `escalation`, the newest
  working main for `working`, the newest unseen completion, the newest
  failure; null otherwise), how long it has been in that state, the
  product of the dimming factors that applied to the device's brightness,
  and the dimming words in the order applied: `idle_dim`, `quiet` (DND),
  `sleep` (display asleep), `auto_dim` (the `auto_dim` setting below).
  `seconds_in_state` is always a **duration in seconds**, never a clock
  reading, and never more than a year: the ask's age, else the session's
  `since` measured against `now`, else -- when no session is behind the
  light -- the glance's relay epoch measured against the *monotonic*
  clock it came from. It is `null` when no honest number exists. Both
  clocks meet in this one field and they are not interchangeable: a
  monotonic reading subtracted from a wall-clock `now` is what made a
  surface report 1.79e9 seconds, which the app rendered as "20704 d".
  `seconds_in_state` is as of the frame's build, and a frame that differs
  from the last one only in it is not sent (it is one of the volatile
  fields), so a held frame's number goes stale. A client that shows it live
  ages it on its own clock from `sessions[].since` (or `asks[].opened_at`
  for a light that is about an ask), and falls back to the number when it
  has no such anchor.
  Every duration-shaped field in `state` and `lights` carries the same
  bound (`core_projection.MAX_DURATION_SECONDS`), `health.sources.*.heard_age_seconds`
  included; `health.intake.silence_seconds` is the policy window, not an
  elapsed time.
  `override` still names the glance override (`focus`, `provider_pin`, …)
  when one applies.
- `auto_dim` (top level, beside `linked`): the decision behind the
  `auto_dim` word, `{mode, source, factor, available, reading}`. `mode` is
  the setting (`off`, `schedule`, `display`, `ambient`); `source` which
  reader produced the factor (`off`, `schedule`, `display`, `ambient`:
  ambient mode without a readable sensor falls back to `display`);
  `factor` the multiplier that went into the `night_dim` stage; `available`
  false when the mode's own source could not be read (no ambient light
  sensor, an external or sleeping display); `reading` the raw reading (lux
  for ambient, the display fraction, minutes since midnight for schedule).
- `devices_linked` (the `devices_linked` setting, default on) is present
  when both a Pro and a Dot are connected: their programs are written
  back to back in one hardware worker command from the same presentation,
  relay epoch and anchor, and only after such a coupled write has landed
  cleanly does the `dot` surface carry the strip's anchor and the two
  loop as one unit. `linked_skew_ms` is the last measured gap between the
  Pro's and the Dot's writes reaching the devices (their fsync returns;
  11 ms on this Mac), always paired with `linked_skew_at`, the epoch it
  was measured; both appear or neither does. It is a diagnostic only
  since 2026-09-24: the Dot's phase comes from the strip's recorded start
  (see "Keeping the Dot on the strip's beat"), and
  `linked_skew_corrected_ms` is no longer sent.
- `dot_link` (top level, always present) is the daemon's own word for the
  Pro + Dot link — the truth `devices_linked` can only guess at:
  `{state, role, error}`. `role` is the normalised `dot_role` (null when
  the link is off or there is no Dot); `error` is a short description of
  the last linked-write failure -- the exception class name, or the
  write's own error -- null otherwise. `state` is one of:

  | state | meaning |
  | --- | --- |
  | `off` | `devices_linked` is off; the Dot always renders itself |
  | `no_dot` | linked on, no Dot connected |
  | `no_strip` | linked on, Dot connected, role `extend`, no strip to extend — the Dot renders itself until one mounts |
  | `beacon` | role `asks`: the beacon needs no strip |
  | `solo` | role `status`: the Dot drives itself by choice |
  | `linked` | the link is in effect for an extend Dot beside a connected strip; the Dot carries the strip's anchor once a coupled write has landed clean (`linked_skew_ms` appears then) |
  | `failed` | role `extend`, both devices connected, and the Dot's half of the last linked write failed (`error` says how) |

  Additive (2026-09-24), with `state` `linked` only -- the pair's timing,
  measured, so the app never has to claim "in step" on its own:

  | field | meaning |
  | --- | --- |
  | `phase_error_ms` | how far the Dot's phase is from the strip's right now, ms, signed (positive: the Dot is ahead); predicted between fresh reads from the Dot's measured clock; null before the first timed Dot write. Drift alone does not re-send the frame: the daemon sends it when the error reaches another 5 ms step or crosses `tolerance_ms` |
  | `clock_rate` | the rate the Dot's program is written for, in Dot-ms per real ms (0.9734: 2.66% slow); 1.0 with clock correction off |
  | `clock_source` | `measured`, `warm` (the saved rate or the 0.9734 warm start), `frozen` (fresh reads stopped moving; re-anchored blind every 60 s) or `off` |
  | `tolerance_ms` | `linked_sync_tolerance_ms` in effect |
  | `last_sync_at` | epoch of the last timed Dot write |
  | `sync_writes_hour` | Dot-only re-anchors in the last hour |
  | `rotation` | how the last Dot write was rotated: `exact`, `snapped` (at a line boundary, to fit the 512-byte budget) or `unrotated` |
  | `check_until` | while Check sync runs, when it ends (epoch, fixed when the check starts); null otherwise |
  | `style` / `rung` | `dot_extend_style`, and the period lock's rung: `brightest`, `average`, `soft`, `static` or `continue` |

- `device_receipts` (additive, 2026-09-24; absent when empty) is keyed by
  device id: `{foreign_write_at, foreign_writes, paused}`. At the reassert
  cadence (never faster) the daemon reads the device's `LEDS.LED` past the
  host's cache and compares it with what it last wrote; a mismatch is
  another writer (upstream's app, a shell `echo`). The first is written
  over at that reassert and noted here; a second inside ten minutes sets
  `paused` and the daemon stops rewriting that device until its own next
  change, so two apps never fight over the flash. The strip and a Dot
  drawing its own display are checked. A linked Dot is not: it is only
  written with a strip restart or by the closed loop, and reading it on the
  write worker the strip shares would stall the strip, so its card never
  carries this receipt.
  `no_dot`/`no_strip`/`failed` are the states a settings toggle cannot
  express: unplugging the strip the Dot was extending forgets the strip's
  last program with it — the Dot's next request falls through to its own
  display rather than looping a ghost, and the frame drops to `no_strip`
  with no `hardware` surface and no `role` on `dot`.

### event
Transient things the app should react to once. The daemon states the fact
and leaves sounds and banners to the app's `EventPolicy` (it never posts a
macOS notification or plays a sound itself in headless mode), so `notify`
and `sound` are usually absent; `sound: "glass"` marks the chime edge of
`escalation_stage` 3. The app's `EventPolicy` holds sounds by
`focus.audible_allowed` and banners by `focus.banner_allowed`, and admits
either by kind class through `focus.outbound`: `ask_opened` and
`escalation_stage` are asks, `failed` is critical, and `completed` and the
`quota_*` kinds are courtesy. That hold never withdraws a banner already
delivered and never touches the status pulse.
```json
{"t":"event","v":1,"id":"ev-12","kind":"completed","session":"…","provider":"claude","label":"jr-bar-b7","detail":null,"at":…,"cursor":"1234-abc123:ev-12"}
{"t":"event","v":1,"id":"ev-13","kind":"escalation_stage","session":"…","label":"sidepulse-core","stage":3,"sound":"glass","at":…,"cursor":"1234-abc123:ev-13"}
```
A `completed` event may also carry two facts for the finish banner, both
absent when the daemon does not have them: `duration`, the seconds the
session ran when the daemon saw both ends of the run (the same number
`list_history` rows carry), and `summary`, the first line of the agent's last
message when the session ended on a `Stop`. The summary is plain words: markdown
markers are gone, token-shaped runs read `[removed]`, and it is at most 140
characters. It rides the live event only; it is not in the activity ledger,
`list_history`, a log or a webhook payload, and a session that ended any other
way carries none.

Every event carries `cursor` — its own resume point in the daemon's
journal (`<stream>:<event id>`). The journal is written under the same
lock as the socket fan-out, so the suffix a `replay_events` call returns
is exactly what the wire carried, in order, with nothing dropped in
between.
Kinds emitted today: `completed`, `failed`, `quota_crossed` (from the
activity ledger), `ask_opened`, `ask_resolved` (from the ask set changing
between refreshes; `detail` carries the summary; both carry `request`,
the episode's canonical identity, when the ask is canonically modelled —
a session whose pending request was REPLACED emits `ask_resolved` for the
old identity then `ask_opened` for the new one rather than silently
reusing the slot, so every surface keys one request to one interruption
episode), `escalation_stage`
(`stage` 0…3), `device_connected`, `device_disconnected` (`label` is the
device name, `detail` its id; keyed by name, so a device whose id moves
from its mount path to its firmware serial is not a disconnect/connect
pair), `deck_input` (`input: {index, kind, at}`, nested because the
envelope's `kind` is the event kind; `label` is the control's name; one
per observed control, whether or not input check is on) and
`deck_receipt` (`code`, `message`: every keymap setup result and every
change of the output service's reason, `ready`, `reconnecting`,
`device_conflict`, …, with the Python app's sentence; the same receipt
sits on `state.deck.device.receipt`) and `usage_history_ready` (`provider`,
`range`, `records`, `scanned_at`, `reading_files`; `label` is the provider, `detail` the
range: a `usage_history` reply that went out `pending` or `stale` now has
a fresh document behind it, ask again; with `reading_files > 0` the scan is
still working through large transcripts and the event repeats after each
bounded pass, see `usage_history`); `usage_history_failed` (`provider`,
`range`, `code`, `message`; `notify: false`) means a scan that owed a
completion failed. Keep the previous reading and observe its current status
with `usage_history {observe: true}`. A delayed failure event must not replace
a newer successful reading. Observation never starts or retries a scan.
The message is public copy and contains no exception details; `quota_reset` (`provider`,
`instance`, `label` such as "Weekly reset", `lane`: the usage lane that
refilled, `weekly` / `five-hour` / a product-scoped id ending in
`-weekly`, and `event_id`, the same id the celebration delivery and the
usage hooks carry; published on every confirmed reset regardless of the
celebration preferences, so the Usage Center can pulse the card and the
Confetti toy can fire on every confirmed provider window. Durable reoffers use the stable `event_id` as `id`, omit `cursor`, and carry `notify: false`. Repeated reoffers reach Confetti's settlement check without repeating normal event effects. Known reset boundaries schedule a read; a temporary transport failure or successful response still quoting the same ended window retains one 15-second recovery read. Advancing or removing the boundary cancels it. Authentication, permission and rate-limit gates remain in force. A reset whose boundary passed
between two reads fires at once. An ordered old-window read at or within 30 seconds after that boundary, followed by a new active window within the same 30 seconds, also counts as TIMING. Existing identity, source, account and replenishment guards still apply; a jump of 50 points or more without the
boundary passing waits for a confirming read at least 60 s later (asked for
inside 30 min, still accepted for a day, so a sleeping laptop loses nothing)
whose reset time matches within two minutes. A window whose boundary had
already passed when the previous read was taken (the source kept quoting the
ended window) and that now reads 90% or more waits for the same
confirmation — `provider_usage_qol.confirm_reset_events`); `quota_pace` (`provider`,
`lane`, `label` the lane's name, `remaining_percent`, `runs_out_at` and
`resets_at` as epochs, and `detail` in words, "30% left · runs out around
3:40 PM · resets 5:30 PM"; once per reset window, when a lane is newly
projected to run out before it resets, only while `quota_alerts_enabled`
is on and the courtesy and quiet gates let it through: the daemon's own
banner posts nothing headless, so the app's `EventPolicy` banners this
and History lists it); `peer_arrived` / `peer_departed`
(`label` is the machine name; the reachable-set diff after the first
applied refresh, never on daemon start).

Quota events may also carry `instance` and `instance_label`. The instance is
the configured source identity; the label is a safe caption from its visual
settings, not the collector's account label. Keep the existing `label` as the
quota window. Public History resolves captions under the current privacy
choice. Clients retain provider-only wording when caption metadata is absent
and keep notification identifiers independent of display captions.
`open_window` (`window`: `overview`, `usage` or `control-center`) and
`reveal_ask` go out when a Creator Micro key asks for one of the app's
windows or for the waiting ask, and only while an app is connected; with
none, the key's receipt is `app_not_connected`. The app runs them through
its command router the way it runs a `jrbar://` link and drops one older
than 10 s. Revealing an ask puts it on the panel; it never answers it.
`power` goes out once per power-log entry worth a line: `power` is the
entry's kind (`lease_ended`, `suspended`, `lid_hold_ended`, `slept`),
`detail` its reason (`expired`, `finished`, `thermal`, `battery`,
`low_power`, `agents_idle`, `policy`), `label` History's words for it ("Keep awake let
go", "Put the Mac to sleep"), `duration` the held stretch where there
is one and, on `lid_hold_ended`, `finished` the runs that finished during
it -- the lid-open report's "3 finished".
`milestone` goes out once when the opt-in milestone odometer
(`milestone_odometer_enabled`) crosses a step on a completion that
happened in the last two minutes -- history re-read after a restart
never fires it: `count` is the step just reached (the latest, when one
batch crossed several), `reached` every step this batch crossed,
`next_count` the step above it (absent at the top of the ladder), `label`
"Completion milestone" and `detail` "50 finished"; `provider` names the
agent whose completion crossed the step. The lights' own cue and
the toys (Confetti, the Aquarium) celebrate the same number from it:
Confetti fires it under its Milestones trigger, in that provider's colours.
`confetti` goes out once per `confetti` command the daemon journals (a
script, a hook or CI asking for a burst): `session` and `provider` when the
caller named a watched session or a provider -- the burst wears that
provider's colours -- `label` the session's name and `detail` the caller's
`reason` ("tests passed"). It is a request, not a trigger: the app's
Confetti toy fires it only while the toy is on, minds the room, and drops a
repeat inside its cooldown.

### settings
Full settings document, sent on connect and after every change from any
writer: the controller's `settings` attribute is a property whose setter
bumps `generation` and republishes, so a save from a menu action, a DND
schedule tick, a device being remembered, or a command all reach the app.
`document` is `AgentMonitorSettings.to_dict()`; `schema` is 3 for this
shape (`devices_linked`, `transcript_monitoring.pi` /
`transcript_monitoring.gemini` and `auto_dim` are additive). The app
renders Settings from this and never keeps its own copy.

`auto_dim` replaces night warmth: `{mode: off|schedule|display|ambient,
schedule: {start_minutes, end_minutes, fraction}, display: {min_fraction},
ambient: {min_fraction, lux_floor, lux_ceiling}}`, default `off` (today's
behaviour). It feeds `brightness_policy`'s `night_dim` stage: `schedule`
applies `fraction` inside the daily window (which may wrap midnight),
`display` follows the built-in display's brightness through the same
reader the per-device auto-brightness uses (never below `min_fraction`;
an unreadable display leaves 1.0), `ambient` reads the light sensor
through IOKit's HID event system (`min_fraction` at `lux_floor`, 1.0 at
`lux_ceiling`, linear between) and falls back to `display` when there is
no sensor. `set_setting` writes it by dot path (`auto_dim.mode`,
`auto_dim.schedule.fraction`); an unknown mode falls back to `off`.

Keys the app catalogued first and the daemon serves since 2026-09-10:

- `menu_bar_icon_style`: `agents` (default, a dot per live session),
  `meters`, `meters_percent`, `compact_percent`, `glyph`, `glyph_ring`,
  `glyph_label`, `orbit`, `hidden`. The status item's picture is the
  app's; the daemon only keeps the choice. An unknown value normalises
  to `agents`, the same default the app's `StatusIconStyle` uses
  (`tests/test_menu_bar_icon_style_default.py` pins the two together).
- `quota_alert_thresholds`: a list of percentages (`[90.0, 95.0]` by
  default) the crossing detector feeds `quota_threshold` activity rows
  from. `set_setting` takes a list of numbers; it comes back normalised
  (0 < x <= 100, sorted, deduplicated, at most four), and an empty or
  unusable list means the defaults.
- `cloud_ingest_token_path`: the daemon's bearer-token file for cloud
  ingest (`~/.local/state/jrbar/cloud-ingest.token`), a string. Read-only:
  it is a fact about the daemon added to the document at publish time,
  never a settings-file key, so `set_setting` on it replies `read_only`
  and `reset_settings` ignores it.
- `settings_seal`: whether the protected settings are sealed, and whether a
  foreign edit of one was ignored (see "Protected settings"). Read-only, like
  `cloud_ingest_token_path`: a fact about the daemon added at publish time.
- `scene_state`: read-only automatic scene state: `{revision, selected_scene,
  effective_scene, lease_id, until}`. `selected_scene` is the person's saved
  `active_scene`; `effective_scene` includes a live automatic rule. `lease_id`
  and `until` are null without an overlay. The opaque revision identifies
  manual scene or scene-pack intent within this daemon instance. It stays
  stable through acquire, renewal, release and expiry. An accepted manual
  write or reset, including a same-value write, invalidates automatic
  ownership. This fact is not persisted, cannot be written or reset, and
  may change in a settings frame at the same settings generation.
- `active_scene_pack`: the id of the installed Scene pack whose validated
  policy rows override the built-in scene's, or `null` for the built-ins.
  Written from Effect Studio's "Use this pack" row; a pack id that names
  nothing installed fails closed to the built-in policies.
- `rainstick_idle_enabled`, `rainstick_night_enabled`,
  `milestone_odometer_enabled`, `milestone_odometer_steps`: the opt-in
  ambient cues `ambient_effect_runtime` produces. Rainstick parks one dim
  advancing pixel while nothing else owns the strip (`_night` lets it run
  inside the night scene, which withholds it otherwise); the odometer
  plays a finite cue when the exact completion count crosses one of
  `milestone_odometer_steps` (positive ints, sorted, deduplicated, at
  most 16, default `[10, 25, 50, 100]`). All default off/empty-consented;
  an enabled odometer with no valid step stays dark.

Usage-source keys (additive, 2026-09-24; each decoded tolerantly by
`usage_source_settings.py`, so a bad field falls back to its default and
never costs the rest of the file):

- `usage_hooks`: `{enabled: false, rules: [{id, enabled, event (one of the
  seven, or "*"), provider (or null), threshold_remaining (or null),
  executable, arguments[], timeout_seconds (0.1–300, default 15), argv
  ("json" or "legacy")}]}`. `set_setting` writes it whole or by dot path
  (`usage_hooks.enabled`). A settings file with no `usage_hooks` but a v1
  `usage_event_hook_path` loads as one enabled rule with id `legacy` and
  `argv: "legacy"`. After that the rule follows the old key on every load:
  a new `usage_event_hook_path` (from `set_setting`, a hand edit or the
  legacy window's field) becomes the `legacy` rule's executable and turns
  the rule and hooks on, an empty one removes the rule, and a path with no
  `legacy` rule left adds it back. A rule the runner refuses stays in the
  document; `usage_hooks_status` says why. If the background worker cannot
  start, each admitted hook records an `error` with detail `did not start hook
  worker`. Work that never started does not spend its cooldown. A later event
  can retry; the failed event is not replayed automatically.
- `provider_display` (default null): shared app presentation preferences,
  `{order: [provider_id], hidden: [provider_id]}`. `order` ranks both the
  menu bar and panel; unlisted providers keep their incoming order after
  listed providers. `hidden` affects only the menu bar. Panel visibility
  remains the per-instance `panel_hidden` option. Write the whole object
  with `set_setting` so one drag changes one shared order atomically.
  Both lists contain unique lowercase provider ids, at most 128 entries
  each and 64 characters per id. Unknown ids survive for future providers.
  Socket writes require app authentication. The value is reviewed unsealed
  because it grants no capability. Invalid writes return `invalid_value`.
  Null allows a one-time
  import of the app's former `menuBarProviders` preferences; once imported,
  the daemon owns the value. These choices never enable tracking, grant
  usage consent, install hooks or make outbound requests.

- `provider_status_feeds_enabled` (default false): the provider status
  pages (`status.anthropic.com`, `status.openai.com`, `status.cursor.com`)
  are asked, every 10 minutes and only for a provider whose source was
  found, while this is exactly `true`. Off, no request is made, a running
  feed is stopped on the next usage refresh, and no `incident` string is
  stamped from a feed. Read live on every refresh; a non-boolean value
  loads as `false`.
- `provider_update_checks_enabled` (default false): "update available" for
  the agent CLIs. While this is exactly `true`, and only then, the daemon
  asks the npm registry (`https://registry.npmjs.org/<package>/latest`: one
  plain GET, a 5 s timeout, no cookies, no credentials, no redirects, a
  plain `JR-Bar/update-check` User-Agent, nothing about this Mac in it) for
  each installed CLI that has a package -- `@anthropic-ai/claude-code`,
  `@openai/codex`, `@xai-official/grok`, `@google/gemini-cli`,
  `opencode-ai`; Devin has none and is never checked -- every 6 hours and
  when `provider_update_check` arrives (at most once a minute). A newer
  version becomes `state.provider_updates[provider].latest_version`. Off, no
  request is made and no thread is started; it is read live, so turning it
  off stops the next check and clears `latest_version`. A non-boolean value
  loads as `false`. The Update button (`provider_update`) never needs this:
  it runs the CLI's own updater, which is the person's click.
- `ntfy_enabled` (default false), `ntfy_topic` (default empty) and
  `ntfy_only_when_away` (default true): the phone alert (`ntfy_alert.py`).
  Nothing is sent until the person has a usable topic AND `ntfy_enabled` is
  exactly `true`; a non-boolean loads as off, and a topic that is not a
  string loads as empty. `ntfy_topic` is a bare topic name (sent to
  `https://ntfy.sh/<topic>`) or a full `https` URL of the person's own ntfy
  server: port 443 or 8443, no credentials, query or fragment, exactly one
  path segment for the topic, no `localhost` and no private address literal.
  When an agent starts waiting on the person (the ledger's `asked` edge) or a
  whole run finishes (the completion edge), and the quiet policy lets a
  notification-webhook effect through, the daemon POSTs one fixed plain-text
  line, `<Provider> needs you` or `<Provider> finished`, with the provider's
  name from the daemon's own table (`Claude`, `Codex`; `An agent` when it has
  none), the title `JR-Bar` and a `JR-Bar/<version>` User-Agent. Never prompt
  text, a path, a project or session name, a token or an account id. With
  `ntfy_only_when_away` on, the line goes only while the screen is locked or
  the Mac has been idle for five minutes (read from the session, no input is
  posted), or while the app's presence report says the same; when the daemon
  cannot tell, it does not send. The same agent and line is sent at most once
  per 20 seconds and no more than 30 lines an hour. No redirect is followed and
  nothing is retried. It only notifies: no reply is read, and nothing on the
  phone answers an ask.
- `claude_statusline_source` (default false) lets Claude Code's statusLine
  readings stand in for OAuth; `statusline_text_enabled` (default true)
  keeps `statusline.txt` written while the source is on.
- `cliproxy_hub`: `{enabled: false, url: "http://127.0.0.1:8317",
  min_interval_seconds: 300}`. A non-loopback URL is kept but refused at
  collection time; the interval is clamped to 300–3600. The management key
  is never here: it is the Keychain's (`providers credential set cliproxy
  management`).
- `provider_extra_homes`: `{claude: [absolute folders], codex: [...]}`,
  extra account homes scanned beside `CLAUDE_CONFIG_DIR` / `CODEX_HOME`
  and the defaults; homes that resolve to one folder count once.
- `pricing_overrides`: `{model: {input, output, cache_read?,
  cache_write?}}` in USD per million tokens; a model needs an input and an
  output price. An override wins over `resources/model_pricing.json`.
- `keep_awake_yield_low_power_mode` (default true): a keep-awake lease is
  suspended with reason `low_power` while macOS Low Power Mode is on.

```json
{"t":"settings","v":1,"generation":17,"schema":3,"document":{…}}
```

Legacy-only settings: the daemon still loads, normalises and re-emits
each of these, but only the retired Python settings window ever
wrote them -- the app has no control for any of them, so a value there
today keeps working exactly as configured:

- `calendar_alerts_enabled`: the calm purple glow before a calendar
  event runs (enabling it is what presented the system Calendars
  prompt).
- `calendar_lead_minutes`: how many minutes ahead of the event the
  calendar glow starts (clamped 1–60).
- `reminder_alerts_enabled`: the amber glow when a Reminder comes due
  (the system Reminders prompt).
- `tips_enabled`: the legacy tip tour may run (default on).
- `dismissed_tips`: the tip texts already dismissed.
- `codex_percent_enabled`: Codex quota leads with a percentage.
- `lid_closed_animation`, `lid_open_animation`,
  `lid_closed_active_animation`, `lid_open_active_animation`: the LED
  programs the daemon plays on lid close/open, idle and
  agents-running variants (`lid_animation_for`).
- `colors.color_by_project`: session identity colours follow the
  session's project.
- `colors.session_colors`: per-agent colour overrides.
- `colors.mode_animation`: the animation style each mode renders with.
- `colors.speed_overrides`: per-blend-mode cycle-speed overrides.
- `colors.round_robin_urgency_alert`: an urgency alert rotates across
  the strips instead of painting all of them.
- `signal_styles`: per-signal look overrides (Signal Engine
  `SignalStyle` rows; absent keys are the built-in defaults).
- `focus_signal_policy`: which signals a Focus may pass through.
- `focus_profile_rules`: Focus id → calibration profile slot applied
  when that Focus activates.
- `global_action_shortcuts`: the chord the retired daemon hotkey registry
  held for `reveal_current_ask`. The app reads it once to adopt it (see
  `AppShortcutCatalog.legacyRevealAskChord`). Nothing in the daemon
  registers or writes it, and a settings save keeps the entries that are
  already there.
- `studio_program`: the hand-written Studio LED program, kept verbatim.
- `studio_library`: the named Studio programs shelf.
- `notification_policy_version`: which notification-policy migration
  has already run.
- `completion_notification_enabled`, `quota_alerts_enabled` (both on for a
  new install and for a file that never wrote them; a stored value, off
  included, is kept) and `escalation_tier`: the three switches the app's
  Alerts profile (Quiet, Balanced, Loud) sets together. None is sealed
  and none sends anything off the Mac.
- `silent_session_banner_enabled` (default off): the app posts one local
  banner when a working session has sent nothing for ten minutes with no tool
  call open. The app counts the silence from `sessions[].since` and `event`;
  the daemon only stores the choice.
- `screen_bar_gauges_enabled`: the Screen Bar's wing-tip micro-gauges.
- `screen_bar_bracket_style`: how the Alcove bracket colours itself
  (`auto`/`spatial`/`identity`/`bracket`).
- `virtual_status_device_wraps_menu_bar`: extends the Screen Bar's glow
  past the notch toward the menu bar's edges -- the app reads it, no
  control yet.

### reply
Answer to a command.
```json
{"t":"reply","v":1,"id":"c-42","ok":true,"result":{…}}
{"t":"reply","v":1,"id":"c-43","ok":false,"error":{"code":"not_found","message":"no such session"}}
```
Error codes: `unauthenticated` (a privileged command on a connection that is not the app's), `auth_failed`, `auth_unavailable`, `auth_replayed` (the `auth` command), `unknown_command`, `bad_frame`, `bad_command`, `internal`,
`not_found`, `not_frontmost`, `invalid_args`, `invalid_path`,
`invalid_value`, `read_only`, `refused`, `expired`, `busy`, `unsupported`,
`frame_too_large` (any command whose answer would not fit in one 1 MiB
frame; nothing is sent but the error, so ask for less, or for a page);
`answer_ask` adds `accessibility_required`, `session_gone`, `stale_ask`,
`stale_request` and
`send_failed` (see below); the Effect
Studio commands add `unknown_effect`, `invalid_scope`, `invalid_target`,
`reserved_semantic`, `invalid_pack`, `conflict`, `export_failed`,
`usage_history` adds `invalid_range`, and the deck commands add
`input_check`, `invalid_plan`, `no_device` and the keymap receipt codes
(`connection_required`, `device_conflict`, `recovery_required`,
`keymap_changed`, `readback_mismatch`, `backup_failed`, `backup_invalid`,
`backup_conflict`, `approved_device_changed`, `previous_owner_stopping`,
`unsupported_file_protocol`, `setup_failed`, `superseded`, …) whose
`message` is the Python app's sentence for that receipt. `superseded` means
the deck's settings changed (or the daemon began stopping) while a setup
was running, so its result was dropped; the command answers at once and
asking again is safe.

### log
Content-free diagnostics for the app's log view: every `log_status_bar`
line the controller writes, mirrored. Bounded to 2000 characters a line.
```json
{"t":"log","v":1,"level":"info","message":"leds=SidePulse Ask target=/Volumes/SidePulse/LEDS.LED","at":…}
```

## App → daemon

### command

Usage providers and compatibility sources are separate identities. T3 Code is
a compatibility integration. Its name is never a provider or an inferred
agent driver. A v2 provider instance name is user-defined; the bound provider
thread's driver identifies a current native provider. Historical attribution
uses the turn's persisted native driver, never a mutable current registry
entry. Generic ACP records remain unattributed unless their persisted record
identifies the actual agent.

`usage_graph` may add `graph.source_statistics`, an array of source readings.
Each row contains `source_id`, `label`, `attribution_status` (`attributed`,
`unattributed` or `mixed`), nullable `tokens` and `sessions`,
`included_tokens`, `included_sessions`, `data_status` (`available`, `partial`
or `unavailable`), confirmed `provider_ids` and `detail`. Missing counts mean
unavailable, never zero. Counts describe the loaded range. Included counts
describe that source's contribution to selected provider series; they are a
subset of the source reading and must not be added again to provider totals.
For T3 source readings, `sessions` and `included_sessions` count distinct T3
threads. A thread switching providers still counts once in that source row.
Clients label these source counts as threads; provider charts retain their
session counts. Unattributed T3 history remains in source readings instead of
provider series. A failed read stays partial and retries without turning
missing counts into zero. Cache fingerprints include SQLite WAL changes.
Stable omissions, such as a record cap or persisted partial turn usage, may
reuse a cached document while remaining labeled partial. Failed and
interrupted reads retry even when the source fingerprint is unchanged.
Native records take precedence over an imported supplement for the same
provider and range until stable cross-source deduplication is established.

A provider series may carry `source_id: t3code` when its values came from
that integration. Clients can say "from T3 Code" while retaining the actual
provider name. Compatibility availability, completed-turn usage and account
quota are independent capabilities. A successful source poll does not renew
agent activity. A recorded requested model is not proof of the resolved model
and must not establish historical pricing.
`sessions[].source_integration` may be `t3code` when the session's validated
work identity names that adapter. Clients can show "from T3 Code" beside the
actual provider. Origin labels and user-defined instance names do not supply
this fact. Native sessions omit the field.

```json
{"t":"command","v":1,"id":"c-42","name":"open_session","args":{"session":"claude:session:…"}}
```
Commands are parsed on the socket thread and run on the AppKit main thread
(`performSelectorOnMainThread`), one at a time, in order per client --
except the slow-lane reads `usage_graph`, `usage_history`,
`session_timeline`, `list_history`, `compare_sessions`, `session_usage`,
`doctor`, `firmware_status` and `firmware_update` (they read a device's
`STATUS.TXT`, which a stalled SD reader can hold for seconds), and the click
`provider_sign_in`. Those queue on daemon-wide workers at utility QoS and each reply
by `id` when it is done, so a reply to a later command can arrive first and
a scan never holds up an `answer_ask`. There are four lanes, each with one
worker. The scan lane carries `usage_graph` and `usage_history`, in order
among themselves, so two scans never overlap. The read lane carries
`session_timeline`, `list_history`, `compare_sessions`, `session_usage`,
`doctor`, `firmware_status` and `firmware_update`, in order among themselves
(the update itself runs on a thread of its own, so the reply to
`firmware_update` comes as soon as the device has been read), so History opens while the Overview's
graph is still being built. The action lane carries `provider_sign_in`: it
is a click, not a read, and it can wait up to 90 s on Claude Code, so it has
a lane of its own and nothing else the app sends waits behind it (a client
allows it a reply time of about two minutes). `mark_history_seen` queues on the read lane (it
still runs on the main thread when its turn comes), so a `list_history`
sent before it computes `unseen` against the old watermark. Past 32
queued on a lane, a new command for that lane is refused `busy`; a backlog
of scans never makes a read busy.
The Deck lane carries `deck_plan_keymap`, `deck_apply_keymap`,
`deck_restore_keymap`, `deck_approve_device`, `deck_disable` and
`deck_set_settings`. It admits one operation across all clients and
refuses another with `busy` immediately. It has no backlog, so a device
write cannot wait in a queue and run later. Setup and settings share this
worker; person-triggered `deck_answer` and `deck_press` keep their existing
dispatch. Each setup phase allows 60 seconds. The app allows 65 seconds
for Plan and Restore, 125 for Apply's inspection and write, 22 for approval's
probe and save, and 20 for Disable's save. Settings keeps the ordinary
client budget; its main-thread completion has no daemon time bound.
`install_hooks` / `uninstall_hooks` run on the socket thread because the
Codex trust handshake can take seconds, and so do `open_session` and
`resume_session`, whose osascript and tmux calls can wait on a first
Automation consent prompt (the controller state they read still hops to
the main thread). Unknown args are ignored.

Factory browser connections store bounded JSON in the instance-scoped
`web-session` Keychain credential. The JSON contains `refresh_token`,
optional `access_token`, optional `organization_id`, optional allowlisted
`client_id`, `browser`, `profile`,
`consent_version: 1`, and an optional opaque `identity` after `auth/me`
proves both user and organization. Generic credential set/delete commands
refuse this account. A saved browser session has priority over the optional
API key. Invalid or rejected sessions never fall back to an API-key account.
The browser owns token renewal. JR-Bar never sends the imported refresh token
to WorkOS. With usage enabled and consented, it uses the access token for
Factory account and billing requests. If the exact browser, profile and
provider instance also have a background-repair grant, each collection may
read that profile's current access token. A 401 permits one more local read
and a retry only if the token changed. Without that grant, an expired token
reports `browser_refresh_consent_required`, with `needs_consent`.
Account continuity must pass before saving the access token or reading quota.
Fingerprint checks prevent a read from overwriting a new connection or a
disconnect. A final check after billing rejects readings for a session that
changed during the request. No network call holds the session lock. A 400
from account or billing requests is an error, not evidence of a sign-out.


| name | args | effect / result |
| --- | --- | --- |
| `open_session` | session, action? | A session still running in a terminal is **raised, not resumed** (`answer_surfaces.py`): its tmux pane (`list-panes -a` matched by the session's tty, then `select-window`/`select-pane`, switching a lone client to that tmux session), its Terminal.app or iTerm2 tab (selected by tty over Apple events), or its Ghostty terminal (`focus` on the surface recorded when the session started, else the only terminal in the session's working directory, else the only one whose title carries the session's name; a tie brings Ghostty forward and never guesses); any other host app is activated. Reply `{session, activated, origin, raised: "pane"\|"tab"\|"terminal"\|"app", app, bundle_id, detail}`. Opening a Codex session also lets a request the decide lane holds for it fall through, so its prompt waiting behind the hook appears at once; a Claude hold stays, since its prompt is already on screen. A live session JR-Bar cannot find refuses `not_found` instead of starting a second process on it; the message names what it looked for -- the host app and its bundle id, the executables it looked through, or the tmux pane -- and ends "Nothing new was started." An ended CLI session whose open is a terminal resume resumes **in the terminal it ran in** (recorded at its SessionStart), not whichever app is in front: a new tab in Ghostty's front window at the session's directory with the resume command typed into the owner's own shell (a new window through the reviewed launch plan when Ghostty refuses the Apple event), or a new Terminal.app / iTerm2 window -- `raised: "new_tab"\|"new_window"`, `detail: "resumed"`. A remote row, a session hosted by its provider's desktop app, an explicit `action` of `app`/`vscode`, or a Clicks-open / provider-profile choice of `vscode` keeps the controller's `open_session` (provider URL, or `cd <cwd> && <cli> --resume <id>` in a terminal): `{session, activated, origin}`; a saved choice of `app` is for the sessions the app hosts, so a live session a terminal hosts is still raised. A session Claude.app runs opens as `claude://code/continue?session=local_…`, the id the app's own session store (`~/Library/Application Support/Claude/claude-code-sessions`, read-only) gives the CLI session, and lands on that session; with no match it is bare `claude://`. Automatic puts VS Code first for a Claude row only when LaunchServices has a `vscode://` handler. `action: "raise"` asks for the live path explicitly. |
| `answer_ask` | session, decision (`approve`/`deny`, or `always` for a held request that offers it, or `answer` for a held question), answers (with `answer` only: `{<question text>: <label>}` for every question in `ask.decision.choices`, a list of labels for a `multi` one), reply_text (optional, for `input` asks), request (optional — the ask's `request` identity; a live request that does not match refuses `stale_request` before anything is armed or typed), only_if_frontmost (default true) | A request the decide lane holds (`ask.decision` non-null) is answered first, through the agent's own `PermissionRequest` hook: `{session, decision, answered, delivered, code: "sent", message, confirmation: "provider_pending", mechanism: "permission_hook"}` -- see "The decide lane" below. Anything else is answered **in its own terminal** (`answer_local.py`, the `local.answer_in_place` surface the `answering` product capability binds to). A bare `decision` posts the key that provider's CLI takes at its permission prompt. Claude Code: `1` to approve ("1. Yes" is always the first row), `esc` to deny (the prompt's own "Esc to cancel"). Codex: `y` to approve ("1. Yes, proceed (y)"), `3` to deny ("3. No, and tell Codex what to do differently"). With `reply_text` (non-empty printable, normalized to one line, at most 280 chars) the action becomes `reply`: the text is typed into the same verified window via `CGEventKeyboardSetUnicodeString` and submitted with Return -- same frontmost/ancestry/tty/accessibility fences, `mechanism: "synthetic_text"`, and the reply reports `decision: "reply"` plus `characters` instead of a key. A `reply_text` on an ask whose capability does not take text is `unsupported`. Only `codex/hooks` and `claude/hooks` declare the capability; any other provider is `unsupported`. Every fence is affirmative-only: unknown liveness (`liveness_unproven`), unwalkable ancestry (`ownership_unproven`), an unresolved session tty (`session_tty_unknown`), and a terminal that cannot name its focused tab (`focused_tab_unproven` -- kitty, WezTerm, Alacritty have no such call; Ghostty proves its focused terminal by it being the surface recorded at the session's SessionStart, and a session with no recorded surface stays unproven -- the only terminal in the session's directory is not proof, since a plain shell the owner opened there looks the same) all refuse; there is no send-anyway path. The reply waits for the real outcome, so `answered: true` means the key went out: `{session, decision, answered, mechanism: "synthetic_keystroke", key, key_code, meaning, confirmation, host{pid, tty, app, app_pid, window_evidence}}`. `confirmation` is `provider_pending` on a posted key -- an attempted delivery, not a confirmed approval; the provider's own stream closing the request is the only proof it landed -- and `none` on a refusal. `window_evidence` on a sent answer is `focused_tab_tty` (the terminal named the focused tab and it is this session's) or, in Ghostty, `recorded_surface` (its focused terminal is the one the session started in, still in the session's directory). See the refusals below. |
| `snooze` | session or `all`, seconds, scope (`family`, the default, or `run`) | Mailbox snooze for the session's family (presets: ≤ 900 s → 15 minutes, ≤ 3600 s → 1 hour, else tomorrow morning; 0 unsnoozes). `{sessions, until, scope: "family"}`. `scope: "run"` ("Quiet this run") quiets that one row instead -- a main session or a single worker, on its exact work key (`snooze_scope: "run"` in `mailbox-preferences.json`), for exactly `seconds` (a week at most) -- so quieting a sub-agent never silences the session that spawned it, nor its siblings, and the family's shelf stays. It needs a named session (`all` is `invalid_args`) whose row has a work key (else `unsupported`); `seconds: 0` lifts it. `{sessions: [id], until, scope: "run"}`, `until` being whatever now quiets the row (its own deadline, or the family snooze already in force on that key, which a run snooze never replaces since that would wake the rest of the family; null when nothing does). Either way a live ask still breaks through, and the row's `snoozed_until` is the later of its family's deadline and its own. A family unsnooze of a named session (or `all`) also lifts that row's own run snooze, so Unsnooze always clears what the row shows. |
| `clear_completed` | sessions[] or `all` | Acknowledges every row `sessions` is currently listing as over -- `completed`, `ended`, and any stale row -- through the Clear Agents plan/commit machinery with widened eligibility (`clearable_presentation_key`). Afterwards `sessions` holds only live rows and the rest are in `list_history`. `sessions` may name a subset; a named row that is not clearable (a live session) is simply not in the batch. Live sessions, asks, failures and worker rows are fenced as protected and never cleared. `{batch, cleared[]}` with every acknowledged session id, or `{batch: null, cleared: []}` when nothing was over. Refuses `busy` while a clear is in flight. |
| `undo_clear` | batch | Remove that batch's acknowledgement receipts within its 300 s window. The receipt survives a daemon restart. Visibility is recomputed from current activity, preserving newer work. `{batch, restored[]}`; `expired` after, `not_found` for another batch, `refused` if already undone or invalidated by newer receipt writes. |
| `set_setting` | path, value | Dot-path write (`colors.agent_colors.claude`, `devices.0.brightness`) into `to_dict()`, re-validated through the real settings loader, saved, side effects applied (closed-lid, cloud ingest, transcript monitoring, remote peers), then a refresh. `{generation, path, value}` with the value as normalised. A read-only key (`cloud_ingest_token_path`) replies `read_only`. The reply comes first: the new `settings` document is out before it, the file is written by the persistence writer right after (a burst writes once; an I/O error is retried on the next refresh and at quit), and the refresh runs after the reply, so the `state` and `lights` that show the change follow it. A write refused for good (a settings file from a newer version) is logged once and not retried; the value stays live for the session. A write that lost to an outside edit of `settings.json` (a hand edit, a restore, `jrbar battery configure`) is not retried either: the next refresh adopts the file when it parses and validates, keeps what the daemon held as `settings.json.replaced`, and sends the `settings` document again, so Settings shows what is on disk. This happens the next time the daemon saves a setting, not the moment the file changes. A file that does not parse is looked at again one refresh later, in case an editor is still saving it; if it has not changed, it is set aside as `settings.json.corrupt-<UTC stamp>` (the newest three kept) and the daemon's settings are written out again. A save refused because the file cannot be read right now (a half-written save) is retried on the next refresh and at quit. |
| `reset_settings` | paths[] | Each path back to `AgentMonitorSettings()`'s default. `{generation, reset}`. |
| `set_brightness` | device or `all`, value 0..1 | `set_device_brightness` (turns auto-brightness off, as the slider does). |
| `set_device_display` | device, mode | `agent`, `battery`, `studio`, `quota_runway`. |
| `apply_calibration` | device, profile {red_gain, green_gain, blue_gain, resting_glow, brightness?} | Per-channel gains (0.3…1.5), resting glow (0…0.35) and device brightness (0…255) for that device, clamped and persisted; the reply's `profile` echoes what actually persisted plus `generation`. Ends any held calibration preview for the device. `not_found` for an unknown device, `invalid_args` for a non-numeric field. |
| `preview_program` | surface (`screen_bar`, `hardware`, `dot` or a device id), program, seconds (0.2…30) | Writes the program to the matching strip(s) now and marks the surface `why: preview` in `lights`; after `seconds` the daemon refreshes and the live program returns. Refused with `busy` while a held `preview_calibration` owns the surface or any target device -- a 3 s flash cannot be allowed to paint over a 10-minute calibration hold. |
| `preview_calibration` | device, gains {red, green, blue} (0.3…1.5, clamped), resting_glow? (0…0.35), brightness? (0…255, default the device's stored brightness), patch? (`white`/`red`/`green`/`blue`/`grey` or `#RRGGBB`, default `white`), companion? (default false) | Shows the nominal patch through the GIVEN values -- resting glow, channel gains and brightness applied once through the device's own write boundary, never the stored profile on top. Held daemon-side for 600 s (re-armed on every call) so the sheet can sit open while the eye decides; live writes for the held device(s) are suppressed meanwhile. For `virtual:status-bar` the transform is the Screen Bar's code-domain one and the hold lands on the `screen_bar` surface. `companion: true` on a Dot also lights the followed strip with the same patch through the strip's STORED profile, so the Dot can be matched to it by eye; the reply's `companion` names that strip (or null). `{device, surface, until, program, companion}`; `not_found`/`invalid_args` on errors. |
| `end_calibration_preview` | device | Drops the held preview(s) that device owns -- its own and a companion strip's -- clears the dedupe identity the preview bytes left, and re-arms the live program. Idempotent: `{device, ended}`. |
| `apply_effect` | effect, scope, target, parameters? | Effect Studio assignment (`EffectAssignmentRecord.create`); `effect` null or `"none"` removes it. Protocol-1 alias of `set_assignment`/`clear_assignment`: answers the same fuller assignment document, parameters sidecar included. |
| `refresh_usage` | providers[] | Forces a provider usage refresh; the next `state` carries the result. |
| `reset_receipt` | event_id, outcome, reason? | The app's account of a `quota_reset` it was sent: `outcome` is `delivered` (the burst was on screen), `held`, `dropped`, `expired` or `suppressed`, `reason` one word. Recorded on the event in `provider-reset-events.json`, so a celebration that never landed is visible there. `delivered` and `dropped` close the greet's replay offer; a later `delivered` overrides an earlier `dropped`. The others leave the reset re-offerable. `not_found` for an unknown `event_id`, `invalid_args` for an unknown outcome. |
| `reset_status` | retry? | Read at most 16 pending app resets with original `at` timestamps and canonical IDs, plus `remaining` and reset-save `persistence`: revision, dirty, in_flight, retries, retry_at, error. Reads do not settle events. `retry: true` starts a new bounded save attempt for the current revision. `reset_receipt.recorded` means the owner accepted the in-memory receipt; its `persistence` describes queue admission, not synchronous durability. |
| `usage_hooks_status` | — | The Settings Hooks section's truth (lane oss, 2026-09-24): `{enabled, problem, events[], rules[{id, enabled, event, provider, threshold_remaining, executable, arguments[], timeout_seconds, argv, problem, last_result}]}`. `problem` on a rule says why it will never run (a relative executable, an unknown event, more than 32 arguments, a string over 4 KiB); `problem` on the document is set when more than 32 rules make every rule refuse (fail closed). `last_result` is `{rule, event, provider, at, outcome (ok, exit, timeout, refused, error), exit_code?, duration_seconds?, detail?, sentence}`, kept in memory while the daemon runs. Off the main thread. |
| `usage_hooks_test` | event (one of the seven), provider, rule? | Runs the rules a made-up event would match (or just `rule`), whatever the master switch says, with `state: "test"` in the event, and waits at most 8 s: `{event, provider, results[…last_result shape…], status}`. `invalid_args` for an unknown event or rule. The Test button. Off the main thread. |
| `list_providers` | provider?, instance? | The inspect surface behind `jrbar providers status`: one row per configured provider *instance* — `{id, instance, label, enabled, usage_consent, menu_visible, browser_sources_enabled, supports_browser_sources, supports_local_tokens, supports_quota, source_order, options, consents[], credentials[], imported_credential, state, reason, action, account_label, observed_at}`. `consents` carry `source_instance_id` so a row only lists the grants its own instance holds; `credentials` report `{account, available}` — availability, never the secret; `imported_credential` says the stored token came from a consented browser import (the only credential a revoke may remove). `state`/`reason`/`action` mirror the live snapshot for that exact instance. `usage_consent` (additive, 2026-10-07) is the per-provider switch for the read that asks the provider's servers for usage, or reads another app's sign-in to do it: `{granted, version, source, at, required_version, question, summary, detail, hosts[], credential}`. `granted` is true only while `version >= required_version`; `source` is `setup`, `settings`, `cli`, `usage_center` or `migration` (an upgrade that kept a provider that was enabled and already returning usage); `at` is when the person said yes (null for a migrated one). `question`, `summary` and `detail` are the plain sentences Setup and Settings show verbatim, `hosts` is who is asked (empty when nothing leaves the Mac) and `credential` is whose sign-in the request carries. Every provider starts with `granted: false`. |
| `factory_session_profiles` | none | Lists up to 256 existing supported browser profiles as `{profiles: [{browser, profile, label}]}`. Reads directory metadata only, never sessions or remote services. Privileged local worker command. Errors `invalid_args`, `unavailable`. |
| `factory_session_import` | browser, profile, instance?, confirm, background_repair? | Requires `confirm: true` after disclosing access to the selected profile's `app.factory.ai` and `auth.factory.ai` local storage fields `workos:refresh-token` and `workos:access-token`, and storage in JR-Bar's instance-scoped Keychain `web-session`. Confirmation authorizes one bounded local read. Optional `background_repair: true` also authorizes continued reads of that exact profile for this provider instance; it defaults to false and must be disclosed separately. Browser refresh tokens are never consumed. No remote request, API key change, usage enable, or usage consent change. Reply `{provider: "factory", instance, message}`. Errors `invalid_args`, `unknown_instance`, `browser_session_not_found`, `credential_unavailable`, `unavailable` contain no secrets. Missing sessions ask the person to sign in at `https://app.factory.ai` in the selected profile and import again. Privileged local worker command. |
| `factory_session_disconnect` | instance? | Removes only this instance's JR-Bar Factory `web-session` and bound browser grants. Leaves API keys, other instances and usage settings unchanged. Reply `{provider: "factory", instance, message}`. Errors `invalid_args`, `unknown_instance`, `credential_unavailable`, `unavailable`. Privileged local worker command. |
| `set_provider_credential` | provider, account, secret, instance? | Stores one explicitly supplied native-provider credential in JR-Bar's Keychain entry for that configured instance. Privileged local command. Provider and credential kind must be registered; instance defaults to `default`. Factory `web-session` writes and deletes require its dedicated commands. Secret is a trimmed, nonempty single-line string up to 64 KiB. It is never returned, logged, journaled, or placed in state. Saving does not enable usage, grant consent, or schedule a provider request. Reply `{provider, instance, account, available: true}`. `invalid_args`, `unknown_provider`, `unknown_instance`, `credential_unavailable` are sanitized errors. |
| `delete_provider_credential` | provider, account, instance? | Removes that instance's JR-Bar-owned credential without changing provider settings or consent. Privileged local command with the same provider/account/instance validation. Reply `{provider, instance, account, available: false, removed}`; removing a missing key is a successful no-op. It never journals credential arguments or returns a secret. |
| `set_provider_enabled` | provider, enabled, instance? | Persists the per-instance enabled flag through the settings document's optimistic concurrency — a concurrent edit answers `settings_changed`, never a silent merge; `unknown_instance` when no configured instance exists. `{provider}` is the row as persisted, and an enable triggers a usage refresh for that provider. |
| `set_provider_usage_consent` | provider, enabled, instance?, source? | The per-provider usage switch (additive, 2026-10-07). `enabled: true` records the person's consent (`usage_consent.version` = the build's `required_version`, `source` one of `setup`, `settings`, `cli`, `usage_center`, default `settings`) and turns the provider on; `enabled: false` withdraws it and leaves the provider's local figures (token totals, Claude Code's status line) alone. Persisted through the settings document's optimistic concurrency like `set_provider_enabled` (`settings_changed` on a concurrent edit, `unknown_instance`, `unknown_provider`, `invalid_args`), and it forces a usage refresh for that provider. `{provider}` is the row as persisted, in the `list_providers` shape. Until a provider is on, its snapshot is `state: needs_consent`, `reason: usage_not_turned_on`, `action: "Turn on <Provider> usage"`, with no lanes and no incident: nothing is asked and no sign-in is read. `provider_action` and `provider_sign_in` for such a provider refuse with `usage_off` and the sentence to show. |
| `set_provider_options` | provider, options, instance? | Saves a partial patch of non-secret usage source options through optimistic concurrency and returns `{provider}` as persisted. Every provider accepts `panel_hidden: "true" or "false"`. Claude accepts `cli_fallback: "true" or "false"`, reserved with no effect in 0.10.0 and omitted from `list_providers.options`. Kimi accepts `region: china or international` and `source: auto, api, web or cli`. Kilo accepts `organization_id`, a printable identifier of at most 128 ASCII letters, numbers, dots, underscores, colons or hyphens; an empty string removes it. Other keys or values are `invalid_args`; unconfigured instances are `unknown_instance`, unknown providers are `unknown_provider`, and concurrent edits are `settings_changed`. Existing unrelated options and consent are preserved. Changing these options never grants usage consent. The affected instance is refreshed through the existing consent gate. `list_providers.options` includes these non-secret values. |
| `provider_add_instance` | provider, instance, label? | Configures one more account for a provider (a second Codex or Claude sign-in, say). The instance starts enabled and metered with browser sources off; `label` is optional, not blank, at most 128 characters with no control characters, and defaults to `<Provider> · <instance>`. It is written through the settings document's optimistic concurrency, like `set_provider_enabled`, and forces a usage refresh for that provider. `{provider}` is the new row in the `list_providers` shape. `unknown_provider` for an unregistered id, `unsupported` for a provider that reads this Mac's own sign-in and has no per-instance source (a second account would report the first one twice), `invalid_args` for a missing or malformed `provider`, `instance` or `label` and for the `default` instance every provider already has, `already_exists` for an instance already configured, `settings_changed` for a concurrent settings edit. |
| `provider_consent` | action (`list`/`grant`/`revoke`), provider?, browser?, profile?, instance?, background_repair? | The exact-scope consent store. `grant` binds provider + browser + profile + the provider's declared domain/field allowlist and imports nothing — the import remains its own action. `list` returns `{consents[]}`; grant/revoke return `{consent}` with the bound scope, `was_granted`, and on revoke `imported_data`: `removed`/`replaced`/`retained`/`none` — the imported credential is deleted only while the stored value still matches the import's digest, so a user-replaced token survives. `unsupported` for providers with no consented browser source. |
| `provider_action` | provider, instance?, action? | `action` accepts `resign_in`, `hide`, or `open_app`. Runs the staged flow behind the provider's CURRENT action label — clipboard/LevelDB import, reconnect, repair — and returns `{provider, instance, message}` with the exact string the daemon surfaced (it may be a success note, not only an error). `unsupported` when no staged action matches the live state, `unknown_provider` for an unregistered id. Ownership is preserved: a credential the provider's own CLI owns (Grok's auth.json, Gemini's oauth_creds.json) produces a message pointing at that CLI, never a JR-Bar-side rewrite. Factory uses this explicit action to queue a consent-gated usage refresh for the selected instance; it never runs a CLI sign-in. |
| `provider_sign_in` | provider, instance?, terminal? | The Usage Center's **Fix sign-in**: the best automatic thing for a provider whose card is not ready, tried in this order, always ending in one plain sentence the app shows verbatim. (0) A provider with no login command of its own (Devin, Cursor, Gemini CLI, Antigravity, the OpenAI API) first runs the staged action behind its card's CURRENT action label, the one the card's old button ran (`handle_provider_usage_action`): "Reconnect Devin" or "Reconnect Cursor" clears the rejected stored token and re-reads the browser session, else names the token page; the Gemini and Antigravity labels say where the CLI or app signs in; "Add OpenAI Admin key" reads the clipboard because the person just clicked. A token page it would open is returned as `sign_in_url` for the app to open (the daemon opens nothing), and the outcome is `staged`. A label that is not part of that flow falls through to (1), and so does a second account's. (1) Re-read what the provider's own tooling holds (the same re-pull as `provider_action` with `action: "resign_in"`). (2) Claude only, default instance: when that read does not find a current sign-in (Claude Code's Keychain copy expired, empty or missing) and `claude auth status` (JSON, bounded) says Claude Code is logged in, ask Claude Code to renew its own Keychain item with one tiny real call, `claude -p "reply with the single word ok" --max-turns 1`: an argv list and never a shell, the resolved absolute path of `claude`, a fresh private (0700) temporary directory as its working directory, the owner's environment with every `JRBAR_*` variable removed and `JRBAR_STATE_DIR` pointing inside that directory (the hook shim honours it, so the call spools there and registers no session with this daemon), stdin closed, a hard 90 s timeout, output read only to keep the pipe clear, capped at 4 KB and never logged or returned. The directory is removed afterwards. It counts as renewed when the credential source's fingerprint changed (the Keychain item's modification stamps and `~/.claude/.credentials.json`; no secret is read, and the 60 s attribute cache is bypassed for the check); JR-Bar never touches Claude Code's refresh token. A second renewal inside 60 s is refused. A hung call is killed and reported as failed; a CLI that says it is not logged in, or a call that exits without renewing, falls through to (3). (3) Otherwise open the owner's own terminal on the provider's sign-in command, through the same opener as `new_session` (`terminal` as there; else the terminal of the most recent session, else Ghostty when installed, else Terminal.app), in the home folder. The command comes from a table fixed in the daemon and the executable is the CLI's resolved absolute path (see `provider_update` for what makes a tool safe to run); the client sends neither: `claude auth login`, `grok login`, `codex login`, `opencode providers login`, `kiro-cli login`. Gemini CLI has no login command of its own, and Devin's usage is read from a browser session that `devin auth login` would not change, so those two (and any provider with no CLI) are never opened in a terminal: they take (0), else the re-read's advice, for Devin the session import or a `sign_in_url` to app.devin.ai. A provider whose sign-in the CLI cannot report on (Codex, OpenCode) is opened only when its card is signed out or unknown, never for a stale card whose problem is something else. (4) The outcome watch is armed and the provider's usage refresh is forced, as for `provider_action`, so the card recovers the moment the CLI saves its new sign-in. A second account (`instance` other than `default`) is only re-read: its sign-in is never the CLI's. `{provider, instance, outcome, message, command, sign_in_url}`: `outcome` is `renewed` (a stored or CLI-held sign-in is current again), `opened_terminal`, `already_ok` (the sign-in is current; `message` says what was refreshed), `staged` (the card's own staged action ran: `message` says what it did or what to do next, `sign_in_url` the token page to open or null), `unavailable` (nothing JR-Bar can do: `message` is the advice, `sign_in_url` a page to open or null, and a renewal inside 60 s of the last is refused this way) or `failed` (the call timed out, no private working folder could be made, or the terminal could not be opened). `command` is the command as the person would type it (`grok login`) when a terminal was opened, else null. `unknown_provider` and `invalid_args` as for `provider_action`. Explicit only: a click, never a timer. Queued on the action lane. |
| `provider_update` | provider | Runs a provider updater or its proven global installation manager on a worker thread and returns at once. The argv comes from a table fixed in the daemon (`claude update`, `grok update`, `devin update`, `opencode upgrade`), or from the owning trusted npm/Homebrew installation for Codex and Gemini and the client sends only a provider id; the executable is the resolved CLI or manager's absolute path, with the owner's environment plus the login shell's `PATH`, stdin closed and a hard 600 s timeout. A tool is run only if it holds the installed-agent inventory's line: relative and empty `PATH` entries are ignored, the file (after following any symlink, which npm and Homebrew use, so the link is judged by where it lands) is a regular executable owned by root or the person with no setuid or setgid bit and writable by nobody else, and the directory that holds the entry and the one that holds the file are owned by root or the person and not world-writable, nor group-writable except under `/opt/homebrew` and `/usr/local`, where Homebrew makes `bin` writable by the admin group. A path with a control character is refused. A match that fails is skipped as if it were not there, and the child's own `PATH` has the relative entries dropped too. One update per provider at a time and at most two at once. Codex and Gemini also reserve the owning npm prefix or Homebrew executable, preventing overlapping updates that share an installation manager. The CLI's `--version` is read before and after (bounded), the output is kept as its last 20 lines and 4 KB with anything that looks like a token removed, and the result lands in `state.provider_updates[provider]`: `updated` (old to new), `unchanged`, or `failed` with the exit code and the last lines. An updater that fails asking for a terminal (a `[y/N]` or `(yes/no)` prompt, "press enter", "not a tty", "not a terminal") returns `needs_terminal`. Native updaters open the terminal through the opener `provider_sign_in` uses. Managed npm/Homebrew updates instead give manual guidance, so no detached installer outlives its manager reservation. Only those specific phrases count; a plain failure is never re-run in a visible terminal. Devin's updater is never run blind: `devin update` checks and only optionally installs, and has no non-interactive flag, so with no input it could exit 0 having installed nothing and read as "already up to date"; its Update always opens the terminal (`needs_terminal`). `{provider, started, reason, message}`: `started: true` when the worker began; otherwise `started: false` with `reason` `no_updater` (the CLI has no supported updater or its installation manager cannot be established; `message` says to use the original installer), `not_installed`, or `busy` and a sentence. `unknown_provider` and `invalid_args` as for `provider_action`. Never run unless clicked: no timer and no setting starts an updater. |
| `provider_update_check` | | The Settings › Agents & Usage refresh asks whether newer CLI versions exist. Does nothing at all unless `provider_update_checks_enabled` is exactly `true`: then, off the main thread and at most once a minute, it asks the npm registry (see that setting) and the answer lands in `state.provider_updates[provider].latest_version`. `{enabled, started}`; with the setting off `{enabled: false, started: false}` and no request is made. |
| `firmware_status` | | What Settings › Devices & Lighting shows in each device's Firmware group, read fresh from each connected device's `STATUS.TXT` and compared offline with the releases pinned in the app. Makes no network request and writes nothing. `{catalog[{model, name, version, notes[], package{host, name, bytes, cached}, drive, image_bytes}], devices[{id, name, root, mounted, model, serial, version, active_slot, build, uptime_ms, latest, update_available, can_update, why_not{code, message}\|null, other_slot{name, has_image, valid, version}\|null, colour_note}], job, download_host}`. `update_available` is true when the device runs an older release than the catalog's, false when it is current, null when its version cannot be read. `can_update` is true only when an update would be accepted right now; `why_not` says why not (`not_mounted`, `model_unknown`, `model_mismatch`, `no_release`, `facts_unknown`, `device_busy`, `battery_low`) and is null for a device that is simply up to date. `colour_note` is true for a Pro whose firmware balances colour itself (1.1.0 and later). `package.cached` says whether the verified package is already on this Mac. Off the main thread. |
| `firmware_update` | device (a `devices[].id`), confirm (must be exactly `true`), package? (path of a package zip on this Mac) | Starts the firmware update of one device and returns at once: `{started: true, job}`, the job being the document under "Firmware updates". Progress follows in `state.firmware`. `confirm` other than `true` is `invalid_args` (nothing happens), an unknown device is `not_found`, a second update while one runs is `busy`, and every other reason the device cannot be updated now is `refused` with the plain sentence `why_not.message` gives. Fetching the package is the only network request, it happens inside this command and only when the package is not already cached or named with `package`, and nothing else in the daemon ever asks for it. |
| `ntfy_test` | | Settings › Remote's **Test** button: one fixed line, `JR-Bar test: your phone will hear from your agents here.`, to the saved `ntfy_topic`, now, because the person clicked. It needs a usable topic but not `ntfy_enabled` or the away condition, and waits (up to 8 s) for ntfy's answer. `{sent, reason, message}`: `reason` is `sent`, `no_topic`, `invalid_target`, `unreachable` or `rejected`, and `message` is the sentence the app shows verbatim. Off the main thread. Nothing else calls it, and no timer or event ever does. |
| `install_hooks` / `uninstall_hooks` | providers[] | `install.py` per provider: install registers the hook command (with the compiled shim when available and the Codex trust hash recomputed); uninstall removes the managed hook blocks the installer wrote. Claude's `settings.json` and Codex's `config.toml` are the ones in the folder the daemon's environment names with `CLAUDE_CONFIG_DIR` / `CODEX_HOME` when it names a folder that exists, else in `~/.claude` / `~/.codex` — the same home the usage scans read (`provider_homes.py`); `refresh_hooks`, the detectors and `hooks_doctor` follow it too, and no other home is touched. The daemon reads the variables from the environment the app launched it with (the app passes its own through), so one exported only in a shell profile is not seen. `{providers, results{provider: {ok, detected, changed, config_path, codex_trust, warning}}}` — `detected` is the installed-agent inventory's finding for that provider, `null` while the daemon has not finished looking (see `health.detected`), and an install then goes ahead: only an explicit `false`, a CLI that was looked for and never found, is a per-provider `{ok: false, detected: false, error}` row, not a silently claimed success (uninstall has no such gate: it removes what is there). |
| `refresh_hooks` | | Refreshes only integrations still owned by JR-Bar when the command executes. The daemon detects ownership and updates under the same cross-process mutation lock used by app and CLI installs/removals. It preserves provider-level disabled flags and leaves foreign hooks and removed integrations alone. Returns `{providers, results{provider: {ok, changed, config_path, codex_trust, warning}}}`. Per-provider failures remain failures; the app advances its build stamp only after the selected batch succeeds. No caller-supplied provider snapshot authorizes a refresh. |
| `set_closed_lid_policy` | policy | `never`, `agents`, `always`. |
| `quiet` | mode (`dnd`/`pause`, `dim`, `mute`, `dark`, `asks_only`), seconds | A DND override for a finite duration, clamped to 60 seconds through seven days. A finite nonpositive duration ends the override. Booleans and non-finite or overflowing durations are `invalid_args`. Returns `{until, mode}` when applied or `{until: null}` when ended; a refused save returns `refused` for either action. |
| `confetti` | session?, provider?, reason? | A burst asked for from outside JR-Bar -- `jrbar confetti [--session ID \| --provider NAME \| --from-hook] [--why TEXT]`, a Stop hook, `make test && …`, CI (`confetti_requests.py`). `session` is the daemon's id (`claude:session:…`) or the agent's own (`session_id` from its hook payload, which names the session's main row before any worker); `provider` (`[a-z][a-z0-9._-]{0,31}`) wins over the session's own; `reason` is one printable line, at most 80 chars. Journals one `confetti` event (see event) and replies `{sent: true, coalesced: false, event, cursor, session, provider, unmatched}`. The daemon only states the fact: the app's Confetti toy fires it when the toy is on and the room is clear, with its own cooldown. A second ask inside 3 s (the app's cooldown) is answered `{sent: false, coalesced: true}` and never journaled, so a loop in a hook cannot evict the events a reconnecting app replays. A named session nobody watches still celebrates, in the Toys colour: `session: null`, `unmatched: <the id>`. Bad args are `invalid_args`. |
| `quiet_lease` | action (`acquire` or `release`), lease_id (1 to 128 ASCII characters), expected_revision (required for acquire) | A rule's daemon-owned 900-second Pause lease. Acquire compares the override revision before writing. Repeating the same lease ID with its latest receipt revision renews it. An active manual override ending more than 900 seconds later returns `{status: "deferred", revision, until}` without writing or claiming ownership. Successful acquire returns `{status: "acquired", revision, until}`. Release requires the owned lease ID and restores the displaced override's exact original deadline if still active, otherwise clears it; returns `{status: "released", revision, until}`. Every accepted manual override edit invalidates ownership, including identical edits and cancellation. A stale revision, foreign lease, or release after restart returns `conflict` without writing. Save failure returns `refused` and retains ownership and settings. Lease IDs are unique per rule activation. The daemon forgets leases at restart; their persisted overrides expire normally. |
| `scene_lease` | action (`acquire` or `release`), lease_id, expected_revision and scene for acquire | Holds a temporary scene over the person's saved choice. IDs are 1 to 128 ASCII characters. Acquisition compares the manual-selection revision and rejects another owner with `conflict`. The same ID and scene can renew for 30 seconds using the original revision. Expiry uses a monotonic clock and leaves the saved scene unchanged. Release retires only that ID, so a delayed acquisition cannot revive it or release a replacement. Returns `{status: acquired\|released, revision, scene, until}` with the effective scene and a finite epoch deadline or null. Manual scene or pack writes supersede the overlay, including same-value writes. Daemon restart forgets overlays; the app renews live rules every 10 seconds. Retired IDs are bounded to 256; eviction advances the revision conservatively. No automatic scene is saved to the settings file. |

| `hold_awake` | exactly one of `seconds` (> 0), `until` (epoch), `until_time` (a local `HH:MM`, the next one, resolved in the Mac's zone so "until 08:00" survives a daylight-saving night), `until_agents_idle: true` (+ optional `sessions[]`), `indefinite: true`; `display` (default false); `source` (a short word, default `app`) | The person's keep-awake lease, the one hold every surface shares (the notch chip, a deck key, a CLI verb). It replaces any earlier lease, lasts at most 24 h (an agents lease: until none of its sessions is working or waiting on the person, backstop 12 h; without `sessions` it waits on every main session running now), retains captured sessions whose last-known row is stale and still pending until a fresh replacement, the normal retirement policy or the 12-hour backstop resolves them; stale rows do not admit new leases or count as current work; an empty `Unknown` snapshot is not a completion observation; holds the display too with `display: true` (the screen will not lock), outranks the agent-only switches (`agent_keep_awake_enabled`, `keep_awake_on_battery`) and survives a daemon restart. It yields -- never ends -- to heat and to the low-battery floor (`state.power.hold.suspended`). `seconds: 0` ends it, like `quiet`. `{lease, hold}`; `refused` "No agent is working right now." for an agents lease with nothing to wait on, `invalid_args` otherwise. A failed lease save returns `unavailable`, publishes the current hold, and does not replace the lease in memory. Saved data may be uncertain; retry before restarting the monitor. |
| `release_awake` | | Ends the person's lease (the agent hold keeps its own switch). `{ended, hold}`; `ended: false` when no lease was in force, including a successful cleanup retry. The daemon resyncs the hold before returning `unavailable` if saved-data cleanup or process release fails. A later command retries a failed process release even when the manual lease has already ended. Agent holds continue. |
| `session_energy` | | Which agent session is keeping the CPU busy -- the battery reading no battery app can make (`jrbar.session_energy`). Each live main session's process (the pid its hook recorded, still running under the same start time) and every process under it -- the builds, tests and servers its tools started -- billed to the nearest session above it, so a session started from another's shell is never counted twice; shared-host providers are never billed. `{sampled_at, window_seconds, sessions[{session, provider, cpu_percent, cpu_seconds, processes}], total_percent, heaviest}`: `cpu_percent` is Activity Monitor's (100 is one core fully busy) averaged over `window_seconds` -- the time since the previous ask when that was 1.5 s to 15 min ago, else a 1.5 s window the command waits for -- and null for a session whose pid the earlier sample did not see; heaviest first; `heaviest` is the top session at 5 % or more, else null. One `ps` fork per sample and nothing sampled in the background; no command line or argument is read. Socket thread. |
| `what_plays` | device? (device id, default all known devices) | Read-only live light plan. `{mixes[{id, name, parameters[{key, type, minimum, maximum, default}]}], devices[{device, led_count, requested_mix, played, reason, warnings[], providers[{provider, animation, parameters}], program, cue, cue_reason}]}`. The mix catalog supplies Studio controls. Uses the device's provider pin, direction, travel style and mix override. One working provider plays its own animation; two or more use `colors.blend_mode`. The Calm mixes `classic` and `color_blend` hold steady when several providers work or none are working. A lone working provider always keeps its own animation. Status only uses the state colour; Smooth blends provider colours. Asks keep their attention signal and failures remain visible. `warnings` names every budget or geometry fallback, including rejected Studio parameters. `cue` is null or `{id, until}` in monotonic seconds. Short cues tint the running animation for at most 2 seconds. The family rules below distinguish layers from takeovers. An ember is suppressed when any working provider has a chosen animation. This is a plan before calibration, brightness and higher priority device displays such as a preview or battery display. `not_found` for an unknown device. |
| `list_cues` | | The semantic ambient cues by name (`jrbar.ambient_cues`), highest priority first: `{cues[{id, name, meaning, enabled, default_enabled, setting, priority}]}`. `id` is the ambient family (`firefly_completion`, `completion_meniscus`, `handoff_baton`, `recovery_grace`, `ask_heartbeat`, `turn_length_ember`, `fleet_arrival_departure`, `courtesy_signature`, `glance_light`, `rainstick_idle`, `milestone_odometer`); `setting` names what switches it -- `ambient_cues_disabled` for the nine that default on, the cue's own flag (`rainstick_idle_enabled`, `milestone_odometer_enabled`) for the two opt-in ones. The Dot's binary heartbeat and the assigned semantic effects are displays, not cues, and are not listed. The `milestone_odometer` row adds `count` (the exact completions this daemon has counted since it started) and `next_step` (the next of `milestone_odometer_steps` above it, or null), so its cue arrives with a meaning you could see coming. |
| `set_cue` | id, enabled | Switches one cue through its `setting` (a switched-off cue is still planned and simply never reaches a surface), saved like `set_setting`. `{generation, cues}`; `invalid_args` for an unknown id or a non-bool. |
| `burn_init` | program, device? (id, default every connected strip and Dot), confirm? (default false) | The power-up program. Each device is judged at its own LED count through `animation.plan_power_up_burn`'s four gates -- the model, the compile, the device limits and the real firmware parser, refusing when that parser is unavailable. Without `confirm: true` nothing is written: the reply is the exact plan. `{confirmed, written, devices[{device, name, led_count, bytes, firmware_checked, warnings[], written, target, error}]}`; a device whose program does not validate carries `error: "invalid_program"` and `problems[{severity, code, message, step}]` and is never written. Runs on the socket thread (an SD write can take seconds). `not_found` with no connected hardware (the Screen Bar has no INIT.LED), `invalid_args` for an empty program, one past 4096 characters, or a non-bool `confirm`. |
| `calibration_profile` | action (`save`/`apply`/`delete`), slot (`Day`/`Night`/`Travel`) | The calibration profile slots: `save` snapshots every known device's brightness, gains and resting glow into the slot, `apply` writes the slot back onto the devices it names (`matched` counts them; `not_found` for an empty slot), `delete` empties it. `{slot, action, generation, slots[]}` (`delete`: `{slot, removed, slots}`). `focus_profile_rules` maps a Focus id to a slot the daemon applies when that Focus turns on; write it whole with `set_setting` on `focus_profile_rules` -- Focus ids contain dots, so a per-key dot path cannot address them. |
| `auto_dim_learning` | clear? (bool: forget the votes) | What the panel slider has taught the ambient curve (`jrbar.auto_dim`). While auto-dim follows the ambient sensor and the sensor answers, every `set_brightness` for `all` over at least one connected hardware device (auto-dim scales only the hardware) is a vote -- at this smoothed lux the person chose lights at their slider times the curve's factor -- the latest vote at a given light (within 25 %) replacing an older one, 24 kept since the daemon started. Once there are 3 votes from light at least 3 times brighter than the darkest, and a curve fits them clearly better than the one set now, it is OFFERED, never applied: `{mode, votes, ready, reason, suggested{brightness, min_fraction, lux_floor, lux_ceiling} or null, error_now, error_suggested, samples[{lux, level, at}]}` -- `reason` `needs_votes`, `needs_range`, `already_fits` or `no_fit` while not ready; the app applies a suggestion with `set_setting` (`auto_dim.ambient.*`) and `set_brightness` when the person says so. `invalid_args` for a non-boolean `clear`. Socket thread. |
| `check_palette` | colors? (`{"agent:<provider>": "#RRGGBB", "state:<idle|working|done|ask|error>": "#RRGGBB"}`, an edit previewed on top of the saved palette), visions? (list of `normal`, `deuteranopia`, `protanopia`, `tritanopia`; default the first three, the ones the shipped palette was searched against) | The colour-vision check: which of the person's provider and state colours read as one light for a colourblind viewer, measured the way the palette was chosen (Viénot's LMS simulation, CIE Lab distance, 12 the floor). `{min_separation, visions, checked, pairs[{left, right, left_color, right_color, vision, separation, shipped, suggestion}]}`, worst first: `vision` is the worst model for the pair, `shipped` true when both colours are exactly as shipped (the person did not cause it), and `suggestion` `{key, color, separation}` the smallest lightness step (hue kept, still bright enough to be a light) that clears the moved colour from every other colour, not just its pair -- the person's own edit moves first, then a provider before a state -- or null when no such step exists. Error is checked as the lights paint it. Nothing is written. `invalid_args` for an unknown key, a colour that is not `#RRGGBB`, or an unknown vision. Socket thread. |
| `preview_fleet` | scenario? (default `fleet`: two working, one done; or `quiet`, `one_working`, `one_needs_you`, `same_provider_duo`, `pair`, `full_team`, `busy_team`), blend_mode? (`color_blend`, `round_robin`, `spatial_split`, `relay`, `cycle`, `classic`, `alternate`, `weave`, `tide`, `effect`; default the device's own, else the global), cycle_speed_seconds? (the speed that mode plays at, even over its own override), device? (whose blend to use), led_count? (2 or 8, default 8) | A blend mode played against a synthetic fleet in the person's own colours, before choosing it -- how a mixed desk reads, which a single swatch hides. Compiled exactly as the device would play it; nothing is written to a device. `{scenario, label, blend_mode, cycle_speed_seconds, led_count, program, transformed, played, reason, warnings[], agents[{provider, mode}]}`. A scenario with an ask in it shows one strip under every blend: an ask takes the strip. `invalid_args` for an unknown scenario (or `live`), blend mode or LED count. Socket thread. |
| `resolve_effect` | semantic (`ask`, `failure`, `notification`, `handoff`, `work`, `completion`, `recovery`, `environment`, `idle`), scene? (default the active scene), provider?, instance?, project?, device? | Situation preview for the Effect Studio: which assignment wins before the situation happens. `{semantic, scene, urgent, winner{scope, target_id, effect_id} or null, ladder[{scope, target_id, applicable, effect_id, wins}]}` -- the ladder walked in precedence order (device, project, provider instance, provider, scene, meaning, everywhere), each rung's own assignment shown so a losing one is visible too. An ask or a failure keeps its reserved alert: `urgent` is true and only the meaning rung is walked. `invalid_args` for an unknown meaning or scene, or an empty id. Socket thread. |
| `list_light_log` | limit? (default 20, at most 200) | The light log for Why this light: the content-free effect history (`effect_history`, 200 events, persisted) newest first -- `{rows[{at, effect, category, surface, outcome, explanation, unseen}], total, last_seen}`, where `outcome` is `shown`/`suppressed`/`acknowledged`/`expired` and `explanation` is the history's own sentence ("Suppressed on the Dot by Do Not Disturb."). No provider text, session or path is ever in it. `invalid_args` for a non-positive limit. |
| `list_focuses` | | The Focuses this Mac has configured, so a per-Focus rule can name a custom one: `{available, reason, focuses[{id, name}], active[], active_available, active_reason}`. `available` and `reason` describe the configured roster. `active_available` separately says whether active identifiers were read completely under the `focus.named_readable` validation and limits. Unreadable identifiers, malformed record collections, encoding failures and exceeded limits make it false. `active_reason` then gives a safe explanation, otherwise null. `active` stays empty when unavailable; only `active_available: true` makes an empty list an observed absence of active modes. When the roster read fails, active names are not attempted and both availability fields are false. macOS guards these files with Full Disk Access. These fields do not change the public Focus activity reading. Socket thread. |
| `presence` | mic, camera, screen_shared (bools), locked? (bool), idle_seconds? (≥ 0), focus? (bool, INFocusStatusCenter's `isFocused` from the app's grant), meeting_until? (epoch of a calendar meeting's end, at most 12 h ahead), next_event_start? (epoch, or null for "nothing coming"), reminders_due? (list of up to 32 reminder ids) | The app's report of what it senses (`jrbar.presence`). `next_event_start` and `reminders_due` are the app's own Calendar and Reminders readings: while they keep arriving (each stands 180 s), the calendar and reminder glows use them and the helper never asks EventKit or needs a grant of its own -- one reader, so the glow and the shelf cannot disagree; absent keys leave the helper's own read in place, and a malformed one refuses the whole report. A live microphone, camera or screen share is a call: the quiet policy gains a `call` source per `call_quiet_mode` (default `sounds`: every light and banner stays, `audible_allowed` goes false), the escalation ladder holds at `ramp` (no menu-bar pulse on a shared screen, no chime into a headset; `escalation_stage` events follow the held stage), and `state.presence.celebrations_held` asks the app's celebrations to hold their burst. A meeting adds a `calendar` source per `meeting_quiet_mode` (default `off`) until `meeting_until`. `locked`, or `idle_seconds` of 300 or more, is away: an ask that reaches the menu-bar stage goes straight to the finale (still capped by `escalation_tier`). `focus: true` stands in for the daemon's own Focus reading while the daemon holds no Focus Status grant (Follow Focus must be on). A report stands for 180 s: the app renews it at least every minute while a sensor is live or `focus` is true, and a stale one ends the call (and the Focus stand-in) on its own. Unknown keys are ignored; a known key of the wrong type is `invalid_args`. `{presence}` (the `state.presence` document). |
| `list_history` | since, limit | Everything `sessions` no longer lists. Activity ledger rows `{at, kind, provider, session, label, detail, duration, unseen}`; kinds `completed`, `asked`, `failed`, `quota_crossed`, `ask_expired` (an ask closed by age, unanswered, with no process behind it). `label` is the name the last published `state.sessions` row gives that session (the provider's own title), falling back to the label recorded with the row for a session `sessions` no longer lists; a `detail` that only repeated the new label is dropped. `duration` is set only when the daemon observed both ends of the active stint — a session first seen already over gets none. `unseen` is derived per row from `at > last_seen`, the ledger's persistent watermark; the daemon also marks everything seen when the last client disconnects. `{rows, total, last_seen}`. |
| `list_commands` | | The durable command journal: what was asked and how it settled. `answer_ask` writes its intent there before it types, so a crash mid-answer leaves a record behind. `{outcome_unknown[], counts{completed, failed, pending}, commands[]}`. `commands` is the newest 50 settled records, newest first, each `{command_id, command, args, status, accepted_at, settled_at, receipt, error}` with `status` `completed` or `failed`. `outcome_unknown` is the ids of records that are still `accepted` with no settlement: a command whose effect was never confirmed, which a restart must not pretend finished. `counts.pending` is its length. |
| `list_roster` | scope (`all`/`live`/`workers`/`attention`/`finished`/`hidden`), provider, parent, since, limit | The independent roster: every session the collector retains — panel visibility never removes a row. Each row is the `state.sessions` shape, `axes` included (`{outcome, review, freshness}`, described once under `state`; Clear Agents acknowledgement is the review receipt), plus `schema` (record contract version), `pinned` (open ask) and `visibility` (the verdict the panel *would* give: `live`/`completion`/`hidden`). `hidden` scope is the audit cut: exactly what panel aging evicts. `{t:"roster", schema, now, scope, filters, sessions, counts{total, workers, attention, live, finished, hidden_from_panel, listed}, coverage}` — `coverage` names the bound: the collector's retained statuses; deeper history is `list_history`'s event ledger, not session records. `invalid_value` for an unknown scope. |
| `session_timeline` | id? or session+provider, cwd?, limit (default 100, max 500), before? | A session's provider transcript as bounded, paginated items — the Overview inspector's Timeline (S7.2). `id` is a roster row id and resolves the status's provider/`session_id`/cwd itself (`not_found` for an unknown id); an ended session whose status aged out is still inspectable via `session` (the provider uuid) + `provider` + optional `cwd`. Items are `{seq, at, kind, role?, name?, text?, tool_use_id?, is_error?, sidechain?, model?, uuid?, parent_uuid?, origin:"transcript", recorded_at:null, untrusted?}` — `kind` is `message`/`tool_use`/`tool_result`/`turn_end`; `tool_use`/`tool_result` pair on `tool_use_id`; `at` is the row's own stamp (occurrence) and `recorded_at` stays null because per-row ingestion time was never kept. `untrusted` marks tool output and assistant text — content, never a command. `before` is the seq of the oldest item the caller holds; the reply is `{schema, events[], has_more, next_before, total, source{provider, file}, gaps[]}` where `gaps` names `transcript_not_found`, `transcript_unreadable`, `transcript_too_large:N`, `timeline_item_cap:N`, or `unsupported_provider` (providers without a transcript reader answer that, not an empty success). Supported: `claude` (`~/.claude/projects/**/*.jsonl`) and `codex` (`~/.codex/sessions/**/*.jsonl`), matched by uuid-in-filename. Reads are bounded (64 MB file cap, 5000-item cap, 600-char text, secret-run redaction). `invalid_value` without a provider. |
| `compare_sessions` | a, b (roster ids, different) | Two runs side by side on retained facts only (S7.4). `{t:"compare_runs", schema, generated_at, a, b, shared{provider, workspace, model:null}, warnings[], gaps[]}` — each side is `{id, label, provider, cwd, lifecycle, mode, axes, remote, activity, interruptions, artifacts, model:null, gaps[]}`. `activity` is the transcript aggregate `{counts{user_messages, assistant_messages, tool_uses, tool_failures, retried_tools, turn_ends, sidechain_rows}, tools{name:count}, span{first_at, last_at, duration_s}, file}` or `null` with a named gap (`transcript_not_found`/`unsupported_provider`); `interruptions` counts the ledger's `asked`/`blocked`/`completed` rows for that agent id. `artifacts` is the files the run's edit tools named, read from each tool call's input (Claude Edit/Write/MultiEdit/NotebookEdit `file_path`, Codex `*** Add/Update/Delete File:` patch headers): `{files[{path, edits}], total, truncated}`, paths relative to the run's cwd or `~`, most-edited first, at most 200; `null` when the transcript was not read, and then `gaps` names `artifacts_not_tracked`. `model` is always `null` (per-session models come from `session_usage`) and `gaps` names `model_not_tracked`. `warnings` always includes `not_a_controlled_benchmark` plus `different_providers`/`different_workspaces` when the sides differ. `invalid_value` for missing/identical ids; `not_found` for an id not in the retained set. |
| `session_usage` | ids[] (roster ids, up to 64), since? (epoch) | Per-session model, tokens, cost and context for the panel's rows, the Overview's Model/Cost columns and Compare runs. Each id resolves its status's provider/`session_id`/cwd like `session_timeline`, and the session's own transcript is read incrementally (only bytes appended since the last request; a shrunk or replaced file is re-read). `{schema, sessions{id: {provider, model, models{model: tokens}, tokens{input, cached_input, cache_creation, output}, turns, estimated_cost_usd, cost_estimated, unpriced_models[], context_tokens, context_window, context_window_source, first_at, last_at, partial, window_tokens, tokens_since?}}, gaps{id: reason}, since, pricing{as_of, table_version, semantics:"api_equivalent_estimate"}}`. Every id lands in exactly one of `sessions` or `gaps` (`remote`, `not_found`, `unsupported_provider`, `transcript_not_found`, `transcript_unreadable`, `reading`) — never a zero. A request reads for at most 1.5 s (checked between lines and between files, a line at a time); an id whose transcript it did not finish, or did not reach, answers `reading` rather than a partial total, and the next request carries on from the saved offset. A lookup that finds no transcript is trusted for 60 s. Counting follows `usage_stats` (Claude: first sighting of a message id; Codex: `last_token_usage` deltas or cumulative differences, cache reads/writes split out of input). `estimated_cost_usd` is the Usage Center's list-price estimate (`cost_estimated` when a stand-in rate priced any model, null when no model had a price). `context_tokens` is the newest main-chain turn's prompt; `context_window` is Codex's `model_context_window` (`reported`) or, for Claude, 200k/1M `inferred` from the largest prompt seen. `partial` when a transcript past 64 MB was read from its tail. `since` adds `tokens_since` (turns at or after it). `window_tokens` is the session's tokens since its provider's primary usage window opened (`resets_at` minus the window's length, on the window the Usage Center's card leads with, this Mac's own account), for the Agent Overview's derived "≈ N %" window share; null when the provider reports no window, the session has no token timeline, or a tail read starts inside the window. `invalid_value` for an empty `ids`. |
| `mark_history_seen` | | The user just looked at History: advances the ledger's `last_seen` to when the command arrived (it waits on the slow lane, so not when it ran), so `unseen` rows and the "while you were away" banner measure from the last look, not from an app restart. `{last_seen}`. |
| `audit_export` | scope (roster scopes), provider?, parent?, since?, ids?, view?, format (`json`/`markdown`), path? | The redacted audit bundle over the SAME `list_roster`/`list_history` projections the surfaces show: `{format, document{t:"audit_export", schema, core_version, generated_at, scope, counts, coverage, gaps[], sessions[], activity[], pricing?, redaction, audit_only}}` — sessions/activity rows are the projected fields only (no raw provider payloads), with the home prefix collapsed to `~` and secret-shaped runs (≥24 unseparated chars) replaced by `[redacted]`. `gaps[]` names what is missing: no collector snapshot, ledger rows past the `since` cut, a usage scan still pending. `pricing` is the cached per-provider usage coverage (`records`, `estimated_records`, `unpriced_records`, `unpriced_models`, `pending`/`stale` flags over the 30d range) — the export never blocks on a cold scan. `format: "markdown"` adds `text` (the rendered report). `path` writes the bundle through `write_private_export` to a user-picked destination (`written{path, bytes}` in the reply); without it the document returns for preview. `ids` (a list of roster ids) narrows sessions and activity to the rows a surface is showing — the Overview's preset, project, search and selection are app-side cuts no roster scope expresses — and `view` names that cut; the bundle's `gaps` then say "Exported the N sessions in <view>; the roster retains M." An application audit, not a compliance record. `invalid_value` for an unknown scope. |
| `replay_events` | after?, limit? (default 500, capped at the journal size) | The event stream's resumable suffix. `after` is a `cursor` from an `event` frame or `hello`; omitting it replays the whole retained journal. Replies `{t:"events", stream, retained, dropped, events[], cursor, has_more, resync_required}` — `events` are the exact journaled frames in order, `cursor` is the last one returned, `has_more` means the page cut before the tail (call again with that `cursor`). A cursor from another stream incarnation answers `resync_required: true, reason: "foreign_stream"`; one the bounded journal already evicted answers `reason: "cursor_expired"` — never a fabricated empty catch-up. `retained`/`dropped` are the journal's coverage/gap counters. `unsupported` when the core cannot replay. |
| `dismiss_ask` | session, request? | Takes one ask that **may be stale** (`ask.dismissible`) off the Mac's surfaces: the strip, the Screen Bar, the panel, the deck and History's open asks stop showing it. Sends nothing to the agent -- it is never an answer. The dismissal is remembered across a restart (`dismissed-asks.json`, 0600, content-free: a session id and the millisecond the ask opened) and covers only that ask. `request` pins the ask the card shows; a replaced one refuses `stale_request`. `{session, dismissed, opened_at}`. `not_found` for a session with no open ask, `refused` for a `remote:` row or an ask that is not stale ("only an ask that may be stale can be dismissed"). |
| `dismiss_session` | session | Acknowledges one live or stuck row until it next speaks — the same receipt `clear_completed` writes, aimed at a single session the batch clear would never touch; the row leaves `sessions` now and returns the moment a newer event lands. `not_found` for an unknown session, `refused` for a `remote:` row (the peer's to manage) or a session with an open ask (the ask is the point; a stale one is dismissed with `dismiss_ask`). |
| `new_session` | provider, cwd, terminal? | Starts that agent's CLI (`claude`, `codex`, `devin`, `grok`, `cursor-agent`, `hermes`) in `cwd`, in the owner's own terminal: `terminal` (`com.mitchellh.ghostty`, `com.apple.Terminal`, `com.googlecode.iterm2`) when named, else the terminal the most recent recorded session ran in, else Ghostty when installed, else Terminal.app. Ghostty gets a new tab in its front window at `cwd` with the command typed into the owner's shell (a new window through the reviewed launch plan when it refuses the Apple event); Terminal.app and iTerm2 a new window. `{provider, cwd, raised: "new_tab"\|"new_window", app, bundle_id}`. `invalid_args` for an unknown agent, a relative path or an unreviewed terminal; `not_found` for a directory that does not exist; `unsupported` when the terminal could not be opened. Explicit only -- the Overview's "New session here"; the agent's first prompt is still the owner's to type. |
| `resume_session` | session, terminal? | History's Resume, by agent id (`list_history` rows carry it). A session `sessions` still lists opens exactly as `open_session` would. One it no longer lists is found in the process registry, which knows its directory: ended, it resumes in the terminal named by `terminal` (`com.mitchellh.ghostty`, `com.apple.Terminal` or `com.googlecode.iterm2`), else **in the terminal it ran in** (recorded at its SessionStart), else the terminal of the owner's most recent session, else Ghostty when installed -- as a new Ghostty tab at the session's directory with the resume typed into the owner's own shell, or a new Terminal.app / iTerm2 window: `{session, provider, cwd, raised: "new_tab"\|"new_window", app, bundle_id, detail: "resumed"}`. Still running (cleared from the list, not ended), its own tab, pane or Ghostty terminal is raised instead -- `raised: "pane"\|"tab"\|"terminal"\|"app"` -- and one JR-Bar cannot find refuses `not_found` ("…nothing new was started."): a second process on a live session is never started. `not_found` also for no registry record or a directory that is gone; `unsupported` for a remote row, a worker, or an agent JR-Bar cannot resume (Claude, Codex, Devin, Grok, Cursor, Hermes CLIs only); `invalid_args` for another `terminal`. Explicit only. |
| `hooks_doctor` | | `jrbar hooks doctor` as data, for a per-provider line in Settings › Agents & Usage: `{checked_at, state_dir, shim, shim_env, ingress_socket{path, answers}, core_socket{path, answers}, pending[{file, lines}], providers[{provider, label, config_path, config_home, installed, hook_events, hooks_enabled, registered[], registered_commands[], would_install, would_install_command, last_event_at, pending_lines, decide?}]}`. `config_home` is `environment` when the provider's config lives in a folder the daemon's environment names (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) and `default` otherwise. `last_event_at` is the provider's event log's modification time (when a hook last reached the daemon), `pending_lines` the payloads queued for it while the daemon was down, `decide` (Claude and Codex only) `installed`/`missing`/`not_installed` for the decide lane, `hooks_enabled` false when the hooks are installed but the agent's own settings turn them off (Claude's `disableAllHooks`, Codex's hooks feature). Content free: paths, command shapes, counts and times. Repair is `install_hooks`. |
| `t3code_integration` | enabled? (bool, legacy) | T3 Code's automatic local integration status: `{present, installed, running, database, enabled, activity_statistics, read_only, observation}`. `present` says whether the selected database exists; `installed` includes a database, a running host, or a T3 app bundle in `/Applications` or `~/Applications`. The app hides the row when `installed` is false; `running` says whether a desktop or CLI host uses it. Detection is always on. `enabled` remains readable and writable for older clients but does not stop detection. Custom paths and statistics consent still apply. `read_only` describes the settings file. `observation` reports `{available, threads, active, needs_user, reason, in_flight}` regardless of the legacy key. Reads stay local and read-only. `t3_snapshot_truncated` marks a partial projection; retained statuses are bounded to 1,024, with asks and active rows first. A non-bool `enabled` is `invalid_args`; an unsafe settings write is `refused`. |
| `session_in_front` | session | Whether the owner is looking at that session's own tab, pane or Ghostty terminal right now, for "Quiet while you watch" (every Ghostty window is one process, so the app alone cannot tell a background tab from the one in front): `{session, in_front, evidence, app}`. `in_front` is `true` only on proof -- `focused_tab_tty` (Terminal.app / iTerm2 named the focused tab and it is the session's), or `recorded_surface` (Ghostty's focused terminal is the one recorded at the session's SessionStart, still in the session's directory -- the process's, or the one it started in; being the only terminal in that directory is never enough); `false` for `other_app`, `other_tab` or `other_surface` (the focused Ghostty terminal is in another directory, or the recorded one is open and something else is focused); `null` when it cannot be told -- `tmux_unproven` (the terminal around a tmux pane is not the session's ancestor), `tab_unproven` (kitty, WezTerm, an IDE: the app is in front, the tab unknown), `automation_not_granted` (macOS has not yet allowed JR-Bar's Apple events to that terminal; this command never asks), `focused_tab_unproven`, `focused_surface_unproven`, `ownership_unproven`, `not_running`, `remote`. Nothing is raised, typed or prompted. A surface reads `null` as "keep its own rule". |
| `doctor` | | `{ok, core_version, commit, python, pid, socket, uptime_seconds, clients, hooks, devices, settings_generation, state_generation, commands, checks[{name, ok, detail}], memory, performance, appkit_loaded}` from `doctor.py` plus the hook shim and pending-file checks. `appkit_loaded` is a read-only dyld check in the daemon process, `true` when AppKit is loaded, `false` when absent, or `null` when the inventory is unavailable. It never loads AppKit or reports image paths. `commit` is `JRBAR_COMMIT` from an installed deployment (`scripts/install-agents.sh`), else the checkout's HEAD; `performance` is `{metrics{name: {count, p50_ms, p95_ms, max_ms, outcomes}}}` (the `PerformanceRegistry` timings the legacy Why panel renders), `cpu{user_s, system_s, percent_since_last}` (rusage deltas between doctor calls; `percent_since_last` is `null` on the first), and `frames{state_generation, lights_generation, state_per_minute, lights_per_minute}` (documents actually broadcast, counted over a rolling 60 s window). `jrbar doctor` appends these as a `performance:` section when a daemon answers (its `--socket` selects another daemon); `--json` carries it under `daemon.performance`. |
| `usage_history` | provider, range (`7d`, `30d`, `90d`, `365d`), observe? (bool, default false) | Daily and hourly token/cost rows for one provider from the local transcript scan (`usage_stats.scan_usage`, the same one the Python Usage window ran): `{provider, range, days[{date, tokens_in, tokens_out, cache_read, cost_usd}], hours[{hour, at, …}] (last 7×24), pricing{input_per_mtok, output_per_mtok, cache_read_per_mtok, as_of, approximate, currency, model, source, estimated} or null, account, state, records, estimated, estimated_records, unpriced_records, unpriced_models[], models[{model, tokens, cost_usd, records, priced, estimated}], reading_files, partial}`. `partial` is true while the rows are a first answer (`pending`) or `reading_files` is above 0, which is when the app keeps its "still reading transcripts" note and asks again; it is false for a finished scan, including a `stale` one that is only being refreshed. Clients retain `stale` separately from scan progress and label completed cached rows as the previous reading while refreshing. A stale empty reading does not confirm that no local records exist. Older replies without `stale` default to false; a nonboolean value is malformed. `reading_files` is how many transcripts the scan has not finished reading (0 once every transcript in the window is read to its last complete line). A transcript of any size is streamed, never skipped: the scan reads in bounded passes of about 2 s, each stopping at a clean line boundary and saving where it stopped, so a cold start over many gigabytes shows what has been read so far (`stale: true`, `reading_files > 0`) and a `usage_history_ready` event follows each pass until `reading_files` is 0. A line over 16 MiB (`usage_stats.USAGE_RECORD_MAX_BYTES`) is skipped as one unparseable record; a transcript over 8 GiB (`USAGE_FILE_SANITY_BYTES`) is skipped whole. Both are counted in the scan's coverage, which is why the Usage Center says partial only while reading or after such a skip. `tokens_in` counts input plus cache writes. `models` splits the range's tokens and dollars by the model each record ran on, most tokens first (Claude records carry the pricing key, `opus-4-5`; Codex records the turn's model) — it sums to the `days` rows it was cut from. `pricing` is the dominant model's quote from the Python price tables (`usage_stats.MODEL_PRICING`, `GPT_MODEL_PRICING`, `GEMINI_MODEL_PRICING`; cache reads 0.1× input, Anthropic cache writes 1.25×, OpenAI cache writes 1×): `source` is `table` (the model's own row), `codex_default` (a Codex record that names no model, the literal `codex` from rollouts without a `turn_context` row, is priced at the `model` in `~/.codex/config.toml`; records after a `turn_context` carry that turn's model, `gpt-5.6-sol`, `gpt-6-astra`, and are priced as it) or `reference` (a model the table does not know, priced at the provider's mid-range reference model, `sonnet` / `gpt-5.6` / `gemini-3-flash`, with `estimated: true` rather than $0). The document's `estimated` says whether any counted record was priced that way. `unpriced_records`/`unpriced_models` are the other failure: counted records whose model has no quote at all (a provider with no price table and no reference rate) — their tokens are in the rows, the $0 they contribute is a real absence rather than a price, and they are never blended into `estimated`. Supported providers scan their configured local history. A provider without a local-history adapter answers empty rows, with a reference quote when available. Every dollar figure is approximate. The scan runs on its own thread. A normal request starts or joins it and immediately returns what memory holds: `pending: true` with empty rows when there is nothing yet, or the last document with `stale: true`. The socket scan lane never waits for that background scan. Claude and Codex use the shared `token-history.sqlite3` index described below. Only changed transcripts are parsed; range opens read stored buckets. A `usage_history_ready` event follows when an owed scan lands. With `observe: true`, the request reports current memory without starting or retrying work. A running scan returns its pending or stale reading and owes a completion event; a completed failure returns `unavailable`; an unrequested range returns `unavailable` with no invented scan. Observation can be repeated by multiple clients without consuming the outcome. A nonboolean `observe` is `invalid_args`. `scanned_at` is the epoch of the scan behind the rows (null while pending). A completed failed scan returns `unavailable` with "Local history could not be refreshed. Try again." and emits `usage_history_failed` when it owed a completion, instead of `usage_history_ready`. The client retains its prior rows. An active retry can return the previous reading with `stale: true`, or `pending: true` when no reading exists. A document younger than 60 s answers as is only when no scan failure is recorded. When token history is enabled, the daemon warms local history providers 8 s after it is ready, then maintains the index every 60 s. Turning it off cancels that maintenance. |
| `usage_graph` | days? (`7`/`30`/`90`/`365`), metric? (`tokens`/`cost`/`sessions`/`percent`), providers? (nonempty list of registry ids) | The shared-axis multi-provider usage chart — the same local-transcript scan `usage_history` runs, assembled by `usage_graph_worker.usage_graph_document` into `{graph, summary}`. `graph` is `{days, period_label, metric, labels[] (strided "MM/DD", empty slots draw no tick), series[{provider_id, values[], source_instance_id?, identity?, label?, has_priced_usage?}], scale_max, heatmap, providers[], partial_provider_ids[], cost_semantics?, cost_coverage?}` — `values` and `labels` are index-aligned one slot per calendar day, and a series value `< 0` is a gap day (before the provider had samples): the client must break the line there, not bridge it. In `sessions` mode a provider whose sessions are counted only from its hook log (it has no transcript reader) gets gap days for every day before the first event that log still retains, because the log is compacted to its newest events: those days are unknown, not zero. Percent mode emits one series per (provider, source instance): two rows can share `provider_id`, so chart identity must carry `source_instance_id` (`label` is the daemon's display name, `provider · instance` for a non-default instance) — keying on `provider_id` alone merges them into a fabricated single line. `providers` echoes the resolved request so a picker can tell unchecked from checked-but-empty. `reading_files` (graph, additive) counts transcripts the bounded scan pass did not finish; while it is above 0 the sums are what was read so far, the summary says `Still reading N files`, and the reply is not remembered, so the next ask continues from the saved offsets. A visible Usage pane continues positive `reading_files` replies at a paced interval, with one request at a time. Until it reaches zero, the client labels totals as read so far and does not stamp the document as a completed refresh. Hidden or closed panes do not continue; failures retain the document and require retry. Stable partial source coverage with zero `reading_files` does not trigger this continuation. `heatmap` is the JSON-projected day grid `{days[] (ISO), providers{id: {provider_id, cells[{day, tokens, sessions, intensity 0–4, color, accessibility_label}], totals{tokens, sessions}, data_status}}, aggregate, timezone}` — the same GitHub-style calendar the old Settings window drew. `summary` is the scan's own sentence ("Last 30 days: Claude 12.3M · 45 sessions") including its `Partial local history:`, `Still reading N files` and `API-equivalent estimate` disclosures — the client shows it verbatim rather than recomputing. In cost mode, optional `cost_coverage` contains nonnegative `observed_records`, `priced_records`, `unpriced_records`, `unpriced_sessions` and unpriced `token_categories` (`input`, `cached_input`, `cache_creation`, `output`). Counts cover deduplicated positive-token records in the selected range and providers; priced plus unpriced equals observed. A mixed-model session counts once among sessions with unpriced usage. This is price coverage, separate from incomplete source history. Cost series optionally include `has_priced_usage`: false means positive-token usage has no price estimate, so the client labels the subtotal `Unpriced`. True includes known zero-cost usage. Negative cost values mark days with unpriced usage and no known subtotal; empty days remain zero. All three args are per-request overrides: absent means the stored `usage_graph_*` settings, and nothing the pane picks is written back. Invalid overrides are `invalid_args`, never a silent substitution. Cold transcript scans can be slow. The command uses the daemon's serial scan lane, separate from short reads and person-triggered actions. Clients use a longer request timeout and show scanning progress. |
| `list_effects` | | `{effects[], packs[], cadences[], generation}`: every effect in the runtime registry (builtins, the provider animations and installed packs) with typed `parameters[]`, a `preview {program, led_count}` rendered at the defaults, the blink `cadence` when one applies; `packs[]` is `{id, name, version, effects[ids], license?, path?}` from the pack store; `cadences[]` the three safe blink cadences. `generation` is derived from the catalog's own content -- every effect id and version, every installed pack's id, version and effect list, plus the assignment cache's save counter -- so it changes when the registry, the installed packs or the assignments change, and does not otherwise (`core_effects.catalog_generation`). It is stable across daemon restarts and never 0. |
| `render_effect` | effect_id, parameters, led_count, color? | `{effect_id, program, led_count, parameters, cadence}`: the LEDS program the daemon would play for those parameters (unknown parameters dropped, bounds enforced), through the presentation safety compiler. Builtins use their registered shapes, provider animations the live solo renderer (`duration_seconds` sets the cycle), pack effects their `motion`/`color`/`cadence` data or a primitive for their meaning. |
| `list_assignments` | | `{assignments[{effect_id, scope, target_id, parameters}], active_scene, generation}` from the effect assignment store; `parameters` come from the daemon's sidecar (`effect-assignment-parameters.json`). `generation` is derived from the assignments and the active scene (`core_effects.assignments_generation`). |
| `set_assignment` | effect_id, scope, target_id?, parameters? | Validates through `effect_studio.plan_assignment` (global takes no target, `asking`/`failure` keep `alert`, scenes and semantic families are checked), saves the assignment document and the parameters sidecar, refreshes. Semantic targets outside the four the event router can deliver (`asking`, `failure`, `completion`, `notification`) are refused `unroutable_semantic` — `working`, `idle`, `recovery`, `environment`, `transition` and `quota` are persistent states, not deliverable effects. A `provider_animation`-catalog effect assigned at `provider` scope also writes `colors.provider_animation[target]`, the persistent motion the live renderers read, and the reply gains `motion_warning` when that settings write fails. Replies the assignment document plus `assignment`. |
| `clear_assignment` | scope, target_id? | Removes that assignment (and its parameters sidecar entry, and -- when the removed row was a provider-scope motion -- that provider's `colors.provider_animation` and `colors.provider_animation_parameters` entries, so it plays what it plays when nobody chose: OpenCode's own Pendulum, anyone else Automatic); the document plus `removed`. |
| `list_lid_presets` | | Effect Studio › Moments › Lid (2026-09-24): `{kinds[{kind, label, path, current, shipped, shipped_program, presets[{name, duration_seconds, shape, program, dot_program, setting}]}]}` for the four lid transitions (`open`, `closed`, `open_active`, `closed_active`). `program`/`dot_program` are the look drawn for the Pro's eight LEDs and the Dot's two, as thumbnails -- the Iris looks (`shape` `iris_open`, `iris_close`, `iris_open_active`, `iris_close_active`) are drawn per device, the active ones in the working agent's colour. A thumbnail starts dark, so the Iris close's `program`/`dot_program` open with a 200 ms ease up to cyan; `setting.program`, and what the strip plays, close on whatever was lit. `current` names the look the transition plays (null for a custom program; `shipped` says it is still the look it came with). To pick one, `set_setting` the transition's `path` to its `setting` object. |
| `play_lid_preset` | kind, name | Plays that lid look on the connected strip and Dot exactly as a lid change would (`play_lid_animation`, each device drawn for its LED count), then hands the light back. `{kind, name, seconds}`; `invalid_args` for an unknown look. Hardware: the app asks for its preview consent first. |
| `list_finish_looks` | | The done celebration's looks: `{current, enabled, looks[{style, label, program, dot_program}]}` -- `bloom` (the shipped twinkle-then-bloom), `land`, `ripple` -- drawn in the done colour. `current` is `colors.done_celebration_style`. |
| `preview_provider_motion` | provider, led_count? (2…8) | Preview the provider's chosen motion at its own tempo, or the Relay for Automatic, independently of the global Mix. Calm holds the live display while these picker previews still animate. `{provider, led_count, motion, program}`. The Lighting page's provider swatches play it. |
| `import_effect_pack` | path, update? | `EffectPackStore.install` of a data-only JSON v2 pack (`invalid_pack` on anything the validator refuses, `conflict` when that pack id is installed), the registry rebuilt with every installed pack; replies the catalog plus `imported {id, name, effects}`. `update: true` replaces the installed pack with that id instead (`refused` with `not_installed` when there is none, `already_current` when nothing changed). |
| `remove_effect_pack` | pack_id | `EffectPackStore.remove` of one installed pack (`not_installed`/`refused`/`remove_failed` as appropriate), the registry rebuilt; replies the catalog plus `removed {id}`. |
| `export_effect_pack` | ids[], path, name? | Writes a data-only JSON v2 pack of those effects (pack effects keep their data, builtins become their motion plus parameter defaults, fallbacks kept only when exported too) through `write_private_export`; `{path, effects, bytes, id}`. |
| `list_scene_packs` | | `{packs[{id, name, scenes[], installed}]}` — the installed Scene packs as the `ScenePackSummary` the app decodes; `scenes` lists the scene names each pack overrides. |
| `import_scene_pack` | path, update? | Validates the pack file first (`preview_source`, so nothing writes before the plan exists — a version-1 pack is migrated in memory, `invalid_pack` when the validator refuses it), then `ScenePackStore.install` (or `update` with `update: true`). `{pack_id, name, scenes[], installed, migrated, status}`; `conflict` when the pack id is installed and no update was asked for. Scene packs are data-only, network-free and bounded, must declare reduced-motion / high-contrast / non-colour-cue support, and may only name the known scenes (`focus`, `calm`, `night`, `demo`, `travel`, `dnd`). |
| `preview_scene_pack` | pack_id, led_count? | `not_found` when no installed pack has that id. Else renders the pack's scene-by-scene policy tour — one step per overridden scene, the scene's colour dimmed by its brightness policy, the motion policy choosing step length and interpolation — through the presentation safety compiler at the requested LED count (clamped 2–24). `{pack_id, led_count, program}` — an `EffectPreview` with a `pack_id` extra the app ignores. |
| `serve_token` | | `{token, enabled, running}` — the bearer `JRBAR_SERVE_ACCESS_TOKEN` the daemon was launched with (null when none), whether `serve_enabled` is on, and whether the loopback server is actually bound. When `serve_enabled` and the token are both present the daemon hosts `serve.create_serve_server` in-process (port `JRBAR_SERVE_PORT`, default 8737); a missing token means no endpoint, never anonymous. The token travels on the local socket only, never inside the HTTP document it guards. The same server carries `GET /asks.json` and `POST /answer` (see "Answering from serve" below), which act only while `serve_answer_enabled` is on. |
| `adopt_seal` | | Seals the settings the daemon holds as the baseline for the protected keys (see "Protected settings"). `{state}`. Refused `seal_unavailable` when the daemon has no seal key, and `refused` when the file could not be written (nothing is sealed then). |
| `keep_protected_change` | | Applies and seals the protected values a foreign edit of `settings.json` tried to set and the daemon ignored. `{state, kept}`; `nothing_to_keep` when there is none. |
| `deck_press` | index 0…23 | What a press of that control does, from the screen (the physical key runs the same rule through `DeckInputDispatch`). An explicit `deck-controls.json` mapping wins (`{index, action: <kind>, receipt}`; `next_bank` / `previous_bank` add `bank`, `next_scope` / `previous_scope` add `scope`; a failed app shortcut is `refused` with the deck controller's sentence). Else a session key: when that session has a live ask the decide lane holds -- in any terminal, frontmost or not -- or a live ask whose terminal or origin app is frontmost, the press approves it through the `answer_ask` path (`{action: "answer_ask", decision: "approve", answered: true}`); otherwise it reveals the session through the board's navigation resolver (`{action: "reveal_session", receipt, activated}`). `not_found` with "No session assigned." / "Reserved: session not observed." / "Configure this control in the Creator Micro window."; `input_check` while input check is on. |
| `deck_answer` | index 0…12, decision (`approve`, `deny`, `always`, `answer`), answers? (with `answer`), request?, command_id? | An explicit answer from a session key -- the Rail's Deny, Always allow (from its own button) or a picked choice, a Stream Deck key through serve's `/answer` -- where a press can only approve. The key's session is answered through `answer_ask` with `only_if_frontmost: true`: the same fences, command journal and decide lane (`always` and `answer` only while the lane holds the agent's own prompt), so a key can never do what the panel's own buttons could not. Never falls back to revealing: a key whose session has no live ask refuses `not_found`. `{index, identity, session, action: "answer_ask", …the answer_ask receipt}`. `invalid_args` for another decision or an index past the session keys; `not_found` for an empty or reserved key; `input_check` while input check is on. Runs on the socket thread. |
| `deck_pin` | index 0…12 | Toggles the pin on the identity at that key (pins are per identity and survive Clear absent). `{index, identity, pinned}`; `not_found` for an unassigned key. |
| `deck_bank` | delta | Steps the bank, wrapping. `{index, count}`. |
| `deck_scope` | delta | Steps the board scope through `automatic` plus the configured provider scopes, wrapping (what the `next_scope` / `previous_scope` aux actions run). `{scope, scopes}`. |
| `deck_rail` | edge (`off`, `left`, `right`, `top`, `bottom`) | The compact rail's edge, persisted with the board. `{edge}`. |
| `deck_clear_absent` | | Unpinned identities with no observed session leave the board; later keys move up. `{removed, banks}`. |
| `deck_plan_keymap` | profile, layer, include_auxiliary, layers? | `creator_micro_keymap.plan_keymap` for that layer over the inspected keymap: `{profile, layer, include_auxiliary, changes[], preview, controls[{index, label}]}`, `preview` being the Python review alert's text. `layers` (`[{"layer": int, "name": str}]`) previews the multi-layer write instead: every listed layer is claimed and named. The first call (and any call after 120 s, or after a write) inspects the device: the output service is stopped, the keymap read, the pad handed back. `invalid_plan` with the ValueError message; otherwise the receipt code (`connection_required` when the pad is not approved, `busy` while another setup or settings operation runs). Deck worker. |
| `deck_apply_keymap` | profile, layer, include_auxiliary, layers? | `CreatorMicroSetup.apply` of that plan (private backup first, verified write, readback): `{code: keymap_verified\|already_configured, message, changes, state, backup_at, generation}`; input check turns on after a verified write. With `layers`, one write claims and names every listed layer (`apply` re-derives the whole plan, so a forged selection cannot write arbitrary JSON). Refusals are error replies whose code is the receipt (`keymap_changed`, `recovery_required`, `readback_mismatch`, …). No alert is shown; the confirmation is the app's. |
| `deck_restore_keymap` | | `CreatorMicroSetup.restore` from the first private backup: `{code: keymap_restored\|already_restored, message, state, backup_at, generation}`, same refusals (`backup_invalid` with no backup, `keymap_changed` for later device edits). |
| `deck_approve_device` | | The Devices pane's Enable, for a pad that is here: the daemon probes HID once more and refuses with `no_device` ("No Creator Micro 2 is connected.") when it sees none, so a remembered serial is never enabled blindly; otherwise the sole stable serial becomes `creator_micro_device_serial` with `creator_micro_enabled` and the output service is reconfigured. `{serial, approved}`; `ambiguous_device_identity`, `device_identity_unavailable`. |
| `deck_disable` | | The off half of `deck_approve_device`: writes `creator_micro_enabled = false`, so the output service is torn down, and keeps the approved serial, so the next enable does not ask for the pad again. `{enabled: false}`; `busy` when the save did not finish in time, `refused` when it could not be saved. Off the main thread. |
| `deck_check_input` | enabled | Input check on or off (queued input is revoked). `{enabled}`. |
| `deck_set_settings` | enabled?, session_mode?, analog_enabled?, bindings?, layer_map?, scopes?, ownership?, layer_owners? | Writes `deck-controls.json`, reconfigures the deck runtime. `bindings` replaces the whole auxiliary set (`{index, action|null}` rows for controls 13…23 — 20…23 are the analog joystick sectors; a null unbinds; matrix-key bindings survive). `layer_map` (`{layer, scope}` rows) maps hardware layers to board scopes and `scopes` adds provider ids past the mapped ones; both are validated (no duplicates, `automatic` only inside `layer_map`). `enabled`, `session_mode` and `analog_enabled` are bools. `ownership` (`yield` or `hold`) is how the output owner answers a foreign writer on the pad's report stream: `yield` pauses JR-Bar's output while the adapter waits out its conflict retry, `hold` absorbs the accusation on a layer JR-Bar owns and writes its latest frame back. `layer_owners` (`{layer, owner}` rows, at most 24, one per layer) says who may paint each hardware layer: `jrbar` (the auto layer, and what any layer not listed is), `everything`, or a provider id, which hands the layer to that external writer so JR-Bar leaves it alone while the pad sits there; layer 0 always stays `jrbar`. Every argument is optional, but a request that names none is `invalid_args`, as is any value that breaks the rules above; `refused` when `deck-controls.json` changed underneath the request or could not be saved. `{enabled, session_mode, analog_enabled, bindings[{index, action}], layer_map[], scopes[], ownership, layer_owners[]}`, the settings as saved. |
| `ping` | | `{pong, now}`. |
| `quit` | | Replies, then the daemon releases its holds and exits. |

Ambient families follow these rules on the strip, Dot and Screen Bar:

- `turn_length_ember`, `firefly_completion`, `completion_meniscus`,
  `handoff_baton`, `recovery_grace`, `milestone_odometer`,
  `fleet_arrival_departure` and `courtesy_signature` tint the base colours
  for at most two seconds. They keep its timing and LED positions.
- A `semantic_selection` completion using the default `notification`
  effect also layers for at most two seconds. Other `semantic_selection`
  effects and `glance_light` replace the base for their declared lifetime.
- `rainstick_idle` replaces the idle program while its plan is active.
  `ask_heartbeat` and `dot_binary_heartbeat` replace the base while their
  request or semantic plan remains active. They do not use the short-layer
  deadline.

Human-readable mix `name`, preview `label`, and playback `reason` values use sentence case and provider display names, such as Claude, Codex and OpenCode.

Share mixes allocate one share per provider. Groups and sessions of that
provider merge; their most urgent state wins. A fresh failure keeps its share
until its five-second signal expires, even while another session works.
Retained failed and ended sessions take no share. The share keeps the provider
colour as sessions come and go. Explicit session colours and Color by Project still apply.
Asks stay individual and take priority. Everyone uses contiguous shares when
a chosen animation is a sweep, including Knight Rider, Scanner and Pendulum.
Each sweep then travels through adjacent LEDs inside its own share.
Interleaving would scatter that path across the other provider's LEDs.
Other Everyone shares may interleave. `what_plays.reason` names the
contiguous layout.

`set_assignment` also accepts `scope: "mix"` without a target. It atomically selects Mix `effect` and saves `colors.mix_effect` from `effect_id` and `parameters`. This is a Mix setting, outside assignment precedence. Its reply adds `mix_effect`; `list_assignments.assignments` stays unchanged so older apps can read it.

An ask or failure keeps its priority over a short layer. `what_plays`
reports the provider program and short layer before higher-priority
presentation owners apply a takeover.


### Deprecated/internal commands

The commands below stay registered and answered, but the current app build
never sends them. They are protocol-compat surface, not dead code: removing
one would break any older or third-party client still calling it (and the
daemon's `REQUIRED_COMMANDS` registration test). None is reachable from the
`jrbar` CLI.

- `apply_effect` — the protocol-1 spelling of `set_assignment`/`clear_assignment`
  (`effect: null` removes). Kept for older clients that predate the assignment
  pair; the app only sends the newer names.
- `set_device_display` — no app caller. It remains the only socket-level way
  to switch a device's display mode (`agent`/`battery`/`studio`/`quota_runway`) on the
  headless `jrbar core` daemon, which has no menu.
- `set_closed_lid_policy` — no app caller; a typed, validated spelling of the
  `closed_lid_awake_policy` write that `set_setting` already covers. Kept as a
  stable contract for headless clients.
- `quit` — the app stops the daemon with SIGTERM (the daemon's signal handler
  runs the same orderly `coreQuit:` path); the command remains so a socket
  client can ask for a graceful shutdown in-band.

### answer_ask: the checks, and what each refusal means

Answering means typing into a window the owner did not look at first, so every
check below runs before anything leaves the daemon, in this order, and the
first one that fails refuses. **Nothing skips them** -- `only_if_frontmost` does
not gate them. `only_if_frontmost: false` means "raise the session's terminal
first" (`NSRunningApplication.activateWithOptions_`), after which the same
chain runs against whatever is genuinely in front; it is not a bypass and it
can still refuse.

| code | when | message |
| --- | --- | --- |
| `not_found` | the daemon's canonical state has no live request for that session | `no live ask for that session` |
| `unsupported` | the provider's contract does not declare `answering`, or the answer controller would not accept the action (a typed reply, an attempt already sending, or already sent and waiting for the agent) | `this ask cannot be answered from here` |
| `stale_ask` | the request left the live phase between the command and the keystroke -- answered in the terminal, timed out, superseded -- or the delivery overran `answer_local.DELIVERY_BUDGET_SECONDS` (4 s). Re-checked immediately before the key is posted, so a resolved ask never leaves a keystroke pending. | reason `resolved_elsewhere`, `resolved_while_sending`, `budget_exceeded`, `not_in_canonical_state` |
| `session_gone` | the session's process is not running, or the daemon has no row for it, or it is stopped (Ctrl-Z) so its terminal is showing the shell | reason `no_live_process`, `no_session_row`, `process_stopped` |
| `not_frontmost` | the window in front is not this session's. Reasons: `no_frontmost_app`; `unknown_host` (JR-Bar cannot say which app hosts the session); `frontmost_is:<bundle id>`; `other_window` (the frontmost application's process is not the one the session descends from); `other_tab:<tty>` (Terminal.app / iTerm2 named a focused tab that is not this session's); `other_surface` (Ghostty's focused terminal is in another directory than the session's process); `changed_while_sending` (the proof held when the answer began but no longer holds: the window proof is taken again immediately before the key is posted, and a change refuses the key). Ghostty names no tty: its proof is the focused terminal of its front window being the surface recorded when the session started, still in the session's directory (`window_evidence: "recorded_surface"`); with no recorded surface -- or a recorded one Ghostty no longer lists -- it refuses `focused_tab_unproven`, however few terminals share the directory, since an agent that moves itself into a worktree leaves a plain shell there looking like its own. With `only_if_frontmost: false` the session's own tab (by tty), tmux pane or Ghostty terminal is raised first (`answer_surfaces.raise_for_answer`), then the app. | the sentence plus the reason |
| `accessibility_required` | `AXIsProcessTrusted()` is false, so a posted key would silently go nowhere | `JR-Bar cannot answer this ask until macOS lets it send the keystroke. Turn on System Settings > Privacy & Security > Accessibility > <row>.` The row is the daemon's own bundle name -- `jrbar-core` on an installed deployment, since the helper is a separate TCC client from JR-Bar.app. |
| `send_failed` | macOS refused to build or deliver the event | the failure's name |
| `busy` | the answer worker did not finish inside `ANSWER_REPLY_BUDGET_SECONDS` (6 s) | `answering did not finish in time` |

A refused, failed or timed-out send never blocks a later Approve or Deny.
Every `answer_ask` is a fresh verdict: all of the checks above run again in
full, and nothing retries on its own.

The same surface backs the panel's Approve/Deny, the notification actions and a
Creator Micro session key, so a refusal reads identically wherever it happens;
the panel shows the refusal's own sentence rather than an exception name.

### The decide lane

Claude Code and Codex run a `PermissionRequest` hook when they are about to
ask for approval, and take the hook's stdout as the answer (both vendors'
hook references, checked 2026-09-22). JR-Bar installs that one hook as
`jrbar-hook … --decide` with a 60 s timeout (Codex's entry also carries
`statusMessage = "Waiting for an answer in JR-Bar"`); every other event keeps
the plain shim and its 250 ms budget. The daemon (`answer_decisions.py`)
parks the request before it queues the payload and holds it for up to 45 s.
`answer_ask` on a held request replies to the hook instead of typing, so it
needs no frontmost window, no focused-tab proof and no Accessibility grant,
and it works from every surface that sends `answer_ask` -- the panel, a
banner action, the notch, a deck key or the Rail:

| decision | verdict the hook prints |
| --- | --- |
| `approve` | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` |
| `deny` | `{"behavior":"deny","message":"The user denied this tool call from JR-Bar."}` -- plus `"interrupt":true` for Claude, which stops the turn the way Esc on its own prompt does. Codex takes no `interrupt`. |
| `always` | Claude only, and only when `ask.decision.always`: `{"behavior":"allow","updatedPermissions":[…]}` with the request's own `addRules`/`allow` suggestions copied field by field. Mode changes and directory grants are never echoed. Anything else refuses `unsupported`. |
| `answer` | Claude's `AskUserQuestion` only, and only when `ask.decision.choices` is non-empty: `{"behavior":"allow","updatedInput":{…the agent's own input…,"answers":{"<question>":"<label>"}}}` -- the documented way to answer the tool from a hook. A `multi` question's labels are joined with `", "` in the agent's own option order. `answers` must name every question exactly and pick only offered labels, or it refuses `invalid_args` before anything is sent. |

Only an explicit `answer_ask` decides. The hold ends without a verdict --
the shim prints nothing, which both agents read as "no decision", so their
own prompt carries on -- when it lapses, when the agent ran the tool (the
matching `PostToolUse`) or the turn moved on (`Stop`, `StopFailure`,
`UserPromptSubmit`, `SessionEnd`, `Interrupt`), when the hook process is
gone, when `open_session` opens the session to answer it there, or when the
daemon stops. Claude Code shows its own prompt while the hook runs and takes
whichever answer comes first, so a hold costs it nothing; Codex asks its
hooks before it shows the prompt, so a Codex request is not held while its
terminal is the frontmost app, and a held one is let go within a second of
its terminal coming to the front, so the owner who switched there to answer
sees the prompt. `ExitPlanMode` is never held: its answer is
a plan, not a yes. Claude's `AskUserQuestion` is held as a choice when every
question and option can be offered exactly (1–4 questions with distinct
texts, 1–8 distinct printable labels each, no comma in a multi-select
label, the input under 24 KiB); anything else keeps the agent's own
prompt. On a held question `approve` and `always` are never sent -- a bare
allow would run it with no answer -- so `approve` takes the keystroke path
it always had, and `deny` declines it like Esc. The question's request id
ignores `answers`, so the `PostToolUse` of a question answered in its own
prompt releases the hold. At most 16 requests are held at once; past that
they fall through.

Refusals on a held request: `stale_request` (the card's `request` is not the
live one), `stale_ask` ("That ask was already answered from JR-Bar.", "JR-Bar's
hold on that ask lapsed; …", "The agent stopped waiting for JR-Bar; …"),
`unsupported` (an `always` with nothing to remember, an `answer` on an ask
with no `choices` or with nothing held) and `invalid_args` (`answers` that
do not pick from the offered options for every question). A request the lane
does not hold goes through the checks above unchanged.

### Answering from serve

A Stream Deck key (or a script) can answer through the loopback endpoint,
on the one answer path the panel uses (`serve_answers.py`). Both routes are
bearer-authenticated like `/status.json` -- never anonymous, whatever
`--allow-anonymous-status` says -- and act only while
`serve_answer_enabled` is on (off by default; separate from
`serve_enabled`, since reading the fleet and answering for the owner are
different grants). The daemon's own server reads the switch on every
request; a standalone `jrbar serve --allow-answers` reads the switch and the
asks over `core.sock`, caching those reads for at most one second. An
unreachable daemon returns `unavailable`, HTTP `503`, rather than
`answering_off`. Its answers are refused there (`unauthenticated`,
HTTP `403`): answering is app-only on the socket, and only the serve server
inside the daemon answers, through the daemon's own dispatch and not the
socket. Its answer waits up to 12 s for the
reply -- past `answer_ask`'s own 6 s budget and the hops to the main
thread -- so a slow focus check is never reported as an unreachable monitor
while the answer is still delivered.

- `GET /asks.json` → `{ok: true, asks: [{session, provider, label, slot,
  kind, request, opened_at, preview, risk, decisions, choices}]}`: what is
  waiting, the deck `slot` (1-13, the current bank's key; null when none)
  showing it, one bounded line of what it wants, and the `decisions` an
  answer may carry -- `approve`/`deny` only while the ask is `answerable` and
  not yet `decided`,
  `always` only when the agent offered a rule to remember, `answer` only
  for a held question (`choices`); once the decide lane has `decided`, the
  hold is spent, and stays spent until the agent's own events close the
  request (7 days at most): neither `always` nor `answer` (nor its
  `choices`) is offered.
- `POST /answer` names one `session` (the daemon's id) or one `slot` and an
  explicit `decision`, in the query string (`/answer?slot=2&decision=deny`,
  for a key that can only send a URL) or a JSON object body (which wins
  where both name a field); `answers` (an object, JSON only) goes with
  `answer`, `request` pins the ask. A session runs `answer_ask`
  (`only_if_frontmost: true`), a slot `deck_answer`. A slot answer that
  pins no `request` is refused `stale_request` while the ask on that slot
  is under 1.5 s old: the key may still have shown the ask it replaced, so
  a second press answers the one it shows now. A standalone
  `jrbar serve --allow-answers` reads the switch and the asks over one core
  connection, reused for a second. `200 {ok: true,
  result: {session, decision, answered, delivered, mechanism, code,
  message, confirmation}}` -- never the host's pid, tty or window
  evidence. Refusals are `{ok: false, error: {code, message}}` with the
  answer path's own code: `400` `invalid_args`, `401` without the bearer
  token, `403` `answering_off`, `404` `not_found`, `413` for a body over
  16 KiB, `503` when the monitor is unreachable, `500` `internal` for a
  failure on the answer path itself, `409` for everything else
  (`stale_ask`, `stale_request`, `unsupported`, `not_frontmost`, `busy`, …).

### subscribe
Optional. A daemon advertising `state_slices` accepts
`subscribe {state_slices: true}` on that connection. The reply echoes the
mode. The greeting always includes a full `state`; after subscription,
changes arrive as `state_delta` instead. Clients that do not subscribe keep
receiving full states. An app connected to an older daemon uses full states.

```json
{"t":"state_delta","v":1,"generation":42,"base_generation":40,"now":1792968000,"slices":{"sessions":{"generation":8,"value":[]},"asks":{"generation":3,"value":[]}}}
```

Each top-level state field except `t`, `v`, `generation` and `now` is a
slice. A delta contains only changed slices, each with its own increasing
generation and a complete replacement value. `null` removes an optional
field. A removed collection is sent as an empty collection. The frame's
generation orders the combined state, so related changes apply together.
The existing volatile-field comparison also governs slice changes.

The `sessions` slice may instead contain `changes`, `removed`, and `order`.
`changes` maps session ids to changed row fields; a new id carries a complete
row. `removed` lists ids to drop. `order` gives the complete resulting id
order. A null row field clears that field. These edits apply to the last
snapshot sent to that connection, so a reconnect or a delayed greeting
cannot borrow another client's baseline.

An object slice may use `patch` instead of `value`. It is a list of edits
with a `path` of object keys and either `value` or `remove: true`. Arrays
are replaced as values. Null is a value; only `remove` deletes a key.
Edits apply in order to that slice's previous value. A client rejects a
patch whose path does not exist, and reconnects for a full snapshot.

Every delta carries `base_generation`, the generation of the previous
state transmitted to that connection, after coalescing. Generations need
not be consecutive. Before applying any slices, a client requires this
baseline to equal its current state generation. A missing or mismatched
baseline rejects the whole delta and reconnects for a full snapshot.
This catches skipped and reordered object patches and roster edits.

A client needs a full state before applying deltas. It ignores deltas
older than that state and repeated slice generations. A reconnect resets
slice generations and receives a full state before taking live changes.
Coalescing compares against the last state sent, so an intermediate change
cannot disappear from the next delta. An unreadable delta makes state
untrusted just as an unreadable full state does.

LED write counters and timings travel in `lights.device_write_health`, a
dictionary keyed by device id. Slice subscribers do not receive
`devices[].write_health`. Full states retain that field for older clients.
The lights generation advances independently of the state slices.

### environment

`environment` is an app-authenticated command. The native app reports
workspace sleep, display sleep, session activation, accessibility display
preferences and the frontmost application identifier. `event` is one of
`wake`, `sleep`, `screens_wake`, `screens_sleep`, `session_active`,
`session_inactive`, `clock`, `timezone`, `accessibility`, or `snapshot`.
The four accessibility flags are booleans in `accessibility`; the optional
`frontmost` is a bundle identifier. A snapshot also supplies `display_asleep`
and `session_active`. These are local sensor readings. The daemon applies
the existing DND and presentation policies. The app already owns these
workspace observations. Until a connected app successfully reports all four
accessibility flags, the daemon keeps a native workspace fallback for
accessibility changes, sleep/wake, display sleep, session and clock edges.
A two-second startup grace lets a capable app report before the fallback
starts. Without a report, including with a 0.9.17.2 app or no app,
IOKit supplies sleep/wake notifications. CoreGraphics supplies display and
session readings once a second, and Foundation supplies clock notifications.
The fallback reads available boolean accessibility preferences from
`com.apple.universalaccess`. An absent or unsupported preference keeps its
last known flag, or conservatively reduces effects until the app reports
the exact flag. A valid report stops native observations; losing that
reporting connection restores them. The fallback loads neither AppKit nor
PyObjC. The socket command and its ownership rules are unchanged.

## Hook shim

`jrbar-hook` (`hook/jrbar-hook.c`, built by `hook/build.sh` into
`hook/build/jrbar-hook`) is the compiled hook command. Provider configs
invoke it as `jrbar-hook --provider codex --log <path>` (`--log` is kept
for compatibility; the daemon decides where records go). It reads stdin
(max 1 MiB), connects to `$XDG_STATE_HOME/jrbar/hook-ingress.sock`
(`JRBAR_STATE_DIR` overrides the directory) and sends one frame in the
existing ingress wire format:

```
JRBARHOOK\x01 + be32(header length) + be32(payload length)
  + json({"version":1,"provider":"codex","log_path":"…","ppid":<getppid()>,"ppid_start":<proc start epoch>})
  + <stdin bytes>
```

It waits up to 200 ms for the disposition and exits 0; everything after it
has read stdin is capped at 250 ms. Every such budget, the spool lock wait
and the 50 s decide wait are timed on a clock that only moves forward
(`CLOCK_UPTIME_RAW`, the one `poll(2)` and the daemon's own hold use), never
the wall clock, so a clock correction cannot stretch a wait and a wake from
sleep cannot make it look spent; the only wall-clock read is the
`queued_at_ms` stamped on a spooled record. Measured on this Mac (2026-09-09, 100 invocations from a
shell loop): 6.2 ms wall per invocation of which 3.3 ms is the bare
fork/exec (`/usr/bin/true` in the same loop), so the shim's own work is
about 3 ms; from Python's `subprocess.run` the median is 5.7 ms; the
Python hook client took 88 ms. If the socket is absent, the budget cut
the frame short, or the daemon answered `refused_full` or `refused_closed`
(its queue holds 128 hooks and 16 MiB of payload; a connection that finds
all eight connection slots busy is answered `refused_full` unread), the shim appends
`{"provider","ppid","ppid_start","queued_at_ms","payload"}` as one JSON
line to `$XDG_STATE_HOME/jrbar/<provider>.pending.jsonl` (mode 0600) and
exits 0; at 16 MiB the file rotates to `<provider>.overflow.jsonl` (one
generation) and a fresh one starts. A record ends at a newline and nowhere
else: U+2028, U+2029 and U+0085 inside a payload are data (the shim copies
every byte at or above 0x80 verbatim), so the drain, `hooks_doctor`'s
`pending_lines` and `doctor`'s "pending hook lines" check split the file on
`\n` only. Every append and rotation holds an
`flock` on the file its path still names, and the daemon takes that lock on
a file it has renamed to drain, so no line lands in a file after it was
rotated or read. The daemon drains those files at launch,
every 30 s after that, and 0.3 s after a queue that refused a payload is
empty again. The launch drain runs before the sockets open but stops at a
1.5 s budget (a line costs about 4 ms, so a full 5000-line file would keep
the daemon deaf for about 21 s); the drain thread then finishes the same
pass, the same files and lines in the same order, while the sockets are
open. Live hooks that arrive meanwhile are accepted and processed after the
backlog, so it still lands ahead of them, and a `--decide` hook among them
is not held (its agent's own prompt appears at once). A drain thread that
is stopped mid-pass puts back the lines it never reached. Every drain
registers each payload's agent process from `ppid`/`ppid_start` (for a node-hosted CLI such as pi or
Gemini the nearest `node` ancestor is the agent process); a line whose
`ppid_start` is -1 still replays but registers no process, since only the
start time tells a later replay that the pid was not reused. A record queued within the last
30 min replays as a live one, logged at the drain time: the live monitor
keeps one watermark per provider source, shared by every session, and a
record stamped earlier than another session's newer hook would be skipped.
One older than 30 min is logged at its `queued_at_ms` (capped at the drain
time) and does not wake the live monitor.
For Cursor and Gemini CLI the shim prints `{}` on stdout as those hook
contracts require (`--emit-empty-json` forces it for any provider);
otherwise it prints nothing.

A payload past 1 MiB (a PostToolUse carrying screenshots, a PermissionRequest
for a very large Write) is never forwarded or spooled whole. For `--provider
claude` and `codex` the shim reads the top-level keys of the first MiB it
already holds, buffering nothing more, and sends or spools a small record in
its place: `hook_event_name`, `session_id`, `tool_name`, `turn_id`,
`agent_id` and `transcript_path` when each is plain printable ASCII (at most
256 bytes, 1 KiB for the path), the call's own `tool_input` when it is a
whole object of at most 64 KiB, otherwise `payload_fingerprint` (the 64-bit
FNV-1a of the first 64 KiB of that input's text, 16 lowercase hex digits),
and `"payload_truncated":true`. The content is never copied. A head that does not name both the event and the session,
and every other provider, is dropped as before. The daemon reads the record
as the event it names: a PostToolUse resolves its request, a PermissionRequest
opens an ask, and neither is ever parked for a verdict. The request id is
the turn, the tool and the input (`provider_adapters`), so a record that
kept its input names the same request as the whole payload would have, and
one whose input was too large to keep names its call by the fingerprint, which
an ask and its PostToolUse cut down the same way share and a different huge
call in the same session does not (two huge calls whose first 64 KiB are
identical are one request). A PostToolUse cut down after an ask that arrived
whole does not resolve it; the ask clears when the turn ends. The shim
sends no `decide_ms` for such a record and prints nothing, so the agent's own
prompt appears at once; `permission_facts` refuses it too. `python -m
jrbar.hook_client`, the command that runs when no compiled shim is installed,
does the same for Claude and Codex: it reads at most the first MiB and a byte,
builds the same record with the same rules and fingerprint, and sends it as an
ordinary hook (a test feeds one payload to both and compares the two records);
every other provider's oversize payload is still dropped.

A `ppid` of 1 or less in a frame means the agent had already exited and
launchd had adopted the hook. The daemon reads such a frame as carrying no
`ppid` (and no `ppid_start`), so it registers no process from it, and
delivers the event instead of refusing it, whether the frame arrives live
or from the spool. A `--decide` frame with such a `ppid` is still refused
`refused_invalid`: an agent that is gone cannot be waiting for a verdict, so
nothing is parked.

A connection that closes before sending a byte is a liveness probe (`jrbar
hooks doctor` and the daemon's own `hooks_doctor` connect and close the
ingress socket). It is answered `refused_invalid` as before, so a bare
close is never read as delivered, but it is neither counted nor written to
the rejection log. A non-empty frame that fails to decode still is.

`--decide` (the decide lane, installed only on Claude's and Codex's
`PermissionRequest`) adds `"decide_ms":50000` to the header. Delivery and
spooling are unchanged and keep the 250 ms budget; the shim then keeps
reading for up to 50 s after its payload arrived. The daemon replies with
the disposition line and, when a click decides, one more line -- the
verdict document -- and closes the connection; the shim prints that line
only if it is whole, follows `accepted` and opens a
`{"hookSpecificOutput":` document (64 KiB cap). A lapsed or released hold,
a daemon that is down, or any other reply prints nothing. `python -m
jrbar.hook_client --decide` does the same when no shim is built. A parked
connection hands its worker slot back before it waits, so held requests
never starve ordinary hooks of the ingress's eight connection slots.

A `SessionStart` from the shim also records where the session started, for
`open_session`, in `<state>/session-surfaces.json` (0600, 256 sessions, 14
days), on its own thread: the terminal app its ancestry reaches (from the
process table -- no permission involved; a provider's desktop app and tmux
are not recorded), and in Ghostty the exact terminal surface -- when Ghostty
is frontmost, macOS already allows the daemon to send Ghostty Apple events
(`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded` false:
starting an agent never raises a permission prompt), and the focused
terminal of its front window is in the session's directory. Every start
the owner makes (`source` `startup`, `resume`, `clear`, `fork`, or none)
replaces the record, and one that cannot place the session forgets the old
surface, so a session resumed elsewhere is never raised -- or proven -- in
the terminal it left. A `compact` start, which fires on auto-compaction with
whatever terminal the owner is reading in front, keeps the record it finds.

`install.hook_command_arguments` registers the shim when `JRBAR_HOOK_EXEC`
names one (an empty value disables it), when a bundled copy sits beside a
frozen executable, or when a source checkout has built
`hook/build/jrbar-hook`; otherwise `python -m jrbar.hook_client` as before.
The development layout installs `~/.local/share/jrbar/bin/jrbar-hook`
(`scripts/install-agents.sh` copies it there, sets `JRBAR_HOOK_EXEC` in the
daemon's LaunchAgent, and runs `jrbar agent-monitor install all` so every
provider with a config on this Mac -- claude, codex, devin, grok, cursor,
hermes, openclaw, opencode, antigravity, kiro, pi, gemini -- runs it; an
installed package can also locate a sibling shim). The packaged app uses
`Contents/Helpers/jrbar-hook` and the chosen-provider policy below. Provider
configs do not name that path, which dies with the bundle: they run a launcher
at `~/.local/share/jrbar/hook/jrbar-hook` (a small `sh` script, mode 0755, that
runs the bundled shim and exits 0 when the bundle is gone, so a trashed or moved
app never fails an agent's tool call). `install.stable_hook_shim` writes it on
every install and refresh, and the app's hook stamp includes the bundle's shim
path, so moving the app between `~/Applications` and `/Applications` refreshes
the hooks once. `jrbar agent-monitor uninstall all` removes the launcher with
the last hook. A shim outside an app bundle (the development layout) is named
as it is.
The OpenClaw handler,
the OpenCode plugin and the pi extension embed the shim argv; Antigravity's
envelope pipes into it.
Both shapes are recognised as ours by every installer, uninstaller and
detector, and the Codex trust hash is computed locally for whichever is
written. `jrbar hooks doctor` shows, per provider, the command registered
today (read from JSON and TOML configs, folded YAML, the argv arrays
embedded in handlers, and the Antigravity envelope) and the one an
install would write, the shim path, whether the ingress and core sockets
answer, and any queued payloads; for Claude and Codex it also says whether
the decide lane is installed (`decide=installed|missing|not_installed`).
An install from before the lane existed keeps working and reads `missing`
until Settings › Agents & Usage reinstalls the hooks.

### Claude Code's status line (`--statusline`)

`jrbar-hook --statusline [--then <command>]` is Claude Code's `statusLine`
command when the person turns on Settings › Agents & Usage › Advanced › Claude Code status line
(or runs `jrbar agent-monitor install claude-statusline [--wrap]`). It sends
the statusLine JSON as one frame whose header carries `"kind":"statusline"`
(provider `claude`). The daemon never treats that frame as a hook event:
it keeps only `session_id`, `model.id` and `rate_limits.five_hour` /
`rate_limits.seven_day` (`used_percentage`, `resets_at`), drops a window
whose reset has passed, and never touches session liveness, because the
status line re-renders while Claude is idle (`claude_statusline_source`).
The Claude collector uses that reading only when the OAuth usage endpoint
is rate limited, signed out, unavailable or not connected; its lanes carry
`source: "claude-statusline"`, and after an OAuth failure the endpoint
rests (10 min after a 429) while the status line covers for it. Nothing
is spooled when the daemon is down. The shim then prints
`$XDG_STATE_HOME/jrbar/statusline.txt` (one line, at most 256 bytes, e.g.
`JR-Bar · 2 working · 1 needs you · 5h 58% left`; empty while
`statusline_text_enabled` is off), and with `--then` runs the person's
previous statusLine command through `/bin/sh` with the same stdin and
prints its output after JR-Bar's line (3 s and 4 KiB at most). Install
never replaces an existing `statusLine`: without `--wrap` it is refused;
with it, the old command moves into `--then`, and uninstall puts the old
value back exactly. `claude_statusline_install {wrap}` and
`claude_statusline_uninstall` are the Settings switch's commands; the
first answers `{installed, wrapped, needs_wrap, message}` and asks before
wrapping.

### Pi and Gemini CLI

Pi (`@mariozechner/pi-coding-agent`) runs TypeScript extensions in-process
under Node. `jrbar agent-monitor install pi` writes
`~/.pi/agent/extensions/jrbar.ts` (marker `jrbar-pi-extension-v1`; an
unmanaged file is never overwritten), which spawns the shim argv baked at
install time (`HOOK_COMMAND`; the Python client as `FALLBACK_COMMAND`)
with a Claude-shaped payload `{hook_event_name, session_id, cwd,
transcript_path, tool_name?, source: "pi"}` on stdin, never awaiting it:
`session_start`→SessionStart, `before_agent_start`→UserPromptSubmit,
`tool_execution_start`→PreToolUse, `tool_execution_end`→PostToolUse,
`agent_end`→Stop, `session_shutdown`→SessionEnd. `before_agent_start`
fires once per submitted prompt where `turn_start` fires once per model
turn, which announced the prompt again after every tool result. Pi has no
ask lane and no event to give it one: 0.73.1's `ExtensionEvent` union has
no `ui_prompt_start`/`ui_prompt_end` (that pair was a mistake), and its
tool gate, `tool_call`, asks an extension for `{block, reason}` rather
than a person.
Transcript fallback (`transcript_monitoring.pi`) reads
`~/.pi/agent/sessions/**/*.jsonl` (header `{"type":"session",…}`).

Gemini CLI hooks live under `hooks` in `~/.gemini/settings.json`
(`{"matcher":"*","hooks":[{"name":"jrbar","type":"command","command":…,"timeout":5000}]}`;
every other key, and Antigravity's `~/.gemini/config/hooks.json`, is
untouched): SessionStart, BeforeAgent→UserPromptSubmit, BeforeTool→PreToolUse,
AfterTool→PostToolUse, Notification (`notification_type: ToolPermission`
becomes PermissionRequest on ingest), AfterAgent→Stop, SessionEnd. The
hook's stdout must be a JSON object, so the shim prints `{}`. Transcript
fallback (`transcript_monitoring.gemini`) reads
`~/.gemini/tmp/<project>/chats/session-*.jsonl`.

### OpenCode

`jrbar agent-monitor install opencode` writes a plugin that hands the shim
one small Claude-shaped payload per OpenCode event, in order, on stdin:
`{hook_event_name, session_id?, request_id?, notification_type?}` plus the
event's `sequence` and `timestamp` when it has them. Only opaque ids are
forwarded, never a prompt, command, path or question text. The events it
forwards:

| OpenCode event | hook event |
| --- | --- |
| `session.created` | `SessionStart` |
| `session.status` (`active` or `busy`) | `UserPromptSubmit` |
| `session.idle` | `Stop` |
| `session.error` | `StopFailure` |
| `permission.asked` | `PermissionRequest` |
| `question.asked` | `Notification` with `notification_type: "input_required"` |
| `permission.replied`, `question.replied`, `question.rejected` | `PostToolUse` |
| `tool.execute.before`, `tool.execute.after` | `PreToolUse`, `PostToolUse` |
| `session.compacting` (or `session.compact.before`) | `PreCompact` |
| `session.compacted` (or `session.compact.after`) | `PostCompact` |

An ask is named by its request id, and the two halves of the pair spell it
differently: `permission.asked` and `question.asked` carry it as
`properties.id`, while `permission.replied`, `question.replied` and
`question.rejected` carry it as `requestID`. The plugin reads the id from
each event the way that event spells it, so a reply resolves the ask it
answers. An asked event whose id is not an opaque identifier is forwarded
without a `request_id` and reads as an ask with no identity; a replied or
rejected event with a malformed `requestID`, or any event with a malformed
session id, is dropped.

## Running it

```sh
python -m jrbar core                    # headless daemon on ~/.local/state/jrbar/core.sock
python -m jrbar core --socket /tmp/x    # elsewhere (tests; AF_UNIX paths are capped at 104 bytes)
JRBAR_TRACEMALLOC=1 python -m jrbar core   # + a tracemalloc report in the log every 60 s (a number = seconds)
```

The old Python menu bar (`jrbar status-bar start`) is gone. The daemon
unloads and deletes its LaunchAgent (`com.jonathanreed.jrbar.app`, and the
pre-rename `io.sidepulse.agentstatus`/`com.sidepulse.agentstatus`) at
startup; `jrbar status-bar stop` does the same by hand.

On this Mac the running pair is the packaged app, `~/Applications/JR-Bar.app`
(installed from `dist/JR-Bar-<version>.pkg` by `make clean-install`, which
puts it there without a password): the app supervises
`Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core core` as its
child (`JRBAR_SUPERVISED=1`, `JRBAR_HOOK_EXEC` = the bundled shim,
`JRBAR_COMMIT` from the bundle's `JRBarCommit`) and registers itself as a
login item. A fresh installation leaves provider configs alone until the
person connects a provider in Settings › Agents & Usage. On an upgrade, the app
asks the live daemon to `refresh_hooks` for its currently owned integrations,
preserving disabled flags and custom log destinations. It records the new
build stamp only after the daemon affirms every selected result.
launchd is not involved: no LaunchAgents,
no `~/.local/share/jrbar` venv. The daemon's `doctor` reply carries the
`commit` it was built from (`-dirty` = uncommitted changes) and a `memory`
field (`rss_mb`, `peak_rss_mb`; with `JRBAR_TRACEMALLOC` also `traced_mb`
and the top files). The frozen daemon sits around 160–200 MB RSS, of which
roughly 100 MB is shared framework text (`footprint <pid>` shows the
private ~110 MB).

Stop, reinstall, start:

```sh
osascript -e 'tell application "JR-Bar" to quit'   # the app stops its child (SIGTERM, 3 s grace)
installer -pkg dist/JR-Bar-<version>.pkg -target CurrentUserHomeDirectory
open ~/Applications/JR-Bar.app
~/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core hooks doctor
```

`hooks doctor` prints the shim the daemon would install (the bundled
`Contents/Helpers/jrbar-hook` when frozen) and what each provider's config
runs today; every provider must say `runs=shim`.

Under the Swift app in development: `JRBAR_CORE_EXEC=scripts/run-core.sh`
makes the app spawn and supervise the daemon (`CoreSupervisor`; the script
execs `.venv/bin/python -m jrbar core`, passing `JRBAR_CORE_SOCKET` through
as `--socket`). A dev daemon run by hand (`.venv/bin/python -m jrbar core`)
needs the packaged app quit first: one process owns the event socket. A
daemon started that way holds no app secret, so it refuses privileged commands
(see "Who may send what"); `JRBAR_DEV_ALLOW_UNAUTH=1 .venv/bin/python -m jrbar
core` lets a source checkout take them from any connection, for development
with no app attached. The frozen release daemon ignores that variable. A
daemon the app starts, `JRBAR_CORE_EXEC` ones included, is handed the secret
and needs no variable.

The two development LaunchAgents (`com.jonathanreed.jrbar.core` / `.ui`,
`scripts/install-agents.sh`) are parked as `*.plist.disabled` in the state
directory; `scripts/install-agents.sh --pkg` is what `make clean-install`
runs, plain `scripts/install-agents.sh` puts the dev layout back and turns
the login item off.

## The Dot's role (`lights.surfaces.dot.role`)

Added 2026-09-10. A linked Dot has two LEDs and, until now, exactly one
job: replay the strip. That is one good answer, not the only one, so the
Dot now carries a **role** — `dot_role` in the settings document, and
`role` on the `dot` surface of every `lights` frame.

```json
"dot":{"program":"brightness 46\n#FF9F0A 1200ms cosine\noff 1200ms cosine\nrepeat",
       "led_count":2,"anchor":1788982891.31,"brightness":0.8,
       "role":"asks","why":"waiting","why_detail":{…}}
```

| `role` | what the Dot plays |
| --- | --- |
| `extend` (default) | The strip's own program, phase-locked, **rendered for two LEDs**. The strip's eight indices are downsampled into two bands (0–3 and 4–7), each band showing its brightest lit colour, so a chase still sweeps and a solid colour stays solid. Every line the conversion emits addresses **both** LEDs (or paints the whole strip), and the conversion is a pure function of the strip's program: an LED painted once and then left unmentioned holds that colour until something writes again, which on 2026-09-10 was a green from a finished program sitting on the Dot indefinitely. |
| `asks` | A designated attention beacon: dark while everything is fine, lit only when a session needs the person. A glance at the Dot alone answers "do they need me?". |
| `status` | The Dot renders its own two-LED semantic display (`dot_binary_heartbeat` through the ambient dispatch), exactly as an unlinked Dot always has. `role` is then absent from the frame: nothing is driving the Dot but the Dot. |

`extend` also carries the strip's brightness, once. The strip's own
`brightness` lines are the Dot's too (`linked_follow_brightness`),
`linked_dot_scale` (default 0.3) takes a fraction of the **light** each one
means, and the write boundary does the one sRGB decode. Scaling the code instead and letting the boundary decode the
result is the same arithmetic in the wrong domain: 0.3 arrived at the
hardware as 6.7% of the strip's light. `asks` is not scaled at all -- a
beacon dimmed to a third is a beacon nobody notices.

`role` appears on the `dot` surface only, and only while a role is
actually driving it (never on a `preview`). It is `jrbar.dot_role`'s
answer, and it **outranks the per-device display kind**: that kind is
recorded by the render path a role takes away, so on a role-driven Dot it
freezes at whatever it was the last time the Dot rendered for itself. That
is why a Dot could sit at `why: "capacity"` for hours after a quota alert
had gone, next to a strip that said `working`. The role now decides the
Dot's `why` as well as its program.

### The `asks` beacon

| state | colour | cadence |
| --- | --- | --- |
| nobody is needed | dark (`off`, so the device's own `resting_glow` applies) | — |
| an ask is open (`aggregate.needs_you`) | amber `#FF9F0A` | breathes; tightens with the escalation stage |
| something is blocked or failed (`aggregate.failed`) | error red `#B00020` (`colors.MODE_ERROR`) | the stage-2 cadence, whatever the ask's age |
| an unseen completion (`aggregate.ready`) | green `#00FF66` | the slowest cadence — and **only** when `dot_role_include_completions` is on |

Precedence is the person's: blocked outranks waiting, which outranks
merely finished. The beacon returns to dark the moment the ask resolves.

Escalation is visible in the cadence, never in the flash rate:

| escalation stage | on / off | cycle | peak |
| --- | --- | --- | --- |
| 0 (none) | 1200 ms / 1200 ms | 2.4 s | 0.42 Hz |
| 1 (ramp) | 900 ms / 900 ms | 1.8 s | 0.56 Hz |
| 2 (menu bar) | 600 ms / 600 ms | 1.2 s | 0.83 Hz |
| 3 (final) | 500 ms / 500 ms | 1.0 s | 1.0 Hz |

Both phases are `cosine`, so it is a breath and not a blink. Every cadence
sits at or under 1 Hz — half the `presentation_compiler` ceiling of 2 Hz,
and exactly at its 1 Hz saturated-red ceiling, so the red state needs no
separate table. The compiler is still the authority; `dot_role` simply
never hands it work to do.

### The `call` role, and a shut lid

Added 2026-09-22. `dot_role: "call"` makes the Dot a presence light the way
a busylight is one: a **steady** red `#FF2D20` -- held, never breathed, it
sits in view of the camera -- while `state.presence.on_call` is true
(`why: "on_call"`, `reasons: ["presence", "on_call"]`) and for the whole
of a calendar meeting while `state.presence.in_meeting` is (`why:
"in_meeting"`; a live call names itself first), the way Kuando marks the
meeting and not only its start, and exactly the `asks` beacon above the
rest of the time. It reads the devices, not a call
app's API, so it works for every call app, and between calls it still says
whether an agent needs the person. Like `asks` it needs no strip
(`lights.dot_link.state` is `beacon`), is never scaled by
`linked_dot_scale`, and is never what a linked Screen Bar mirrors.

With the lid shut (the daemon's lid reading, `state.power.closed_lid.lid_closed`),
an `extend` Dot has nothing in view to continue -- the strip in the SD slot
and the notch band are both behind the lid -- so it plays the `asks` beacon
instead, unscaled: the surface's `role` reads `asks` and its `reasons`
carry `auto:lid_closed`. The stored `dot_role` is untouched; the Dot goes
back to `extend` when the lid opens.

### Settings

Both live in the `settings` document and are writable with `set_setting`:

| path | type | default | meaning |
| --- | --- | --- | --- |
| `dot_role` | `"extend"` \| `"asks"` \| `"status"` | `"extend"` | What the Dot is for. An unknown value reads as `extend`. |
| `dot_role_include_completions` | bool | `false` | Whether the `asks` beacon also lights green for a completion nobody has looked at yet. |

Migrated once, on the first load of a settings file with no `dot_role`
key: a Dot whose per-device `led_display` was pinned to a dedicated
readout (`quota_runway`, `studio`, `battery`) meant "do not follow the
strip", and becomes `status`. Everything else — `agent` above all — held
no opinion and becomes the `extend` default. Once the key exists it is the
only answer.

### The write boundary

No program rendered for one LED count may reach a device with another.
`device_writer.write_led_program` refuses a program that addresses LEDs the
target does not have — both spellings, a colour list longer than the device
and a named index past its last LED — logs the refusal to stderr, and
raises `DeviceWriteError`. The animation validator calls both of those a
*warning* (the firmware parses the extra and then discards it), which is
exactly why nothing noticed an eight-colour strip program being written to
a two-LED Dot: LEDs 0 and 1 were black in most frames of the chase, so a
lit strip sat beside a Dot that looked dead.

## Keeping the Dot on the strip's beat

Added 2026-09-24 (`jrbar.linked_sync`, `jrbar.device_clock`,
`jrbar.linked_runtime`). The firmware starts a program's clock when it
parses the file and has no start time, epoch or sync directive, and the
first Dot's own clock runs about 2.7% slow (its `STATUS.TXT` `ticks`
advance about 973 ms per 1000 ms of real time; the Pro's `uptime_ms`
matches the Mac's to 0.02%). So:

- **One start.** The daemon records `A_pro`, the moment the followed strip
  took its current program -- the fsync return of that write, reasserts
  included -- and the Dot, the Screen Bar (`screen_bar_anchor`) and the
  lights document's `dot` anchor all use it. A Dot-only write never moves
  it.
- **Every Dot write is phased from it.** After the safety gate has judged
  the Dot's program in real milliseconds, the write boundary rotates it to
  the phase the strip will be on when the Dot parses it (a `pulse` cut
  mid-flight becomes its two `cosine` halves; a curve cut part-way is
  spelled with the easing that fits it) and retimes it for the Dot's clock,
  every lap exact to half a millisecond. The firmware parser checks the
  exact bytes; the gate never re-judges the scaled text. Over budget, the
  cut moves to the nearest line boundary, then to none.
- **A strip restart always restarts the Dot**, whatever the Dot's deduper
  thinks; the Dot's dedupe token carries `A_pro` and never the rotation.
- **The period is locked.** The strip's program is compiled once at its own
  LED count and the Dot is derived from that; if the Dot's own gate would
  change the loop's length it steps down (band average, `none` softened to
  `linear`, the loop's mean colour held still) instead.
- **The loop closes.** Every 20 s a fresh read of the Dot's `ticks`
  (mmap + `msync(MS_INVALIDATE)` + `pread`, on a worker thread, abandoned
  after 0.5 s) feeds a per-device rate estimate, saved in
  `~/.local/state/jrbar/device-clocks.json`. Between reads the error is
  predicted from the measured drift; past 75% of the tolerance the Dot
  alone is re-anchored, at most once every 20 s. The strip is never
  rewritten for sync.

### Settings

| path | type | default | meaning |
| --- | --- | --- | --- |
| `linked_dot_clock_correction` | bool | `true` | Retime the Dot for its clock and close the loop. Off, every Dot write still starts on the strip's beat but drifts between writes. |
| `linked_dot_phase_trim_ms` | number, -250..250 | `0` | A constant nudge of the Dot against the strip; positive runs it ahead. |
| `linked_sync_tolerance_ms` | number, 20..200 | `40` | How far the Dot may drift before a re-anchor. |
| `dot_extend_style` | `"continue"` \| `"mirror"` | `"continue"` | Let light run off the end of the strip into the Dot (travelling light only: a comet or chase crosses it, a fill completes into it; anything else mirrors), or fold the strip into two bands. |
| `dot_extend_side` | `"after_last"` \| `"before_first"` | `"after_last"` | Continue only: where the Dot sits as you face the pair, `after_last` on the strip's right (past LED 7 on a strip running forward), `before_first` on its left. Each device's `devices[].led_direction` (default `forward`: LED 0 on the left) says which way round it is mounted, so a strip turned round hands its light on from LED 0, and the light enters the Dot at its LED nearest the strip. |
| `linked_follow_brightness` | bool | `true` | A linked Dot takes the strip's brightness lines times `linked_dot_scale` (in light), capped by its own manual brightness, and ignores its own auto-brightness. |

Brightness, on the strip and the Dot alike (upstream #38): every authored
`brightness M` becomes `round(M·N/255)` for a device cap `N`, and `N` goes
in front only when the program has none and `N < 255`. A custom
`brightness 255` no longer escapes the cap.

### Commands

| command | args | result |
| --- | --- | --- |
| `linked_sync_check` | `{seconds?}` (default 60, 10-120) | `{until, devices}`. Both devices flash white for 80 ms every 2 s, the Dot timed like any linked write and re-anchored by the loop if it drifts; both are held (like a calibration preview) until `until`. `not_ready` unless the Dot is linked with role `extend` beside a strip; `busy` under a calibration hold. |
| `eject_guard` | - | The SD eject guard as launchd has it: `{installed, scope, plist_path, volume_uuid, run_at_load, keep_alive, loaded, running, runs, pid, last_exit, protects, mounted_volume_uuid, mounted_name, protects_mounted}`. Read-only. |
| `protect_sidepulse` | - | Reinstalls the guard for the mounted SidePulse's volume UUID (user scope, started) and answers like `eject_guard`. Only ever from the person's click. `not_found` with no SidePulse mounted. |
| `release_sidepulse` | - | Puts the guard back to protecting nothing (its plist without a volume, reloaded, so the running guard stops and Finder can eject the SidePulse again) and answers like `eject_guard`. Only ever from the person's click. `not_ready` when it is not protecting anything. |

## Light and presence settings the legacy window owned

Added 2026-09-22. These keys were always in the `settings` document; until
now only the PyObjC window wrote them. Every one is a plain `set_setting`
path, validated by the real settings loader:

| path | type | default | meaning |
| --- | --- | --- | --- |
| `calendar_alerts_enabled` | bool | `false` | A calm purple glow before a timed event starts. |
| `calendar_lead_minutes` | number (1…60) | `5` | How long before the event the glow starts. |
| `reminder_alerts_enabled` | bool | `false` | An amber glow when a Reminder comes due. |
| `battery_monitoring.charging_idle_enabled` | bool | `true` | The charging fill while idle and plugged in. |
| `battery_monitoring.show_on_power_change` | bool | `true` | The short power-change preview. |
| `battery_monitoring.low_battery_threshold_minutes` | number (0…120) | `0` (off) | The low-battery warning by time left rather than charge: a fast drain at 20 % can be closer to empty than a slow one at 8 %. While agents run on battery under a keep-awake hold it fires at twice this. Never on an estimate macOS is still making, never on AC. |
| `rainstick_night_enabled` | bool | `false` | Let the Rainstick drip inside the night scene too. |
| `milestone_odometer_steps` | list of positive ints (at most 16) | `[10, 25, 50, 100]` | The completion counts that earn the milestone cue. |
| `ambient_cues_disabled` | list of cue ids | `[]` | The semantic cues switched off (`list_cues`, `set_cue`). |
| `calibration_profiles` | object: slot → device id → `{brightness, red_gain, green_gain, blue_gain, resting_glow}` | `{}` | Written by `calibration_profile save`. |
| `focus_profile_rules` | object: Focus id → slot | `{}` | Write the whole object (Focus ids contain dots). |
| `devices.N.blend_mode` | `color_blend` \| `round_robin` \| `spatial_split` \| `relay` \| `cycle` \| `classic` \| `alternate` \| `weave` \| `tide` \| `effect`, or null | null | A per-device blend, so eight discrete LEDs can take per-provider blocks while the band stays smooth. Null (or an unknown word) follows the global `colors.blend_mode`. The override accepts the same mix ids as the global setting. |
| `call_quiet_mode` | `off` \| `sounds` \| a quiet-mode word | `sounds` | What a call does (`presence`). |
| `meeting_quiet_mode` | `off` \| `sounds` \| a quiet-mode word | `off` | What a calendar meeting does. |
| `away_quiet_mode` | `off` \| `sounds` \| a quiet-mode word | `off` | What an empty desk does (a locked screen or five idle minutes, as the app reports them): `asks_only` keeps the Dot beacon and every ask lit while the rest goes quiet, `dark` turns the desk off like Lolgato. The report expires after 180 s, so the quiet cannot outlive the evidence. |
| `escalation_tier_by_provider` | object: provider id → `light`/`menu_bar`/`chime`/`takeover` | `{}` | A ceiling per provider under `escalation_tier`, judged on the oldest open ask's provider: Claude's asks may climb to the chime while another provider's never go past the light. It only ever lowers the stage (the global tier arms the finale). |

## LED motion settings (2026-09-24)

The live light for one working agent is now drawn by the same renderer as
its Settings thumbnail and its Effect Studio preview
(`motion_shapes.render_motion`). These keys shape it:

| path | type | default | meaning |
| --- | --- | --- | --- |
| `colors.blend_mode` / `colors.mix_mode` | `color_blend`, `round_robin`, `spatial_split`, `cycle`, `alternate`, `relay`, `weave`, `tide`, `classic`, `effect` | `color_blend` | Global Mix for two or more working providers. Only `colors.blend_mode` is stored. `colors.mix_mode` is a protocol read/write alias; an old file containing only that key is migrated. When both exist, `blend_mode` wins. Device `blend_mode` overrides still take precedence. `classic` holds the aggregate state colour for several providers and for idle or Done. A single working provider plays its own animation under every Mix. |
| `colors.mix_effect` | object: `{effect_id, parameters}` | `{}` | Library effect for Mix `effect`. Plays only while at least two providers work. Each provider gets one complete effect cycle in its colour, regardless of session or group count. Parameters belong to this Mix effect, separate from provider parameters. Asks win. Unknown effects or programs over 512 bytes or 20 lines fall back with a `what_plays` warning. Old daemons ignore this object and treat the unknown mix as their default. New apps offer this choice only when the mix catalog includes `effect`. |
| `colors.mix_parameters` | object: mix id → {parameter: value} | `{}` | Studio values for each mix. `duration_seconds` is one pass or beat, clamped 0.3–10 seconds; `width` is the beam or stripe width in LEDs, clamped 1–8; `softness` is the Relay beam's trailing fraction, clamped 0–1. `what_plays` reports when an exact program exceeds 512 bytes or 20 lines. The fallback is One at a time if the full provider animations fit, then Alternate, then Smooth. No fallback rewrites settings. |
| `colors.mix_schema_version` | integer | `1` | Stored mix semantics. Loading a document without version 1 migrates global and device `relay` selections from old Spotlight to `cycle`, One at a time. This keeps provider turns, now across the whole strip for four seconds each. Relay selected under version 1 is the new scanner and stays Relay on reload. |
| `colors.provider_animation_parameters` | object: provider id → {parameter: value} | `{}` | The Effect Studio values a provider's motion was assigned with (`set_assignment` at provider scope writes them; clearing the assignment, or choosing Automatic, removes them). `duration_seconds` gives that provider its own tempo instead of `colors.cycle_speed_seconds`. A file written before this key existed seeds every provider that already had a motion with the tempo its lone-agent light played (breathe 5.5 s, blink 1.6 s, anything else 2.2 s). An owned collection: a provider removed here stays removed. |
| `colors.tint_by_tool` | bool | `false` | The head of a Chase, Comet or Glint takes the colour of the working tool's family (shell, edit, read, web and MCP, task, plan); the tail keeps the provider colour (on a wiping Dot, the LED the light sets out from). Only a change of family can change the light, at most once every 3 s for each provider; asks and failures never take it. |
| `colors.done_celebration_style` | `bloom` \| `land` \| `ripple` | `bloom` | How a finish is celebrated while `colors.done_celebration_enabled` is on. Anything else reads as `bloom`. |
| `devices.N.led_direction` | `forward` \| `reversed` | `forward` | Which way round the strip is mounted. Reversed mirrors every agent light drawn for that device (LED `i` becomes `n-1-i`, rolls turn the other way), and a `preview_program` played on it. The Screen Bar ignores it. A linked Dot whose role is not `status` follows the Pro in desk order: the daemon turns a reversed Pro's program back before narrowing it, so flipping the Pro never turns the Dot's light round. Continue then reads that program as a forward strip, and the Dot's own setting only says which of its LEDs is nearest the strip (`dot_extend_side`); Mirror, Asks and Call ignore it. |
| `devices.N.dot_travel_style` | `wipe` \| `crossfade` | `wipe` | How a travelling motion plays on a two-LED device: LED 0 rises, LED 1 rises, LED 0 falls, LED 1 falls; or the older soft crossfade. A Dot plays it while it draws its own display: unlinked, or linked with the `status` role. |
| `lid_*_animation.shape` | a lid shape or null | null | A lid look drawn per device (the Iris looks); `program` then holds its eight-LED form. |

Provider turns fade into an animation's seed for at least 400 ms instead of painting
the next provider's colour immediately. Pulses fade to a dark starting frame
so they cannot return to the previous provider's colour. Blink retains its
steps after the entry fade. One at a time includes the entry within each
four-second hold, counting the firmware's 17 ms zero-duration paint frames.
Library effects keep their native motion after the entry fade. Alternate
and Relay already crossfade their provider entries. These transitions use
the same firmware budget and reported fallback rules as the animation.

Automatic follows the chosen providers' existing step grid when their step
durations match, keeping their native periods, curves and pauses intact.
When following Knight Rider, Scanner or Pendulum, Automatic draws that
sweep across its own LED share and fits the complete passes to the chosen
steps. It never samples a travelling path only at the turnarounds, which
would skip LEDs between them. Its sweep uses the chosen beam and background
parameters. Solo programs do not change.
Simultaneous shares with incompatible step boundaries can use four linear
keyframes only when their chosen Studio periods are equal. Automatic follows
the chosen period. For that simplification, each share is checked against
its native timeline every 20 ms over one native or Studio cycle, whichever
is longer, and at native boundaries, both at startup and while looping.
A maximum error of 24/255 per
channel is allowed. `what_plays` names each simplified animation and any
change from its native cycle to the Studio period. Above that limit, or with
different Studio periods, the animations take turns through the reported
fallback. Programs that exceed 512 bytes or 20 lines also use the reported
fallback. Solo programs keep their original timing and shape.

`colors.provider_animation` also takes `ripple` and `pendulum`. OpenCode
plays `pendulum` at 2.2 s (Effect Studio's Pendulum default) when it has no motion of its own; choosing
Automatic for it is stored as `"auto"`, the one provider-animation value
that is ever written as a word.

## Firmware updates

A person updates a SidePulse's firmware from Settings › Devices & Lighting (a
"Download and update" button and a confirmation sheet) or with
`jrbar firmware upgrade`. It is the vendor's procedure, run by JR-Bar and
watched: copy the model's `FIRMWARE.BIN` alone to the top of the device's
drive, leave the device untouched for at least ten seconds, and read
`STATUS.TXT` again. The device applies the file only from a complete valid
image, so a failure at any step leaves it on its old firmware.

**Nothing leaves the Mac by itself.** The app pins every release it knows
(`device_firmware.RELEASES`): the host, the path, the zip's SHA-256, the image's
SHA-256, size and header. "Is there an update" is answered offline by comparing
what the device reports with that table; there is no check for news, no timer
and no request at launch. The one request is a single `GET` for the package, to
`raw.githubusercontent.com` over https, made only inside `firmware_update` (or
`jrbar firmware upgrade --yes`) when the verified package is not already cached
under `~/.local/state/jrbar/firmware/` (private files) and no `package` file was
named. No redirect is followed and no other host is contacted; the body is
capped at 1 MiB and 45 s. The bytes are checked against the pinned zip hash
before the zip is opened, then each member name is validated (the four
expected files, no `..`, no absolute path, no link, no encryption, size caps),
then `FIRMWARE.BIN` is checked against its own pinned hash, size and header
(`SDUP` for a Pro, `UF2` for a Dot). A package that fails any step is never
used and never cached.

**Job document** (`state.firmware`, `firmware_status.job`, `firmware_update.job`):
`{id, device, model, name, serial, from_version, to_version, phase,
phase_label, outcome, code, message, what_to_do, source, started_at,
phase_started_at, updated_at, finished_at, download, removed_sidecars,
new_slot, previous_firmware, colour_check, restarted}`.

- `phase` runs `checking`, `downloading` (skipped for a cached or named
  package), `verifying`, `preparing`, `copying`, `restarting`, `confirming`,
  `done`. `phase_label` is the sentence the app shows.
- `outcome` is null while it runs, then `updated` (the device itself reports
  the new version), `failed` (the device is on its old firmware or an
  unexpected one; `code` and `what_to_do` say which and what to do) or
  `unconfirmed` (the device's drive did not come back within two minutes: the
  honest "check the device and reconnect", never a success).
- `code` on a failure is a `PackageError` code (`bad_hash`, `too_large`,
  `bad_member`, `bad_zip`, `wrong_model`, `bad_header`, `bad_size`, `network`,
  `timeout`, `http_error`, `redirected`, `unreadable`), a drive code
  (`drive_full`, `no_space`, `no_room`, `copy_failed`), or `device_changed`,
  `not_applied`, `unexpected_version`, `no_return`, `internal`.
- `source` is `download`, `cache` or `file`. `download` is `{bytes, total}`
  while downloading, else null.
- `previous_firmware` is `{version, slot, valid, firmware}` after a Pro
  update whose own status shows the old image still valid in the other slot
  (the Pro keeps both: the old firmware is in slot A when B is now active);
  null otherwise. JR-Bar writes no rollback: the vendor documents none.
- `colour_check` is true when the update crossed Pro 1.1.0, whose firmware
  applies its own colour gains, so the app can suggest re-checking colour
  calibration.
- `removed_sidecars` lists the macOS `._` files removed from the drive.

**What runs, in order.** `checking`: the device is read past the host's cache
(`mmap` + `msync(MS_INVALIDATE)` + `pread`) and refused unless it names one
model, its serial prefix agrees (`SPP-` Pro, `SPD-` Dot), its slot or build is
known, it is not mid-update, it runs an older release than the catalog's, no
other update is running, and the Mac is not on battery below 30%. `preparing`:
from here every write to that device's drive (and its linked partner's) is held
(`firmware_hold`): the LED writer, the keepalive and the hardware worker wait.
The root directory of these drives holds 16 entries, a long name or a macOS
`._` sidecar takes two or three, and a plain copy of the Pro's image failed with
"No space left on device" at 92% free for exactly that reason, so JR-Bar counts
the entries and removes only `._` files it has read and found to be sidecars
(empty, AppleDouble, or blanked), never a device file, and refuses with the
names in the way if there is still no room. `copying`: a streamed write (no
extended attributes) of `FIRMWARE.BIN`, replacing one that is there (the Dot's
drive always shows a fixed `FIRMWARE.BIN`, so its presence proves nothing), then
a flush. `restarting`: wait at least ten seconds, then up to 120 s in all for the
drive (possibly under a new name, found by its serial) to answer.
`confirming`: only the `release_version` (Pro) or `app_version` (Dot) the device
itself reports counts. Then the `._FIRMWARE.BIN` sidecar macOS made is removed
and the hold ends. The hold also ends on any failure and after a hard deadline
whatever happens, and the LED program is rewritten once the device is back.

## Versioning

`v` is bumped only for incompatible changes. Additive fields are always
allowed; the app ignores unknown keys, the daemon ignores unknown command
args.

## Usage windows: applicability, and the three states of a reading

Added 2026-09-10 after a Pro account's Codex row carried a permanent red
"5-hour · 100%" for a window that plan does not have.

### `usage.providers[].account`

```json
"account": {"plan": "pro", "label": "d3a51c1c-…", "fidelity": "official"}
```

`plan` is the provider's own word for the subscription, never inferred from
which windows arrived. Which windows an account *has* follows from its plan,
so the plan is carried as a fact and applicability is derived from it rather
than guessed backwards. The block appears as soon as either half is known;
`plan` is `null` when no first-party source stated one.

| provider | where `plan` comes from |
| --- | --- |
| `codex` | `rateLimits.planType` from `codex app-server`'s `account/rateLimits/read`, else a rollout's `plan_type`, else the `chatgpt_plan_type` claim in `~/.codex/auth.json`'s `id_token` |
| `claude` | `oauthAccount`'s tier words in `~/.claude.json` (`userRateLimitTier`, `organizationRateLimitTier`, `seatTier`, `organizationType`), rendered as Claude's own UI renders them ("Pro", "Max 5x", "Max 20x"). The usage endpoint states no plan at all. |
| `cursor` | `account.membershipType` when the payload carries it |
| `devin`, `grok`, `antigravity` | a `plan` / `planName` / `tier` string when the payload carries one; otherwise `null` |
| `openai-api` | not applicable — an API key has no consumer plan |

### Three states, never two

A window can be in exactly one of three states, and they reach the app as
three different values in `usage.providers[].windows[]`:

| state | what it means | on the wire |
| --- | --- | --- |
| **absent** | this account's plan has no such window | **no entry at all** in `windows[]` |
| **unknown** | the window exists and the provider stated no number | an entry whose `used_pct` is `null` |
| **exhausted** | the window exists and is spent | an entry whose `used_pct` is `100` |

Absence is something providers state explicitly, and it must be read as a
statement rather than as a zero. Codex writes `"secondary": null`; Claude
writes `"seven_day_opus": null`. Neither is "0 % remaining".

`used_pct: null` must never render as a full bar — nor as an empty one. A
consumer that needs a number for layout should treat `null` as "no reading"
and draw the window and its `resets_at` without a balance — the same thing
the capacity plane calls `ObservationState.NULL`. The app decodes it as
`CoreUsageWindow.usedPct == nil` and prints `—` (never `0%`, never blank):
the panel bar and the Usage Center ring are drawn dashed rather than filled,
the forecast reads "No reading for the 7d window" instead of promising room,
the menu-bar meter marks that column with a dash across its track, and no
sample from an unmeasured window enters any pace.

A percentage key holding a **malformed** value (`NaN`, a bool, a string) is
dropped rather than read as unknown: it is not the provider saying "no
reading", and dropping it is also what lets an aliased key fall through to
its live sibling.

### Codex limit families

Codex reports several limit **families** side by side, and every family uses
the same `primary` / `secondary` key names:

```json
{"rateLimits": {"limitId": "codex", "limitName": null,
                "primary": {"usedPercent": 100, "windowDurationMins": 10080,
                            "resetsAt": 1789440279},
                "secondary": null, "planType": "pro"},
 "rateLimitsByLimitId": {
   "codex": {…the same…},
   "codex_bengalfox": {"limitId": "codex_bengalfox",
                       "limitName": "GPT-5.3-Codex-Spark",
                       "primary":   {"usedPercent": 100, "windowDurationMins": 300,
                                     "resetsAt": 1789078256},
                       "secondary": {"usedPercent": 85, "windowDurationMins": 10080,
                                     "resetsAt": 1789501977}}}}
```

Only `limitId: "codex"` names the **account's** windows. Everything else —
`codex_bengalfox`, `premium`, anything under `additional_rate_limits[]` — is
a model- or product-scoped sub-cap. Two rules follow:

1. **A window's horizon is its stated duration, not its key.** 240–360
   minutes is the 5-hour window, 10000–10200 is the weekly one. A `primary`
   carrying 10,080 minutes is the weekly ceiling under a renamed key.
2. **A sub-cap never claims an account lane.** It gets its own dynamic lane
   named after the product (`spark-five-hour` → "Spark 5-hour",
   `spark-weekly` → "Spark Weekly"), `bindable: false`, with `model` set.

A rollout file carries exactly one family per record, tagged `limit_id` /
`limit_name`. Reading a Spark rollout's 300-minute `primary` as the account's
5-hour ceiling is what produced the phantom row: an account whose plan has no
5-hour window at all showed one, permanently at 100 %, because the lane it
named never existed and so never moved.

When a live `codex app-server` read is available it enumerates every family
the account has, so for the families it covered it is the whole truth —
including which windows a family does **not** have. Rollout windows for those
families are discarded rather than merged; only families the live read did
not cover fall back to rollout evidence.

Menu bar item shortcuts are app-owned preferences in
`MenuBarSettings.itemHotkeyBindings`. The app resolves and presses the selected
Accessibility item after a person presses its shortcut. These bindings are not
core facts or daemon commands and do not require a Python settings migration.


### Kiro CLI-owned allowances

Kiro usage starts disabled and requires per-provider usage consent. The
collector reads the default Kiro CLI account only. It opens the CLI-owned
SQLite database read-only, using `KIRO_DATA_DIR/data.sqlite3` when that
absolute directory is configured, otherwise
`~/Library/Application Support/kiro-cli/data.sqlite3`. It reads the existing
access token and profile ARN, never saves a Keychain key, refreshes the
token, or invokes a chat command. Named instances cannot borrow this CLI
account and return `unsupported`.

The profile selects one of two fixed regional `GetUsageLimits` endpoints:
`codewhisperer.us-east-1.amazonaws.com` or `q.eu-central-1.amazonaws.com`.
The consent disclosure names both hosts and the access token and profile
ARN sent to them. No credential read or request occurs before consent.
Monthly plan credits and enabled, capped overage credits are separate
lanes. Reset timestamps must be reported Unix seconds. A non-empty bonus
list makes plan spend ambiguous, so that response supplies no monthly or
trial lane. If no separable allowance remains, the snapshot is
`unsupported` with reason `no_separable_quota`. This API path does not
establish complete CLI trial or bonus usage parity.

An explicit `provider_sign_in` action can open the resolved `kiro-cli`
executable with the fixed `login` argument in the person's terminal. The
CLI owns that interactive sign-in. Kiro has no configured updater or
proven automatic sign-in watcher. After finishing login, the person
refreshes the usage card, which reads the new CLI state through the same
consent gate. Background collection never invokes `kiro-cli login`.

### Sweep parameters

Provider animations `kitt`, `scanner` and `pendulum` use catalog version 2.
Their `background_glow` number ranges from 0 to 100, in percent, and defaults
to 0. It sets the resting colour relative to the moving head's peak. The
provider assignment stores it with the other animation parameters. This
background is independent of the global working-state fade floor.

### Token history index

`token_history_enabled` is a boolean setting, default true. False cancels
startup warming and subsequent scan passes. It refuses `usage_history`,
`usage_graph` with `disabled`. Session tokens and context occupancy stay on.
Codex quota percentages still read bounded rollout tails without indexing tokens.
History reads use a private SQLite index, shared across ranges and clients.
Unchanged transcripts require only a stat check. Appends resume a guarded
byte offset for Claude and Codex. Other adapters replace changed files.
Rewrites replace that file's contributions. Parser version,
source identity changes rebuild the index. Schema v7 interns provider,
session and model IDs, stores each fact once, and maintains additive UTC
quarter-hour totals. Local timezone changes affect reads and write nothing. Removed and
rotated files retract their contributions after a complete inventory walk.
Global deduplication includes copied Claude messages and admitted Codex fork
lineage. Files and rows older than 368 days are skipped or pruned. Newest
files are read first. Reconciliation checkpoints survive a pass budget.

Provider rows may include `token_history_state`: `ready`, `stale`, `building`,
`failed`, `disk_full`, `damaged` or `over_cap`. This describes local token
totals independently of quota-window freshness. A short scan does not mark
current data stale. Cards retain the last index reading when busy. Retired
JSON scan caches are never a fallback. Each provider's caches are removed
when that provider finishes indexing. The daemon cannot use legacy graph
capture or the legacy controller's transcript writer.

Cold and full rebuilds run in a separate Utility process. It commits source
offsets about every 50,000 records, reports committed progress, and exits.
Disabling history or quitting stops the child. The daemon retains a 6 MiB
SQLite writer cache and runs small incremental passes at its default QoS,
with a 50 ms CPU allowance. SQLite temporary tables use disk. Reconciliation
commits completed chunks when the allowance expires.

One damaged database and its sidecars are retained until the next damage
replaces them. Recovery waits a minute. A file over the configured size cap
is not quarantined as damage. Disk-full failures back off for an hour.

Token-history rows and `session_usage` publish `processed_tokens` separately from
`estimated_cost_usd`. `processed_tokens` includes input, cache reads, cache
writes and output. It is a work count, never context occupancy or quota
percentage. Context occupancy remains `context_tokens` and `context_window` in
`session_usage`. Quota percentages remain provider window readings. `cost_usd` remains the compatible
alias for approximate API-equivalent dollars, never subscription spend.

### Observed Focus

`state.focus.observed_active` is the observed macOS Focus activity, independent
of JR-Bar's quiet policy and `focus_sync_enabled`. It is `true`, `false`, or
`null` when no observation is available. `observed_identifiers` contains the
active mode identifiers already observed for named Focus/profile rules, or an
empty array when names are unavailable. Quiet `mode` and `source` retain their
existing meaning. Clients must not infer observed activity from those fields.

Publishing these fields performs no filesystem reads. It reuses the daemon's
public Focus status, fresh app presence hint, and existing named-rule observations.
The app never opens the protected Focus database. Its announcement watcher also
reads the public Focus Status API on a bounded background worker, independent of
Focus sync. A new observation updates activity; an unavailable source keeps the
other source's reading. An unknown observation does not announce Focus off. Identifier changes while active announce the new mode.

### Optional feature lifecycle

`settings.document.presence_enabled` is a boolean, default true. Off stops
the app's microphone and camera presence reporting and its renewal work.
Privacy dots use the same gate. The presence reporter polls Focus only
while connected with `focus_sync_enabled` on. Notch announcements keep
their own watcher gate. Neither switch grants system permission.

Each physical `settings.document.devices` row has `enabled`, a boolean
defaulting to true for existing devices. Settings shows it as "Use this
device". Off stops inventory reads and LED writes for that device. The
Screen Bar keeps its existing `virtual_status_device_enabled` gate.

A provider with Track off or usage consent off schedules no collection
job and reads no local quota or credential source. Turning it on starts a
fresh collection. Disabled ambient cues do not run their observers or
planners. Turning phone alerts off cancels queued and active deliveries.
