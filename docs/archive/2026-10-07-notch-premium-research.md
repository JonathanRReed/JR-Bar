# Notch island: why it did not feel like Alcove, and what we took

Researched and written 2026-10-07 for the notch-premium lane. The ask:
"the notch still doesn't feel like an alcove; it doesn't feel premium."
An earlier round made the geometry exact (pixel-snapped hardware rectangle,
concave top shoulders, settled frames) and it still did not feel right.
This note records what we studied, what we found in our own code, and what
we adopted or turned down. Tokens and the choreography they drive are in
[docs/TOP-OF-SCREEN.md](../TOP-OF-SCREEN.md), "Motion".

Nothing here was copied. Boring Notch, Mew Notch and Atoll are GPL-3.0 and
were read for behaviour and numbers only; DynamicNotchKit is MIT; Alcove and
NotchNook are closed source and were studied from their public pages,
release notes and reviews. The attribution entry is in
[docs/PRIOR-ART.md](../PRIOR-ART.md).

## What the others do

**Alcove** (tryalcove.com, v1.7, Henrique Lorente; closed source). The
marketing page promises "fluid transitions", "instant notifications", live
activities, swipe gestures and customizable HUDs. The motion detail is in the
public release notes (<https://github.com/henrikruscon/alcove-releases/releases>,
1.6.5 to 1.7.2), which read as a record of where the hard problems were:
expand, collapse, HUD, hover and cycle stutters fixed one after another;
"corner radius frame skip" (1.6.9); "expand state stuck after hover in rare
situations"; "race condition hover freeze" (1.6.7); AppleScript work stalling
the animation; idle frame rate lowered to cut energy (1.6.11); a "HUD
overshoot" feature added (1.6.6) and later forced on (1.6.13); blur on swipe
to expand and progressive blur (1.6.9, 1.6.14); a hover duration setting;
haptics; limiting a swipe to one action; a pill for notch-less displays (1.7.0).
Our own live inspection of 1.7.9 (see `AlcoveGeometry`) found the capsule drawn
inside one fixed transparent 624 x 320 window. No spring numbers are public.
MacStories' review is headlined "An Excellent Notch Utility with Beautiful
Animations".

