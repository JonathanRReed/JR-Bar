# JR-Bar (native Swift)

The native macOS replacement for the SidePulse Python UI: a menu-bar agent
app that renders the LED strip's animation as one glowing band under the
MacBook notch, driven by the same `LEDS.LED` program the hardware plays, and
a Raycast-style panel under the status item fed by the core daemon protocol
(`docs/CORE-PROTOCOL.md`).

Everything lives under `app/`. Nothing here touches `src/`, `tests/`, `docs/`,
`packaging/` or `scripts/`.

## Layout

| Path | What it is |
| --- | --- |
| `Package.swift` | SwiftPM package `JRBar` (tools 6.2, macOS 26). |
| `Sources/JRBarLEDS/` | Pure Swift LEDS DSL: model, parser, sampler, presentation-safety compiler. No AppKit. |
| `Sources/JRBarCore/` | The core daemon protocol: NDJSON Unix-socket client, Codable models, `@Observable` `CoreModel`, the event-delivery policy, the "why this light" table, the panel's layout math and label rules, the history model, the Creator Micro 2 deck model and rail geometry, and the child-process supervisor. Foundation only. |
| `Sources/JRBarUI/` | AppKit pieces small enough to test on their own: the status item icon renderer. |
| `Sources/JRBarApp/` | The AppKit + SwiftUI agent app: status item, panel, Screen Bar, Settings, History, Usage Center, Effect Studio and Control Center windows, the deck rail, notifications, sounds, HUD, file-feed fallback. |
| `Tests/JRBarLEDSTests/` | Swift Testing suites plus the firmware fixtures they check against. |
| `Tests/JRBarCoreTests/` | Protocol codec tests over fixture frames, settings-document tests, the explanation table and the documented `why` vocabulary, the panel layout math, usage window and session label rules, the event policy, history filtering, the deck model and rail geometry, supervisor restart/backoff, and mock-daemon integration tests (every app-proposed command round-tripped). |
| `Tests/JRBarUITests/` | The icon renderer: every style draws, styles differ, warning colours, caching. |
| `scripts/gen_leds_fixtures.py` | Regenerates the fixtures from the Python/firmware reference. |
| `scripts/mock-core.py` | A stdlib-only mock `jrbar-core` that plays a scripted timeline over a socket (`$TMPDIR/jrbar-mock.sock`; it refuses the installed daemon's). |
| `scripts/build-app.sh` | `swift build -c release`, assembles and signs `build/JR-Bar.app` (`JRBAR_BUNDLE` picks another path). |
| `scripts/run-dev.sh` | Starts the mock on its socket and `build/JR-Bar-dev.app` against it; never touches the installed app. `--stop` ends both by pid. |
| `scripts/make-icon.swift` | Draws the placeholder icon PNG used for `AppIcon.icns`. |

## Build, run, test

Command Line Tools only (no Xcode, no `xcodebuild`):

```sh
cd app
swift build                 # library + app, debug
swift test                  # 149 tests / 27 suites; the parity test fans out over 29 programs
./scripts/build-app.sh      # release build -> build/JR-Bar.app (signed "Nautilus Local Dev", ad-hoc fallback)
./scripts/run-dev.sh        # mock + build/JR-Bar-dev.app on the mock socket (--build rebuilds, --stop ends both)
```

Sparkle: `build-app.sh` links the pinned Sparkle.framework when
`JRBAR_SPARKLE_FRAMEWORK_DIR` names a directory holding it (the default is
`../build/macos-pkg/sparkle-distribution`, which exists after one `make
package`), embeds it in the dev bundle and writes the feed URL and the
committed public key (`packaging/sparkle_public_ed_key.txt`) into its
Info.plist, so the dev app can check the real feed. Without the framework
(`JRBAR_SPARKLE_FRAMEWORK_DIR=` or a fresh clone) `SparkleUpdater.swift`
compiles its stub half: "Check for Updates…" stays in the app menu,
disabled, with the reason as its tooltip. The packaging script prepares
the distribution first and passes it in (`JRBAR_EMBED_SPARKLE=0`: it embeds
and signs the framework itself). Plain `swift build` / `swift test` never
link it. The manifest reads the variable at evaluation time and SwiftPM
re-evaluates it when the environment changes, so switching modes is one
rebuild.

`swift test` on a CLT-only machine needs swift-testing's macro plugin and
runtime, which the CLT installs outside the default search paths. The manifest
detects that setup and adds the flags itself (`-load-plugin-library` and two
rpaths); an Xcode toolchain gets a plain manifest. If an incremental `swift
test` right after a plain `swift build` complains that the `TestingMacros`
plugin was not found, that is the swiftbuild backend reusing a stale module
graph: `rm -rf .build` and run `swift test` again.

Regenerate fixtures after changing the reference programs:

```sh
/Users/jonathanreed/Downloads/JR-Bar/.venv/bin/python app/scripts/gen_leds_fixtures.py
```

`@State` is a macro on the macOS 26 SDK and the Command Line Tools ship no
`SwiftUIMacros` plugin either, so the views use `@ViewState`, a typealias for
the `SwiftUICore.State` property wrapper (`PanelMotion.swift`). `#Preview` is
unavailable for the same reason.

Run against the mock daemon. The installed app (a LaunchAgent) owns
`~/.local/state/jrbar/core.sock`; the mock never binds that path unless
`--i-know-this-is-the-real-socket` is passed, and `run-dev.sh` never points
the dev app there. Nothing here is stopped by name (`pkill JR-Bar` would
take the installed app down); `run-dev.sh --stop` kills the pids it started.

```sh
python3 scripts/mock-core.py            # listens on $TMPDIR/jrbar-mock.sock, plays the timeline once
python3 scripts/mock-core.py --step 1   # faster; --start-at 2 begins at the Codex ask, --once for tests, --loop replays
JRBAR_OPEN_PANEL=1 ./scripts/run-dev.sh # mock + dev app, panel open 1.2 s after launch
JRBAR_OPEN_CONTROL_CENTER=1 JRBAR_DECK_RAIL=left ./scripts/run-dev.sh --deck unapproved
```

Or let the app launch and supervise the mock as its child (what the bundled
`Contents/Helpers/jrbar-core` will get):

```sh
JRBAR_CORE_EXEC="python3 $PWD/scripts/mock-core.py --step 2.5" ./build/JR-Bar.app/Contents/MacOS/JR-Bar
```

Against the real daemon from this checkout (stop the LaunchAgents first,
`launchctl bootout gui/$UID/com.jonathanreed.jrbar.{ui,core}`, since only
one daemon can own the hook sockets):

```sh
JRBAR_CORE_EXEC="$PWD/../scripts/run-core.sh" ./build/JR-Bar.app/Contents/MacOS/JR-Bar
```

What runs on this Mac is installed by `../scripts/install-agents.sh`: the
package into `~/.local/share/jrbar/venv`, the hook shim into
`~/.local/share/jrbar/bin`, this bundle into `~/Applications/JR-Bar.app`,
and two LaunchAgents (`com.jonathanreed.jrbar.core`, `com.jonathanreed.jrbar.ui`).
The daemon is a separate agent there, not a `JRBAR_CORE_EXEC` child, and
nothing launchd runs lives under `~/Downloads`: a launchd job reading a
checkout there (the bundle itself, or python reading `pyvenv.cfg`) blocks
on a "would like to access files in your Downloads folder" prompt. Re-run
the script after building to update the running app (see
`docs/CORE-PROTOCOL.md`, "Running it").

Developer switches (environment variables read at launch):

* `JRBAR_CORE_SOCKET=/path/core.sock` overrides the daemon socket path
  (default `$XDG_STATE_HOME/jrbar/core.sock`, i.e. `~/.local/state/jrbar/core.sock`).
* `JRBAR_CORE_EXEC="cmd args"` makes the app spawn the daemon as a child
  process and keep it alive (see Core supervision below). Unset, it only
  connects to whatever listens on the socket.
* `JRBAR_OPEN_PANEL=1` opens the panel shortly after launch (screenshots);
  `JRBAR_OPEN_PANEL=why` also hovers the "Why this light" row so its popover
  shows. `JRBAR_OPEN_HISTORY=1` opens the History window.
  `JRBAR_OPEN_CONTROL_CENTER=1` opens the Control Center (`apply`,
  `restore` or `clear` also opens that sheet);
  `JRBAR_DECK_RAIL=left|right|top|bottom` sends `deck_rail` for that edge
  once the core is live.
* `JRBAR_RENDER_ICONS=/dir` writes the menu-bar icon styles as 8× PNGs
  (glyph, working tint, ring at 42 / 85 / 97 %, label) for design review.
* `JRBAR_OPEN_SETTINGS=<page>` opens the Settings window on `general`, `agents`,
  `usage`, `devices`, `lighting`, `notifications`, `remote`, `advanced` or
  `effects`; `JRBAR_SETTINGS_HEIGHT=1100` makes it tall enough to show a whole page.
* `JRBAR_PLAIN_MATERIAL=1` uses an `NSVisualEffectView` instead of `NSGlassEffectView`.
* `JRBAR_APPEARANCE=light|dark` pins every window to one appearance
  (screenshots of both looks without touching the system setting).
* `JRBAR_SCREEN_BAR=on|off` flips the Screen Bar at launch the way the
  status item's toggle does (screenshots without the band; the value is
  remembered in `app-state.json`, so a relaunch proves persistence).
