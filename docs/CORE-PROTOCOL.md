# JR-Bar core protocol (protocol 1)

The native app (`JR-Bar.app`, Swift) owns every pixel. The core daemon
(`python -m jrbar core`, the production controller run headless) owns every
fact: provider hooks, session truth, usage and quota, device writers,
escalation decisions, power holds, remote peers, cloud ingest. They talk
over one Unix socket.

This document is the contract, written to what the daemon does today.
Both sides are tested against it: `tests/test_core_server.py`,
`tests/test_core_projection.py`, `tests/test_core_runtime.py` on the
Python side; `app/Tests/JRBarCoreTests` on the Swift side, including
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
  oversize inbound frame closes that client.
- Clients: up to 4 at once; the fifth is refused.
- Lifecycle: the app launches the daemon as a child when `JRBAR_CORE_EXEC`
  is set (`CoreSupervisor`), otherwise it connects to whatever listens.
  The daemon refuses to start (exit 2) while another JR-Bar, the old
  Python status bar included, owns the hook event socket. A supervised
  daemon (`JRBAR_SUPERVISED=1`) exits on its own when its parent is gone.
  On connect the daemon sends `hello`, then the latest full `state`,
  `lights` and `settings`. After that it pushes documents as they change.
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
  client whose sends keep blocking is dropped outright — but events stay
  replayable from the journal (512 entries, larger than the queue on
  purpose) until it evicts them, after which `replay_events` says so
  (`cursor_expired`, with the `dropped` count) instead of pretending.

## Daemon → app

### hello
```json
{"t":"hello","v":1,"core_version":"0.8.0","pid":123,
 "capabilities":["sessions","lights","usage","devices","power","effects","calibration","history","peers","ingest","deck","roster","event_replay"],
 "stream":"1234-abc123","cursor":"1234-abc123:ev-42"}
```
`stream` identifies this daemon incarnation's event journal (pid +
start epoch); `cursor` is its current tail — the position a fresh
client anchors at. A reconnecting client that sees the SAME `stream`
may ask `replay_events` with the last `cursor` it saw to recover the
frames the drop ate. A different `stream` means the journal restarted:
anchor at the new `cursor`, never replay. The journal is bounded
(512 entries) and in-memory by design — replay survives socket churn,
not a daemon restart.

### state (full)
Sent on connect, at the end of every controller refresh (a 15 s timer plus
every hook event), on DND changes, on escalation stage changes, when a
client connects, and after every command that changes the world. The app
replaces its model wholesale; there is no partial state message in
protocol 1. Timestamps are Unix epoch seconds.

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
    "workers":1,"snoozed_until":null,"event":"PreToolUse","tool":"Bash","message":null}
 ],
 "hidden_count":3,
 "asks":[{"session":"codex:session:…","kind":"permission","opened_at":1788982800.0,"summary":"Run: rm -rf build",
          "answerable":true,"replyable":false,"request":"request:v1:{…}",
          "decision":{"hold_until":1788982845.0,"always":false,"decided":false,"choices":[]},
          "preview":"rm -rf build","risk":"destructive"}],
 "devices":[{"id":"sidepulse:pro:B293A1","kind":"pro","name":"SidePulse","path":"/Volumes/SidePulse","leds":8,"connected":true,"brightness":79,"linked":true,"last_write":1788982891.31,"error":null},
            {"id":"sidepulse:dot:7F02C4","kind":"dot","leds":2,"connected":false,"error":"volume unmounted"},
            {"id":"screen-bar","kind":"screen_bar","name":"Screen Bar","leds":8,"enabled":true,"brightness":100,"linked":true,"error":null}],
 "usage":{"refreshed_at":…,"next_refresh_at":…,"refreshing":false,
          "providers":[{"id":"claude","instance":"default","account":{"plan":null,"label":"Max","fidelity":"official"},
                        "windows":[{"name":"5h","id":"five_hour","used_pct":42.0,"resets_at":…,"scope":"account","model":null},
                                   {"name":"7d","id":"seven_day","used_pct":61.0,"resets_at":…}],
                        "fidelity":"official","state":"ready","reason":null,"action":null,"observed_at":…,
                        "tokens":{"input":1200,"cached_input":800,"output":300},"estimated_cost_usd":null,"credits_remaining":null,
                        "forecast":{"window_id":"five_hour","remaining_pct":58.0,"exhausts_at":1789000292.4,"pace":"under","rate_pct_per_hour":12.0,"samples":13}}]},
 "power":{"keep_awake":true,"closed_lid":{"policy":"agents","holding":false,"helper_installed":true}},
 "focus":{"mode":"dim","source":"schedule","until":…,"display":"all","brightness_factor":0.15,"banner_allowed":true,"audible_allowed":false,"summary":"Dim until 07:00"},
 "escalation":{"stage":"menu_bar","since":1788982800.0},
 "health":{"hooks":{"claude":"ok","codex":"stale","pi":"missing"},
           "detected":{"claude":true,"codex":true,"pi":false},
           "sources":{"claude":{"fresh":true,"heard_age_seconds":1.4}},
           "intake":{"hook_state":"configured","source_health":"partial","silence_seconds":1.4}},
 "peers":[],
 "unseen_completions":["gemini:session:…"],
 "settings_generation":17,
 "catalog_generation":42,
 "deck":{…}}
```

Vocabulary:

- `sessions[].id` is the existing agent id: `provider:session:<sid>` for a
  main session, `provider:agent:<id>` for a worker (`kind: "worker"`,
  `parent` = the main session's id). `label` is human: the provider's own
  session title when it has one (Claude's `name` from
  `~/.claude/sessions/<pid>.json`, Codex's `thread_name` from
  `~/.codex/session_index.jsonl`), else the collector's derived name with
  its short id stripped (project / first prompt), else the working
  directory's last path component, else `<Provider> <short id>`; a
  worker is `<parent label> worker <short id>`. `short_id` is the first 8
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

  **Liveness beats silence: a session whose process is alive never reads
  `ended`.** `ended_unconfirmed` is what the collector says when a working
  session stops sending hooks past its window (`WORKING_SILENCE_SECONDS`,
  four minutes; `POST_TOOL_WORKING_VISIBLE_SECONDS`, two, after a
  `PostToolUse`) -- "probably over, nobody said so", which was the best
  guess available when a silence timer was the only evidence there was. It
  is not any more: the liveness sweep reads the process table every five
  seconds, and when it can point at the agent's own process the session is
  not over. A long tool run legitimately says nothing for many minutes, and
  such a row reads exactly what it is -- `mode: "working"`,
  `lifecycle: "active"` (or `"stale"` once its information is old enough
  for the collector to say so), never `ended` and never `completed`, since
  being alive is not a finish. `since` carries how long it has been quiet.
  Nor is it `stale`: `stale` means "the source stopped delivering and
  nobody can vouch for this row", and the registry just did. That matters
  three times over -- a stale row is dropped from `sessions` ten quiet
  minutes after its last event, is not counted in `active`, and is offered
  to `clear_completed` -- so the header, the strip and the Dot keep showing
  work that is still happening, and the row stays listed for as long as the
  tool run takes. Finished, failed and idle modes keep their own clocks: a
  terminal left open does not pin a Done row on screen for ever. The
  evidence is affirmative only: no registry record, no readable process
  table, or a reused pid all leave the silence rule exactly as it was, so a
  session whose process is gone and which never sent a terminal event still
  reads `ended`.

  `next_actor` comes from canonical operator state (`user`, `provider`)
  with a mode-based fallback. `snoozed_until` is the mailbox's active
  snooze epoch for this session (a family `snooze` covers the family, not
  the row; a `scope: "run"` snooze covers this row alone; the later
  deadline wins), null while none is in effect -- the panel reads it to
  say "Snoozed until…" and to offer Unsnooze.
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
- `ask.decision` is non-null while the decide lane holds the request: the
  agent's own `PermissionRequest` hook ran as `jrbar-hook --decide` and is
  waiting on JR-Bar for a verdict (see "The decide lane" under
  `answer_ask`). Such an ask is `answerable` whatever hosts the session --
  Ghostty, an IDE panel, a headless run -- because an answer is the hook's
  own reply and nothing is typed. `hold_until` is the epoch at which the
  hold lapses and the agent's own prompt carries on; `always` says an
  Always allow can be sent (Claude, when its `permission_suggestions`
  carry an allow rule); `decided` is true for the few seconds after an
  answer, while the provider's events catch up. A hold that lapses, is let
  go or is answered republishes `state` at once, not at the next refresh.
  `preview` is one bounded
  line of what the agent wants to run (the command, the file, the URL,
  `server · tool` for MCP; token-shaped runs masked) and `risk` is
  `"destructive"` when a shell command matches a pattern that loses work
  if it runs by mistake (`rm -r`, `sudo`, a forced push, `reset --hard`,
  `curl … | sh`, …) -- a mark, never a block. `decision` is `null` for an
  ask the lane does not hold; `preview` and `risk` still come from the
  `PermissionRequest` the ingress saw for that exact request id (Claude,
  Codex, Devin, Grok, OpenCode, pi; remembered for an hour), and are `null`
  when there was none.
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
- Device ids are the Python device ids; the Screen Bar row is `screen-bar`
  with `enabled` (the Python `virtual_status_device_enabled` setting).
  Hardware `brightness` is the effective percent after idle/DND dimming.
  `linked` follows the row's `kind`, because two different mechanisms
  share the word: on `screen_bar` it is `link_screen_bar_to_hardware`
  (the bar plays the strip's program); on `pro` and `dot` it is the
  `devices_linked` pairing — true only while the setting is on AND one
  of each is actually connected, so a Dot with no strip never claims to
  be linked.
- `usage.providers[].windows[].name` is the short form the panel shows:
  `5h`, `7d`, `Daily`, `Weekly`, `Monthly`, `Credits` (a model-scoped lane
  such as Claude's Fable window is `7d Fable`; a lane with no short form
  keeps its label); `id` is the lane id (`five-hour`, `weekly`,
  `fable-only`, …). `used_pct` is `100 - remaining_percent` from the
  provider usage lanes; `resets_at` is the lane's reset epoch whenever the
  lane knows it; `bindable` is false for a lane the provider's own catalog
  does not know — evidence only, never an applicable constraint;
  `fidelity` is `stale` when the source is stale, else
  `official`; `state` is the `ProviderSourceState` value.
- `usage.providers[].constrained` is the window the daemon says is worth
  watching — not the name convention but the least headroom among the
  `bindable` windows that were actually measured: `{id, name, used_pct,
  resets_at, reason, candidates}`, where `reason` is `only_measured` or
  `least_headroom` and `candidates` is how many windows were eligible.
  Null when nothing applicable was measured. The app's card leads with
  this window and explains the pick when it departs from the `5h`
  convention; an unclassified lane cannot win it even at 1 % left.
- `usage.providers[].quota_source` is whether a quota collector exists for
  the provider at all (read off `provider_usage_platform`'s descriptors,
  not the snapshot's claims), so a "show meters" control can hide instead
  of drawing dead.
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
- `focus` is the quiet state in the words a client reads: `mode` is the
  active quiet mode (`mute`, `dim`, `pause`, `asks_only`, `dark`) or the
  literal `off` -- never null -- while nothing quiet is in effect.
  `source` is `override` (a `quiet` command's manual override),
  `schedule`, `focus` (a macOS or named Focus), or null under `off`.
  `until` is when *this* quiet ends: the override's own expiry for a
  manual quiet, the schedule interval's end for a scheduled or Focus
  quiet, and null while nothing is in effect -- a merely upcoming quiet
  period never surfaces as an end time.
- `escalation.stage`: `none`, `ramp`, `menu_bar`, `final` (0…3);
  `since` is when the oldest unanswered ask started blocking.
- `power` says why the Mac is (or is not) held awake. `keep_awake` is true
  while anybody wants it awake -- the agents (working, or in the grace
  after) or the person's lease -- and nothing has made the holds yield.
  `hold` is the one keep-awake hold: `state` is `off`, `agents` (the
  agents hold it; `agents` counts the main sessions working) or `manual`
  (a lease is in force; `lease` is `{kind: duration|agents|indefinite,
  started_at, until, sessions[], display, source}`, `until` being the
  countdown's end for `duration` and the backstop for `agents`); `active`
  is whether the assertion is actually held right now; `display` whether
  the screen is held too; `grace_until` the end of the post-work grace
  while the agents' hold is in it; `suspended` names a yield that took the
  hold away while the demand stands -- `thermal` (the thermal state
  reached `serious` with the lid shut or `critical` with it open, released
  until five cool minutes pass) or `battery` (the low-battery floor);
  `thermal` is `nominal`/`fair`/`serious`/`critical` or null.
  `closed_lid` adds `lid_closed` (the daemon's last reading, null while it
  has none or while nothing watches the lid -- the lid is polled only
  under a closed-lid policy, a hold or a lid animation, and a reading the
  poll no longer keeps is not reported), `sleeps_on_release` (the daemon asks for sleep -- an
  unprivileged `pmset sleepnow` -- when the closed-lid hold drops with the
  lid shut and `AppleClamshellCausesSleep` says no external display is
  keeping clamshell mode; heat and the battery floor release even the
  `always` policy), `last_sleep_at` and `sleep_error`. `last_release` is
  the newest release worth reading, `{kind, reason, at, duration,
  finished, slept_at}`: `kind` `lease_ended` (`reason`
  `expired`/`finished`), `suspended` (`thermal`/`battery`),
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
  cannot see); null until it has tried.
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
  can say "not installed" instead of implying a dead hook.
- `catalog_generation` is the effect catalog's content-derived generation
  (the same derivation as `list_effects`' `generation`): it moves when the
  registry, installed packs or assignments change, so a client can decide
  to reload its catalog without reconnecting. Absent until the catalog has
  been built once.

#### The Creator Micro 2 deck (`state.deck`)

The pad as the daemon drives it, built by `core_deck.build_deck_document`
from the session board (`deck_session_board.py`), `deck-controls.json`,
`integrations.json`, a background HID enumerate every 10 s, the output
service's receipts and the private keymap backup. Always present; every
field is one the Control Center and the Rail decode.

```json
"deck":{
 "device":{"serial":"D0CF130481EC","name":"Creator Micro 2","transport":"bluetooth","connected":true,"approved":true,
           "firmware":null,"layer":0,"profile":0,"conflict":null,
           "receipt":{"code":"ready","message":"Creator Micro 2 ready.","at":1788982862.4}},
 "slots":[{"index":0,"identity":"<sha256 of the work key>","session":"codex:session:…","label":"sidepulse-core","provider":"codex",
           "state":"input_required","pinned":true,"navigable":true,"color":"#FF3A00"}, …13 rows…],
 "aux":[{"index":13,"label":"Encoder 1 input 1","mapping":"previous_bank"}, …AG13..AG19…],
 "scope":"automatic","scopes":["codex","claude"],
 "banks":{"index":0,"count":1},
 "rail":{"edge":"left"},
 "keymap":{"state":"applied","backup_at":1788896492.4,"generation":3,
           "layers":[{"profile":0,"layer":0,"label":"Profile 1 / Layer 1: Base","scope":"automatic"}]},
 "input_check":false,
 "last_input":{"index":1,"kind":"press","at":1788982888.4},
 "settings":{"enabled":true,"session_mode":true,"analog_enabled":false,
             "bindings":[],"layer_map":[{"layer":1,"scope":"codex"},{"layer":2,"scope":"claude"}],"scopes":[]}}
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
  backed-up) keymap, each with the `scope` the layer map assigns it.
