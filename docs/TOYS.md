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
  Notch Buddy, Confetti, Alcove, then the external app rows, then an
  "Add an app…" button.

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
  little-endian UInt16 are degrees. Every HID touch runs on a serial
  queue (`SensorPump`) — a feature report is a kernel call and a hung
  one must never stall the main runloop — and the poll rate adapts:
  10 Hz above the arming band (`activation + 12°`), 60 Hz inside it,
  120 Hz while the lid is actually swinging (instantaneous velocity
  < −6°/s kicks it within a beat or two). The same queue re-reads
  `AppleClamshellState` once a second and rides it out on each
  `Sample{angle, at, clamshell}` so no per-frame path ever touches IOKit.
  Missing device → `status = .unavailable("No lid-angle sensor on this Mac")`
  and the Simulate slider still works.
- **Motion** `AlphaBeta` (`JRBarCore/FoldMath.swift`): an α–β predictor
  fed on accepted samples. While the lid moves, `renderAngle` leads the
  measurement by ~60 ms of predicted travel, clamped to ±8° — that lead
  is what hides the sensor→capture→display latency, the difference
  between the fold following your finger and trailing it. Residuals are
  dt-normalized so a poll-rate change can't mistune the gain, a
  > 1200°/s miss snaps instead of chasing, a reversal zeroes the lead,
  and 0.2 s of confirmed stillness freezes it: parked, the render angle
  IS the measurement, so a resting fold never drifts. `velocity` (deg/s,
  smoothed) feeds the motion blur and decays to rest if the feed goes
  stale. The eased `displayedTurn` chases the target on a
  `CADisplayLink` at the screen's own refresh with follow ≈ 16 (~62 ms
  time constant).
- **Gesture** `FoldMath.normalizedTurn`: the fold is a bounded 0…1 arc
  from `activationAngle` down to `foldEndAngle` (8°, just above the
  5° closed-lid pause), not an unbounded tilt. At 0 the shader is the
  identity — activating is invisible; at 1 the arc completes as the lid
  shuts. The activation gate reads the raw angle so a predicted lead
  can never open the overlay early, and a jitter-suppressed sample can
  never hold it open.
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
  `sharingType = .none`, covers the built-in screen only, `MTKView`
  (`framebufferOnly`, capped at `min(120, screen.maximumFramesPerSecond)`)
  with one Metal pipeline. Each frame blits into a private mipmapped
  texture (3 levels, `generateMipmaps` on the GPU — no CPU decode), so
  the matte blur reads real LODs. The fragment shader treats the
  captured desktop as a rigid plane still standing at its angle: a
  bounded projection (`bend = turn^1.18 · 48°`) blends an orthographic
  hold into a finite-eye keystone by `perspective`. The matte is a
  Vogel-disc (golden-angle spiral, area-uniform rings, per-pixel phase
  jitter) whose radius grows toward the far edge and with the gesture,
  plus a velocity boost (`|v| > 30°/s`, ≤ 12) so fast closes smear like
  real glass; the disc adapts 12/20/32 taps by turn. A glass term dims
  the tilted panel, a sheen band and a hinge seam catch the light, the
  void fades in beyond the far edge (Dusk, Fog), and the last tenth of
  the arc finishes to near-black — a full close reads as the display
  switching off, not the image vanishing. Where the projection leaves
  the image there is only void, feathered over a few pixels. Tilt =
  projection only; Dusk = dim + a light matte; Fog = dim + the deep
  matte. The overlay is ordered out whenever `turn ≤ 0.002` or no frame
  has landed, so at rest nothing runs.
- **Safety**: pause (hide overlay, stop capture, keep sensor) when the
  lid reads ≤ 5°, when `AppleClamshellState` on `IOPMrootDomain` says
  closed — the daemon's `closed_lid.holding` is the keep-awake
  assertion, NOT lid state, and it arrives cached on the sensor's 1 Hz
  beat — when the built-in display is missing or mirrored (cached,
  refreshed on the screen-parameters notification plus a 2 s backstop),
  or on screen sleep; resume 0.5 s after all clear. Never pick an
  external display. Reduce Motion: the fold still follows the lid (it's
  a function of angle, not an animation) but the blur disc and the
  velocity boost are skipped.
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

Every live session is a fish — and the provider picks the species.
Claude swims as a clownfish (bold white bars, rounded fins), codex &
grok as sleek sharks, gemini as a tall angelfish with trailing fins,
antigravity & openclaw as spotted puffers, hermes as an upright
seahorse, opencode/kiro/t3code as flowing-finned bettas, devin as a
tang, cursor & pi as little tetras; anything new is a minnow
(`FishSpecies` in `AquariumModel.swift`, so the mapping is testable).
Each fish keeps its tapered body, translucent tail that articulates,
gill line and a proper eye, in the provider's colour with the session
label in a small dark chip under it.

