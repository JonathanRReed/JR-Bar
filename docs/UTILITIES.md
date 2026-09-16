# Utilities

Utilities are the serious half of JR-Bar: features that manage the Mac's own
surfaces rather than play on them. Toys never touch agents; utilities never
touch agents either — they touch *macOS*. The distinction that decides where a
feature lives:

- **Toy**: a thing you turn on for fun or focus (Fold, Aquarium, Notch Buddy,
  Confetti). Lives on the Toys page.
- **Utility**: a thing you turn on to replace another app (Notch island,
  Dock, Menu Bar, agent Overview). Lives on the Utilities page.

Notch stays callable a "toy" internally only for history — the card code is
the same shape; the page it sits on is Utilities.

## Page layout

`SettingsStore.Page` gains `utilities`, placed **after `devices`** and before
`lighting`. The sidebar stays flat (sections are a separate cohesion pass).
Toys page keeps Fold, Aquarium, Notch Buddy, Confetti — in that order — and
loses the Notch card and the future Dock card to Utilities.

Utility cards reuse `ToyCard`'s shape (DisclosureGroup: tinted symbol tile,
name + blurb, status chip, on/off toggle, controls in the body) via a shared
`UtilityCard`/`ToyCard` common shell — one visual language, two registries.
State lives in `UtilitiesState` (JRBarCore, tolerant `Codable`, same pattern
as `ToysState`) persisted in `app-state.json` under `utilities`, managed by a
`UtilitiesStore` mirroring `ToysStore`. Old `ToysState.notch` decodes into
`UtilitiesState.notch` — the legacy `alcove`→`notch`→`utilities.notch` chain
must keep working end to end.

## Menu Bar (vs Ice, Bartender 7)

Replaces Ice and Bartender 7. Both are reference apps only: Ice is GPL-3,
Bartender is closed — **clean-room**, no code, no verbatim assets.

> **Status — what is built.** The positional section model, the
> spacers, the override covers, the reveal gestures, the Item Bar (live
> tiles + `AXPress` click-through), the per-item override pickers, the
> arrange editor, the ⌘⇧K command bar, hotkeys, triggers, profiles,
> cover appearance, and the combined control.
>
> **How hiding works on macOS 26 — verified live (2026-09-15).** macOS 26
> packs the status region right-to-left and *parks* whatever no longer
> fits in its own overflow (the "Show Hidden Menu Bar Items" control
> MenuBarAgent draws). A 3 000-point item is parked itself; a 250-point
> item inserted mid-row stays and pushes everything left of it into that
> overflow, with no holes. So **JR-Bar's own status item is Bartender's
> separator**: items left of it are hidden, and hiding is the item's
> own `length` growing a blank spacer left of its icon
> (`StatusItemController.boundarySpacer`) that reaches the **fit edge**
> — the screen x where a spacer's left edge may land and still be
> drawn (macOS draws a status item only when it fits in the visible
> run; one that reaches too far is overflowed with its glyph and hides
> nothing visibly). The edge is a property of the screen: it starts
> `fitInset` (54 pt, measured) right of the notch's edge, moves right by
> a step only when macOS's own `«` lands on the icon's glyph — the
> proof of an overflowed boundary — on a listing taken after the
> reflow, is never moved left on its own, and is remembered per screen
> size in `UserDefaults`. The `«` itself stays visible beside the run
> (it draws above any panel of ours; it says "more here", which is
> true) and the Screen Bar's right ear narrows to stop short of it.
> Revealing collapses the spacer and the run packs back where it was;
> a click on the blank stretch, a hover on it, or a scroll over the
> bar is the reveal, and the icon's right-click menu carries a "Hidden
> Menu Bar Items" submenu. There is exactly one
> status item of ours on purpose: a second one (the old always-hidden
> control, `···`) swapped places with the boundary on every reflow —
> a length write re-sorts the bar, and two of our keys straddled the
> spacer's range — and each swap changed the spacer again, a
> two-state dance at three beats a second. "Always hidden" is an
> override (a cover where the item sits) rather than a second
> boundary. Length writes are damped: a length goes out only when two
> passes in a row want it and a second has passed since the last
> write, except after a reveal or a hide, which write on the spot. A
> control found parked (its spacer did not fit under a wide app menu)
> lowers a learned cap and collapses; caps reset on screen changes and
> when the frontmost app changes. A separate chevron item remains only
> as the fallback when no host is wired (tests).
>
> Foreign items are never moved by the utility: the person ⌘-drags items
> across the controls to choose sections, exactly as with Bartender. The
> section map is *overrides only* — an item marked Cover/Always by hand
> while it sits right of the chevron is covered in place by a borderless
> `.menu`-material panel at `statusBar + 1` (a hole, and honest about
> it). Files from the cover era, whose map assigned every item hidden,
> are cleared once on first apply (`layoutModel` 0 → 2). The controls
> seed once at fixed slots and the person ⌘-drags them from there — an
> automatic seat next to JR-Bar's own item was tried and removed: a
> status item's preferred position is a sort key against other apps'
> stored keys, not an x, and steering it blind put the controls in the
> wrong place on a real bar.
> Physically reordering items is possible only via synthetic ⌘-drags —
> which move the person's real cursor — so `MenuBarItemMover` runs only
> inside the explicit, cancellable arrange mode and has no background
> call sites.

