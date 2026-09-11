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
 "hidden_count":3,
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
                        "forecast":{"window_id":"five_hour","remaining_pct":58.0,"exhausts_at":1789000292.4,"pace":"under","rate_pct_per_hour":12.0,"samples":13}}]},
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
  with a mode-based fallback.
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
  `approval`, `review`) with a fallback from the hook event; `summary` is
  the hook's message or tool name; `opened_at` the request's opening epoch.
- `pid` is the process registry's live pid for that session (absent when
  the process ended). `origin` is the hook's origin annotation plus the
  bundle id when the kind names an app or IDE; `terminal` is found by
  walking the pid's ancestry for a known terminal or IDE, plus `ps`'s tty.
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
  lane knows it; `fidelity` is `stale` when the source is stale, else
  `official`; `state` is the `ProviderSourceState` value.
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
  than a point), and needs 30 minutes of spread; until then `forecast`
  is null (the app extrapolates from its own samples) unless the window
  is already exhausted. Without a known reset a window heading for 100 %
  is `ahead`.
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
  writes (`creator_micro_lighting`: ask `#FF3A00`, error `#B00020`, working
  `#00E5FF`, done `#00FF66`, dark `#020204`) or `#000000` while the pad is
  not driven (no output service ready, or session mode off). `failure` and
  `quota_exhausted` take the error colour, `input_required` and
  `quota_warning` the ask one -- a key you can answer and a key you cannot
  are never the same colour.
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
 "linked":true,"devices_linked":true,"linked_skew_ms":11.0,"linked_skew_at":1788982891.31,
 "dot_link":{"state":"linked","role":"extend","error":null}}