**Boring Notch** (TheBoredTeam, GPL-3.0, commit `e2654ee4`). One fixed panel
(640 x 210) at the top of the screen; SwiftUI animates the shape inside it.
Open on `spring(response 0.42, damping 0.8)`, close on `spring(0.45, 1.0)`
(critically damped), hover and gestures on an interactive spring (0.38, 0.8);
the expanded content enters with `scale 0.8 from the top + opacity` over
`.smooth(0.35)`; corner radii animate (top 6 to 19, bottom 14 to 24); a soft
black shadow (0.7, radius 6) only while open or hovered; a 1 pt black bar
over the top edge hides the hairline; hover opens after 0.3 s, a leave
closes after 100 ms and a new hover cancels it. Its issues name the same
failure modes as Alcove's notes: laggy open gesture (#134), flicker on
brightness change (#1110), a stuck hover (#1359).

**DynamicNotchKit** (MrKai77, MIT, `cd0b3e52`). The library several apps
build on. A fixed window sized for animation headroom; `bouncy(0.4)` open,
`smooth(0.4)` close; content transition is blur 10 + scale + opacity, the
expanded content scaling in from 0.6 at the top; a black rectangle padded
under the shape so overshoot never shows a gap; shadow 0.5 to 0.8 opacity,
radius 10 to 20, growing on hover. Its maintainer documents that a window
that never assigns `ignoresMouseEvents` passes clicks through fully
transparent pixels, and that assigning `false` explicitly turns that off for
the window's life (issue #48).

**Mew Notch** (monuk7735, GPL-3.0, `2b909a58`): `bouncy(0.4, extraBounce 0.1)`
open, hover scales the island 1.1 and fires a haptic, a 0.5 s default hover
delay, radii 8/13 closed and 8/24 open. **Atoll** (Ebullioscopic, GPL-3.0,
`903d1ed3`, a Boring Notch fork): critically damped open and close, hover on
`bouncy.speed(1.2)`, content swaps with `blurReplace`. **NotchNook** (lo.cafe)
and **DynamicLake**: closed, marketing only; no numbers.

**Apple.** WWDC23 "Animate with springs": springs retarget without a restart
and keep their velocity; about 15% bounce is subtle and above 0.4 is
exaggerated for UI; the presets are `smooth` (no bounce), `snappy` (a little)
and `bouncy` (more). Apple's own pages give no Dynamic Island timings and the
HIG motion page did not load, so the island's shape is taken from what the
clones converge on: a slightly underdamped open, a critically damped close,
content that blurs and scales in behind the shape.

**macOS pitfalls.** All four open-source apps and Alcove animate a shape in a
fixed window and never resize the window per frame. The click-through of
transparent pixels is OS behaviour that Apple's forums report broken in
macOS 26.3 RC and again in a 26.4 beta, so a design should not lean on it for
anything that lasts.

## What we found in our own code

1. **The frame was the only thing that was resized, per tick.** Every display
   tick the island called `setFrame` on its window, and the Screen Bar
   followed with a second window resize on the same notification. Measured in
   isolation the SwiftUI layout for that is cheap (0.3 ms a tick for the real
   card on this Mac), so the cost is the window server's and the band's, which
   cannot be measured without a screen; but it is exactly the thing the apps
   people compare us with do not do.
2. **Two clocks.** The shape ran a spring (0.42 / 0.78 to grow, 0.32 / 0.9 to
   fold); the content swap ran a different SwiftUI spring (0.32 / 0.82) on
   the face; the rows gated on a 60% threshold then faded on a third clock
   (0.12 s ease-out, 20 ms stagger); the hover marks used a fourth (0.22 /
   0.75). They agreed by luck and never after a reversal.
3. **The header was there from the first frame**, fully opaque, clipped by a
   shape a few points tall; the rows came in on opacity alone. No blur, no
   scale, no lift: the content did not condense out of the notch, it was
   uncovered.
4. **A fold dropped the content on the face's spring**, not the shape's, so
   rows were cut by the shrinking silhouette while still opaque.
5. **The hover swell and the card opened on the same instant** by default
   ("Open after" 0.12 s, swell delay 0.12 s), so there was no anticipation.
   The swell also rode the 0.42 s grow spring, sluggish for a 2 to 4 pt move.
6. **The integrator ran ahead of its own curve.** Semi-implicit Euler at a
   fixed 1/120 sub-step is about half a sub-step (4 ms) ahead of the
   closed-form spring early in a move (63 pt against 54 pt at 25 ms), and
   what the tokens say is not what drew.
7. **No edge**: a pure black body on a dark desktop with nothing marking its
   lower edge.
8. Timing literals scattered over five files (HUD 0.22/0.12/0.2/0.16, glass
   card 0.18/0.12/0.24, island view 0.18/0.14/0.15/0.12, row fade) and a dead
   helper (`idleCenterX`).

## What we adopted

- **A fixed window during motion** (Alcove, Boring Notch, DynamicNotchKit,
  Atoll, Mew Notch), reimplemented as a stage that exists only while a move
  runs, so the old promise that nothing transparent hangs over the menu bar
  at rest still holds. Reasoning in TOP-OF-SCREEN.md.
- **Asymmetric springs**: lively open, damped close (Boring Notch, Atoll,
  DynamicNotchKit).
- **Retarget without restart, velocity carried** (WWDC23), already true of
  our spring, now proved by test and exact.
- **Blur plus scale plus opacity as one sheet that follows the shape**
  (DynamicNotchKit, Boring Notch, Alcove's blur on expand).
- **A swell that leads the card** (Mew Notch's hover scale, Boring Notch's
  hover spring, Alcove's hover-duration setting).
- **A one-point light on the lower edge**, in place of the soft drop shadow
  the others draw.
- **Reduce Motion as a crossfade with no swell**, on one tested branch.

## What we turned down

- **A drop shadow** (Boring Notch 0.7 / 6, DynamicNotchKit 0.5 to 0.8 / 10 to
  20). It needs window padding, and window padding is exactly the
  transparent area that swallows menu-bar clicks. The edge light does the
  job of separating a black body from a dark desktop without leaving the
  shape.
- **Opening on a bounce past 0.3 / critical close everywhere** (Atoll): a
  critically damped open reads as sluggish next to Alcove.
- **A permanent fixed 640 x 210 window** (Boring Notch): leans on the OS
  click-through that regressed twice in one year.
- **Dropping the track title from the resting island** (Dynamic Island's
  compact leading and trailing). The resting island carries a title strip
  that makes it 495 pt wide beside a playing track, which is the clearest
  remaining gap against Alcove, but with the Screen Bar's ears on (the
  daily setup) the ears carry that strip, so it is a follow-up for the
  Screen Bar, not a change to make blind here.
- **A level HUD that flanks the notch** (icon left, value right, one row)
  rather than dropping a lip: also a follow-up; nothing public confirms
  Alcove's exact layout.

## What could not be verified

No spring numbers for Alcove exist outside its binary, and this lane could
not watch the real animation. The tokens are therefore ours, reasoned from
the clones and from the failure list in Alcove's own release notes, and the
hand-check in the lane report is the way to compare them. The click-through
of a stage's transparent margin is OS behaviour that was not exercised
(the lane never posts input); the stage exists for under half a second and
refuses its margin in the hit test either way.
