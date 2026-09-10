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
 "capabilities":["sessions","lights","usage","devices","power","effects","calibration","history","peers","ingest"]}
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
    "parent":null,"label":"jr-bar-b7","cwd":"/Users/j/Downloads/JR-Bar",
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
 "settings_generation":17}
```

Vocabulary:

- `sessions[].id` is the existing agent id: `provider:session:<sid>` for a
  main session, `provider:agent:<id>` for a worker (`kind: "worker"`,
  `parent` = the main session's id). `label` is the display name with its
  short id stripped, the way the Python menu titled rows.
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
- `usage.providers[].windows[].used_pct` is `100 - remaining_percent` from
  the provider usage lanes; `fidelity` is `stale` when the source is
  stale, else `official`; `state` is the `ProviderSourceState` value.
  `forecast` is not produced yet.
- `focus` reflects the DND projection: `mode` is the active DND mode
  (`mute`, `dim`, `pause`, `asks_only`, `dark`) or `normal`, `source` is
  `manual`, `schedule`, `focus` or `default`, `until` the next transition.
- `escalation.stage`: `none`, `ramp`, `menu_bar`, `final` (0…3);
  `since` is when the oldest unanswered ask started blocking.
- `health.hooks[provider]`: `ok` (installed and delivering), `stale`
  (installed, running, nothing arriving), `missing` (not installed).

### lights
The presentation program for each surface, exactly the LEDS DSL text the
hardware receives, plus the anchor the app needs to phase-lock the Screen
Bar to the strip. Sent whenever a program changes on any surface (every
Screen Bar sync, every completed hardware write, every preview start and
end) and with every refresh.

```json
{"t":"lights","v":1,
 "surfaces":{
   "hardware":{"program":"#000000 160ms cosine\n0:#1D050A 420ms pulse 0ms; …\nrepeat","led_count":8,"anchor":1788982891.31,"brightness":0.79,"why":"needs_you"},
   "screen_bar":{"program":"…","led_count":8,"anchor":1788982891.31,"motion":"continuous","static_fallback":"…","brightness":1.0,"why":"needs_you","override":"dnd"},
   "dot":{"program":"…","led_count":2,"anchor":…,"why":"needs_you"}
 },
 "linked":true}
```

- `hardware` is the first connected 8-LED strip (a second one is
  `hardware:<device id>`), `dot` the connected 2-LED device, `screen_bar`
  the program the Python Screen Bar would draw (calibration and resting
  glow applied). With the Screen Bar setting off and a strip present, the
  `screen_bar` surface mirrors `hardware`.
- `anchor` is epoch seconds: the strip's write-completion moment for
  hardware, the presentation's playback anchor for the Screen Bar; when
  `linked` (the `link_screen_bar_to_hardware` setting) the Screen Bar
  takes the later of the two so both surfaces loop together.
- `motion` is `static`, `finite` or `continuous`; `static_fallback` is the
  reduced-motion program.
- `why` is the glance semantic the program expresses: `needs_you`,
  `completed_unseen`, `working`, `idle`, `failed`, `capacity`, or
  `preview` while a `preview_program` holds the surface; `override` names
  a glance override (a DND or idle dim) when one applies.

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
device name, `detail` its id). Reserved, not emitted yet: `quota_reset`,
`peer_arrived`, `peer_departed`.

### settings
Full settings document, sent on connect and after every change from any
writer: the controller's `settings` attribute is a property whose setter
bumps `generation` and republishes, so a save from a menu action, a DND
schedule tick, a device being remembered, or a command all reach the app.
`document` is `AgentMonitorSettings.to_dict()`; `schema` is 3 for this
shape. The app renders Settings from this and never keeps its own copy.
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
`invalid_value`, `refused`, `expired`, `busy`, `unsupported`.

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
| `doctor` | | `{ok, core_version, pid, socket, uptime_seconds, clients, hooks, devices, settings_generation, state_generation, commands, checks[{name, ok, detail}]}` from `doctor.py` plus the hook shim and pending-file checks. |
| `open_legacy_window` | name | Migration bridge: opens a Python window on demand even in headless mode (`settings`, `setup`, `agent_browser`, `effect_studio`, `usage_center`, `control_center`, `why`). |
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
capped at 250 ms. Measured on this Mac: ~5 ms wall per invocation including
the caller's fork/exec (the Python client took ~90 ms). If the socket is
absent the shim appends
`{"provider","ppid","ppid_start","payload"}` as one JSON line to
`$XDG_STATE_HOME/jrbar/<provider>.pending.jsonl` (mode 0600) and exits 0;
the daemon drains those files at start and every 30 s, registering each
payload's agent process from `ppid`/`ppid_start`. For Cursor the shim
prints `{}` on stdout as that hook contract requires; otherwise it prints
nothing.

`install.hook_command_arguments` registers the shim when `JRBAR_HOOK_EXEC`
names one (an empty value disables it), when a bundled copy sits beside a
frozen executable, or when a source checkout has built
`hook/build/jrbar-hook`; otherwise `python -m jrbar.hook_client` as before.
Both shapes are recognised as ours by every installer, uninstaller and
detector, and the Codex trust hash is computed locally for whichever is
written. `jrbar hooks doctor` shows, per provider, the command registered
today and the one an install would write, the shim path, whether the
ingress and core sockets answer, and any queued payloads.

## Running it

```sh
python -m jrbar core                    # headless daemon on ~/.local/state/jrbar/core.sock
python -m jrbar core --socket /tmp/x    # elsewhere (tests)
jrbar status-bar start                  # the old Python UI; refuses to run beside the daemon
```

Under the Swift app: `JRBAR_CORE_EXEC="/path/.venv/bin/python -m jrbar core"`
makes the app spawn and supervise the daemon (`CoreSupervisor`).

## Versioning

`v` is bumped only for incompatible changes. Additive fields are always
allowed; the app ignores unknown keys, the daemon ignores unknown command
args.
