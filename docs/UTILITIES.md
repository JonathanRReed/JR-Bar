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
> cover appearance, the combined control, and the provider picker —
> the card's "Render with" hands the whole surface to an installed
> counterpart (Bartender, Ice, Hidden Bar; `MenuBarSettings.provider`)
> and parks our engine while the pick stands, with a live
> installed/running note that flips on workspace launch and quit.
>
> **The boundary affordance stands under the spacer engine.** While the
> utility is on and the spacer engine runs, the JR-Bar item keeps a
> 30 pt drop zone with a ‹ mark inside it
> (`MenuBarUtility.boundaryAffordance` → `StatusItemController`'s
> folded face) — the separator the person ⌘-drags items across, visible
> whether or not anything is hidden yet. The concealer claims none: the
> width pushed the item's slot into the notch dead zone and parked it.
> There the mirror's ‹ is the mark (below).
>
> **How hiding works on macOS 26 — verified live (2026-09-15).** macOS 26
> packs the status region right-to-left and *parks* whatever no longer
> fits in its own overflow (the "Show Hidden Menu Bar Items" control
> MenuBarAgent draws). A 3 000-point item is parked itself; a 250-point
> item inserted mid-row stays and pushes everything left of it into that
> overflow, with no holes. So **JR-Bar's own status item is Bartender's
> separator**: items left of it are hidden, and hiding is the item's own
> `length` growing a blank spacer — the spacer engine, below.
>
> **macOS 27 (this Mac): the concealer.** The menu bar is one surface
> `MenuBarAgent` draws, and the utility drives the agent's own
> assessment mode through the private `MenuBarClientCore` framework
> (`MenuBarConcealer.swift`, facts in docs/PRIOR-ART.md): an allowlist
> of running apps stays, the agent conceals the rest and repacks the
> row. No spacer; the native « appears only on a bar too crowded for
> what stays. Sections are per app (`concealedApps`) and explicit: an
> app is hidden only when the person picks it — with a ⌘-drag across
> the icon (below), in the card's overrides, on an Item Bar tile, in the
> icon's menu or in the ⌘⇧K palette — and nothing is ever learned from
> where an item happens to sit. Apple's own extras and bare helpers have
> no path through the agent and take a cover where they sit, unless
> `curation.concealAppleExtras` lets Weather, Passwords and Time Machine
> hide like any app (off until a live probe shows they conceal
> cleanly). Reveal = invalidate, rehide = re-activate, a new
> assertion goes up before the old comes down; clicks on the agent's own
> clock/battery/Wi-Fi are held at an event tap, lifted for and replayed.
>
> Under the concealer macOS never draws JR-Bar's own item: the agent
> exempts by signing identity, and the helper that holds the assertion
> shares ours (measured 2026-09-22). The real item goes slim and blank,
> and `MenuBarIconMirror`, a panel at `statusBar + 1` wearing the face
> the item would wear, is the icon. It stands flush left of the first
> drawn item with room for it, clear of the notch, the Screen Bar and
> the front app's menus: the right end of the empty bar left of what
> stays drawn, where Bartender keeps its icon. It answers clicks the way
> the real button does: a left click opens the panel, a right, ⌥ or
> Control click pops the full menu, and its ‹ toggles the Item Bar. The
> empty bar left of it is the hover and click reveal zone. When no
> mirror stands — the Hidden icon style, or a target with nothing
> running to conceal, where macOS draws the real item again — the ‹
> moves to the Screen Bar's right ear. Everything below describes the
> **spacer engine**, the fallback where the framework does not resolve.
>
> The spacer engine: JR-Bar's
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
> Menu Bar Items" submenu. The click answers in the Item Bar, not the
> row: macOS only un-parks what fits, so a ‹ or › click toggles the
> Item Bar open or closed (the run follows), and an empty run pops
> the hidden-items menu with a teach row — a click is never dead. There is exactly one
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
> JR-Bar never moves an item and never posts a drag: a synthetic ⌘-drag
> moves the person's real cursor. The person's own ⌘-drag is the only
> thing that reorders the bar.

### ⌘-drag across the icon (macOS 27)

