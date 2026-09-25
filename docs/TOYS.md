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
public struct FoldSettings { enabled: Bool = false; anchor: FoldAnchor = .movement;
                             activationAngle: Double = 65;
                             perspective: Double = 0.6; blur: Double = 0.6; shade: Double = 0.67;
                             jitterTolerance: Double = 1.5; provider: FoldProvider = .jrbar;
                             frost: Double = 0; holdStrength: Double = 1;
                             dwellTimeout: Double = 0; restoreSound: Bool = false;
                             look: FoldLook = .duo; fadeLength: Double = 0.55 /* 0.2…1 */ }
// (`holdPicture` is read once to seed `holdStrength`: on → 1, off → 0; a
//  file with no `look` moves to Duo and anchor `.movement`, keeping its
//  blur, shade and activation angle)
// (the Tilt/Dusk/Fog style picker is retired — `style` is decoded only to
//  recognize old default sets for migration; nothing reads it)
public enum FoldProvider: String { case jrbar, bendy, lidPlane }  // who renders the fold
public enum FoldAnchor: String { case angle, movement }  // fixed angle, or wherever the lid rests
public enum FoldLook: String { case duo, room }  // the iPhone Duo's held picture, or the portal room
public enum DayNightMode: String { case realTime, cycle }  // the clock / the four-minute breathe
public struct AquariumSettings { enabled: Bool = false; showLabels: Bool = true; density: Double = 1.0;
                                 speciesOverrides: [String: String] = [:]  /* provider id → species */;
                                 dayNight: DayNightMode = .realTime }
public struct NotchBuddySettings { enabled: Bool = false; character: String = "dot";
                                   presentation: String = "character" /* or "mini" */;
                                   buddyName: String = ""; care: BuddyCare;
                                   freePosition: BuddySpot?; tucked: Bool = false;
                                   showCaption: Bool = true; scale: Double = 1.0 /* 1…3, floating only */;
                                   wearsStripColor: Bool = true; walkabout: Bool = true;
                                   wearing: String? /* a ShopItem raw value */;
                                   walkEvery: Double = 12 /* minutes between walks, 3…40 */ }
public struct BuddySpot { x: Double; y: Double }                    // parked screen point
public enum BuddyCharacter: String { case dot, cat, ghost, robot, owl, slime,
                                     axolotl, crab, mushroom, ufo }
public struct BuddyCare { lastInteractionAt: Double; lastTreatAt: Double; lastCrumbAt: Double;
                          /* epoch seconds; 0 = never */
                          petCount: Int; treatsGiven: Int; crumbsEaten: Int }
public struct ConfettiSettings { enabled: Bool = false; landing: ConfettiLanding = .rest;
                                 density: Double = 1.0 /* Amount, 0.5…2 */;
                                 duration: Double = 1.0 /* Hang time, 0.7…1.5 */;
                                 palette: ConfettiPalette = .provider; shapes: ConfettiShapes = .mixed;
                                 triggers: ConfettiTriggers; firedKeys: [String] /* dedup ring, 64 deep */;
                                 whenHeld: ConfettiHeldBurst = .later; sound: Bool = false;
                                 origin: ConfettiOrigin = .notch; intensity: ConfettiIntensity = .standard;
                                 seasonal: Bool = false; screens: ConfettiScreens = .all;
                                 momentStyles: Bool = false }
public struct ConfettiTriggers { sessionCompleted: Bool = false; weeklyReset: Bool = true;
                                 perProviderReset: Set<String> /* provider ids, lowercase */;
                                 codexBankedReset: Bool = false; allClear: Bool = false }
public enum ConfettiLanding: String { case rest, fall, fade }   // lie on window tops & the Dock / shower off the bottom / dissolve mid-air
public enum ConfettiPalette: String { case provider, toys, party, gold, pastel, mono, everyone }  // "rainbow" decodes as party
public enum ConfettiShapes: String { case mixed, streamers, flecks, glyphs, stars }
public enum ConfettiOrigin: String { case notch, icon, corners, rain }
public enum ConfettiIntensity: String { case subtle, standard, big }
public enum ConfettiScreens: String { case all, main }
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

Closing the lid folds the desktop. Two looks, picked on the card:

