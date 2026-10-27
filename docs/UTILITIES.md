# Utilities

Utilities are the serious half of JR-Bar: features that manage the Mac's own
surfaces rather than play on them. Toys never touch agents; utilities never
touch agents either — they touch *macOS*. The distinction that decides where a
feature lives:

- **Toy**: a thing you turn on for fun or focus (Fold, Aquarium, Notch Buddy,
  Confetti). Lives on the Toys page.
- **Utility**: a thing you turn on to replace another app (Menu Bar, Dock,
  Keep Awake, agent Overview, Notch island). Lives on the
  Utilities page, in that order.

Notch stays callable a "toy" internally only for history — the card code is
the same shape; the page it sits on is Utilities.

## Page layout

`SettingsStore.Page` gains `utilities`, placed **after `devices`** and before
`lighting`. The sidebar stays flat (sections are a separate cohesion pass).
The Toys page keeps Fold, Aquarium, Notch Buddy and Confetti; the Notch card
and the Dock card live on Utilities.

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
> override covers, the reveal gestures, the Item Bar (live
> tiles + `AXPress` click-through), the per-item override pickers, the
> ⌘⇧K command bar, hotkeys, triggers, profiles, cover appearance, and
> the provider picker —
> the card's "Render with" hands the whole surface to an installed
> counterpart (Bartender, Ice, Hidden Bar; `MenuBarSettings.provider`)
> and parks our engine while the pick stands, with a live
> installed/running note that flips on workspace launch and quit.
>
> **Position is the setting (2026-10-07).** The Menu Bar model is Ice's:
> JR-Bar's own status item is the divider. Everything left of it is hidden,
> everything right of it stays, and you hold ⌘ and drag an item across the
> icon to change it. Moving it left makes it disappear; moving it right
> makes it come back. There is no list to keep in step: the card's rows
> are a read-out of where things sit (`MenuBarPositionPanel.swift`), and
> JR-Bar never moves another app's item for you — a pick made on a tile, in
> the icon's menu or in the palette is answered with the one gesture that
> does it (`MenuBarPositionCopy.guide`), and a pick to bring one back opens
> the reveal first so the item is drawn and can be dragged. Revealing
> (the ‹ and the blank bar left of the icon, a hover, a scroll, the
> hotkey) draws the hidden items on the bar for the rehide delay; what the
> run right of the notch cannot hold at once waits in the Item Bar, which
> opens by itself when a reveal leaves items parked. Research and sources:
> [archive/research/2026-10-07-menu-bar-ice-model.md](archive/research/2026-10-07-menu-bar-ice-model.md).
>
> **One engine, the divider.** The **divider** is the only engine: the
> JR-Bar icon grows a blank spacer left of itself, capped under half the
> screen's width (the system drops a longer item instead of clamping it),
> and macOS parks what no longer fits in its own overflow. The real icon is
> always drawn, so there is always something to drag across. A saved list of
> hidden apps never decides what hides, and neither does a crowded bar. A
> settings file that still names another engine reads as the divider.
>
> A newcomer is where macOS puts it (left of the icon it is hidden, right
> of it shown). The real icon's ‹ and the blank bar left of it reveal, while
> a click on the glyph itself still opens the panel. The log
> (`devin.jrbar:menubar`) names the engine start (`engine:`), every drag
> (`drag:`) and the positional record it wrote (`record:`).
>
> **A saved list is only a suggestion.** A file from before this model
> keeps every pick, and nothing is cleared. The apps its list hid are kept
> once, in `dividerSuggestions`, and the card offers them under "Your bar"
> with where each sits: the divider does not hide an app because the list
> says so, only because it stands left of the icon. A one-line hint, "Hold ⌘
> and drag an app left of the JR-Bar icon to hide it", stays until the
> person closes it. After that the list (`concealedApps` in the settings
> file) is only a record, kept up to date from the bar's positions; nothing
> hides on its say-so. **Show everything** folds the divider away, and
> turning the utility off returns every item.
>
> **A bar too full for the icon.** When macOS parks JR-Bar's own item for
> want of room (`MenuBarDividerRoomWatch`: off the row for eight seconds with
> no spacer to blame, or three parked-boundary lessons inside a minute) the
> card and the icon's menu say so, count the items macOS holds in its «
> overflow, and say how few items would have to leave the bar to seat the
> icon (`MenuBarRoomHelp`: the widest first). The person quits or switches
> off those items; JR-Bar does not move them.
>
> **A ⌘-drag holds the bar still.** macOS reflows the whole row while a
> status item is dragged, and anything JR-Bar wrote in that time reflowed it
> again. While a ⌘-press is on the bar and for 0.9 s after the drop
> (`MenuBarPointerGate`), the hider reads and writes nothing, the hover
> reveal and the rehide clock stand down, and nothing is recorded. One
> reconcile follows the drop, and the log says what moved
> (`MenuBarPositionDiff`). The drag handler under the divider only
> observes. "What JR-Bar sees" on the card lists the engine, the icon's
> place, the spacer and why, the two sides, and the last change.
>
> **The bar re-forming.** When the Mac, its displays or the session wake,
> a display is attached or removed, or a Space changes, macOS rebuilds the
> row and apps put their items back one at a time. The divider then leaves
> the spacer alone for about 2.5 s, forgets what it learned about the bar's
> room, and checks the icon on two fresh listings: on the row, the width
> JR-Bar wrote, and clear of other apps' items. A clear icon costs no write.
> A wrong one is re-seated once (the spacer folded and written again) and,
> if it is still wrong, "What JR-Bar sees" says so and JR-Bar stops; macOS
> keeps the order of the row. A spacer held short of the fit edge covers the
> items it cannot push off, in place, and says how far short it is. The
> per-event table is in [TOP-OF-SCREEN.md](TOP-OF-SCREEN.md).
>
> **The boundary affordance.** While the utility is on, the JR-Bar item
> keeps a 30 pt drop zone with a ‹ mark inside it
> (`MenuBarUtility.boundaryAffordance` → `StatusItemController`'s
> folded face) — the separator the person ⌘-drags items across, visible
> whether or not anything is hidden yet.
>
> **How hiding works — verified live on macOS 26 (2026-09-15).** macOS
> packs the status region right-to-left and *parks* whatever no longer
> fits in its own overflow (the "Show Hidden Menu Bar Items" control
> MenuBarAgent draws). A 3 000-point item is parked itself; a 250-point
> item inserted mid-row stays and pushes everything left of it into that
> overflow, with no holes. So **JR-Bar's own status item is Bartender's
> separator**: items left of it are hidden, and hiding is the item's own
> `length` growing a blank spacer, below.
>
> **The spacer.** JR-Bar's
> own `length` grows a blank spacer left of its icon
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
> bar can reveal items. Hover has separate entry and exit delays,
> defaulting to 180 ms and 250 ms. Under "After a delay", clicks and
> scrolls keep their own timer; open menus keep the items visible.
> The icon's right-click menu carries a "Hidden
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

