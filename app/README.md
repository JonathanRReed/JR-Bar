# JR-Bar (native Swift)

The first slice of the native macOS replacement for the SidePulse Python UI: a
menu-bar agent app that renders the LED strip's animation as one glowing band
under the MacBook notch, driven by the same `LEDS.LED` program the hardware
plays.

Everything lives under `app/`. Nothing here touches `src/`, `tests/`, `docs/`,
`packaging/` or `scripts/`.

## Layout

| Path | What it is |
| --- | --- |
| `Package.swift` | SwiftPM package `JRBar` (tools 6.2, macOS 26). |
| `Sources/JRBarLEDS/` | Pure Swift LEDS DSL: model, parser, sampler, presentation-safety compiler. No AppKit. |
| `Sources/JRBarApp/` | The AppKit agent app: status item, Screen Bar panel, file feeds. |
| `Tests/JRBarLEDSTests/` | Swift Testing suites plus the firmware fixtures they check against. |
| `scripts/gen_leds_fixtures.py` | Regenerates the fixtures from the Python/firmware reference. |
| `scripts/build-app.sh` | `swift build -c release`, assembles and signs `build/JR-Bar.app`. |
| `scripts/run-dev.sh` | Kills a running JR-Bar and opens the freshly built bundle. |
| `scripts/make-icon.swift` | Draws the placeholder icon PNG used for `AppIcon.icns`. |

## Build, run, test

Command Line Tools only (no Xcode, no `xcodebuild`):

```sh
cd app
swift build                 # library + app, debug
swift test                  # 16 tests / 3 suites; the parity test fans out over 29 programs
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

Developer switches (environment variables read at launch):

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

## The app (`JRBarApp`)

* `LSUIElement` accessory app; `NSStatusItem` with a template glyph (a bar
  tucked under a notch cap) tinted by the aggregate state read from
  `~/.local/state/sidepulse/agent-monitor/latest.json` (either the `agents`
  summary counts or the raw `works` list). Menu: state header, detail line,
  feed source, "Show Screen Bar" toggle (persisted), Quit.
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
* Feeds (all kqueue/notification driven, no polling): `/Volumes/SidePulse/LEDS.LED`
  when the strip is mounted, else `~/.local/state/sidepulse/agent-monitor/screen-bar.led`
  (may not exist yet), else a built-in breath. Every program goes through the
  presentation-safety compiler before it is shown; refused programs keep the
  previous one and are named in the menu's feed line.

## Stubbed or deliberately deferred

* No daemon protocol yet; the file feeds above stand in for it.
* The aggregate state is a simple reduction of `latest.json` (needs input >
  failed > working > done-within-90 s > idle); the Python attention model with
  its signals, quotas and presentation hints is not ported.
* Alcove coexistence, notch silhouette measurement, announcer pill, standing
  gauges, wings-only bracket, reduce-motion handling: not ported.
* The `wrapMenuBar` choice is a constant (`ScreenBarController.wrapMenuBar`),
  not a setting.
* The icon is a programmatic placeholder.
