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
public struct NotchBuddySettings { enabled: Bool = false; character: String = "dot";
                                   buddyName: String = ""; care: BuddyCare;
                                   freePosition: BuddySpot?; tucked: Bool = false;
                                   showCaption: Bool = true; scale: Double = 1.0 /* 1…3, floating only */ }
public struct BuddySpot { x: Double; y: Double }                    // parked screen point
public enum BuddyCharacter: String { case dot, cat, ghost, robot, owl, slime,
                                     axolotl, crab, mushroom, ufo }
public struct BuddyCare { lastInteractionAt: Date?; petCount: Int; treatsGiven: Int; crumbsEaten: Int }
public struct ConfettiSettings { enabled: Bool = false; landing: ConfettiLanding = .rest;
                                 density: Double = 1.0; duration: Double = 1.0;
                                 palette: ConfettiPalette = .provider; shapes: ConfettiShapes = .mixed;
                                 triggers: ConfettiTriggers; firedKeys: [String] /* dedup ring, 64 deep */ }
public struct ConfettiTriggers { sessionCompleted: Bool = false; weeklyReset: Bool = true;
                                 perProviderReset: Set<String> /* provider ids, lowercase */;
                                 codexBankedReset: Bool = false; allClear: Bool = false }
public enum ConfettiLanding: String { case rest, fall, fade }   // rest on the band / rain to the bottom / dissolve mid-air
public enum ConfettiPalette: String { case provider, toys, rainbow }
public enum ConfettiShapes: String { case mixed, streamers, flecks }
public struct AlcoveSettings { enabled: Bool = false; provider: AlcoveProvider = .jrbar;
                               islandEnabled: Bool = true; showUsage: Bool = true;
                               expandOnHover: Bool = true; capsuleNotifications: Bool = true;
                               mediaEnabled: Bool = true; capsuleKinds: AlcoveCapsuleKinds }
public struct AlcoveCapsuleKinds { ask: Bool = true; completed: Bool = true;
                                   failed: Bool = true; quotaReset: Bool = true;
                                   charging: Bool = true }
public enum AlcoveProvider: String { case jrbar, alcove, boringNotch }  // who owns the notch
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
  one must never stall the main runloop. Measured at 240 Hz, the report
  is a 10 Hz sensor: it changes value only every ~100 ms (integer
  degrees — 9–13° per update on a moderate close, dead steady at rest),
  and each read costs ~0.5 ms. So the poll runs at just two rates:
  10 Hz — the sensor's own cadence — above the arming band
  (`activation + 12°`), and 120 Hz inside it, where a dense poll
  timestamps each sensor edge to ±8 ms. The same queue re-reads
  `AppleClamshellState` once a second and rides it out on each
  `Sample{angle, at, clamshell}` so no per-frame path ever touches IOKit.
  Missing device → `status = .unavailable("No lid-angle sensor on this Mac")`
  and the Simulate slider still works.
- **Motion** `LidTracker` (`JRBarCore/FoldMath.swift`): edge dead
  reckoning, not a predictor — a 10 Hz stepping sensor has no
  poll-to-poll signal worth filtering. Only a changed reading is an
  edge: each edge re-anchors the position and updates a blended
  velocity (a reversal takes the new direction whole). `tick`, once per
  render frame, sets `renderAngle` to the edge plus that velocity
  extrapolated for at most 150 ms and clamped to ±8° — enough to cover
  the sensor's ~100 ms latency, bounded so a wrong estimate can't run
  away; after 0.3 s without an edge the lid is parked, velocity is zero
  and the render angle IS the measurement. The tracker itself smooths
  nothing — the eased `displayedDelta` is the one smoothing stage,
  chasing the target on a `CADisplayLink` at the screen's own refresh
  with an 80 ms time constant (`1 − exp(−dt/0.08)`), so at each edge the
  dead-reckoned position is already near the new value and the ease only
  absorbs the residual. `velocity` (deg/s) feeds the motion blur.
