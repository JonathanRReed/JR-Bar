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

> **Status — what is built vs planned.** Built: the section model, the
> covers, the reveal gestures, the Item Bar (icon tiles + `AXPress`
> click-through), first-enable seeding, and the per-item section pickers.
> Planned (phases 2–3): live-capture tiles, the arrange editor, command
> bar, hotkeys, triggers, profiles, appearance, the combined Status item.
>
> **How hiding works on macOS 26 — verified live.** A foreign item cannot
> be evicted: oversized status items, remove/reinsert, `isVisible`, and
> off-screen drops were all tested and all leave the item drawn. So JR-Bar
> *covers* assigned items where they sit — borderless panels at
> `statusBar + 1` backed by `.menu` material, opaque to the items beneath
> and reading as ordinary empty bar. Items are never physically moved and
> the pointer is never touched; the covers swallow clicks (which double
> as the reveal gesture) and `AXPress` still reaches a covered item.
> Physically reordering items is possible only via synthetic ⌘-drags —
> which move the person's real cursor — so `MenuBarItemMover` exists
> solely for a future explicit, user-initiated arrange mode and has no
> background call sites.

### Item management

- Three sections: **shown**, **hidden** (covered in place, reveal via the
  chevron or a gesture), **always-hidden** (deeper hide, own reveal
  gesture). **Built.**
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
