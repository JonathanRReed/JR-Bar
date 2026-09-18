# Changelog

All notable changes to JR-Bar are documented here.

## 0.9.9 (unreleased)

- The shelf finally looks like a shelf: chips carry each file's real
  Finder icon and upgrade to a Quick Look thumbnail the moment one
  exists — no more wall of generic `doc` glyphs. Plain-text drops
  land too: a dragged snippet materialises as a `.txt` on the shelf
  (a link as a `.webloc`), named by a deterministic hash so the same
  drop lands on the same file across launches instead of piling up
  duplicates. Chips drag into a new order and the order persists.
- The media card sings along: a synced-lyrics line rides under the
  transport, fetched from LRCLIB (free, keyless) once the track's
  title and artist are known, parsed from the LRC payload and stepped
  to the playhead by binary search. Plain-lyrics tracks show their
  first line, instrumentals and misses stay silent — no empty box.
- Revealing the hidden run can now hide the shown one: the new
  "hide shown items while revealing" mode covers the visible stretch
  while the Item Bar is open, Bartender Golden Gate's swap — so the
  hidden set reads as *the* bar, not a second one beside it. The
  covers are computed apart from the hidden shutter's and never paint
  the protected controls. Off by default; it persists per setting.
- Folder Pop strips give their files back: a chip drags out of the
  popover as a real file URL — the same provider the window cards
  already carried, so dragging a download straight onto a document
  works like the Dock's own folders do in DockDoor 1.40.