* Every panel open prints two lines to stdout, `panel frame t=0 (target):
  x= y= w= h= top=` and the same `t=1s` later, so a run can prove the
  frame never moved after opening (`top` is the distance from the top of
  the primary display, for `screencapture -R`).
* `JRBAR_PROGRAM_FILE=/path/file.led` feeds the Screen Bar from any file
  (watched like the device file) without writing to the strip.
* `JRBAR_NO_HALO=1` disables the blurred halo layer.

## The LEDS engine (`JRBarLEDS`)

The Python app never samples LED colours itself: its Screen Bar pipeline drives
the firmware's own parser and renderer (`sidepulse/resources/sdled.wasm`)
through JavaScriptCore. So the Swift engine is a port of the *firmware*, and
its rules were measured against that WASM rather than inferred from
`LEDS_FORMAT.md`. The findings that differ from the document, all recorded in
`Tests/JRBarLEDSTests/Fixtures/`:

* an untimed line lasts 17 ms (the firmware rounds 1000/60 up); a `0ms` colour
  line also lasts 17 ms and shows its target at once, while `roll 0ms` takes
  no time;
* a duration with no easing uses `ease`; an easing with no duration lasts
  330 ms; `none` jumps after its delay; roll's `none` behaves as `linear`;
* `cosine` is a 16-segment piecewise-linear table of the half cosine and
  `pulse` walks that table out and back; the four CSS easings are exact;
* interpolation rounds the delta's magnitude to nearest with exact halves
  toward zero (255→0 at p=0.5 gives 128, 0→255 gives 127);
* a painting line spans the longest `delay + duration` among segments that
  reach a real LED; a line naming only ignored LEDs takes no time and does
  not count as lighting something for `repeat`;
* `brightness N` is global (the last one anywhere wins) and scales the 8-bit
  output; transitions start from the unscaled stored colour;
* `repeat` may appear once, needs a lighting line before it, and a finite
  count plays the loop that many times before the lines after it run once.

API:

```swift
let program = try LEDSProgram.parse(text, ledCount: 8)   // throws LEDSParseError, never renders red strobe
let sampler = LEDSSampler(program: program, ledCount: 8, initialCodes: previous)
sampler.colors(at: seconds)          // [RGB] floats 0...1 (codes / 255), .linear / RGB.fromLinear helpers
sampler.codes(atMilliseconds: ms)    // exact [RGB8] after brightness
program.cycleDuration, program.isStatic, program.motionEndsAt
LEDSPresentationCompiler.compile(text)   // port of presentation_compiler.py (2 Hz / 1 Hz red clamps)
```

Colour note: the sampler's floats are the firmware codes over 255. The strip
PWMs those linearly; the Python Screen Bar paints them straight into an sRGB
context ("identity transfer", see `_led_status_legacy.py`). The app does the
same, in the sRGB colour space rather than the Python's DeviceRGB, so the hex
codes mean what a colour picker says they mean. `RGB.linear` and
`RGB.fromLinear` are the exact IEC 61966-2-1 curves for anyone who needs light.

### Parity

`scripts/gen_leds_fixtures.py` samples 29 programs through
`sidepulse._led_wasm_legacy.SdLedWasmController` (raw firmware engine:
`reset(0)`, `parse(program, 0)`, `step(t_ms)`) at the required times
(0, 0.05, 0.1, 0.25, 0.5, 1.0, 1.5, 2.0, 3.7 s) plus a 37 ms sweep over the
first four seconds. Programs: the device's current `LEDS.LED`, every
`AgentMode` at 8 and 2 LEDs via `program_for_display_state`, the done
celebration, failure, first light, and hand-written edge cases covering every
syntax feature. The Swift sampler matches within one code per channel at every
sample. The same script records 250 firmware parse verdicts (accept / error
name) and 41 `compile_presentation_program` results, which the parser and
compiler ports reproduce exactly.

## The core protocol (`JRBarCore`)

`docs/CORE-PROTOCOL.md`, protocol 1, as a library with no AppKit:

* `CoreClient`: one background thread owns a `SOCK_STREAM` Unix socket
  (`SO_NOSIGPIPE`, peer UID checked with `getpeereid`), reads 64 KiB chunks
  through `NDJSONSplitter` (1 MiB frame cap, CRLF tolerated), decodes each
  frame and hands it to a handler. Reconnects on the documented schedule
  (0.5 s, 1 s, 2 s, 4 s, then 5 s; a connection that reached `hello` resets
  it); `retryNow()` skips the wait when the socket directory changes.
  `send(name:args:)` writes a `command` with a `c-N` id and suspends until
  the matching `reply` (10 s timeout; every pending command fails with
  `.disconnected` when the socket drops).
