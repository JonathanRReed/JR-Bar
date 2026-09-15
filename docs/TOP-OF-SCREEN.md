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

`ScreenBarGeometry` is the only source of notch truth: `notchDepth`,
`slotWidth` (auxiliary-areas gap), `preferredScreen`, band rects, wing
extents, corner radii from `NotchProfile`. Nothing else measures the notch.
Menu Bar's "beat the notch" (items that would land under the notch auto-hide)
reads `slotWidth`; the Dock's top-edge option and per-display docks resolve
through `preferredScreen`.

## Window levels

| Surface | Level | Mouse | Capture |
| --- | --- | --- | --- |
| Screen Bar band + wings | `statusBar + 1` | click-through (monitors do the hit-testing) | `sharingType = .none` |
| Menu bar appearance underlay | `statusBar - 1` | click-through | `.none` |
| Notch island (idle/notice/card) | `statusBar` | interactive | `.none` (`JRBAR_CAPTURE_CARD` dev escape) |
| Item Bar / notch card fallback / popovers | `statusBar + 1` | click-through until pinned | normal |
| Dock panel | `floating` | interactive | normal |
| Fold overlay | above all | pass-through while unarmed | — |

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
- Auto-rehide timers never fire while a pinned card or the Item Bar is open.

## Persistence

- Toy state → `AppState.toys`; utility state → `AppState.utilities`; the
  Aquarium's game → `aquarium-save.json`; setup progress → `setup.json`.
- Apple's own state we change (Control Center item visibility, Dock
  autohide) is always read first, saved, and restored on
  disable/quit/terminate.
