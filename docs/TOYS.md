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
public struct FoldSettings { enabled: Bool = false; activationAngle: Double = 110; style: FoldStyle = .tilt;
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
  (`CGDisplayIsBuiltin`), `SCContentFilter(display:excludingWindows:)`
  excluding the overlay window(s); 30 fps; no audio. Permission via
  `CGPreflightScreenCaptureAccess()`; request with
  `CGRequestScreenCaptureAccess()`; deep link
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
  Denied → `.needsPermission("Needs Screen Recording")` and nothing else
  runs.
- **Render** `FoldOverlayWindow`: borderless `NSWindow`, `.screenSaver`
  level, `ignoresMouseEvents = true`, `sharingType = .none`, covers the
  built-in screen only, `MTKView` with one Metal pipeline. Fragment shader
  takes `fold ∈ [0,1]` (0 at/above activation angle, 1 at 40° below it,
  clamped) and the three style weights, and does: perspective warp about
  the hinge (bottom) edge scaled by `perspective`; darken toward the top by
  `shade` (Dusk, Fog); separable blur whose radius grows toward the top by
  `blur` (Fog). Tilt = perspective only. The overlay is hidden entirely
  when `fold == 0`, so at rest nothing runs.
- **Safety**: pause (hide overlay, stop capture, keep sensor) when the
  lid reads ≤ 5°, when `core.state.power.closedLid` says closed, when the
  built-in display is missing or mirrored, on screen sleep; resume 0.5 s
  after all clear. Never pick an external display. Reduce Motion: the
  fold still follows the lid (it's a function of angle, not an animation)
  but the blur pass is skipped.
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

Every live session is a fish. Provider colour, session label under it,
swims left-right at its own pace. An ask brings the fish to the surface
where it bobs with a small bubble; a failed session goes grey and sinks;
a completion drifts off the edge. The tank is a resizable window
(`AquariumWindowController`), `TimelineView(.animation)` + `Canvas`,
reads `core.sessions` only, and stops its timeline when hidden. Controls:
On/Off (opens/closes the window), Show labels, Density (how much
plankton/bubbles), "Fill screen" button (borderless full-screen, Esc
leaves). Reduce Motion: fish glide without tail wag.

## Notch Buddy (native)

A tiny creature in the `NotchHUD` panel that lives by the agent state:
asleep when nothing runs, paces while sessions work, waves (and turns
amber) when an ask is open, slumps when something failed, does one hop on
a completion. Drawn in SwiftUI shapes, one character to start ("dot"),
with the enum left open. It must never cover the HUD's toasts: when a
toast shows, the buddy steps aside. Off by default.

## Confetti (native)

When a provider's **weekly** quota resets, a short burst of confetti in
that provider's colours falls from the notch/Screen Bar area over ~1.5 s
in a transparent, click-through overlay window, then the window closes.
The trigger is the daemon's `quota_reset` event where `lane == "weekly"`
or `lane` ends in `-weekly` (docs/CORE-PROTOCOL.md); five-hour and
session resets do not fire. Hooks into `EventCoordinator.apply` via
`ToysStore.confetti.fire(providerColor:)`. A "Test burst" button in the
card fires one on demand. Honors Reduce Motion (a single soft flash
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
picker of effects (from `list_effects`), the delay slider, and the live
"playing / waiting (idle 3m of 20m) / off" fact.

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
