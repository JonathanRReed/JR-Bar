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
  Notch Buddy, Confetti. (Notch is a utility — it lives on the Utilities
  page. The external-app rows and "Add an app…" were removed entirely —
  the `externalApps` key in an old state file decodes as an ignored
  unknown key.)

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
    public var notch: NotchSettings       // also decodes the legacy `alcove` key
}
public struct FoldSettings { enabled: Bool = false; anchor: FoldAnchor = .angle;
                             activationAngle: Double = 65;
                             perspective: Double = 0.6; blur: Double = 0.5; shade: Double = 0.7;
                             jitterTolerance: Double = 1.5; provider: FoldProvider = .jrbar;
                             frost: Double = 0; holdPicture: Bool = true;
                             dwellTimeout: Double = 0; restoreSound: Bool = false }
// (the Tilt/Dusk/Fog style picker is retired — `style` is decoded only to
//  recognize old default sets for migration; nothing reads it)
public enum FoldProvider: String { case jrbar, bendy, lidPlane }  // who renders the fold
public enum FoldAnchor: String { case angle, movement }  // fixed angle, or wherever the lid rests
public enum DayNightMode: String { case realTime, cycle }  // the clock / the four-minute breathe
public struct AquariumSettings { enabled: Bool = false; showLabels: Bool = true; density: Double = 1.0;
                                 speciesOverrides: [String: String] = [:]  /* provider id → species */;
                                 dayNight: DayNightMode = .realTime }
public struct NotchBuddySettings { enabled: Bool = false; character: String = "dot";
                                   presentation: String = "character" /* or "mini" */;
                                   buddyName: String = ""; care: BuddyCare;
                                   freePosition: BuddySpot?; tucked: Bool = false;
                                   showCaption: Bool = true; scale: Double = 1.0 /* 1…3, floating only */ }
public struct BuddySpot { x: Double; y: Double }                    // parked screen point
public enum BuddyCharacter: String { case dot, cat, ghost, robot, owl, slime,
                                     axolotl, crab, mushroom, ufo }
public struct BuddyCare { lastInteractionAt: Double; lastTreatAt: Double; lastCrumbAt: Double;
                          /* epoch seconds; 0 = never */
                          petCount: Int; treatsGiven: Int; crumbsEaten: Int }
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
public struct NotchSettings { enabled: Bool = false; provider: NotchProvider = .jrbar;
                              islandEnabled: Bool = true; showUsage: Bool = true;
                              expandOnHover: Bool = true; capsuleNotifications: Bool = true;
                              mediaEnabled: Bool = true; capsuleKinds: AlcoveCapsuleKinds;
                              pullGestures: Bool = true; hapticTick: Bool = true;
                              mediaHUD: Bool = true; alerts: Bool = true;
                              soundEffects: Bool = true; weather: Bool = false;
                              weatherCity: String = ""; simulateNotch: Bool = false;
                              mirror: Bool = false; audioVisualizer: Bool = false;
                              replaceSystemHUD: Bool = false; shelfShakeToSummon: Bool = true }
public struct AlcoveCapsuleKinds { ask: Bool = true; completed: Bool = true;
                                   failed: Bool = true; quotaReset: Bool = true;
                                   charging: Bool = true }
public enum NotchProvider: String { case jrbar, alcove, boringNotch }   // who owns the notch
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

Closing the lid looks like the desktop continues *into* the display — a
portal, not a tilting picture: windows float as cards in a lit space, the
wallpaper recedes behind them, and the whole thing blurs, fogs and
dissolves toward the hinge. One style, "Portal" — the iPhone Duo read of
the gesture. Clean-room; no Lid Plane (GPL-3) or Bendy code.

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
  timestamps each sensor edge to ±8 ms. A shut lid (≤ 5° or clamshell)
  and any pause hold the parked 10 Hz, at utility QoS with a 15 ms
  leeway: the fold cannot draw there. A reopen steps back up when the
  reconcile that lifts the pause restores the band, as the 0.5 s resume
  quiet starts, so the band is back before the fold can draw. The same queue re-reads
  `AppleClamshellState` once a second and rides it out on each
  `Sample{angle, at, clamshell}` so no per-frame path ever touches IOKit.
  Missing device → `status = .unavailable("No lid-angle sensor on this Mac")`
  and the Simulate slider still works.