- `input_check`: inputs are shown as `deck_input` events and every
  bound action is paused (also turned on by a verified keymap write, as
  the Python app did). `last_input` is the last observed control
  (`kind`: `press` for a key, `dial` for AG13..15, `joystick` for
  AG16..19, `analog` for the calibrated sectors 20..23).
- `settings` mirrors `deck-controls.json` (`enabled`, `session_mode`,
  `analog_enabled`, the explicit aux `bindings`, the `layer_map` from
  hardware layer to board scope, and extra `scopes`; the Python defaults
  are all off, with layers 1 and 2 mapped to `codex` and `claude` on a
  fresh install).

### lights
The presentation program for each surface, exactly the LEDS DSL text the
hardware receives, plus the anchor the app needs to phase-lock the Screen
Bar to the strip. Sent whenever a program changes on any surface (every
Screen Bar sync, every completed hardware write, every preview start and
end) and with every refresh.

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
  the program the Python Screen Bar would draw (calibration and resting
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
  (`core_runtime.screen_bar_anchor`). `screen_bar_phase_offset_ms`
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
  | `phase_error_ms` | how far the Dot's phase is from the strip's right now, ms, signed (positive: the Dot is ahead); predicted between fresh reads from the Dot's measured clock; null before the first timed Dot write |
  | `clock_rate` | the rate the Dot's program is written for, in Dot-ms per real ms (0.9734: 2.66% slow); 1.0 with clock correction off |
  | `clock_source` | `measured`, `warm` (the saved rate or the 0.9734 warm start), `frozen` (fresh reads stopped moving; re-anchored blind every 60 s) or `off` |
  | `tolerance_ms` | `linked_sync_tolerance_ms` in effect |
  | `last_sync_at` | epoch of the last timed Dot write |
  | `sync_writes_hour` | Dot-only re-anchors in the last hour |
  | `rotation` | how the last Dot write was rotated: `exact`, `snapped` (at a line boundary, to fit the 512-byte budget) or `unrotated` |
  | `check_until` | while Check sync runs, when it ends (epoch); null otherwise |
  | `style` / `rung` | `dot_extend_style`, and the period lock's rung: `brightest`, `average`, `soft`, `static` or `continue` |

- `device_receipts` (additive, 2026-09-24; absent when empty) is keyed by
  device id: `{foreign_write_at, foreign_writes, paused}`. At the reassert
  cadence (never faster) the daemon reads the device's `LEDS.LED` past the
  host's cache and compares it with what it last wrote; a mismatch is
  another writer (upstream's app, a shell `echo`). The first is written
  over at that reassert and noted here; a second inside ten minutes sets
  `paused` and the daemon stops rewriting that device until its own next
  change, so two apps never fight over the flash.
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
`escalation_stage` 3.
```json
{"t":"event","v":1,"id":"ev-12","kind":"completed","session":"…","provider":"claude","label":"jr-bar-b7","detail":null,"at":…,"cursor":"1234-abc123:ev-12"}
{"t":"event","v":1,"id":"ev-13","kind":"escalation_stage","session":"…","label":"sidepulse-core","stage":3,"sound":"glass","at":…,"cursor":"1234-abc123:ev-13"}
```
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
`range`, `records`, `scanned_at`; `label` is the provider, `detail` the
range: a `usage_history` reply that went out `pending` or `stale` now has
a fresh document behind it, ask again); `quota_reset` (`provider`,
`instance`, `label` such as "Weekly reset", `lane`: the usage lane that
refilled, `weekly` / `five-hour` / a product-scoped id ending in
`-weekly`; published on every detected reset regardless of the
celebration preferences, so the Usage Center can pulse the card and the
Confetti toy can fire on the weekly one); `quota_pace` (`provider`,
`lane`, `label` the lane's name, `remaining_percent`, `runs_out_at` and
`resets_at` as epochs, and `detail` in words, "30% left · runs out around
3:40 PM · resets 5:30 PM"; once per reset window, when a lane is newly
projected to run out before it resets, only while `quota_alerts_enabled`
is on and the courtesy and quiet gates let it through: the daemon's own
banner posts nothing headless, so the app's `EventPolicy` banners this
and History lists it); `peer_arrived` / `peer_departed`
(`label` is the machine name; the reachable-set diff after the first
applied refresh, never on daemon start).
`open_window` (`window`: `overview`, `usage` or `control-center`) and
`reveal_ask` go out when a Creator Micro key asks for one of the app's
windows or for the waiting ask, and only while an app is connected; with
none, the key's receipt is `app_not_connected`. The app runs them through
its command router the way it runs a `jrbar://` link and drops one older
than 10 s. Revealing an ask puts it on the panel; it never answers it.
`power` goes out once per power-log entry worth a line: `power` is the
entry's kind (`lease_ended`, `suspended`, `lid_hold_ended`, `slept`),
`detail` its reason (`expired`, `finished`, `thermal`, `battery`,
`agents_idle`, `policy`), `label` History's words for it ("Keep awake let
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

- `menu_bar_icon_style`: `glyph` (default), `glyph_ring`, `glyph_label`.
  The status item's picture is the app's; the daemon only keeps the
  choice. An unknown value normalises to `glyph`.
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

```json
{"t":"settings","v":1,"generation":17,"schema":3,"document":{…}}
```

Legacy-only settings: the daemon still loads, normalises and re-emits
each of these, but only the deprecated Python settings window ever
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
- `global_action_shortcuts`: persisted chords for the global actions.
- `studio_program`: the hand-written Studio LED program, kept verbatim.
- `studio_library`: the named Studio programs shelf.
- `notification_policy_version`: which notification-policy migration
  has already run.
- `screen_bar_gauges_enabled`: the Screen Bar's wing-tip micro-gauges.
- `screen_bar_bracket_style`: how the Alcove bracket colours itself
  (`auto`/`spatial`/`identity`).
- `virtual_status_device_wraps_menu_bar`: extends the Screen Bar's glow
  past the notch toward the menu bar's edges -- the app reads it, no
  control yet.

### reply
Answer to a command.
```json
{"t":"reply","v":1,"id":"c-42","ok":true,"result":{…}}
{"t":"reply","v":1,"id":"c-43","ok":false,"error":{"code":"not_found","message":"no such session"}}
```
Error codes: `unknown_command`, `bad_frame`, `bad_command`, `internal`,
`not_found`, `not_frontmost`, `invalid_args`, `invalid_path`,
`invalid_value`, `read_only`, `refused`, `expired`, `busy`, `unsupported`;
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
`unsupported_file_protocol`, `setup_failed`, …) whose `message` is the
Python app's sentence for that receipt.