- **Gesture** `FoldMath.deltaRadians`: the fold is the real lid travel —
  `(activationAngle − angle)` in radians, clamped at 1.25 rad (~72°),
  the arc the projection is stable over. It is not a normalized
  gesture: the held plane counter-rotates by exactly what the hinge
  moved, which is what makes the desktop appear to stay put. At 0 the
  shader is the identity — activating is invisible. The activation gate
  reads the raw angle so an extrapolated lead can never open the overlay
  early, and a jitter-suppressed sample can never hold it open.
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
  the matte blur reads real LODs. The fragment shader is the physical
  model, nothing else painted: the desktop plane held at the activation
  angle, projected parallel (t = 1: pure `cos(delta)` compression, no
  taper) or through a finite eye at (0, 0.65, 1.6) screen heights —
  `perspective` blends the two. Blur and shade scale with
  `sin(delta)·height`: the matte is a Vogel-disc (golden-angle spiral,
  area-uniform rings, per-pixel phase jitter) whose radius grows toward
  the far edge with the real tilt, plus a velocity boost (`|v| > 30°/s`,
  ≤ 12) so fast closes smear like real glass; the disc adapts 12/20/32
  taps by the computed radius. The edge feather is the blur's own
  sigma, and where the projection leaves the image there is only void.
  Tilt = projection only; Dusk = dim + a light matte; Fog = dim + the
  deep matte. The overlay is ordered out whenever `delta ≤ 0.002` or no
  frame has landed, so at rest nothing runs.
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
Each fish keeps its tapered body, a translucent tail that articulates
a beat behind the head, swept dorsal and pectoral fins, a gill line,
a pale belly countershade and a proper eye with a catchlight, in the
provider's colour with the session label on a small floating tag
tethered under it.

Sub-agent sessions join as fry — about half size, the school's
species — orbiting loosely around their parent's fish, up to eight a
school (extra workers merge visually rather than crowding the tank).
A worker whose parent isn't listed drifts to the largest
same-provider fish, or free-swims when there isn't one. Fry carry no
labels or status bubbles; a failed worker just fades & sinks a
little, and a parent that sinks or drifts off takes its whole school
with it.

The tank is dressed like a real one: a seeded set from
`AquariumModel.decorSet` — clusters of broad ruffled kelp blades
swaying in a slow S behind the fish (narrow root, full translucent
mid-blade, lit margin) and two dark near-glass fronds drifting in
front for parallax, sea-grass tufts, shaded pebble piles, a coral
branch or a
grooved brain coral, scattered shells, a starfish, sometimes a sunken
bottle, and a treasure chest with brass bands that burps the
occasional bubble — so the layout is the same every launch. Every
piece sits on the dune line under a soft pooled shadow. A jellyfish
pulses through the mid-water every ~40 s (and stays on as the
resident drifter while the tank is empty, under a small quiet caption
low on the left) and a snail inches along the sand. Behind it all: a
multi-stop gradient from a bright green surface band to a deep
blue-green floor, five soft god rays breathing a couple of degrees
and pooling as wandering caustic light on the dune crest, a slow
sheen drift through the column, animated caustic bands and a bright
meniscus at the waterline, plankton motes in two parallax layers,
wobbling ambient bubbles off the chest and the sand, a dune floor of
overlapping rounded humps with a light-catching crest, faint ripple
contours down the face and seeded grains, a corner vignette and a
faint diagonal glass highlight.

