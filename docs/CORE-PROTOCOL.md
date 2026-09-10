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
regenerates it).

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
  If the socket drops, the app restarts the daemon and reconnects with
  backoff (0.5 s, 1 s, 2 s, 4 s, cap 5 s).
- Every message has `"t"` (type) and `"v": 1`.
- Coalescing: `state` at most 20/s, `lights` 30/s, `settings` 10/s, latest
  wins. `event`, `reply` and `log` are never coalesced or dropped.

## Daemon → app

### hello
```json
{"t":"hello","v":1,"core_version":"0.8.0","pid":123,
 "capabilities":["sessions","lights","usage","devices","power","effects","calibration","history","peers","ingest","deck"]}
```

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
    "ask":null,"terminal":{"app":"Ghostty","bundle_id":"com.mitchellh.ghostty","tty":"/dev/ttys004"},
    "workers":1,"event":"PreToolUse","tool":"Bash","message":null}
 ],
 "asks":[{"session":"codex:session:…","kind":"permission","opened_at":1788982800.0,"summary":"Run: rm -rf build"}],
 "devices":[{"id":"sidepulse:pro:B293A1","kind":"pro","name":"SidePulse","path":"/Volumes/SidePulse","leds":8,"connected":true,"brightness":79,"linked":true,"last_write":1788982891.31,"error":null},
            {"id":"sidepulse:dot:7F02C4","kind":"dot","leds":2,"connected":false,"error":"volume unmounted"},
            {"id":"screen-bar","kind":"screen_bar","name":"Screen Bar","leds":8,"enabled":true,"brightness":100,"linked":true,"error":null}],
 "usage":{"refreshed_at":…,"next_refresh_at":…,"refreshing":false,
          "providers":[{"id":"claude","instance":"default","account":{"plan":null,"label":"Max","fidelity":"official"},
                        "windows":[{"name":"5h","id":"five_hour","used_pct":42.0,"resets_at":…,"scope":"account","model":null},
                                   {"name":"7d","id":"seven_day","used_pct":61.0,"resets_at":…}],
                        "fidelity":"official","state":"ready","reason":null,"action":null,"observed_at":…,
                        "tokens":{"input":1200,"cached_input":800,"output":300},"estimated_cost_usd":null,"credits_remaining":null,
                        "forecast":null}]},
 "power":{"keep_awake":true,"closed_lid":{"policy":"agents","holding":false,"helper_installed":true}},
 "focus":{"mode":"dim","source":"schedule","until":…,"display":"all","brightness_factor":0.15,"banner_allowed":true,"audible_allowed":false,"summary":"Dim until 07:00"},
 "escalation":{"stage":"menu_bar","since":1788982800.0},
 "health":{"hooks":{"claude":"ok","codex":"stale","pi":"missing"},
           "sources":{"claude":{"fresh":true,"heard_age_seconds":1.4}},
           "intake":{"hook_state":"configured","source_health":"partial","silence_seconds":1.4}},
 "peers":[],
 "unseen_completions":["gemini:session:…"],
 "settings_generation":17,
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
  `lifecycle` reduces it: `active`, `completed`, `failed`, `ended`,
  `stale`. `next_actor` comes from canonical operator state (`user`,
  `provider`) with a mode-based fallback.
- `ask.kind` is the canonical request kind (`permission`, `input`,
  `approval`, `review`) with a fallback from the hook event; `summary` is
  the hook's message or tool name; `opened_at` the request's opening epoch.
- `pid` is the process registry's live pid for that session (absent when
  the process ended). `origin` is the hook's origin annotation plus the
  bundle id when the kind names an app or IDE; `terminal` is found by
  walking the pid's ancestry for a known terminal or IDE, plus `ps`'s tty.
- `aggregate.mode`: `needs_you` > `failed` > `working` > `done` > `idle`.
  `ready` counts unseen main-session completions (the same set the menu
  badge used); `unseen_completions` lists them.
- Device ids are the Python device ids; the Screen Bar row is `screen-bar`
  with `enabled` (the Python `virtual_status_device_enabled` setting).
  Hardware `brightness` is the effective percent after idle/DND dimming.