* `CoreCodec` / `CoreMessages`: `hello`, `state` (aggregate, sessions with
  origin/terminal/ask, asks, devices, usage windows and forecast, power,
  focus, escalation, health as `JSONValue`, settings generation, usage
  providers with the daemon's `action` / `reason` fix-it hints), `lights`
  (surfaces by name with program, led count, anchor, motion, static
  fallback, brightness, why; `linked`, `devices_linked`, `linked_skew_ms`
  and the `auto_dim` decision as `CoreAutoDim`), `event`, `settings` (document as `JSONValue`),
  `reply`, `log`, and `command` encoding. Unknown keys are ignored, unknown
  types and future `v` values decode to `.unknown` instead of failing, and
  every field the daemon might omit is optional.
* `CoreModel` (`@MainActor @Observable`): latest hello/state/lights/
  settings, connection status, last event (deduped by id), in-flight count,
  and the command helpers the panel uses (`openSession`, `answerAsk`,
  `clearCompleted`, `setBrightness`, `quiet`, `snooze`). `isLive` is true
  only once connected *and* a state has arrived; until then (and whenever
  the daemon goes away) the app keeps using the file feeds below.

* `SettingsDocument` / `SettingsPath` / `SettingsKey`: the settings
  document with dot-path reads (`colors.agent_colors.claude`,
  `devices.0.brightness`; integer segments index arrays), a pure
  `replacing` write for optimistic overlays, and the catalogue of every key
  the Settings window touches, by page. Keys are the Python
  `AgentMonitorSettings.to_dict()` names; the five the dataclass lacks
  (`menu_bar_icon_style`, `devices_linked`, `cloud_ingest_token_path`,
  `quota_alert_thresholds`, `devices[].resting_glow`) are listed in
  `SettingsKey.appIntroduced`. `CoreModel` gained `setSetting`,
  `resetSettings`, `installHooks` / `uninstallHooks`, `previewProgram`,
  `applyCalibration`, `doctor`, and a bounded `logTail` of `log` messages.

* `EventPolicy`: the pure table from a `CoreEvent` plus the state and
  settings document to an `EventDelivery` (sound name and repeat count,
  notification title/body/category, HUD toast, status pulse, chime
  start/stop). `completed` → Glass plus a banner when
  `completion_notification_enabled`; `ask_opened` → Funk × `alert_burst`
  plus an Approve/Deny banner, skipped for sub-agents unless
  `subagent_asks_alert`; `failed`, `quota_crossed`, `quota_reset` →
  banners; `escalation_stage` (capped by `escalation_tier`: light 1,
  menu_bar 2, chime/takeover 3) → stage 2 pulses the icon, stage 3 starts a
  30 s chime; `ask_resolved` withdraws the ask banner and stops both when
  no ask is left; device and peer events → a toast. `focus.mode` `dim` /
  `dark` / `pause` silence sounds (banners stay), `pause` also blocks the
  chime; `notify: false` from the daemon is final.
* `LightExplainer`: `lights.surfaces.*.why` → a `LightExplanation` (motion
  word, reason, the session it is about, detail lines). Known whys have
  hand-written lines ("Amber pulse: Codex sidepulse-core is waiting on you
  (permission, 45 s)", "Green sweep: docs-sweep finished 12 s ago", "Dim
  ember: Quiet hours until 07:00"); unknown ones get a motion word derived
  from the surface's `motion` and `static_fallback` colour ("Purple sweep")
  and "Core says …". Details: each surface (LEDs, motion, colour,
  brightness, anchor age), linked, global brightness, idle dim, quiet hours,
  focus.
* `CoreHistoryRow` / `HistoryFilter` / `HistoryGrouping` / `AwaySummary`:
  `list_history` rows, the provider/kind/text filter, day grouping (Today,
  Yesterday, weekday + date), and the "While you were away: 2 finished, 1
  needed you" banner built from the unseen run at the newest end.
  `CoreModel.listHistory`, `clearCompleted` (keeps the reply's `batch`),
  `undoClear` (`undo_clear` inside the 300 s window), `appendLocalLog`.
* `CoreSupervisor`: runs the daemon as a child `Process` with stdout/stderr
  captured line by line, restarts it on the protocol's backoff (0.5 s, 1 s,
  2 s, 4 s, then 5 s), gives up after 10 exits in 2 minutes (`.crashed`)
  until `restart()`, and `stop()` sends SIGTERM then SIGKILL after the
  grace period. The child gets `JRBAR_SUPERVISED=1` and
  `JRBAR_SUPERVISOR_PID` so it can exit if the app dies without unwinding.

`scripts/mock-core.py` is the daemon stand-in: hello/state/lights/settings
on connect, then a looping timeline (Claude starts working, a Codex
permission ask opens, escalates to stage 2 then 3, and resolves, Codex
completes, the Pro disconnects and reconnects, Gemini fails, Claude
completes, idle) with usage ticking up across the `quota_alert_thresholds`
(`quota_crossed`, and `quota_reset` at the idle step), working relay and
amber ask pulse programs on the lights surfaces with fresh anchors, a `log`
line per step, and `ok` replies to every command (answer_ask,
set_brightness, clear_completed / undo_clear and quiet also change the
world). Every step is recorded for `list_history` (rows `{at, kind,
provider, session, label, detail, duration, unseen}`; kinds started /
completed / asked / answered / failed / ended); rows recorded with no client
connected, and a seeded batch from yesterday and earlier today, are
`unseen: true`. `clear_completed` replies with a `batch` that `undo_clear`
restores for 300 s. When supervised it exits once its parent is gone. Its
settings document is seeded from the real Python defaults
(`default_settings_document()`, `auto_dim` included; a write under
`auto_dim.*` republishes `lights` with the mock's `auto_dim` decision:
schedule against the wall clock, display a fixed 62 %, ambient falling
back to display with `available: false` since there is no sensor);
`set_setting` writes by dot path and
echoes a new `settings` (an index past the end of an array is refused with
`invalid_path`), `reset_settings` (`paths[]`, a protocol-1 extension)
restores from the defaults, `install_hooks` / `uninstall_hooks` flip
`health.hooks`, `apply_calibration` writes the gains into the device entry,
`doctor` returns a checklist document. The Creator Micro 2 deck is the
board below (`--deck approved|unapproved|absent|usb|recovering` picks how
the pad starts). `--step`, `--start-at`, `--loop` (the timeline plays once
by default: it makes sounds), `--socket` (default `$TMPDIR/jrbar-mock.sock`;
the installed daemon's path is refused without
`--i-know-this-is-the-real-socket`), `--once`.

### Protocol extensions the mock proposes

`docs/CORE-PROTOCOL.md` is the contract; these are what the Usage Center
and Effect Studio need beyond it, answered by the mock and decoded
tolerantly by `JRBarCore` (every field optional, unknown keys ignored).
The daemon adopted them on 2026-09-09 (`usage_history`, `list_effects`,
`render_effect`, `list_assignments`, `set_assignment`, `clear_assignment`,
`import_effect_pack`, `export_effect_pack`, `reset_settings`, `undo_clear`'s
`batch`); the contract documents the daemon's shapes, the mock mirrors them.

* `state.usage.providers[]`: `account {plan, label, fidelity}` next to the
  windows, and `forecast {exhausts_at, pace}` (the doc reserves `forecast`
  without a shape; `pace` is `ahead` / `on_pace` / `behind`). A provider
  whose `state` is `not_signed_in` (any state containing `sign`, `auth` or
  `login`) may have no windows; the Usage Center shows how to fix it.
* `usage_history {provider, range: 7d|30d|90d|365d}` →
  `{provider, range, days[{date, tokens_in, tokens_out, cache_read,
  cost_usd}], hours[{hour, at, …same}], pricing {input_per_mtok,
  output_per_mtok, cache_read_per_mtok, as_of, approximate, currency},
  account}`. Errors: `not_found` for an unknown provider, `invalid_range`.
  `refresh_usage` replies `{requested_at, providers}` as the daemon does.
* `list_effects` → `{effects[], packs[], cadences[], generation}`; each
  effect is the registry's `EffectDefinition.to_dict()` shape (`id, label,
  description, meaning, surfaces, parameters[{name, type, default,
  description, minimum, maximum, choices, minimum_items, maximum_items,
  allow_empty, unit}], safety, energy, reduce_motion_fallback, version,
  catalog, role`) plus `pack` for `pack:<pack>:<effect>` ids, `preview
  {program, led_count}` (the rendered 8-LED LEDS program) and `cadence` for
  hard blinks. Packs: `{id, name, version, effects[], license, path}`.
* `render_effect {effect_id, parameters, led_count, color?}` →
  `{effect_id, program, led_count, parameters (normalised), cadence}`.
* `list_assignments` → `{assignments[{effect_id, scope, target_id,
  parameters}], active_scene, generation}`.
* `apply_effect {effect, scope, target, parameters?}` is the protocol's
  own command; the mock replies with the daemon's `{effect, scope, target,
  assignments[]}` plus the fuller rows above, `active_scene` and
  `generation`. `EffectAssignment` decodes both the lean `{effect, target}`
  rows and the `{effect_id, target_id, parameters}` ones. Refusals are
  `invalid_args`, as in the daemon.
* `import_effect_pack {path}` → the new catalog plus `imported {id, name,
  effects}`; `invalid_pack` for anything but a data-only JSON v2 pack under
  256 KB, `conflict` for a pack id already loaded from elsewhere.
  `export_effect_pack {ids[], path, name?}` writes a v2 pack and replies
  `{path, effects, bytes, id}`.
* `quota_reset` is emitted (the doc reserves it) with `provider` and
  `detail` when the idle step puts a window back.

The Creator Micro 2 deck (proposed and adopted 2026-09-10, mirroring
`deck_session_board.py`, `creator_micro_keymap.py`,
`creator_micro_lighting.py` and `deck_control_center_window.py`; the
daemon's shapes are in `docs/CORE-PROTOCOL.md`, and
`Tests/JRBarCoreTests/Fixtures/real_state.json` is one of its frames with
the pad off: `device` present but `connected` / `approved` false and
`transport` / `layer` / `profile` / `firmware` / `receipt` null, thirteen
remembered identities with null labels, seven banks, a stock keymap with
three layers):

* `state.deck = {device, slots[13], aux[7], banks, rail, keymap, input_check,
  last_input, settings}`.
  `device {serial, name, transport: usb|bluetooth, connected, approved,
  firmware, layer, profile, conflict, receipt {code, message, at}}` or
  null with no pad; `conflict` is a runtime reason (`foreign_responses`:
  another app answered on the report stream, the daemon stopped writing).
  `slots[]`: one per key of the current bank, `{index 0..12, identity
  (the board's digest of the work key, null when unassigned), session (the
  live id, null when the identity is remembered but not observed:
  "Reserved"), label, provider, state, pinned, navigable, color}`; `state`
  is the board's word (`input_required`, `failure`, `active`, `completed`,
  `idle`, `stale`, `unavailable`, `unknown`, `ended_unconfirmed`, shown as
  Needs you / Error / Working / Completed / Idle / Stale / Not observed /
  Unknown / Ended, unconfirmed) and `color` the solid per-key colour the
  lighting layer writes (ask `#FF3A00` for input_required and failure,
  working `#00E5FF`, done `#00FF66`, else `#020204`; `#000000` when the pad
  is not driven). `aux[]`: `{index 13..19, label, mapping}` for Encoder 1
  inputs 1–3 and Joystick sectors 1–4 with their explicit deck action
  (`next_bank`, `open_usage`, … or null). `banks {index, count}` (13 slots
  per bank, wrapping). `rail {edge: off|left|right|top|bottom}`. `keymap
  {state: stock|applied|recovering, backup_at, generation, layers[{profile,
  layer, label}]}`. `input_check` (inputs shown, actions paused).
  `last_input {index 0..23, kind: press|dial|joystick|analog, at}`.
  `settings {enabled, session_mode, analog_enabled}` (`deck-controls.json`).
* `deck_press {index}` → `{index, action, identity, session}`: what the
  physical press does, from the screen. A session key reveals its session
  (`reveal_session`; no approval is emulated), an auxiliary control runs
  its mapping (`next_bank` / `previous_bank` reply with `bank`). Errors:
  `invalid_args`, `not_found` ("Reserved: session not observed." / "No
  session assigned." / "Configure this auxiliary control in Settings >
  Devices."), `input_check` while input check is on.
* `deck_pin {index}` → `{index, identity, pinned}` toggles the pin on the
  identity at that key (pins are per identity and survive Clear absent);
  `not_found` for an unassigned key.
* `deck_bank {delta}` → `{index, count}`, wrapping. `deck_rail {edge}` →
  `{edge}`. `deck_clear_absent` → `{removed, banks}`: unpinned identities
  with no observed session leave, later keys move up.
* `deck_plan_keymap {profile, layer, include_auxiliary}` → `{profile,
  layer, include_auxiliary, changes[], preview, controls[{index, label}]}`,
  the `plan_keymap` result: `changes` are "Key N: old -> KV_OAI_AGnn;
  replaces its normal keystroke with a JR-Bar device input." (and
  "Encoder 1 input N: … replaces its normal firmware action." with the
  auxiliary switch), `preview` the review alert's text. `invalid_plan`
  with the ValueError message otherwise.
* `deck_apply_keymap {profile, layer, include_auxiliary}` → `{code,
  message, changes, state, backup_at, generation}`: the receipt
  (`keymap_verified`, or `already_configured`) as an ok reply; refusals are
  error replies whose code is the receipt code (`connection_required`,
  `device_conflict`, `recovery_required`, `invalid_plan`, `readback_mismatch`,
  `backup_failed`, …) and whose message is the Python app's sentence for
  it. Input check turns on after a verified write. `deck_restore_keymap`
  → `{code: keymap_restored|already_restored, message, …}`, same refusals.
* `deck_approve_device` → `{serial, approved}` (`no_device`).
  `deck_check_input {enabled}` → `{enabled}`. `deck_set_settings {enabled?,
  session_mode?, analog_enabled?}` → the settings (`invalid_args` for
  anything but bools).
* Events: `deck_input {input: {index, kind, at}}` (nested, because the
  envelope's `kind` is the event kind) for every observed control, and
  `deck_receipt {code, message}` whenever a receipt is recorded; the same
  receipt sits on `device.receipt`. Both are `notify: false`; the app
  toasts only receipts that mean the pad cannot be written.

## The app (`JRBarApp`)

* `LSUIElement` accessory app; `NSStatusItem` with a template glyph (a bar
  tucked under a notch cap) tinted by `state.aggregate` when the core is
  live, else by the aggregate reduced from
  `~/.local/state/sidepulse/agent-monitor/latest.json` (either the `agents`
  summary counts or the raw `works` list). Left click toggles the panel;
  right click or Option-click shows a utility menu (state, core status,
  lights source, Open Panel, History…, "Show Screen Bar" toggle (persisted),
  Settings…, Quit). `menu_bar_icon_style` picks the look
  (`StatusIconRenderer` in `JRBarUI`, 18×18 pt, cached per spec, redrawn
  only when the spec changes): `glyph`; `glyph_ring`, the glyph inside a
  thin ring showing the primary provider's 5 h window (the first of
  `usage_graph_providers` that reports usage), amber from 80 %, red from
  95 % (a non-template image then, so the ring keeps its colour); and
  `glyph_label`, the glyph beside "1 ask · 2 working" as the button's
  title. Stage-2 escalation pulses the icon amber (a layer opacity
  animation; Reduce Motion holds amber) until the ask resolves; the state's
  `escalation.stage` is the source of truth so a launch mid-escalation
  catches up.
* Events → the Mac (`EventCoordinator`, decisions from `EventPolicy`):
  sounds through `AVAudioPlayer` on the system AIFFs (Glass, Funk, Basso,
  Pop, Hero for the chime), so a muted alert channel does not silence
  them; notifications through `UNUserNotificationCenter`
  (`NotificationBridge`), permission requested the first time a banner is
  due and never at launch, an `ask` category with Approve / Deny actions
  that send `answer_ask`, a click on any banner sends `open_session`, the
  ask banner withdrawn on `ask_resolved`; device and peer events show a
  2 s glass pill under the notch (`NotchHUD`). Every delivery is written to
  the log tail ("event ask_opened · sidepulse-core → Funk×3, banner").
  Unbundled (`swift run`) there is no bundle identifier, so banners become
  log lines.
* The panel (`PanelController`, `PanelStore`, `PanelView`): a borderless
  non-activating `NSPanel` at `.popUpMenu` level, 360 pt wide, anchored under
  the status item and clamped to the screen, hosting SwiftUI inside an
  `NSGlassEffectView` (14 pt continuous corners). It becomes key without
  activating the app so the keyboard works: Up/Down move the selection
  (nothing is selected until an arrow key says so), Return sends
  `open_session` for it, Esc closes, Cmd-Q quits; Cmd-Return / Cmd-D
  approve or deny the focused ask. It closes on Esc, on a click anywhere
  outside it, and when it resigns key. Its size is computed, never
  measured: `PanelLayout` (in `JRBarCore`, pure and tested) adds up fixed
  row heights (session 44 pt, ask 92 pt, usage 50 pt, why row 30 pt, header
  40 pt, devices 82 pt, footer 34 pt) for the content the store is about
  to show, caps the Sessions list at 7½ rows and Usage at 3½ (a cut list
  scrolls, ends half a row in and fades out over its last 16 pt), and
  keeps the whole panel under 70 % of the screen by taking rows from
  whichever list is closer to its own cap, down to floors of 2½ and 1½.
  The window is set to that frame once, before it is shown; every label is
  one line (`lineLimit(1)` with truncation: session label, cwd tail, state
  word, window names, device names) and the state/elapsed column and the
  percent column have fixed widths, so nothing inside can change the size.
  Nothing animates until the unfold has finished (`PanelStore.animationsArmed`);
  after that rows coming and going resize the window with the contents
  spring. Rows are buttons: a hover tint only under the pointer while the
  panel is open, a pressed tint only while the mouse is down, and the
  selection tint only for the keyboard's row. Sections: header (aggregate
  word, counts, connection dot with a tooltip), Sessions (asks pinned first
  with Approve/Deny sending `answer_ask`; then waiting, failed, working,
  done, idle rows with the provider tile, the label (`SessionLabel`: the
  daemon's label with a leading provider name dropped and UUIDs shortened,
  else `short_id`, so "Claude Claude fca1eb06-…" can never appear), cwd
  tail, state word and activity mark, elapsed time, worker badge; click
  sends `open_session`), Usage (per provider: the 5h and 7d bars, or the
  first two windows, labelled by `UsageWindowLabel` (`five-hour`/`5h` →
  5h, `weekly`/`7d` → 7d, `daily`, `monthly`, `credits`, else the first
  six characters of the name) in the provider accent turning amber at
  80 % and red at 95 %, the percent right-aligned in its own column with
  `~` when the fidelity is not `official`, one line of reset countdowns,
  pace hint), Devices (Pro / Dot / Screen Bar chips; the Screen Bar chip
  toggles the band; a brightness slider sends `set_brightness` for `all`,
  throttled to one command per 120 ms while dragging and flushed on
  release), and a footer (Clear done → `clear_completed all`, Quiet… →
  `quiet` for 30 min / 1 h / 4 h / 12 h, History (⌘Y), an overflow menu
  (Usage Center ⌘U, Effect Studio, Control Center ⌘K), a gear for
  Settings…, Quit). Empty states: "No agents right now" when live and
  quiet; "Core is starting" / "Core not connected" with the file-feed
  summary when not. With a supervised core that gave up, the header shows
  "Core crashed 10× in 2 min" with a Restart button and a red dot.