- **Duo** (the default) is the iPhone Duo's fold: the picture stays put in
  space while the glass swings through it. A seated eye sees the desktop
  neither move nor shrink; only the glass silhouette drops, the picture
  goes soft and dark away from the hinge (the hinge stays sharp and
  bright), and the glass is black by the time the eye loses it edge-on.
  No sheen, no seam, a pure black void.
- **Room** is the earlier portal: windows float as cards in a lit space,
  the wallpaper recedes behind them, and the whole thing blurs, fogs and
  dissolves toward the hinge, with Frost and the seam light.

Both fold from wherever the lid rests by default (the Duo reacts from the
first degree), or from a set angle. Clean-room; no Lid Plane (GPL-3) or
Bendy code; the Duo's numbers come from the public chuspeeism/iphone-duo
study of Apple's own model (MIT).

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
  and the Simulate slider still works. The Duo's movement fold is the
  one exception to the 10 Hz idle: while it is armed the poll runs at
  120 Hz so the edge interpolator gets each edge to ±8 ms.
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
  image. The Duo feeds the tracker through `EdgeInterpolator` instead of
  the raw staircase: the lid is drawn one sensor period (100 ms) in the
  past, straight between the edges already seen, into a stiffer tracker
  (ω 40). The latency stays ~150 ms but the ±25 % ten-times-a-second
  speed pulse is gone (under 5 % at 40–140°/s, `FoldSmoothingTests`). A
  lid leaving rest back-dates its first segment so motion starts at once;
  the simulate slider and Try it bypass it, being smooth already.
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
  opening black. In the Duo the capture arms on 3° of travel down (a
  nudge, or tilting the screen back wider, never flashes the Screen
  Recording indicator; the Room still arms either way), the first frame of
  a gesture eases the delta up from 0 over 150 ms instead of popping to
  a close that is already 15° in, and the overlay's first 120 ms on
  screen fade it in. The Duo's travel is not clamped: its geometry goes
  to black on its own.
- **Capture** `FoldCapture`: the Duo runs ONE stream (`dual: false`), the
  whole desktop minus JR-Bar, except JR-Bar's own menu-bar windows (the
  icon mirror, the Screen Bar, kept through `exceptingWindows`) so the
  whole bar folds together; no far stream and no window-list poll. The
  Room runs TWO ScreenCaptureKit streams on the
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
- **Render** `FoldOverlayWindow` + `FoldRenderer`:
  borderless `NSWindow`, `.screenSaver` level, `ignoresMouseEvents =
  true`, `sharingType = .none`, covers the built-in screen only, `MTKView`
  (`framebufferOnly`, capped at `min(120, screen.maximumFramesPerSecond)`),
  one pipeline per look in one runtime-compiled library.
  - **Duo** (`duoFragment`, `FoldDuoModel`): each captured frame lands
    in an 8-level Gaussian pyramid (`MPSImageGaussianPyramid`; plain
    mipmaps where MPS can't run). Units are screen heights in the lid's
    side view, hinge at the origin. The seated eye sits at (2.6, 2.0)·(1.6
    − Perspective): 2.6 H toward you, 2.0 H up at the default. Each glass
    pixel, on a lid drawn at θref − Hold·(θref − θ), casts a ray from the
    eye and shows the point it hits on the resting plane θref: the exact
    front-view hold, the identity at rest, the hinge row pinned. Below
    edge-on (37.6° for the default eye) the pixel is black. `motion =
    smoothstep(δ / (fadeLength·(θref − 5°)))` has zero slope at the
    start. In the picture's own rows (e = 0 at the hinge row, 1 at the
    far edge) blur σ = 0.10·Blur·motion·e^1.35 H, read as one pyramid
    level through a cubic B-spline (≈ 0.82·2^L px, MPS's decimation
    offset undone; `FoldRendererTests` pins it within 6/255 of a
    Gaussian, so no ghost copies), and darkening is
    min(1, 3·Shade·motion·((e − 0.2)/0.8)^1.35): the hinge-side fifth
    never darkens and the far edge is black once motion ≥ 0.5 at the
    default Shade. The end fade runs from clear at edge-on + 22° to black
    at edge-on + 2°. The overlay's alpha ramps over the first 2° of
    travel. Reduce Motion: no warp, no blur, darkening only.
  - **Room** (`foldFragment`, `FoldPortalModel`): the model is a room,
    not a picture: the wallpaper is the far wall, each window a card
    floating in front of it at a depth from its stacking order, so the
    contents parallax as the lid moves. With the fold the space scales
    toward the hinge, the matte fog swallows the far end and the whole
    composite dissolves over the last ~20°. Perspective sweeps the eye
    from orthographic to close-up, Blur is the fog (Vogel-disc LOD reads
    off the GPU-mipped textures), Shade the room's darkness, Frost the
    milk of the cover.
  - **Hold picture in place** is a 0–100 % strength (default 100 %) in
    both looks: 100 % keeps the desktop where a seated eye saw it while
    the glass tilts over it, 0 % glues it to the lid. (Until 2026-09-24 it
    was a switch that sent Perspective to a shader that read it
    backwards, so "on" held the picture less than "off".)
  - The overlay is ordered out whenever `delta ≤ 0.002` or no frame has
    landed, so at rest nothing runs.