### log
Content-free diagnostics for the app's log view: every `log_status_bar`
line the controller writes, mirrored. Bounded to 2000 characters a line.
```json
{"t":"log","v":1,"level":"info","message":"leds=SidePulse Ask target=/Volumes/SidePulse/LEDS.LED","at":…}
```

## App → daemon

### command
```json
{"t":"command","v":1,"id":"c-42","name":"open_session","args":{"session":"claude:session:…"}}
```
Commands are parsed on the socket thread and run on the AppKit main thread
(`performSelectorOnMainThread`), one at a time, in order per client --
except the slow-lane reads `usage_graph`, `usage_history`,
`session_timeline`, `list_history`, `compare_sessions`, `session_usage` and
`doctor`. Those queue on one daemon-wide worker at utility QoS, in order
among themselves (two scans never overlap), and each replies by `id` when
it is done, so a reply to a later command can arrive first and a scan never
holds up an `answer_ask`. `mark_history_seen` queues on the same lane (it
still runs on the main thread when its turn comes), so a `list_history`
sent before it computes `unseen` against the old watermark. Past 32
queued, a new one is refused `busy`.
`install_hooks` / `uninstall_hooks` run on the socket thread because the
Codex trust handshake can take seconds, and so do `open_session` and
`resume_session`, whose osascript and tmux calls can wait on a first
Automation consent prompt (the controller state they read still hops to
the main thread). Unknown args are ignored.