### Item management

- Three sections: **shown** (right of the chevron), **hidden** (left of
  the chevron — packed off by its spacer, reveal via the chevron or a
  gesture), **always-hidden** (left of the ··· control — its own spacer,
  reveal via the Item Bar). **Built.**
- Reveal triggers: hover over the menu bar's empty space, click empty space,
  scroll/swipe on the menu bar, hotkey per section. Auto-rehide after N s
  (default 4, off when the Item Bar panel is pinned). **Built** except the
  per-section hotkeys (phase 2).
- **Item Bar**: a floating panel under the menu bar (Liquid Glass — it floats)
  listing hidden items as tiles. **Built**: owner-icon tiles, `AXPress`
  click-through (reaches covered and system-parked items), ⌘-click pulls a
  tile up a section, a reposted-click fallback when the element cannot be
  re-resolved. **Planned**: `SCScreenshotManager` live tiles at 2 Hz —
  never a stream, so no capture indicator.
- Items that would land under the notch auto-move to hidden ("beat the
  notch") using `ScreenBarGeometry.slotWidth`. **Planned.**
- **Layout editor**: drag-to-arrange within a live snapshot of the bar.
  **Planned** — and arrange is the *only* place synthetic ⌘-drags may run,
  inside an explicit mode the person entered deliberately, because a posted
  drag moves the real cursor. Items that can't be moved (Siri, clock) are
  marked and skipped.
- **Item search / Command bar**: ⌘⇧K or click on the JR-Bar item's menu —
  fuzzy search over every menu bar item (shown + hidden), Return triggers it.
- **Spacing**: per-item padding adjustments via spacer status items where
  Apple's item allows, plus a global "compact / default / roomy" that also
  tightens our own items. Marked *best-effort* — macOS may ignore it for
  items that fix their own width.
- **Profiles**: named layouts (shown/hidden sets + spacing + appearance);
  hotkey or trigger to switch; per-display override.

### Appearance

- Menu bar background: none / solid / gradient / glass, opacity + tint;
  shadow and bottom border toggles; rounded corner option; light/dark
  independent overrides. Drawn as an underlay panel at `statusBar - 1` level,
  click-through, sized to the menu bar rect, `sharingType = .none` so Fold's
  capture doesn't double-draw it.

### Triggers

Rule list: *when* (battery unplugged / on <N>% / charging; Wi-Fi network name
match / public vs known; Bluetooth device connects; audio output changes;
Focus mode starts; app launches/quits; time of day; display attach) *then*
(show item / hide item / apply profile / open Item Bar). Evaluated off the same
monitors we already run (`AlcovePowerMonitor`, CoreWLAN, audio route
listener, `CoreState.focus`, `NSWorkspace` notifications). Off by default,
each rule individually removable.

### Hotkeys

Carbon `RegisterEventHotKey` like `PanelHotkey`: toggle each section, open JR
Bar, open search, toggle app menus. Recorded in Settings as a key field.

### The combined system item ("Status")

A second `NSStatusItem` JR-Bar owns that can absorb Apple's items. Each
absorption is individually opt-in; absorbing one writes the matching
`com.apple.controlcenter "NSStatusItem Visible …" 0` default (the same key
System Settings writes) and restores the prior value on un-absorb/disable/
quit — the Dock Replace save-and-restore pattern.

- Absorbable: **Battery**, **Wi-Fi**, **Bluetooth**, **Sound**, **Focus**.
  Clock and Siri are never absorbed (can't be; they're drawn inline).
- **Variants** (`StatusIconStyle`-style picker, lives on the Utilities card
  not the General page):
  - **Fold** — the Orbit form: outer ring = battery, centre glyph = Wi-Fi
    strength, the gap-dots = working sessions (amber if any ask). The dots
    replace "cellular signal" with the thing you actually check.
  - **Strip** — tiny monochrome inline glyphs, tighter than Apple's set.
  - **Agent** — JR mark tinted by agent state, battery as ring, tightest
    usage window as an arc segment.
  - **Text** — "87% · 2 working · Claude 56%".
- Click opens one popover: battery detail (cycle count, time-remaining),
  Wi-Fi (network name, deep-link into Control Center's Wi-Fi panel for
  switching), Bluetooth devices (deep-link), volume slider (via the audio
  HAL, output device only — the existing "no certified volume read" caveat
  applies: show it as a slider that writes, never a level that reads back
  live), Focus picker (reads `CoreState.focus`), and the agent rows the
  notch card already shows.
- Feeds reuse existing monitors: `AlcovePowerMonitor` (battery), CoreWLAN
  (Wi-Fi — SSID needs Location permission; degrade to signal-strength-only
  without it), `ScreenBarAudioMonitor` (route), `CoreState.focus`
  (daemon-side, needs the Focus toggle + FDA), `core.sessions` (agents).

## Agent Overview

The utility that replaces "a dozen terminal tabs you can't see": one card
summarizing every live agent session `CoreModel.sessions` knows about, plus
a **Full overview…** button that opens the existing Overview window (list +
force-directed graph).

- **Counts that matter**: sessions grouped by state (working, asking,
  done, idle) and by provider; asks always surface first — a pending ask
  is the thing that stalls a run.
- **Quick actions** ride the existing `CoreModel` commands — open the
  session, approve/deny an ask, dismiss, snooze, clear completed, undo
  the clear, copy the working directory, reveal it in Finder. Nothing is
  re-tracked; the card is a lens over the daemon's session feed.
- Settings: enabled toggle plus which state groups count toward the
  card's badge; the session source of truth stays `CoreModel` either way.

## Cohesion contract

`docs/TOP-OF-SCREEN.md` owns the cross-surface rules; the short version:

- Glass only on what floats. Anything growing from the notch is black.
- One surface per role: the notch card IS the island when the Notch utility
  is on; the hidden-items panel IS the notch card's bottom row when both
  Notch and Menu Bar are on (the glass Item Bar only when the island isn't
  drawn).
- `ScreenBarGeometry` is the single source of notch truth for all of them.
- Menu bar tint flows to the Screen Bar band accent when "match menu bar" is
  on (default off — the LED band keeps its own colour unless asked).

## Permissions

| Feature | Needs | Without it |
| --- | --- | --- |
| Hide/show items, sections, Item Bar (icon tiles) | nothing extra | full |
| Live tiles in Item Bar | Screen Recording | app icons instead |
| ⌘-drag arrange, click-through to real items, triggers on click | Accessibility | arrange + click disabled, search still opens item's app |
| Wi-Fi network name | Location | shows strength glyph only |
| Focus readout | daemon Focus sync (FDA) | Focus row hidden |
| Hide Apple's Battery/Wi-Fi/etc. | nothing (user defaults) | — |

Every card row names the missing permission and deep-links to the Setup
page's permission step.