- `usage.providers[].windows[].name` is the short form the panel shows:
  `5h`, `7d`, `Daily`, `Weekly`, `Monthly`, `Credits` (a model-scoped lane
  such as Claude's Fable window is `7d Fable`; a lane with no short form
  keeps its label); `id` is the lane id (`five-hour`, `weekly`,
  `fable-only`, …). `used_pct` is `100 - remaining_percent` from the
  provider usage lanes; `resets_at` is the lane's reset epoch whenever the
  lane knows it; `fidelity` is `stale` when the source is stale, else
  `official`; `state` is the `ProviderSourceState` value. `forecast` is
  not produced yet.
- `focus` reflects the DND projection: `mode` is the active DND mode
  (`mute`, `dim`, `pause`, `asks_only`, `dark`) or `normal`, `source` is
  `manual`, `schedule`, `focus` or `default`, `until` the next transition.
- `escalation.stage`: `none`, `ramp`, `menu_bar`, `final` (0…3);
  `since` is when the oldest unanswered ask started blocking.
- `health.hooks[provider]`: `ok` (installed and delivering), `stale`
  (installed, running, nothing arriving), `missing` (not installed).

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
 "banks":{"index":0,"count":1},
 "rail":{"edge":"left"},
 "keymap":{"state":"applied","backup_at":1788896492.4,"generation":3,
           "layers":[{"profile":0,"layer":0,"label":"Profile 1 / Layer 1: Base"}]},
 "input_check":false,
 "last_input":{"index":1,"kind":"press","at":1788982888.4},
 "settings":{"enabled":true,"session_mode":true,"analog_enabled":false}}
```

- `device` is `null` when no pad is known (nothing approved, nothing
  enumerated). `serial` is the approved serial (`integrations.json`), else
  the first pad the HID probe sees; `transport` is `usb` or `bluetooth`
  from the probe (USB preferred when both); `connected` when the probe
  lists it or the output service holds it; `approved` when
  `creator_micro_enabled` names this serial; `profile` / `layer` are the
  device's active position from the last inspection (0-based, as the
  keymap indexes them; the firmware reports the layer 1-based); `firmware`
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
  writes (`creator_micro_lighting`: ask `#FF3A00`, working `#00E5FF`, done
  `#00FF66`, dark `#020204`) or `#000000` while the pad is not driven (no
  output service ready, or session mode off).
- `aux[]` are AG13..AG19 (one encoder, three inputs; four joystick
  sectors) with the explicit `deck-controls.json` mapping kind bound to
  each (`next_bank`, `open_usage`, …) or null; labels come from the
  inspected keymap when there is one.
- `keymap.state`: `stock` (no private backup, or the recovery journal
  says the original is back), `applied` (a verified JR-Bar write),
  `recovering` (an interrupted transfer: Restore is the way forward),
  `unknown` (files that do not parse); `backup_at` is the backup file's
  mtime; `generation` counts setup results since the daemon started;
  `layers` lists the editable profile/layer pairs of the inspected (or
  backed-up) keymap.
- `input_check`: inputs are shown as `deck_input` events and every
  bound action is paused (also turned on by a verified keymap write, as
  the Python app did). `last_input` is the last observed control
  (`kind`: `press` for a key, `dial` for AG13..15, `joystick` for
  AG16..19, `analog` for the calibrated sectors 20..23).
- `settings` mirrors `deck-controls.json` (`enabled`, `session_mode`,
  `analog_enabled`; the Python defaults are all off).

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
 "linked":true,"devices_linked":true,"linked_skew_ms":11.0}