* "Why this light": the last row of the Sessions section is the
  `LightExplanation` headline ("Amber pulse: Codex sidepulse-core is
  waiting on you (permission, 45 s)", "Breathing orange: Claude jr-bar-67
  is working"). `LightExplainer` reads `lights.surfaces.screen_bar.why`
  as the documented vocabulary (`LightWhy`: idle, working, waiting,
  completed, failed, capacity, quiet, sleep_dim, idle_dim, battery,
  calendar, reminder, escalation, preview, studio, unknown; the older
  spellings `needs_you`, `completed_unseen`, `quota_crossed`, `dnd`,
  `escalation_*` map onto them) and `why_detail` (`session`, `label`,
  `provider`, `seconds_in_state`, `brightness_factor`, `dimming[]`) for
  the subject and the dimming factors; the motion word comes from the
  surface's `motion` (`static` / `finite` / `continuous`, or the older
  `breathe` / `chase` / `beat` / `sweep`) and the brightest colour in its
  `static_fallback` (a bare hex or a whole static program). A `why` the
  table does not know falls back to the motion word plus the top session
  ("Breathing orange: Claude fca1eb06 is working (moon phase)"); provider
  names are never doubled and UUIDs never printed. Hovering the row for
  0.35 s opens a detail popover (a glass child window that never becomes
  key, so the panel keeps the keyboard) with the hardware / Screen Bar /
  Dot programs, how long the state has held, the dimming in effect and
  the settings that shape brightness; it follows the row when rows above
  come and go. Clicking it opens the session the light is about. The
  Screen Bar tooltip carries the same headline as its second line.
