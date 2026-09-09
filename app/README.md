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
| `Sources/JRBarCore/` | The core daemon protocol: NDJSON Unix-socket client, Codable models, `@Observable` `CoreModel`. Foundation only. |
| `Sources/JRBarApp/` | The AppKit + SwiftUI agent app: status item, panel, Screen Bar, Settings window, file-feed fallback. |
| `Tests/JRBarLEDSTests/` | Swift Testing suites plus the firmware fixtures they check against. |
| `Tests/JRBarCoreTests/` | Protocol codec tests over fixture frames, settings-document tests, and mock-daemon integration tests. |
| `scripts/gen_leds_fixtures.py` | Regenerates the fixtures from the Python/firmware reference. |
| `scripts/mock-core.py` | A stdlib-only mock `jrbar-core` that plays a scripted timeline over the socket. |
| `scripts/build-app.sh` | `swift build -c release`, assembles and signs `build/JR-Bar.app`. |
| `scripts/run-dev.sh` | Kills a running JR-Bar and opens the freshly built bundle. |
| `scripts/make-icon.swift` | Draws the placeholder icon PNG used for `AppIcon.icns`. |

## Build, run, test

Command Line Tools only (no Xcode, no `xcodebuild`):

```sh
cd app
swift build                 # library + app, debug
swift test                  # 37 tests / 7 suites; the parity test fans out over 29 programs
./scripts/build-app.sh      # release build -> build/JR-Bar.app (signed "Nautilus Local Dev", ad-hoc fallback)
./scripts/run-dev.sh        # restart the built app
```

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

Run against the mock daemon:

```sh
python3 scripts/mock-core.py            # listens on ~/.local/state/jrbar/core.sock, loops the timeline
python3 scripts/mock-core.py --step 1   # faster; --start-at 1 begins at the Codex ask, --once for tests
JRBAR_OPEN_PANEL=1 ./scripts/run-dev.sh # opens the panel 1.2 s after launch
```

Developer switches (environment variables read at launch):

* `JRBAR_CORE_SOCKET=/path/core.sock` overrides the daemon socket path
  (default `$XDG_STATE_HOME/jrbar/core.sock`, i.e. `~/.local/state/jrbar/core.sock`).
* `JRBAR_OPEN_PANEL=1` opens the panel shortly after launch (screenshots).
* `JRBAR_OPEN_SETTINGS=<page>` opens the Settings window on `general`, `agents`,
  `usage`, `devices`, `lighting`, `notifications`, `remote`, `advanced` or
  `effects`; `JRBAR_SETTINGS_HEIGHT=1100` makes it tall enough to show a whole page.
* `JRBAR_PLAIN_MATERIAL=1` uses an `NSVisualEffectView` instead of `NSGlassEffectView`.
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
  focus, escalation, health as `JSONValue`, settings generation), `lights`
  (surfaces by name with program, led count, anchor, motion, static
  fallback, brightness, why), `event`, `settings` (document as `JSONValue`),
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

`scripts/mock-core.py` is the daemon stand-in: hello/state/lights/settings
on connect, then a looping timeline (Claude starts working, a Codex
permission ask opens and resolves, Codex completes, the Pro disconnects and
reconnects, Claude completes, idle) with usage ticking up, working relay and
amber ask pulse programs on the lights surfaces with fresh anchors, a `log`
line per step, and `ok` replies to every command (answer_ask,
set_brightness, clear_completed and quiet also change the world). Its
settings document is seeded from the real Python defaults
(`default_settings_document()`); `set_setting` writes by dot path and
echoes a new `settings` (an index past the end of an array is refused with
`invalid_path`), `reset_settings` (`paths[]`, a protocol-1 extension)
restores from the defaults, `install_hooks` / `uninstall_hooks` flip
`health.hooks`, `apply_calibration` writes the gains into the device entry,
`doctor` returns a checklist document. `--step`, `--start-at`, `--no-loop`,
`--socket`, `--once`.

## The app (`JRBarApp`)

* `LSUIElement` accessory app; `NSStatusItem` with a template glyph (a bar
  tucked under a notch cap) tinted by `state.aggregate` when the core is
  live, else by the aggregate reduced from
  `~/.local/state/sidepulse/agent-monitor/latest.json` (either the `agents`
  summary counts or the raw `works` list). Left click toggles the panel;
  right click or Option-click shows a utility menu (state, core status,
  lights source, Open Panel, "Show Screen Bar" toggle (persisted), Quit).
* The panel (`PanelController`, `PanelStore`, `PanelView`): a borderless
  non-activating `NSPanel` at `.popUpMenu` level, 360 pt wide, anchored under
  the status item and clamped to the screen, hosting SwiftUI inside an
  `NSGlassEffectView` (14 pt continuous corners). It becomes key without
  activating the app so the keyboard works: Up/Down move the selection,
  Return sends `open_session` for it, Esc closes, Cmd-Q quits; Cmd-Return /
  Cmd-D approve or deny the focused ask. It closes on Esc, on a click anywhere
  outside it, and when it resigns key. Sections: header (aggregate word,
  counts, connection dot with a tooltip), Sessions (asks pinned first with
  Approve/Deny sending `answer_ask`; then waiting, failed, working, done,
  idle rows with the provider tile, label, cwd tail, state word and
  activity mark, elapsed time, worker badge; click sends `open_session`),
  Usage (per provider: 5h and 7d bars in the provider accent turning amber
  at 80 % and red at 95 %, percent with `~` when the fidelity is not
  `official`, reset countdowns, pace hint), Devices (Pro / Dot / Screen Bar
  chips; the Screen Bar chip toggles the band; a brightness slider sends
  `set_brightness` for `all`, throttled while dragging), and a footer
  (Clear completed → `clear_completed all`, Quiet… → `quiet` for 30 min /
  1 h / 4 h / 12 h, Settings… (stub), Quit). Empty states: "No agents right
  now" when live and quiet; "Core is starting" / "Core not connected" with
  the file-feed summary when not.
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
  scene, and an Effects… page that is an empty state), Notifications &
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

## Stubbed or deliberately deferred

* The app does not launch the daemon as a child process yet (there is no
  daemon to launch); it connects to whatever listens on the socket and
  keeps the file feeds as the fallback until then.
* Settings: Software Update is a stub button plus an app-local channel
  choice (no updater). The Effects page is an empty state; Effect Studio
  (`apply_effect`) is a later slice. `menu_bar_icon_style` is written but
  the status item still draws the glyph only. Launch at login registers
  with `SMAppService`, which only works from a bundled, signed app.
  `reset_settings` is an app-proposed command the mock answers; the real
  daemon has to adopt it (or the app falls back to nothing: the button
  reports the refusal). `subscribe` and `list_history` are not surfaced.
* Events play a sound and are logged; no banners, confetti or notifications.
* The aggregate fallback is a simple reduction of `latest.json` (needs input >
  failed > working > done-within-90 s > idle); the Python attention model with
  its signals, quotas and presentation hints is not ported. Live, the
  status item follows `state.aggregate.mode` and the counts.
* Alcove coexistence, notch silhouette measurement, announcer pill, standing
  gauges, wings-only bracket, reduce-motion handling: not ported.
* The `wrapMenuBar` choice is a constant (`ScreenBarController.wrapMenuBar`),
  not a setting.
* The icon is a programmatic placeholder.