Deeper lanes hold smaller, dimmer, slower fish. Fish ease into curved
U-turns at the glass instead of mirror-flipping, and new sessions swim
in from an edge; a recently updated session's tail beats faster. An
idle session holds midwater on a slow drift and rises to sip the
surface every half-minute or so. An ask rises to the glass — a little
closer to the viewer — trailing small bubbles, bobs there with a
bubble riding overhead, and pulses a soft glow ring off its nose like
a tap on the pane. A failed session goes grey, sinks nose-down onto
the sand, rolls onto its side for a beat, then fades. A completion
corkscrews up and out the top-right, dropping two or three food
pellets behind it: the nearest live fish dart over to eat them while a
gold star glints at the spot. Three or more finishes inside five
seconds pop the treasure chest in a fast bubble plume off its lid.
Hovering or tapping a fish floats a name tag above it — fry included,
which is how a worker's name shows. A slow day/night wash deepens the
water on a four-minute cycle. The tank is a resizable window
(`AquariumWindowController`) drawn in three passes: the still bed
(water, sand, every decor piece that doesn't sway) renders on a slow
tick into a `.drawingGroup` bitmap, an additive `Canvas` carries the
rays, caustic pools & sheen, and a `TimelineView(.animation)` capped
at 30 fps + `Canvas` draws only what moves — fish labels resolve once
and are cached. It reads `core.state.sessions` (mains AND workers) and
stops its timelines while occluded. Controls: On/Off (opens/closes the
window), Show labels, Density (how much plankton/bubbles/decor), "Fill
screen" button (borderless full-screen, Esc leaves). Reduce Motion:
rays, shimmer & kelp hold still, tails don't wag, the jellyfish &
snail freeze, and the sips, spirals, rings & bursts hold at a still
pose — poses stay.

## Notch Buddy (native)

A tiny creature in the `NotchHUD` panel that lives by the agent state:
asleep under a flopped nightcap when nothing runs, paces while sessions
work, bounces in place when three or more work at once (a gathering —
busy is exciting, not calm), waves amber when an ask is open, tumbles
into a slump when something failed, does one hop on a completion. Drawn
in SwiftUI shapes; `BuddyCharacter` is the roster — `dot`, `cat`,
`ghost`, `robot`, `owl`, `slime`, `axolotl`, `crab`, `mushroom`, `ufo`
— and every member shares the one
skeleton (pose, blink, effects) and differs only in the body. The card's
Character picker lists them by name over a live strip that paces each
one, tap-to-pick.

The bodies: Dot is the original soft blob, gradient-lit with eyes and
mouth punched through to the capsule. Cat adds ears that prick for asks
and flatten for the slump, whiskers, a tail that wags on the good moods
and flops out along the ground on a failure, and a ω mouth that drops
its tongue on the hop. Ghost is a translucent scalloped sheet that
hovers and never quite touches its shadow. Robot is brushed metal under
a glass visor — LED pixel eyes, a glowing LED mouth, a side antenna
whose lamp pulses while an ask is up, and a thrown gear where everyone
else throws a sparkle. Owl is all eyes: two huge discs whose pupils ride
the look amplified so they visibly track the "!", feather tufts that
prick like the cat's ears, wings that lift on the hop, a beak that parts
for the ask, and eyes that squint into happy arcs when it sleeps. Slime
is a gooey translucent drop whose tip wobbles on a lag after every
landing, melts wider in the slump, sheds a droplet off its crown at the
hop's apex, and carries a sheen up-left. Axolotl fans three pink gill
fronds off each cheek — they sway, droop in the slump and perk for
asks — over a wide soft head that never grew up. Crab carries its eyes
on stalks, walks its patrol sideways, and claps a pair of pincers while
an ask is up or a hop lands. Mushroom is a spotted cap on a pale stalk,
permanently drowsy — the lids ride heavier and the cap nods on its own
slow clock. UFO never lands: a metal disc with rim lights chasing, a
glass dome over a small green pilot whose almond eyes track and blink,
and a beam that brightens while an ask is up.

It's not just cute: while two or more sessions are working a pill badge
by its feet carries the count in the busiest provider's colour, an open
ask's "!" wears the count past one ("!2"), and hovering the buddy reads
the state back — "3 working · 1 waiting · Codex, Claude". All of it
comes from `core.sessions`; the daemon is never asked for more.

It is also a small pet. The pill takes taps while the buddy holds it
(toasts stay click-through): a tap counts as a pet and cycles a trick —
hop, spin, wave, blush — and while an ask is open the tap opens the
session doing the asking. The card can name it (blank keeps the
character's own name) and feed it ("Give treat" → hearts off the crown,
a hop, and a `fed` glow for a while); each completed session lands as a
crumb it "eats" with a "+1". A day without a pat droops it — the
`BuddyCare` log in `app-state.json` is the whole mechanism; `mood(at:)`
is the only read.

And it is not nailed to the notch. Click-hold past ~4pt on the pill
lifts it out of the slot — it dangles from the cursor, tipped toward
the travel direction with its feet up — and a drop parks it anywhere on
screen in its own little panel (`BuddyPanel`, a `NotchHUDPanel`
sibling: borderless, nonactivating, status-bar-level, mouse-accepting
so it stays draggable). The parked point persists as
`NotchBuddySettings.freePosition` and clamps back into the visible
frame on restore; a drop back on the notch slot, or the menu's "Dock at
the notch", sends it home. Toasts never fight it: docked, the buddy
still steps aside for a toast; parked, the toast keeps the notch panel
to itself. Right-click (or a long press) opens its menu — Pet it, Give
treat, Rename…, Change character →, Open the asking session while one
is up, Dock/Float free, Show caption, Tuck away. Tucked is a nap: off
the screen until the next session event or a card re-enable. Parked, it
can wear a quiet one-line caption naming what it is watching —
"Claude · rename-the-fish — working", or "… — waiting on you" — the
`BuddyFocus` pick: an open ask first, then failed, then the freshest
working session, a done row only when nothing live remains.

The floating pet is sizable: the card's Size slider sets
`NotchBuddySettings.scale` (1…3, default 1), which the free panel reads
as a `scaleEffect` on the 18pt figure — vector all the way down, so
strokes, eyes and the badge stay crisp — with padding, caption (up to
~11pt) and the capsule's corner radius growing with it. The panel
re-measures off the hosting view on every present, so the slider drags
the pet bigger live and a parked 3× buddy still clamps fully on-screen;
the docked pill ignores the dial entirely — the notch slot is fixed.

The skeleton is a soft body, two pupils under lids, a mouth and a ground
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

It must never cover the HUD's toasts: when a toast shows, a docked
buddy steps aside (a parked one has its own panel and is already out of
the way). Reduce Motion swaps the moving poses for still ones (the
blink stays — a shut-eye frame is a pose too) and the drag is a plain
carry: no dangle, no landing squash. Off by default.

## Confetti (native)

When a provider's **weekly** quota resets, a confetti cannon pops at the
notch/Screen Bar centre: a flash & starburst at the muzzle with three
hot spark streaks inside the cone's first 0.15 s, then ~140 pieces in
that provider's colours burst up & out in a cone (a few fired sideways,
like spray), arc under gravity & quadratic air drag, and tumble down —
cards twinkle (a scaleX oscillation standing in for a spin about the
vertical axis), streamers corkscrew, ~8% are tiny provider glyph flecks
(rounded diamonds & pac-dots, 3–4pt, spinning on their axis in the
provider colour or a pale step of it). A couple of streamers drag a
faint colour streak for their first 0.3 s. Every piece reads as paper:
a light face and a darker back that swap as the twirl flips it, a thin
lighter rim, a whisper of a shadow while it passes over the top strip,
and a slight stretch along its travel while it's still fast.