* History (`HistoryWindowController`, `HistoryStore`, `HistoryView`): a
  titled 680×520 window (⌘Y from the panel, the footer's History item, the
  status menu, or the app menu) listing `list_history` rows grouped by day
  with pinned day headers, a filter bar (search field, scrolling provider
  chips with tiles and kind chips), an away banner on top when the newest
  rows are `unseen` ("While you were away: 2 finished, 1 needed you", with
  Open latest), rows with a clock column, provider tile, label, kind badge,
  detail, a monospaced duration column and hairline separators; clicking a
  row sends `open_session`. Toolbar: Clear completed (`clear_completed`),
  Undo (`undo_clear` for the last batch, shown with the time left in the
  5-minute window), Refresh. Rows refresh on every event and every 30 s
  while the window is open.
* Motion (`PanelMotion`): three springs only. `unfold` (the window fades in
  and rises 6 pt), `contents` (rows insert, remove and reorder), `crossfade`
  (a word or number changes in place). The working mark breathes, the ask
  mark pulses amber. With Reduce Motion on, everything collapses to short
  opacity fades and the marks hold still; the setting is read live.
* `ProviderStyle`: id → display name, accent (the Python app's
  `default_agent_color` values, captured from `sidepulse/colors.py`), and a
  glyph (SF Symbol, or a text glyph for π and K) for claude, codex, gemini,
  pi, grok, devin, opencode, openclaw, antigravity, cursor, hermes and kiro;
  unknown providers get a neutral tile and a capitalised name.