- **Motion** `SlewTracker` (`FoldPortal.swift`): a slew-limited
  critically-damped tracker — semi-implicit Euler, velocity hard-capped at
  `maxRate` 150°/s so a slammed lid glides shut in ~300 ms instead of
  lurching between the sensor's 10 Hz integer-degree samples. A crossing
  guard makes overshoot structurally impossible, an arrival epsilon snaps
  to the target so it can truly rest, and a `maxDt` clamp means a slept
  display is a stall, never a teleport. The tracker IS the motion — no
  second spring, no velocity smear; opening is the exact reverse.
  `DeltaChase` carries the retrace guarantee: instant while the target
  grows, a slew-limited unwind (3 rad/s — just over the tracker's own
  cap) when it drops, so a real opening is followed exactly and only a
  gate snap ever sees the easing. The same angle always draws the same
  image.
- **Gesture** `FoldMath.deltaRadians`: the fold is the real lid travel —
  `(activationAngle − angle)` in radians, clamped at 1.25 rad (~72°),
  the arc the projection is stable over. It is not a normalized
  gesture: the held plane counter-rotates by exactly what the hinge
  moved, which is what makes the desktop appear to stay put. At 0 the
  shader is the identity — activating is invisible. The activation gate
  reads the raw angle so an extrapolated lead can never open the overlay
  early, and a jitter-suppressed sample can never hold it open.
  `FoldAnchor` picks what the travel measures from: `angle` is the
  fixed `activationAngle`; `movement` is `MoveAnchor` — wherever the
  lid has rested ≥ 400 ms while flat becomes the reference, so the fold
  starts from wherever it was parked (delta is positive only; opening
  back through the anchor is 0). Parked mid-fold never re-seats — that
  would collapse a held fold — but the dwell pause re-seats it at the
  parked angle when it hands the desktop back. Movement mode arms the
  streams on the first move off the anchor and holds the delta at 0
  until the first complete frame — the warm-up keeps the room from
  opening black; the sensor idles at its own 10 Hz throughout since
  nothing consumes edge timestamps any more.
- **Capture** `FoldCapture`: TWO ScreenCaptureKit streams on the
  built-in display (`CGDisplayIsBuiltin`), 60 fps, BGRA sRGB, no audio,
  no cursor, complete frames only, capped at 2560 px: a near stream
  (`excludingApplications` JR-Bar itself) for the window cards, and a
  wallpaper-only stream (filter = `desktopWindows` + excluded apps +
  excluded windows — a static layer rate-limited to 2 fps) for the
  portal's far wall. Between them a `CGWindowList` poll (4 Hz, inside
  the arming band only) gives each window card its on-screen rect; cards
  crop their pixels out of the near frame and sort by front-to-back
  window order (`PortalDepth`). `FoldArming` owns the lifecycle: armed
  inside `activation + 12°` (`FoldArming.margin`) — or, in movement
  mode, from the first deviation off the `MoveAnchor` — disarmed 1°
  above the activation edge (`hysteresis`), a 2 s linger on disarm so
  lingering at the edge doesn't flap the purple indicator — outside the
  band everything is stopped and nothing is captured. Both SCStreams
  are stopped and released when the machine idles. Permission via
  `CGPreflightScreenCaptureAccess()`; request with
  `CGRequestScreenCaptureAccess()`; deep link
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
  Denied → `.needsPermission("Needs Screen Recording")` and nothing else
  runs.