Bartender's, Ice's and Hidden Bar's habit, under the concealer
(`MenuBarDragLearn`, `MenuBarUtilityDrag.swift`; on by default,
`curation.dragToHide`, card row "⌘-drag across the icon hides or
shows"). ⌘-drag an item and drop it left of the JR-Bar icon: its app
hides. Drop it right of the icon: it shows. Hold ⌥ at the drop for
Always Hidden; a hide keeps an existing Always, and a drop that lands
the app where it already is writes nothing (a reorder is only a
reorder). A drop on the icon itself does nothing.

- **Where it is heard.** The click bridge's event tap (the one that
  already lifts the clock, battery and Wi-Fi for a click) passes every
  ⌘-press straight through — it used to turn a ⌘-drag of Wi-Fi into a
  plain click — and reports the press and the release that ends it.
  With the tap down, the reveal's own discrete monitor (mouse-downs and
  mouse-ups) stands in. Nothing is posted; the pointer is the person's.
- **One drag, one write.** The press notes the drawn item under it —
  never ours, never the «, never a concealed app's Accessibility ghost —
  and the icon's span as the person saw it. The release reads the drop's
  side, waits 0.6 s for MenuBarAgent to persist the move, reads a fresh
  listing, and writes one section through the same path the pickers take
  (the active profile's delta when that profile already speaks for the
  app, else the base). A listing that changes on its own never writes:
  no press, no write — the lesson of `424c08ad`, pinned by a test.
- **A whole-bar shift is not a move.** Every ScreenCaptureKit capture
  lights the recording indicator and shifts the bar about 56 pt. The
  confirm measures the item against the clock (or Control Center) read
  in the same pass and needs a real reorder; when the anchor itself
  moved, or Accessibility did not answer, only a drop that crossed the
  icon is believed (or, when granted, the layout table read after it).
- **Frozen while it lasts.** From the press until 1.2 s after the write
  (through `shrinkHold` when the bar shifted), the icon keeps its right
  edge, the hover reveal stands down (so the drop no longer pops the
  Item Bar), and an inline reveal's rehide clock re-arms. A held mouse
  button suppresses the hover reveal too.
