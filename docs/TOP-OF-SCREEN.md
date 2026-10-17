# Top-of-screen contract

The rules every surface at the top of the display follows, so Notch, Screen
Bar, Menu Bar, Dock and the floating cards read as one system instead of five
apps sharing a pixel row. The short version lives in `docs/UTILITIES.md`; this
is the contract.

## Material rule

- **Glass only on what floats.** `NSGlassEffectView` may appear on surfaces
  visually detached from the notch (the Item Bar panel, the Screen Bar peek card
  when the island isn't drawn, the Dock, popovers).
- **Black on what grows from the notch.** The island, its expanded card, its
  notices and the LED band are solid black and contiguous with the notch's
  own silhouette.
- **One surface per role.** When the Notch island is drawn it IS the notch's
  card — the glass fallback stays dark, the band's gestures route to the toy.
  When both Notch and Menu Bar are enabled, hidden-item reveal rides the
  island's card bottom row; the floating Item Bar is the fallback only.

## Geometry rule

The island's body stands in from its frame by the shoulder's width on each
side (the silhouette draws its shoulders in the gap, at the top only). Anything
that continues the island's side downward takes
`NotchSilhouetteGeometry.body(of:notchWidth:notchDepth:)`, not the frame: the
Screen Bar's housing under a notice, an ask or the card did take the frame, and
stepped out past the island by 4 pt on each side.

`ScreenBarGeometry` is the only source of notch truth: `notchDepth`,
`slotWidth` (auxiliary-areas gap), `preferredScreen`, band rects, wing
extents, corner radii from `NotchProfile`. Nothing else measures the notch.
The notch itself is resolved by `NotchHardware.resolve`, a pure function of
injected screen metrics (frame, safe-area inset, the two menu-bar areas, backing
scale, built-in or not): a real notch needs both areas and a gap between them,
so an inset with no gap (a screen mid-reconfiguration) is not a notch, and an
external or notch-less display floats as a pill. Areas that arrive in a screen's
own coordinates are moved to global ones, so a notched panel arranged away from
the origin still seats at its own centre. The rectangle is snapped outward to
whole device pixels and bleeds one pixel past each side, so the bare housing is
exactly the hardware with no hairline against its edge, and every island frame
(`NotchIslandLayout.settled`) lands on the pixel grid and never dips under the
notch while it springs. A grown body wears the hardware's concave top
shoulders (up to 4 pt, `NotchSilhouetteGeometry.topFlare`), which swell with
its width over the first 24 points it reaches past the notch's side
(`flareRamp`), so there is no size at which a shoulder pops onto the bezel,
and which never exceed that overhang, so the body below is never narrower
than the notch. The bottom corners are a function of the shape's height alone
(`radiusRamp`, 165 points past the notch, eased out), never of the clock: a
one-line notice already has a soft foot, a card has the full 28 pt, and an
interrupted morph wears whatever its present size asks for. The island is above the menu bar (`statusBar`) and stays
over a full-screen Space on purpose: its window is exactly its shape, so it
never parks glass over a menu.
Menu Bar plans an item that sits under the notch or under the front app's
menus as hidden, because macOS leaves it behind the glass (the Item Bar still
lists it); the Dock's top-edge option and per-display docks resolve through
`preferredScreen`.

## Motion

Everything that moves on the island takes its numbers from one file,
`NotchMotion` (`app/Sources/JRBarCore/NotchMotion.swift`). Three rules
run through it.

- **The shape is the clock, and the content has one of its own that
  starts with it.** The island's frame is one spring (`NotchFrameSpring`),
  advanced by its exact solution so 60 Hz and 120 Hz draw the same curve.
  The edge light, the corners, the shoulder and the soft foot are pure
  functions of how far the shape has travelled (`NotchMorph.openness`,
  `NotchReveal`). The card's content is not: read only off the shape it
  could only arrive after it, so the grown shape was empty black for its
  first 90 ms and a fold ended with empty black falling away. It runs on a
  small spring of its own (`NotchContentClock`), ticked by the same
  display link, that is aimed at the face the island is going to: it begins
  to resolve on the tick the shape begins to move (`NotchMotion.contentIn`)
  and, aimed the other way, leaves ahead of it (`contentOut`). The clock
  keeps its position and its velocity across a change of aim, so a reversal
  in either direction bends the content and never pops it, and a landed
  move snaps it whole or gone. `jrbar.notchStagedMotion` set to false (and
  Reduce Motion, which has no travel at all) take the old rule back: the
  content is wherever the shape is.
- **Opening is lively, closing is quick and calm.** The grow overshoots about
  1% of its travel (2% of the width's), only outward and downward, and never
  at the bezel (the top edge is held by a test); the fold is home in about
  135 ms and lands under 0.02% so a dismissal never bounces.
- **The width has its own clock.** The card is laid out once at its own
  width and the shape uncovers it, so on the grow the width runs a quarter
  quicker than the depth (`NotchMotion.widthLead`, 0.72 of the response)
  and on the fold it trails (`widthLag`, 1.3). The card's openness is the
  lesser of the shape's depth and width (`NotchMorph.openness(size:)`), so
  the sides never cut through content that is already lit.
- **Reduce Motion swaps every move for a quiet 0.15 s crossfade.** No
  swell, no travel, no blur; the card is simply there
  (`NotchMotion.faceTransition` is the one branch).

| Token | Response | Damping | Overshoot | 90% at | Used for |
| --- | --- | --- | --- | --- | --- |
| `open` | 0.42 s | 0.78 | 2.0% | 195 ms | the island growing into the card |
| `live` | 0.34 s | 0.80 | 1.5% | 162 ms | a short hop outward: a notice dropping under the notch, a shoulder gaining a mark (growth under 110 pt) |
| `close` | 0.23 s | 0.95 | 0.01% | 133 ms | any fold or shrink |
| `nudge` | 0.30 s | 0.90 | 0.15% | 163 ms | content-driven resizes, the swell relaxing |
| `hover` | 0.20 s | 0.72 | 3.8% | 86 ms | the small swell when hover-to-open is off; hover-to-open keeps the resting shape until the card opens |
| `hoverMarks` | 0.18 s | 0.75 | 2.8% | 77 ms | marks scale slightly (1.02); the resting outline stays fixed when hover-to-open is on |
| `contentIn` | 0.20 s | 0.92 | 0.06% | 110 ms | the card's content (and a notice's) resolving: a third of the way at 40 ms, whole by about 170 ms |
| `contentOut` | 0.14 s | 0.95 | 0% | about 80 ms | content leaves ahead of the shape but stays visible through the first fold frames |
| `pageTurn` | 0.24 s | 0.92 | 0.06% | 135 ms | a page of the grown card arriving after a sideways swipe: readable (opaque) by about 70 ms, landed by 0.25 s |

`NotchMotion.frameMotion(from:to:)` picks the spring from the size of the
change, so no caller names one. Why these numbers: Boring Notch opens on
0.42 / 0.8 and closes critically damped (0.45 / 1.0), Atoll on 0.42 / 1.0,
DynamicNotchKit on a 0.4 s bounce; the grow here sits at the livelier end
of that range and the fold at the calm end, and the hover swell is the
liveliest because it only travels 2 to 4 pt and has to start moving at
once. The research and the sources are in
[docs/archive/2026-10-07-notch-premium-research.md](archive/2026-10-07-notch-premium-research.md).

| Layer | Window (of the shape's travel) | Why |
| --- | --- | --- |
| Sheet (header and rows together) | the content clock's level (`NotchReveal.sheet(level:)`): opacity is the level, from an 8 pt blur that clears, a 0.96 scale and a 6 pt lift | it starts with the shape and leaves ahead of it; the old rule, still the `jrbar.notchStagedMotion` revert, was 0.45 to 0.90 of the shape's travel |
| Sheet width | scaled to stand as wide as the shape, 8 pt in from each side, while the shape is narrower than the card (`NotchReveal.fit`, never under 0.5) | the sheet is laid out once at the card's width, and a sheet that arrives with the shape would have its rows cut by the sides; it condenses out of the notch, the Dynamic Island's own gesture |
| Row cascade | by level: first row at 0.10, 0.04 later per step (six at most), each over 0.50 | the rows follow the sheet in, and the last leaves first on a fold; the old rule was 0.52 and 0.02 of the shape's travel |
| Soft foot | 18 pt of black over the shape's lower edge while it is within 24 pt of the content's own height (`NotchReveal.footFade`) | the edge dissolves what it uncovers instead of slicing through a button or a line of text; black on black, so no mask and no offscreen pass, and nothing drawn once the shape has landed |
| Edge light | 0.55 to 0.95 | a hairline of white (14% at its brightest) along the foot and bottom corners; absent on the resting island, which stays exactly the bezel's black |

A notice, an ask or a level is laid out once at the width of its own frame
and never re-wraps while the island grows. It runs on the same kind of
clock as the card (`NotchStageModel.noticeClock`), with a 3 pt blur and a
6 pt settle, held by a gate on how far the lip has dropped
(`NotchReveal.noticeGate`: nothing until a fifth down, all of it from three
fifths, so the lower edge never cuts a line that arrived before the lip
did; it was 40% to 85% of the shape's travel). It stands as wide as the
shape while the shape is narrower than the face, as the card's sheet does,
and leaves ahead of the shape on dismissal, remaining visible through the first fold frames.
Only when nothing moves on a stage (the shape at rest, Reduce Motion, the
old per-tick resize) does it fall back to a plain fade of 0.18 s in and
0.14 s out.

### Widths that fit their content

- **The resting strip is Alcove's compact live activity.** A playing track
  alone is the cover left of the notch and a small waveform right of it
  (`NotchIdleLayout.mediaArtLeft`), 14 and 22 pt of content, so the island
  reaches about 36 pt past the notch on each side, not the 158 pt it did
  when the strip carried a truncated title. When the agent HUD holds the
  left shoulder, the cover joins the waveform on the right (42 pt). The
  title is not part of the strip at all (it is in the tooltip and said to
  VoiceOver, and is on the card), so the width is the same for every
  track and nothing shifts when the title changes. Width changes between
  faces ride the width clock like any other. An ask or a failure still
  takes the right shoulder from the strip, and while the Screen Bar draws
  its ears the face is the bare housing, as before. A shoulder gives its
  content `NotchIslandLayout.bodyInset` (4 pt) more at its outer end,
  because the body stands in from the frame by the top shoulder's width.
- **A one-line notice is as wide as its copy.** The words are measured at
  the line's own sizes (`NotchToy.copyWidth`) and the shape is the glyph,
  the words and the air plus the body's inset
  (`NotchIslandLayout.noticeWidth`), between 28 and 64 pt past each side of
  the notch, so "Tea done" is a 233 pt lip where it was 278 and a long line
  stops at 313, under the card's 320. The ask, meeting and level faces keep
  their own widths. The notch-less pill fits between 150 and 340.

Fades that are not springs: one face giving way to another
fades 0.18 s in and 0.12 s out; a new track's cover dissolves into the last
one's over 0.22 s (`NotchMotion.trackSwap`) while its title and byline go in
sequence, the old words out over 0.09 s and the new in over 0.15 s after a
0.07 s wait (`NotchMotion.trackSwapLevels`, `NotchTrackLine`), so two sets of
small glyphs are never both more than a fifth legible; the detached glass panels fade on
`NotchMotion.panelCurve`. The hover clocks: a direct arrival can earn the
hover mark on the same turn (`peekDelay` is 0), with `hoverDelay` (120 ms) for one that came down from the
menu bar's row,
which may only be reaching a menu; the card opens at "Open after"
(default 0.12 s, never sooner than 0.30 s from the bar's row), and a
card the pointer leaves folds after 0.10 s, so a brief leave and return
does not ping-pong it. Staying is more generous than arriving: a swell holds
for `swellGrace` (80 ms) after the pointer slips off the island, so a pointer
riding the notch's edge does not shiver it, and a grown card is not folded
while the pointer is within `leaveSlop` (8 pt) of it, at its sides and under
its foot (`NotchHoverBand`). A click on the swollen notch opens at once and
drops the dwell that was armed. With hover-to-open on, the resting shape stays
fixed until the card opens. With it off, the small swell remains. Reduce Motion has no swell at all, and a click
still just shows the card. Two-finger swipe down on the resting island opens
it and up (or down) on the card folds it; a pinch does the same.

### Page turns and the felt edges

The card has two pages, Now and Shelf, and a two-finger sideways swipe
moves between them (the tabs at its foot do the same by click).

- **The page that arrives comes from the side the fingers went**
  (`NotchPageTurn`). A swipe toward the left brings Shelf in from the right,
  a swipe back brings Now in from the left: 18 pt of slide, a 3 pt blur that
  clears and a fade that is whole by 0.6 of the spring's travel, all on the
  `pageTurn` spring. The page that left is gone in the same frame (a removal
  of nothing), so the two never share the card and the card is never taller
  than the page it shows. The header and the tab bar do not move; the shape
  still follows the new height on its own `nudge` spring. The rows used to
  swap in one frame, which read as a flicker. Reduce Motion keeps the arrival
  and drops the slide and the blur: a plain fade on the same curve.
- **Past the last page the card gives a little.** A swipe left on Shelf, or
  right on Now, turns nothing and moves the card's content 6 pt the way the
  fingers went (0.07 s out, 0.24 s back): friction instead of a wall, and the
  only answer that says "that is all there is". Reduce Motion has no nudge.
- **The trackpad taps for what a hand did** (`NotchHaptics`, one switch:
  Notch settings, "Haptic tick"). The grow taps (`generic`, as before); a swipe
  that turns the page taps (`alignment`); a swipe, pinch or pull that folds
  the card taps (`alignment`). The edge nudge, a click's fold and a hover
  leaving do not. Nothing the island does by itself ever taps (an ask, a
  notice, a timer, a quota reset): a tap is only felt while a finger rests on
  the trackpad, so a tap for news would reach the person only by accident, and
  it would be the one signal they could not learn. Reduce Motion does not
  silence it: a tap is not movement, and it is what a person who has asked
  for less movement still gets. A Mac without a haptic trackpad (or with
  trackpad haptics off in System Settings) feels nothing and loses nothing.

### The ask without a pointer

The island is never a key window, so it can never take typing from the app
in front. The ask face is the one exception, and only because a person asks:
"Show the waiting ask" (`AppCommandRouter`'s `revealAsk`: the recorded key, a
`jrbar://` link) hands the island the keyboard when an ask with a verb is on
its face (`NotchToy.engageAskKeyboard`), and opens the card as before when it
is not. From then on the window is key (`NotchIslandWindow.takeKeyboard`;
the panel is non-activating, so the terminal stays the frontmost app) and
`NotchAskFocus` reads the keys:

| Key | Does |
| --- | --- |
| Tab, Right, Down | the ring moves to the next verb, from nowhere to the first, wrapping |
| Shift-Tab, Left, Up | the other way, from nowhere to the last |
| Return, Enter, Space | presses the verb the ring is on; with the ring nowhere, nothing |
| Esc | lets the keyboard go; never denies, never dismisses |
| anything else | spent, and does nothing |

No key answers an ask by itself: engaging focuses nothing, the first press
of Return does nothing until a person has moved the ring, and Esc, a click
elsewhere (`resignKey`), 15 s without a key (`NotchToy.askKeyIdle`), the ask
being answered or replaced, and the capsule stepping down all give the
keyboard back and clear the ring. The window gives key status back by being
ordered out and in within one turn of the run loop, with no ordering
notification, so the Screen Bar's coupling does not blink.

The buttons, the keyboard and VoiceOver share one door,
`NotchToy.performAskVerb`, which first checks the verb is still on the face
(`NotchAskVerbPlan`: the same `AskVerbs` rules the buttons are drawn behind,
so a lapsed hold, an answer in flight, an ask already decided or a peer's
ask take their verbs away from the keyboard exactly as from the pointer). A
held question's options are verbs when the face draws them as buttons; when it
folds them into a menu the keyboard offers Deny and Open and leaves the menu
to the pointer and VoiceOver. VoiceOver reads the face as one item, "<who>
needs you", valued with the question, with every verb as an action on it and
as a labelled button with a hint. The ring is a white line on the verb's own
edge with a dark one inside it (so it reads on the white Approve), and the
row's left end says "Tab to choose", then "Press Return". The Settings
shortcuts page lists the key; it has no default.

### The shadow

A grown island casts a soft shadow so the black reads as hanging from the
bezel (`NotchShadow`: a tight contact layer and a wide ambient one). It is a
panel of its own, laid just under the island, that never takes a click
(`ignoresMouseEvents`) and is out of screen capture like the island, so the
island's own window never grows transparent margin. It arrives once the
shape has landed (0.22 s), lets go as a fold begins (0.12 s), is never cast
by the resting island (the bare housing is the bezel and nothing may show
around it) or the hover swell, and is parked with the island. Setting
`jrbar.notchShadow` to false in the app's defaults takes it away.

### The stage

A window the size of the island would be resized on every display tick,
and resizing a window is the dearest thing a window can be asked to
do. Alcove draws inside one fixed transparent window (624 x 320 on a
14-inch MacBook Pro) and every open-source notch app studied does the
same. JR-Bar keeps its rule that nothing transparent hangs over the
menu bar at rest, so it takes the middle road: while a move runs, the
window is a stage (`NotchStage`), set once to a frame that holds the
shape's start, its target and the spring's overshoot, and the shape
travels inside it; the instant the spring lands the window is the shape
again, exactly. `NotchIslandWindow.presentedFrame` is the shape, and it
is what the Screen Bar couples to. The faces sit in an overlay over a clear base the size of the shape, so a
face with a rigid width (the card's 320 points) can neither widen the black
nor leave it narrower than the stage says. A stage is transparent glass for the
fraction of a second it exists: the view's hover and press follow the
shape (`contentShape`), the hosting view's hit test refuses the margin,
and the window never assigns `ignoresMouseEvents`, which lets a click on
fully transparent pixels fall through. Setting `jrbar.notchStagedMotion` to false in
the app's defaults puts the old per-tick resize back.

### The motion filmstrip

Motion can be judged without a screen. `JRBAR_RENDER_PROOF=1
JRBAR_RENDER_PROOF_DIR=<folder> swift test --filter NotchFilmstripTests`
plays eleven scenarios (open, close, open interrupted at 40%, close
interrupted at 40%, notice in and out, an ask arriving, a track change, a
media strip expanding, the hover swell, and the swell followed by the open)
on an injected clock and writes, for each, `filmstrip-<name>.png` (sixteen
frames of the real island view, with the curves for width, height, content,
corner, shoulder, shadow and speed under them), `filmstrip-<name>.csv` (the
sheet's frames), `-dense.csv` (every 1/120 s: width, height, top edge,
corner radius, top flare, openness, content opacity, blur, scale and level, shadow,
foot fade, speeds) and `filmstrip-metrics.csv`. The numbers half runs in
every test run and holds the rules: the top edge never leaves the bezel,
overshoot only outward, no corner, shoulder or content step is a jump, and a
retarget at any of a hundred moments keeps the frame and the speed exactly.
The content's own clock is played alongside (`content_level` in the CSVs,
`NotchFilmstrip(directional: false)` plays the rule before it, so the two
can be set side by side): the open's content is at 10% inside 25 ms where it
was 90 ms, a fold has it at under 40% at 30 ms where it held 87%, and
a reversal at any moment steps it by less than 7% of its range in 1/480 s.
What it cannot judge is how it feels under a hand and a real display.

`JRBAR_RENDER_PROOF=1 JRBAR_RENDER_PROOF_DIR=<folder> swift test --filter
NotchPageTurnRenderProofTests` writes the page turn the same way: four
contact sheets, `notch-pageturn-before.png` (the shelf whole on the first
frame), `-after.png` (the shelf read at 0, 16, 33, 50, 66, 100, 150 and 250 ms
off the `pageTurn` spring), `-reduced.png` (Reduce Motion's fade) and
`-edge.png` (the nudge's six points). The "after" frames are the real card
view at a forced moment of its arrival (`NotchCardView.stillTurn`), because
a SwiftUI transition cannot be sampled by an injected clock; the numbers
behind them (`NotchPageTurn`, the spring) are tested without one.

## Alcove parity audit (2026-10-08)

Where the island stands against Alcove, capability by capability, read from
the code on this date. The row-by-row board with Boring Notch beside it is
[TOY-PARITY.md](TOY-PARITY.md); this is the short version with where each
thing lives and what was decided this round. Alcove's own release notes
(`github.com/henrikruscon/alcove-releases`) answered 404 on the day, so the
Alcove column rests on tryalcove.com (v1.7), its FAQ, press reviews and the
notes read for [the earlier research](archive/2026-10-07-notch-premium-research.md);
nothing here was measured on a running Alcove.

| Capability | JR-Bar today | Gap or decision |
| --- | --- | --- |
| Music live activity | Cover left of the notch and a waveform right of it at rest, a transport row, scrubbing and synced lyrics on the card (`AlcoveMediaMonitor`, `NotchIdleLayout`, `LyricsStore`) | None |
| Timer | Timers on the Shelf page, a capsule when one ends, ⌘-drag sideways on the notch sets one (`ShelfTimerModel`, `NotchTimerDrag`) | None |
| Charging, battery | A capsule on plug, unplug and full, adapter watts, time to empty on the card; low battery only while agents are working (`AlcovePower`) | No battery chip at rest. Deliberate: the strip is for agents and the icon's face carries the battery |
| Calendar, next meeting | Day glance on the Shelf with Join; a heads-up capsule two minutes before with Join, off by default (`ShelfCalendarModel`, `meetingAlerts`) | No idle "next meeting" chip. Not built: it would compete with agent state for the one strip, and the capsule already covers the moment that matters |
| Volume, brightness HUD | A level capsule out of the notch, scroll to scrub, duration setting, optional suppression of Apple's HUD (`NotchHUD`, `NotchHUDKeys`) | None |
| AirPods, Bluetooth | Name, battery and connect or disconnect (`BluetoothWatcher`) | None |
| Focus, DND | On and off with the mode's name; completions held while it is on (`FocusWatcher`) | None |
| Screen recording indicator | Mic and camera dots on the right shoulder and a "who is listening" line (`NotchSensorMonitor`) | Recording itself is Won't: it needs private CGS |
| Drag to shelf | Drop on the island, stacks, Quick Look, AirDrop, shake to summon (`ShelfTrayModel`) | None |
| Swipe gestures | Sideways on the card turns the page, on the resting island skips the track; down opens, up folds; pinch; press-and-pull; ⌘-drag timer (`NotchIslandHostingView`, `NotchToyGestures`) | The page turn was an instant swap with no answer at the edge: built this round (above) |
| Haptics | A tap on the grow | Page turn and gesture fold added behind the same switch; none for news, by decision (above) |
| Sounds | A quiet tick on HUD and device events; agent sounds on their own page | None |
| Hover | Resting shape stays fixed with hover-to-open on; card after "Open after" (0.12 s; 0.30 s from the menu bar's row), 0.10 s to fold, 8 pt of slop around the card | Motion parity is unverified. Alcove's public page gives no timings, and JR-Bar still needs installed hover/reveal acceptance |
| Lock screen | None | Won't: private SkyLight spaces end to end |
| Per display | One island, on the built-in, the main or the pointer's display; a pill on a notch-less screen, an optional synthetic housing | No Duo mode: nothing here needs a second island |
| Full screen | The island stays over a full-screen Space; hover will not grow the card while the menu bar is hidden, a click or swipe still does | None |
| Download progress, clipboard history | None | Not tracked by the board; neither is agent state |

Chosen by evidence, not by list order: the swipe is Alcove's signature move
and the one most used on a trackpad, and the page swap was the one place the
card gave no answer to it. Haptics come second for the same reason (the hand
is on the trackpad exactly when they are felt). A battery chip and a
meeting chip at rest were weighed and left out because the resting strip's
width is the first thing a person sees move, and agent state owns it.

## Window levels

| Surface | Level | Mouse | Capture |
| --- | --- | --- | --- |
| Screen Bar band + wings, peek card | `statusBar + 2` | click-through (monitors do the hit-testing); the peek card is interactive | band: normal; peek card: `.none` |
| Menu bar covers | `statusBar + 1` | click-through | `.none` |
| Menu bar appearance underlay | `statusBar - 1` | click-through | `.none` |
| Notch island (idle/notice/card) | `statusBar` | interactive | `.none` (`JRBAR_CAPTURE_CARD` dev escape) |
| Notch island's shadow | `statusBar`, ordered just under the island | click-through | `.none` |
| Notch card panel | `statusBar + 1` | click-through until pinned | `.none` |
| Item Bar | `statusBar + 1` | interactive | `.none` |
| Dock preview panel | `statusBar` while it covers the Dock's name label (the default), otherwise one level under the Dock | interactive | normal |
| Fold overlay | `screenSaver` | pass-through while unarmed | `.none` |

None of these is a status item: JR-Bar has exactly one, the icon, and the
divider is the icon's own width.

## Coordination rules

- `ScreenBarInteraction` owns the band's gestures; while
  `islandOwnsNotch` is true its pin/dismiss route to the island's
  expand/collapse and the glass card never appears.
- Menu Bar's reveal gestures only fire in menu-bar space that no other
  surface owns: the band's rect, the island's frame, and an open card are
  excluded hit regions.
- Fold arming pauses the island's interactivity (existing `foldEngaged`
  click-through) and must pause Menu Bar's reveal monitors the same way —
  a mid-fold stray gesture shouldn't pop panels.
- Menu bar tint flows to nothing automatically. An opt-in "match menu bar"
  on the Screen Bar tints the band accent; default off.
- Auto-rehide timers never fire while a pinned card or the Item Bar is open,
  nor while a mouse button is held: a ⌘-drag that brings an item back across
  the icon is never folded under the hand, and the reveal waits for the drop.
- The JR-Bar icon is the Menu Bar's divider: everything left of it is hidden
  and everything right of it stays (docs/UTILITIES.md, "Position is the
  setting"). A reveal draws the hidden items on the row; what the run right
  of the notch cannot hold at once opens in the Item Bar by itself. The
  Screen Bar's ears stop short of the system's « overflow control, which
  stays beside the hidden run, and of the divider's own item (the icon and
  the blank stretch left of it; the Screen Bar stands a layer above the
  status items and would eat the icon's clicks and the drop zone's). While a
  ⌘-drag moves items the bar holds still, and for 0.9 s after the drop
  (`MenuBarPointerGate`).
- The menu bar's escape hatch is always one click away: Show everything
  (the Menu Bar card's banner) puts every item back on the row and no rule
  outvotes it (it folds the divider away), and turning the utility off gives
  every item back. A surface that crowds the row — the Screen Bar's ears, the
  island — never silences the explanation: when macOS has no room for
  JR-Bar's icon the card says so.

## The divider through the day

The divider is JR-Bar's own status item: its length is the blank spacer left
of the icon, and macOS parks what no longer fits. Nothing else hides
anything, so the item's width is the whole mechanism. What each event does to
it (`MenuBarItemHider`, `MenuBarWakeRecovery`, `MenuBarUtility`):

| Event | What the code does | What the bar looks like |
| --- | --- | --- |
| Launch or login | `start()` installs the 30 pt floor, then the hider reconciles at once and every second; the spacer goes out after two passes agree and a second has passed since the last write (`writeCooldown`). The positional record waits 20 s (`startSettle`) and three agreeing passes. | Icon with its ‹ mark for a second or two, then the spacer: everything left of the icon is pushed into macOS's « overflow. A record write used to fold the spacer here (below). |
| Any settings write (the record, a card toggle) | `applySettings()` re-installs the boundary. It now re-applies the length the hider last wrote (`standingSpacer`); it used to write the 30 pt floor over it while the hider still believed its length stood, so nothing wrote it again. | Unchanged. Before the fix every item left of the icon came back, 24 s after launch, until the next reveal or hide. |
| System sleep, wake | `willSleep` marks the bar dark (the check is dropped). `didWake` drops the cached listing and the parked caps, wakes the listing loop, and opens a wake episode: 2.5 s of quiet (no spacer write, no parked or fit-edge lesson), one clean re-measure, then the check below. | While the Mac wakes apps put their items back one at a time and the row moves: the spacer is left as it was, so items arriving left of the icon are pushed off as they come. After about 3 s the icon is checked. |
| Displays sleep, wake | `screensDidSleep` parks the 1 Hz pass and the listing loop (nobody can see the bar). `screensDidWake` resumes both and opens a wake episode. | As above. |
| Lock, unlock; session resign, become active | The same dark and re-formed pair, from the session notices and the distributed lock notices. The hover reveal parks with them (`MenuBarReveal`). | As above. |
| Display attached, removed, rearranged | `didChangeScreenParameters`: geometry dropped, the fit edge reloaded for the new main screen's size, caps reset, a wake episode opened, a reconcile now (its write held by the quiet). The drag environment invalidates a drag in flight. | The spacer is rewritten once the bar has settled, from the new boundary frame and fit edge. The fit edge is keyed on `NSScreen.main`, so which display counts as main decides which edge is used. |
| Space or full-screen change | `activeSpaceDidChange` opens an episode too. While a full-screen app hides the menu bar (`barShowing` false) no parked-cap or overflow lesson is learned and nothing is judged: a boundary found off the row then is the bar leaving, not a spacer too long. | Nothing changes. Before, each full-screen visit could lower the spacer's cap by 40 pt and leave items drawn on return. |
| Another app adds or removes a status item | The launch or quit bumps the bar's activity; the next scan reconciles. The icon's right edge moves, and the spacer follows it: longer after two agreeing passes and a second, shorter only after 5 s (`shrinkHold`, so the screen-recording indicator does not make it dance). | An item added left of the icon is hidden at once by position. For about a second after an item leaves the right side the spacer is a little short and an item may peek out at the « end. |

**After the bar re-forms** (`MenuBarWakeRecovery`, the wake, display, session,
unlock and Space rows). The hider leaves the spacer alone while the bar forms
(2.5 s after the last event, never more than 10 s after the first), forgets
what it learned, and then looks at the icon on two fresh listings in a row:
on the row, the width JR-Bar wrote, and clear of other apps' items (only the
icon's own face counts, not the spacer's stretch, where pushed items pass).
All three hold: nothing is written. If not, the spacer is folded and written
again once, which makes macOS sort the row afresh, and the icon is checked
again. If it is still wrong JR-Bar stops there and "What JR-Bar sees" says
which of the three it is, and that macOS keeps the order. The next wake earns
one new try. An icon that is the wrong width for three passes with no event at
all opens one such check of its own. Nothing polls: the checks ride the scans,
the 1 Hz pass and at most three timed passes per episode.

**An item left of the icon that the spacer cannot cover.** The spacer is the
icon's right edge less the fit edge (the notch's right edge plus 54 pt on a
notched bar), held under a learned cap and half the screen's width. The cap
drops 40 pt each time macOS parks the icon under a long spacer. While the
spacer is held 8 pt or more short, the items left of the icon that it cannot
push off the row are covered in place, as an override's items are, and the
card says how far short it is. A notch-less bar has no notch to measure from:
its first guess is the screen's middle, and the edge only ever moves right,
so items packed between the front app's menus and the middle of the screen
are not pushed off. That is a known gap, not something JR-Bar hides.

## Persistence

- Toy state → `AppState.toys`; utility state → `AppState.utilities`; the
  Aquarium's game → `aquarium-save.json`; setup progress → `setup.json`.
- Apple's own state we change (Control Center item visibility, Dock
  autohide) is always read first, saved, and restored on
  disable/quit/terminate.