```

- `hardware` is the first connected 8-LED strip (a second one is
  `hardware:<device id>`), `dot` the connected 2-LED device, `screen_bar`
  the program the Python Screen Bar would draw (calibration and resting
  glow applied). With the Screen Bar setting off and a strip present, the
  `screen_bar` surface mirrors `hardware`.
- `anchor` is epoch seconds: the strip's write-completion moment for
  hardware, the presentation's playback anchor for the Screen Bar; when
  `linked` (the `link_screen_bar_to_hardware` setting) and a strip is
  connected the Screen Bar carries the strip's anchor, because the strip
  loops from its write and never re-anchors on a Screen Bar re-sync
  (`core_runtime.screen_bar_anchor`).
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
  failure; null otherwise), how long it has been in that state (the ask's
  age, else the session's `since`, else the glance's relay epoch), the
  product of the dimming factors that applied to the device's brightness,
  and the dimming words in the order applied: `idle_dim`, `quiet` (DND),
  `sleep` (display asleep), `auto_dim` (the `auto_dim` setting below).
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
  when both a Pro and a Dot are connected: their programs were written
  back to back in one hardware worker command from the same presentation,
  relay epoch and anchor, so the `dot` surface carries the strip's anchor
  and the two loop as one unit. `linked_skew_ms` is the last measured
  gap between the Pro's and the Dot's write completion (11 ms on this Mac).

### event
Transient things the app should react to once. The daemon states the fact
and leaves sounds and banners to the app's `EventPolicy` (it never posts a
macOS notification or plays a sound itself in headless mode), so `notify`
and `sound` are usually absent; `sound: "glass"` marks the chime edge of
`escalation_stage` 3.
```json
{"t":"event","v":1,"id":"ev-12","kind":"completed","session":"…","provider":"claude","label":"jr-bar-b7","detail":null,"at":…}
{"t":"event","v":1,"id":"ev-13","kind":"escalation_stage","session":"…","label":"sidepulse-core","stage":3,"sound":"glass","at":…}
```
Kinds emitted today: `completed`, `failed`, `quota_crossed` (from the
activity ledger), `ask_opened`, `ask_resolved` (from the ask set changing
between refreshes; `detail` carries the summary), `escalation_stage`
(`stage` 0…3), `device_connected`, `device_disconnected` (`label` is the
device name, `detail` its id; keyed by name, so a device whose id moves
from its mount path to its firmware serial is not a disconnect/connect
pair), `deck_input` (`input: {index, kind, at}`, nested because the
envelope's `kind` is the event kind; `label` is the control's name; one
per observed control, whether or not input check is on) and
`deck_receipt` (`code`, `message`: every keymap setup result and every
change of the output service's reason, `ready`, `reconnecting`,
`device_conflict`, …, with the Python app's sentence; the same receipt
sits on `state.deck.device.receipt`). Reserved, not emitted yet:
`quota_reset`, `peer_arrived`, `peer_departed`.

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
```json
{"t":"settings","v":1,"generation":17,"schema":3,"document":{…}}
```

### reply
Answer to a command.
```json
{"t":"reply","v":1,"id":"c-42","ok":true,"result":{…}}
{"t":"reply","v":1,"id":"c-43","ok":false,"error":{"code":"not_found","message":"no such session"}}
```
Error codes: `unknown_command`, `bad_frame`, `bad_command`, `internal`,
`not_found`, `not_frontmost`, `invalid_args`, `invalid_path`,
`invalid_value`, `refused`, `expired`, `busy`, `unsupported`; the Effect
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
(`performSelectorOnMainThread`), one at a time, in order per client;
`install_hooks` / `uninstall_hooks` run on the socket thread because the
Codex trust handshake can take seconds. Unknown args are ignored.

| name | args | effect / result |
| --- | --- | --- |
| `open_session` | session, action? | The controller's `open_session` (terminal launch or provider URL, honouring the session-open preference). `{session, activated, origin}`. |
| `answer_ask` | session, decision (`approve`/`deny`), only_if_frontmost (default true) | The Agent Browser's answer path (`AnswerController.perform_browser_answer`) for the session's live request. With `only_if_frontmost`, refused with `not_frontmost` unless the frontmost app is the session's terminal or origin app (or, when neither is known, any known terminal). `unsupported` when the provider has no answer handler. |
| `snooze` | session or `all`, seconds | Mailbox snooze for the session's family (presets: ≤ 900 s → 15 minutes, ≤ 3600 s → 1 hour, else tomorrow morning; 0 unsnoozes). `{sessions, until}`. |
| `clear_completed` | sessions[] or `all` | Clear Agents commit for every clearable completion (a list is accepted but the batch is always the full preview in protocol 1). `{batch, cleared}`. |
| `undo_clear` | batch | Undo that batch within its 300 s window; `expired` after. |
| `set_setting` | path, value | Dot-path write (`colors.agent_colors.claude`, `devices.0.brightness`) into `to_dict()`, re-validated through the real settings loader, saved, side effects applied (closed-lid, cloud ingest, transcript monitoring, remote peers), then a refresh. `{generation, path, value}` with the value as normalised. |
| `reset_settings` | paths[] | Each path back to `AgentMonitorSettings()`'s default. `{generation, reset}`. |
| `set_brightness` | device or `all`, value 0..1 | `set_device_brightness` (turns auto-brightness off, as the slider does). |
| `set_device_display` | device, mode | `agent`, `battery`, `studio`, `quota_runway`. |
| `apply_calibration` | device, profile {red_gain, green_gain, blue_gain, resting_glow} | Per-channel gains and resting glow for that device. |
| `preview_program` | surface (`screen_bar`, `hardware`, `dot` or a device id), program, seconds (0.2…30) | Writes the program to the matching strip(s) now and marks the surface `why: preview` in `lights`; after `seconds` the daemon refreshes and the live program returns. |
| `apply_effect` | effect, scope, target | Effect Studio assignment (`EffectAssignmentRecord.create`); `effect` null removes the assignment. Returns the assignment list. |
| `refresh_usage` | providers[] | Forces a provider usage refresh; the next `state` carries the result. |
| `install_hooks` / `uninstall_hooks` | providers[] | `install.py` per provider (with the compiled shim when available and the Codex trust hash recomputed). `{providers, results{provider: {ok, changed, config_path, codex_trust, warning}}}`. |
| `set_closed_lid_policy` | policy | `never`, `agents`, `always`. |
| `quiet` | mode (`dnd`/`pause`, `dim`, `mute`, `dark`, `asks_only`), seconds | A DND override for that long (0 ends the override). `{until, mode}`. |
| `list_history` | since, limit | Activity ledger rows `{at, kind, provider, session, label, detail, duration, unseen}`; kinds `completed`, `asked`, `failed`, `quota_crossed`. `unseen` is newer than the last visit; the daemon marks everything seen when the last client disconnects, so what happens while the app is away stays flagged until it looks again. `{rows, total, last_seen}`. |
| `doctor` | | `{ok, core_version, commit, python, pid, socket, uptime_seconds, clients, hooks, devices, settings_generation, state_generation, commands, checks[{name, ok, detail}]}` from `doctor.py` plus the hook shim and pending-file checks. `commit` is `JRBAR_COMMIT` from an installed deployment (`scripts/install-agents.sh`), else the checkout's HEAD; `alcove_follow_state` never fails the daemon (Alcove following is the app's). |
| `usage_history` | provider, range (`7d`, `30d`, `90d`, `365d`) | Daily and hourly token/cost rows for one provider from the local transcript scan (`usage_stats.scan_usage`, the same one the Python Usage window ran): `{provider, range, days[{date, tokens_in, tokens_out, cache_read, cost_usd}], hours[{hour, at, …}] (last 7×24), pricing{input_per_mtok, output_per_mtok, cache_read_per_mtok, as_of, approximate, currency, model} or null, account, state, records}`. `tokens_in` counts input plus cache writes; `pricing` is the dominant model's list price. Claude and Codex have transcripts; any other provider answers empty rows. Runs on the socket thread; a cold scan over a month of transcripts takes tens of seconds, a warm one about a second. |
| `list_effects` | | `{effects[], packs[], cadences[], generation}`: every effect in the runtime registry (builtins, the provider animations and installed packs) with typed `parameters[]`, a `preview {program, led_count}` rendered at the defaults, the blink `cadence` when one applies; `packs[]` is `{id, name, version, effects[ids], license?, path?}` from the pack store; `cadences[]` the three safe blink cadences. `generation` is the assignment cache's. |
| `render_effect` | effect_id, parameters, led_count, color? | `{effect_id, program, led_count, parameters, cadence}`: the LEDS program the daemon would play for those parameters (unknown parameters dropped, bounds enforced), through the presentation safety compiler. Builtins use their registered shapes, provider animations the live solo renderer (`duration_seconds` sets the cycle), pack effects their `motion`/`color`/`cadence` data or a primitive for their meaning. |
| `list_assignments` | | `{assignments[{effect_id, scope, target_id, parameters}], active_scene, generation}` from the effect assignment store; `parameters` come from the daemon's sidecar (`effect-assignment-parameters.json`). |
| `set_assignment` | effect_id, scope, target_id?, parameters? | Validates through `effect_studio.plan_assignment` (global takes no target, `asking`/`failure` keep `alert`, scenes and semantic families are checked), saves the assignment document and the parameters sidecar, refreshes. Replies the assignment document plus `assignment`. |
| `clear_assignment` | scope, target_id? | Removes that assignment; the document plus `removed`. |
| `import_effect_pack` | path | `EffectPackStore.install` of a data-only JSON v2 pack (`invalid_pack` on anything the validator refuses, `conflict` when that pack id is installed), the registry rebuilt with every installed pack; replies the catalog plus `imported {id, name, effects}`. |
| `export_effect_pack` | ids[], path, name? | Writes a data-only JSON v2 pack of those effects (pack effects keep their data, builtins become their motion plus parameter defaults, fallbacks kept only when exported too) through `write_private_export`; `{path, effects, bytes, id}`. |
| `open_legacy_window` | name | Migration bridge: opens a Python window on demand even in headless mode (`settings`, `setup`, `agent_browser`, `effect_studio`, `usage_center`, `control_center`, `why`). |
| `deck_press` | index 0…23 | What a press of that control does, from the screen (the physical key runs the same rule through `DeckInputDispatch`). An explicit `deck-controls.json` mapping wins (`{index, action: <kind>, receipt}`; `next_bank` / `previous_bank` add `bank`; a failed app shortcut is `refused` with the deck controller's sentence). Else a session key: when that session has a live ask and the frontmost app is its terminal or origin app, the press answers it through the `answer_ask` path (`{action: "answer_ask", decision: "approve", answered: true}`); otherwise it reveals the session through the board's navigation resolver (`{action: "reveal_session", receipt, activated}`). `not_found` with "No session assigned." / "Reserved: session not observed." / "Configure this auxiliary control in Settings > Devices."; `input_check` while input check is on. |
| `deck_pin` | index 0…12 | Toggles the pin on the identity at that key (pins are per identity and survive Clear absent). `{index, identity, pinned}`; `not_found` for an unassigned key. |
| `deck_bank` | delta | Steps the bank, wrapping. `{index, count}`. |
| `deck_rail` | edge (`off`, `left`, `right`, `top`, `bottom`) | The compact rail's edge, persisted with the board. `{edge}`. |
| `deck_clear_absent` | | Unpinned identities with no observed session leave the board; later keys move up. `{removed, banks}`. |
| `deck_plan_keymap` | profile, layer, include_auxiliary | `creator_micro_keymap.plan_keymap` for that layer over the inspected keymap: `{profile, layer, include_auxiliary, changes[], preview, controls[{index, label}]}`, `preview` being the Python review alert's text. The first call (and any call after 120 s, or after a write) inspects the device: the output service is stopped, the keymap read, the pad handed back. `invalid_plan` with the ValueError message; otherwise the receipt code (`connection_required` when the pad is not approved, `busy` while another setup runs). Socket thread. |
| `deck_apply_keymap` | profile, layer, include_auxiliary | `CreatorMicroSetup.apply` of that plan (private backup first, verified write, readback): `{code: keymap_verified\|already_configured, message, changes, state, backup_at, generation}`; input check turns on after a verified write. Refusals are error replies whose code is the receipt (`keymap_changed`, `recovery_required`, `readback_mismatch`, …). No alert is shown; the confirmation is the app's. |
| `deck_restore_keymap` | | `CreatorMicroSetup.restore` from the first private backup: `{code: keymap_restored\|already_restored, message, state, backup_at, generation}`, same refusals (`backup_invalid` with no backup, `keymap_changed` for later device edits). |
| `deck_approve_device` | | The Devices pane's Enable: the sole stable serial the HID probe sees becomes `creator_micro_device_serial` with `creator_micro_enabled`, and the output service is reconfigured. `{serial, approved}`; `no_device` ("No Creator Micro 2 is connected."), `ambiguous_device_identity`, `device_identity_unavailable`. |
| `deck_check_input` | enabled | Input check on or off (queued input is revoked). `{enabled}`. |
| `deck_set_settings` | enabled?, session_mode?, analog_enabled? | Writes `deck-controls.json` (bindings untouched), reconfigures the deck runtime. The three settings; `invalid_args` for anything but bools. |
| `ping` | | `{pong, now}`. |
| `quit` | | Replies, then the daemon releases its holds and exits. |

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

It waits up to 200 ms for the disposition and exits 0; the whole run is
capped at 250 ms. Measured on this Mac (2026-09-09, 100 invocations from a
shell loop): 6.2 ms wall per invocation of which 3.3 ms is the bare
fork/exec (`/usr/bin/true` in the same loop), so the shim's own work is
about 3 ms; from Python's `subprocess.run` the median is 5.7 ms; the
Python hook client took 88 ms. If the socket is absent the shim appends
`{"provider","ppid","ppid_start","payload"}` as one JSON line to
`$XDG_STATE_HOME/jrbar/<provider>.pending.jsonl` (mode 0600) and exits 0;
the daemon drains those files at start and every 30 s, registering each
payload's agent process from `ppid`/`ppid_start` (for a node-hosted CLI
such as pi or Gemini the nearest `node` ancestor is the agent process).
For Cursor and Gemini CLI the shim prints `{}` on stdout as those hook
contracts require (`--emit-empty-json` forces it for any provider);
otherwise it prints nothing.

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
answer, and any queued payloads.

### Pi and Gemini CLI

Pi (`@mariozechner/pi-coding-agent`) runs TypeScript extensions in-process
under Node. `jrbar agent-monitor install pi` writes
`~/.pi/agent/extensions/jrbar.ts` (marker `jrbar-pi-extension-v1`; an
unmanaged file is never overwritten), which spawns the shim argv baked at
install time (`HOOK_COMMAND`; the Python client as `FALLBACK_COMMAND`)
with a Claude-shaped payload `{hook_event_name, session_id, cwd,
transcript_path, tool_name?, source: "pi"}` on stdin, never awaiting it:
`session_start`→SessionStart, `turn_start`→UserPromptSubmit,
`tool_execution_start`→PreToolUse, `tool_execution_end`→PostToolUse,
`agent_end`→Stop, `session_shutdown`→SessionEnd, and
`ui_prompt_start`/`ui_prompt_end`→PermissionRequest/PostToolUse on a pi
that emits them (0.73.1 does not, so pi has no ask lane yet).
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
jrbar status-bar start                  # the old Python UI; refuses to run beside the daemon
```