- **Never silent.** A drop that asked for something says what happened
  for four seconds under the icon, in the Item Bar's own glass: macOS's
  own item ("macOS keeps Wi-Fi, the clock and Control Center — hide them
  in System Settings › Menu Bar"), an Apple extra that took a
  cover, another display's bar, an app with several items ("Hid all of
  iStat Menus's items"), or a drop macOS did not take.
- **Limits.** Apps hide as a whole (a platform limit Bartender, Thaw and
  Ice share). Only the main display's bar carries the icon. The start
  of a run (the 2.5 s adoption grace) learns nothing.
- **Show hidden items while ⌘-dragging** (`revealWhileDragging`, off):
  Ice's reveal — the hidden run comes in beside the icon for the drag
  and the ‹ becomes a thin divider. Off by default: MenuBarAgent may
  drop a drag when the assertion changes under it.
- **Drag a tile out of the Item Bar** onto the bar right of the icon to
  show its app — the bar's own drag session, read where it ends.
- **The icon's seat** (`mirrorSeat`, Advanced › Icon seat): beside the
  first shown item (today) or on JR-Bar's own slot, with the real item
  sized to the icon (rounded up to 8 pt, grown at once, shrunk only after
  5 s) so "left of the icon" is the agent's own order.
- **The layout table** (Advanced › Menu bar layout table): pick
  `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/
  com.apple.MenuBar.plist` once in an open panel (with Full Disk Access
  already granted, the click reads it with no panel) and JR-Bar reads
  `TrailingItemPreferredPositions` — read-only, watched, never written.
  It orders the Item Bar and the layout editor, backs a drag's confirm
  when Accessibility is slow to answer, and — on the slot seat, where
  the icon's sides are macOS's order — flags an app whose section and
  place disagree with a one-click section fix (a pick, never a move).
  The file's shape is unverified until a real grant; the parser takes
  the likely forms.
- **The clock and Control Center** (`concealSystemItems`, off,
  experimental, no card row): a ⌘-drag may hide them through the
  assertion's system item list. Wi-Fi, the battery and sound always
  stay. It stays off, and out of the card, unless a live probe shows
  they conceal and come back cleanly.
- **Apple's extras** (`concealAppleExtras`, the card's "Hide Apple's
  extras like apps"): a file that never chose follows the code default,
  and only a choice made on the card is written — so the default can
  flip once the live probe passes and reach every file that never chose.

Also in this pass: **New menu bar items** (`newItems`: where macOS
puts them and the ear asks, straight to Shown, or straight to Hidden),
**Item Bar opens at** the icon or the pointer (`itemBarAt`), **Tuck
away when you switch apps** (`RehideMode.focusChange`, Ice's smart
rehide), keep-awake rule actions (keep awake for N minutes, until
released, or let the Mac sleep — the Keep Awake card's own hold), and
**Relaunch menu bar apps** under the spacing dial: items take a new
spacing only as their apps relaunch, so a confirm lists the apps it will
quit and reopen. It never runs on its own and never touches Apple's.

### Item management

- Three sections: **shown** (right of the JR-Bar icon), **hidden** (left
  of the icon — packed off by its spacer, reveal via the blank stretch
  or a gesture), **always-hidden** (an override only: a cover where the
  item sits, hidden even while the run is revealed, reachable through
  the Item Bar). **Built.**
- Reveal triggers: hover over the menu bar's empty space, click empty space,
  scroll/swipe on the menu bar, hotkey per section. Auto-rehide after N s
  (default 4, off when the Item Bar panel is pinned). **Built** except the
  per-section hotkeys (phase 2).
- **Item Bar**: a floating panel under the menu bar (Liquid Glass — it floats)
  listing hidden items as tiles. **Built**: owner-icon tiles, `AXPress`
  click-through (reaches covered and system-parked items), ⌘-click pulls a
  tile up a section, a reposted-click fallback when the element cannot be
  re-resolved, `SCScreenshotManager` live tiles at 2 Hz with icon fallback —
  never a stream, so no capture indicator (see docs/TOY-PARITY.md).
- Items that would land under the notch auto-move to hidden ("beat the
  notch") using `ScreenBarGeometry.slotWidth`. **Built** (see docs/TOY-PARITY.md).
- **Layout editor**: three rows (Shown, Hidden, Always) of the items' own
  glyphs; dragging a tile to another row is a pick through the same write
  the pickers make — never a move on the bar. With the layout table
  granted, the rows follow macOS's own order. **Built.**
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
a **Full overview…** button that opens the Overview window (sortable roster
table + inspector) — its own independent panel, opened from the app
menu, the status-item menu, the notch card, the utility card, or ⌘O.
The Obsidian-style force-directed session graph was removed: the Aquarium
and the agent Overview are the ambient surfaces now, not a separate
constellation map. The After Dark / flying-toaster screensaver lineage is
likewise gone — same reason.

- **Connections browser**: the Overview's idle inspector is a wiring
  diagram of everything the daemon already pushes — the core link and
  version, each node with its session count, every device with its link
  state, every provider with its quota read. Evidence stays honest:
  "source not found" and "disabled" show as what they are instead of
  invented numbers (`OverviewLinks`, a pure builder over `CoreModel`).
- **Counts that matter**: sessions grouped by state (working, asking,
  done, idle) and by provider; asks always surface first — a pending ask
  is the thing that stalls a run.
- **Quick actions** ride the existing `CoreModel` commands — open the
  session, approve/deny an ask, dismiss, snooze, clear completed, undo
  the clear, copy the working directory, reveal it in Finder. Nothing is
  re-tracked; the card is a lens over the daemon's session feed.
- Settings: enabled toggle plus which state groups count toward the
  card's badge; the session source of truth stays `CoreModel` either way.
- **Smart suppression** ("Quiet while you watch"): when the ask's own
  terminal pane is frontmost the escalation ladder stays silent — no
  sound burst, no amber pulse, no stage-3 chime — because the user is
  already looking at it. The banner still lands for the record, and a
  frontmost-app change re-decides the noise without waiting for the next
  stage boundary. The proof is `answer_local`'s own: the host app's
  bundle on the frontmost app plus the frontmost pid on the session's
  process ancestry (`AskingPane`); a pane the daemon cannot prove keeps
  its noise.
- **Incident badges**: the daemon's status feeds already stamp a live
  vendor incident on each usage snapshot; `CoreProviderUsage.incident`
  carries it now. The Screen Bar's quota ear flips to the attention tone
  and names it in the peek, the panel's usage row tags "incident", and
  the Usage Center header badges it — always with the feed's own text on
  hover, never presented as a quota verdict.
- **Countdown on the ring**: the ear's fill ring gets a finer inner arc
  draining toward the window's reset (the lane's own span is the
  denominator — a `credits` lane has no clock and draws none), the peek
  and the island card name it in words, and the panel/Usage Center
  countdowns are unchanged.

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
| ⌘-drag across the icon, click-through to real items, triggers on click | Accessibility | drags and clicks go unheard, the pickers still work, search still opens item's app |
| Wi-Fi network name | Location | shows strength glyph only |
| Focus readout | daemon Focus sync (FDA) | Focus row hidden |
| Hide Apple's Battery/Wi-Fi/etc. | nothing (user defaults) | — |

Every card row names the missing permission and deep-links to the Setup
page's permission step.