### The model, and what the card says about it

Each app with a menu bar item is **Shown** (right of the icon),
**Hidden** (left of it) or **Always hidden** (a cover where it sits, the one
section that is an override, since a second status item of ours swaps sides
on every reflow). The card opens with "Your bar": the model in one
sentence, a live diagram of the bar (Hidden, the icon, Shown), the
engine, the old list as suggestions while any are left, and what JR-Bar
sees. Hidden apps wait in the Item Bar, which opens from the
icon's ‹, a hover or click on the blank bar, or the ⌘⌥B hotkey, and by
itself when a reveal leaves items parked; Always-hidden ones open only from
the Item Bar's tiles or the reveal-always-hidden hotkey. Nothing is hidden
until the person drags it, and an app that launches later is shown where
macOS puts it.

The card's first line is `MenuBarHidingBanner`, the one answer to "is
hiding working": `MenuBarHidingStatus.assess` over the engine's health,
the standing overlay, rivals, Accessibility and the icon's room. Each
state names itself and carries its fix, in this order:

| State | Says | One click |
| --- | --- | --- |
| Menu Bar off | every item shows as macOS draws it | |
| Another manager renders | whose, and whether it runs | Open it |
| Show everything / Hide all standing | what stands, until when | Hide my picks again / Show everything |
| Start grace | starting up | |
| A rival manager runs | two managers fight | Quit it |
| No Accessibility | the Item Bar cannot press items | Open Settings |
| The bar is too full for the icon | macOS holds N items in its « overflow; at least K must leave the bar | |
| Nothing left of the icon | hold ⌘ and drag an item left of the icon (or the icon itself right, when it is at the bar's left end) | |
| Healthy | Hiding N items left of the icon, and how to reach them | |

The way out is always on the banner: **Show everything** while anything is
hidden (the card's own Show everything button also offers 5 minutes or an
hour), and **Turn Menu Bar off** beside every warning. Show everything
(`MenuBarUtility.showEverythingNow`) always shows everything, even over a
Hide all — the older Show all restores over a quiet bar so a lock/unlock
rule pair ends where it began, and stays that for hotkeys and rules. No
rule outvotes a standing Show everything. Picks are kept; turning the
utility off gives every item back and leaves the picks in the file for
the next time.

### A relaunch finds an icon

Opening JR-Bar right after quitting it waits up to 10 s for the old
instance to let go of `~/.local/state/jrbar/app.lock` instead of giving up.
JR-Bar clears any saved "hidden" placement for its own item at launch and
recreates the item when it cannot find it (`status-item` in the log).
Opening JR-Bar.app while it runs brings up Settings, so the way in never
depends on the icon.

### ⌘-drag across the icon

Bartender's, Ice's and Hidden Bar's habit. Hold ⌘ and drag an item left of
the JR-Bar icon and it is hidden; drop it right of the icon and it is
shown. macOS moves the item itself. JR-Bar only watches
(`MenuBarUtilityDrag.swift`): it posts nothing, writes nothing to the bar,
and the pointer is the person's.

- **The bar holds still.** From the ⌘-press until 0.9 s after the drop
  (`MenuBarPointerGate`) the hider reads and writes nothing, the hover
  reveal and the rehide clock stand down, and nothing is recorded. A held
  mouse button suppresses the hover reveal too.
- **One drop, one read.** After the drop JR-Bar reads the bar once and
  compares it with what it saw before (`MenuBarPositionDiff`). The log
  says what moved (`drag:`) and what the positional record now holds
  (`record:`). A listing that changes on its own is never taken for a
  drag: no press, no record.
- **Never silent.** A drop says what happened for four seconds under the
  icon, in the Item Bar's own glass, including the cases where nothing
  changed sides.
- **Drag a tile out of the Item Bar** onto the bar to move its app: the
  drag is the Item Bar's own session, the pointer is the person's, and a
  drop on either side of the icon is answered with the ⌘-drag that does the
  move. JR-Bar never moves another app's item itself.
Also in this pass: **Item Bar opens at** the icon or the pointer
(`itemBarAt`), **Tuck
away: When you switch apps** (`RehideMode.focusChange`, Ice's smart
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
- Reveal triggers, all on by default: **Hover the blank stretch**, **Click
  the blank stretch**, **Scroll over the bar**, and two hotkeys (Item Bar
  toggle ⌘⌥B, reveal Always hidden ⌘⌥⇧B; both off until you turn them on).
  **Tuck away** picks how a reveal ends: After a delay (1 to 15 s, default
  4), When you click elsewhere, or When you switch apps. The delay re-arms
  while the pointer is on the bar or the open Item Bar. **Built.**
- **Item Bar**: a floating panel under the menu bar (Liquid Glass — it floats)
  listing hidden items as tiles. **Built**: owner-icon tiles, `AXPress`
  click-through (reaches covered and system-parked items), ⌘-click pulls a
  tile up a section. Without Accessibility, or when the item can no longer
  be found, a click raises the owning app instead; JR-Bar never posts a click
  at the item. Live tiles are one `SCScreenshotManager` capture per tile
  when the bar opens (at most one per half second per item), never a loop
  or a stream, because a capture lights the recording indicator and shifts
  the bar; without Screen Recording a tile shows the glyph photographed
  while it was drawn, or the app's icon (see docs/TOY-PARITY.md).
- An item that sits under the notch or under the front app's menus is
  planned as hidden, because macOS leaves it behind the glass; the Item Bar
  lists it. The switches are **Keep items out of the notch** and **Hide items
  under app menus** under More, on by default.
  **Built** (see docs/TOY-PARITY.md).
- **Item search / Command bar**: ⌘⇧K, the icon's menu, or the Command bar
  button under Advanced › Automate. It is JR-Bar's one palette, so the
  menu bar items (shown and hidden) sit beside asks and sessions, the front
  app's menus, quiet, lights and windows; Return runs the pick. It also
  carries the bar's verbs: set an app's section, reveal, Hide all, Show all,
  switch, save or rename a profile, and run a rule or turn it on or off. While the
  Menu Bar utility is off the key still opens the palette, without those verbs.
- **Spacing**: one system-wide gap between every app's items, under
  Advanced: **Item spacing** (System, Tight 4 pt, Compact 8 pt, Roomy 14 pt)
  and **Custom spacing** (0 to 24 pt). It writes `NSStatusItemSpacing` and
  `NSStatusItemSelectionPadding` for the current host, so items take it only
  as their apps relaunch (the Relaunch row above). macOS may ignore it for
  items that fix their own width. JR-Bar draws no spacer
  items of its own: it has one status item, and the divider is that item's own width.
- **Profiles**: named layouts (the section picks, the cover look, the reveal
  style and clock, the item spacing and the spacer items); switch from the
  Profiles row, the icon's menu, the palette, the next and previous profile
  hotkeys or a rule. A profile is a delta over your own picks, so switching
  never rewrites them. **Profile at this desk** and **Profile per display**
  pick one automatically. Rules and hotkeys are not part of a profile.

### Appearance

- The look of a cover, under Overrides: **Cover material** (Blend In, Menu,
  HUD, Popover or Sheet), **Tint the cover** with a **Tint color** and
  **Tint strength**, **Rounded ends** (0 to 14 pt) and **Edge separators**.
  There is one look; no separate light and dark settings, and no
  gradient, shadow or border.
- **Tint the whole bar** (Extras, off by default) draws the same material and
  tint as an underlay panel under the full menu bar row on every display,
  one level under the status items (`statusBar - 1`), click-through, sized to
  the bar (the notch depth where there is one). It ignores the rounded ends
  and separators, and it is kept out of screen captures (`sharingType =
  .none`). On macOS builds where the bar's backdrop is opaque it reads as
  nothing.

### Triggers

Under Advanced › Automate there are two lists, both empty until you add a
rule. Each rule has its own switch and a remove button.

- **Rules** fire once on an event: *When* the screen locks or unlocks; an app
  activates, launches or quits (by bundle id); a time of day; the charger
  goes in or out; the battery falls to or rises past N%; Wi-Fi joins a named
  network, changes or drops; the microphone goes live or quiet; a Focus turns
  on or off; a display connects or disconnects; the lid closes or opens
  (clamshell, Mac still awake); agents start working, an agent needs you or
  the agents finish; usage headroom falls to N%; a SidePulse device connects
  or disconnects. *Then* apply a profile, Hide all, Show all, reveal for N
  seconds, run a script (a shell command run with `/bin/sh -c`),
  keep the Mac awake for N minutes (up to a day) or until released, or let it
  sleep. The first battery reading is a baseline, so a rule never fires for a
  level the Mac was already in.
  Scripts allow one running job per rule and four across the utility.
  Another trigger is refused while that rule runs. Run Now reports whether
  its script was queued or refused. Stopping Menu Bar, editing or removing
  the rule, or switching it off cancels its job. An unchanged script has no
  execution deadline. When a job ends, JR-Bar stops children in its process
  group; a child that starts another group is outside that cleanup. Only the
  last 8 KiB of combined output is retained, in private diagnostics.
- **While…** rules hold a state for as long as a condition lasts and put
  everything back when it ends: the microphone is live, a Focus is on, the
  screen is locked, on battery, battery at or below N%, on a named Wi-Fi, an
  app is in front or running, between two hours, the lid is closed, an
  external display is attached, agents are working, an agent needs you,
  agents are idle, usage headroom at or below N%, or SidePulse is connected
  (each with a Not box). They hold the quiet bar or Show everything, a
  profile, an LED scene and quiet agents, as an overlay that never rewrites
  your own picks.

Rules read the sources the app already runs: distributed lock
notifications, `NSWorkspace` notifications, the power source (the same read as
`AlcovePowerMonitor`), CoreWLAN, the microphone capture read, the daemon's
agent and usage facts. They start only while an enabled rule can fire. A
named Wi-Fi match needs Location; a Focus rule needs the Focus Status
permission, which the card asks for when you add the rule.

### Hotkeys

Carbon `RegisterEventHotKey` like `PanelHotkey`. Settings › Shortcuts has a
"Menu bar" group with a switch and a key recorder per action; the Menu Bar
card (Advanced › Automate) shows the same switches and keys but does not
record. The hotkeys are held only while the utility runs (the ⌘⇧K palette key
is parked and still opens the palette when it is off). While one recorder is
listening, another no longer hands the keys back to the system. Seven actions,
with these defaults: the ⌘⇧K command bar
(on); Item Bar toggle ⌘⌥B, reveal Always hidden ⌘⌥⇧B, Hide all ⌘⌥⇧H, Show
all ⌘⌥H, next profile ⌃⌥⌘→ and previous profile ⌃⌥⌘← (all off until you turn
them on). A key another app already owns is named, not taken.

### One status item

JR-Bar has exactly one status item, the icon, and writes no Control Center
preference. An older build drew a second "one system item" (and an agent item
and spacer items) and hid Control Center's own Battery, Wi-Fi, Bluetooth,
Sound, Now Playing and Focus items while it showed. All three are gone. The
icon's own Agents and Orbit styles carry the state and the counts; there is
no separate agent item.

**Upgrading.** A settings file that had `combinedSystemItem`,
`agentStatusItem` or `spacers` on has them read once, named in a one-time
launch notice (`retiredExtras`), and never written back. At launch
`ControlCenterRestore` undoes what the old build did, once: if the saved
record `jrbar.menubar.ccOriginals` exists, each of the six Control Center keys
that still holds the `false` JR-Bar wrote gets its saved original back (a key
that was never set is removed again), a key the person has changed since is
left alone, the record is removed, Control Center is relaunched so it reads the
values, and one log line says which items came back. With no record it does
nothing. `OneItemMigration` runs it and posts the notice; a test pins that the
app creates an `NSStatusItem` nowhere but `StatusItemController`.

## Dock (vs DockDoor, AltTab)

Rest on a Dock icon and that app's windows appear over it; ⌥⇥ raises the
window switcher. The feature table is `docs/TOY-PARITY.md` "Dock"; this
section covers the preview's air and where it sits.

### Spacing, distance and the name label (2026-09-24)

- **Spacing** is one scale, stored as `DockEnhanceSettings.previewSpacing`
  (0.5…1.6). The card's segmented control offers **Tight** (0.6, the
  default), **Standard** (1.0) and **Roomy** (1.4); between the stops no
  segment is lit and the row's subtitle names the value ("Custom: 85%"),
  so the row keeps its shape. "Fine spacing" under More preview options
  sets it in 0.05 steps. `DockPreviewMetrics.scaled(s)` turns the scale
  into every inset the panel draws: glass edge to content, the air between
  sections, the card plate's reach, card to card, still to caption, the
  ask and list rows' padding, the header icon and the verb discs. Each is
  its Standard value times the scale, held at a floor (the plate never
  under 4 pt, so the waiting ring's 3 pt reach stays on it; verb discs
  never under 20 pt). The header's icon and verb discs are controls, not
  air: they shrink toward Tight and stop at Standard's 30 and 22 pt, so
  Roomy is air round the header, not a bigger one. Below 0.8 the
  hairline between sections goes and the air alone separates them. The
  corners are derived, so they stay
  concentric: plate = still corner + pad, glass = plate + inset (24 at
  Standard, where it was 20). Standard is otherwise the look before the
  knob: Safari's three-card panel is 496×194 at Standard and 472×165 at
  Tight.
- **Distance from the Dock** (`dockGap`, 0…40 pt, default 4) is the air
  between the icon's edge and the glass. The frame math never lets it
  under 2 pt, so the road from the icon to the cards (`inCorridor`)
  always has somewhere to run.
- **Cover the Dock's name label** (`coverDockLabel`, default on). The
  Dock draws its name bubble inside its own full-screen window. On, the
  panel rides at the status-bar level, over that window, with no band
  kept for the bubble — DockDoor's "above app labels" — and with the Dock
  magnifying it also clears the swollen icon's reach
  (`largesize − tile`, 128 when `largesize` was never set). Off, the
  panel sits one level under the Dock and keeps today's band (34 pt on a
  bottom Dock; the name's width, up to 240 pt, beside a side Dock).
- One `DockPlacement` serves the show, the re-anchor, the refit and the
  gesture toast; three call sites used to repeat one expression. All
  three set the panel's level from it too, so turning the cover on or off
  while a preview is up lands on its next move. Covering, the opening
  drift stops a point short of the gap (a 10 pt drift over the Dock's
  window crossed the hovered icon and could take the Dock's hover);
  under the Dock it drifts the full 10.
- The card's live sample (`DockPreviewSample`) draws a desk, a Dock of
  55 pt tiles and Safari's preview placed by that same frame math, with
  the name bubble where the Dock would show it. It draws built-in stills
  (`DockPreviewSamples`, which the render proofs use too), never a
  capture, so opening Settings never lights the recording dot. Its desk
  is one fixed size (600×380), measured to hold the roomiest spacing at
  the farthest gap with the name band kept, so the card never jumps
  under a slider.
- The ⌥⇥ switcher follows the same scale (`DockSwitcherMetrics`): the
  pane, row and strip insets and the card gap scale with it, the zoom
  pane narrows to 80 % at the tight end, and the glass corner is the
  card corner plus the strip inset less two (24 at Standard).
- **Cards take each window's shape** (off): a card's width follows its
  window's aspect, held between 0.6 and 1.9 of the height, and the still
  fills it from the top-leading corner — no letterbox beside a portrait
  window. The caption and plate keep a 96 pt column, the narrow still
  centred in it, so a portrait window's title still reads. The still's
  box is pinned, so pointing at a card never widens it; a still too
  narrow for the row of hover verbs stacks them down its edge.
- The switcher's own knobs, under the card's Switching header: **Switcher**
  (who answers ⌥⇥ and ⌘⇥: JR-Bar, AltTab, DockDoor, Witch, Contexts or Off,
  separate from the previews' **Render with**), **⌥⇥ window switcher** (on),
  **⌘⇥ app switcher** (off), **⌥⇥ lists this display only** (off),
  **Window order** (most recent first, or grouped by app), **Apps with no
  windows** (off: a card per running app with none, at the strip's end) and
  **Card faces** (stills, or icons that never capture). The Dock utility
  itself is off until you turn it on; hover previews are on once it is.
- The ⌥⇥ strip takes its keys in the order they were typed, and when macOS
  switches its key tap off for a moment it reads the held modifiers again, so
  a release that happened meanwhile still commits and the open strip does not
  keep swallowing keys.
- **Hold the Dock out** keeps an auto-hiding Dock showing while a preview is
  up. If a quit left that hold behind, or an older build's Replace bar left
  Apple's Dock auto-hide on, the next launch hands it back and the card says
  so in one line ("Put your Dock's auto-hide back after an unclean quit" or
  "… after an older JR-Bar hid it") until you dismiss it. Handing back the
  older build's auto-hide restarts the Dock.

## Agent Overview

The utility that replaces "a dozen terminal tabs you can't see" is two
surfaces over one feed, `CoreModel.sessions`. The roster is the panel's and
the Overview window's (sortable roster table + inspector), its own
independent panel, opened from the app menu, the status-item menu, the
notch card, the utility card, or ⌘O. The utility's own card on the Utilities
page keeps no list and no session verbs: it sets how loud each agent may
be, holds the "Quiet while you watch" switch, and has an **Open the
Overview** button into that window.
The Overview's sidebar has Views, Insights (**Graph** and **Usage**),
Projects, Branches and Saved views. The Graph pane is a map of the fleet:
providers as hubs, projects as clusters, each main session a capsule with
its workers branching off, the state on its ring. It inspects and opens
sessions and never answers an ask. The old Obsidian-style force-directed
constellation and the After Dark / flying-toaster screensaver lineage are
gone.

- **Connections browser**: the Overview's idle inspector is a wiring
  diagram of everything the daemon already pushes — the core link and
  version, each node with its session count, every device with its link
  state, every provider with its quota read. Evidence stays honest:
  "source not found" and "disabled" show as what they are instead of
  invented numbers (`OverviewLinks`, a pure builder over `CoreModel`).
- **Asks first**: the panel lists a session with an open ask above
  everything else (longest-unanswered leading), then waiting, failed,
  working, done, ended and idle. A pending ask is the thing that stalls a
  run. The card does not repeat that list or count it by state.
- **Quick actions** live in the panel and the Overview window, not on the
  card, and ride the existing `CoreModel` commands — open the session,
  approve/deny an ask, snooze, clear completed, undo the clear. Nothing is
  re-tracked; both are a lens over the daemon's session feed.
- **Alert rules**: one row per provider with hooks or a session on
  record — asks, finishes, failures, sounds, and how far its escalation may
  climb. A blank rule follows Settings › Alerts & Sounds, and a rule can
  only narrow or widen what the global policy already decided for that
  provider's events.
- Settings: an **enabled** toggle that shows or parks the card, **Quiet
  while you watch**, and the alert rules. The session source of truth stays
  `CoreModel` either way. A settings file from an older build may still
  carry grouping, row-limit and show/hide keys for a list the card no
  longer has; they are ignored on read and dropped on the next save.
- **Smart suppression** ("Quiet while you watch"): when the ask's own
  terminal pane is frontmost the escalation ladder stays silent — no
  sound burst, no amber pulse, no stage-3 chime — because the user is
  already looking at it. The banner still lands for the record, and a
  frontmost-app change re-decides the noise without waiting for the next
  stage boundary. The proof is `answer_local`'s own: the host app's
  bundle on the frontmost app plus the frontmost pid on the session's
  process ancestry (`AskingPane`); a pane the daemon cannot prove keeps
  its noise.
- **Incident badges**: while Settings › Agents & Usage › Provider status pages is
  on (it is off until then), the daemon's status feeds stamp a live vendor
  incident on each usage snapshot; `CoreProviderUsage.incident` carries it. The Screen Bar's quota ear flips to the attention tone
  and names it in the peek, the panel's usage row tags "incident", and
  the Usage Center header badges it — always with the feed's own text on
  hover, never presented as a quota verdict.
- **Countdown on the ring**: the ear's fill ring gets a finer inner arc
  draining toward the window's reset (the lane's own span is the
  denominator — a `credits` lane has no clock and draws none), the peek
  and the island card name it in words, and the panel/Usage Center
  countdowns are unchanged.

## Keep Awake (vs Amphetamine, KeepingYouAwake, Atoll)

The person's own hold, as a card after Dock. The card's switch (**Manual
session**) is that hold: on keeps the Mac awake until turned off; off ends
only that manual session. The agents' own hold and other apps' holds are
independent and may still keep the Mac awake, and the card says so under the
switch. It is the same hold as the notch card's Awake chip, the panel
footer's cup and the Screen Bar's right ear (`SystemTogglesStore`): the
daemon's `hold_awake` lease while the monitor is connected, the app's own
power assertion otherwise. A hold the daemon asked for but nothing is
keeping reads "Not held" on the chip, and the card says "Couldn't hold the
Mac awake" with **Try again**, which re-asks the same hold. It never says
"Awake".

A hold keeps the computer awake and lets the display sleep: the daemon's
`caffeinate -ims`, the app's own `kIOPMAssertionTypeNoIdleSleep`, and
`caffeinate -i -w` for `jrbar awake` without the monitor. The display is
held only when the person turns on **Keep the display on** (their sessions)
or **Keep display awake** (the agents), and never with the lid shut on no
external display. Both were reset to off once in 0.10.1
(`keep_display_awake_default_version`, `keepAwakeDisplayMigration`).

- **While a command runs**: `jrbar awake -- <command>` and `jrbar awake
  --pid N` start the daemon's `process` lease. One kqueue `NOTE_EXIT`
  watch per lease hears the exit; the card reads "While swift runs".
- **Heads-up**: five minutes before a timed session ends, one notice with
  **+30 min** (`KeepAwakeHeadsUpScheduler`): one scheduled event, armed
  when the hold changes and dropped when it changes again, held by the
  quiet that holds banners, off with **Heads-up before it ends**. The cup's
  steam (`KeepAwakeSteam`) fades in steps on the countdown's own redraw.

- **Duration menu** (`KeepAwakeMenu`): the presets ("For 15 minutes", …),
  Until 08:00 (the panel's next-morning rule: the next 08:00 at least an
  hour away; between 07:00 and 08:00 it takes the 08:00 in front of it,
  since a lease lasts at most a day), Until the agents finish (the daemon's
  agents lease; offered only while the monitor is live), Indefinitely, Keep
  the display on, and **End manual session** (enabled only while a manual
  hold is in force). A right-click or long press on the Awake chip, a
  right-click on the footer cup and its line, and a right-click on the
  Screen Bar's right ear all open the same list. The card shows the same
  choices as buttons, with the display switch as its own row.
- **Presets** live in `jrbar.keepAwakeDurations` (seconds, app defaults;
  Atoll's 15 m, 30 m, 1 h, 2 h, 4 h by default). Each is a minute to 24
  hours, sorted, without repeats, at most eight; an empty or unusable list
  reads as the default. Edited on the card under Presets (a stepper and
  **Add**, a remove button on each, **Reset**; the last one cannot be
  removed).
- **While agents run**: the four daemon rows (**Keep Mac awake**, **Keep
  display awake**, **Lid closed** with Let it sleep, Stay awake while agents
  run or Always stay awake, and **Keep awake on battery**; Keep Mac awake
  and Keep awake on battery default on, Keep display awake off, and Lid
  closed to Let it sleep). Settings › General › Power
  keeps them too. A finished agent's quota lease no longer keeps a
  quota-exhausted Mac awake for the agent still working. The closed-lid hold
  rides the privileged sleep helper (`pmset disablesleep`) and the daemon
  turns sleep off only once its fail-safe (a renewal file and a watchdog
  that put sleep back within about four minutes if the daemon dies) is
  running; a renewal dated in the future counts as dead; if the helper refuses
  to release, the fail-safe stays until sleep is back on.
- **Other apps holding this Mac awake**: read-only from
  `IOPMCopyAssertionsByProcess`, apps only, JR-Bar itself left out.
- A pause reads in words: "Low Power Mode is on", "too warm" or "battery
  low" (`suspended`), and the hold comes back on its own.

## Coexistence

"Still allowing them to be an option" cuts both ways: every utility can be
switched off and costs nothing while off (`UtilityOffCostTests`), and an
installed rival can have the surface. `UtilityRivals` is the one table of
rival apps by role; `RivalGuardView` is the note any card mounts. The menu
bar keeps its own list and note this wave (`MenuBarRivals`), and so does
the Dock card's switcher (its chord note). What JR-Bar does while a rival
runs depends on the role:

| Role | Rivals | While one runs | Where the note shows |
| --- | --- | --- | --- |
| Menu bar | Bartender, Ice, Hidden Bar, Vanilla, Dozer, Barbee, Tuck, SaneBar (`MenuBarRivals`) | Ask: Hand over where a pick exists, Quit on a click | Menu Bar card |
| Dock previews | DockDoor, ActiveDock, DockView | Ask | Dock card, under Render with |
| Switcher | AltTab, DockDoor, Witch, Contexts | Ask (the card's existing chord note) | Dock card, Switching |
| Notch island | Alcove, Boring Notch, Atoll, MewNotch, DynamicLake, Notchy, NotchNook | Ask: Hand over to Alcove or Boring Notch | Notch card, under Render with |
| HUD | MediaMate, SlimHUD (Alcove, Boring Notch, Atoll and MewNotch also count, but are named by the Notch island note) | Ask | Notch card, under Volume & brightness capsules |
| Shelf gesture | Dropover, Yoink, Dropzone | **Step aside**: the shake summon's monitors stand down while one runs (`shelfYieldToRivals`, on), because one shake can't be shared; dropping on the notch still works. The note has no buttons | Notch card, Shelf rows, while JR-Bar draws the Notch |
| Keep-awake | Amphetamine, KeepingYouAwake, Caffeine, Lungo, Theine | Inform only: holds stack harmlessly | Keep Awake card, Other apps |

Nothing is ever quit or handed over without the person's click. A rival
already picked under Render with is the choice, not a clash, so its note
does not show. The yield reads "the app is running", not "its shake is on"
(Dropover's own preferences are not readable); the **Step aside for other
shelf apps** switch is the way out.

## Cohesion contract

`docs/TOP-OF-SCREEN.md` owns the cross-surface rules; the short version:

- Glass only on what floats. Anything growing from the notch is black.
- One surface per role: the notch card IS the island when the Notch utility
  is on. Hidden items list in the glass Item Bar under the menu bar, and the
  Screen Bar's right ear hangs a black peek of the same tiles from the notch.
- `ScreenBarGeometry` is the single source of notch truth for all of them.
- The Screen Bar band keeps its own colour; nothing tints it from the menu
  bar.

## Permissions

| Feature | Needs | Without it |
| --- | --- | --- |
| Hiding the apps you picked, the Item Bar's app-icon tiles | nothing extra | full |
| Seeing which items sit on the bar (tiles, search, the rows on the card) | Accessibility | the list and the tiles go blind; hiding itself still works |
| Live tiles in Item Bar | Screen Recording | the photographed glyph or the app's icon instead |
| ⌘-drag across the icon, read once after the drop | Accessibility | drags go unheard; the pickers still work |
| Item Bar click-through to the real item, search opening an item | Accessibility | a click raises the owning app instead |
| Wi-Fi network name (named Wi-Fi rules) | Location | named rules never fire |
| Focus (Focus rules) | Focus Status, asked when you add a Focus rule | Focus rules never fire |
| Other apps holding the Mac awake | nothing (public IOKit read) | — |
| Shelf Copy Text on images | nothing (Vision runs on this Mac) | — |
| Dock hover previews | Accessibility | previews cannot see which icon the pointer rests on |
| Dock window thumbnails | Screen Recording | icon and title cards; raising, closing and minimizing still work |

The Menu Bar and Dock cards show a note naming the missing permission with an
**Open Settings** button that opens the matching System Settings pane.