| name | args | effect / result |
| --- | --- | --- |
| `open_session` | session, action? | A session still running in a terminal is **raised, not resumed** (`answer_surfaces.py`): its tmux pane (`list-panes -a` matched by the session's tty, then `select-window`/`select-pane`, switching a lone client to that tmux session), its Terminal.app or iTerm2 tab (selected by tty over Apple events), or its Ghostty terminal (`focus` on the surface recorded when the session started, else the only terminal in the session's working directory, else the only one whose title carries the session's name; a tie brings Ghostty forward and never guesses); any other host app is activated. Reply `{session, activated, origin, raised: "pane"\|"tab"\|"terminal"\|"app", app, bundle_id, detail}`. Opening a Codex session also lets a request the decide lane holds for it fall through, so its prompt waiting behind the hook appears at once; a Claude hold stays, since its prompt is already on screen. A live session JR-Bar cannot find refuses `not_found` ("…still running, but JR-Bar can't find its window; nothing new was started.") instead of starting a second process on it. An ended CLI session whose open is a terminal resume resumes **in the terminal it ran in** (recorded at its SessionStart), not whichever app is in front: a new tab in Ghostty's front window at the session's directory with the resume command typed into the owner's own shell (a new window through the reviewed launch plan when Ghostty refuses the Apple event), or a new Terminal.app / iTerm2 window -- `raised: "new_tab"\|"new_window"`, `detail: "resumed"`. A remote row, a session hosted by its provider's desktop app, an explicit `action` of `app`/`vscode`, or a Clicks-open / provider-profile choice of `vscode` keeps the controller's `open_session` (provider URL, or `cd <cwd> && <cli> --resume <id>` in a terminal): `{session, activated, origin}`; a saved choice of `app` is for the sessions the app hosts, so a live session a terminal hosts is still raised. A session Claude.app runs opens as `claude://code/continue?session=local_…`, the id the app's own session store (`~/Library/Application Support/Claude/claude-code-sessions`, read-only) gives the CLI session, and lands on that session; with no match it is bare `claude://`. Automatic puts VS Code first for a Claude row only when LaunchServices has a `vscode://` handler. `action: "raise"` asks for the live path explicitly. |
| `answer_ask` | session, decision (`approve`/`deny`, or `always` for a held request that offers it, or `answer` for a held question), answers (with `answer` only: `{<question text>: <label>}` for every question in `ask.decision.choices`, a list of labels for a `multi` one), reply_text (optional, for `input` asks), request (optional — the ask's `request` identity; a live request that does not match refuses `stale_request` before anything is armed or typed), only_if_frontmost (default true) | A request the decide lane holds (`ask.decision` non-null) is answered first, through the agent's own `PermissionRequest` hook: `{session, decision, answered, delivered, code: "sent", message, confirmation: "provider_pending", mechanism: "permission_hook"}` -- see "The decide lane" below. Anything else is answered **in its own terminal** (`answer_local.py`, the `local.answer_in_place` surface the `answering` product capability binds to). A bare `decision` posts the key that provider's CLI takes at its permission prompt. Claude Code: `1` to approve ("1. Yes" is always the first row), `esc` to deny (the prompt's own "Esc to cancel"). Codex: `y` to approve ("1. Yes, proceed (y)"), `3` to deny ("3. No, and tell Codex what to do differently"). With `reply_text` (non-empty printable, normalized to one line, at most 280 chars) the action becomes `reply`: the text is typed into the same verified window via `CGEventKeyboardSetUnicodeString` and submitted with Return -- same frontmost/ancestry/tty/accessibility fences, `mechanism: "synthetic_text"`, and the reply reports `decision: "reply"` plus `characters` instead of a key. A `reply_text` on an ask whose capability does not take text is `unsupported`. Only `codex/hooks` and `claude/hooks` declare the capability; any other provider is `unsupported`. Every fence is affirmative-only: unknown liveness (`liveness_unproven`), unwalkable ancestry (`ownership_unproven`), an unresolved session tty (`session_tty_unknown`), and a terminal that cannot name its focused tab (`focused_tab_unproven` -- kitty, WezTerm, Alacritty have no such call; Ghostty proves its focused terminal by it being the surface recorded at the session's SessionStart, and a session with no recorded surface stays unproven -- the only terminal in the session's directory is not proof, since a plain shell the owner opened there looks the same) all refuse; there is no send-anyway path. The reply waits for the real outcome, so `answered: true` means the key went out: `{session, decision, answered, mechanism: "synthetic_keystroke", key, key_code, meaning, confirmation, host{pid, tty, app, app_pid, window_evidence}}`. `confirmation` is `provider_pending` on a posted key -- an attempted delivery, not a confirmed approval; the provider's own stream closing the request is the only proof it landed -- and `none` on a refusal. `window_evidence` on a sent answer is `focused_tab_tty` (the terminal named the focused tab and it is this session's) or, in Ghostty, `recorded_surface` (its focused terminal is the one the session started in, still in the session's directory). See the refusals below. |
| `snooze` | session or `all`, seconds, scope (`family`, the default, or `run`) | Mailbox snooze for the session's family (presets: ≤ 900 s → 15 minutes, ≤ 3600 s → 1 hour, else tomorrow morning; 0 unsnoozes). `{sessions, until, scope: "family"}`. `scope: "run"` ("Quiet this run") quiets that one row instead -- a main session or a single worker, on its exact work key (`snooze_scope: "run"` in `mailbox-preferences.json`), for exactly `seconds` (a week at most) -- so quieting a sub-agent never silences the session that spawned it, nor its siblings, and the family's shelf stays. It needs a named session (`all` is `invalid_args`) whose row has a work key (else `unsupported`); `seconds: 0` lifts it. `{sessions: [id], until, scope: "run"}`, `until` being whatever now quiets the row (its own deadline, or the family snooze already in force on that key, which a run snooze never replaces since that would wake the rest of the family; null when nothing does). Either way a live ask still breaks through, and the row's `snoozed_until` is the later of its family's deadline and its own. A family unsnooze of a named session (or `all`) also lifts that row's own run snooze, so Unsnooze always clears what the row shows. |
| `clear_completed` | sessions[] or `all` | Acknowledges every row `sessions` is currently listing as over -- `completed`, `ended`, and any stale row -- through the Clear Agents plan/commit machinery with widened eligibility (`clearable_presentation_key`). Afterwards `sessions` holds only live rows and the rest are in `list_history`. `sessions` may name a subset; a named row that is not clearable (a live session) is simply not in the batch. Live sessions, asks, failures and worker rows are fenced as protected and never cleared. `{batch, cleared[]}` with every acknowledged session id, or `{batch: null, cleared: []}` when nothing was over. Refuses `busy` while a clear is in flight. |
| `undo_clear` | batch | Undo that batch within its 300 s window; the rows return to `sessions` exactly as they were. `{batch, restored[]}`; `expired` after, `not_found` for another batch. |
| `set_setting` | path, value | Dot-path write (`colors.agent_colors.claude`, `devices.0.brightness`) into `to_dict()`, re-validated through the real settings loader, saved, side effects applied (closed-lid, cloud ingest, transcript monitoring, remote peers), then a refresh. `{generation, path, value}` with the value as normalised. A read-only key (`cloud_ingest_token_path`) replies `read_only`. |
| `reset_settings` | paths[] | Each path back to `AgentMonitorSettings()`'s default. `{generation, reset}`. |
| `set_brightness` | device or `all`, value 0..1 | `set_device_brightness` (turns auto-brightness off, as the slider does). |
| `set_device_display` | device, mode | `agent`, `battery`, `studio`, `quota_runway`. |
| `apply_calibration` | device, profile {red_gain, green_gain, blue_gain, resting_glow, brightness?} | Per-channel gains (0.3…1.5), resting glow (0…0.35) and device brightness (0…255) for that device, clamped and persisted; the reply's `profile` echoes what actually persisted plus `generation`. Ends any held calibration preview for the device. `not_found` for an unknown device, `invalid_args` for a non-numeric field. |
| `preview_program` | surface (`screen_bar`, `hardware`, `dot` or a device id), program, seconds (0.2…30) | Writes the program to the matching strip(s) now and marks the surface `why: preview` in `lights`; after `seconds` the daemon refreshes and the live program returns. Refused with `busy` while a held `preview_calibration` owns the surface or any target device -- a 3 s flash cannot be allowed to paint over a 10-minute calibration hold. |
| `preview_calibration` | device, gains {red, green, blue} (0.3…1.5, clamped), resting_glow? (0…0.35), brightness? (0…255, default the device's stored brightness), patch? (`white`/`red`/`green`/`blue`/`grey` or `#RRGGBB`, default `white`), companion? (default false) | Shows the nominal patch through the GIVEN values -- resting glow, channel gains and brightness applied once through the device's own write boundary, never the stored profile on top. Held daemon-side for 600 s (re-armed on every call) so the sheet can sit open while the eye decides; live writes for the held device(s) are suppressed meanwhile. For `virtual:status-bar` the transform is the Screen Bar's code-domain one and the hold lands on the `screen_bar` surface. `companion: true` on a Dot also lights the followed strip with the same patch through the strip's STORED profile, so the Dot can be matched to it by eye; the reply's `companion` names that strip (or null). `{device, surface, until, program, companion}`; `not_found`/`invalid_args` on errors. |
| `end_calibration_preview` | device | Drops the held preview(s) that device owns -- its own and a companion strip's -- clears the dedupe identity the preview bytes left, and re-arms the live program. Idempotent: `{device, ended}`. |
| `apply_effect` | effect, scope, target, parameters? | Effect Studio assignment (`EffectAssignmentRecord.create`); `effect` null or `"none"` removes it. Protocol-1 alias of `set_assignment`/`clear_assignment`: answers the same fuller assignment document, parameters sidecar included. |
| `refresh_usage` | providers[] | Forces a provider usage refresh; the next `state` carries the result. |
| `list_providers` | provider?, instance? | The inspect surface behind `jrbar providers status`: one row per configured provider *instance* — `{id, instance, label, enabled, menu_visible, browser_sources_enabled, supports_browser_sources, supports_local_tokens, supports_quota, source_order, options, consents[], credentials[], imported_credential, state, reason, action, account_label, observed_at}`. `consents` carry `source_instance_id` so a row only lists the grants its own instance holds; `credentials` report `{account, available}` — availability, never the secret; `imported_credential` says the stored token came from a consented browser import (the only credential a revoke may remove). `state`/`reason`/`action` mirror the live snapshot for that exact instance. |
| `set_provider_enabled` | provider, enabled, instance? | Persists the per-instance enabled flag through the settings document's optimistic concurrency — a concurrent edit answers `settings_changed`, never a silent merge; `unknown_instance` when no configured instance exists. `{provider}` is the row as persisted, and an enable triggers a usage refresh for that provider. |
| `provider_consent` | action (`list`/`grant`/`revoke`), provider?, browser?, profile?, instance?, background_repair? | The exact-scope consent store. `grant` binds provider + browser + profile + the provider's declared domain/field allowlist and imports nothing — the import remains its own action. `list` returns `{consents[]}`; grant/revoke return `{consent}` with the bound scope, `was_granted`, and on revoke `imported_data`: `removed`/`replaced`/`retained`/`none` — the imported credential is deleted only while the stored value still matches the import's digest, so a user-replaced token survives. `unsupported` for providers with no consented browser source. |
| `provider_action` | provider, instance? | Runs the staged flow behind the provider's CURRENT action label — clipboard/LevelDB import, reconnect, repair — and returns `{provider, instance, message}` with the exact string the daemon surfaced (it may be a success note, not only an error). `unsupported` when no staged action matches the live state, `unknown_provider` for an unregistered id. Ownership is preserved: a credential the provider's own CLI owns (Grok's auth.json, Gemini's oauth_creds.json) produces a message pointing at that CLI, never a JR-Bar-side rewrite. |
| `install_hooks` / `uninstall_hooks` | providers[] | `install.py` per provider: install registers the hook command (with the compiled shim when available and the Codex trust hash recomputed); uninstall removes the managed hook blocks the installer wrote. `{providers, results{provider: {ok, detected, changed, config_path, codex_trust, warning}}}` — `detected` is the installed-agent inventory's finding for that provider, and an install for a provider whose CLI was never found is a per-provider `{ok: false, detected: false, error}` row, not a silently claimed success (uninstall has no such gate: it removes what is there). |
| `set_closed_lid_policy` | policy | `never`, `agents`, `always`. |
| `quiet` | mode (`dnd`/`pause`, `dim`, `mute`, `dark`, `asks_only`), seconds | A DND override for that long (0 ends the override). `{until, mode}`. |
| `confetti` | session?, provider?, reason? | A burst asked for from outside JR-Bar -- `jrbar confetti [--session ID \| --provider NAME \| --from-hook] [--why TEXT]`, a Stop hook, `make test && …`, CI (`confetti_requests.py`). `session` is the daemon's id (`claude:session:…`) or the agent's own (`session_id` from its hook payload, which names the session's main row before any worker); `provider` (`[a-z][a-z0-9._-]{0,31}`) wins over the session's own; `reason` is one printable line, at most 80 chars. Journals one `confetti` event (see event) and replies `{sent: true, coalesced: false, event, cursor, session, provider, unmatched}`. The daemon only states the fact: the app's Confetti toy fires it when the toy is on and the room is clear, with its own cooldown. A second ask inside 3 s (the app's cooldown) is answered `{sent: false, coalesced: true}` and never journaled, so a loop in a hook cannot evict the events a reconnecting app replays. A named session nobody watches still celebrates, in the Toys colour: `session: null`, `unmatched: <the id>`. Bad args are `invalid_args`. |
| `hold_awake` | exactly one of `seconds` (> 0), `until` (epoch), `until_time` (a local `HH:MM`, the next one, resolved in the Mac's zone so "until 08:00" survives a daylight-saving night), `until_agents_idle: true` (+ optional `sessions[]`), `indefinite: true`; `display` (default false); `source` (a short word, default `app`) | The person's keep-awake lease, the one hold every surface shares (the notch chip, a deck key, a CLI verb). It replaces any earlier lease, lasts at most 24 h (an agents lease: until none of its sessions is working or waiting on the person, backstop 12 h; without `sessions` it waits on every main session running now), holds the display too with `display: true` (the screen will not lock), outranks the agent-only switches (`agent_keep_awake_enabled`, `keep_awake_on_battery`) and survives a daemon restart. It yields -- never ends -- to heat and to the low-battery floor (`state.power.hold.suspended`). `seconds: 0` ends it, like `quiet`. `{lease, hold}`; `refused` "No agent is working right now." for an agents lease with nothing to wait on, `invalid_args` otherwise. |
| `release_awake` | | Ends the person's lease (the agent hold keeps its own switch). `{ended, hold}`; `ended: false` when no lease was in force. |
| `session_energy` | | Which agent session is keeping the CPU busy -- the battery reading no battery app can make (`jrbar.session_energy`). Each live main session's process (the pid its hook recorded, still running under the same start time) and every process under it -- the builds, tests and servers its tools started -- billed to the nearest session above it, so a session started from another's shell is never counted twice; shared-host providers are never billed. `{sampled_at, window_seconds, sessions[{session, provider, cpu_percent, cpu_seconds, processes}], total_percent, heaviest}`: `cpu_percent` is Activity Monitor's (100 is one core fully busy) averaged over `window_seconds` -- the time since the previous ask when that was 1.5 s to 15 min ago, else a 1.5 s window the command waits for -- and null for a session whose pid the earlier sample did not see; heaviest first; `heaviest` is the top session at 5 % or more, else null. One `ps` fork per sample and nothing sampled in the background; no command line or argument is read. Socket thread. |
| `list_cues` | | The semantic ambient cues by name (`jrbar.ambient_cues`), highest priority first: `{cues[{id, name, meaning, enabled, default_enabled, setting, priority}]}`. `id` is the ambient family (`firefly_completion`, `completion_meniscus`, `handoff_baton`, `recovery_grace`, `ask_heartbeat`, `turn_length_ember`, `fleet_arrival_departure`, `courtesy_signature`, `glance_light`, `rainstick_idle`, `milestone_odometer`); `setting` names what switches it -- `ambient_cues_disabled` for the nine that default on, the cue's own flag (`rainstick_idle_enabled`, `milestone_odometer_enabled`) for the two opt-in ones. The Dot's binary heartbeat and the assigned semantic effects are displays, not cues, and are not listed. The `milestone_odometer` row adds `count` (the exact completions this daemon has counted since it started) and `next_step` (the next of `milestone_odometer_steps` above it, or null), so its cue arrives with a meaning you could see coming. |
| `set_cue` | id, enabled | Switches one cue through its `setting` (a switched-off cue is still planned and simply never reaches a surface), saved like `set_setting`. `{generation, cues}`; `invalid_args` for an unknown id or a non-bool. |
| `burn_init` | program, device? (id, default every connected strip and Dot), confirm? (default false) | The power-up program. Each device is judged at its own LED count through `animation.plan_power_up_burn`'s four gates -- the model, the compile, the device limits and the real firmware parser, refusing when that parser is unavailable. Without `confirm: true` nothing is written: the reply is the exact plan. `{confirmed, written, devices[{device, name, led_count, bytes, firmware_checked, warnings[], written, target, error}]}`; a device whose program does not validate carries `error: "invalid_program"` and `problems[{severity, code, message, step}]` and is never written. Runs on the socket thread (an SD write can take seconds). `not_found` with no connected hardware (the Screen Bar has no INIT.LED), `invalid_args` for an empty program, one past 4096 characters, or a non-bool `confirm`. |
| `calibration_profile` | action (`save`/`apply`/`delete`), slot (`Day`/`Night`/`Travel`) | The calibration profile slots: `save` snapshots every known device's brightness, gains and resting glow into the slot, `apply` writes the slot back onto the devices it names (`matched` counts them; `not_found` for an empty slot), `delete` empties it. `{slot, action, generation, slots[]}` (`delete`: `{slot, removed, slots}`). `focus_profile_rules` maps a Focus id to a slot the daemon applies when that Focus turns on; write it whole with `set_setting` on `focus_profile_rules` -- Focus ids contain dots, so a per-key dot path cannot address them. |
| `auto_dim_learning` | clear? (bool: forget the votes) | What the panel slider has taught the ambient curve (`jrbar.auto_dim`). While auto-dim follows the ambient sensor and the sensor answers, every `set_brightness` for `all` over at least one connected hardware device (auto-dim scales only the hardware) is a vote -- at this smoothed lux the person chose lights at their slider times the curve's factor -- the latest vote at a given light (within 25 %) replacing an older one, 24 kept since the daemon started. Once there are 3 votes from light at least 3 times brighter than the darkest, and a curve fits them clearly better than the one set now, it is OFFERED, never applied: `{mode, votes, ready, reason, suggested{brightness, min_fraction, lux_floor, lux_ceiling} or null, error_now, error_suggested, samples[{lux, level, at}]}` -- `reason` `needs_votes`, `needs_range`, `already_fits` or `no_fit` while not ready; the app applies a suggestion with `set_setting` (`auto_dim.ambient.*`) and `set_brightness` when the person says so. `invalid_args` for a non-boolean `clear`. Socket thread. |
| `check_palette` | colors? (`{"agent:<provider>": "#RRGGBB", "state:<idle|working|done|ask|error>": "#RRGGBB"}`, an edit previewed on top of the saved palette), visions? (list of `normal`, `deuteranopia`, `protanopia`, `tritanopia`; default the first three, the ones the shipped palette was searched against) | The colour-vision check: which of the person's provider and state colours read as one light for a colourblind viewer, measured the way the palette was chosen (Viénot's LMS simulation, CIE Lab distance, 12 the floor). `{min_separation, visions, checked, pairs[{left, right, left_color, right_color, vision, separation, shipped, suggestion}]}`, worst first: `vision` is the worst model for the pair, `shipped` true when both colours are exactly as shipped (the person did not cause it), and `suggestion` `{key, color, separation}` the smallest lightness step (hue kept, still bright enough to be a light) that clears the moved colour from every other colour, not just its pair -- the person's own edit moves first, then a provider before a state -- or null when no such step exists. Error is checked as the lights paint it. Nothing is written. `invalid_args` for an unknown key, a colour that is not `#RRGGBB`, or an unknown vision. Socket thread. |
| `preview_fleet` | scenario? (default `fleet`: two working, one done; or `quiet`, `one_working`, `one_needs_you`, `same_provider_duo`, `pair`, `full_team`, `busy_team`), blend_mode? (`color_blend`, `round_robin`, `spatial_split`, `relay`, `cycle`, `classic`; default the device's own, else the global), cycle_speed_seconds? (the speed that mode plays at, even over its own override), device? (whose blend to use), led_count? (2 or 8, default 8) | A blend mode played against a synthetic fleet in the person's own colours, before choosing it -- how a mixed desk reads, which a single swatch hides. Compiled exactly as the device would play it; nothing is written to a device. `{scenario, label, blend_mode, cycle_speed_seconds, led_count, program, transformed, agents[{provider, mode}]}`. A scenario with an ask in it shows one strip under every blend: an ask takes the strip. `invalid_args` for an unknown scenario (or `live`), blend mode or LED count. Socket thread. |
| `resolve_effect` | semantic (`ask`, `failure`, `notification`, `handoff`, `work`, `completion`, `recovery`, `environment`, `idle`), scene? (default the active scene), provider?, instance?, project?, device? | Situation preview for the Effect Studio: which assignment wins before the situation happens. `{semantic, scene, urgent, winner{scope, target_id, effect_id} or null, ladder[{scope, target_id, applicable, effect_id, wins}]}` -- the ladder walked in precedence order (device, project, provider instance, provider, scene, meaning, everywhere), each rung's own assignment shown so a losing one is visible too. An ask or a failure keeps its reserved alert: `urgent` is true and only the meaning rung is walked. `invalid_args` for an unknown meaning or scene, or an empty id. Socket thread. |
| `list_light_log` | limit? (default 20, at most 200) | The light log for Why this light: the content-free effect history (`effect_history`, 200 events, persisted) newest first -- `{rows[{at, effect, category, surface, outcome, explanation, unseen}], total, last_seen}`, where `outcome` is `shown`/`suppressed`/`acknowledged`/`expired` and `explanation` is the history's own sentence ("Suppressed on the Dot by Do Not Disturb."). No provider text, session or path is ever in it. `invalid_args` for a non-positive limit. |
| `list_focuses` | | The Focuses this Mac has configured, so a per-Focus rule can name a custom one: `{available, reason, focuses[{id, name}], active[]}`. macOS keeps the roster beside the Focus assertions it guards with Full Disk Access; without that grant `available` is false and `reason` says why. Socket thread. |
| `presence` | mic, camera, screen_shared (bools), locked? (bool), idle_seconds? (≥ 0), focus? (bool, INFocusStatusCenter's `isFocused` from the app's grant), meeting_until? (epoch of a calendar meeting's end, at most 12 h ahead), next_event_start? (epoch, or null for "nothing coming"), reminders_due? (list of up to 32 reminder ids) | The app's report of what it senses (`jrbar.presence`). `next_event_start` and `reminders_due` are the app's own Calendar and Reminders readings: while they keep arriving (each stands 180 s), the calendar and reminder glows use them and the helper never asks EventKit or needs a grant of its own -- one reader, so the glow and the shelf cannot disagree; absent keys leave the helper's own read in place, and a malformed one refuses the whole report. A live microphone, camera or screen share is a call: the quiet policy gains a `call` source per `call_quiet_mode` (default `sounds`: every light and banner stays, `audible_allowed` goes false), the escalation ladder holds at `ramp` (no menu-bar pulse on a shared screen, no chime into a headset; `escalation_stage` events follow the held stage), and `state.presence.celebrations_held` asks the app's celebrations to hold their burst. A meeting adds a `calendar` source per `meeting_quiet_mode` (default `off`) until `meeting_until`. `locked`, or `idle_seconds` of 300 or more, is away: an ask that reaches the menu-bar stage goes straight to the finale (still capped by `escalation_tier`). `focus: true` stands in for the daemon's own Focus reading while the daemon holds no Focus Status grant (Follow Focus must be on). A report stands for 180 s: the app renews it at least every minute while a sensor is live or `focus` is true, and a stale one ends the call (and the Focus stand-in) on its own. Unknown keys are ignored; a known key of the wrong type is `invalid_args`. `{presence}` (the `state.presence` document). |
| `list_history` | since, limit | Everything `sessions` no longer lists. Activity ledger rows `{at, kind, provider, session, label, detail, duration, unseen}`; kinds `completed`, `asked`, `failed`, `quota_crossed`. `label` is the name the last published `state.sessions` row gives that session (the provider's own title), falling back to the label recorded with the row for a session `sessions` no longer lists; a `detail` that only repeated the new label is dropped. `duration` is set only when the daemon observed both ends of the active stint — a session first seen already over gets none. `unseen` is derived per row from `at > last_seen`, the ledger's persistent watermark; the daemon also marks everything seen when the last client disconnects. `{rows, total, last_seen}`. |
| `list_roster` | scope (`all`/`live`/`workers`/`attention`/`finished`/`hidden`), provider, parent, since, limit | The independent roster: every session the collector retains — panel visibility never removes a row. Each row is the `state.sessions` shape plus `schema` (record contract version), `pinned` (open ask), `visibility` (the verdict the panel *would* give: `live`/`completion`/`hidden`), and `axes`: `{outcome, review, freshness}` — `outcome` is `none`/`succeeded`/`failed`/`unreported`/`unknown` (what the provider reported, separate from `lifecycle`), `review` is `pending`/`unreviewed`/`reviewed` (Clear Agents acknowledgement is the review receipt), `freshness` is `live`/`delayed`/`unknown` (is the source still delivering). `hidden` scope is the audit cut: exactly what panel aging evicts. `{t:"roster", schema, now, scope, filters, sessions, counts{total, workers, attention, live, finished, hidden_from_panel, listed}, coverage}` — `coverage` names the bound: the collector's retained statuses; deeper history is `list_history`'s event ledger, not session records. `invalid_value` for an unknown scope. |
| `session_timeline` | id? or session+provider, cwd?, limit (default 100, max 500), before? | A session's provider transcript as bounded, paginated items — the Overview inspector's Timeline (S7.2). `id` is a roster row id and resolves the status's provider/`session_id`/cwd itself (`not_found` for an unknown id); an ended session whose status aged out is still inspectable via `session` (the provider uuid) + `provider` + optional `cwd`. Items are `{seq, at, kind, role?, name?, text?, tool_use_id?, is_error?, sidechain?, model?, uuid?, parent_uuid?, origin:"transcript", recorded_at:null, untrusted?}` — `kind` is `message`/`tool_use`/`tool_result`/`turn_end`; `tool_use`/`tool_result` pair on `tool_use_id`; `at` is the row's own stamp (occurrence) and `recorded_at` stays null because per-row ingestion time was never kept. `untrusted` marks tool output and assistant text — content, never a command. `before` is the seq of the oldest item the caller holds; the reply is `{schema, events[], has_more, next_before, total, source{provider, file}, gaps[]}` where `gaps` names `transcript_not_found`, `transcript_unreadable`, `transcript_too_large:N`, `timeline_item_cap:N`, or `unsupported_provider` (providers without a transcript reader answer that, not an empty success). Supported: `claude` (`~/.claude/projects/**/*.jsonl`) and `codex` (`~/.codex/sessions/**/*.jsonl`), matched by uuid-in-filename. Reads are bounded (64 MB file cap, 5000-item cap, 600-char text, secret-run redaction). `invalid_value` without a provider. |
| `compare_sessions` | a, b (roster ids, different) | Two runs side by side on retained facts only (S7.4). `{t:"compare_runs", schema, generated_at, a, b, shared{provider, workspace, model:null}, warnings[], gaps[]}` — each side is `{id, label, provider, cwd, lifecycle, mode, axes, remote, activity, interruptions, artifacts, model:null, gaps[]}`. `activity` is the transcript aggregate `{counts{user_messages, assistant_messages, tool_uses, tool_failures, retried_tools, turn_ends, sidechain_rows}, tools{name:count}, span{first_at, last_at, duration_s}, file}` or `null` with a named gap (`transcript_not_found`/`unsupported_provider`); `interruptions` counts the ledger's `asked`/`blocked`/`completed` rows for that agent id. `artifacts` is the files the run's edit tools named, read from each tool call's input (Claude Edit/Write/MultiEdit/NotebookEdit `file_path`, Codex `*** Add/Update/Delete File:` patch headers): `{files[{path, edits}], total, truncated}`, paths relative to the run's cwd or `~`, most-edited first, at most 200; `null` when the transcript was not read, and then `gaps` names `artifacts_not_tracked`. `model` is always `null` (per-session models come from `session_usage`) and `gaps` names `model_not_tracked`. `warnings` always includes `not_a_controlled_benchmark` plus `different_providers`/`different_workspaces` when the sides differ. `invalid_value` for missing/identical ids; `not_found` for an id not in the retained set. |
| `session_usage` | ids[] (roster ids, up to 64), since? (epoch) | Per-session model, tokens, cost and context for the panel's rows, the Overview's Model/Cost columns and Compare runs. Each id resolves its status's provider/`session_id`/cwd like `session_timeline`, and the session's own transcript is read incrementally (only bytes appended since the last request; a shrunk or replaced file is re-read). `{schema, sessions{id: {provider, model, models{model: tokens}, tokens{input, cached_input, cache_creation, output}, turns, estimated_cost_usd, cost_estimated, unpriced_models[], context_tokens, context_window, context_window_source, first_at, last_at, partial, tokens_since?}}, gaps{id: reason}, since, pricing{as_of, table_version, semantics:"api_equivalent_estimate"}}`. Every id lands in exactly one of `sessions` or `gaps` (`remote`, `not_found`, `unsupported_provider`, `transcript_not_found`, `transcript_unreadable`, `reading`) — never a zero. A request reads for at most 1.5 s (checked between lines and between files, a line at a time); an id whose transcript it did not finish, or did not reach, answers `reading` rather than a partial total, and the next request carries on from the saved offset. A lookup that finds no transcript is trusted for 60 s. Counting follows `usage_stats` (Claude: first sighting of a message id; Codex: `last_token_usage` deltas or cumulative differences, cache reads/writes split out of input). `estimated_cost_usd` is the Usage Center's list-price estimate (`cost_estimated` when a stand-in rate priced any model, null when no model had a price). `context_tokens` is the newest main-chain turn's prompt; `context_window` is Codex's `model_context_window` (`reported`) or, for Claude, 200k/1M `inferred` from the largest prompt seen. `partial` when a transcript past 64 MB was read from its tail. `since` adds `tokens_since` (turns at or after it). `invalid_value` for an empty `ids`. |
| `mark_history_seen` | | The user just looked at History: advances the ledger's `last_seen` to when the command arrived (it waits on the slow lane, so not when it ran), so `unseen` rows and the "while you were away" banner measure from the last look, not from an app restart. `{last_seen}`. |
| `audit_export` | scope (roster scopes), provider?, parent?, since?, ids?, view?, format (`json`/`markdown`), path? | The redacted audit bundle over the SAME `list_roster`/`list_history` projections the surfaces show: `{format, document{t:"audit_export", schema, core_version, generated_at, scope, counts, coverage, gaps[], sessions[], activity[], pricing?, redaction, audit_only}}` — sessions/activity rows are the projected fields only (no raw provider payloads), with the home prefix collapsed to `~` and secret-shaped runs (≥24 unseparated chars) replaced by `[redacted]`. `gaps[]` names what is missing: no collector snapshot, ledger rows past the `since` cut, a usage scan still pending. `pricing` is the cached per-provider usage coverage (`records`, `estimated_records`, `unpriced_records`, `unpriced_models`, `pending`/`stale` flags over the 30d range) — the export never blocks on a cold scan. `format: "markdown"` adds `text` (the rendered report). `path` writes the bundle through `write_private_export` to a user-picked destination (`written{path, bytes}` in the reply); without it the document returns for preview. `ids` (a list of roster ids) narrows sessions and activity to the rows a surface is showing — the Overview's preset, project, search and selection are app-side cuts no roster scope expresses — and `view` names that cut; the bundle's `gaps` then say "Exported the N sessions in <view>; the roster retains M." An application audit, not a compliance record. `invalid_value` for an unknown scope. |
| `replay_events` | after?, limit? (default 500, capped at the journal size) | The event stream's resumable suffix. `after` is a `cursor` from an `event` frame or `hello`; omitting it replays the whole retained journal. Replies `{t:"events", stream, retained, dropped, events[], cursor, has_more, resync_required}` — `events` are the exact journaled frames in order, `cursor` is the last one returned, `has_more` means the page cut before the tail (call again with that `cursor`). A cursor from another stream incarnation answers `resync_required: true, reason: "foreign_stream"`; one the bounded journal already evicted answers `reason: "cursor_expired"` — never a fabricated empty catch-up. `retained`/`dropped` are the journal's coverage/gap counters. `unsupported` when the core cannot replay. |
| `dismiss_session` | session | Acknowledges one live or stuck row until it next speaks — the same receipt `clear_completed` writes, aimed at a single session the batch clear would never touch; the row leaves `sessions` now and returns the moment a newer event lands. `not_found` for an unknown session, `refused` for a `remote:` row (the peer's to manage) or a session with an open ask (the ask is the point). |
| `new_session` | provider, cwd, terminal? | Starts that agent's CLI (`claude`, `codex`, `devin`, `grok`, `cursor-agent`, `hermes`) in `cwd`, in the owner's own terminal: `terminal` (`com.mitchellh.ghostty`, `com.apple.Terminal`, `com.googlecode.iterm2`) when named, else the terminal the most recent recorded session ran in, else Ghostty when installed, else Terminal.app. Ghostty gets a new tab in its front window at `cwd` with the command typed into the owner's shell (a new window through the reviewed launch plan when it refuses the Apple event); Terminal.app and iTerm2 a new window. `{provider, cwd, raised: "new_tab"\|"new_window", app, bundle_id}`. `invalid_args` for an unknown agent, a relative path or an unreviewed terminal; `not_found` for a directory that does not exist; `unsupported` when the terminal could not be opened. Explicit only -- the Overview's "New session here"; the agent's first prompt is still the owner's to type. |
| `resume_session` | session, terminal? | History's Resume, by agent id (`list_history` rows carry it). A session `sessions` still lists opens exactly as `open_session` would. One it no longer lists is found in the process registry, which knows its directory: ended, it resumes in the terminal named by `terminal` (`com.mitchellh.ghostty`, `com.apple.Terminal` or `com.googlecode.iterm2`), else **in the terminal it ran in** (recorded at its SessionStart), else the terminal of the owner's most recent session, else Ghostty when installed -- as a new Ghostty tab at the session's directory with the resume typed into the owner's own shell, or a new Terminal.app / iTerm2 window: `{session, provider, cwd, raised: "new_tab"\|"new_window", app, bundle_id, detail: "resumed"}`. Still running (cleared from the list, not ended), its own tab, pane or Ghostty terminal is raised instead -- `raised: "pane"\|"tab"\|"terminal"\|"app"` -- and one JR-Bar cannot find refuses `not_found` ("…nothing new was started."): a second process on a live session is never started. `not_found` also for no registry record or a directory that is gone; `unsupported` for a remote row, a worker, or an agent JR-Bar cannot resume (Claude, Codex, Devin, Grok, Cursor, Hermes CLIs only); `invalid_args` for another `terminal`. Explicit only. |
| `hooks_doctor` | | `jrbar hooks doctor` as data, for a per-provider line in Settings › Agents: `{checked_at, state_dir, shim, shim_env, ingress_socket{path, answers}, core_socket{path, answers}, pending[{file, lines}], providers[{provider, label, config_path, installed, hook_events, registered[], registered_commands[], would_install, would_install_command, last_event_at, pending_lines, decide?}]}`. `last_event_at` is the provider's event log's modification time (when a hook last reached the daemon), `pending_lines` the payloads queued for it while the daemon was down, `decide` (Claude and Codex only) `installed`/`missing`/`not_installed` for the decide lane. Content free: paths, command shapes, counts and times. Repair is `install_hooks`. |
| `t3code_integration` | enabled? (bool) | Settings › Agents' T3 Code row, `jrbar-integrations enable\|disable t3code` as data: `{present, database, enabled, activity_statistics, read_only, observation}`. `present` is whether T3 Code's database (`$T3_HOME` or `~/.t3`, `userdata/state.sqlite`) exists, `read_only` whether `integrations.json` was written by a newer build. With `enabled` the opt-in is written first through the integration-settings facade (a no-op when already so) and the T3 reader is reconciled at once rather than on the next refresh; a file it cannot safely replace refuses `refused` and stays as it was. `observation` is null while off, else the reader's last look `{available, threads, active, needs_user, reason, in_flight}`. The read stays local and read-only. A non-bool `enabled` is `invalid_args`. |
| `session_in_front` | session | Whether the owner is looking at that session's own tab, pane or Ghostty terminal right now, for "Quiet while you watch" (every Ghostty window is one process, so the app alone cannot tell a background tab from the one in front): `{session, in_front, evidence, app}`. `in_front` is `true` only on proof -- `focused_tab_tty` (Terminal.app / iTerm2 named the focused tab and it is the session's), or `recorded_surface` (Ghostty's focused terminal is the one recorded at the session's SessionStart, still in the session's directory -- the process's, or the one it started in; being the only terminal in that directory is never enough); `false` for `other_app`, `other_tab` or `other_surface` (the focused Ghostty terminal is in another directory, or the recorded one is open and something else is focused); `null` when it cannot be told -- `tmux_unproven` (the terminal around a tmux pane is not the session's ancestor), `tab_unproven` (kitty, WezTerm, an IDE: the app is in front, the tab unknown), `automation_not_granted` (macOS has not yet allowed JR-Bar's Apple events to that terminal; this command never asks), `focused_tab_unproven`, `focused_surface_unproven`, `ownership_unproven`, `not_running`, `remote`. Nothing is raised, typed or prompted. A surface reads `null` as "keep its own rule". |
| `doctor` | | `{ok, core_version, commit, python, pid, socket, uptime_seconds, clients, hooks, devices, settings_generation, state_generation, commands, checks[{name, ok, detail}], memory, performance}` from `doctor.py` plus the hook shim and pending-file checks. `commit` is `JRBAR_COMMIT` from an installed deployment (`scripts/install-agents.sh`), else the checkout's HEAD; `alcove_follow_state` never fails the daemon (Alcove following is the app's). `performance` is `{metrics{name: {count, p50_ms, p95_ms, max_ms, outcomes}}}` (the `PerformanceRegistry` timings the legacy Why panel renders), `cpu{user_s, system_s, percent_since_last}` (rusage deltas between doctor calls; `percent_since_last` is `null` on the first), and `frames{state_generation, lights_generation, state_per_minute, lights_per_minute}` (documents actually broadcast, counted over a rolling 60 s window). `jrbar doctor` appends these as a `performance:` section when a daemon answers (its `--socket` selects another daemon); `--json` carries it under `daemon.performance`. |
| `usage_history` | provider, range (`7d`, `30d`, `90d`, `365d`) | Daily and hourly token/cost rows for one provider from the local transcript scan (`usage_stats.scan_usage`, the same one the Python Usage window ran): `{provider, range, days[{date, tokens_in, tokens_out, cache_read, cost_usd}], hours[{hour, at, …}] (last 7×24), pricing{input_per_mtok, output_per_mtok, cache_read_per_mtok, as_of, approximate, currency, model, source, estimated} or null, account, state, records, estimated, estimated_records, unpriced_records, unpriced_models[], models[{model, tokens, cost_usd, records, priced, estimated}]}`. `tokens_in` counts input plus cache writes. `models` splits the range's tokens and dollars by the model each record ran on, most tokens first (Claude records carry the pricing key, `opus-4-5`; Codex records the turn's model) — it sums to the `days` rows it was cut from. `pricing` is the dominant model's quote from the Python price tables (`usage_stats.MODEL_PRICING`, `GPT_MODEL_PRICING`, `GEMINI_MODEL_PRICING`; cache reads 0.1× input, Anthropic cache writes 1.25×, OpenAI cache writes 1×): `source` is `table` (the model's own row), `codex_default` (a Codex record that names no model, the literal `codex` from rollouts without a `turn_context` row, is priced at the `model` in `~/.codex/config.toml`; records after a `turn_context` carry that turn's model, `gpt-5.6-sol`, `gpt-6-astra`, and are priced as it) or `reference` (a model the table does not know, priced at the provider's mid-range reference model, `sonnet` / `gpt-5.6` / `gemini-3-flash`, with `estimated: true` rather than $0). The document's `estimated` says whether any counted record was priced that way. `unpriced_records`/`unpriced_models` are the other failure: counted records whose model has no quote at all (a provider with no price table and no reference rate) — their tokens are in the rows, the $0 they contribute is a real absence rather than a price, and they are never blended into `estimated`. Claude and Codex have transcripts; Gemini and any other provider answer empty rows, Gemini with its reference quote so the rate card still shows. Every dollar figure is approximate. The scan runs on its own thread and the reply waits for it at most 2 s (`core_usage_history.REPLY_BUDGET_SECONDS`): a warm scan (the on-disk cache under `~/.local/state/jrbar/usage-scan-cache.*` is incremental, keyed by file mtime and size, so only new or changed transcripts are parsed) answers inside that; a cold one answers what memory holds, `pending: true` with empty rows when there is nothing yet, or the last document with `stale: true`, and the `usage_history_ready` event follows when the scan lands. `scanned_at` is the epoch of the scan behind the rows (null while pending). A document younger than 60 s answers as is. The daemon warms both providers' 30-day scans 8 s after it is ready, so on the Mac the first request is normally warm (measured 2026-09-10: cold Codex 45 s, Claude 11 s; warm Codex 1.5 s, Claude 1.0 s, plus 0.3 s of bucketing). |
| `usage_graph` | days? (`7`/`30`/`90`/`365`), metric? (`tokens`/`cost`/`sessions`/`percent`), providers? (nonempty list of registry ids) | The shared-axis multi-provider usage chart — the same local-transcript scan `usage_history` runs, assembled by `usage_graph_worker.usage_graph_document` into `{graph, summary}`. `graph` is `{days, period_label, metric, labels[] (strided "MM/DD", empty slots draw no tick), series[{provider_id, values[], source_instance_id?, identity?, label?}], scale_max, heatmap, providers[], partial_provider_ids[], cost_semantics?}` — `values` and `labels` are index-aligned one slot per calendar day, and a series value `< 0` is a gap day (before the provider had samples): the client must break the line there, not bridge it. Percent mode emits one series per (provider, source instance): two rows can share `provider_id`, so chart identity must carry `source_instance_id` (`label` is the daemon's display name, `provider · instance` for a non-default instance) — keying on `provider_id` alone merges them into a fabricated single line. `providers` echoes the resolved request so a picker can tell unchecked from checked-but-empty. `heatmap` is the JSON-projected day grid `{days[] (ISO), providers{id: {provider_id, cells[{day, tokens, sessions, intensity 0–4, color, accessibility_label}], totals{tokens, sessions}, data_status}}, aggregate, timezone}` — the same GitHub-style calendar the old Settings window drew. `summary` is the scan's own sentence ("Last 30 days: Claude 12.3M · 45 sessions") including its `Partial local history:` and `API-equivalent estimate` disclosures — the client shows it verbatim rather than recomputing. All three args are per-request overrides: absent means the stored `usage_graph_*` settings, and nothing the pane picks is written back. Invalid overrides are `invalid_args`, never a silent substitution. The scan is heavy on a cold transcript cache (~30 s): the command runs on the client's socket thread at utility QoS, so the reply can take that long — clients should pass a long timeout and show a scanning state. |
| `list_effects` | | `{effects[], packs[], cadences[], generation}`: every effect in the runtime registry (builtins, the provider animations and installed packs) with typed `parameters[]`, a `preview {program, led_count}` rendered at the defaults, the blink `cadence` when one applies; `packs[]` is `{id, name, version, effects[ids], license?, path?}` from the pack store; `cadences[]` the three safe blink cadences. `generation` is derived from the catalog's own content -- every effect id and version, every installed pack's id, version and effect list, plus the assignment cache's save counter -- so it changes when the registry, the installed packs or the assignments change, and does not otherwise (`core_effects.catalog_generation`). It is stable across daemon restarts and never 0. |
| `render_effect` | effect_id, parameters, led_count, color? | `{effect_id, program, led_count, parameters, cadence}`: the LEDS program the daemon would play for those parameters (unknown parameters dropped, bounds enforced), through the presentation safety compiler. Builtins use their registered shapes, provider animations the live solo renderer (`duration_seconds` sets the cycle), pack effects their `motion`/`color`/`cadence` data or a primitive for their meaning. |
| `list_assignments` | | `{assignments[{effect_id, scope, target_id, parameters}], active_scene, generation}` from the effect assignment store; `parameters` come from the daemon's sidecar (`effect-assignment-parameters.json`). `generation` is derived from the assignments and the active scene (`core_effects.assignments_generation`). |
| `set_assignment` | effect_id, scope, target_id?, parameters? | Validates through `effect_studio.plan_assignment` (global takes no target, `asking`/`failure` keep `alert`, scenes and semantic families are checked), saves the assignment document and the parameters sidecar, refreshes. Semantic targets outside the four the event router can deliver (`asking`, `failure`, `completion`, `notification`) are refused `unroutable_semantic` — `working`, `idle`, `recovery`, `environment`, `transition` and `quota` are persistent states, not deliverable effects. A `provider_animation`-catalog effect assigned at `provider` scope also writes `colors.provider_animation[target]`, the persistent motion the live renderers read, and the reply gains `motion_warning` when that settings write fails. Replies the assignment document plus `assignment`. |
| `clear_assignment` | scope, target_id? | Removes that assignment (and its parameters sidecar entry, and the `colors.provider_animation` entry when the removed row was a provider-scope motion); the document plus `removed`. |
| `import_effect_pack` | path, update? | `EffectPackStore.install` of a data-only JSON v2 pack (`invalid_pack` on anything the validator refuses, `conflict` when that pack id is installed), the registry rebuilt with every installed pack; replies the catalog plus `imported {id, name, effects}`. `update: true` replaces the installed pack with that id instead (`refused` with `not_installed` when there is none, `already_current` when nothing changed). |
| `remove_effect_pack` | pack_id | `EffectPackStore.remove` of one installed pack (`not_installed`/`refused`/`remove_failed` as appropriate), the registry rebuilt; replies the catalog plus `removed {id}`. |
| `export_effect_pack` | ids[], path, name? | Writes a data-only JSON v2 pack of those effects (pack effects keep their data, builtins become their motion plus parameter defaults, fallbacks kept only when exported too) through `write_private_export`; `{path, effects, bytes, id}`. |
| `list_scene_packs` | | `{packs[{id, name, scenes[], installed}]}` — the installed Scene packs as the `ScenePackSummary` the app decodes; `scenes` lists the scene names each pack overrides. |
| `import_scene_pack` | path, update? | Validates the pack file first (`preview_source`, so nothing writes before the plan exists — a version-1 pack is migrated in memory, `invalid_pack` when the validator refuses it), then `ScenePackStore.install` (or `update` with `update: true`). `{pack_id, name, scenes[], installed, migrated, status}`; `conflict` when the pack id is installed and no update was asked for. Scene packs are data-only, network-free and bounded, must declare reduced-motion / high-contrast / non-colour-cue support, and may only name the known scenes (`focus`, `calm`, `night`, `demo`, `travel`, `dnd`). |
| `preview_scene_pack` | pack_id, led_count? | `not_found` when no installed pack has that id. Else renders the pack's scene-by-scene policy tour — one step per overridden scene, the scene's colour dimmed by its brightness policy, the motion policy choosing step length and interpolation — through the presentation safety compiler at the requested LED count (clamped 2–24). `{pack_id, led_count, program}` — an `EffectPreview` with a `pack_id` extra the app ignores. |
| `serve_token` | | `{token, enabled, running}` — the bearer `JRBAR_SERVE_ACCESS_TOKEN` the daemon was launched with (null when none), whether `serve_enabled` is on, and whether the loopback server is actually bound. When `serve_enabled` and the token are both present the daemon hosts `serve.create_serve_server` in-process (port `JRBAR_SERVE_PORT`, default 8737); a missing token means no endpoint, never anonymous. The token travels on the local socket only, never inside the HTTP document it guards. The same server carries `GET /asks.json` and `POST /answer` (see "Answering from serve" below), which act only while `serve_answer_enabled` is on. |
| `deck_press` | index 0…23 | What a press of that control does, from the screen (the physical key runs the same rule through `DeckInputDispatch`). An explicit `deck-controls.json` mapping wins (`{index, action: <kind>, receipt}`; `next_bank` / `previous_bank` add `bank`, `next_scope` / `previous_scope` add `scope`; a failed app shortcut is `refused` with the deck controller's sentence). Else a session key: when that session has a live ask the decide lane holds -- in any terminal, frontmost or not -- or a live ask whose terminal or origin app is frontmost, the press approves it through the `answer_ask` path (`{action: "answer_ask", decision: "approve", answered: true}`); otherwise it reveals the session through the board's navigation resolver (`{action: "reveal_session", receipt, activated}`). `not_found` with "No session assigned." / "Reserved: session not observed." / "Configure this control in the Creator Micro window."; `input_check` while input check is on. |
| `deck_answer` | index 0…12, decision (`approve`, `deny`, `always`, `answer`), answers? (with `answer`), request?, command_id? | An explicit answer from a session key -- the Rail's Deny, Always allow (from its own button) or a picked choice, a Stream Deck key through serve's `/answer` -- where a press can only approve. The key's session is answered through `answer_ask` with `only_if_frontmost: true`: the same fences, command journal and decide lane (`always` and `answer` only while the lane holds the agent's own prompt), so a key can never do what the panel's own buttons could not. Never falls back to revealing: a key whose session has no live ask refuses `not_found`. `{index, identity, session, action: "answer_ask", …the answer_ask receipt}`. `invalid_args` for another decision or an index past the session keys; `not_found` for an empty or reserved key; `input_check` while input check is on. Runs on the socket thread. |
| `deck_pin` | index 0…12 | Toggles the pin on the identity at that key (pins are per identity and survive Clear absent). `{index, identity, pinned}`; `not_found` for an unassigned key. |
| `deck_bank` | delta | Steps the bank, wrapping. `{index, count}`. |
| `deck_scope` | delta | Steps the board scope through `automatic` plus the configured provider scopes, wrapping (what the `next_scope` / `previous_scope` aux actions run). `{scope, scopes}`. |
| `deck_rail` | edge (`off`, `left`, `right`, `top`, `bottom`) | The compact rail's edge, persisted with the board. `{edge}`. |
| `deck_clear_absent` | | Unpinned identities with no observed session leave the board; later keys move up. `{removed, banks}`. |
| `deck_plan_keymap` | profile, layer, include_auxiliary, layers? | `creator_micro_keymap.plan_keymap` for that layer over the inspected keymap: `{profile, layer, include_auxiliary, changes[], preview, controls[{index, label}]}`, `preview` being the Python review alert's text. `layers` (`[{"layer": int, "name": str}]`) previews the multi-layer write instead: every listed layer is claimed and named. The first call (and any call after 120 s, or after a write) inspects the device: the output service is stopped, the keymap read, the pad handed back. `invalid_plan` with the ValueError message; otherwise the receipt code (`connection_required` when the pad is not approved, `busy` while another setup runs). Socket thread. |
| `deck_apply_keymap` | profile, layer, include_auxiliary, layers? | `CreatorMicroSetup.apply` of that plan (private backup first, verified write, readback): `{code: keymap_verified\|already_configured, message, changes, state, backup_at, generation}`; input check turns on after a verified write. With `layers`, one write claims and names every listed layer (`apply` re-derives the whole plan, so a forged selection cannot write arbitrary JSON). Refusals are error replies whose code is the receipt (`keymap_changed`, `recovery_required`, `readback_mismatch`, …). No alert is shown; the confirmation is the app's. |
| `deck_restore_keymap` | | `CreatorMicroSetup.restore` from the first private backup: `{code: keymap_restored\|already_restored, message, state, backup_at, generation}`, same refusals (`backup_invalid` with no backup, `keymap_changed` for later device edits). |
| `deck_approve_device` | | The Devices pane's Enable, for a pad that is here: the daemon probes HID once more and refuses with `no_device` ("No Creator Micro 2 is connected.") when it sees none, so a remembered serial is never enabled blindly; otherwise the sole stable serial becomes `creator_micro_device_serial` with `creator_micro_enabled` and the output service is reconfigured. `{serial, approved}`; `ambiguous_device_identity`, `device_identity_unavailable`. |
| `deck_check_input` | enabled | Input check on or off (queued input is revoked). `{enabled}`. |
| `deck_set_settings` | enabled?, session_mode?, analog_enabled?, bindings?, layer_map?, scopes? | Writes `deck-controls.json`, reconfigures the deck runtime. `bindings` replaces the whole auxiliary set (`{index, action|null}` rows for controls 13…23 — 20…23 are the analog joystick sectors; a null unbinds; matrix-key bindings survive). `layer_map` (`{layer, scope}` rows) maps hardware layers to board scopes and `scopes` adds provider ids past the mapped ones; both are validated (no duplicates, `automatic` only inside `layer_map`). The three bools; `invalid_args` for anything else. |
| `ping` | | `{pong, now}`. |
| `quit` | | Replies, then the daemon releases its holds and exits. |

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
| `unsupported` | the provider's contract does not declare `answering`, or the answer controller would not accept the action (a typed reply, an already-sending attempt) | `this ask cannot be answered from here` |
| `stale_ask` | the request left the live phase between the command and the keystroke -- answered in the terminal, timed out, superseded -- or the delivery overran `answer_local.DELIVERY_BUDGET_SECONDS` (4 s). Re-checked immediately before the key is posted, so a resolved ask never leaves a keystroke pending. | reason `resolved_elsewhere`, `resolved_while_sending`, `budget_exceeded`, `not_in_canonical_state` |
| `session_gone` | the session's process is not running, or the daemon has no row for it, or it is stopped (Ctrl-Z) so its terminal is showing the shell | reason `no_live_process`, `no_session_row`, `process_stopped` |
| `not_frontmost` | the window in front is not this session's. Reasons: `no_frontmost_app`; `unknown_host` (JR-Bar cannot say which app hosts the session); `frontmost_is:<bundle id>`; `other_window` (the frontmost application's process is not the one the session descends from); `other_tab:<tty>` (Terminal.app / iTerm2 named a focused tab that is not this session's); `other_surface` (Ghostty's focused terminal is in another directory than the session's process). Ghostty names no tty: its proof is the focused terminal of its front window being the surface recorded when the session started, still in the session's directory (`window_evidence: "recorded_surface"`); with no recorded surface -- or a recorded one Ghostty no longer lists -- it refuses `focused_tab_unproven`, however few terminals share the directory, since an agent that moves itself into a worktree leaves a plain shell there looking like its own. With `only_if_frontmost: false` the session's own tab (by tty), tmux pane or Ghostty terminal is raised first (`answer_surfaces.raise_for_answer`), then the app. | the sentence plus the reason |
| `accessibility_required` | `AXIsProcessTrusted()` is false, so a posted key would silently go nowhere | `JR-Bar cannot answer this ask until macOS lets it send the keystroke. Turn on System Settings > Privacy & Security > Accessibility > <row>.` The row is the daemon's own bundle name -- `jrbar-core` on an installed deployment, since the helper is a separate TCC client from JR-Bar.app. |
| `send_failed` | macOS refused to build or deliver the event | the failure's name |
| `busy` | the answer worker did not finish inside `ANSWER_REPLY_BUDGET_SECONDS` (6 s) | `answering did not finish in time` |

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
request; a standalone `jrbar serve --allow-answers` reaches the daemon over
`core.sock` and reads the same switch. Its answer waits up to 12 s for the
reply -- past `answer_ask`'s own 6 s budget and the hops to the main
thread -- so a slow focus check is never reported as an unreachable monitor
while the answer is still delivered.

- `GET /asks.json` → `{ok: true, asks: [{session, provider, label, slot,
  kind, request, opened_at, preview, risk, decisions, choices}]}`: what is
  waiting, the deck `slot` (1-13, the current bank's key; null when none)
  showing it, one bounded line of what it wants, and the `decisions` an
  answer may carry -- `approve`/`deny` only while the ask is `answerable`,
  `always` only when the agent offered a rule to remember, `answer` only
  for a held question (`choices`); once the decide lane has `decided`, the
  hold is spent and neither `always` nor `answer` (nor its `choices`) is
  offered.
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
Optional; protocol 1 always sends everything. Reserved.

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
has read stdin is capped at 250 ms. Measured on this Mac (2026-09-09, 100 invocations from a
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
generation) and a fresh one starts. Every append and rotation holds an
`flock` on the file its path still names, and the daemon takes that lock on
a file it has renamed to drain, so no line lands in a file after it was
rotated or read. The daemon drains those files once
before it opens the ingress socket, so a startup backlog lands ahead of any
live hook, every 30 s after that, and 0.3 s after a queue that refused a
payload is empty again, registering each payload's agent
process from `ppid`/`ppid_start` (for a node-hosted CLI such as pi or
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
On this Mac the installed copy is `~/.local/share/jrbar/bin/jrbar-hook`
(`scripts/install-agents.sh` copies it there, sets `JRBAR_HOOK_EXEC` in the
daemon's LaunchAgent, and runs `jrbar agent-monitor install all` so every
provider with a config on this Mac -- claude, codex, devin, grok, cursor,
hermes, openclaw, opencode, antigravity, kiro, pi, gemini -- runs it; an
installed package also finds that copy on its own). The OpenClaw handler,
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
until Settings › Agents reinstalls the hooks.

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
`JRBAR_COMMIT` from the bundle's `JRBarCommit`), re-points every provider's
hook at `Contents/Helpers/jrbar-hook` on the first launch of a build, and
registers itself as a login item. launchd is not involved: no LaunchAgents,
no `~/.local/share/jrbar` venv. The daemon's `doctor` reply carries the
`commit` it was built from (`-dirty` = uncommitted changes) and a `memory`
field (`rss_mb`, `peak_rss_mb`; with `JRBAR_TRACEMALLOC` also `traced_mb`
and the top files). The frozen daemon sits around 160–200 MB RSS, of which
roughly 100 MB is shared framework text (`footprint <pid>` shows the
private ~110 MB).

Stop, reinstall, start:

```sh
osascript -e 'tell application "JR-Bar" to quit'   # the app stops its child (SIGTERM, 3 s grace)
installer -pkg dist/JR-Bar-0.8.0.pkg -target CurrentUserHomeDirectory
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
needs the packaged app quit first: one process owns the event socket.

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
| `dot_extend_style` | `"continue"` \| `"mirror"` | `"continue"` | Let light run off the end of the strip into the Dot (travelling light only; anything else mirrors), or fold the strip into two bands. |
| `dot_extend_side` | `"after_last"` \| `"before_first"` | `"after_last"` | Continue only: which end of the strip the Dot carries on from. The Dot's own `devices[].led_direction` (default `forward`) flips its two LEDs. |
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
| `devices.N.blend_mode` | `color_blend` \| `round_robin` \| `spatial_split` \| `relay` \| `cycle` \| `classic`, or null | null | A per-device blend, so eight discrete LEDs can take per-agent blocks while the band stays smooth. Null (or an unknown word) follows the global `colors.blend_mode`. |
| `call_quiet_mode` | `off` \| `sounds` \| a quiet-mode word | `sounds` | What a call does (`presence`). |
| `meeting_quiet_mode` | `off` \| `sounds` \| a quiet-mode word | `off` | What a calendar meeting does. |
| `away_quiet_mode` | `off` \| `sounds` \| a quiet-mode word | `off` | What an empty desk does (a locked screen or five idle minutes, as the app reports them): `asks_only` keeps the Dot beacon and every ask lit while the rest goes quiet, `dark` turns the desk off like Lolgato. The report expires after 180 s, so the quiet cannot outlive the evidence. |
| `escalation_tier_by_provider` | object: provider id → `light`/`menu_bar`/`chime`/`takeover` | `{}` | A ceiling per provider under `escalation_tier`, judged on the oldest open ask's provider: Claude's asks may climb to the chime while another provider's never go past the light. It only ever lowers the stage (the global tier arms the finale). |

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
