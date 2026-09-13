# Toys

Toys are the things in JR-Bar that are fun first. They don't track agents
and they don't manage usage. They live in one Settings page ("Toys") so the
rest of the app stays serious, and each one can be turned off without
touching anything else.

This document is the contract every toy is built against. It is written
before the code; the code follows it.

## Where toys live

- Settings sidebar page `.toys`, title "Toys", symbol `party.popper.fill`,
  tint a warm magenta (`Color(red: 0.93, green: 0.30, blue: 0.62)`), placed
  right after Lighting and before Notifications & Focus.
- Page header: the JR monogram (`JRMonogram` view, drawn in SwiftUI, no
  asset: the letters "JR" set tight in the page tint's rounded square, 44pt)
  beside a one-line intro in Jonathan's voice. No paragraphs of preamble.
- Below the header, one `ToyCard` per toy, in this order: Fold, Aquarium,
  Notch Buddy, Confetti, Screen Bar Screensaver, Alcove, then the external
  app rows, then an "Add an app…" button.

## Persistence

App-side toys persist in `AppState` (`~/.local/state/jrbar/app-state.json`),
never `UserDefaults` (cfprefsd refuses writes on the owner's Mac; see
`AppState.swift`). `AppState` gains one field:

```swift
public var toys: ToysState   // default ToysState()
```

`ToysState` is `Codable, Equatable, Sendable` with tolerant decoding
(missing/mistyped keys fall back to defaults, unknown keys ignored), in
`app/Sources/JRBarCore/ToysState.swift`:

```swift
public struct ToysState {
    public var fold: FoldSettings
    public var aquarium: AquariumSettings
    public var notchBuddy: NotchBuddySettings
    public var confetti: ConfettiSettings
    public var externalApps: [ExternalToyApp]
}
public struct FoldSettings { enabled: Bool = false; activationAngle: Double = 82; style: FoldStyle = .dusk;
                             perspective: Double = 0.6; blur: Double = 0.5; shade: Double = 0.4;
                             jitterTolerance: Double = 0; provider: FoldProvider = .jrbar }
public enum FoldStyle: String { case tilt, dusk, fog }          // perspective only / + darken / + blur
public enum FoldProvider: String { case jrbar, bendy, lidPlane }  // who renders the fold
public struct AquariumSettings { enabled: Bool = false; showLabels: Bool = true; density: Double = 1.0 }
public struct NotchBuddySettings { enabled: Bool = false; character: String = "dot" }
public struct ConfettiSettings { enabled: Bool = false }
public struct ExternalToyApp: Identifiable { id: String /* bundle id */; name: String; launchWithJRBar: Bool }
```

Daemon-side toys (Screen Bar Screensaver) persist in the daemon's settings
document like every other setting, through `set_setting`.

## The `Toy` shape

Every toy card renders from one small protocol so the page never special-
cases a toy:

```swift
@MainActor protocol Toy: AnyObject, Observable {
    var id: String { get }                 // "fold", "aquarium", …
    var name: String { get }
    var blurb: String { get }              // one line, Jonathan's voice
    var symbol: String { get }             // SF Symbol
    var isOn: Bool { get set }
    var status: ToyStatus { get }          // what the chip says
    @ViewBuilder var controls: AnyView { get }   // the card's disclosure body
}
enum ToyStatus: Equatable { case off, on, paused(String), needsPermission(String), external(String), unavailable(String) }
```

`ToyCard` shows: symbol tile in the page tint, name, blurb, status chip,
toggle, and a disclosure with `controls`. Status copy is a fact, never a
promise ("Needs Screen Recording", "Paused: lid closed", "Bendy is
rendering it", "No lid-angle sensor on this Mac").

`ToysStore` (`@Observable`, app target) owns the toy objects, reads/writes
`AppState.toys`, and is created once in `AppDelegate` next to
`SettingsStore`. `SettingsStore` gets `weak var toys: ToysStore?` so the
page can reach it.

## Fold (native)

Your desktop tilts, dims and blurs as the lid comes down, like it's holding
its angle in the room while the screen moves. Clean-room; no Lid Plane
(GPL-3) or Bendy code.

- **Sensor** `LidAngleSensor` (`JRBarApp/Toys/Fold/LidAngleSensor.swift`):
  IOKit HID, match usage page `0x20` (Sensor), usage `0x8A` (Orientation),
  vendor `0x05AC`, product `0x8104`. Read feature report ID 1; bytes 1–2
  little-endian UInt16 are degrees. Poll at 30 Hz only while Fold is on
  and the display is eligible; otherwise no timer. Missing device →
  `status = .unavailable("No lid-angle sensor on this Mac")` and the
  Simulate slider still works.
- **Capture** `FoldCapture`: ScreenCaptureKit on the built-in display
  (`CGDisplayIsBuiltin`), `SCContentFilter(display:excludingApplications:)`
  excluding JR-Bar itself; 30 fps; BGRA sRGB; no audio, no cursor;
  complete frames only; capped at 2560 px on the long edge. The stream
  stays alive across the activation line — only the overlay hides — so
  re-entering a fold never pays a capture restart. Permission via
  `CGPreflightScreenCaptureAccess()`; request with
  `CGRequestScreenCaptureAccess()`; deep link
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
  Denied → `.needsPermission("Needs Screen Recording")` and nothing else
  runs.
- **Render** `FoldOverlayWindow` + `FoldRenderer`: borderless `NSWindow`,
  `.screenSaver` level, `ignoresMouseEvents = true`,
  `sharingType = .none`, covers the built-in screen only, `MTKView` with
  one Metal pipeline. The fragment shader treats the captured desktop as
  a rigid plane still standing at the anchor angle: each pixel projects
  back onto that plane — parallel projection, blended toward a finite-eye
  perspective by `perspective` — so at delta 0 the render is
  pixel-identical and activating is invisible. `delta` is radians past
  the anchor (`(activation − angle)·π/180`, clamped −0.65…1.25), eased
  with an ~80 ms exponential filter on a `CADisplayLink` at the screen's
  own refresh — the 30 Hz sensor moves the target, the vsync moves the
  fold. While the overlay is up the `MTKView` free-runs at
  `preferredFramesPerSecond`; ordered out, it is paused. Blur is a
  4-level MPS Gaussian pyramid baked once per frame, mixed by a radius
  that grows toward the far edge (`smoothstep(0.08,1,h)·|sin δ|·65`,
  scaled by `blur`); the image boundary feathers out over the blur radius
  into a dark surround; `shade` dims toward the top (Dusk, Fog). Tilt =
  projection only. The overlay is ordered out whenever `|delta| ≤ 0.002`
  or no frame has landed, so at rest nothing runs.
- **Safety**: pause (hide overlay, stop capture, keep sensor) when the
  lid reads ≤ 5°, when `AppleClamshellState` on `IOPMrootDomain` says
  closed — the daemon's `closed_lid.holding` is the keep-awake
  assertion, NOT lid state — when the built-in display is missing or
  mirrored, on screen sleep; resume 0.5 s after all clear. The
  activation gate reads the raw angle so a jitter-suppressed sample can
  never hold the overlay open. Never pick an external display. Reduce
  Motion: the fold still follows the lid (it's a function of angle, not
  an animation) but the blur pass is skipped.
- **Swap**: `FoldProvider.bendy` / `.lidPlane`: detect via
  `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` (Lid Plane's
  bundle id is in its repo `Info.plist`; Bendy's is read from
  `/Applications/Bendy.app/Contents/Info.plist` when present, else offer
  the storefront link). Choosing an external provider stops our renderer,
  launches that app, and the chip reads "Bendy is rendering it". When the
  chosen app isn't installed the picker row says so and links to it.
- **Controls**: On/Off, Style (Tilt / Dusk / Fog segmented), Activation
  angle slider 60–160°, Perspective / Blur / Shade sliders, Jitter
  tolerance 0–5°, "Simulate a fold" slider (drives the angle while held),
  live angle readout ("104°" or "no sensor"), Render with (JR-Bar / Bendy /
  Lid Plane).

## Aquarium (native)

Every live session is a fish — a real one: tapered body, dorsal &
pectoral fins, a translucent tail that articulates, a gill line, a
lateral highlight and a proper eye, in the provider's colour with the
session label in a small dark chip under it. The tank has depth: a lit
gradient warming toward the surface, three slow god rays, a caustic
shimmer band under the surface line, plankton in two parallax layers,
ambient bubbles, a dune floor and a soft bottom-corner vignette.
Deeper lanes hold smaller, dimmer, slower fish. Fish ease into curved
U-turns at the glass instead of mirror-flipping, and new sessions swim
in from an edge; a recently updated session's tail beats faster. An
ask rises to the surface trailing small bubbles and bobs there with a
bubble riding overhead; a failed session goes grey, sinks nose-down
onto the sand and settles with a slow rocking; a completion drifts off
the right edge. The tank is a resizable window
(`AquariumWindowController`), `TimelineView(.animation)` capped at 30
fps + `Canvas`, reads `core.sessions` only, and stops its timeline
while occluded. Controls: On/Off (opens/closes the window), Show
labels, Density (how much plankton/bubbles), "Fill screen" button
(borderless full-screen, Esc leaves). Reduce Motion: rays & shimmer
hold still, tails don't wag, fish glide — poses stay.

## Notch Buddy (native)

A tiny creature in the `NotchHUD` panel that lives by the agent state:
asleep when nothing runs, paces while sessions work, waves (and turns
amber) when an ask is open, slumps when something failed, does one hop on
a completion. Drawn in SwiftUI shapes, one character to start ("dot"),
with the enum left open.

It's a soft blob body, two pupils under lids, a small mouth and a ground
shadow — at 18pt the silhouette does the work, so the craft lives in the
animation. Pacing is an eased walk with a per-step bob and a pause at
each end where the eyes turn before the body follows. The wave and the
hop both crouch first, stretch on the way up and land flat; the ask pops
a "!" once and the hop throws two sparkles near its apex. Sleeping
breathes and drifts "z"s; slumping droops half-lidded and keeps slowly
deflating. Every awake mood blinks on a jittered ~2.5–6s cadence. While
it paces it wears the working provider's accent when one provider owns
the work (`ProviderStyle.style(for:).accent`); ask stays amber, failed
red, the hop green.

It must never cover the HUD's toasts: when a toast shows, the buddy
steps aside. Reduce Motion swaps the moving poses for still ones (the
blink stays — a shut-eye frame is a pose too). Off by default.

## Confetti (native)

When a provider's **weekly** quota resets, a confetti cannon pops at the
notch/Screen Bar centre: a flash & starburst at the muzzle, then ~140
pieces in that provider's colours burst up & out in a cone (a few fired
sideways, like spray), arc under gravity & quadratic air drag, and
tumble down the band — cards twinkle (a scaleX oscillation standing in
for a spin about the vertical axis), streamers corkscrew — easing out
near the bottom edge over ~2.6 s in a transparent, click-through overlay
window, then the window closes. Pieces are rects, dots & long thin
streamers; the palette is the provider colour in light & dark steps plus
white & a few gold flecks. Motion is closed-form (`ConfettiPhysics`);
piece constants are fixed at fire time. The trigger is the daemon's
`quota_reset` event where `lane == "weekly"` or `lane` ends in `-weekly`
(docs/CORE-PROTOCOL.md); five-hour and session resets do not fire. Hooks
into `EventCoordinator.apply` via `ToysStore.confetti.fire(providerColor:)`.
A "Test burst" button in the card fires one on demand. Honors Reduce
Motion (a gentle radial bloom of the provider colour at the notch
instead). Off by default. `ConfettiSettings { enabled: Bool = false }`
(the `onCompletion`/`onMilestone` fields are dropped).

Blurb: "A burst in the provider's colours when your weekly limit resets."

## Screen Bar Screensaver (daemon)

Instead of only going dark after a long idle, the strip and Screen Bar can
play a chosen effect from the library. Settings keys (schema-visible,
`set_setting`, tolerant decode, Swift `SettingsKey` rows in `.lighting`):

- `idle_screensaver_enabled: bool = false`
- `idle_screensaver_effect: str | None = None` (an effect id from the
  registry; unknown id → fail closed, nothing plays)
- `idle_screensaver_after_minutes: int = 20` (5–1440)

Runtime: in `ambient_effect_runtime`, when idle exceeds the threshold,
no ask/working/failed signal owns the strip, DND admits it, and the toy is
enabled with a valid effect, plan that effect as an ambient owner; any
real signal preempts it immediately; it never runs inside the night scene
unless `rainstick_night_enabled` is on (same consent as rainstick). The
existing `idle_auto_off` still wins when it fires later. The card shows a
picker of effects (from `list_effects`), the picked effect playing live
in a `LEDStripPreview` band (the catalog's own `preview.program`, so the
band is what the bar will play; no program in the catalog → no row, the
picker still stands), the delay slider, a "Play it now" peek button, and
the live "playing / peeking / waiting (idle 3m of 20m) / off" fact.

The peek is the `screensaver_peek` core command (docs/CORE-PROTOCOL.md):
the daemon arms a ~9 s window during which each observation batch stages
the picked effect through the same IDLE-candidate seam — the toggle and
the delay do not gate an explicit preview, but admission, Reduce Motion
and every live semantic still do — and the batch after the window retires
it. While a peek owns the surfaces the fact reads `"peeking"`; the button
disables as "Playing…" while `state` is `peeking` or `playing`.

## Alcove (bridge)

Alcove is Henrik's notch app; JR-Bar already follows its capsule. The
card makes that visible: installed? running? (bundle
`com.henrikruscon.Alcove`), the existing `screen_bar_follow_alcove`
toggle, the capsule width the follower currently sees ("following: 312 pt
wide" / "Alcove isn't running"), and Open Alcove / Get Alcove buttons.

## External app toys

"Add an app…" opens an `NSOpenPanel` on `/Applications` for `.app`
bundles. Each row: app icon (`NSWorkspace.shared.icon(forFile:)`), name,
running dot, Launch / Quit, "Launch with JR-Bar" toggle (JR-Bar opens it
at its own launch if not running), Remove. Identity is the bundle id;
a removed or missing app shows "not installed" and Remove.

## Copy

Every string on the page is in Jonathan's voice (see the jr-writing
skill): plain, short, a bit informal, `&` is fine, no em dashes, no
marketing words. Examples:

- Page intro: "Stuff that's just fun. None of it touches your agents or
  your usage, & every bit of it can be turned off."
- Fold blurb: "Your desktop tilts & blurs as the lid comes down."
- Aquarium blurb: "Every session is a fish. Asks come up for air."
- Notch Buddy blurb: "A little guy in the notch who lives by what your
  agents are doing."
- Confetti blurb: "A burst in the provider's colours when your weekly
  limit resets."
- Screensaver blurb: "When you've been gone a while, the bar plays
  something instead of just going dark."
- Alcove blurb: "JR-Bar already follows Alcove's capsule. This is where
  you can see it doing that."

## Tests

- `ToysState` decode/encode round trip and tolerant decode
  (`JRBarCoreTests/ToysStateTests.swift`).
- Fold math: `foldAmount(angle:activation:)` clamps, jitter filter
  accepts/rejects, pause predicate on each safety input (pure functions
  in `JRBarCore/FoldMath.swift`, tests in `FoldMathTests.swift`).
- Aquarium: session → fish state reducer (`AquariumModel.swift` in
  JRBarCore, pure), tests for ask/failed/completed transitions.
- Screensaver: Python tests for the settings keys, the ambient runtime
  admission (idle threshold, preemption, night consent, unknown effect
  fails closed), and the mock-core document.