Where the pieces end up is the **Landing** setting: Rest (the default —
streamers that reach the bottom of the band get one small squash-bounce
and rest there as litter while cards & dots ease out near the edge),
Fall (the overlay spans the whole screen and pieces rain to the bottom
edge, fading over the last ~8% of the drop), or Fade (pieces dissolve
between 40% and 60% of the screen's height with a little shrink, and
never land). The window's frame follows the mode, and its life is
derived — the slowest piece's travel in that mode on that screen,
stretched by the Duration setting, plus a 0.4 s tail — so nothing is
ever vanished mid-air. The card also offers Palette (Provider / Toys
tint / Rainbow, a six-colour spectrum in the app's saturation range),
Shapes (Mixed / Streamers / Flecks), Density (0.5–2× the piece count)
and Duration (0.7–1.5× the timeline). Motion is closed-form
(`ConfettiPhysics`, including `fallTime` — the inverse fall — and
`floorBounce`); piece constants are fixed at fire time.

What earns a burst is the **Triggers** section, judged by
`ConfettiTriggerPolicy` in JRBarCore: a session completing
(`completed` events), any provider's weekly lane resetting
(`quota_reset` on a `weekly` / `*-weekly` lane — on by default),
picked providers' EVERY lane resetting (the five-hour window
included), Codex's banked-credit balance growing (a state edge the
daemon's `credits_remaining` exposes), or the last open ask clearing.
Event triggers dedup on `event:<id>` against the persisted `firedKeys`
ring (64 deep — a restart can't re-celebrate); state edges are folded
by `ConfettiEdgeTracker`, and the first document only seeds the
baseline, so nothing fires on facts older than the app. Events arrive
through `EventCoordinator.handle`, state documents through its
`trackState` observation loop; the burst's colour still comes from
`ProviderStyle` with the event's session fallback. A "Test burst"
button fires one on demand with the current settings. Honors Reduce
Motion (a gentle radial bloom at the notch instead, in every mode).
Off by default. `ConfettiSettings { enabled; landing; density;
duration; palette; shapes; triggers; firedKeys }` — every key decodes
tolerantly to the shipped look.

Blurb: "A burst in the provider's colours when the moment earns it."

## Alcove (notch island)

The notch island is JR-Bar's own Dynamic-Island-style capsule: a black
shape flush with the notch whose lip carries the working providers'
dots (plus amber for asks, red for failures) and a live count —
"3 working · 1 waiting" — breathing slowly while anything works.
Hover grows it into a card: live session rows in the panel's
precedence, then the providers' headline usage meters when `showUsage`
is on. The window (`AlcoveIslandWindow`) is a non-activating panel at
`statusBar` level — one step under the Screen Bar's `statusBar + 1`,
so while the band is up its LED strip draws across the island's dead
top zone instead of the island's black face covering it; the layout
adds `ledBandClearance` under the notch so the island's own content
sits below the band, and the bar's click-through window never steals a
hover. `sharingType = .none` so Fold's desktop capture never sees it,
and its frame is always exactly the drawn shape — nothing invisible
swallows a menu-bar click; while Fold's overlay is up, the island lets
clicks fall through it.

"Render with" picks who owns the notch, Fold-style: **JR-Bar** draws
the island itself (settings: Show the island, Grow on hover, Usage
meters), or an external app — **Alcove** (bundle
`com.henrikruscon.Alcove`, detected via `NSWorkspace`) or **Boring
Notch** (no pinnable bundle id — read off the app's own Info.plist in
/Applications or ~/Applications, the way `FoldToy.bendyURL` resolves
Bendy). Picking an external provider parks the island and opens the
app; the status chip tells the truth per provider — "rendering it"
only while it actually runs, "isn't installed" / "isn't running"
otherwise. The `screen_bar_follow_alcove` toggle and the capsule-width
fact live under the Alcove provider, where they're meaningful.
`AlcoveIsland` in JRBarCore owns the pure summary/meter/layout math;
`AlcoveIslandTests` covers it.

Three Alcove-parity behaviours ride the same window. **Event capsules**
(`capsuleNotifications`, per-kind switches in `capsuleKinds`): an
`ask_opened` / `completed` / `failed` / `quota_reset` event morphs the
island into a wide notice capsule — the kind's glyph and tint (amber
ask, green done, red failed, the provider's accent for a reset) over a
"Claude · rename-the-fish" / "needs you" line — for ~2.4 s, then the
island settles back. `AlcoveEventPolicy` shapes the notice and
`AlcoveCapsuleQueue` owns the pipeline — one showing, at most one
waiting (newest wins), a 30 s cooldown per kind+session, a 1.2 s
minimum gap — all pure and covered by `AlcoveEventsTests`; the toy only
runs the timers. A capsule outranks a closed card, but while the card
is open its rows already tell the story, so events then earn nothing;
a hover during a capsule still lands its expand when it steps down.
A fifth kind, `charging`, is synthesized locally: `AlcovePowerMonitor`
polls IOKit's power-source list every 5 s (only while the island is
shown and both capsule switches are on) and `AlcovePower.notice` turns
a real transition — charger in, on battery, fully charged — into a
bolt-tinted "Power · Charging · 84%" capsule. The first poll is a
baseline and percent drift never speaks.
**Now Playing** (`mediaEnabled`): while a track is up, the idle capsule
carries the artwork, "Title — Artist" and three visualizer bars
(animated only while actually playing — dressing, not a spectrum), and
the card gains a transport row. Since macOS 15.4 `mediaremoted`
refuses unentitled readers, so the data path is a child process:
`/usr/bin/perl` (a platform binary with the now-playing entitlement)
loads the embedded `jrbar_mediaremote` dylib — built once and shipped
as bytes in `AlcoveMediaAdapterAsset.swift` — which calls MediaRemote
inside that process and streams JSON lines (`AlcoveMediaAdapter`).
If the helper can't run, the in-process MediaRemote bridge covers the
older releases where reads were never gated, and Music's own
`com.apple.Music.playerInfo` payload fills in wherever it posts.
Transport commands go through `MRMediaRemoteSendCommand`, which was
never gated, and down the helper's stdin for good measure.
**Swipes**: a horizontal two-finger swipe on the capsule is
next/previous while media shows; a downward swipe dismisses the capsule
or folds the card — read off the hosting view's scroll phases,
normalised for the user's scroll-direction setting so it means the same
flick either way. Reduce Motion swaps the morph for a quiet crossfade;
a parked island holds no listener and runs no clock.

Blurb: "A notch island: who's working, up in the notch. Alcove or
Boring Notch can draw it instead."

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
  (`JRBarCoreTests/ToysStateTests.swift`). `BuddyCharacter` raw values
  decode and stay stable, unknown names resolve to Dot
  (`JRBarCoreTests/BuddyCharacterTests.swift`); the roster's pose render
  proof writes PNGs to `/tmp/buddy-proof`
  (`JRBarAppTests/BuddyRenderProofTests.swift`). The roaming half is
  pure and pinned too: `BuddyFocus` picks the watched session and
  `BuddyPlacement` owns the drag threshold, dangle tilt, screen clamp
  and dock-snap (`JRBarCoreTests/BuddyPresenceTests.swift`); the free
  spot's persist, tuck/wake, menu contents and drag bookkeeping live in
  `JRBarAppTests/BuddyRoamingTests.swift`.
- Fold math: `deltaRadians(angle:reference:)` clamps, jitter filter
  accepts/rejects, pause predicate on each safety input (pure functions
  in `JRBarCore/FoldMath.swift`, tests in `FoldMathTests.swift`).
- Aquarium: session → fish state reducer (`AquariumModel.swift` in
  JRBarCore, pure), tests for ask/failed/completed transitions.