```

- `hardware` is the first connected 8-LED strip (a second one is
  `hardware:<device id>`), `dot` the connected 2-LED device, `screen_bar`
  the program the Python Screen Bar would draw (calibration and resting
  glow applied). The `screen_bar` surface mirrors `hardware` only while
  the bar is linked (`link_screen_bar_to_hardware`) and a strip is
  connected; unlinked it publishes nothing unless a live bar program is
  playing.
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
  Pro's and the Dot's write completion (11 ms on this Mac), always paired
  with `linked_skew_at`, the epoch it was measured; both appear or
  neither does.
- `dot_link` (top level, always present) is the daemon's own word for the
  Pro + Dot link — the truth `devices_linked` can only guess at:
  `{state, role, error}`. `role` is the normalised `dot_role` (null when
  the link is off or there is no Dot); `error` is the failed linked
  write's exception class, null otherwise. `state` is one of:

  | state | meaning |
  | --- | --- |
  | `off` | `devices_linked` is off; the Dot always renders itself |
  | `no_dot` | linked on, no Dot connected |
  | `no_strip` | linked on, Dot connected, role `extend`, no strip to extend — the Dot renders itself until one mounts |
  | `beacon` | role `asks`: the beacon needs no strip |
  | `solo` | role `status`: the Dot drives itself by choice |
  | `linked` | role `extend` and the last coupled write landed cleanly |
  | `failed` | role `extend`, both devices connected, and the Dot's half of the last linked write raised (`error` names the class) |

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
sits on `state.deck.device.receipt`) and `usage_history_ready` (`provider`,
`range`, `records`, `scanned_at`; `label` is the provider, `detail` the
range: a `usage_history` reply that went out `pending` or `stale` now has
a fresh document behind it, ask again). Reserved, not emitted yet:
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
`invalid_value`, `read_only`, `refused`, `expired`, `busy`, `unsupported`;
`answer_ask` adds `accessibility_required`, `session_gone`, `stale_ask` and
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
(`performSelectorOnMainThread`), one at a time, in order per client;
`install_hooks` / `uninstall_hooks` run on the socket thread because the
Codex trust handshake can take seconds. Unknown args are ignored.

| name | args | effect / result |
| --- | --- | --- |
| `open_session` | session, action? | The controller's `open_session` (terminal launch or provider URL, honouring the session-open preference). `{session, activated, origin}`. |
| `answer_ask` | session, decision (`approve`/`deny`), only_if_frontmost (default true) | Answers the session's live request **in its own terminal**, by posting the key that provider's CLI takes at its permission prompt (`answer_local.py`, the `local.answer_in_place` surface the `answering` product capability binds to). Claude Code: `1` to approve ("1. Yes" is always the first row), `esc` to deny (the prompt's own "Esc to cancel"). Codex: `y` to approve ("1. Yes, proceed (y)"), `3` to deny ("3. No, and tell Codex what to do differently"). Only `codex/hooks` and `claude/hooks` declare the capability; any other provider is `unsupported`. The reply waits for the real outcome, so `answered: true` means the key went out: `{session, decision, answered, mechanism: "synthetic_keystroke", key, key_code, meaning, host{pid, tty, app, app_pid, window_evidence}}`. `window_evidence` is `focused_tab_tty` (Terminal.app / iTerm2 named the focused tab and it is this session's), `host_process_ancestry` (the frontmost application's process is the one the session descends from) or `frontmost_application_only`. See the refusals below. |
| `snooze` | session or `all`, seconds | Mailbox snooze for the session's family (presets: ≤ 900 s → 15 minutes, ≤ 3600 s → 1 hour, else tomorrow morning; 0 unsnoozes). `{sessions, until}`. |
| `clear_completed` | sessions[] or `all` | Acknowledges every row `sessions` is currently listing as over -- `completed`, `ended`, and any stale row -- through the Clear Agents plan/commit machinery with widened eligibility (`clearable_presentation_key`). Afterwards `sessions` holds only live rows and the rest are in `list_history`. `sessions` may name a subset; a named row that is not clearable (a live session) is simply not in the batch. Live sessions, asks, failures and worker rows are fenced as protected and never cleared. `{batch, cleared[]}` with every acknowledged session id, or `{batch: null, cleared: []}` when nothing was over. Refuses `busy` while a clear is in flight. |
| `undo_clear` | batch | Undo that batch within its 300 s window; the rows return to `sessions` exactly as they were. `{batch, restored[]}`; `expired` after, `not_found` for another batch. |
| `set_setting` | path, value | Dot-path write (`colors.agent_colors.claude`, `devices.0.brightness`) into `to_dict()`, re-validated through the real settings loader, saved, side effects applied (closed-lid, cloud ingest, transcript monitoring, remote peers), then a refresh. `{generation, path, value}` with the value as normalised. A read-only key (`cloud_ingest_token_path`) replies `read_only`. |
| `reset_settings` | paths[] | Each path back to `AgentMonitorSettings()`'s default. `{generation, reset}`. |
| `set_brightness` | device or `all`, value 0..1 | `set_device_brightness` (turns auto-brightness off, as the slider does). |
| `set_device_display` | device, mode | `agent`, `battery`, `studio`, `quota_runway`. |
| `apply_calibration` | device, profile {red_gain, green_gain, blue_gain, resting_glow, brightness?} | Per-channel gains (0.3…1.5), resting glow (0…0.35) and device brightness (0…255) for that device, clamped and persisted; the reply's `profile` echoes what actually persisted plus `generation`. Ends any held calibration preview for the device. `not_found` for an unknown device, `invalid_args` for a non-numeric field. |
| `preview_program` | surface (`screen_bar`, `hardware`, `dot` or a device id), program, seconds (0.2…30) | Writes the program to the matching strip(s) now and marks the surface `why: preview` in `lights`; after `seconds` the daemon refreshes and the live program returns. |
| `preview_calibration` | device, gains {red, green, blue} (0.3…1.5, clamped), resting_glow? (0…0.35), brightness? (0…255, default the device's stored brightness), patch? (`white`/`red`/`green`/`blue`/`grey` or `#RRGGBB`, default `white`), companion? (default false) | Shows the nominal patch through the GIVEN values -- resting glow, channel gains and brightness applied once through the device's own write boundary, never the stored profile on top. Held daemon-side for 600 s (re-armed on every call) so the sheet can sit open while the eye decides; live writes for the held device(s) are suppressed meanwhile. For `virtual:status-bar` the transform is the Screen Bar's code-domain one and the hold lands on the `screen_bar` surface. `companion: true` on a Dot also lights the followed strip with the same patch through the strip's STORED profile, so the Dot can be matched to it by eye; the reply's `companion` names that strip (or null). `{device, surface, until, program, companion}`; `not_found`/`invalid_args` on errors. |
| `end_calibration_preview` | device | Drops the held preview(s) that device owns -- its own and a companion strip's -- clears the dedupe identity the preview bytes left, and re-arms the live program. Idempotent: `{device, ended}`. |
| `apply_effect` | effect, scope, target | Effect Studio assignment (`EffectAssignmentRecord.create`); `effect` null removes the assignment. Returns the assignment list. |
| `refresh_usage` | providers[] | Forces a provider usage refresh; the next `state` carries the result. |
| `install_hooks` / `uninstall_hooks` | providers[] | `install.py` per provider (with the compiled shim when available and the Codex trust hash recomputed). `{providers, results{provider: {ok, changed, config_path, codex_trust, warning}}}`. |
| `set_closed_lid_policy` | policy | `never`, `agents`, `always`. |
| `quiet` | mode (`dnd`/`pause`, `dim`, `mute`, `dark`, `asks_only`), seconds | A DND override for that long (0 ends the override). `{until, mode}`. |
| `list_history` | since, limit | Everything `sessions` no longer lists. Activity ledger rows `{at, kind, provider, session, label, detail, duration, unseen}`; kinds `completed`, `asked`, `failed`, `quota_crossed`. `unseen` is newer than the last visit; the daemon marks everything seen when the last client disconnects, so what happens while the app is away stays flagged until it looks again. `{rows, total, last_seen}`. |
| `doctor` | | `{ok, core_version, commit, python, pid, socket, uptime_seconds, clients, hooks, devices, settings_generation, state_generation, commands, checks[{name, ok, detail}]}` from `doctor.py` plus the hook shim and pending-file checks. `commit` is `JRBAR_COMMIT` from an installed deployment (`scripts/install-agents.sh`), else the checkout's HEAD; `alcove_follow_state` never fails the daemon (Alcove following is the app's). |
| `usage_history` | provider, range (`7d`, `30d`, `90d`, `365d`) | Daily and hourly token/cost rows for one provider from the local transcript scan (`usage_stats.scan_usage`, the same one the Python Usage window ran): `{provider, range, days[{date, tokens_in, tokens_out, cache_read, cost_usd}], hours[{hour, at, …}] (last 7×24), pricing{input_per_mtok, output_per_mtok, cache_read_per_mtok, as_of, approximate, currency, model, source, estimated} or null, account, state, records, estimated, estimated_records}`. `tokens_in` counts input plus cache writes. `pricing` is the dominant model's quote from the Python price tables (`usage_stats.MODEL_PRICING`, `GPT_MODEL_PRICING`, `GEMINI_MODEL_PRICING`; cache reads 0.1× input, Anthropic cache writes 1.25×, OpenAI cache writes 1×): `source` is `table` (the model's own row), `codex_default` (a Codex record that names no model, the literal `codex` from rollouts without a `turn_context` row, is priced at the `model` in `~/.codex/config.toml`; records after a `turn_context` carry that turn's model, `gpt-5.6-sol`, `gpt-6-astra`, and are priced as it) or `reference` (a model the table does not know, priced at the provider's mid-range reference model, `sonnet` / `gpt-5.6` / `gemini-3-flash`, with `estimated: true` rather than $0). The document's `estimated` says whether any counted record was priced that way. Claude and Codex have transcripts; Gemini and any other provider answer empty rows, Gemini with its reference quote so the rate card still shows. Every dollar figure is approximate. The scan runs on its own thread and the reply waits for it at most 2 s (`core_usage_history.REPLY_BUDGET_SECONDS`): a warm scan (the on-disk cache under `~/.local/state/jrbar/usage-scan-cache.*` is incremental, keyed by file mtime and size, so only new or changed transcripts are parsed) answers inside that; a cold one answers what memory holds, `pending: true` with empty rows when there is nothing yet, or the last document with `stale: true`, and the `usage_history_ready` event follows when the scan lands. `scanned_at` is the epoch of the scan behind the rows (null while pending). A document younger than 60 s answers as is. The daemon warms both providers' 30-day scans 8 s after it is ready, so on the Mac the first request is normally warm (measured 2026-09-10: cold Codex 45 s, Claude 11 s; warm Codex 1.5 s, Claude 1.0 s, plus 0.3 s of bucketing). |
| `list_effects` | | `{effects[], packs[], cadences[], generation}`: every effect in the runtime registry (builtins, the provider animations and installed packs) with typed `parameters[]`, a `preview {program, led_count}` rendered at the defaults, the blink `cadence` when one applies; `packs[]` is `{id, name, version, effects[ids], license?, path?}` from the pack store; `cadences[]` the three safe blink cadences. `generation` is derived from the catalog's own content -- every effect id and version, every installed pack's id, version and effect list, plus the assignment cache's save counter -- so it changes when the registry, the installed packs or the assignments change, and does not otherwise (`core_effects.catalog_generation`). It is stable across daemon restarts and never 0. |
| `render_effect` | effect_id, parameters, led_count, color? | `{effect_id, program, led_count, parameters, cadence}`: the LEDS program the daemon would play for those parameters (unknown parameters dropped, bounds enforced), through the presentation safety compiler. Builtins use their registered shapes, provider animations the live solo renderer (`duration_seconds` sets the cycle), pack effects their `motion`/`color`/`cadence` data or a primitive for their meaning. |
| `list_assignments` | | `{assignments[{effect_id, scope, target_id, parameters}], active_scene, generation}` from the effect assignment store; `parameters` come from the daemon's sidecar (`effect-assignment-parameters.json`). `generation` is derived from the assignments and the active scene (`core_effects.assignments_generation`). |
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
| `deck_approve_device` | | The Devices pane's Enable, for a pad that is here: the daemon probes HID once more and refuses with `no_device` ("No Creator Micro 2 is connected.") when it sees none, so a remembered serial is never enabled blindly; otherwise the sole stable serial becomes `creator_micro_device_serial` with `creator_micro_enabled` and the output service is reconfigured. `{serial, approved}`; `ambiguous_device_identity`, `device_identity_unavailable`. |
| `deck_check_input` | enabled | Input check on or off (queued input is revoked). `{enabled}`. |
| `deck_set_settings` | enabled?, session_mode?, analog_enabled? | Writes `deck-controls.json` (bindings untouched), reconfigures the deck runtime. The three settings; `invalid_args` for anything but bools. |
| `ping` | | `{pong, now}`. |
| `quit` | | Replies, then the daemon releases its holds and exits. |

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
| `session_gone` | the session's process is not running, or the daemon has no row for it | reason `no_live_process`, `no_session_row` |
| `not_frontmost` | the window in front is not this session's. Reasons: `no_frontmost_app`; `unknown_host` (JR-Bar cannot say which app hosts the session); `frontmost_is:<bundle id>`; `other_window` (the frontmost application's process is not the one the session descends from); `other_tab:<tty>` (Terminal.app / iTerm2 named a focused tab that is not this session's). | the sentence plus the reason |
| `accessibility_required` | `AXIsProcessTrusted()` is false, so a posted key would silently go nowhere | `JR-Bar cannot answer this ask until macOS lets it send the keystroke. Turn on System Settings > Privacy & Security > Accessibility > <row>.` The row is the daemon's own bundle name -- `jrbar-core` on an installed deployment, since the helper is a separate TCC client from JR-Bar.app. |
| `send_failed` | macOS refused to build or deliver the event | the failure's name |
| `busy` | the answer worker did not finish inside `ANSWER_REPLY_BUDGET_SECONDS` (6 s) | `answering did not finish in time` |

The same surface backs the panel's Approve/Deny, the notification actions and a
Creator Micro session key, so a refusal reads identically wherever it happens;
the panel shows the refusal's own sentence rather than an exception name.

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
jrbar status-bar start                  # the old Python UI; refuses to run beside the daemon
```

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
`brightness` line caps the Dot, `linked_dot_scale` (default 0.3) then takes
a fraction of the **light** that means, and the write boundary does the one
sRGB decode. Scaling the code instead and letting the boundary decode the
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
