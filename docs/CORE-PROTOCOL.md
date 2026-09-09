# JR-Bar core protocol (draft, protocol 1)

The native app (`JR-Bar.app`, Swift) owns every pixel. The core daemon
(`jrbar-core`, Python, bundled inside the app) owns every fact: provider
hooks, session truth, usage and quota, device writers, escalation, power
holds, remote peers, cloud ingest. They talk over one Unix socket.

This document is the contract. Both sides are tested against it.

## Transport

- Socket: `$XDG_STATE_HOME/jrbar/core.sock` (default
  `~/.local/state/jrbar/core.sock`), mode 0600, peer UID checked.
- Framing: newline-delimited JSON (one object per line, UTF-8, no
  embedded newlines). Max frame 1 MiB.
- Lifecycle: the app launches the daemon as a child process (also
  reachable standalone for the CLI and tests). On connect the daemon sends
  `hello`, then a full `state`, then a full `lights`. After that it pushes
  deltas as they happen. If the socket drops, the app restarts the daemon
  and reconnects with backoff (0.5 s, 1 s, 2 s, cap 5 s).
- Every message has `"t"` (type) and `"v": 1`.

## Daemon → app

### hello
```json
{"t":"hello","v":1,"core_version":"0.8.0","pid":123,
 "capabilities":["sessions","lights","usage","devices","power","effects","calibration","history","peers","ingest"]}
```

### state (full)
Sent on connect, and whenever anything below changes, coalesced to at most
20 per second. The app replaces its model wholesale; there is no partial
state message in protocol 1.

```json
{"t":"state","v":1,"generation":4812,"now":1788982892.4,
 "aggregate":{"mode":"working","needs_you":0,"active":2,"ready":1},
 "sessions":[
   {"id":"claude:session:fca1eb06-…","provider":"claude","kind":"main",
    "parent":null,"label":"jr-bar-b7","cwd":"/Users/j/Downloads/JR-Bar",
    "mode":"tool_running","lifecycle":"active","next_actor":"provider",
    "since":1788978889.9,"updated_at":1788982891.0,"stale":false,
    "pid":9170,"origin":{"kind":"claude_desktop","label":"Claude Desktop","bundle_id":"com.anthropic.claudefordesktop"},
    "ask":null,"terminal":{"app":"Ghostty","bundle_id":"com.mitchellh.ghostty","tty":"/dev/ttys004"},
    "workers":2}
 ],
 "asks":[{"session":"codex:session:…","kind":"permission","opened_at":…,"summary":"Run: rm -rf build"}],
 "devices":[{"id":"sidepulse:pro:B293…","kind":"pro","name":"SidePulse","path":"/Volumes/SidePulse","leds":8,"connected":true,"brightness":79,"linked":true,"last_write":…,"error":null},
            {"id":"sidepulse:dot:…","kind":"dot","leds":2,"connected":true},
            {"id":"screen-bar","kind":"screen_bar","leds":8,"enabled":true}],
 "usage":{"refreshed_at":…,"providers":[{"id":"claude","windows":[{"name":"5h","used_pct":42.0,"resets_at":…},{"name":"7d","used_pct":61.0,"resets_at":…}],"fidelity":"official","state":"ok","forecast":{"exhausts_at":…,"pace":"ahead"}}]},
 "power":{"keep_awake":true,"closed_lid":{"policy":"agents","holding":false,"helper_installed":true}},
 "focus":{"mode":"dim","source":"schedule","until":…},
 "escalation":{"stage":"none","since":null},
 "health":{"hooks":{"claude":"ok","codex":"ok","pi":"missing"},"sources":{"codex":{"fresh":true}}},
 "settings_generation":17}
```

### lights
The presentation program for each surface, exactly the LEDS DSL text the
hardware receives, plus the anchor the app needs to phase-lock the Screen
Bar to the strip. Sent whenever a program changes.