* Screen Bar: a borderless non-activating `NSPanel` at `.statusBar` level on
  all Spaces, click-through, sized by the ports of
  `virtual_window_frame_for_screen` / `rounded_band_bounds` /
  `screen_bar_design.py`: the notch slot from `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea`, 14 pt auto wings, a 6 pt band with 3 pt corners
  1 pt below the notch (197 pt on this MacBook Pro). The eight LED samples
  become one horizontal `CAGradientLayer` through the Python's raised-cosine
  inter-LED blend (2 pt columns, 1/1024 quantised, coalesced runs), plus a
  GPU-blurred copy underneath as the halo and the design's faint outline.
  There is never a per-LED segment.
* Frame clock: a `CADisplayLink` from the view, capped at 60 Hz; the sampler
  runs only on ticks, identical frames are not committed, and the link pauses
  when the program is static or finished, when the bar is hidden, or when the
  display sleeps.
* Lights: when the core is live, `lights.surfaces.screen_bar.program` goes on
  the bar and its `anchor` (Unix seconds) is mapped onto the display link's
  clock so the band is phase-locked to the strip; a repeated program with
  the same anchor is not restarted, and a future or stale anchor falls back
  to "now". Otherwise the file feeds (all kqueue/notification driven, no
  polling): `/Volumes/SidePulse/LEDS.LED` when the strip is mounted, else
  `~/.local/state/sidepulse/agent-monitor/screen-bar.led` (may not exist
  yet), else a built-in breath. The daemon's program wins the moment it is
  live and the file program returns when the socket drops. Every program
  goes through the presentation-safety compiler before it is shown; refused
  programs keep the previous one and are named in the menu's lights line.
* Events: `completed`, `ask_opened` and friends play their named system
  sound when `notify` is true, and are logged. No banners yet.
* Screen Bar interactions (`ScreenBarInteraction`): the band stays
  click-through (`ignoresMouseEvents`), and global + local `NSEvent`
  monitors hit-test the pointer against the band's own rect instead.
  Hovering for 0.32 s shows a glass pill under the band with the
  top-priority session (a live ask, else a failure, else the working one,
  else an unseen completion; with nothing live, the aggregate word) as
  provider tile, label and state word; it leaves when the pointer does,
  on any click, when the geometry changes, and after 4 s regardless.
  Clicking the band sends `open_session` for the ask's session, else the
  working one, else nothing. The panel never becomes key.