Under the Swift app in development: `JRBAR_CORE_EXEC=scripts/run-core.sh`
makes the app spawn and supervise the daemon (`CoreSupervisor`; the script
execs `.venv/bin/python -m jrbar core`, passing `JRBAR_CORE_SOCKET` through
as `--socket`).

On this Mac the running pair comes from `scripts/install-agents.sh`, which
installs the package (non-editable) into `~/.local/share/jrbar/venv`, the
shim into `~/.local/share/jrbar/bin`, the app bundle into `~/Applications`,
and loads two LaunchAgents, both `KeepAlive` + `RunAtLoad`:

| label | runs |
| --- | --- |
| `com.jonathanreed.jrbar.core` | `~/.local/share/jrbar/venv/bin/python -m jrbar core` (logs `~/.local/state/jrbar/core.{out,err}.log`) |
| `com.jonathanreed.jrbar.ui` | `~/Applications/JR-Bar.app/Contents/MacOS/JR-Bar` (logs `ui.{out,err}.log`) |

The daemon is its own agent rather than the app's `JRBAR_CORE_EXEC` child,
and nothing launchd runs lives under `~/Downloads`: a launchd job that
reads a checkout there (the app bundle, or python reading `pyvenv.cfg`)
blocks on a "would like to access files in your Downloads folder" TCC
prompt until someone answers it. launchd restarts the daemon within its
5 s throttle when it dies; the app reconnects on the protocol backoff. The
script also boots out and parks the old `com.jonathanreed.jrbar.app`
(Python status bar) plist in the state directory. Re-run it after every
commit that should be running; `doctor` reports the installed commit.

Revert to the Python UI:

```sh
launchctl bootout gui/$UID/com.jonathanreed.jrbar.ui
launchctl bootout gui/$UID/com.jonathanreed.jrbar.core
.venv/bin/python -m jrbar status-bar start
```

## Versioning

`v` is bumped only for incompatible changes. Additive fields are always
allowed; the app ignores unknown keys, the daemon ignores unknown command
args.