```json
{"t":"lights","v":1,
 "surfaces":{
   "hardware":{"program":"#000000 160ms cosine\n0:#1D050A 420ms pulse 0ms; …\nrepeat","led_count":8,"anchor":1788982891.31,"motion":"pulse","static_fallback":"#1D050A","brightness":0.79,"why":"completed_unseen"},
   "screen_bar":{"program":"…","led_count":8,"anchor":1788982891.31,"motion":"pulse","static_fallback":"…","why":"completed_unseen"},
   "dot":{"program":"…","led_count":2,"anchor":…}
 },
 "linked":true}
```
`why` is the semantic the program expresses, for the "why is the light doing
that" explanation. When `linked` is true the hardware and screen bar carry
the same program and anchor; the Dot carries a 2-LED rendering of the
same semantic (or, in linked Pro+Dot mode, a phase-locked continuation).

### event
Transient things the app should react to once: chimes, banners, confetti.
```json
{"t":"event","v":1,"id":"…","kind":"completed","session":"…","label":"…","at":…,"sound":"glass","notify":true}
```
Kinds: `completed`, `ask_opened`, `ask_resolved`, `failed`, `quota_crossed`,
`quota_reset`, `device_connected`, `device_disconnected`, `escalation_stage`,
`peer_arrived`, `peer_departed`.

### settings
Full settings document, sent on connect and after every change (from any
writer). The app renders Settings from this and never keeps its own copy.
```json
{"t":"settings","v":1,"generation":17,"schema":3,"document":{…}}
```

### reply
Answer to a command.
```json
{"t":"reply","v":1,"id":"c-42","ok":true,"result":{…}}
{"t":"reply","v":1,"id":"c-43","ok":false,"error":{"code":"not_found","message":"no such session"}}
```

### log
Content-free diagnostics for the app's log view. Bounded.

## App → daemon

### command
```json
{"t":"command","v":1,"id":"c-42","name":"open_session","args":{"session":"claude:session:…"}}
```

Protocol 1 commands:

| name | args | effect |
| --- | --- | --- |
| `open_session` | session | Raise the terminal/app that hosts the session (daemon knows tty and bundle id). Returns what it activated. |
| `answer_ask` | session, decision (`approve`/`deny`), only_if_frontmost | Type the answer into the hosting terminal only when the daemon confirms the surface is frontmost and the ask is still live. |
| `snooze` | session or `all`, seconds | Silence escalation for that scope. |
| `clear_completed` | sessions[] or `all` | Acknowledge completions (undoable within 300 s via `undo_clear`). |
| `undo_clear` | batch | |
| `set_setting` | path, value | Validated write; replies with the new generation. |
| `set_brightness` | device or `all`, value 0..1 | |
| `set_device_display` | device, mode | |
| `apply_calibration` | device, profile | |
| `preview_program` | surface, program, seconds | Show a program on a surface for N seconds then revert. |
| `apply_effect` | effect, scope, target | Effect Studio assignment. |
| `refresh_usage` | providers[] | |
| `install_hooks` / `uninstall_hooks` | providers[] | |
| `set_closed_lid_policy` | policy | |
| `quiet` | mode, seconds | DND override. |
| `list_history` | since, limit | Activity history rows. |
| `doctor` | | Content-free diagnostics document. |
| `quit` | | Daemon exits after releasing holds. |

### subscribe
Optional; protocol 1 always sends everything. Reserved.

## Hook shim

`jrbar-hook` is a tiny compiled binary bundled with the app. Provider
configs invoke it as `jrbar-hook --provider codex`. It reads stdin (max 1
MiB), connects to `$XDG_STATE_HOME/jrbar/hook.sock`, and sends one frame:

```
JRBARHOOK\x01 + json({"provider":"codex","payload":<stdin text>,"ppid":<getppid()>,"ppid_start":<proc start epoch>})
```

then exits 0 in under 5 ms. The daemon does everything else (normalize,
persist, dedupe, process registry). If the socket is absent the shim
appends the raw line to `$XDG_STATE_HOME/jrbar/agent-monitor/<provider>.pending.jsonl`
so nothing is lost while the daemon is down; the daemon drains that file
on start. For Cursor the shim prints `{}` on stdout as the protocol
requires.

## Versioning

`v` is bumped only for incompatible changes. Additive fields are always
allowed; the app ignores unknown keys, the daemon ignores unknown command
args.