* Settings (`SettingsWindowController`, `SettingsStore`, `SettingsView`,
  `SettingsPagesA/B`): a standard titled, resizable 760×520 window
  ("JR-Bar Settings", frame autosaved, page name in the subtitle) hosting
  a `NavigationSplitView` with System Settings-style tinted sidebar icons
  and a grouped `Form` per page. Every control reads the daemon's document
  and writes through `set_setting`; the store overlays each write until the
  echo carries it (so sliders do not snap back), throttles slider streams
  to one write per 120 ms, and shows refused writes in a transient line.
  A key the document lacks renders its default, disabled, with a "Not
  provided by core" caption; with no document at all a banner says so.
  Pages: General (launch at login via `SMAppService`, icon style, tips,
  Screen Bar on/Alcove/full screen/link, global brightness, Software Update
  stub with an app-local channel), Agents (twelve provider rows with hook
  status from `state.health.hooks`, Install/Reinstall/Remove →
  `install_hooks` / `uninstall_hooks`, per-provider "Open in", transcript
  toggles, sub-agent asks), Usage (providers shown, display mode, graph
  range, Claude plan-limits consent (writes `claude_plan_limits_enabled`
  and `…_consent_version` together), quota thresholds, capacity history),
  Devices & Screen Bar (a card per `devices[]` entry with display mode,
  brightness, auto-brightness, provider pin, asks-only, Calibrate… sheet
  with RGB gains + resting glow previewed live through `preview_program`
  and applied through `apply_calibration`; Pro+Dot link; gap width, wing
  length (null = automatic), bracket style, minimum glow), Lighting
  (provider colour pickers, blend mode with descriptions, cycle speed, done
  celebration, pulse floor/ceiling per mode, idle/sleep dim, auto-off,
  Auto-dim (`AutoDimSettings` in `JRBarCore`: a segmented Off / Schedule /
  Follow display / Ambient light picker on `auto_dim.mode`, then only the
  chosen mode's rows: start/end time pickers and a fraction slider,
  the display floor, or the ambient floor with lux floor/ceiling fields;
  under them a "Right now" line from `lights.auto_dim` via
  `AutoDimReadout`: "Ambient: 12 lux → 45 %", "Sensor unavailable,
  following display: 62 % → 62 %", "Schedule: 23:10, inside the window →
  30 %", "Display unreadable → 100 %"), scene, and Effects…), Notifications &
  Focus (completion banner/sweep, escalation tier and timings, alert burst,
  quiet schedule with time pickers, focus sync with per-Focus dim rules,
  DND mode, keep-awake, closed-lid policy with the helper's status from
  `state.power`, battery threshold), Remote (peers, unmuted machine list,
  cloud ingest with the token path, webhook URL and events), Advanced
  (connection, core version, socket, capabilities, generations, Reveal
  State Folder, Run Doctor → `doctor` shown as a checklist plus JSON, the
  `log` tail, and a per-page Reset… → `reset_settings`). The panel's
  Settings… and the status menu's Settings… (⌘,) open it; a minimal main
  menu gives the text fields ⌘C/⌘V/⌘A.

* Usage Center (`UsageCenterWindowController`, `UsageCenterStore`,
  `UsageCenterView`; ⌘U from the panel, the panel's Usage header
  "Details ›", the footer overflow menu, the status menu and the app
  menu): a 760×720 titled window with a range picker (7d / 30d / 90d /
  365d), a Tokens / Cost picker and Refresh (`refresh_usage`, ⌘R). One
  card per provider in `state.usage.providers`: tile, name, a state badge
  ("Near limit", "Limited", "Stale"), the account line (plan · label ·
  fidelity from `account`, else the history's), the primary (5h) percent
  in the provider accent turning amber at 80 % and red at 95 % with `~`
  when the fidelity is not official, then a ring per window with its reset
  countdown and burn rate, and beside the rings the forecast reading:
  the daemon's `forecast {exhausts_at, pace}` when it sends one, else a
  least-squares pace over the last 45 minutes of `state` samples
  (`UsageSampleLog` in `CoreModel`, `UsageForecaster` in `JRBarCore`):
  "At this pace the 5h window runs out at 16:42 (in 1h 12m)", "Comfortable:
  61 % left, resets before you'd hit it", "Used up", or "no pace yet". Under
  a divider, a Swift Charts stacked bar graph of `usage_history` (input,
  output and cache reads by day, by hour for 7d; or cost) with totals, the
  cost estimate, the cache savings line (cache reads priced at the input
  rate minus the cache rate) and the pricing disclosure ("Approximate: list
  prices ($3.00 in / $15.00 out per M tokens, $0.30 cache), as of …
  Subscription plans are not billed per token."). A `quota_reset` event
  washes that card in its accent with a "Window reset" pill for ~1.5 s
  (a fade under Reduce Motion) and reloads its history. Empty states:
  "Core not connected", "No usage yet", "Sign in via the CLI" for a
  provider whose `state` says it is signed out (windows stay hidden in the
  panel), a breathing skeleton while a history loads, an error row with
  Retry when the command fails, "Nothing recorded in this range".
* Effect Studio (`EffectStudioWindowController`, `EffectStudioStore`,
  `EffectStudioView`; Settings › Lighting › Effects…, the panel footer's
  overflow menu, the status menu and the app menu): a 1060×680 window in
  three panes. Library: a search field and the `list_effects` catalog
  grouped by meaning ("Provider animation", "Attention required", "Pack ·
  nightlab", …), each row a still of the effect's brightest frame (the
  selected row animates), pack and Attention / Critical badges, a check
  when an assignment uses it. Inspector: label, pack badge, id,
  description and meaning; the live 8-LED preview (`LEDStripPreview`,
  30 Hz, every program through the presentation compiler first) plus the
  Screen Bar band under it; "Preview on hardware" (`preview_program` on
  `hardware` for 5 s, a one-time consent alert remembered in
  `UserDefaults`, a countdown while it plays); Assign… (⌘↩); fact chips
  (safety, energy, surfaces, Reduce Motion fallback); a safety panel for
  attention / critical effects and named cadences ("1.0 Hz · 500 ms on /
  500 ms off", the 2 Hz clamp note); parameters as native controls from
  `EffectParameter.control` (switch, slider with unit, integer slider or
  stepper, menu, colour well, palette editor with add / remove / clear),
  re-rendered through `render_effect` 150 ms after the last change, with
  Reset to defaults; and the "Used by" list. Assignments: the Active scene
  menu (`set_setting active_scene`), `list_assignments` grouped by scope in
  precedence order (Device, Project, Provider instance, Provider, Scene,
  State, Default) with the target's display name, the effect, "tuned" when
  parameters differ from the defaults, a band preview and a remove button
  (`apply_effect` with `effect: null`). The Assign sheet picks scope and
  target (state, scene, provider, device menus; free text for instance and
  project), keeps or drops the tuned parameters, warns on attention /
  critical effects and refuses the reserved Needs-you / Failed states
  before the daemon does. Toolbar: Import… (`NSOpenPanel` →
  `import_effect_pack {path}`; the daemon parses and validates the JSON,
  the app never does), Export… (`NSSavePanel` → `export_effect_pack {ids,
  path, name}` for the selected effect, its whole pack, or every provider
  animation) and Refresh.
* Control Center (`ControlCenterWindowController`, `DeckStore`,
  `ControlCenterView`; ⌘K from the panel, the footer's overflow menu, the
  status menu, the app menu and Settings › Devices): a 1000×740 window for
  the Creator Micro 2, everything on it `state.deck`. A device chip
  (serial, USB/Bluetooth glyph, connected / needs approval / conflict dot,
  firmware, profile and layer, an Approve button until the serial is
  approved, the keymap badge, and the last receipt with its time). A red
  banner while `device.conflict` is set ("Another app is talking to the
  device; JR-Bar stopped writing"). The pad drawn as it is: four key rows
  of 2 / 4 / 4 / 3, the dial beside the short top row with its three
  inputs named by their mappings, the joystick beside the bottom row with
  its four sectors; each key a dark cap carrying the provider tile, the
  number, the label ("Unassigned" / "Reserved" / the session), the state
  word, a glow in the daemon's solid colour when lit, a pin badge, and a
  pin/unpin button on hover; click sends `deck_press`; a white flash on
  `deck_input` (0.9 s, no animation under Reduce Motion). "Bank N of M"
  with wrapping ‹ › (arrow keys). Under it the observed-input line ("Key 3
  pressed 4 s ago", "No physical input observed") and the Python
  footnote. A Sessions list beside the pad (bound key number, pin mark,
  "other bank"); dragging a session onto the pad pins the slot that holds
  it, the context menu pins, reveals or opens it. A control strip at the
  top (inside the content: the NSToolbar shows menus as bare icons):
  Check input (`deck_check_input`; presses are refused while it is on),
  Apply keymap… (sheet: the layer picker from `keymap.layers`, "Also
  configure supported dial and joystick mappings", the `deck_plan_keymap`
  preview re-read 150 ms after each change and retried when the core
  comes up, Apply → `deck_apply_keymap`), Restore original… (the Python
  confirmation, `deck_restore_keymap`), Clear absent… (the Python
  confirmation, `deck_clear_absent`), and the compact-rail edge popup
  (`deck_rail`). Pins, bank steps and clears are
  shown optimistically until the next `state`. Empty states: "Core not
  connected"; with no pad the same board, dimmed, and "Turn on your
  Creator Micro 2 or plug it in" (the slots and the rail need no
  hardware).
* The Rail (`DeckRailController`): a glass `NSPanel`, non-activating,
  floating, on every Space, never key, no auto-hide, shown while
  `rail.edge` is not `off` and the core is live. Fourteen contiguous cells
  along the chosen edge (`DeckRailGeometry`: `(extent - 20) / 14` clamped
  to 18–30 pt, a 34 pt band, centred): the thirteen keys as their number
  plus the Python marks ("!" for Needs you / Error, "·" for Working) on a
  tint of the daemon's colour, a pin dot, a white flash on `deck_input`,
  and "…" which opens the Control Center. Click sends `deck_press`; hover
  shows a glass label (title, state, number) beside the cell. It lives on
  the Control Center's screen, else the key window's.
* Settings › Devices › Creator Micro 2: Enable, Session keys and Analog
  joystick sectors (`deck_set_settings`), the status line, keymap, rail
  edge, slot count and last receipt, and Open Control Center… (⌘K).
* Lighting page previews: each provider's colour well sits beside a 66 pt
  band that plays that provider's working animation under the current
  blend mode and cycle speed (rebuilt on every change, each provider a
  phase apart), and the Celebrate completions row shows the done
  celebration as eight dots, dimmed when the toggle is off.
* Core supervision (`CoreSupervisor` in `JRBarCore`): with
  `JRBAR_CORE_EXEC` set the app spawns that command as a child, captures
  its stdout/stderr into the log tail (Advanced → log), retries the socket
  as soon as the child is running, restarts it with backoff when it exits,
  and after 10 exits in 2 minutes shows "Core crashed" in the panel header
  with a Restart button (the status menu's Core line says the same). Quit
  (including `pkill JR-Bar`: SIGTERM is turned into an orderly
  `NSApp.terminate`) sends the child SIGTERM and SIGKILL after 3 s. Unset,
  today's behaviour: connect to whatever is listening.

## Stubbed or deliberately deferred

* The packaged bundle supervises `Contents/Helpers/jrbar-core.app` (the
  frozen daemon) itself; a dev bundle has no daemon and either supervises
  `JRBAR_CORE_EXEC` or connects to whatever listens on the socket. The
  file feeds remain the fallback while nothing is connected.
* Notifications need the user to allow them the first time one is due
  (the system prompt). `quota_crossed` / `quota_reset` banners are on
  unless `quota_alerts_enabled` is false. Nothing is done for
  `peer_arrived` / `peer_departed` beyond the toast. Escalation stage 3 is
  a repeating chime (Hero, every 30 s); the `takeover` tier gets the same
  chime, no full-screen takeover.
* Software Update: the app owns a `SparkleUpdater` (`SparkleUpdater.swift`)
  over the embedded framework: "Check for Updates…" in the app menu
  (`AppDelegate.checkForUpdates(_:)`, validated by
  `SPUUpdater.canCheckForUpdates`), automatic checks off until turned on
  (`SparkleUpdater.shared?.automaticallyChecksForUpdates`; the first
  launch writes `SUEnableAutomaticChecks=false` to user defaults so
  Sparkle never shows its own prompt), and the channel picker's
  `updateChannel` default read by `allowedChannels(for:)` (`beta` adds the
  beta-tagged items). Settings › General binds all three: its "Check for
  Updates…" button sends `AppDelegate.checkForUpdates(_:)` through the
  responder chain, "Automatically check for updates" mirrors
  `SparkleUpdater.shared?.automaticallyChecksForUpdates` through
  `SettingsStore.refreshUpdater()` (both disabled, with the reason as the
  subtitle and tooltip, when the framework is not in the build), and the
  channel picker calls `channelDidChange()`. The panel's overflow menu has
  the same "Check for Updates…" row; when the updater is unavailable the
  panel shows the reason as a toast.
* App state: the hooks-installed stamp, the login-item marker and the
  Screen Bar flag live in `~/.local/state/jrbar/app-state.json`
  (`AppState` / `AppStateFile` in JRBarCore, tolerant read, atomic write,
  seeded once from the old user-defaults keys when the file is absent),
  not in `UserDefaults`: on the owner's Mac cfprefsd stopped persisting
  any domain (`defaults write` fails from the shell too), so the defaults
  forgot them on every relaunch. User defaults keep only Sparkle's own
  keys, `updateChannel`, and the window conveniences (Usage Center range,
  Effect Studio selection and hardware-preview consent). The launch logs
  `JR-Bar app state (…): hooksInstalledFor=… showScreenBar=…` so a
  relaunch can be checked from the console.
  Launch at login registers with `SMAppService`,
  which only works from a bundled, signed app. `reset_settings` and
  `undo_clear`'s `batch` shape are app-proposed details the mock answers;
  the real daemon has to adopt them. `subscribe` is not surfaced.
* The daemon serves `usage_history`, `list_effects`, `list_assignments`
  and friends since 2026-09-09 and `state.deck` since 2026-09-10; the
  history section still shows an error row with Retry, and the studio its
  "Loading effects…" state, against any core that lacks them. The
  daemon reports no price table, so the Usage Center's cost lines read
  "≈ $0.00 · Approximate: the core reported no price table for this
  provider". `apply_effect`'s `parameters` argument is an extension: the
  daemon's `EffectAssignmentRecord` has no parameters yet, so tuned values
  only survive on the mock.
* The Control Center against a remembered pad that is off (the owner's
  case: `connected` and `approved` both false) says "Off, not yet
  approved", keeps the keymap badge from the backup and disables Apply /
  Restore, since the daemon refuses them with `connection_required`;
  Approve appears only once the pad is seen. The 0.8 intent that a key on a live ask may approve it when
  the terminal is frontmost is the daemon's `deck_press` to implement; the
  app only sends the press. Explicit per-control mappings (open_app,
  shortcut, …) are not edited here: the Dial and Joystick show what the
  daemon reports and point at Settings › Devices, which does not have that
  editor yet. Analog sectors (AG20–AG23) are inputs and a switch, not
  drawn on the pad.
* The Lighting page's tiny previews are built locally
  (`LightingPreviewPrograms`): a reading of each blend mode and the
  celebration, not the daemon's compiler output. The strip is the truth.
* History rows are whatever `list_history` returns (labels through
  `SessionLabel`, so the daemon's "Claude 8870963f-850a-…" reads
  "8870963f" over the Claude tile); the app does not persist its own copy,
  so nothing is shown while the core is away.
* Settings keys the daemon does not serve show "Not provided by core"
  rather than a blank: today `menu_bar_icon_style`,
  `quota_alert_thresholds` and `cloud_ingest_token_path` (the
  `SettingsKey.appIntroduced` set). macOS notification permission for the
  bundle id is the user's: a denied permission logs "notification skipped:
  permission denied" in the Advanced log and the sound still plays.
* The aggregate fallback is a simple reduction of `latest.json` (needs input >
  failed > working > done-within-90 s > idle); the Python attention model with
  its signals, quotas and presentation hints is not ported. Live, the
  status item follows `state.aggregate.mode` and the counts.
* Alcove coexistence, notch silhouette measurement, announcer pill, standing
  gauges, wings-only bracket, reduce-motion handling: not ported.
* The `wrapMenuBar` choice is a constant (`ScreenBarController.wrapMenuBar`),
  not a setting.
* The icon is a programmatic placeholder.