- The ⌘⇥ strip ranks what you meant: fuzzy matches now sort by score
  — a hit in the window's title outranks one that only matched the
  app name, recency breaks ties — instead of whatever order the dock
  happened to keep. A preview pane sits above the filmstrip and
  follows hover (the keyboard's selection when the pointer is away),
  showing the hovered card's thumbnail at full size with its title —
  AltTab's glance, without a second window.
- The card carries a Control Center strip of its own: eight one-tap
  chips — keep awake, dark mode, desktop icons, hidden files, mute,
  screen saver, lock, Dock auto-hide — each honest about its state.
  Keep-awake holds a real `IOPMAssertion` until *you* let go (folding
  the card does not), mute rides CoreAudio, and the rest drive
  supported `defaults`/AppleScript/`pmset` paths — no private
  SkyLight calls, and a refused write reports itself instead of
  flipping the chip. The lock button puts the display to sleep
  (`pmset displaysleepnow`), which locks on wake wherever a password
  is required — the old `CGSession` binary is gone on macOS 27.
- Two timing-sensitive tests got honest bounds: the notch hover
  deadline test and the shared-timer delivery test both poll real
  clocks (`asyncAfter` arms, a 1 s runloop `Timer`) that can slide
  past their old timeouts under a parallel suite. The windows are
  wider now — what each proves (the deadline is kept; the timer fires
  exactly once) is unchanged.
- The right wing is visible again: its ear had collapsed to zero width
  whenever JR-Bar's own status item stood on the row — the ‹ glyph was
  deliberately suppressed to avoid duplicating that item's mark, and
  the suppression took the whole ear with it. The handle now draws on
  the ear while the concealer runs regardless of where the status item
  sits, and `wingEarDrop` is back to its shipped six points — a flush
  black tray on a black bar read as no wing at all, so the ear lobes
  hang below the bezel line again. The wing panel also rides a level
  above the cover shutters, ending a same-level z-order race that let
  covers paint over it.
- Items the agent cannot hold no longer flash uncovered: a resistant
  escapee (cmux, ChatGPT, Tailscale and friends re-stand through every
  re-assert) is now covered from a sticky proof — once an item has
  stood through one re-assert it keeps its cover through the session's
  flap cycles instead of re-earning resistance after another 8 s
  window. Covered or parked items stop blocking the wing's ears too —
  an already-invisible slot is free for our own furniture. The shutter
  logs its painted spans (`cover paint`) so cover behaviour is
  verifiable without screenshots, which cannot see the panels at all.
- The ‹ boundary is Bartender's invariant again: whatever stands left
  of it *is* hidden — whether a hand ⌘-dragged it there or macOS
  re-stood it behind the mark when an assertion released. The ⌘-flip
  learn only ever saw drags, so items macOS placed behind the caret
  stood in the hidden zone forever, shown and un-parked — including
  the stretch where the notch's right wing draws, which collapsed the
  wing to a sliver behind them. A positional reconcile now maps live
  on-row frames to sections every pass: left of ‹ hides, right of ‹
  with a stale mark un-hides under ⌘, `alwaysHidden` outranks position
  both ways, and a deliberate Show or Show All is exempt until its
  item actually crosses in front — so the wing's flank clears and the
  caret means what it shows.
- Long channel-tagged app names lay out slim: the Dock preview header
  splits "T3 Code (Nightly)" into "T3 Code" plus a small channel chip
  (Nightly, Beta, Dev, Canary, Insiders, PTB, Technology Preview,
  Developer Edition — parenthesised, dashed, or trailing spellings),
  the title column caps at 240 pt and tail-truncates, and the
  switcher's caption uses the split base so a long name stops driving
  the card wide. Tooltips keep the full name.
- The ⌥⇥ switcher is AltTab's card now: every window row fills in with
  the real still (the shared ScreenCaptureKit capture the previews use,
  cache and alpha-trim included) instead of a bare icon, with the app
  badged in the corner. The same "Window thumbnails" switch and Screen
  Recording grant answer for both surfaces — no grant, icon cards.
- Type-ahead is Witch's fuzzy, not a substring: "sfr" lands Safari the
  way the command bar's subsequence scorer does, on title or app name.
- ⌘F in the switcher toggles fullscreen for real — it read the
  window's `AXFullScreen` state and now writes the opposite instead of
  forcing `true` a second time.
- Dock preview cards grew DockDoor's right-click menu: Raise,
  Minimize/Bring Back, Full Screen, a "Tile To" submenu with halves and
  quarters (real `AXSize`+`AXPosition` writes on the pointer's screen),
  and Close — on top of the hover pills and middle-click that were
  already there.
- Menu-bar rules learned the battery: "Battery falls to…" and "Battery
  rises past…" join charger, Wi-Fi, mic and Focus as trigger kinds —
  edges on the internal battery's percent, with the same baseline rule
  as every other level source.
- The ⌘⇧K command bar now folds on a click anywhere outside it — the
  same monitor pair the Item Bar has always used.
- Drag a file or a link to the notch and the shelf opens to catch it —
  NotchNook's signature gesture. The island is a registered drop
  destination; the card grows held, the drop lands in the tray, and a
  drag abandoned mid-flight folds the card it summoned rather than
  leaving it pinned.
- Web links are tray citizens: a dropped URL materialises as a real
  `.webloc` under the shelf's folder, so Reveal/Share/AirDrop all
  answer it. `javascript:` and friends never materialise.
- Tray chips preview — double-click or "Quick Look" in the context
  menu opens the system's own `QLPreviewPanel` over every entry that
  still resolves, paged at the chip.
- A swipe up on the grown island card tucks it back into the notch —
  Alcove's dismiss flick, sharing the down-flick's fold path and its
  shelved-capsule dismissal. On a resting island the flick stays inert;
  the notch can't be pushed into the screen.
- The ⌘⇥ app strip learned Witch's drill-down: tap ↓ on an app and the
  card narrows to that app's windows alone — the drill mark survives
  re-sorts, ⌘-release commits the chosen window, and ⎋ or a tap on
  another app walks back out to the strip.
- Unread badges ride the Dock tiles: the preview header's icon and the
  ⌘⇥ switcher cards wear the tile's own `AXStatusLabel` count — the
  red pill Mail and Messages already draw on the Dock, read once per
  build rather than polled.
- Menu-bar rules run scripts now: "run a script" joins apply-profile,
  hide/show-all and reveal as a trigger action, dispatching the typed
  command through `/bin/sh -c` detached so a lock, charge, or Wi-Fi
  edge can fire anything the shell can.
- The shelf answers a global key: ⌃⌥D opens the notch's card from any
  app — Yoink's summon — and folds it again on a second press. It
  shares the panel hotkey's Carbon plumbing with its own signature and
  settings row, and says so in Settings if the chord is taken.

## 0.9.8 (unreleased)

- Provider pickers everywhere a counterpart exists: each utility card
  now carries "Render with" — Menu Bar delegates to Bartender, Ice, or
  Hidden Bar; Dock to DockDoor or ActiveDock; the Notch already had
  Alcove and Boring Notch. An external pick parks our engine entirely
  (the settings persist through `MenuBarSettings.provider` /
  `DockSettings.provider`, decoded tolerantly), the card shows a live
  installed/running note with an Open button, and a workspace launch
  watch flips the note the moment the counterpart starts or quits.
- The menu-bar drag boundary is finally *visible*: the JR-Bar icon's
  item now keeps a standing 30 pt drop zone with a ‹ mark while the
  utility is on — the separator Bartender's always-on-bar caret is.
  The hint glyph existed but was deliberately disabled ("the blank
  stretch is the affordance") and the spacer collapsed to 0 when
  nothing was hidden — a drag target nobody could see. The floor
  applies under both engines and the mark rides inside it.
- Dock previews centre for real: captures are alpha-trimmed to their
  content bounds before display, so a purged margin or shadow inset
  can no longer drift the window's image off-centre inside the card;
  the strip's `ViewThatFits` centring shipped earlier — the two halves
  were each needed.
- The ‹ and › affordances now answer every click. They routed to the
  hidden-run toggle all along, but the toggle keyed on `revealed` —
  a hover could leave the run revealed with no surface up, so the
  click folded it back and read as dead. The click now keys on the
  Item Bar instead: closed → the run reveals and the bar opens (the
  surface macOS's full bar cannot show); open → the run rehides and
  the bar closes. An empty run pops the hidden-items menu with a
  teach row instead of swallowing the click.
- The Dock preview header trades its spelled-out buttons for macOS
  traffic lights — Quit, Hide, and New (plus Min-all when several
  windows are up) are tinted circles like DockDoor's compact header,
  with the action names kept as tooltips and accessibility labels.
  The row is ~110 pt narrower; the folder face's Open is a circle too.
- ⌘-drag hiding finally works end to end under the concealer. Three
  stacked bugs killed it: the learn measured macOS's « caret while the
  visible ‹ mark sits ~30 pt right of it, so a drop between the two
  read "shown"; the ⌘ stamp only counted key-*downs*, so a slow drag's
  learn window lapsed before the reconcile saw the flip; and an item
  parked from the gap flipped only its membership, which the side-flip
  test could not see. The boundary now prefers the visible mark, the
  stamp covers ⌘-up too, and the learn flips on side *or* membership —
  plus the card's list shows macOS-parked items nobody mapped with a
  truthful "in overflow" label, so nothing hides invisibly.
- The Screen Bar's ears yield 8 pt to the nearest status item instead
  of 2 — transient indicators macOS drops in the flank (the mic pill,
  a recording mark) land inside the flank gap and a 2 pt seam read as
  the ear overlapping them.
- Dock thumbnails lose the dark band on top: the alpha probe's opaque
  threshold rose to 64 so a soft shadow cell crops out instead of
  keeping a dead strip, and the .fit letterbox backs with the card's
  own surface instead of a black wash. And the strip finally centres:
  `ViewThatFits` alone only centres inside its own content-hugging
  bounds, and the body's `VStack` left-aligns it — a single card sat
  hard left with the panel's dead glass on its right, reading as a
  phantom second slot. Spacers now hand the row's full width to the
  fit-or-scroll choice, so a fitting set truly centres and an
  overflowing set scrolls edge to edge.
- The notch card's "Bare — the Screen Bar's ears carry the HUD" tag is
  gone — ears-drawn is simply On, and no "Screen Bar" text truncates
  into the status line anywhere.

- The "notch too long" doubling is fixed — and the menu bar stretch it
  paved is back. The island read the daemon's
  `virtual_status_device_enabled` doc for "is the Screen Bar live", so
  any dead monitor (or the missing bundled daemon — `build-app.sh`
  never copied `Contents/Helpers`) left it stale-false: the island grew
  its own ~160 pt shoulders over the bar's ears — a ~500 pt black slab
  that sat over the menu bar and covered the status items inside it.
  The read is now the local show/hide flag (`PanelStore.screenBarShown`,
  tracked, reconciled on flip), so a down core can never un-bare the
  island. `build-app.sh` also bundles `jrbar-core.app` + `jrbar-hook`
  and signs inside-out like the pkg pipeline, so the installed app
  supervises its own monitor instead of hunting a dead socket.
- The Bluetooth notification thread no longer spins a core: an idle
  `RunLoop.run(mode:before:)` returns instantly with zero sources, so
  the worker hot-looped (~100% CPU). A keep-alive mach port parks it on
  the real wait.
- The media adapter reaps itself when orphaned: the perl helper's
  stdin-EOF exit never fires after a SIGKILL'd parent, so helpers
  leaked. A watcher thread exits once `getppid` reports it orphaned.
- Mirror's capture session lives in a queue-owned box instead of
  `nonisolated(unsafe)` state, and pinning in and out while a TCC
  prompt is up can't stack `requestAccess` calls behind it.
- Parity pass 2: the last honest gaps closed. Mirror joins the notch
  card — a live camera preview row behind a toggle (consent is asked
  on the toggle, the lens closes when the card folds away, frames flow
  through `AVCaptureVideoPreviewLayer` on a private queue). The
  switcher takes type-ahead: hold the chord and spell — "saf" lands
  Safari, ⌫ widens again, and the buffer shows itself under the strip.
  Dock previews accept document drops: drag a card carrying
  `AXDocument` onto another app's preview and that app opens the file —
  the same verb as dropping on its Dock tile, one panel nearer. Menu
  Bar learned Bartender's "Show for updates": a hidden item that
  rewrites its title — a clock's minute, a VPN's "Connected" — reveals
  its run for the re-hide interval, seeded silently and never
  announcing its own motion.
- Screen-recording indicator is a documented Won't: macOS 26 exposes
  no public capture signal (`kCGSSessionScreenIsCaptured` is gone, the
  purple dot is WindowServer-composited, `replayd` keeps its state
  private) — verified live against `screencapture`. Alcove reaches it
  through private API; we won't link private frameworks for a capsule.
- Launch can no longer hang inside Bluetooth. `IOBluetoothDevice`
  `.register` synchronizes on the CoreBluetooth coordinator's
  first-contact handshake, and with a Bluetooth TCC answer still
  pending that semaphore held the main thread inside
  `applicationDidFinishLaunching` — the run loop never spun, so no
  utility ever started. Registration now lives on a dedicated thread
  (which IOBluetooth needs anyway — notifications deliver on the
  registering thread's runloop), so a wedged handshake only ever parks
  that worker and the announcements just stay quiet.
- Media-key HUDs listen, they don't intercept: the event tap is
  `.listenOnly`, which is the permission the app actually holds
  (Listen Event). The active `.defaultTap` variant silently required
  Post Event consent and `tapCreate` returned nil on every launch.
- The hidden run's handle lives in the island now, where nothing can
  park it. The agent refuses to composite a second status item of ours
  no matter when it registers — early, born-visible, fresh autosave,
  adoption beat: parked every time, a blank slot while the surface sat
  under our own wing. So the right ear's outer slice is a permanent
  `‹`/`›` handle while the concealer runs — drawn by our own window,
  hover reveals, click toggles, `›` while the run is out, and the ears
  yield to whatever real status item lands in the flank (its frame is
  published, the ear clamps to the free gap or collapses under a
  readable width) instead of drawing over it. The standalone chevron
  stays the fallback where the concealer can't run.
- Parity pass 3: Menu Bar stops hiding things you never asked it to.
  The v1 concealer auto-seeded every parked app into `concealedApps`
  once, then kept hiding them forever — layout model 3 wipes that map
  and the seed can never write it again, so hiding is strictly opt-in
  (items stay active by default; macOS's own « overflow still parks
  what genuinely doesn't fit, and hover/click reveal reaches it). The
  boundary is real again under the concealer too — ⌘-dragging any item
  across the native « caret, the host boundary, or the fallback
  chevron learns its section, so position alone picks hidden vs
  shown, the Bartender model. "Show for updates" now watches covered
  items' tiles as well as hidden items' titles.
- Dock previews stop showing purged windows as blank cards.
  ScreenCaptureKit hands back a fully transparent CGImage when the
  window's backing store is gone (occluded, off-Space, minimized), and
  the old code cached it for 30 s — an empty dark rect where a window
  should be. Transparent captures are rejected at the seam now, and a
  slot with no image shows the app icon and title instead of a ghost
  glyph. The panel takes the keyboard too: arrows walk the strip with
  a selection ring, Return raises the window, Escape folds — the
  DockDoor verbs.
- The right ear's quota ring lost its stray line — a second, finer
  reset-countdown arc in near-white sat inside the provider-colored
  usage ring and read as a scratch, not a feature. The reset timing
  still lives in the mark's tooltip; the ring is one color now. And
  the ears teach themselves: the notch card carries a dismissible
  "the ears take gestures" line until the first flick or swipe lands,
  and the media row animates a little equalizer while something's
  playing (boring.notch's telltale, ours stops when playback does).
- The separator is back on the row under the agent. The concealer hid
  the standalone chevron outright ("the island's ‹ is the affordance"),
  but a handle outside the item flow can never be a drag anchor — there
  was nothing to pull an item behind, so position-based hiding could
  not bootstrap. The chevron now stands whenever no host boundary does
  (registered born-visible before the first assertion, protected like
  every item of ours): click toggles the hidden run, and ⌘-dragging an
  item across it — or across macOS's own « while a run is parked —
  writes its section, the Ice/Bartender model. The learn itself is
  gated on ⌘: a global flagsChanged watch timestamps the last press,
  and only a side-flip with real travel inside a 1.5 s window writes —
  space-parking, reveals, arrivals and width churn never carry ⌘, so
  they can never fake a drag. One drag moves one item, so only the
  biggest mover writes; an "always" pick survives a stray drag out.
- The media ear is alive: while a track plays, whichever notch flank
  is free draws the three-bar equalizer (the island strip's grammar —
  animated, stilled under Reduce Motion, gone when playback stops).
  The session slot still owns the left while work runs and the meter
  the right; media fills the quiet ear or an unmetered right. The
  PanelStore reader shares the app's single media monitor and stands
  down when the Screen Bar hides.
- Dock previews centre the strip when it fits: one card left-anchored
  beside dead glass read as a second, empty slot (and a notch of
  see-through desktop). `ViewThatFits` centres any run that fits the
  panel; only an overflowing set scrolls.
- Notch announces the small system toggles Alcove announces: Caps Lock
  (a flagsChanged monitor on both the global stream and our own
  windows, so it fires even while a JR-Bar panel is key), a display
  arriving or leaving, and the Focus and Bluetooth capsules that were
  already wired.
- Dock previews learned the rest of DockDoor's verbs. "Min all" sits in
  the header of a multi-window preview and minimizes the whole set at
  once; ⌘-right-click on a tile quits the app (⌘⌥ force-quits) without
  opening anything; middle-click on a card closes its window.
- Dock folders pop now, DockDoor-style: an `AXFolderDockItem` tile opens
  a capped, directories-first strip of its contents with an Open verb
  and per-entry opens. The listing runs on a POSIX `readdir` off the
  main actor behind the same generation guard as thumbnails, and the
  header icon is the generic LaunchServices folder — nothing on main
  ever touches the folder, because a folder is exactly where an open()
  can pend: Downloads, Desktop and Documents gate behind
  Files-and-Folders consent, and an agent's first access waits ~5s on
  the TCC prompt before it resolves. A denied or timed-out folder says
  so — "No access to this folder" with a Settings shortcut — instead of
  spinning forever. Apps can be excluded from previews outright via the
  Dock card's filter list.
- Dock thumbnails can't wear another app's pixels anymore. A row's id
  used to be its index — a capture still in flight when the preview
  retargeted could write its pixels onto the new app's card at the same
  index. Row ids are stamped per fill now (an old preview's write finds
  no row), the capture cache keys on owner-pid + window id (a recycled
  CGWindowID can't serve another app's still), and a post-capture check
  re-verifies the preview still belongs to the app that asked.
- Fold's parked battery drain is gone. The hinge sensor jitters ±1° at
  rest, and with the Jitter deadband at its old 0 default every wobble
  retargeted the slew tracker — which never reached its moving target,
  never rested, and held the vsync link open at frame rate forever
  (a parked fold was a 60 fps timer plus a log line a frame). The
  deadband defaults to 1.5° now — above the integer sensor's noise,
  below any real lid swing, which still streams every sample through.
- Menu Bar hides like Bartender now, not like a blindfold. macOS 26
  parks any status item that no longer fits into its own overflow, and
  an item inserted mid-row pushes everything left of it there — so the
  JR-Bar icon itself is the separator: items left of it are hidden,
  hiding is the icon growing a blank spacer to its left that reaches the
  bar's fit edge (learned once per screen, never moved back on its
  own), revealing is it folding back. ⌘-drag any item across the icon
  to choose; hover or click the blank stretch, or scroll the bar, to
  peek; the icon's right-click menu lists what is hidden.
  No holes, nothing moved, the pointer never touched. The section map
  is overrides only (an item marked Cover by hand while it sits right
  of the icon is still covered in place, honestly a hole); cover-era
  maps are cleared once. A boundary found parked under a wide app menu
  learns a cap and collapses; caps reset on screen and frontmost-app
  changes. Every plan change logs to `devin.jrbar:menubar`.
- The menu bar no longer dances. JR-Bar had two status items — the
  icon and a separate always-hidden control — and a length write
  re-sorts the bar, so the two traded places on every reflow and each
  swap changed the spacer again: a two-state flap three times a
  second, ninety cycles in two minutes in the log. There is exactly
  one status item now ("always hidden" is an override cover, not a
  second boundary), a length goes out only when two passes agree and
  a second has passed since the last write, and a fit-edge lesson
  needs two fresh listings — one can be the launch handoff.
- The display stays awake while agents run. The Mac itself never
  slept — the daemon held a system-sleep assertion all day — but the
  screen was allowed to sleep and the lock followed, which reads as
  "it went to sleep while my agents were running". Keep display awake
  is on by default now; both power switches say exactly what they hold.
- Notch: with the Screen Bar drawing its ears the island used to be a
  bare black slab 12 pt wider than the notch on each side, with
  nothing in it, and it swallowed menu-bar clicks under those
  shoulders. A bare housing is exactly the notch now. With the ears
  off, each shoulder is its own width (a Now Playing strip on the
  right no longer earns the left an empty 148 pt slab), the marks are
  a point larger and brighter, the hover waits a third of a second
  before growing the card (and does nothing when "Card on hover" is
  off), the card is 320 pt wide so its rows fit, and the settings say
  what the island does under the ears.
- The menu bar holds still while macOS shows its screen-recording
  indicator. Every Dock thumbnail capture makes macOS put the purple
  indicator beside the clock for a few seconds; the whole bar shifts
  left under it and back. The spacer used to chase the shift — shrink,
  grow, shrink — a reflow each way, several times a preview. A shorter
  spacer now waits five seconds before it goes out: for the shift's
  few seconds the boundary and everything left of it sit in macOS's own
  overflow and come back on their own, and a shift never teaches the
  fit edge anything. Every reveal gesture and rehide logs.
- Notch: hovering an ear is hovering the island, the way Alcove's
  wings work — the Screen Bar's hover region (ears, tray, island) drives
  the island's own hover, a pointer still on the band is not a leave,
  the hover grows the card after 0.12 s, and the grow itself runs a
  beat quicker.
- **Menu Bar hides the way macOS 27 hides.** This Mac runs macOS 27
  (`sw_vers`), where the menu bar is one surface drawn by
  `MenuBarAgent` and a spacer can only ever feed Apple's « overflow —
  the «, the blank stretch and the fit-edge guessing were that
  mechanism's ceiling. The utility now drives the agent's own
  assessment mode (the private `MenuBarClientCore` assertion every
  working 27 manager uses — Bartender 7, Thaw, Pelmet, Ice's pending
  branch): an allowlist of apps stays, the agent conceals the rest.
  No spacer, no blank, no «, nothing of ours drawn. Sections are per
  app (Hidden / Always under Overrides), seeded once from what the
  spacer hid; hover, click or scroll on the empty bar beside the notch
  reveals; the rehide clock conceals again; a click on the clock,
  battery or Wi-Fi — which the agent ignores under any assertion — is
  held at an event tap, concealment lifted for the click, the click
  replayed at the same point. The spacer engine remains the fallback
  where the framework does not resolve — and, for now, on this build:
  the agent keeps an allowlisted app on the bar only when it passes
  Gatekeeper, and an unnotarized build's own icon is concealed with
  the rest (measured with probe apps). A notarized build (the
  `jrbar-notary` profile) turns the concealer on; the card offers
  "Hide the way macOS hides" anyway for a bar without our icon.
  Attribution in docs/PRIOR-ART.md; the audit in
  docs/AUDIT-2026-09-16.md.
- Battery. JR-Bar sat in "Using Significant Energy". Measured on an
  idle desk: the app at 3% (an Accessibility round trip to every
  running app twice a second, and three pointer polls at 10–20 Hz) and
  the daemon at 2% in bursts (a whole-table `ps` on every state build,
  `diskutil` per mount, the 15 s refresh). The listing now asks only
  the apps known to own items and walks every app once in twenty
  seconds or on a launch/quit; the pointer polls fall to 4 Hz while
  the pointer is far from their zone; the daemon caches the process
  table for ten seconds and sweeps liveness every fifteen.
- The Screen Bar's ears end where the hardware ends: no 6 pt chin
  below the bezel, ears 24 pt wide — the black no longer reads as the
  notch grown down and sideways.
- The `‹` beside the icon is gone: macOS's own « already marks the
  run's other end, and two left-pointing marks 200 points apart read
  as clutter. The tooltip and the blank stretch are the affordance.
- The island grows straight down from the notch. Its hosting view had
  no sizing contract, so mid-grow the 320-point card was laid out at
  the window's left edge and marched with it, then snapped centred at
  the last tick — "the notch comes in from the side". The toy owns the
  frame now. And every face shares the notch's centre: the idle window
  takes the wider shoulder on both sides and the content hugs the
  notch, so a morph between faces never travels sideways.
- Maintenance: a settings edit re-applies only the utility it
  belongs to (a dragged Agents slider used to reconcile the menu bar
  and rewrite the Dock's defaults a dozen times over); the aquarium's
  economy ticks and writes to disk only while the toy is on; "Clear
  finished" clears exactly the rows the card counted; the buddy's
  timeline pauses under Reduce Motion; Accessibility values are
  type-checked before the casts that could crash on a stray item.
- Dock previews are usable on an auto-hidden Dock: the panel follows
  the tile while the Dock slides in and never leaves the screen, sits
  one level under the Dock so a magnified icon still takes its click,
  gets mouse-moved events so the hover × and – actually appear, keeps
  the tile's rest clock across the seam between two tiles, previews
  nothing for an app with no windows, raises the picked window
  rather than every window, matches a late thumbnail to its card by
  identity, reads the Dock's tiles once a quarter-second instead of
  twenty times a second on the main thread, and stays out of screen
  recordings. The panel's content fills the glass and the panel is
  sized from its intrinsic size — the hosting view used to sit at its
  first frame in the panel's corner, which read as off-centre. The
  card's copy says what the toggles do.
- Dock is one mode. Enhance keeps Apple's Dock and floats window
  previews over it; the Replace bar is gone (a replacement dock has to
  get minimize animation, drag-to-dock, Exposé and Stage Manager right
  first — each is weeks). Previews match thumbnails by window frame so
  untitled and same-titled windows get their own capture, include
  windows on other Spaces and minimized ones, carry hover-revealed
  close and minimize buttons, offer Hide/Quit (or Open) in the header,
  close on a click anywhere else, sit on glass, and come in a large
  size. The permission probes that ran twenty times a second are
  cached for three seconds; the Dock's AX list is cached while the
  pointer is away.
- Notch: the resting island's dots were drawn centred under the
  hardware notch, where nobody can see them, animating at 15 fps. The
  content lives in the shoulders now — agents on the left (a dot per
  working provider plus the count), attention on the right (open asks
  in amber with their count, failures in red) or the Now Playing strip
  — and the island stays a bare housing while the Screen Bar draws its
  own ears there. One Now Playing feed serves the island and the card
  (two perl helpers used to run). Every quota meter — notch card, ear
  ring, menu bar, Usage Center — leads with the same most-constrained
  window, so a provider can no longer read 17 % in one place and 100 %
  in another.
- Aquarium: sessions stay fish. A fish raised to stage 1 or beyond
  keeps swimming after its session leaves — a resident, idling under
  its remembered name in its provider's species, up to six, living on
  feeding alone and still starving down a stage at a time. A returning
  session takes its fish back, same swim.

- Fold actually shows again: a captured desktop frame that arrived
  before the overlay existed was dropped, leaving an ordered-in window
  with no texture — invisible forever on a static screen, where
  ScreenCaptureKit may only ever deliver one frame. The frame now
  materializes the renderer itself, and a stream that stays frameless
  is recycled every 5 s instead of hanging. The Fold card gained a
  "Fold state" line that names the first missing link (waiting for a
  frame / needs Screen Recording / paused) instead of just "On", and
  the decision chain logs to `devin.jrbar:fold` so a real close can be
  read back from `log show`. Parked-lid churn found by that
  instrumentation is gone too: suppressed polls no longer re-push the
  sensor's polling state 120×/s.
- Alcove is a real toy now: JR-Bar draws its own notch island — a
  capsule hugging the notch that breathes with provider dots and a live
  count ("3 working · 1 waiting"), and grows into a card on hover with
  the session roster and per-provider usage meters. "Render with" picks
  who owns the notch: JR-Bar's island, or the real Alcove / Boring
  Notch, which JR-Bar parks itself for and can install or open.
- Confetti fires on the triggers you choose, not just the weekly
  reset: weekly reset (default), per-provider resets you pick, a
  session completing, Codex banking credits back, or every ask clearing.
  Event triggers dedup against a persisted ring so a restart can't
  re-celebrate, and document edges seed a baseline on the first state
  so nothing fires on facts older than the app.
- The second `‹` on the bar is gone for good. The Screen Bar's
  right ear carved a handle slice and drew the glyph whenever the ear
  existed — the provider's nil answer only stopped the click, not the
  mark — so the ear's `‹` stood ~100 pt from the status item's own
  mark with nothing behind it. The slice now exists only while the
  provider reports a real revealed handle.
- The ears take Alcove's gestures for real. A dismissed wing used to
  resurrect on the next tick: dismissal matched the slot's *value*,
  and the right ear's usage meter mutates its own value every refresh,
  so the lobe was back within a second — and with nothing left
  dismissed, the summon swipe found nothing to restore. Dismissal now
  keys on the wing's subject (provider + symbol + visualizer kind), so
  value churn can't wake it while a different subject claiming the
  side still revives it. The summon surface is the ghost: the lobe's
  last rect stays in the hit region in *screen* coordinates — it used
  to keep view coordinates and reconvert them after the relayout, which
  threw the ghost a screen-height off the top. Flick dismiss, swipe the
  ghost or the band to summon, drag down for the card.
- A Bluetooth reconnect can no longer crash the run loop.
  `IOBluetoothDevice.value(forKey: "batteryPercent")` raises
  NSUnknownKeyException on devices that don't publish the key (it does
  not return nil), and a device connecting mid-session threw on the
  main queue — wedging the gesture monitors with it. The read is
  gated on `responds(to:)` now.
- Dock preview traffic lights went traffic-light small: 13 pt discs
  inside an 18 pt hit ring each, so the header hugs the card title
  instead of padding around fingertip targets, and a window title that
  just repeats the app name isn't printed twice in the header.
- Fold's residual judder is gone. Three sources, each measured: an edge
  timestamped across a 20 ms floor could claim a 500 °/s slam (now
  capped at a physical 240 °/s); a 1° wobble mid-close snapped the
  velocity's sign (below 15 °/s it blends weakly instead of reversing);
  and the first-order ease transmitted every sensor edge's slope step
  straight to the eye — the displayed delta now rides a critically
  damped spring that turns slope steps into acceleration and clamps at
  the physical floor, so the close glides at the sensor's own cadence.
- The native Alcove island does the real thing now: agent events slide
  a notification capsule out of the notch — asks, completions, failures
  and quota resets, each toggleable — queued newest-wins with a 30 s
  same-source cooldown so a burst never strobes. Now Playing rides the
  idle capsule (artwork + track line + a live visualizer) via
  MediaRemote, with transport buttons on the card and Alcove's own
  gesture: a two-finger swipe left/right skips tracks, a swipe down
  dismisses the capsule or folds the card away.
- The buddy can leave the notch. Click-and-hold carries it anywhere on
  screen — a drop near the notch snaps it home, anywhere else it parks
  floating on its own glass pill with a dangle-and-squash landing.
  Right-click, control-click, or hold a press half a second and it
  menus: pet, treat, rename, change character, open the waiting
  session, dock/float, caption, or tuck away. The caption names what
  it's watching — "Claude · rename-the-fish — waiting on you" — and a
  tucked buddy wakes on the next real event.
- The Aquarium got its polish pass: kelp is broad translucent blades
  with lit, ruffled margins instead of ribbons; the floor is overlapping
  dune humps with a lit crest and ripple contours; fish tails phase-lag
  behind the head and fins read as fins (the angelfish is a diamond
  now, not a leaf); and name tags are floating chips on a hairline
  tether instead of boxes.
- Notch Buddy is a pet: ten characters on one skeleton (Axolotl, Crab,
  Mushroom and UFO joined the six), a name field with per-character
  defaults, a "Give treat" button that bursts hearts, a tap on the pill
  that cycles hop → spin → wave → blush — or opens the session when an
  ask is up — a crumb it eats for each completed session, and droop
  when nobody's patted it in a day.
- The Aquarium tells the states apart: idle sessions drift at
  third-speed and occasionally sip the surface, waiting ones float up
  with a pulsing ring, failed ones sink and roll, and a completed
  session corkscrews out the top-right dropping pellets the nearest
  fish dart over to eat — a burst of finishes pops a bubble plume off
  the chest. Hover or tap any fish (fry included) for its name tag, and
  a four-minute day/night wash keeps the tank alive.
- Session names make sense now: a Devin session is titled by its first
  prompt (or explicit title) instead of `Devin cubic-cl` — the slug
  falls through whole, so the fish reads `cubic-class`, and once a real
  name lands, later facts can't rename the row. Sub-agent workers keep
  their titles on replay.
- Creator Micro 2 no longer reports "malformed report" and drops its
  RPC link when the pad pushes a notification we didn't expect: id-less
  messages only need a string `m`/`method` now (params optional, extra
  fields kept under `extra`), an unreadable push is skipped and logged
  once instead of disconnecting, and the receipt names the offending
  keys when one does fail. A daemon restart no longer accuses the pad of
  a "foreign response id" either: stale replies to the previous process
  are drained on connect and ignored for a 3 s grace, an out-of-order
  reply to our own id is retired instead of read as a second controller,
  and a real conflict retries the connection after 60 s rather than
  parking the pad for good.
- Devin sub-agent tracking hardened from review: the Sidekick worker is
  scoped per session (two sessions' sidekicks no longer share one row),
  background helpers are retired on SessionEnd rather than the turn's
  Stop, a completion without the title can't erase a worker's name, and
  replayed labels are bounded/printable.
- Devin sub-agents are tracked. Devin CLI fires no subagent hooks, so
  the daemon now derives workers from the parent's `run_subagent` and
  `sidekick` tool calls: PreToolUse opens a worker under the session
  (labelled with the sub-agent's title, or "Sidekick"), the matching
  foreground PostToolUse closes it, and the parent's Stop/SessionEnd
  retires any background workers still running. One Devin session with
  three helpers now reads as one main plus three workers — in the panel,
  the light, and as a school of fry in the Aquarium.
- Notch Buddy grew a roster: Dot (redrawn — gradient-lit, catchlight
  eyes, a mouth that changes with mood), Cat, Ghost, Robot, Owl and
  Slime, all sharing one skeleton; a picker with a live preview strip;
  and an info layer — a count pill at the buddy's feet while 2+ sessions
  work, "!2" when more than one ask is open, and a hover line
  ("3 working · 1 waiting · Codex, Claude").
- Aquarium looks like water now: layered gradient with a caustic surface
  band and meniscus, soft swaying god rays, vignette and glass highlight;
  a dune sand bed with speckle and back-wall depth; kelp ribbons, sea
  grass, two coral types, shaded rocks, a proper chest, shells, a sunken
  bottle; scattered two-depth plankton; countershaded fish with eye
  catchlights, translucent fins and a sand shadow; a resident jellyfish
  and a quiet caption instead of "Nothing swimming yet".
- Confetti: the weekly-reset burst is tunable — Landing (rest on the
  strip / rain to the bottom edge / dissolve mid-air), Palette
  (provider / Toys tint / rainbow), Shapes, Density and Duration; the
  overlay's height and lifetime now follow the mode and the slowest
  piece's own travel.
- Fold: back to the physical plane-hold model — the held desktop
  counter-rotates by the real lid delta again (the v3 bounded-arc
  shader with its sheen/seam/void/close-fade decorations is gone);
  blur and shading follow sin(tilt)·height; 80 ms easing.
- Fold's lid tracking was rebuilt around the measured sensor cadence:
  the hinge report is a 10 Hz sensor that steps every ~100 ms and sits
  dead steady at rest (probed at 240 Hz), so the old α–β predictor read
  a phantom slam at each step then zero velocity until the next — a
  10 Hz sawtooth the poll-rate kick only made worse. `LidTracker` now
  dead-reckons from each sensor edge instead: a blended velocity per
  edge, extrapolated at most 150 ms and clamped to ±8°, zeroed after
  0.3 s of quiet — and the pump polls at the sensor's own 10 Hz above
  the arming band, 120 Hz inside it so each edge is timestamped to
  ±8 ms. The 80 ms ease remains the only smoothing.
- Four new provider animations ported from the upstream SidePulse
  animation catalog: **Ember** (a centre-hot idle swell — the upstream
  idle-pulse gradient), **Bloom** (a centre-out spread — the lid-open
  program as a loop), **Frontier** (a held fill whose tip breathes — the
  battery-bar pattern, so a level can ride the strip) and **Glint** (a
  thin specular pass over a lit bed). Each ships as a pure motion shape
  rendered through the shared DSL, so it works identically on SidePulse
  Pro, Dot, the Screen Bar and every preview — 2-LED and 8-LED, solo
  and segmented — and every one is firmware-validated inside the
  512-byte/20-line budget.
- Effect Studio's gallery search now ranks an effect whose name or id
  matches the query above description-only hits — searching "pulse"
  finds Pulse, not whichever description happens to say "pulsing".
- Fold fixes from review: the overlay no longer hard-cuts when the raw
  angle crosses above activation (it eases home on the same glide), a
  starved predictor can't leave the render angle led on a parked lid,
  the vsync link stops being born and killed per parked sample, capture
  can't revive after shutdown on a slow permission grant, the sensor's
  rate reschedule can't mint a phantom slam, and the Metal view clamps
  to a real frame-rate floor.
- Aquarium: "is this a fry" now follows the panel's own `mainSessions`
  rule — a main session that merely names a parent keeps its full fish,
  and a parentless worker swims full-sized instead of schooling at a
  ghost anchor.
- Confetti's window lives 3.4 s — the slowest streamer was still
  visibly falling when 2.6 s used to vanish it.
- Dock previews hold the Dock out. A preview panel used to sit over an
  auto-hidden Dock that slid away the moment the pointer left its tile,
  taking the hover with it; the utility now drives the Dock's own
  autohide (`CoreDockSetAutoHideEnabled`, the private call DockDoor
  uses, probed at launch and fail-soft) so the Dock stays raised while
  a preview is up and its autohide setting is restored — never bounced
  — when the panel closes or the app exits, even after a crash.
  Preview cards gained Fullscreen and New Window verbs and actually
  open windowless apps now (the Open button's path used to dead-end
  before it could render), and a tile with more windows than the new
  compact-list limit falls back to a row-per-window list instead of
  outgrowing the screen.
- Notch: the ears answer a hover. A pointer resting on a Screen Bar
  ear swells the ear's mark outward — the tell the bare island could
  never show — and the grown card's deadline depends on where the
  pointer came from: straight onto the island opens after 0.12 s, a
  drift down from the menu-bar row waits a third of a second (the copy
  always said so; the code now agrees), and crossing ear-to-island
  keeps the original deadline instead of re-arming the short one.
  Hover-open holds back entirely while a fullscreen app is frontmost,
  and an optional haptic tick lands when the card opens (Notch
  settings).
- The escalation ladder notices when you're already watching. An ask
  whose own terminal pane is frontmost — proven the daemon's way, the
  host app's bundle plus the frontmost process on the session's
  ancestry — gets its banner for the record but no sound burst, no
  menu-bar pulse and no chime, and walking away from the pane re-arms
  the stage without waiting for the next boundary. Toggle in the Agent
  Overview card ("Quiet while you watch"). The quota ear now reads the
  window's reset too: a fine arc inside the ring drains toward the
  reset, the peek and the island card name it in words, and a live
  incident from the provider's status feed — the daemon polled them
  all along; the wire simply dropped the field — badges the ear amber,
  the panel row and the Usage Center header with the feed's own text.
- Agent Overview actually opens now. The window used the weak,
  deprecated activation call, so from a menu-bar accessory the panel
  could order front on another Space and look like "nothing happens" —
  `show()` now does the house's activation dance, un-minimizes, and
  re-centers a frame autosaved off-screen. And it earns its name: the
  window opens on a Connections browser built from the state the
  daemon already pushes — the core link and version, each node with
  its session count, every device with its link state, every provider
  with its quota read — with the honest "source not found" /
  "disabled" labels instead of invented ones, alongside the roster
  table and graph it always had.
- The Screen Bar is part of the notch, not a slab over it. The strip
  used to seat at the bezel's depth no matter how tall the island
  grew, so with the card up the band and its housing cut straight
  across the island's face — the "clipping into the notch" read. The
  strip now rides the island's live bottom edge at every size, and
  the housing's top corners are scooped where they would pave the
  bezel's rounded arcs (even-odd fill, so the corner gaps are real
  holes). The wings grew actual lobes: claimed ears drop below the
  bezel line as rounded feet with the mark centered in the ear — the
  Alcove silhouette — while the shared tray stays flush under the
  bezel between them and an unclaimed side grows no lobe at all.

## 0.9.7 (unreleased)

- Fold learned the last of the gesture. The fold is now a bounded 0…1
  arc from your activation angle down to the shut line instead of an
  ever-steeper tilt — the iPhone-Duo shape: invisible at activation,
  composed through the swing, and finishing to near-black in the last
  degrees so a full close reads as the display switching off. An α–β
  predictor leads the measurement by ~60 ms of lid travel (clamped to
  ±8°, dead while parked, killed on reversal), which is what hides the
  sensor→capture→display latency — the fold follows your finger instead
  of trailing it. HID reads moved off the main runloop onto a serial
  queue, the poll adapts (10 Hz idle / 60 Hz armed / 120 Hz while the
  lid swings), and clamshell & display topology are cached facts instead
  of IOKit/CoreGraphics queries at vsync rate — the jitter the old
  engine could never ease away. The matte is a golden-angle Vogel disc
  over real mip levels (each frame blits into a private mipmapped
  texture, no CPU decode) whose radius grows toward the far edge and
  with lid speed; a sheen band, hinge seam and edge feather finish the
  glass. Tilt = projection only; Dusk = dim + light matte; Fog = dim +
  deep matte.
- Aquarium grew into a real tank. Every provider is its own species now —
  clownfish, shark, angelfish, puffer, seahorse, betta, tang, tetra —
  and sub-agent sessions swim as fry, ~0.45× and capped at eight,
  schooling loosely around their parent fish and sharing its fate (a
  completion spirals the whole school off the edge). The floor is
  furnished: seeded kelp strands, pebble beds, coral, a starfish and a
  treasure chest that burps bubbles; a jellyfish drifts through every
  so often and a snail inches along the sand. Reduce Motion stills the
  sway; occlusion still pauses the tank.
- Notch Buddy got busier and cuter: a gathering bounce when three or
  more sessions work at once, a nightcap while asleep, a tumble-in on
  failure, and asks now alternate between the full wave + "!" and a
  quiet lean-in that just holds eye contact. Confetti bursts carry
  provider-coloured glyph flecks, streamers bounce once on the floor
  and rest as ribbons, and the pop cone throws a few spark streaks.
- Screen Bar Screensaver is gone, end to end — the card, the
  `screensaver_peek` command, the `ambient.screensaver` fact, the
  `idle_screensaver_*` settings and their tests. The ambient runtime's
  other seams (semantic cues, DND, night) are untouched.

## 0.9.6 (unreleased)

- Toys. A new Settings page for the things that are fun first & don't
  touch agents or usage (docs/TOYS.md). Six to start: Fold, your desktop
  tilting, dimming & blurring as the lid comes down, rendered by JR-Bar
  from the hinge sensor, or handed to Bendy or Lid Plane if you'd rather
  (Tilt / Dusk / Fog, activation angle, a simulate slider, pauses on a
  closed lid, mirroring & sleep, never touches an external display);
  Aquarium, every session a fish in its provider's colour, asks come up
  for air, failures sink, completions drift off; Notch Buddy, a small
  creature in the notch who sleeps, paces, waves & hops with what your
  agents are doing; Confetti, a burst in the provider's colours when a
  weekly limit resets (the `quota_reset` event now names the lane);
  Screen Bar Screensaver, the strip & bar play an effect from your
  library after a long idle instead of just going dark, preempted the
  moment anything real happens; and an Alcove card that shows the
  capsule JR-Bar is already following. Any .app on the Mac can join the
  shelf too: launch, quit, launch with JR-Bar, remove. Everything is off
  by default & remembered in the app's own state file.
- Fold learned the real trick. The overlay now treats the captured
  desktop as a rigid plane still standing at the anchor angle while the
  lid swings under it — the hold-the-angle illusion instead of a warp —
  so at the activation angle the render is pixel-identical and nothing
  appears until the lid is meaningfully closed. The delta eases with an
  ~80 ms exponential filter on a vsync display link — the 30 Hz sensor
  moves the target, the screen's own refresh moves the fold — blur is a
  real Gaussian pyramid baked once per frame with a radius that grows
  toward the far edge, and the image boundary feathers into the dark
  surround. Under the hood: capture is capped at 2560 px, drops the
  cursor, only accepts complete frames and excludes all of JR-Bar's
  windows; the stream stays alive across the activation line instead of
  restarting on every crossing; and the activation gate reads the raw
  sensor angle so jitter can never hold the overlay open. A corrupt HID
  report outside 0–180° is dropped, "lid closed" now comes from the
  registry's clamshell state rather than the keep-awake hold, and the
  shipped defaults moved to 82° / Dusk — a file still carrying the old
  untouched defaults migrates.
- The toys stopped feeling like novelties. Confetti is a real cannon
  now: 140 pieces launched from the notch under closed-form ballistics
  (gravity plus quadratic drag, solved rather than integrated), cards
  and streamers that tumble, twirl and flutter to their own terminal
  speeds, a muzzle flash & shockwave on the pop, and a radial bloom in
  place of the burst under Reduce Motion. Notch Buddy grew a skeleton:
  it blinks, anticipates turns, leans into its stride, squashes on
  landing, wears the working provider's colour while it paces, crouch-
  jumps and springs a "!" on an ask, throws sparkles on a completion,
  and sags half-lidded when work fails. Aquarium is a body of water:
  sun glow, god rays, caustic shimmer, a dune floor, parallax plankton,
  and fish with real skeletons — notched tail-fan beats, pectoral flaps,
  sheen & belly shading, depth lanes that shrink and desaturate the far
  swimmers, wall approaches that pitch & squash, edge swim-ins for new
  sessions, nose-up ask rises and failure drops that rock to rest on
  the sand. Screen Bar Screensaver can audition itself: a live LED
  preview of the picked effect on the card plus "Play it now", which
  stages the effect through the same admission gates on a short window
  (2–15 s) and retires it on its own — new `screensaver_peek` command.
  The status chips breathe while a toy is on.
- Every control does what it says. An audit found eight settings that
  wrote keys nothing read or described things the app couldn't do:
  Show in full screen, Gap width and Wing length now shape the Screen
  Bar for real; the Bracket style picker is gone because the app never
  drew one; menu-bar wrap follows its setting; a strip's resting glow
  survives a settings round trip (the daemon dropped it from the
  document); analog joystick sectors can carry mappings, editable in
  the Control Center, which is also where the pad's help text now
  points; and the session-key help no longer implies matrix keys take
  explicit mappings. `uninstall_hooks` and the legacy-only settings are
  documented.
- The app target has tests now. `JRBarAppTests` covers the panel row
  helpers, the menu-bar item's spec/label/width reconciliation, Screen
  Bar program acceptance and the deck apply-sheet planning; the Screen
  Bar geometry moved to JRBarUI with its own tests.

- The Creator Micro 2's hardware layers now mean something. The daemon
  polls the pad's live layer over `device.status` and scopes the session
  board to it: layer 1 stays Automatic (every session, asks first),
  layer 2 is Codex, layer 3 is Claude, and any provider — T3 Code
  included — can be added as a cyclable scope from the Control Center.
  Because input reports carry no layer field, lighting follows the
  board the pad is actually showing; scoped boards only ever carry live
  sessions of that provider, so dead "Reserved" identities can't fill a
  layer. The keymap now writes every mapped layer in one apply (the
  preview shows the real multi-layer write), and the encoder pages
  banks while the joystick cycles scopes out of the box — explicit aux
  bindings still replace the whole set.
- Snoozed sessions stop asking for attention. A snoozed ask or working
  session no longer drives the attention lights, the escalation ladder,
  or the "needs you" count — the gate sits at the projection seam, so
  every consumer agrees. "Unsnooze all" previously only lifted asking
  sessions; it now clears every family actually snoozed, and the status
  menu shows a live "N sessions snoozed — unsnooze all" row while any
  exist. When escalation does fire, the menu names the stage ("menu
  bar flash", "chime") so a repeating chime is no longer a mystery.
- The webhook toggles do what they say. Ask opened, session failed, and
  quota threshold crossed now emit through the existing escalation
  webhook machinery — once per edge, never for refused batches — where
  only "completion" was wired before. Quota resets publish a
  `quota_reset` event regardless of celebration preferences so the
  Usage Center can refresh, and peer arrivals/departures emit events
  while `state.peers` finally carries the live fleet (the Remote page
  shows it).
- One bad row can't blank the document. State decoding now drops a
  malformed session, ask, device, usage row, or light surface
  individually instead of rejecting the whole frame; a field whose
  container type violates the protocol still fails closed.
- Settings tells the truth about what it can't do. A banner warns when
  the daemon's settings schema is newer than the app understands,
  notifications show a "permission denied" warning with an Open
  Settings button instead of a toggle that can't deliver, and the
  panel's brightness slider stays enabled without a strip because the
  Screen Bar is a real brightness target. The first-run card now
  teaches the band's two powers — hover for who's asking, click to jump
  to the session.
- Idle power draw drops. Device inventory polling backs off once the
  hardware set is stable (and speeds back up around connection changes
  or while the Devices pane is open), lid observation runs a slower
  cadence when only animations need it, screen sleep forces an
  immediate lid poll, wake forces a lighting reassert because the strip
  may have rebooted into its stored program, and the repeating timers
  carry wider tolerances. A mounted SidePulse volume no longer leaks
  into tests through the keepalive scan.
- Scene packs now apply. The active pack merges its policy overrides
  over the base policies fail-closed (missing, corrupt, or mistyped
  entries disable rather than guess), the cache is bounded and keyed on
  content, and the rainstick idle/night and milestone-odometer cues have
  real settings flags so they can actually be turned on.

## 0.9.4

- Black means black on a linked Screen Bar. The mirror's luminance lift
  was a flat floor, so every dim code — embers, fade tails, codes the
  strip's write boundary crushes to off — painted the same constant glow
  the hardware does not have. The lift is now a continuous curve that
  keeps dark beats dark: `#000000` stays exact, near-black stays
  near-black, and a mid-dark tail gets only a partial lift. The surface
  also reports the program's own `brightness` (the strip's) rather than
  the bar's ambient plan, and the housing rim follows the live Minimum
  glow setting and turns off entirely while the band shows no light.
- Animations no longer restart on brightness noise. Ambient-lux drift
  was baking a new `brightness N` into the program text every refresh —
  a real firmware write, a new anchor, a visible restart on the strip
  and the bar alike. Emitted brightness now has hysteresis: sub-
  perceptible drift is held, deliberate settings writes always pass,
  and fades to zero are never held. A republish with the same program
  and a nil or unmoved anchor no longer recompiles anything; a moved
  anchor re-aligns by replaying the plan, not rebuilding it; and a
  window move that changes neither plan nor phase is a no-op.
- A reassert now publishes the program the strip is actually running.
  Reasserts write the steady-state variant (no approach frame), so the
  strip's loop is shorter than the published text — the bar drifted a
  little further off phase every lap. Both `last_program` and the
  nominal mirror now record the running variant.
- The document dedupe now works: state and lights frames carried ticking
  fields (`now`, ages, now-relative forecasts) that made every broadcast
  look changed. Publish-time compares significance with those volatile
  paths stripped — a quiet rebuild costs one compare instead of a full
  broadcast-and-redecode on every client.
- `menu_bar_icon_style` no longer bounces: the daemon accepts all five
  app styles (it only knew the three glyph styles, so picking a meters
  or dots style reported "the core kept 'glyph' instead").
- Copy sweep, round two: the daemon is "the monitor" in user-facing text
  (tooltips, toasts, empty states, errors); the Screen Bar chip says
  "shown"/"hidden" instead of borrowing "connected"; Ask/Error carry
  their Lighting names in the assign sheet ("Ask — needs you",
  "Error — failed") with a caption explaining the reservation and why
  only two states are offered; the Active scene subtitle says what it
  does; the Stream Deck card gained its own serve toggle; the integer
  slider shows its unit; the rail and the band ease in and out instead
  of snapping (Reduce Motion keeps the instant swap); "Details" is
  "Usage Center"; elapsed-time units read the same everywhere.
- Small bounds: the per-session extras cache is capped; the lights build
  asks for the device list once instead of twice.

## 0.9.3

- Linked Screen Bar mirrors the strip's program, not a second rendering
  of it. The bar and the SidePulse shared an anchor but drew from
  different palettes (agent colours vs. mode colours), so the same beat
  could read as two different lights. When linked, the bar now presents
  the strip's nominal program — timing and hue identical — lifted to the
  display legibility floor, hue and saturation intact. Drive bytes stay
  on the strip: the bar never wears the die's calibration.
- One word per thing, everywhere. "Needs you" is the same phrase in the
  panel, the menu bar, and the effect targets; the Dot's roles read
  Mirror the strip / Alert beacon / On its own (they were Extend /
  Ask beacon / Status while the wire said linked / beacon / solo); the
  two link toggles say what they do — "Mirror the hardware strip" and
  "Dot follows the strip"; blend-mode names and descriptions now match
  between the app and the daemon; "Everywhere" is one scope, one name;
  percentages are "42%", window names match their menu items, and
  internal words ("core", raw enum names like `command_confirmation`,
  transfer-generation numbers) no longer leak into the UI.
- The first-run card tells the truth about the light language — a beat,
  not a strobe (nothing strobes), red means broke — plays a real
  LEDStripPreview instead of a gradient, eases out instead of
  vanishing, and points at the menu-bar icon.
- Screen Bar settings live on one page: the General section moved to
  Devices & Screen Bar; the Devices card no longer duplicates the
  serve toggle (status stays, the switch lives in Remote).
- Frame dedupe on the wire: identical state/lights/settings documents
  are never broadcast twice — a poke that changes nothing costs one
  encode instead of a full broadcast-and-redecode on every client.
- Terminal and TTY lookups are keyed by (pid, process start) instead of
  pid alone: a reused pid can no longer inherit the previous owner's
  terminal, and both caches are bounded.
- The status menu's Lights line says what the band is doing — "monitor ·
  working · following Alcove" — instead of render-pipeline diagnostics.

## 0.9.2

- Auto-dim's ambient curve is calibrated for real rooms. The sensor that
  faces you reads ~50-150 lux in a normally lit space; the old defaults
  treated 400 lux as "bright" and 5 lux as "dark", so every indoor room
  pinned the bar near its 10% floor. The defaults are now 15 lux → 35%
  rising to full at 150 lux. Lighting › Auto-dim also gets a "use this
  room" calibrator that sets the marks from the live reading.
- A resolved ask can no longer hold a session on "waiting". The
  canonical projection counted resolved request tombstones as open
  requests, so a Codex permission prompt kept the row — and its share
  of the light — waiting after you'd answered. Only live requests whose
  next actor is the user pin a session now.
- The four long-standing red tests are fixed, not skipped: the battery
  LED tests get a controllable clock, the Grok-payload routing test
  stops inheriting the host's process ancestry, and the Codex
  permission test is the fix above. The Python suite is fully green.
- Clock continuity heals: a freshness-only source loss used to pin the
  daemon at "uncertain" forever; it now ages out after the timing lease
  while a genuine source loss still requires two confirmations.
- Effect Studio answers "what plays on Devin?" — a What plays where
  section groups each live provider's motion, its instance and semantic
  rows, and device rows in one place, and the assign sheet re-hydrates
  parameters per (scope, target) instead of showing the last tuning.
- Stream Deck is in the hardware section: a card on the Devices page
  shows the status endpoint, copies the bearer token, toggles serving,
  and a minimal polling plugin scaffold lives in `integrations/streamdeck/`.
- First launch gets a one-card orientation — what the band is, what the
  marks mean — hung under the band after the hook-install toast, once.
- Reduce Motion now reaches the band: the Screen Bar holds a still frame
  instead of animating, and the band, preview strips, and panel rows
  speak VoiceOver — including which session the band is showing.

## 0.9.1

- The default multi-agent look is Smooth (`color_blend`): one seamless
  light mixed from every active agent's colour. On the Screen Bar —
  which already blends each LED with its neighbours — Everyone's
  alternating per-agent blocks averaged into a shifting grey seam; a
  single mixed colour stays one calm band however many agents report.
  Existing `colors.blend_mode` values are untouched; Everyone, Split,
  Spotlight, One at a Time and Status Only remain in the picker.
- The Assign sheet can no longer promise what the daemon won't deliver.
  Its default draft is Provider scope aimed at a provider this Mac has
  actually seen, the State picker only offers the routable targets
  (Notification, Done), the Provider picker lists live providers first,
  the Project target accepts real origin labels ("Claude in VS Code")
  instead of demanding an identifier that can't exist, and the dead
  "Screen Bar" device target is gone. The sheet also says when a draft
  would replace an existing assignment, surfaces the daemon's
  `motion_warning` when a provider-motion write fails, and stops toasting
  "assigned to everywhere Everywhere".
- `remove_effect_pack` exists on the daemon — the Studio's pack removal
  no longer answers `unknown_command` — and scene packs can be imported
  from the window. Assignment rows say what they do ("plays as Devin's
  motion while it works", "fires on done events", "the Dot follows the
  strip while linked").
- Dead call sites removed: the fire-and-forget `applyCalibration` and
  `previewCalibration` posts are gone; every calibration call awaits its
  verdict.

## 0.9.0

- Assigning an effect now does what the picker says. Provider-scope
  `provider_animation` assignments write `colors.provider_animation`, the
  persistent per-provider motion the solo renderers already read — so
  "Devin breathes while working" is a real write instead of a recorded
  wish, and clearing the assignment restores Automatic. Semantic targets
  the event router can never deliver (`working`, `idle`, `recovery`,
  `environment`, `transition`, `quota`) are refused `unroutable_semantic`
  rather than saved as a write-only row, and an assigned effect's own
  program — parameters applied — is what reaches each surface, rendered
  once per selection and compiled per LED count. The four bounded
  builtins keep their safety-timed variants.
- Settings > Remote's Serve switch runs the endpoint it describes. The
  app mints a bearer token once (`~/.local/state/jrbar/serve-token`,
  0600) and hands it to the daemon it spawns; with `serve_enabled` on the
  core hosts `serve.py` in-process on loopback and `serve_token` reports
  `running` alongside `enabled`, so the card can say serving, not just
  switched.
- The core protocol grew the commands the panel's newer affordances need.
  `dismiss_session` acknowledges a live or stuck row — the same receipt
  `clear_completed` writes — so it leaves the list until the session next
  speaks; remote rows and sessions with an open ask are refused.
  `mark_history_seen` advances the activity ledger's persistent
  `last_seen` watermark, and `list_history` now derives each row's
  `unseen` from it rather than a stored flag. `list_scene_packs`,
  `import_scene_pack` (validate-and-preview before any write, with
  version-1 packs migrated on the way in) and `preview_scene_pack` expose
  the Scene pack store to the Studio. `serve_token` hands the loopback
  status endpoint's bearer to Settings over the local socket only.
- The state document says more of the truth. Asks carry `answerable` and
  `replyable` computed from the provider's negotiated contract and the
  registered handler, so an Approve button is never offered for an ask no
  daemon can type. Sessions carry `remote` for a peer Mac's row.
  `health.detected` reports which provider CLIs were actually found, and
  `install_hooks` answers per-provider `detected` plus a refused row for
  a provider that was never seen rather than claiming success.
  `catalog_generation` lets a client reload the effect catalog only when
  it actually changed.
- The mock daemon (`app/scripts/mock-core.py`) matches: dismissal,
  remote rows, history watermarks, scene packs, detected-agent metadata
  and the serve token, so app development and fixture tests exercise the
  same contract.
- The panel says what it means. `long_task_progress` rows read Working
  instead of grey Idle while the header still counted them; failed
  sessions get their own tint and count; asks sort oldest-first and
  snoozed ones stop pulsing in the menu bar; quiet rows say quiet, remote
  rows say which Mac, and a stuck row can be dismissed in place.
  Answer-in-place only offers Approve/Deny or a reply field when the
  daemon reports the ask answerable, and a refused answer surfaces the
  refusal (with the Accessibility-settings deep link when that is the
  missing piece) instead of toasting "Approved" anyway.
- The surfaces got honest. Effect Studio's scope picker only offers
  targets that can fire, "keep tuned parameters" actually reaches the
  daemon, scene packs list/import/preview from the window, and hardware
  preview says which target it lit. History rows carry real durations,
  open affordances only appear on live sessions, and the unseen banner
  resets when the window opens. Usage Center reads the daemon's
  per-window forecast, keeps duplicate provider accounts distinct, and
  shows missing readings as missing rather than zero. Calibration errors
  surface instead of silently saving, and hardware-gated controls say so
  when nothing is plugged in.

## 0.8.1

- A Devin session could read "Working" forever. The startup replay seeds a
  compatibility status row per session from the newest legacy record and
  normalized ingest never touches it again, and the merge let that frozen
  row shadow the live canonical projection on precedence alone -- a
  `PreToolUse` replayed moments before a restart outranked every newer
  truth until the presence horizon dropped the row outright. Precedence now
  only decides between observations of the same moment: a supplemental
  status must be at least as fresh as the projection it would outrank.
- The process registry's read side learned what the write side already
  knew. Shared-host providers record the host's pid, not the session's, so
  a leftover `devin acp` record made every historical Devin session look
  alive for as long as the host stayed up -- vetoing the silence timer on
  the status row and pointing "answer in terminal" at a process that owns
  no terminal. The record's own end is still session-level truth; liveness
  is left to the silence timer.
- Every `PostToolUse` carries a derived request identity so it can close
  the ask its own tool call opened, and most calls never had one -- but
  resolving a request nobody opened materialized a permanent tombstone. A
  long session accumulated the 1000-request cap of dead entries and every
  refresh and reduce paid to carry them. Unopened resolutions are now a
  no-op, and dead tombstones are filtered on write and on restore, with the
  works' request linkage re-derived from what survived.

## 0.8.0

- Usage history answers inside a reply budget. A cold Codex scan over
  5,541 rollouts takes 45 s and the app abandons a command after 10 s, so
  the Usage window showed nothing at all. The scan now runs on its own
  thread and the reply waits at most 2 s for it; past that the reply is
  what memory holds -- `pending: true` with empty rows, or the last
  document with `stale: true` -- and a new `usage_history_ready` event
  says when the fresh one has landed. The daemon warms both providers'
  30-day scans 8 s after start. Measured over the socket: first ask
  answers pending at 2.02 s, the event lands at 2.4 s, every later ask is
  under 10 ms; Claude answers inline at 1.3 s. A provider with a price
  table but no configured account (Gemini) now answers empty rows and its
  reference quote instead of `not_found`.
- Codex ran whole turns with JR-Bar seeing nothing whenever `CODEX_HOME`
  was reached through a symlink. Codex canonicalizes the config path
  before it looks up `hooks.state."<config>:<event>:…"`, so the
  unresolved spelling produced keys it never reads -- and it then runs no
  hook at all, silently. The trust writer resolves the path.
- Pi's `ui_prompt_start`/`ui_prompt_end` do not exist. 0.73.1's
  `ExtensionEvent` union has no such names; its tool gate, `tool_call`,
  asks an extension for `{block, reason}` rather than a person, so pi has
  no ask lane and `PermissionRequest` is gone from its event set.
  `before_agent_start`, not `turn_start`, is the prompt: `turn_start`
  fires once per model turn and re-announced the prompt after every tool
  result.
- A Codex `PermissionRequest` used to hold the session's own `SessionEnd`
  behind a timing quarantine: per-record diagnostics (no request id, no
  request capability, no request authority) were reported as the *source*
  losing freshness. A request identity is now derived from the turn and
  the exact tool call when the payload names no request.
- New: `scripts/mock_llm_server.py`, a stdlib-only OpenAI/Anthropic/Gemini
  endpoint that answers every turn the same way, and
  `scripts/verify_providers_live.py`, which drives Codex, pi and Claude
  Code through real turns against it in scratch homes and asserts what the
  daemon recorded. `docs/FINAL-TESTING.md` is rewritten around the five
  0.8 gates. The supported Python floor is 3.12.
- Usage history: the transcript scan keeps the newest files when a corpus
  is over the per-source cap (now 8,192, was 4,096) instead of the first
  in path order. `~/.codex/sessions` is date-partitioned, so the old rule
  dropped exactly the current days: 5,540 rollouts on the Mac left
  `usage_history codex 7d` at 0 records and `30d` nine days short.
  Codex records now carry the turn's model from the rollout's
  `turn_context` rows (`gpt-5.6-sol`, `gpt-5.4-mini`, …), so the price
  quote is the table row for that model rather than the config default or
  the reference estimate; the Codex scan cache is rebuilt once
  (`CODEX_CACHE_SEMANTICS_VERSION` 5).
- Core protocol: the Creator Micro 2 lives in the daemon. `state.deck`
  (device, 13 slots, 7 auxiliary controls, banks, rail, keymap,
  input check, last input, settings) is projected from the session board,
  `deck-controls.json`, `integrations.json`, a background HID probe and
  the keymap backup; the `deck_press`, `deck_pin`, `deck_bank`,
  `deck_rail`, `deck_clear_absent`, `deck_plan_keymap`, `deck_apply_keymap`,
  `deck_restore_keymap`, `deck_approve_device`, `deck_check_input` and
  `deck_set_settings` commands run the existing board, dispatch and
  keymap setup code (no NSAlert headless: the plan text goes to the app);
  `deck_input` and `deck_receipt` events carry the Python app's receipt
  sentences. New 0.8 rule: a session key whose session has a live ask
  answers it through `answer_ask` when the daemon confirms the session's
  terminal is frontmost, else reveals the session. The daemon now starts
  the optional integration runtime (Creator Micro output and deck input)
  as the menu-bar app did; `hello` advertises `deck`.
- Auto-dim replaces night warmth: the `auto_dim` setting (`off` by
  default, `schedule`, `display`, `ambient`) feeds `brightness_policy`'s
  `night_dim` stage; ambient mode reads the light sensor through IOKit's
  HID event system and falls back to the display when there is none.
  `lights.auto_dim` reports `{mode, source, factor, available, reading}`
  and `why_detail.dimming` says `auto_dim`.
- Core protocol: `state.sessions[].label` is human (the provider's own
  session title, else the derived project/prompt name, else the working
  directory, else provider + short id; workers hang off their parent),
  with new `short_id` and `cwd`; `lights.surfaces.*.why` is the documented
  enum (`idle`, `working`, `waiting`, `completed`, `failed`, `capacity`,
  `quiet`, `sleep_dim`, `idle_dim`, `battery`, `calendar`, `reminder`,
  `escalation`, `preview`, `studio`, `unknown`) with `why_detail`;
  `usage.providers[].windows[].name` is `5h` / `7d` / `Daily` / `Weekly` /
  `Monthly` / `Credits`.
- A volume named `PulseDot` (first-batch Dot firmware) is a 2-LED SidePulse
  Dot with a stable identity, not an 8-LED strip.
- Pro + Dot linked mode: the new `devices_linked` setting (default on)
  writes both devices in one hardware worker command from the same
  presentation and anchor; `lights.devices_linked` and `linked_skew_ms`
  report it.
- Link mode gets honest: two mechanisms shared the word and neither told
  the truth about itself. The linked Dot used to replay an unplugged
  strip's last program forever — the inventory change now forgets it and
  the Dot falls through to its own display. With two strips the Dot
  follows the first in inventory order, the one `lights` calls
  `hardware`, and the second strip's writes no longer overwrite the
  program it loops. The Dot's surface carries the strip's anchor only
  after a coupled write actually landed, a failed linked write surfaces
  as `dot_link.state: "failed"` with its error class, and the new
  `lights.dot_link` object says which of `off`, `no_dot`, `no_strip`,
  `beacon`, `solo`, `linked` or `failed` applies, with `linked_skew_at`
  timestamping every `linked_skew_ms`. `state.devices[].linked` stops
  repeating the Screen Bar's setting on every row: the bar reports
  `link_screen_bar_to_hardware`, the pair reports whether a Pro and a Dot
  are actually joined. The Screen Bar's own link gains
  `screen_bar_phase_offset_ms` (±1 s, default 0) to nudge the bar against
  the strip, and the app reads all of it: the Dot's readout says
  "Nothing to extend" or names the failed write, a link glyph sits
  between the panel's Pro and Dot chips, and the two links are never
  conflated in copy again.
- Calibration is a guided sheet now, and its preview finally tells the
  truth. The old preview multiplied the working gains into the patch hex
  and then ran it through `preview_program`, which applied the STORED
  gains through the strip transfer on top -- at the owner's real G=0.38 a
  previewed white drove green at ~12 while the applied profile drove 97.
  The new `preview_calibration` command takes the nominal patch plus the
  working gains, resting glow and brightness and puts them through the
  same write boundary live output uses, once, and `end_calibration_preview`
  hands the device back to the live program; the hold is daemon-side
  (600 s, re-armed on every change) so the sheet's debounced edits no
  longer flash three-second previews. Brightness is part of the profile
  (`apply_calibration` accepts `brightness`, and a device dimmed by
  calibration stops reading "Uncalibrated"), a Dot can light its strip
  beside it with `companion: true` so the two can be matched by eye, the
  Screen Bar calibrates through its own code-domain transform on
  `virtual:status-bar`, and battery display mode now runs the same strip
  transfer the agent path does instead of a code-domain multiply that
  rendered every colour differently. Fixes along the way:
  `with_device_resting_glow` used to drop the glow when the device had no
  settings row yet, and a malformed calibration number answers
  `invalid_args` instead of leaking a ValueError.
- The panel now says when a quiet is in effect, and says it truthfully:
  `state.focus` carries `mode` (`pause`, `dim`, `mute`, `dark`,
  `asks_only`, or the literal `off` -- never null), `source`
  (`override` for the panel's own Quiet menu, `schedule`, `focus` for a
  macOS or named Focus) and `until` (when this quiet ends; null when
  none is in effect). The footer reads "Paused · 42m" in the waiting
  amber, a `moon.zzz` glyph sits in the header, and "End quiet" exists
  only while the quiet is the panel's own override -- a schedule's quiet
  is not this menu's to cancel. The Quiet menu's presets run in the
  chosen mode ("Until 08:00 tomorrow" names the real clock time rather
  than promising a guessed 12 h). Session rows gain a context menu --
  open in the session's own terminal, snooze the family for 15 minutes /
  an hour / until tomorrow (or Unsnooze; `sessions[].snoozed_until`
  carries the family mailbox's expiry so the row knows), copy or reveal
  the working directory, and Clear for finished, ended and stale rows --
  and the full path is the row's tooltip. ⌘↩ and ⌘D answer the selected
  ask card once, at the panel level, instead of once per row.
- Settings stops lying about usage. "Show tips" is gone (no tip UI
  exists); the Usage page's provider list is now honestly labelled "Menu
  bar meters"; "Lead with" and "Graph range" are `usage_display_mode`
  and `usage_graph_days` for real -- the Usage Center's toolbar writes
  the same keys through `set_setting` instead of a private UserDefaults
  copy, and the panel's sparklines follow the configured range (a week,
  or a month when the range is longer). A stored "percent" metric reads
  as tokens rather than rendering nothing, and the nonexistent "Today"
  range is gone from the picker. Provider colours set in Settings ›
  Lighting (`colors.agent_colors.*`) now reach the panel's rows and
  sparklines, the Usage Center's tiles and rings, History's tiles and
  filter chips, and the menu-bar meter columns.
- New providers: pi (`jrbar agent-monitor install pi` writes
  `~/.pi/agent/extensions/jrbar.ts`) and Gemini CLI (`install gemini` adds
  hooks to `~/.gemini/settings.json`), both with transcript fallbacks
  (`transcript_monitoring.pi` / `.gemini`), lifecycle rules, colours that
  survive dichromacy, and fixtures. The shim prints `{}` for Gemini (and
  with `--emit-empty-json`); the hook doctor reads folded YAML, embedded
  argv arrays and the Antigravity envelope; OpenClaw and OpenCode accept
  the shim argv; `scripts/install-agents.sh` re-points every provider at
  the installed shim.

- Rename the software from SidePulse to JR-Bar. The Python package is `jrbar`
  (`sidepulse.*` imports and `python -m sidepulse.hook_client` keep working
  through a one-release shim), the CLI is `jrbar` (`sidepulse` stays as an
  alias for one release), the app is `JR-Bar.app` / `com.jonathanreed.jrbar`,
  the LaunchAgents are `com.jonathanreed.jrbar.app` and
  `com.jonathanreed.jrbar.sdejectguard`, config/state/data live flat under
  `~/.config/jrbar`, `~/.local/state/jrbar` and `~/.local/share/jrbar`,
  environment variables are `JRBAR_*` (the `SIDEPULSE_*` names are read as a
  fallback), provider Keychain items move to `com.jonathanreed.jrbar.provider.*`
  with copy-forward on read, and every provider hook installer replaces its
  pre-rename registration instead of duplicating it. First launch and
  `jrbar setup` copy an existing SidePulse install forward automatically;
  the hardware names (SidePulse Pro, SidePulse Dot) are unchanged.

- Remove night warmth and the 7 PM–7 AM night dim (the Night Warmth card,
  `NIGHT_WARMTH_GAINS`, and the `night_warmth_enabled` / `night_dim_fraction`
  settings, ignored on load). `brightness_policy` keeps its `night_factor`
  input, fed 1.0 until a time/ambient-light auto-dim replaces it.
- Remove the operator history/diagnostics JSON export (`operator_export`, the
  Local Export card and its two buttons). Operator history itself stays.
- Remove the timebox/timer: the Timer menu, presets, Focus-handshake
  Shortcuts, the "Working timer fill" device display and its
  `timer_fill_program`, the timebox webhook event and chime, and the
  `timer_expected_minutes` / `timebox_shortcuts` settings (ignored on load).
- Remove severe-weather alerts: the NWS/ipapi fetchers, the weather signal,
  style card, Today row, webhook event, demo scenario, and settings. Old
  `weather_*` settings keys are ignored on load. `QUIET_HOUR_EXEMPT_KINDS`
  is now empty.
- Remove the `sidepulse-waybar` client and its console script; `sidepulse serve`
  keeps the loopback status API.
- Remove the external Agent Deck snapshot compatibility (`agent_deck_compat`,
  the `agent-deck` integration, and its ownership yield). The built-in deck
  modules remain as the Creator Micro Control Center.
- Remove the iOS companion app and its Mac half: the `sidepulse glance`
  private listener, `serve --phone-glance`, and the `/glance.json` route.
- Consolidate historical feature/fix branch ancestry without overwriting newer
  implementations; preserve the unmerged historical plan under `docs/archive/`.
- Fix overlapping session-board saves, drain persistence on shutdown and persist
  compact-rail edge selection with backwards-compatible board settings migration.
- Fence bank changes and virtual-input confirmation against stale queued actions;
  refuse new input during termination and reap terminated Shortcut subprocesses.
- Require pending keymap recovery to resolve before a new apply; verify an intact
  original without writing it again.
- Add `make final-test` for clean-checkout, pinned Mac source/package verification
  with local logs, exact source identity and JUnit output; repair portable fixtures
  and include control-center regressions in the ordinary gates.

- Add a hardware-optional native Control Center with stable, identity-scoped
  session slots, explicit banks/pins, input checking and a compact four-edge rail.
- Complete the reviewed HID framing/nonblocking/write-result fixes; classify
  method-tagged firmware errors and retain Python 3.10 Creator Micro imports.
- Add bounded binary keymap reads/writes, device checksums, scratch-file preflight,
  private first-original backup and generation-bound interrupted-write recovery.
- Add selected profile/layer and supported auxiliary-key previews, analog joystick
  sectors, mapping import/export, per-session lighting and stock-map aggregate preview.
- Keep distinct user inputs in a bounded ordered queue, revoke stale generations,
  and expose explicit named macOS Shortcuts without a shell/device execution channel.
- Refresh T3 read-only projection compatibility, keep native and T3 identities
  distinct, and require explicit turn outcomes instead of treating idle as success.
- Portable regression checks do not certify native hardware or a release. Required
  final Mac/device/provider/release checks are in `docs/FINAL-TESTING.md`.

## 0.6.0

- JR-Bar now presents provider attention, activity, authoritative quota limits,
  account aliases, privacy-safe menu rows, reset delivery receipts, and local
  usage heatmaps through one command-center model. T3 Code and Agent Deck
  compatibility are read-only. Creator Micro 2 output uses an approved-device
  identity boundary and yields device ownership to Agent Deck when configured.
  Provider exhaustion can release a stale keep-awake claim without pretending
  that the agent process stopped.
- Screen Bar glow layers now use native Core Graphics gradients instead of
  hundreds of Python-to-Quartz rectangle fills per frame. Continuous ambient
  sampling uses the same bounded cadence as the display surface while finite
  alerts keep their responsive cadence.
- macOS packaging now delegates PKG assembly to an executable, testable
  standard-library seam with fixed production tool paths, explicit missing-tool
  failures, signed and unsigned command coverage, and clear certificate-error
  reporting. The builder validates the full source/package/changelog version
  contract before work starts. The release gate rebuilds the exact wheel and
  source distribution in an empty staging directory, validates both with
  Twine, and binds them to the release evidence. Release checksums are generated
  atomically in deterministic root-relative order and publication refuses any
  asset changed after that evidence was written.
- Production bundles now embed digest-pinned Sparkle 2.9.6 with exact nested
  signing checks, a visible Software Update submenu, stable and beta channel
  selection, and consent-owned automatic checks. The release gate creates a
  supplemental ZIP from the notarized and stapled app, signs and verifies the
  appcast with the dedicated Keychain key, binds channel metadata and receipts
  to the exact candidate, rejects non-monotonic upgrades, and publishes the
  immutable version archive before changing the durable feed. No release or
  feed was published by this source work.
- `make fast` now provides a fail-fast ordinary-change gate over Ruff, real
  imports, lightweight contracts, tracked-file secret scanning, literal
  fixtures, 430 selected contract, fixture, and semantic tests, compilation,
  dependency and version
  policy, and diff hygiene. Full-suite, build, installed-app, hardware, signing,
  notarization, Instruments, and release evidence remain separate. The signed
  release source receipt now disables build and clean-install work so it cannot
  delete the exact candidate or evidence directory it is validating.
- Why Is It Doing That now includes a fixed Current light context section with
  the selected semantic and P1-P7 priority, oldest visible source age, bounded
  current finite-cue suppressions, Scene availability, global surface role,
  Focus/DND observation-policy-decision, Reduce Motion substitution, and
  source-labeled active-output timing. Screen Bar renderer callbacks and
  physical hardware-write latency remain distinct, unavailable values stay
  explicit, and live refresh preserves selection and scroll position without
  retaining prompts, transcripts, identifiers, or a second telemetry store.
- Native notification access now fails closed outside the sealed application
  bundle. Authorization refresh constructs its bridge on the main thread, so
  source tests and unbundled Python processes cannot invoke Notification Center
  through an invalid application identity.
- The explanation panel now shows nine fixed, content-free health aggregates
  for the current run: render duty cycle, dropped batches, delivered FPS,
  runtime queue depth, physical write latency, source freshness, worker count,
  shutdown latency, and refresh duration. The projection reuses existing
  bounded in-memory owners, renders missing observations as unavailable, and
  is never persisted, exported, or sent to a cloud service.
- Power settings now separate the ordinary agent system hold, optional display
  assertion, battery continuation, and stronger closed-lid policy. Displays may
  sleep by default while agent work continues. Changing the display choice
  replaces only the stale `caffeinate` child and preserves battery, grace,
  helper, watchdog, and renewal state.
- Provider hooks now submit to one private, bounded, ordered app-owned ingress
  queue. Accepted work retains FIFO order through the canonical minimizer,
  dedupe, private write, and refresh path; overload and shutdown timeout produce
  content-free receipts; unavailable ingress falls back to the same synchronous
  processor. OpenCode and OpenClaw now await tracked client admission instead
  of detaching unobserved children. A reproducible source benchmark reports
  listener and fallback latency without retaining event content. App-owned
  refresh reconciliation completes inside the ordered worker, so normal shutdown
  does not persist latest state ahead of the accepted tail.
- Screen Bar prefetch now stays inside one generation, parsed program, and
  cadence. New commands and timing stalls discard stale frames immediately,
  finite cues stop requesting frames beyond their visual deadline, and local
  profile counters separate shortened or invalidated work from renderer
  fallback.
- Usage Center, usage-menu, and settings-summary repaints now consume one
  immutable worker-produced state and settings payload. Cross-Mac merge evidence
  is refreshed before AppKit dispatch and reused by logical snapshot value, so
  steady-state UI refresh no longer reads provider settings, Keychain
  credentials, or cached packet files.
- Usage-percent, provider-reset, operator-history, and capacity-history writes
  now share one bounded serial persistence owner. Ordered appends advance their
  watermarks only after a successful receipt, replaceable snapshots keep FIFO
  position honest, capacity consent deletion fences stale queued flushes, and
  normal shutdown reserves one final tail slot before draining accepted work.
- Physical LED writes now coalesce by opaque semantic slot instead of replacing
  every pending command for a device. Asks, failures, finite cues, and explicit
  calibration previews outrank obsolete ambient frames while the latest normal
  state remains queued as the trailing edge. Saturation evicts lower-priority
  work, selected display kinds are snapshotted before worker dispatch, and lid
  flourishes refuse to race a writer that cannot become idle.

## 0.5.0 — Coalescence

The name is **JR-Bar** now (display-name-first; bundle ids stay `io.sidepulse`). Fully divergent from upstream by decision, not drift.

### One system, ~12,000 fewer lines

- Seven audit lanes reported; everything they proved dead is gone in ratchet-safe order: the delivery-planning plane nothing ever invoked (planner, quiet plane, delivery ledger — the canonical-runtime fixture is honestly ten steps now), `runtime_truth` (the KNOWN_UNWIRED ledger reached its goal state: empty), the runtime-install transaction, the quota-forecast plane (owner sign-off; the JR-plane quota runway already answered its question), the replaced Screen Bar draw bodies, the no-op status-audit plane (its residue file is janitor-cleaned from installs), the mailbox v1 writer + migration resolver (store-security tests ported to the v2 API, which proved *stricter* under a parent-swap attack), the pre-mailbox session-menu formatting cluster, the dead `sync_leds_now` render ladder (its tests now drive the live request/worker pipeline and came out stronger), AgentLayoutStabilizer, DeferredMenuPublication, and ~23 leaf orphans whose live claims became test-local oracles.
- The settings_window injection ratchet's retired-branch was a tautology; it bites now, and the injected-name set shrank 60 → 30 (every name importable without a cycle is a real import).
- The two capacity planes stopped double-polling Claude's endpoint (the 429 mechanism); the JR plane owns capacity and the usage menu row outright.

### Wired, not shelved (owner calls)

- **Snooze Until Tomorrow means tomorrow morning** — 9 AM local via the store's timezone-correct resolver, not a flat 86,400 s that missed the morning and drifted across DST.
- **Triage acknowledgements prune** on terminal request truth; the store previously never shrank.
- **Hook registration probe-runs the command before writing it** — a hook that cannot run never reaches an agent config (the failure mode was every prompt in every session blocked).
- **The Agent Browser answers its keyboard**: Return opens, Escape closes, ⌘F finds, arrows move.
- **A hidden main menu** makes ⌘C/⌘V/⌘W/⌘Z/⌘Q work in every window the app owns.

### Native feel

- The dropdown stops rebuilding on a timer: the 30-second signature valve (a measured 799 ms average AppKit rebuild, forever) is deleted; identical content now hashes identically across time, pinned by test.
- The legacy usage card is never built-and-discarded per rebuild.
- Polls, EventKit fetches, and 30 fps settings previews defer past scroll gestures (default run-loop mode); the lights' own deadlines deliberately stay live mid-scroll.
- Settings panes crossfade and their cards cascade in (20 ms stagger, layer transforms only; Reduce Motion keeps the plain fade).

### The Apple-magic layer (motion language, measured from Apple's own work)

- **Idle breathes like a Mac asleep**: the asymmetric human-rate curve (inhale 1.9 s, exhale 2.55 s, dark dwell 850 ms, ~11/min — patent US6658577B2's rate, the measured MacBook curve's shape) replaces the 6 s symmetric pulse; the solo breathe drops from an anxious 18.75/min to the same curve.
- **Urgency arrives as one overshoot-and-settle crest** (swell 300 ms, settle to a 55% hold, anchor stands up) — never two square taps, never a repeated flash.
- **Done crests**: the completion bloom overshoots to 112% luminance once before basking.
- **Plug-in says hello in mint** (rise LED-by-LED, one crest, then the steady fill) and **device connect plays first light** (one soft white breath, then identity). INIT.LED remains the user's own power-up look.
- **The announcer pill arrives on a spring** from its top anchor and fades out faster than it faded in; Reduce Motion keeps the instant show.
- **The refill tells its story**: reset celebrations are the refilled provider's own color rising like a gauge, one white crest, two sparkles — not generic confetti.

### Flows

- **Calibration is a guided stepper**: "Does the light look white to you?" with one-tap Too warm / Looks white / Too cool nudges; fine RGB sliders hide behind Fine-tune; Compare-with-before is one button.
- **The Studio builds without typing**: rows of color wells, duration dials, and feels compile live into the editor through the same validator, persist, firmware parse, and preview. The DSL is an output format now.

### Docs

- FEATURE-MATRIX rewritten from live source (Kiro restored, a 0.3.0-dead bridge row removed); five stale plan documents archived; README renamed and corrected (no Gemini, no notification DB, honest install story); the Signal API plan retired.

### Deliberately deferred, with designs on file

Async settings saves (88 call sites need a debounce plus termination flush), the Screen Bar's ask-swell geometry spring and the 100 ms screen→strip event ripple, VoiceOver row descriptions (needs a view-based table first), and a real consent gate for the activity ledger (its old toggle was a lie and is gone).


## 0.4.0

### Owner decisions, implemented (audit wave 3)

- **Motions are real everywhere.** Cycle turns render each agent's chosen rhythm on the whole strip (byte-budget aware — agents degrade from the end back to the classic breath only when the firmware's 512-byte cap demands it; Automatic keeps Cycle's classic breath exactly). Spatial Split blocks honor the full vocabulary with intra-block travel (converge fronts meet mid-block). In shared strips the positional classes are finally distinguishable — narrow flare (scanner/KITT/comet/marquee/gradient) vs full swell (chase/tide/converge) vs hard pile-on (stack) — and aurora is no longer byte-identical to drift. Relay's collapse is physics (a ~350 ms flare can't hold a lub-dub under the 2 Hz law) and the motion descriptions now say what actually happens.
- **What you preview is what plays.** Thumbnails, hover try-outs, and the hardware preview push all route through the real solo renderer — hovering Knight Rider plays the KITT eye, not a generic roll.
- **Solo honors your gentleness sliders** (fade floor/ceiling), so one working agent is no brighter than the same agent in a crowd; the motion picker still outranks the classic style. **Urgent states keep a guaranteed minimum swing** — an Ask can never become an unblinking steady light, whatever the sliders say.
- **Quota Runway lives**: the LED display is selectable again and fed from the JR usage plane's own gated lanes (worst remaining lane, provider-colored) — the same numbers the menu meters trust.
- **Honest economics**: Fable 5 priced at its published $10/$50 rates, Codex priced from its GPT models (post-Aug-22 Sol cut), and every dollar figure discloses "NN% of tokens priced" whenever coverage is partial.
- **Cross-Mac sync reaches the Usage Center** ("N tokens across synced Macs" renders from locally cached, signature-verified peer documents — never a network fetch in the window path), replay gets a 7-day freshness window, and the docs stop claiming encryption: packets are HMAC-SHA256-signed JSON riding SSH.
- **Snooze means quiet**: a snoozed session stops claiming the LEDs and stops notifying; a genuine ask still breaks through everywhere, and the Agent Browser deliberately keeps showing everything.

### The test suite keeps its hands off the desktop

- Running the tests used to make the machine unusable: AppKit tests exercised product paths calling `makeKeyAndOrderFront_` / `activateIgnoringOtherApps_(True)`, yanking focus from the owner repeatedly for the whole run. Two independent fixes: conftest sets the PROHIBITED activation policy at import time (macOS itself refuses to ever activate the test process), and all twelve window-presentation sites now route through one gate (`window_presentation.py`) that no-ops in the test sandbox. A source ratchet fails the build if anyone writes a direct takeover call again; tests that verify presentation behavior opt back in against mock windows.

### Reset confetti & the alert layer, resurrected (feature audit wave 2)

- A refilled rate limit finally celebrates: multicolor confetti sweeps the bar (finite, safety-compiled, self-terminating on the device) plus one 🎉 notification per event — gated by the courtesy budget, deliberately NOT by the alerts switch. Detection now also fires on a ≥50-point replenishment jump, so a failed poll re-stamping the clocks can no longer hide a reset (exactly how today's live reset went unseen).
- `quota_alerts_enabled` was hard-wired False in three places with no switch, and four alert features routed their only surface through it — reset blink, pace notifications, threshold effects, connection cues. The flag is real now, with a switch in Settings → Extras; pace alerts and the quota blink work for the first time. The legacy raw-percent tracker stays a stub: effects fire on the JR plane's own snapshot transitions, never raw percentages.
- Connection-loss cues actually render (a brief amber notice blink via the notification program that shipped with no claim), and losses hidden inside stale-served snapshots are now detected.
- The sessions chart covers the whole fleet: grok, devin, and every hook-emitting provider chart their per-day sessions from the agent-monitor ledgers alongside Claude/Codex transcripts. "Percent left" mode survives restart, provider selections persist beyond the old two-provider filter, and days before history began render as gaps instead of a fabricated flat line.
- Edge detectors can no longer be blinded by a refresh tick landing mid-apply (resets, thresholds, pace, hooks, and connection losses all diffed against a baseline only the apply path owns).
- Screen Bar: the sampler's hard-coded alpha made dark LEDs opaque black — killing the min-glow floor, the identity collapse, and painting a ~92%-opaque black band on notchless displays; alpha now carries "how lit." The bar also no longer re-runs its full show/reposition dance on every tick while the display sleeps.
- Firmware-reboot detection had never fired in the shipped app (it read `LEDS.LED/STATUS.TXT`); the timebox chime could never play (courtesy grants hard-coded silent); the stage-3 escalation webhook never fired at the default tier (the tier capped the stage before the check); the Studio silently lost typed-but-unpreviewed programs and captures; the Usage pane's status line imported a function that didn't exist; the Devices pane stopped rebuilding on hot-plug under the category navigation; Cursor's reconnect loop could never succeed (stale app-database token always outranked the freshly pasted one); antigravity and openai-api action buttons did nothing; devin's daily lane could hit 0% with no pace verdict possible. All fixed, plus a batch of settings controls that went stale after external changes.

### Reconnect that tells the truth

- Automatic recovery: a signed-out provider stops being re-asked every two minutes and instead watches its own credential file (`~/.grok/auth.json`, `~/.codex/auth.json`, `~/.claude/.credentials.json`) — the moment `grok login` (or any sign-in) rewrites it, the next refresh retries immediately. Transient failures ride an exponential ladder (5 min → 1 h) instead of hammering; a 429 from the Claude usage endpoint now backs off instead of guaranteeing the next 429.
- Reconnect Grok actually probes: it reads the CLI's auth file, clears the stored-token wedge that could shadow it forever, and reports what it found — including "already signed in as you" when the old button would have said `run grok login` to a signed-in user.
- Connect Claude can no longer claim success with a dead token: expiry and the signed-out-with-refresh-token shape are checked before "connected" is allowed, and each failure names its fix.
- Codex gets a real action: the honest report of the newest completed session's age, with the instruction that a turn must *finish* (opening and quitting Codex writes nothing). Stale copy now says "finish one Codex prompt to refresh." A scan that finds no quota evidence no longer silently erases the last real reading.
- Every reconnect message lands somewhere visible by construction — the Usage Center opens with the banner already set; nothing answers into the void. A user-forced refresh no longer piggybacks on an in-flight run that read the old credential. A provider dropping from healthy earns one attention cue through the normal interrupt gates.

### Effects

- Four new motions, all sourced: **Knight Rider** (upstream PR #29's KITT eye — wide overlapping pulses sweeping out and back), **Gradient** (tlip's rolling wave where each LED carries its own shade), **Marquee** (a palette seeded from the provider color, rotated by the firmware's own roll), and **Duotone** (the iOS pattern library's two-tone breathe). All pass the safety compiler and the real firmware grammar on 2- and 8-LED builds.
- Settings thumbnails no longer preview every travelling shape as a plain pulse: the motion→style bridge now covers the whole vocabulary, so scanner/comet/KITT-class motions read as motion in the aggregate renderer too.

### Ambient

- Charging trickle while idle (on by default, one switch in Battery settings): plugged in with nothing running, the bar fills to the charge level in mint with the wattage-paced trickle pulse — and running, asking, freshly-done, or failed agents always take the strip back. Dims like furniture with the ambient stack instead of flashing at signal brightness. Pulse length is bucketed so adapter-wattage jitter no longer rewrites the device's flash every refresh tick.
- The bar stays alive with the lid closed: hardware writes are no longer gated on display sleep (the strip is an external light on the side of the machine), and lid observation no longer stops at exactly the moment the lid closes.
- Night brightness: an optional 7 PM–7 AM dim (50/30/15%) beside Night Warmth, composed into the same stack as idle and Focus dimming; escalation ramps still push through.
- A Sleep Focus with no explicit rule now defaults to near-off instead of the shared dim.

### Studio

- Typing lag: validation is debounced to one parse per pause instead of one per keystroke, and the per-keystroke device enumeration behind the LED-count check is cached.

### Overview chart & app-wide lag (post-deploy audit)

- The Overview usage chart no longer shows "No activity in this range" while it is actually scanning: the view is seeded with a real "Scanning local activity…" state (the worker's placeholder could never reach a freshly built pane — settings_fields is assigned only after the builder returns), a range change mid-scan is remembered and re-fired instead of silently dropped, and identical inputs within a minute are served from memory instead of re-paying the scan.
- The transcript scan thread (30 s cold, ~9 s warm for a year of history — six figures of JSONL lines, pure GIL time) now runs at utility QoS like the Screen Bar sampler, so the whole app stops feeling laggy while the chart loads. First test coverage for the worker.
- Claude's usage fetch timeout drops 30 s → 10 s: the one live hang left "Last known value" on screen for half a minute after Reconnect had already said "refreshing now".
- Stale lanes whose reset moment has passed say "reset passed — reading is older" instead of chanting "resetting now" forever.

### Hostile-review fixes (same audit)

- The charging trickle no longer hijacks devices pinned to Studio, Timer, Battery, or Quota Runway, and yields to a running timebox: the claim moved to dead last before the agent default and only fires on default-display devices.
- A forced refresh landing while the worker was delivering callbacks was silently swallowed, with its flags leaking into a spurious forced run minutes later — the worker now retires under the lock, so a mid-delivery click starts a fresh run.
- Clicking a non-connect Claude action ("Retry later") no longer runs the synchronous Keychain read on the main thread — only Connect/Reconnect clicks do. The Usage Center's fallback refresh is scoped to the clicked provider instead of force-marching the whole fleet through their backoff gates.
- Marquee's loop repaint carries explicit timing, so the safety compiler no longer stamps a freeze-snap hold into "endlessly rotating."
- Re-enabling a disabled provider probes fresh instead of serving its pre-disable failure for up to an hour; device inventory keeps running while the display sleeps (writes without re-enumeration raced devices that unmount during the sleep transition); the "show battery on plug/unplug" toggle got back the immediate refresh an edit splice had orphaned; the night-dim popup re-syncs on settings refresh.

## 0.3.0

### Truth model

- ACTIVE means heard from: a session silent past 240 seconds leaves the title, mailbox, lights, and rows together, and reappears on its next real event.
- Done is a moment: a completed session settles from the done green back to the idle whisper after 120 seconds instead of holding it until the presence horizon dropped the row.
- Sleep-aware clock continuity (naps are continuous; only backwards motion quarantines), boot identity from kern.boottime, live-source-elected global continuity, and per-source clock timing that round-trips through the v2 snapshot with healing for documents from the broken window.

### Screen Bar

- Classic mode is contained: opaque black housing traced from the measured per-row notch silhouette, glow feathered to housing-black before the corner fillets, rim clipped to the body, standing gauges tucked inside — nothing paints on the menu bar's own background. Wings remain the Alcove bracket's language.
- Bar and strip share one clock: the bar re-anchors to the hardware write moment, risers breathe on a six-second swell, and the strip runs the 1400 ms rolling pulse with 170 ms stagger.

### Usage

- Claude usage connects and reports real numbers (the OAuth parser now reads the endpoint's own utilization field), and the Usage Center window survives its own close button instead of crashing the app.
- Codebar-style limits: an eight-cell meter per rate-limit lane with percent left and reset countdown, amber past the provider's low-remaining threshold, in both the menu and the Usage Center.
- Menu curation: choose which elements each row shows and which providers get a row at all; the tightest visible limit rides next to the menu-bar icon on its own switch.
- Pace: every lane with a known window is judged against uniform spend — surplus, on pace, spending fast, or "runs out in ~2h 10m at this rate" when the projection lands before the reset. The menu-bar percent belongs to the provider actually running (lowest among several), on whichever window is most at risk, and turns amber when spending fast and red when it will not make the reset.

### Power

- Keep-awake holds the machine only while agents work, plus one five-minute grace window armed when work stops — rest-to-rest flapping can no longer re-arm it — and uses caffeinate -ims so the display sleeps normally.

### Ratifications and repairs (final-sweep audit)

- A failed tool call is non-terminal everywhere: the canonical adapter now agrees with the mode map and attention layer that PostToolUseFailure keeps the work ACTIVE (it filed live sessions under "ready for review").
- The dropdown's session dots and the completion celebration use provider-brand identity colors like every other surface — no more "purple for some reason when Claude's running" in the menu.
- Provider pins for every registered provider now survive relaunch (the loader silently dropped everything but claude/codex).
- Transcript replay no longer re-stamps unparseable rows with rebuild time; a bad row inherits its neighbor's stamp, seeded from the file's mtime, so stale accounting can age it out.
- The Screen Bar quota ember is real: with gauges enabled, the left tip brightens as the tightest visible lane sinks below its provider's threshold.

### Menu and platform

- "Remove Screen Bar" lives inside the Screen Bar's own submenu; only "Add Screen Bar" appears at the top level, and only while there is none.
- Global brightness control (Dim/Half/Full) for both surfaces from the menu bar.
- Builds install the wheel with --no-cache-dir so a rebuild can never silently ship a stale wheel cached under the same version.
- The test harness pins Focus state, Low Power Mode, and render environment so the gate no longer depends on the machine's battery or Do Not Disturb.

### Runtime truth and safety

- Added explicit states for not configured, reload required, awaiting first activity, idle, working, needs input, completed, failed, and stale hook sources.
- Kept `SessionStart` as session presence rather than working activity, and added specific Grok guidance when hooks were installed after the current session began.
- Added cross-process hook-event deduplication so repeated native events are written and published once.
- Separated foreground, LaunchAgent, socket-owner, and conflict process states.
- Established collection-time test isolation for HOME, XDG paths, launchd mutations, and real `/Volumes` writes.
- Collapsed the public status-bar facade so only one PyObjC controller subclass remains.

### Devices and menu

- Replaced mount-path identity with a stable hardware key derived from a hashed serial, volume UUID, or disk identifier.
- Added bounded background `diskutil` inventory so AppKit reads only cached device metadata.
- Merge remounts, prune temporary and duplicate remembered devices, and preserve device-specific brightness, calibration, provider pins, and resting glow.
- Normalized product labels so a SidePulse Dot can never become “SidePulse Dot Dot.”
- Grouped physical devices, profiles, and timers under one compact Devices submenu.
- Wrapped provider capacity under one Usage row, removed the permanent Tip row, renamed the explanation panel to Diagnostics, and hide Setup after a healthy completed setup.
- Added bounded actionable warning rows for disconnected or silent agent intake.

### Native provider usage

- Added first-party accounting for ChatGPT/Codex, Claude, Cursor, Devin, Grok, Antigravity, and optional OpenAI API organization usage.
- Added actionable source-health states, explicit provider setup and refresh commands, dynamic model- and feature-scoped quota lanes, exact reset countdowns, and finite deduplicated reset celebrations.
- Added token and model counts, credits, incidents, estimated pricing, cache-savings estimates, and cross-Mac totals.
- Added provider-scoped browser consent and isolated browser-store import, with secrets stored in macOS Keychain.
- Added HMAC-signed (not encrypted; transport privacy comes from SSH/SFTP) cross-Mac usage sync that freshness-selects account quotas, rejects packets stamped outside a bounded replay window, and deduplicates machine-local usage events.
- Wired native usage into Finder launch, packaged and source-checkout LaunchAgents, foreground development mode, the menu, and Usage Center.

### Settings and Screen Bar

- Consolidated the Settings sidebar into Overview, Agents & Providers, Usage, Devices & Screen Bar, Appearance & Motion, Notifications & Focus, and Advanced & Diagnostics.
- Kept the tested retained panes as child pages rather than duplicating their controls or creating another controller layer.
- Added a native Usage page with direct Usage Center and refresh actions.
- Replaced the hairline/full-width Screen Bar treatments with a centered, rounded 6-point luminous band bounded to 180–420 points on wide surfaces.
- Kept connected-but-silent visible as a dim outline, preserved production animation colors, and made Alcove corner brackets an explicit style instead of an automatic side effect.
- Removed temporary repository write-probe documents and migrated retired CodexBar settings out of the integration document.

### Production hardening

- Moved routine battery collection, transcript discovery, provider probing, ledger publication, and webhook delivery behind bounded background services.
- Added typed refresh admission and in-process performance diagnostics while retaining the historical AppKit controller as a compatibility host.
- Added one presentation-safety compiler for visible LED output and exact final-byte validation through the packaged firmware parser before physical writes.
- Made device settings persistence lossless and settings documents versioned, downgrade-safe, concurrency-aware, and preserving of unknown fields.
- Added a payload-only macOS package transaction, inside-out signing checks, uninstall support, dependency constraints, SBOM generation, release manifests, and an authoritative signed macOS release gate.
- Added repository governance, dependency review, self-hosted macOS verification, and architecture ratchets that prevent the retained monoliths from growing.

### External compatibility

- T3 Code remains the only optional external agent integration. It reads a query-only local SQLite projection and does not mutate T3 or read its credentials.
- Alcove remains the optional visual geometry integration for Screen Bar following.
- Removed the accidental CodexBar client, process supervisor, dashboard protocol, commands, settings surface, compatibility entry, and package tests. CodexBar is now only an engineering reference for native SidePulse provider accounting.
- Kept T3 pull-request metadata and mutation actions explicitly out of current claims because the reviewed local projection does not expose them.

## 0.2.2

- Added the JR fork’s agent status, Screen Bar, signal, quota, history, device, and macOS integration work.
- Preserved the upstream SidePulse CLI, LED format, battery tools, and device behavior.