- **Render** `FoldOverlayWindow` + `FoldRenderer` + `FoldPortalModel`:
  borderless `NSWindow`, `.screenSaver` level, `ignoresMouseEvents =
  true`, `sharingType = .none`, covers the built-in screen only, `MTKView`
  (`framebufferOnly`, capped at `min(120, screen.maximumFramesPerSecond)`)
  with the `FoldPortal` pipeline. The model is a room, not a picture:
  the wallpaper is the far wall, each window a card floating in front of
  it at a depth from its stacking order — nearer cards translate more
  with the tilt (`PortalDepth.parallax`), so the contents really do
  parallax as the lid moves. **Hold picture in place** (default on)
  counter-rotates the content plane by `delta · Perspective` — a fixed
  eye sees the desktop stay put while the physical glass tilts over it
  (the room's own fog/shade/dissolve still read the real delta); off
  keeps the picture glued to the lid. With the fold the space scales
  toward the
  hinge, the matte fog swallows the far end and the near end dissolves —
  `fade` per card, depth-driven `dissolve` on the wall — which is what
  makes it read as continuing into the display rather than a warped
  screenshot. One style; Perspective / Blur / Shade are its knobs —
  Perspective sweeps the eye from orthographic to close-up, Blur is the
  fog (Vogel-disc LOD reads off the GPU-mipped textures, radius per
  depth — distant layers soft first, never ghosted past frames), Shade
  is the room's darkness (0 = pure dissolve, 1 = near-black void). The
  overlay is ordered out whenever `delta ≤ 0.002` or no frame has
  landed, so at rest nothing runs.
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
- **Controls**: On/Off, Activation
  angle slider 60–160°, Perspective / Blur / Shade sliders (one style —
  the portal), Jitter
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
The fish are drawn chunky and cartooned (`AquariumFishArt` /
`CartoonFish`): fat rounded bodies, big glossy eyes with catchlights,
soft bellies, expressive fins — a toy's fish, not a field guide's.
Each keeps a translucent tail that articulates a beat behind the head,
swept dorsal and pectoral fins, a gill line, a pale belly countershade
and a proper eye with a catchlight, in the provider's colour with the
session label on a small floating tag tethered under it.

It's also a small idle game (`JRBarCore/AquariumGame.swift`, the
`GameStore` on `AquariumStore`): while sessions work, the tank earns
**pearls**; a completion drops a bonus. Lifetime pearls raise the
**tank level** (`AquariumProgression`), and the Shop's pricier shelves
unlock by tier as it climbs — the sheet shows the level, progress to
the next, and what each locked row wants. Pearls spend in the Shop
sheet on decor (kelp, coral, pebbles, shells, chests, jellyfish,
snail — plus a shipwreck, ruins, a volcano, driftwood, an anemone
bed, a bubble wall, a moon-jelly lamp, a statue, an amphora and a
coral garden), **pets** (a sea turtle, an octopus, a cleaner shrimp,
a tetra school, an axolotl, the occasional manta), hats and a second
wearables slot of **accessories** (sunglasses, a monocle, a top hat,
headphones, a bow tie, a scarf, and a tiny laptop that only shows
while its fish's session is working), alternate **substrates**
(white sand, black gravel), a **backdrop** wall or two, and five
more **themes** — dawn, kelp forest, abyss, sunset and blackwater —
alongside the original five. A day with a finished session keeps the
**streak**; a daily **goal** (three completions, ten feedings, ninety
work minutes or five collected pearls — a different chore each day)
pays fifteen pearls when met; sixteen **achievements** pay out once
each, from first pearl to tank level 9; and every ninety minutes or
so a **treasure chest** surfaces half-buried in the sand — three taps
dig it up for a payout. Patient work occasionally draws a **visitor**
across the back layer: two unbroken hours brings the whale, ten
completions in a day brings the diver, and a quota reset brings the
submarine. Big moments land as a small card top-right rather than the
quiet toast. Everything the game owns lives in
a separate `aquarium-save.json` (`AquariumSave`) — resetting settings
never wipes your tank — while the tank's own toggles stay in
`app-state.json` like every toy. Feeding is the active toy: tap to
drop pellets and the nearest fish dart over — and now and then a
tapped fish answers with a trick, a barrel roll or a blown bubble
ring. Nothing in the game ever
touches your agents.

Sessions stay fish. A fish you have raised to stage 1 or beyond keeps
swimming after its session leaves the roster — a **resident**, idling
midwater under its remembered name in its provider's species, up to
`AquariumRules.maxResidents` of them, best-raised first. Residents
carry no plan and no status bubble; feeding is the only thing that
nourishes them, and starvation still costs stages, so a tank left
alone for days quietly empties again. The name and provider are
remembered on the care record (`identify`) whenever the session is
listed; records from before the field stay nameless until their
session is seen again. A resident whose session returns is simply that
session's fish once more, same swim.

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
occasional bubble — so the layout is the same every launch. Owned
shop decor joins it at seeded `DecorSlot` positions spread across two
depth rows so nothing overlaps: the shipwreck, statue, columns,
amphora and volcano sit back behind the fish lane (the volcano's lava
glows and breathes embers after dark), while driftwood, the coral
garden, an anemone bed whose tentacles sway, a bubble wall's rising
curtain, a moon-jelly lamp pulsing every six seconds and the alien
beacon, just right of the castle, hold the front row — each pooled
under its own shadow on the dune line like the originals. Nothing
bought keeps its middle behind the castle's keep, so the volcano's
crater clears the round tower and the beacon's light stands in front
of the side tower. Bought pets swim their own errands on the mover pass:
the turtle glides midwater and climbs to sip the surface, the octopus
keeps house in the amphora (or a rock's lee) and crawls out every few
minutes, the cleaner shrimp hops aboard an idle fish every half a
minute or so, the tetra school orbits as one shared target, the pink
axolotl ambles the sand with waving gill frills, and the manta
crosses the back every few minutes as a wide dim shadow. Alternate
substrates recolour the whole bed — white sand brightens and
strengthens the caustics, black gravel darkens it and deepens the
fish shadows — and a bought backdrop (a coral-nubbed reef wall,
stacked boulders) draws behind everything. Every
piece sits on the dune line under a soft pooled shadow. A jellyfish
pulses through the mid-water every ~40 s (and stays on as the
resident drifter while the tank is empty, under a small quiet caption
low on the left) and a snail works the sand — it fetches pearls while
you watch and keeps its rounds while the window is closed, so dropped
pearls it has picked up land in the "while you were away" card on
reopen. Behind it all: a
multi-stop gradient from a bright green surface band to a deep
blue-green floor, five soft god rays breathing a couple of degrees
and pooling as wandering caustic light on the dune crest, a slow
sheen drift through the column, animated caustic bands and a bright
meniscus at the waterline, plankton motes in two parallax layers,
wobbling ambient bubbles off the chest and the sand, a dune floor of
overlapping rounded humps with a light-catching crest, faint ripple
contours down the face and seeded grains, a corner vignette and a
faint diagonal glass highlight.

Deeper lanes hold smaller, dimmer, slower fish. Movement is
steering-based (`AquariumSteering`): wander, arrive, seek-food and
flee compose into smooth paths — fish bank into turns instead of
pivoting, ease into curved U-turns at the glass instead of
mirror-flipping, and new sessions swim in from an edge; a recently updated session's tail beats faster. An
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
water — following the local clock by default (dark from nine to six,
dawn and dusk blending the edges, which is also when the volcano glows)
or breathing on the old four-minute cycle if you pick it. The tank is a resizable window
(`AquariumWindowController`) drawn in three passes: the still bed
(water, sand, every decor piece that doesn't sway) renders on a slow
tick into a `.drawingGroup` bitmap, an additive `Canvas` carries the
rays, caustic pools & sheen, and a `TimelineView(.animation)` capped
at 30 fps + `Canvas` draws only what moves — fish labels resolve once
and are cached. It reads `core.state.sessions` (mains AND workers) and
stops its timelines while occluded. Controls: see "The card" below.
Reduce Motion:
rays, shimmer & kelp hold still, tails don't wag, the jellyfish
freezes, the snail skips its walk and is simply at each pearl, the
manta and the visitors skip their pass (a queued
visitor is still marked seen and its caption tells the story), tapped
fish do no tricks, and the sips, spirals, rings & bursts hold at a
still pose — poses stay.

### The card

`AquariumControlsView` (`Toys/Aquarium/AquariumControls.swift`). The main
body is five rows:

- **In the tank** — a still swatch of the water and floor, and a fact
  line (fish, fry, pearls on the sand).
- **Look** — a menu of Classic plus every owned water, floor and back
  wall, each a checked pick (`useClassic` always works, so buying a
  theme is never a one-way door), and **Open the shop…**, which brings
  the tank up with its shop showing (`ToysStore.wantsAquariumShop`).
- **Labels** — Always (a chip under each main fish), On hover (only the
  name tag under the pointer — what "Show labels" off always really
  did), or Never (the selected fish still names itself).
- **Day & night** — the clock, the sun, **Follow Light & Dark** (eases
  over two seconds when macOS flips — the water, back wall and sand
  redraw quickly until it lands, so the whole tank dims together), the
  four-minute cycle, **Always day** or **Always night**.
- **Sound** — off by default. A plop when food lands, a gulp when a fish
  eats, a clink for a pearl or coin, a chime for a purchase or a reward
  card, a whoosh for a visitor (`AquariumSound`, synthesized, no asset).
  Only for a tap or a window event, only in the open, uncovered window,
  never on the wallpaper or the screensaver, at the Sounds page's
  volume. It stays quiet during a Focus, quiet hours or a call whether
  or not the Toys page hushes the toys, and, while the Sounds page
  keeps quiet on calls, whenever another app has the microphone
  (`AquariumSound.held`).

A folded **Fine-tune** holds the numbers: **Fish at once** (All, 6, 10,
16, 24 — past it, residents rest first, least raised first, then quiet
sessions, then working ones; an ask, a failure or a finish always shows,
a finished fish frees its place once it has swum off, and fry go with
their parent: `AquariumModel.cap`), **Raised fish stay**, **Plankton**
(0 clears the water), **Bubbles** (0 turns the stream off; the two share
one 0–2 track), **Scenery**
(full, light or bare seeded dressing — what you bought always stays;
the fish's work stations use the same share), **Visitors** (off stops
any visitor from queuing, the alien included, and sends away one already
waiting) and **Reset fine-tune**.
A Settings search that lands on one of these rows opens Fine-tune
(`ToysStore.revealRow`). **Outside the window** keeps Fill screen, Live
wallpaper, Screensaver and its clock.

An older settings file keeps its tank: `showLabels: false` reads as On
hover, and the old `density` becomes Plankton, seeds Bubbles, and picks
light scenery below 1. `showLabels` is still written for older builds.

### The Arcade tank

Three shop items, look only — the economy doesn't change:

- **Arcade** (themes, 60, level 1): bright cyan-to-royal water with a
  drawing style of its own. `TankStyle` rides on each theme's water —
  haze, ink, vivid, bubble size, dark — so a theme can change how the
  tank is drawn, not only its colours. Arcade keeps deep fish nearly as
  bright as shallow ones, pushes their colour, inks their outlines
  heavier and blows big bubbles with a hard crescent glint. Its pearls
  come as **coins** that spin as they fall and turn slowly at rest; a
  crowned fish's drop is a cyan **gem** (worth the same). The pearl chip
  and the flight home follow.
- **Candy gravel** (substrates, 35): a light tan bed under round beads
  in pink, lemon, cyan, lime and violet, with candy pebbles. Baked on the
  still pass like every floor; the shop tile and the card's swatch show
  the beads on the tan.
- **Toy reef** (back wall, 110, level 3): a painted stage set that
  changes with the tank level — a bubble cave (levels 0–2), pink ruins
  (3–5), a coral city whose windows glow at night (6–8) and a star
  cavern with glowing crystals (9).

Nothing in the set is named after or traced from the game it tips its
hat to.

### Drops, the snail, the oyster and the alien

- **Drops fall and stay put.** The tank pins each pearl where it first
  sees it — under its fish — lets a fresh one fall 1.4 s to the sand
  with a little wobble, and rests it there for good, however the fish
  swims on. A drop found already old (a relaunch) just rests.
- **The snail fetches** (`SnailSim`). With the window open it hustles to
  the oldest resting pearl and picks it up (`snailCollected`); the tick
  only sweeps up drops older than 120 s as a backstop. With the window
  closed the tick collects after 10 s as before. A pearl that rests past
  the end of its bed (a leaving fish's, dropped at the glass) is fetched
  from the end it can reach. With no pearls it
  creeps end to end and naps after five quiet minutes; an hour with no
  pearl warms its shell toward red and it huffs. It turns by squashing
  through zero over 0.6 s — never a one-frame flip — and the hermit crab
  walks back with the same turn instead of jumping to the start of its
  lap.
- **Oyster** (pets, 70, level 1): half an hour of the tank's work grows
  a 3-pearl pearl; it opens with the pearl glinting (a coin in Arcade)
  and waits for a tap, first in the tap chain.
- **Alien beacon** (decor, 90, level 3): a failed run the tank hasn't
  seen before calls the **alien**, once a day at most. A round,
  one-eyed, cheerful thing bobs along the upper third for 25 s; five
  taps shoo it off for 8 pearls, once a visit. Left alone it simply
  leaves. It never eats a fish, never takes a pearl, and never touches
  the failed session or its review.
- **Put away.** In the shop, owned decor and pets have an **In tank**
  switch: put away, a piece stays owned but isn't drawn, and the snail,
  the oyster and the beacon only answer while they're in the tank.

### Housekeeping

- An older build keeps shop items it doesn't know (`unknownInventory`),
  so a downgrade never eats a purchase.
- The care records are pruned with the window closed too (from the
  session refresh, at most once a minute), passers-by first — small
  nameless fish, then small named ones, then the oldest — never a live
  fish or a resident. Nothing is pruned until the core has sent its
  session list: before that every live session would look gone.

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
Docked is the same 18pt figure, not a lesser one: poses, tricks, hearts
and crumbs all show in the slot. The card's Mini toggle
(`presentation: "mini"`) swaps the body for the bare status dot wherever
the buddy sits, and while the daemon publishes a `screen_bar` LED
program the docked slot is that dot anyway — it is the strip's extra
LED at the centre seam, sampled on the program's own anchor rather than
a private clock.

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
top centre of every attached screen — one overlay window per display,
each on its own timer — at the notch/Screen Bar's spot: a flash &
starburst at the muzzle with three
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

## Notch (island)

The notch island is JR-Bar's own Dynamic-Island-style capsule: a black
shape flush with the notch whose lip carries the working providers'
dots (plus amber for asks, red for failures) and a live count —
"3 working · 1 waiting" — breathing slowly while anything works.
Anything that comes out of the notch must feel like part of the notch,
so hover — or a click on the band — grows the island itself into the
card, Dynamic-Island style: solid black, contiguous with the notch,
corners from `NotchProfile`, top edge pinned while the bottom edge
travels. The card's content is the shared `NotchCardView` in its
`.island` style: focus header, live session rows in the panel's
precedence, media, battery, tray, timers, calendar, the providers'
headline usage meters when `showUsage` is on, and the Agent Overview
button; its width is the notch slot plus shoulders, clamped to
300–380 pt. The glass card — `NotchCardView` in a `NotchCardPanel`,
owned by `NotchCardPresenter` — is the fallback: it shows under the
band only while the toy is off or an external provider owns the notch,
driven by the band's peek and pin as before. There is never both: the
band's hover arms nothing while the island is drawn, and its
pin/dismiss route to the toy's expand and fold. The window
(`NotchIslandWindow`) is a non-activating panel at `statusBar` level,
under the Screen Bar's `statusBar + 2`, so the bar's tray and ears draw
over the island's notch-deep top. The tray ends at the bezel, so the
island's content may start right under the notch, and the LED strip
seats at the island's bottom edge. The strip's black housing climbs up
behind the island's bottom corners, so content keeps above that climb:
the notice sizes itself with `NotchIslandLayout.noticeSize(…,
underHousing:)` and centres above `NotchIslandLayout.housingClimb`
(`NotchToy.noticeClimb`), and the card reserves
`NotchCardView.islandBottomContentInset`. The bar's click-through
window never steals a hover. `sharingType = .none` so Fold's desktop
capture never sees it (the `JRBAR_CAPTURE_CARD` env var is a dev-only
escape so screenshots can), and its frame is always exactly the drawn shape — nothing
invisible swallows a menu-bar click; while Fold's overlay is up, the
island lets clicks fall through it.

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
`NotchIsland` in JRBarCore owns the pure summary/meter/layout math;
`NotchIslandTests` covers it.

Three Alcove-parity behaviours ride the same window. **Event capsules**
(`capsuleNotifications`, per-kind switches in `capsuleKinds`): an
`ask_opened` / `completed` / `failed` / `quota_reset` event morphs the
island into a compact notice capsule — the kind's glyph and tint
(amber ask, green done, red failed, the provider's accent for a reset)
and one truncating "Claude · rename-the-fish needs you" line — for
~2.4 s, then the island settles back. `AlcoveEventPolicy` shapes the notice and
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

Blurb: "Who's working, up in the notch. Alcove or Boring Notch can
draw it instead."

## Copy

Every string on the page is in Jonathan's voice (see the jr-writing
skill): plain, short, a bit informal, `&` is fine, no em dashes, no
marketing words. Examples:

- Page intro: "Stuff that's just fun. None of it touches your agents or
  your usage, & every bit of it can be turned off."
- Fold blurb: "Your desktop folds into the screen as the lid comes
  down."
- Aquarium blurb: "Every session is a fish. Asks come up for air."
- Notch Buddy blurb: "A little guy in the notch who lives by what your
  agents are doing."
- Confetti blurb: "A burst in the provider's colours when the moment
  earns it."
- Notch blurb: "Who's working, up in the notch. Alcove or Boring Notch
  can draw it instead."

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