Sub-agent sessions join as fry — about half size, the school's
species — orbiting loosely around their parent's fish, up to eight a
school (extra workers merge visually rather than crowding the tank).
A worker whose parent isn't listed drifts to the largest
same-provider fish, or free-swims when there isn't one. Fry carry no
labels or status bubbles; a failed worker just fades & sinks a
little, and a parent that sinks or drifts off takes its whole school
with it.

The tank is dressed like a real one: a seeded set from
`AquariumModel.decorSet` — swaying kelp strands in front of & behind
the fish, pebble clusters, a coral branch or two, a starfish, and a
treasure chest that burps the occasional bubble — so the layout is
the same every launch. A jellyfish pulses through the mid-water every
~40 s and a snail inches along the sand. Behind it all: a lit
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
fps + `Canvas`, reads `core.state.sessions` (mains AND workers), and
stops its timeline while occluded. Controls: On/Off (opens/closes the
window), Show labels, Density (how much plankton/bubbles/decor), "Fill
screen" button (borderless full-screen, Esc leaves). Reduce Motion:
rays, shimmer & kelp hold still, tails don't wag, the jellyfish &
snail freeze — poses stay.

## Notch Buddy (native)

A tiny creature in the `NotchHUD` panel that lives by the agent state:
asleep under a flopped nightcap when nothing runs, paces while sessions
work, bounces in place when three or more work at once (a gathering —
busy is exciting, not calm), waves amber when an ask is open, tumbles
into a slump when something failed, does one hop on a completion. Drawn
in SwiftUI shapes, one character to start ("dot"), with the enum left
open.

It's a soft blob body, two pupils under lids, a small mouth and a ground
shadow — at 18pt the silhouette does the work, so the craft lives in the
animation. Pacing is an eased walk with a per-step bob and a pause at
each end where the eyes turn before the body follows; the gathering
trades the walk for quick happy micro-hops in place. The wave and the
hop both crouch first, stretch on the way up and land flat. Asks
alternate deterministically: odd asks wave with a popped "!", even asks
just lean in holding eye contact — wide pupils, a slight loom, no bang.
The hop throws a sparkle on one side and pops a small green check on the
other. Sleeping breathes, droops the nightcap's tip on a lag, and drifts
"z"s; a failure rolls in on its side, catches its balance, and settles
into the half-lidded slump that keeps slowly deflating. Every awake mood
blinks on a jittered ~2.5–6s cadence. While it paces or gathers it wears
the working provider's accent when one provider owns the work
(`ProviderStyle.style(for:).accent`); ask stays amber, failed red, the
hop green.

It must never cover the HUD's toasts: when a toast shows, the buddy
steps aside. Reduce Motion swaps the moving poses for still ones (the
blink stays — a shut-eye frame is a pose too). Off by default.

## Confetti (native)

When a provider's **weekly** quota resets, a confetti cannon pops at the
notch/Screen Bar centre: a flash & starburst at the muzzle with three
hot spark streaks inside the cone's first 0.15 s, then ~140 pieces in
that provider's colours burst up & out in a cone (a few fired sideways,
like spray), arc under gravity & quadratic air drag, and tumble down the
band — cards twinkle (a scaleX oscillation standing in for a spin about
the vertical axis), streamers corkscrew, ~8% are tiny provider glyph
flecks (rounded diamonds & pac-dots, 3–4pt, spinning on their axis in
the provider colour or a pale step of it). A couple of streamers drag a
faint colour streak for their first 0.3 s. Streamers that reach the
bottom of the band get one small squash-bounce and rest there as litter
until the window fades; cards & dots still ease out near the bottom
edge. It all plays over ~2.6 s in a transparent, click-through overlay
window, then the window closes. Motion is closed-form
(`ConfettiPhysics`, including `fallTime` — the inverse fall — and
`floorBounce`); piece constants are fixed at fire time. The trigger is
the daemon's `quota_reset` event where `lane == "weekly"` or `lane` ends
in `-weekly` (docs/CORE-PROTOCOL.md); five-hour and session resets do
not fire. Hooks into `EventCoordinator.apply` via
`ToysStore.confetti.fire(providerColor:)`. A "Test burst" button in the
card fires one on demand. Honors Reduce Motion (a gentle radial bloom of
the provider colour at the notch instead). Off by default.
`ConfettiSettings { enabled: Bool = false }` (the
`onCompletion`/`onMilestone` fields are dropped).

Blurb: "A burst in the provider's colours when your weekly limit resets."

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