- **Safety**: pause (hide overlay, stop capture, keep sensor) when the
  lid reads ≤ 5°, when `AppleClamshellState` on `IOPMrootDomain` says
  closed — the daemon's `closed_lid.holding` is the keep-awake
  assertion, NOT lid state, and it arrives cached on the sensor's 1 Hz
  beat — when the built-in display is missing or mirrored (cached,
  refreshed on the screen-parameters notification plus a 2 s backstop),
  or on screen sleep; resume 0.5 s after all clear. Never pick an
  external display. Reduce Motion: the fold still follows the lid (it's
  a function of angle, not an animation) but the blur is skipped, and
  the Duo drops its warp too. **Duo closed hold** (`FoldBlackout`): a
  close that reaches the shut line with the fold on screen keeps the
  overlay up as a flat black pass — no texture, capture stopped, the
  anchor kept — instead of ordering it out onto the sharp desktop. It
  lets go on a 3 s watchdog (restarted once when the lid reopens), on
  screen sleep, lock, a session switch or a lost/mirrored built-in
  screen, or when the lid is back past 15° with a frame captured after
  the close. The reopen films at once, wherever the lid is, and the fold
  then unfolds from black: the glass starts at the last angle that still
  draws all black (edge-on + 2°) and the chase unwinds it to the live lid
  in under half a second, so a quick reopen never cuts straight to a
  half-lit desktop. One reference holds for as long as the overlay is up,
  so the unfold, and the dwell pause's unwind, draw from the lid they
  started from. The card reads "Holding black across the close" for the
  whole hold. It sits at the overlay's own level, so never above the
  lock screen, and uses no private SkyLight spaces.
- **Swap**: `FoldProvider.bendy` / `.lidPlane`: detect via
  `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` (Lid Plane's
  bundle id is in its repo `Info.plist`; Bendy's is read from
  `/Applications/Bendy.app/Contents/Info.plist` when present, else offer
  the storefront link). Choosing an external provider stops our renderer,
  launches that app, and the chip reads "Bendy is rendering it". When the
  chosen app isn't installed the picker row says so and links to it.
- **Controls**: On/Off, Look (Duo / Room), Fold from (Set angle /
  Wherever the lid rests), Starts folding at 60–160° (Set angle only; in
  the Duo set it near where your lid rests), Release when parked, Jitter
  0–5°, Perspective / Shade / Blur, Goes dark over 20–100 % (Duo) or
  Frost (Room; a Settings search that lands on the other look's row draws
  it switched off, saying which look has it), Hold picture in place
  0–100 %, Click on return, Hinge
  voice, "Simulate a fold" slider (drives the angle while held), Try it
  (a close and reopen 50° below the fold's own reference), live angle
  readout ("104°" or "no sensor"), Render with (JR-Bar / Bendy / Lid
  Plane).

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
curtain and a moon-jelly lamp pulsing every six seconds hold the
front row — each pooled under its own shadow on the dune line like
the originals. Bought pets swim their own errands on the mover pass:
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

### Swimming

A fish cruises in gentle arcs: the wander bends its path at a turn
*rate* (`AquariumSteering`), a weak spring holds it near its own depth,
its climb stays under about 26° and its drawn pitch is eased and
clamped, so it never noses straight up or down. Turning back is its own
behaviour — a committed U-turn (`SwimTurn`) — started by the glass seen
far enough ahead that the turn fits, by food or a tap behind it, or by a
whim that has lasted a beat; a turn is followed by a cooldown before the
next whim, so a cruising fish reverses about twice a minute at Natural,
mostly at the glass, with the odd mid-tank change of mind. A fish at a
work station swims to it and hovers once it is close, nosing at the
point instead of circling it; its fins lift and sink it with the point,
so it only turns back when the point is well behind it, after a longer
wait — at most about three times a minute at the kelp, the survey or the
wreck. Food and work both outrank the school's pull.

The turn itself (`AquariumTurn`) is a U-turn in depth, after the classic
2D turn strip: the fish stays level, drifts forward about a fifth of a
body and comes back, its head swings round ahead of its tail (a
per-point warp along the body that can never fold), and for four or five
frames in the middle it is drawn head-on (`AquariumFishFront`) — a
proper face built from each species' kit, both eyes on you, the
pectorals out, the tail tips sweeping behind, a white collar on a banded
fish, a translucent fan for the betta's veil, spines on the puffer. The
facing only flips inside that head-on frame, so no fish ever mirrors
where you can see it, and the head-on frame keeps one mirror from the
cut in to the cut out, so a monocle or a scarf's end never hops sides
mid-face. The eyes stop at the silhouette as the head comes round. No
turn is shorter than 0.4 s, however quick the settings. The tail kicks
out of the turn. Hats sit square on the crown head-on, glasses cover
both eyes, the bow tie knots at the middle of the chin and the laptop
sits the frame out. The seahorse, which stands upright, flicks round
through a narrow side view instead.

Everything else that used to mirror in one frame turns too: fry squash
through zero at each end of their orbit, a completing fish facing left
turns round before it corkscrews out, the fish that come for a finished
run's pellets are picked once, when the run finishes, and each swims
over through its own turn and eats its pellet when its mouth gets there,
the turtle comes round over 1.4 s with a small dip, each tetra turns on
its own beat, and the axolotl ambles back with a turn instead of jumping
home. An ask holds the turn about a third of the way round, level, both
eyes on you, whatever the fish was doing when it came; answering swims
it back down from the glass. Every change of state starts from where the
fish was last drawn — its place, its turn, its size, its tail and its
roll — and settles over about half a second. The bubbles, rings, the z's
and the station's work hang off the nose as the turn carries it. The
glad swimmer's flourish is a true barrel roll, decided as it begins: one
due mid-turn or by the surface is let go, and one begun finishes. Reduce
Motion only ever shows a turn's two ends.

Three settings shape it (`AquariumSwimRows`, in the card's Fine-tune
section): **Swim pace** — Calm, Natural (the default) or Lively — sets
how hard the wander bends, how long a fish waits between turns, how long
a turn takes and how fast it cruises; **Swimming speed** (0.5–1.6×)
speeds swimming and turning together, so the paths keep their shape and
only run faster; **Fish size** (0.6–1.6×) scales every fish, and the
hover box with it, and a big fish swims and asks far enough under the
surface that no fin pokes out of the tank.

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
  never on the wallpaper or the screensaver, never while the toys are
  hushed (Focus, quiet hours, a call), at the Sounds page's volume.

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
waiting), the three swim rows (**Swim pace**, **Fish size** and
**Swimming speed**, `AquariumSwimRows`; see "Swimming" above) and
**Reset fine-tune**.
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
hop, spin, wave, blush — and while an ask is open a tap on the "!"
badge over its crown opens the session doing the asking; a pat
anywhere else stays a pat, so petting can't pull the front app away
mid-ask. The card can name it (blank keeps the
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
treat, Rename…, Change character →, About…, Wear → (once the tank's
shop has sold a buddy piece), Feed the tank (while the tank has fish),
Open the asking session while one is up, Dock/Float free, Caption on
hover, Take walks (floating only), Tuck away. Tucked is a nap: off the
screen until the next session event or a card re-enable. Under the
pointer, docked or floating, it wears a quiet one-line caption naming
what it is watching — "Claude · rename-the-fish — working", or "… —
waiting on you" — the `BuddyFocus` pick: an open ask first, then
failed, then the freshest working session, a done row only when
nothing live remains; its name while nothing runs. "Caption on hover"
(the card and the menu) turns it off in both homes.

The floating pet is sizable: the card's Size slider sets
`NotchBuddySettings.scale` (1…3, default 1), which the free panel reads
as a `scaleEffect` on the 18pt figure — vector all the way down, so
strokes, eyes and the badge stay crisp — with its padding and caption
(up to ~11pt) growing with it; it floats bare, no pill behind it. The
readout beside the slider names the stop exactly (1.25×, not 1.2×). The panel
re-measures off the hosting view on every present, so the slider drags
the pet bigger live and a parked 3× buddy still clamps fully on-screen;
the docked pill ignores the dial entirely — the notch slot is fixed.
Docked is the same 18pt figure, not a lesser one: poses, tricks, hearts
and crumbs all show in the slot. The card's Mini toggle
(`presentation: "mini"`) swaps the body for the bare status dot wherever
the buddy sits. While the daemon publishes a `screen_bar` LED program
the docked buddy wears the band's colour ("Wear the Screen Bar's
colour", on by default): the seam's brightest still colour, never its
pulse, so it is a creature dressed like the band rather than a second
light keeping its time. Asks, failures and hops keep their own amber,
red and green.

Floating, it takes the odd calm walk — neko's manners, not the goose's
(`BuddyStroll`). While agents work and nothing asks, now and then it
hops up onto the top edge of the frontmost window with room (or the
bottom of the screen), walks along it, turns round on the spot at the
far end — the edge's end when the edge is short — wanders half the way
back, and hops home to where you parked it. "Take walks" turns it off;
"Time between walks" (`walkEvery`, 3–40 minutes, 12 by default, the
cadence it always had) sets roughly how many minutes of work pass
between one walk and the next, so further right is rarer. It only ever
moves its own panel. A press on it holds it still under the pointer
(the walk picks up on release), its menu holds it too, a carry ends the
walk, and an ask, a failure, idle agents, a window that moved or "Take
walks" turned off send it straight home from where it stands. Resizing
or re-parking it mid-walk does the same instead of teleporting it.
Reduce Motion never walks.

Nothing it does pops. A change of heading on a walk eases over 0.35 s
(`BuddyTurn`): the eyes cross first, the body follows, the lean passes
through upright and the body narrows a touch at the midpoint; stepping
from its patrol into the walk and back blends the two poses over the
same beat. A mood change (a completion hop, an ask, a slump, waking)
hands the old pose over to the new one over 0.24 s (`BuddyHandoff`), so
the patrol's three-point swing never jumps, and a second change inside
that beat carries on from the blend on screen; the new mood's own
entrance still plays. The carried dangle follows the cursor on a short
lag, so a change of direction swings it through upright, and the drop
eases out whatever lean it had. Dragged out of the notch it takes over in place:
no blink, and at 2× it grows from the docked size over 0.3 s instead of
doubling in a frame. Docked again (a drop on the slot, the menu, the
card), the floating one fades out with its figure still in it while the
notch's fades in, and switched off it fades the same way. "Tuck away"
ducks it out over a quarter second — up under the notch when docked,
down to its feet when floating — and it pops back up when it wakes.
Reduce Motion takes every one of these moves in a single step: the tuck
goes at once, and nothing grows, turns or swings; only the panels'
short fades stay.

The skeleton is a soft body, two pupils under lids, a mouth and a ground
shadow — at 18pt the silhouette does the work, so the craft lives in the
animation. Pacing is an eased walk with a per-step bob and a pause at
each end where the eyes turn before the body follows, the lean swinging
through upright to the way back; the gathering trades the walk for
quick happy micro-hops in place. The wave and the
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

When one of the person's triggers lands — by default a provider's
**weekly** quota reset — the notch pops: light spills out of its lower
lip, a puff flares at each lower corner, and a burst of confetti in that
provider's colours sprays out from under it, wide and fast, then
flutters down. Nothing is fired up into the notch, so the burst is seen
from its first frame (on a notched Mac the notch is a hole in the
screen). One overlay per free screen, the whole screen, each on its own
timer.

**Motion** is closed form (`ConfettiPhysics`): a *spray* under linear
drag (`v0·τ·(1 − e^(−t/τ))`, so the spread grows with the launch speed
and scales with the screen's width) and a *settle* whose fall ramps up to
a flutter speed (`vt·(t − tf·(1 − e^(−t/tf)))`), with a falling-leaf
sway, a dip at each end of the swing and a lean into the drift. The lip
fires a mix of sub-bursts (`ConfettiEmitter`): a flat wide volley from
the lip's corners, a mid volley out and down, a drop that leads the
shower, and a slow puff that lingers near the top — so no hollow cone and
no single sheet. Flutter speeds overlap across shapes, so a falling burst
never sorts into layers. The whole burst is worked out when it fires
(`ConfettiBurst`): each piece's end is known, a piece too slow to finish
inside the landing's deadline is nudged just fast enough, and the window
closes the moment the last piece is gone.

**Look.** Each piece is a paper plane tumbling in 3D: a random axis
through Rodrigues' rotation, drawn through the rotation's top-left 2×2
(the exact orthographic projection, whose determinant is R22), lit by a
Lambert shade from the upper left (0.7–1, never muddy) with a specular
glint, its back a deeper, richer shade of its front. About 30% sit on a
far layer drawn first: smaller, slower, a little hazy, no blur. Rects
(9–15 pt), dots, diamonds, stars, twisted ribbon streamers whose ripple
runs along them, and the provider's real glyph (Claude's asterisk,
Gemini's sparkle, Codex's `</>`, set in heavy type so it reads). The
colours are resolved once per burst in eight steps of light, so a frame
never mixes one; 60 fps at most.

**The card** (`ConfettiCard.swift`) has three runs. **Look**: a live
preview (the top middle of the screen at half size, with the notch over
it) that plays one burst for about two seconds after any pick or on
hover, then holds still; Try it (the focused session's colour, the same
one `jrbar://confetti` picks); **Origin** — Notch (the lip; the menu
bar's bottom centre on a screen without one), Icon (under JR-Bar's
menu-bar icon, only on its screen), Corners (two cannons crossing over
the middle, Raycast's look) or Rain (a curtain from the top edge, the
calmest); **Size** — Subtle, Standard or Big (about 90 / 180 / 300
pieces on a 1512 × 982 screen, scaled by each screen's area, 0.8–1.8×;
Big throws a second volley and a softer second pop); **Palette** —
Provider (base, a lighter step, a gold- or cyan-leaning accent, white,
gold, pale), Toys tint, Everyone working (each working provider's colour
and glyph, a glyph always in its own provider's colour), Party, Gold, Pastel, Mono (the tint alone); an older file's
Rainbow reads as Party; **Shapes** — Mixed, Streamers, Flecks, Glyphs,
Stars; **Landing** (below); **Seasonal** (off: on New Year, Valentine's,
Lunar New Year, Easter, Halloween and Christmas, that day's colours and
fleck, read off the Mac's calendar); and under **Adjust**, Amount
(density, 0.5–2× on top of the Size) and Hang time (0.7–1.5×: how slowly
pieces fall and how long they rest — never the pop or the spray); a
Settings search for either opens Adjust.
**When**: the triggers, and **Moment styles** (off: a milestone bursts
gold, big and from the corners; "All caught up" is a gentle rain).
**Manners**: the quiet switch and the held burst, Sound, and **Screens**
(every free screen, or the main one only).

**Landing.** Rest (the default) lands every piece on something real:
the first surface it is over at the moment it comes down to it. That is
the highest window top edge showing there (read once from the window
list — bounds only, no permission — through `OnScreenWindows`, shared
with the buddy). Every window in front counts, so a maximised window
hides the edges behind it, though it holds no pieces itself, and a
piece never lies past the end of an edge. Else it is the Dock's top,
only across the Dock (its tiles read from the Dock's accessibility list;
without Accessibility the Dock's top stands for the whole width), else
the bottom edge. A piece squash-bounces, eases flat onto its ledge,
lies about 1.2 s and fades; the window list is read again once a second,
and a piece whose window moved or closed fades early. Fall is a quick
shower off the bottom, fading over the last 12% of the screen and done
in about 4.3 s (it used to drizzle for 9.6 s); the slow pieces are
hurried, each to its own deadline, so the last ones trail off instead of
landing in a line. Fade dissolves pieces on their way down, between 35%
and 55% of the screen's height (one thrown up from the corners that
peaks lower dissolves over the same depth from its peak), with a little
shrink; a rising piece always shows in full. A Standard burst is gone
within 5 s in every landing on screens 900–1329 pt tall.

**Triggers** are judged by `ConfettiTriggerPolicy` in JRBarCore: a
session completing (`completed` events), any provider's weekly lane
resetting (`quota_reset` on a `weekly` / `*-weekly` lane — on by
default), picked providers' EVERY lane resetting (the five-hour window
included), Codex's banked-credit balance growing, the last open ask
clearing, and Milestones (an Aquarium achievement or tank level, or the
daemon's odometer). Event triggers dedup on `event:<cursor or id>`
against the persisted `firedKeys` ring (64 deep); state edges are folded
by `ConfettiEdgeTracker`, whose first document only seeds the baseline.
A burst no provider owns — All caught up, a completed event without one,
an unknown provider — wears the Toys tint (`burstTint`), never the
unknown-provider grey; a colour set in `colors.agent_colors` wins. From
outside, `jrbar confetti` (a daemon `confetti` event: the toy must be
on, one per 3 s) and `jrbar://confetti?provider=|session=` (an explicit
ask, like Try it and the palette's Fire Confetti) both fire a burst.

**Manners.** While JR-Bar is quiet, a Focus is on or a call has the mic
or camera, a burst is held and replayed smaller once the room clears (a
half-density replay, floored at a quarter, so it is smaller even at the
lowest Amount) or let go; anything held over 30 minutes is let go, and a
screen a fullscreen app owns is skipped. The overlay is invisible to
screen capture and sharing. Reduce Motion gets one soft glow at the lip
(or the icon) and nothing moving. The optional pop and rustle is
synthesized once, cached as a WAV in the caches folder and played
through `SoundPlayer.playSynthesized` on the app's one player (the event
sounds' own): Settings › Sounds' volume, the
alert device when that's picked, held while another app has the
microphone, a touch higher or lower each burst (±6%), and panned toward
the icon when it fires from there. The card's cost line quotes the last
burst's measured frame time (an `os_signpost` interval wraps each draw).
Off by default; every key decodes tolerantly to its default.

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
  `JRBarAppTests/BuddyRoamingTests.swift`. The walk's path, cadence and
  per-frame motion (no more than a step a frame across a leg change or a
  re-plan) are `JRBarAppTests/BuddyStrollTests.swift`; the eased turn,
  the mood handoff and the dangle's lag are
  `JRBarAppTests/BuddyTurnTests.swift` (≤ 2° of lean and ≤ 0.2 of eye
  travel per 1/60 s frame through a reversal).
- Fold math: `deltaRadians(angle:reference:)` clamps, jitter filter
  accepts/rejects, pause predicate on each safety input (pure functions
  in `JRBarCore/FoldMath.swift`, tests in `FoldMathTests.swift`). The
  Duo: `FoldDuoModelTests` (identity at rest, pinned hinge row, the
  observer round trip at 100/90/75/60°, 79.4 % top-row width at 70°,
  motion, darkening, end fade, blackout and catch-up),
  `FoldSmoothingTests` (a simulated 10 Hz lid: ripple, lag, stop,
  reversal, flicker, plus a pin that the old path fails),
  `FoldRendererTests` (GPU: identity at rest, sharp hinge against a soft
  far band, black far edge, the pyramid read against a Gaussian, the
  blackout) and `FoldRenderProofTests` (the seated eye's Dock and window
  corner hold within 2 px from 110° to 75°; `JRBAR_RENDER_PROOF=1` writes
  `fold-duo-strip.png` and `fold-room-strip.png`).
- Aquarium: session → fish state reducer (`AquariumModel.swift` in
  JRBarCore, pure), tests for ask/failed/completed transitions.
