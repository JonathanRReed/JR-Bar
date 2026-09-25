# Toy parity

The point of the native utilities is that Jonathan can uninstall the apps they
stand in for. So each native surface is measured against the app it replaces,
feature by feature. A surface is not "done" until every row for its rivals
reads **Done** or **Won't** with a reason. External providers stay in every
card regardless; parity is about making them optional, not removing them.

## Parity board (scope)

Paid to beat: Bartender 7 (incl. Pro / Top Shelf extras) · iBar · Barbee ·
DockDoor Pro · ActiveDock · DockMate · Sidebar · uBar · SwitchGlass ·
Witch (Many Tricks) · Contexts · Alcove (the gold standard) · NotchNook ·
DynamicLake Pro · TopNotch · MediaMate · Bendy · Mac Duo · Dropover · Yoink ·
Dropzone 4 · Dato · Fantastical · One Switch · BetterTouchTool · iStat Menus ·
Conductor (conductor.build) · Terragon-class dashboards · Govee Home ·
Nanoleaf · Philips Hue Sync · SignalRGB · Elgato Stream Deck ecosystem.

OSS to match: Ice (jordanbaird, GPL-3 clean-room) · Hidden Bar (dwarvesf) ·
Dozer (abandoned) · DockDoor Free (GPL-3) · AltTab (the ⌥⇥ reference —
"AltTab-style" is in our source comments) · boring.notch (TheBoredTeam —
the co-column in every Notch parity row) · Lid Plane (jh3y, GPL-3 clean-room) ·
MewNotch · Itsycal · OnlySwitch · macOS Control Center itself · Stats
(the iStat clone) · RunCat · CodexBar (steipete, MIT — the closest single
analogue) · ccusage · Crystal · Vibe Kanban · cmux · Claude Squad · Omnara ·
Happy · WLED · OpenRGB · Hyperion / HyperHDR · Prismatik (ambient screen-sync
lineage) · Bitfocus Companion · Touch Portal · OpenDeck · Pelmet / Thaw /
Barometer (macOS 27 mechanism docs) · Ice PR #995.

Inspirations (no direct counterpart): Insaniquarium (PopCap) · Tamagotchi ×
Shimeji × Desktop Goose × Apollo's Pixel Pals · Duolingo streaks × Raycast
confetti · After Dark (Berkeley Systems flying toasters) · Aerial (Apple TV
drone footage) · Obsidian graph view · Home Assistant automation trace ·
RunCat (living-meter instinct).

Lineage: SidePulse upstream (inteliwear, MIT — fork origin) → JR-Bar.
Studied and attributed in docs/PRIOR-ART.md: CodexBar · T3 Code · SidePulse
fleet fork (adamstambouli) · T3Notch (concept only, no license — nothing used) ·
Pelmet, Thaw, Barometer, Ice PR #995 (macOS 27 assessment-mode facts) ·
TinyCast (abue-ammar/tinycast — golden-example reference for overlapping
features, flagged by owner).

Sources: tryalcove.com (v1.7.x release notes), TheBoredTeam/boring.notch
README roadmap, dockdoor.net, pro.dockdoor.net + gumroad listing, trybendy.app,
jh3y/lid-plane, macduo.dhananjaytech.app. Full-board research pass 2026-09-17
(menu bar, dock/switcher, notch/HUD, fold/shelf/meters, agents/LED lanes —
official sites, READMEs, pricing pages linked per section). Started 2026-09-14;
refreshed 2026-09-18 (Hidden Bar 1.11.1, Bartender 7.0 + Golden Gate betas,
boring.notch v2.7, DockDoor 1.40/Pro 1.4x, Dropover 5.2.5, iStat 7.5,
NotchNook shutdown, and the Atoll/Notchy/NotchIA/SaneBar/Brow additions).
Nothing here is copied; DockDoor and Lid Plane are GPL-3, AltTab is GPL-3,
Ice/MewNotch/boring.notch are GPL-3, everything native is clean-room.

Labels: **Done** (shipped in the native surface, tested at its seam),
**Planned** (in scope, not yet built; the step that lands it), **Won't**
(out of scope, with the reason). Nothing else counts. Rival columns use
`yes` / `no` / `?` (unverified — needs a cited release note or README);
a `?` never blocks JR-Bar's own Done/Won't.

## Notch (vs Alcove, Boring Notch)

| Feature | Alcove | Boring Notch | JR-Bar Notch | Notes |
| --- | --- | --- | --- | --- |
| Notch-flush black island, hover to expand | yes | yes | Done | The island itself grows into the card, solid black and contiguous with the notch; Liquid Glass is fallback-only — the detached card under the band when the toy is off or an external provider owns the notch |
| Pill shape on notch-less displays | yes (1.7) | yes | Done | `Capsule` face |
| Simulated notch toggle on notch-less Macs | yes (1.7.1) | sizing options | Done | `ScreenBarGeometry.simulatedNotch` — the island hugs the top as a synthetic housing |
| Now Playing: artwork, title/artist, transport | yes | yes | Done | perl-hosted MediaRemote helper |
| Now Playing: waveform/visualizer | yes (iOS-matched) | yes | Done (opt-in) | `AudioLevelTap` — the public macOS 14.2+ process-tap pipeline (`CATapDescription` → `AudioHardwareCreateProcessTap` → private aggregate device → `AudioDeviceCreateIOProcID`), unmuted passthrough, process tap on the playing app's pid when it resolves else the global mixdown; six Goertzel bands at ~30 Hz with fast attack / ~250 ms release. `audioVisualizer` setting off by default (asks the system-audio consent once); denied or failed → the decorative bars stay |
| Now Playing: scrubbing, lyrics | yes / no | scrub yes + synced lyrics (beta, LRCLIB — v2.7) | Done (both) | Interpolated playhead + drag-to-seek through the MediaRemote `seek` verb; synced lyrics via LRCLIB `/api/get` → `/api/search` fallback (free, keyless — the same source boring.notch/Atoll/Notchy use), LRC-parsed, cached per track, quiet line on the media card |
| Audio format badge (Lossless/Atmos) | yes | no | Won't | Private API surface, low value |
| Charging / on battery / full capsule | yes | yes | Done | `AlcovePower` |
| Battery % in card | yes | yes | Done | |
| AirPods / Bluetooth connect capsule (with battery) | yes | roadmap | Done (name + battery %) | `IOBluetooth` watcher on a dedicated runloop thread — the CoreBluetooth handshake can never wedge launch again |
| Volume / brightness / keyboard-backlight HUD replacement | yes | yes | Done (volume, brightness, keyboard backlight + opt-in suppression) | `NX_SYSDEFINED` decode → CoreAudio / DisplayServices / CoreBrightness reads on a `.listenOnly` tap; Apple's HUD still shows too. `replaceSystemHUD` (off by default, needs Accessibility) rebuilds the tap as `.defaultTap`: volume/mute step 1/16 via the default output's scalar+mute, brightness via dlopen'd DisplayServices (nil-safe — no write, no swallow), keyboard illumination passes through (no reliable public setter), Option/Shift variants and failed writes all go back to the stream. Control-Center/Touch-Bar triggers still show Apple's overlay — suppressing those needs `killall -STOP OSDUIHelper` (Atoll's approach — unsanctioned; we won't) |
| Caps Lock indicator | yes | no | Done | `flagsChanged` on the global stream and our own windows — fires while a JR-Bar panel is key |
| Focus mode change capsule | yes | no | Done | `~/Library/DoNotDisturb/DB/Assertions.json` + the daemon's `focus_sync` |
| Display connect / disconnect capsule | yes | no | Done | `NSApplication.didChangeScreenParameters` |
| Screen recording indicator capsule | yes | no | Won't | Mechanism verified private: Atoll binds `CGSIsScreenWatcherPresent` + `CGSRegisterNotifyProc` (CGS events 1502/1503) via `@_silgen_name` — event-driven, no public equivalent (`SCWindow.isActive` is Stage Manager state, not capture). Gray-area fallback: poll `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsCaptured"]` — key-presence semantics confirmed live, but coverage of local SCK streams is unverified; we won't link private CGS for a capsule |
| Notification banners mirrored into the island | yes | yes (2.8, through Accessibility) | Won't | boring.notch 2.8 does it through Accessibility, so "needs private hooks" no longer holds. The reason now: it reads every other app's banners, and a surface that watches agents does not need to |
| Calendar: next event, join link | yes | yes | Done | EventKit, "Show calendar" grant |
| Reminders | no | yes | Done | EventKit, "Show reminders" grant; check-off writes back |
| Weather | yes | roadmap | Done | Open-Meteo keyless (no WeatherKit entitlement), off by default |
| Timers / Pomodoro | via Live Activities | no | Done (timers) | Hide row when empty (step 1) |
| Shelf / file drop with AirDrop | no (Drop in 1.6) | yes | Done (tray + stacks + AirDrop verb + QuickLook + ⌃⌥D summon + shake-to-summon + reorder) | `NSSharingService` AirDrop on the tray chip's menu; Quick Look via `QLPreviewPanel`; URL drops materialize `.webloc`s, text drops materialize `.txt`s; chips carry real file-type icons with Quick Look thumbnail upgrade and drag-to-reorder; drag-to-notch summon + global ⌃⌥D hotkey; swipe-up fold. Capacity 12→40; same-drop or same-folder files become a stack (fanned tile, grid popover, ⌥-click dissolve, Split/Merge menu, drop-onto-stack adds); `shelfShakeToSummon` (on by default) reads global drags for a ≥4-reversal shake in 600 ms at ≥30 pt and pulls the card open as a drop target. Gap kept honest: no multi-shelf |
| Mirror (camera preview) | no | yes | Done | `ShelfMirrorModel` — AVFoundation session on a private queue, consent asked on the toggle, lens closes when the card folds away; off by default |
| Swipe gestures on the island | yes | yes | Done | |
| Hover tell while bare | yes (ear swell) | peek | Done | The Screen Bar ear under the pointer swells outward — the wink the bare island could never draw |
| Hover-open delay: menu-bar drift vs direct | 0.3 s-ish | `minimumHoverDuration` 0.3 | Done (adjustable) | Open after (`hoverOpenDelay`, 0–1 s, default 0.12) sets the card's clock; an arrival from the bar row still waits a third of a second; ear→island keeps the original deadline. MewNotch's slider, boring.notch's minimum hover |
| Which display the island lives on | — | `showOnAllDisplays` / `automaticallySwitchDisplay` | Done | `notchDisplay`: Built-in, Main display, or Where the pointer is (re-seated on a Space or screen change only); the Screen Bar follows through `preferredScreen()` |
| Sound output picker | no | yes (2.8) | Done | The volume row's route button: every output device, the default checked; the pick sets `kAudioHardwarePropertyDefaultOutputDevice` (public HAL) |
| Adapter watts and time to empty | no | yes (2.8) | Done | The battery line names the charger's rating (`IOPSCopyExternalPowerAdapterDetails`); on battery it already gave `IOPSGetTimeRemainingEstimate` |
| A second island running beside ours | — | — | Done | A note under Render with (`UtilityRivals`, role notch): Alcove, Boring Notch, Atoll, MewNotch and more; Hand over to Alcove or Boring Notch, Quit on a click |
| Suppress hover-open under a fullscreen app | yes | no | Done | Frontmost app's presentation options; the wink still answers |
| Haptic on open | yes | no | Done | `NSHapticFeedbackManager` tick; Notch settings toggle |
| Ears as lobes of the notch | yes (wings drop below the bezel line) | ears | Done | Claimed ears widen one black tray, ear to ear, that ends flush with the bezel's bottom edge — no drop below the menu-bar line, where a black tab read as the notch grown downward (turned down 2026-09-16); the lit strip seated under the tray marks each wing's reach, and an unclaimed side ends at its own bezel edge |
| LED strip seated at the island's edge | — | — | Done | The band rides the island's live bottom edge — compact or grown card — instead of crossing its face at bezel depth |
| Lock-screen widgets / mode | yes | yes (v2.7 — notch on the lock screen; widgets still roadmap) | Won't | Mechanism verified private: both boring.notch and Atoll create a SkyLight space at absolute level 400 (`SLSSpaceCreate`/`SLSSpaceSetAbsoluteLevel` via `Lakr233/SkyLightWindow`) and move windows in on `com.apple.screenIsLocked` — private API end to end, no public space tier reaches the lock screen. The Won't stands |
| Duo mode (two islands) | yes (1.7) | no | Won't | Nothing in JR-Bar needs a second island |
| Agent sessions, asks, usage meters in the island | no | no | Done | No longer unique — Atoll, Notchy and NotchIA all ship Claude/Codex quota tracking in the notch (see New Rivals). The edge is breadth: asks with approve/deny, multi-provider forecast, aquarium, Screen Bar and the LED lanes — the others are meters, not surfaces |
| Screen Bar LED strip across the island | no | no | Done | |
| Menu bar icon hidden | Tahoe native | yes | Done | System setting, documented |
| Sound effects on capsule events | yes | yes | Done | `NotchSounds.tick` on HUD/capsule events; on by default, toggle in Notch settings |
| Localisation | partial | Crowdin | Won't for now | English only |

### Notch — additional rivals in scope

| Rival | Type | Coverage | Notes |
| --- | --- | --- | --- |
| NotchNook (lo.cafe) | **Dead — decommissioned as a parity target** | Covered by rows above | Vendor collapse 2026-09: lo.cafe down, Stripe suspended, Setapp removal 2026-09-22, vendor telling users not to buy; Tray + AirDrop, FaceTime Mirror, calendar widget were mature; sources: macmagazine.com.br 2026-09-16 |
| DynamicLake Pro (Avior) | Paid (~$14–17 one-time, Gumroad) | Covered by rows above | Liquid Glass island, FFT waveform, DynaConnect BT, volume/brightness HUD, push notifications + quick reply, DynaClip shelf + DynaDrop actions + AirDrop, timers; sources: dynamiclake.com, gumroad listing |
| TopNotch (MTW/CleanShot team) | Free | N/A — notch hider only | Blackens menu bar to camouflage notch; no island/HUD/calendar/shelf — not a parity target; source: topnotch.app |
| MewNotch (monuk7735, GPL-3) | OSS | Covered by HUD + shelf rows | Power + time-remaining, volume/brightness + HUD kill, adjustable hover delay, persistent shelf, mirror + corner radius, lock-screen padlock; sources: github.com/monuk7735/mew-notch |
| T3Notch (zortos293, no license) | Concept only | Not a parity target | Studied conceptually only per PRIOR-ART.md; nothing used |

## Fold (vs Bendy $4.99, Lid Plane GPL-3, Mac Duo free OSS)

Bendy (trybendy.app, $4.99 one-time, 3 Macs): hinge sensor, Silk/Shade/Frost, sliders, simulate drag, pause/Esc, click sound. Mac Duo (free, OSS — DhananjayBhosale/MacDuo): 6 effects (Duo/Ghost/Roll/Shutter/Flex/Iris), pause-at-angle 1–5 s, external safety, 60 fps Metal, Replay without Screen Recording. Lid Plane (jh3y, GPL-3): rigid plane + blur only, 110° activation. Sources: trybendy.app, mac-duo.com, github.com/jh3y/lid-plane.

| Feature | Bendy | Lid Plane | Mac Duo | JR-Bar Fold | Notes |
| --- | --- | --- | --- | --- | --- |
| Reads the hinge sensor | yes | yes | yes | Done | IOKit HID, 10/120 Hz |
| Duo-style fold | yes | blur only | yes (default) | Done | Two looks. **Duo** (default): one held picture (the exact front-view homography from a seated eye), blur and darkening in the picture's own rows away from the hinge, black void, no sheen or seam; Gaussian pyramid, B-spline read. **Room**: wallpaper far wall + per-window depth cards, Vogel blur, dissolve |
| Rigid held plane | yes | no | yes (Ghost) | Done | The Duo look is exactly this, at a seated eye; the Room's Perspective knob at the shallow end comes close |
| Alternate effects (Roll, Shutter, Flex, Iris) | 3 styles | 1 | 5 | Won't | The Duo is the one correct effect; the Room stays as the second look for anyone who liked it |
| Perspective / blur / shade sliders | yes | no | no | Done | Both looks; in the Duo Perspective is the eye's distance, plus "Goes dark over" (the fade length, 55 % = the Duo's half-closed) |
| Activation angle | yes | yes | yes | Done | |
| Movement anchor (fold starts wherever the lid rested) | no | no | yes (auto-anchor when still) | Done | The default (every older file moved to it; the set angle is kept for "Set angle"). `FoldAnchor.movement` + `MoveAnchor`: still ≥400 ms while flat re-seats; arms on first move (3° down in the Duo); delta 0 above the anchor; dwell re-seats |
| Hold picture in place (viewer compensation) | yes | no | yes (Ghost) | Done | `holdStrength` 0–100 % (default 100 %): 100 % keeps the desktop where a seated eye saw it, 0 % glues it to the lid, in both looks. The old switch read backwards (it sent Perspective, so "on" held less than "off"); files migrate on → 100 %, off → 0 % |
| 10 Hz sensor smoothing | ? | ? | spring / τ 35–45 ms | Done | Duo: `EdgeInterpolator` draws the lid one sensor period late between edges into an ω 40 tracker, the same ~150 ms latency with under 5 % speed ripple (was ±25 %) |
| Black across a full close, unfold from black | n/a | n/a | n/a (macTilt draws over the lock screen) | Done | Duo `FoldBlackout`: a flat black hold with capture stopped, 3 s watchdog, drops on sleep/lock/session; the reopen unfolds from the last all-black angle to the lid; never above the lock screen, no SkyLight |
| Retrace (same angle → same image) | ? | ? | yes (opening retraces closing) | Done | `DeltaChase` slew unwind at 3 rad/s outruns the tracker's 150°/s cap — a real opening is followed exactly; palindrome test |
| Simulate slider (no sensor) | drag | no | Replay | Done | |
| Pause-at-angle timeout (desktop returns after N s at rest) | no | no | yes (1–5 s) | Done | Off by default; a half-closed lid stops being useless |
| Return-to-normal click sound | yes (0.3) | no | no | Done | Off by default; `NotchSounds` tick on restore |
| Screen-capture indicator only while folding | yes (Screen Recording, on-device only) | n/a (minimal capture) | yes (privacy: frames in GPU only) | Done | Streams live only from the first real move off the resting angle (3° down in the Duo, so opening wider never records) or inside `FoldArming`'s band for a set angle (activation + 12°), with a 2 s linger |
| Capture at 60 fps | yes (Metal tilt) | n/a | yes (one Metal pass/frame) | Done | `minimumFrameInterval = 1/60`; the Duo runs one stream (no far wall, no window-list poll) and keeps JR-Bar's own menu-bar windows so the whole bar folds |
| External display / mirrored safety | yes | graceful failure | yes (external left alone) | Done | |
| Reduce Motion honoured | ? (not documented) | n/a | ? (not documented) | Done | |
| Menu bar pause / Esc | yes (click or Esc) | n/a | n/a (Replay instead) | Won't | JR-Bar's card toggle is the pause |

## Dock (vs DockDoor Free, DockDoor Pro)

One mode. **Enhance** keeps Apple's Dock and measures against DockDoor
Free. The Replace bar (our own dock over a hidden Apple Dock, measured
against Pro) was cut on 2026-09-15: a replacement dock has to get minimize
animation, drag-to-dock, Exposé and Stage Manager right before it is a
daily driver, and each of those is weeks — one dock done well beats two
done halfway. `AppleDockControl.restore()` survives so a Mac the bar left
with Apple's Dock hidden gets it back.

### Enhance mode (vs DockDoor Free)

| Feature | DockDoor Free | JR-Bar Dock | Notes |
| --- | --- | --- | --- |
| Hover a Dock icon → live window previews | yes | Done | AX hit-test of the Dock's `AXList`, `SCScreenshotManager` one-shots per window — no stream; each fresh capture pulses the recording indicator once, cached 30 s, but the card under the pointer is re-taken once its still is 5 s old or predates its agent's current state; opt-in live card (one `SCStream` on the pointed-at window, 8 fps, recording dot on while it plays); captures alpha-trimmed to content so a purged margin can't drift the image off-centre; the open card list follows the app (`AXObserver`: new, closed, retitled, minimized windows); `AXStatusLabel` unread badges on the header icon and a right-click verb menu (Raise / Raise, Keep Preview / Minimize / Full Screen / Tile To halves+quarters+Center+Fill / Move To another display / Close); ⌥-click keeps the preview up |
| What opens a preview | yes (Hover, Middle-Click, Modifier-Click) | Done | Hover, hover with ⌥ held, or middle-click the icon (Apple's Dock ignores that button); opt-in scroll up on an icon previews at once, scroll down hides the app; opt-in ⌥` previews the front app from its tile with the next window walked — the keyboard walk with no pointer |
| Agent-aware previews | n/a | Done (native) | `DockAgentMatch` marks the card whose window exclusively hosts a Claude/Codex session — provider-coloured mark, what it's doing, a ring when it waits; header "3 windows · 1 agent waiting"; Approve / Deny rows through the daemon's `answer_ask`; ×, middle-click, W, Quit and ⌘-right-click on a live agent's window need a second press; Close all keeps agent windows |
| Delegate to an installed counterpart | n/a | Done | "Render with" on the card: JR-Bar, DockDoor (free), ActiveDock (paid) — an external pick parks the watcher, live install/run probe + Open button |
| Dock stays raised while a preview is up | yes (auto-hide off while hovering) | Done | Private `CoreDockSetAutoHideEnabled` — no `killall Dock`, restored on close/crash; `DockHold`; where the pair doesn't resolve the card's switch disables and says so, and a launch that repaired an unclean quit's hold says that too |
| Fullscreen / New Window verbs on cards | yes | Done | `AXFullScreen` write; New presses the app's own New Window menu item through AX (else the item it binds to plain ⌘N), posting ⌘N only when the menu offers neither; Quit follows through — an app still running a beat later (macOS 27's keep-running) turns the disc into Force Quit |
| Click preview to raise, close / minimise / maximise buttons | yes | Done (raise, close ×, minimise/restore –) / Won't (maximise — a zoom button on a thumbnail is a mis-click magnet) | `AXRaise`/`AXMain` then a plain activate on click; `AXCloseButton` press; `AXMinimized` write; the walked card takes W / M / F and ⌥←/⌥→ |
| Middle-click to close | yes | Done | `otherMouseDown` on a card presses its `AXCloseButton` |
| Drag a window between previews / to another app | yes | Done | A card carrying `AXDocument` is a file drag source — onto another app's Dock tile, or onto that app's preview, which opens the file there |
| Aero shake (shake a preview to minimise the rest) | yes | Done | `ShakeDetector` on continuous hover → `AXMinimized` on the app's other windows |
| Close-all / minimise-all from the app preview | yes | Done (Min all + Close all + Hide / Quit) | Hide / Quit always in the header; "Min all" appears on multi-window previews and writes `AXMinimized` across the set; "Close all" presses each window's `AXCloseButton` and drops closed cards, the app staying running windowless |
| Compact list view past N windows | yes | Done | Configurable limit; a tile past it renders a row-per-window list |
| Large preview option | yes | Done | 208×130 cards |
| Folder Pop: hover a Dock folder → contents, sort, open, drag out | yes (+ drag items out since 1.40) | Done | `AXFolderDockItem` tiles pop a capped grid (five across, browse into subfolders in place, ⌘-click opens in Finder) in the tile's own Sort By, read from the Dock's `persistent-others` (Name, Date Added, Modified, Created, Kind); Quick Look thumbnails on chips; POSIX `readdir` off-main — a TCC consent pend or stuck vnode can't reach the UI; denied folders get a Settings shortcut, not a spinner; chips are drag sources carrying their own file URL — DockDoor 1.40's drag-out — with Show in Finder and Send to Shelf |
| Option+Tab window switcher with previews and keyboard control | yes | Done | `DockSwitcher` — `CGEventTap` on ⌥⇥ (Accessibility), runs on its own (a Switcher pick hands the chords to AltTab / DockDoor / Witch / Contexts or turns them off, independent of who draws the previews; a pre-split setting that gave DockDoor the Dock keeps giving it ⌥⇥); centred strip with minimized + other-Space windows included (an other-Space pick reaches that exact window through a read-only remote-token AX walk), a "needs you" lane for waiting agents, the list live while ⌥ is held, per-display option, fuzzy type-ahead and ⌘-verbs while the chord is held; stills via the shared `DockThumbnailer` filling card by card (one-shot stills, 30 s cache, same no-stream trade-off AltTab makes — keeps the purple indicator off), icon cards without the grant, Dock `AXStatusLabel` unread badges on cards |
| Cmd+Tab replacement overlay | yes | Done | Same tap, app-level mode with front-window stills, ⌘/ search latch, ↓ drill and ↑ back out, spring-loaded drill on a resting pointer; off by default, it's aggressive |
| Trackpad gestures on previews (swipe to minimise/maximise) | yes | Done (swipe to minimise/restore) | `SwipeCatcher` claims vertical flicks only — horizontal scroll still reaches the strip; a landed shake or flick ticks the trackpad and dips the cards it moved |
| Media widget on hover over Music/Spotify | yes | Done | `MediaFeed` row on whichever app the Now Playing source names (a browser playing video too) — artwork, track, transport, a scrubber; Space plays/pauses with the pointer on the panel |
| Synced lyrics | yes | Done (LRCLIB) | `/api/get` → `/api/search` fallback — free, keyless, the same source boring.notch/Atoll/Notchy use; LRC-parsed, cached per track, playhead-synced quiet line on the notch Shelf's media card; the Dock's player row shows the Shelf's line while the Shelf has one — never a lookup of its own |
| Calendar widget on hover over Calendar | yes | Done | `ShelfCalendarModel` projection on the Calendar tile — the rest of today (up to three, each with Join) and "Free until …"; Zoom / Teams / Webex / FaceTime tiles offer Join on the event whose link opens there |
| Quick quit ⌘+right-click, force quit ⌘⌥ | yes | Done | The switcher's session tap eats a ⌘-right-click inside the Dock's reach so Apple's menu never pops (a global monitor is the fallback); a toast says what happened, and "still running" a beat later when the app didn't go |
| Click the active app's Dock icon to minimize | yes | Done (opt-in) | Observe-only: a plain click on the front app's own icon minimizes its visible windows through AX; with nothing visible the Dock's own reopen brings one back |
| App filters (hide apps from previews) | yes | Done | `excludedBundleIDs` in the Dock settings card (running or installed apps), or "Never Preview <App>" from the preview header's menu — an excluded tile rests without a preview |
| Dock locking to one display | yes | Won't | Needs a private `CoreDock` pin — DockDoor links private calls for it |
| Preview layouts / appearance settings | yes | Done (glass, card size, every-window toggle) | Glass per the material rule: previews float, so glass |
| Spacing scale / distance from the Dock / cover the name label | yes (Spacing Scale 0.5–2×, Buffer from Dock, "Show preview above app labels"; `consts.swift:31-32`, `:162`) | Done | Tight / Standard / Roomy, a fine 0.05 slider between them (the row names a custom value) — one `DockPreviewMetrics` scale for every inset, floors for the agent ring and verb targets, concentric corners; 4 pt off the icon by default, over the Dock's name bubble at the status-bar level (clearing a magnified icon's reach); off keeps the old bubble band; a live sample on the card, drawn, never captured; the ⌥⇥ switcher follows the scale |
| Cards fitted to each window's shape | yes (`allowDynamicImageSizing`, off by default) | Done (opt-in) | Width follows the window's aspect within 0.6–1.9× the height; the still fills the card from its top-leading corner, so no letterbox; a narrow card keeps a 96 pt caption column and stacks its hover verbs |
| AppleScript: show preview / show switcher | yes | Won't for now | Revisit if anyone asks |
| Localisation | yes | Won't for now | |

### Dock — additional rivals in scope

| Rival | Type | Coverage | Notes |
| --- | --- | --- | --- |
| DockDoor Pro | Paid ($20 one-time, 3 Macs) | Enhance rows above apply; Pro-only replace-dock scope cut | Full native Dock replacement, 20+ in-place actions, Alt-Tab replacement + Glance, folder fan-out + file tray + AirDrop, per-display docks + profiles, Now Playing + synced lyrics, AppleScript; 1.4x adds pinned-apps-first switcher ordering, last-focused timestamps, AppSense profile switching, community widget marketplace; replace bar cut 2026-09-15; sources: pro.dockdoor.net/features + CHANGELOG |
| ActiveDock (MacPlus) | Paid (one-time, 14-day trial) | Covered by Enhance rows; external pick parks watcher | Window Preview panel, groups + folders + Start Menu, multi-monitor; "Render with" offers ActiveDock; source: noteifyapp.com/activedock |
| DockMate (MacEnhance) | Paid (from $14.99, stale — last release 0.8.7/2021) | Covered by Enhance rows | Hover → mini → full-size previews, Music + Calendar quick-look + Join; no keyboard switcher; source: macenhance.com/dockmate.html |
| Sidebar (sidebarapp.net) | Paid (lifetime €19.99 / €1.25-mo / €12.50-yr) | Covered by Enhance rows | Vertical Dock replacement + window manager, per-screen sidebars, hover previews, switcher overlay + search, WindowSnap; source: sidebarapp.net |
| uBar (Brawer) | Paid ($30 Personal / $50 Commercial) | Covered by Enhance rows | Windows-style taskbar, grouping, live previews, per-monitor bars, favorites + drag-onto-apps; no Cmd-Tab replacement; source: ubarapp.com |
| SwitchGlass (John Siracusa) | Paid ($4.99 MAS) | App-switcher only — no window thumbnails | Floating app switcher, per-display, drag-onto-icons, exclude list; gaps: no previews/verbs/gestures/media; source: hypercritical.co/switchglass |

### ⌥⇥ Switcher (vs Witch, Contexts, AltTab)

| Feature | Witch ($14, Many Tricks) | Contexts ($9.99) | AltTab (GPL-3, free + Pro $9.99) | JR-Bar Switcher | Notes |
| --- | --- | --- | --- | --- | --- |
| Window switcher with live previews | list/icons/titles (no live thumbnails) | title list (no thumbnails) | yes — live thumbnails + full-size preview | Done | `DockSwitcher` — `CGEventTap` on ⌥⇥ (Accessibility), centred strip; `CGWindowList` + AX merge is live incl. off-screen rows; cards draw real window stills through the shared `DockThumbnailer` (one-shot captures, not a stream), icon fallback without the grant; AltTab's layout — a preview pane above the strip shows the pick, and hovering a card makes it the pick — and the type-ahead score-ranks, title hits over app hits, recency on ties; sources: manytricks.com/witch, contexts.co, github.com/lwouis/alt-tab-macos |
| App switcher (⌘⇥) replacement | yes (multiple switchers) | yes (Cmd-Tab windows-listed) | yes (custom shortcuts) | Done (off by default) | Same tap, app-level mode; ↓ on a card drills into that app's windows — Witch's drill-down — ⌘-release commits the window; Dock `AXStatusLabel` badges on cards; a minimized-only app restores its picked window instead of merely activating; off by default, it's aggressive |
| Type-ahead filtering while chord held | fuzzy type-to-filter | fuzzy search + Fast Search | yes (Pro type-to-filter) | Done | The command bar's subsequence scorer (consecutive-run, word-start, prefix bonuses) — "sfr" lands Safari the way Witch's fuzzy does; keys spell through the current layout (`UCKeyTranslate`); an agent's window is found by its session label, directory or provider, "!" narrows to waiting agents; short queries learn their pick like Contexts' Fast Search. Gaps: no sidebar, and Witch's multi-switcher configurability |
| Close/quit/minimize verbs in switcher | H/M/W/Q/Z/F/P/R/G keys | Close/Quit/Minimize/Hide | close/minimize/fullscreen in switcher | Done (⌘Q/⌘W/⌘M/⌘H/⌘F, ⌥⌘+arrow tiles) | ⌘-verbs on the highlighted row — quit/hide on the app, close/minimize/fullscreen on the window; ⌘W/⌘Q on a live agent's row need a second press; a hint row names the keys while ⌘ is held; the strip rebuilds around the pick; ⌘-keys never leak to the front app while the strip is up |
| Order, windowless apps, card style | per-switcher sort + filters | — | sort order, show windowless apps, thumbnails / app icons / titles (`Preferences.swift:8-47`) | Done | Window order (most recent first, or grouped by app), Apps with no windows (off; a card per running app with none, picking it activates the app), Card faces (stills, or icons that never capture) |

## Menu Bar (vs Ice, Bartender 7)

Ice is GPL-3 — clean-room, like DockDoor. Bartender 7's feature list is the
parity bar; "Pro" extras (Top Shelf) are called out where they're separate.

| Feature | Ice | Bartender 7 | JR-Bar Menu Bar | Notes |
| --- | --- | --- | --- | --- |
| Hide menu bar items (separator section) | yes | yes | Done | Under the macOS 27 concealer (this Mac) the agent hides whole apps, and macOS never draws our own item, so the icon is `MenuBarIconMirror`: a panel flush left of the first drawn item, clear of the notch, the Screen Bar and the front app's menus, with a ‹ that toggles the Item Bar; the empty bar left of it is the reveal zone. Sections there are explicit per app, picked in the Item Bar, the card, the menu or the palette, and nothing is learned from position; Apple's extras and bare helpers, which the agent cannot hide, take a cover where they sit (`cover paint` logs the painted spans). The Screen Bar's right ear carries the ‹ only while no mirror stands (the Hidden icon style, or nothing running to conceal). Under the spacer engine (macOS 26, and the fallback) the icon's own item is the separator: a 30 pt drop zone with a standing ‹ mark, and what stands left of it is packed into macOS's own overflow — see docs/UTILITIES.md |
| ⌘-drag an item across the separator to hide/show | yes | yes | Done | Under the spacer engine an item's section is where it stands, so a ⌘-drag across the icon hides or shows it. Under the concealer the agent repacks the row itself and position decides nothing: a drag moves an item without changing its app's section, which the Item Bar, the card, the menu or the palette picks |
| Delegate to an installed counterpart | n/a | n/a | Done | "Render with" on the card: JR-Bar, Bartender, Ice, Hidden Bar — an external pick parks our engine, live install/run probe + Open button |
| Always-hidden section | yes | yes | Done | |
| Show hidden on hover over menu bar | yes | yes | Done | |
| Show hidden on empty-space click | yes | yes | Done | The ‹/› click toggles the Item Bar itself — macOS only un-parks what fits, so the run's own surface is the answer; an empty run pops a teach menu instead of swallowing the click |
| Show hidden on scroll/swipe | yes | yes | Done | |
| Auto-rehide after N s | yes | yes | Done | |
| Show for updates — a hidden item that changes briefly reveals | no | yes | Done | AX title diff per scan — a clock's minute, a VPN's "Connected" — reveals the run for the re-hide interval; seeds quietly, never announces its own motion |
| Hide app menus when they overlap items | yes | yes | Done | The front app's menu edge is cached per AX scan; items it overdraws plan hidden |
| Drag-and-drop arrange | yes | yes | Done (explicit arrange mode) | ⌘-drag `CGEvent`s on the real items, AX-gated, banner + Esc cancel; never in the background |
| Hidden items in a separate bar (Ice Bar / Bartender Bar) | yes | yes (Liquid Glass) | Done | The "Item Bar" — glass, floats under the menu bar; live `SCScreenshotManager` tiles with icon fallback |
| Search menu bar items | yes | yes (Command Bar + clipboard history) | Done (⌘⇧K) | Click-outside dismissal ships; clipboard history: Won't — a second product |
| Item spacing control | yes (beta) | yes (3 presets + custom) | Done (4 presets) | `MenuBarSpacing` writes `NSStatusItemSpacing`/`SelectionPadding` — the same global pref Bartender writes; running items pick it up on relaunch |
| Spacer / label items in the bar | roadmap | yes | Done | Our own status items as spacers/labels/emoji — click reveals the run |
| Menu bar tint, gradient, shadow, border, rounded | yes | yes (incl. themed bar) | Done (cover tint/material/rounding + full-bar underlay) | Underlay panel at `statusBar - 1` |
| Profiles (named bar layouts) | roadmap | yes | Done | Trigger-switchable; per-display override follows the pointer's screen |
| Triggers (unplug → show battery, VPN on public Wi-Fi, mic in meetings…) | partial (roadmap) | yes | Done (lock/unlock/app/time/charger/battery-above-below/Wi-Fi/mic/Focus → apply-profile, hide/show, reveal, run-script) | `CWEventType.ssidDidChange`, AVCaptureDevice mic poll, Focus DB watch, internal-battery percent edges; the script action is Bartender parity — `/bin/sh -c` detached, launch + exit logged |
| Hotkeys for sections / bar / search | yes | yes | Done | Carbon `RegisterEventHotKey`, same as panel hotkey |
| AppleScript / Shortcuts / Siri control | no | yes | Won't for now | Revisit if asked |
| Custom menu bar widgets (scripts, data sources) | roadmap | yes | Won't | Third-party code in our process; a whole ecosystem |
| Menu bar widgets (clock/stats built-ins) | roadmap | yes | Done | Covered by the combined system item — battery, Wi-Fi, sound, Focus in one popover |
| **Combined system item replacing Apple's Battery/Wi-Fi/BT/Sound/Focus** | no | no | Done | Where we beat them — `com.apple.controlcenter` visibility defaults, save + restore, one popover |
| Agent state in the bar item (usage arc, session dots) | no | no | Done | Where we beat them — the feed's state dot, click opens the Overview |
| Notch-aware hiding (items under the notch → hidden) | partial | yes ("Beat the notch") | Done | The notch band is an obscured frame — an item behind glass plans hidden where the Item Bar can still reach it |
| Works without Screen Recording | no | yes (icon tiles) | Done | Icon tiles; live captures upgrade with the grant |
| Launch at login, auto-update | yes | yes | Done | Existing |
| Localisation | yes | yes | Won't for now | English only |

### Menu Bar — additional rivals in scope

| Rival | Type | Coverage | Notes |
| --- | --- | --- | --- |
| iBar / iBar Pro (Ningbo Shangguan) | Paid (free + $2.99-yr; Pro $9.99 one-time, MAS) | Covered by rows above | Aggregation floating window for notch Macs, 4 gap levels, notch-aware core pitch; requires Screen Recording; sources: MAS ibar-pro-menubar-control-tool, MAS ibar-menubar-icon-control-tool |
| Barbee (HyperartFlow) | Paid (free + 3-day trial; Lifetime ~$12.99 / Yearly ~$4.99, MAS) | Covered by rows above | Normal + Enhanced second row, Emoji/SF dividers, Spotlight-style search, ~40% denser spacing, tint/rounded, cloud profiles, app-launch/Focus/CPU rules, notch support (VIP); sources: MAS barbee-hide-menu-bar-items, lifehacker review |
| Hidden Bar (dwarvesf, MIT) | OSS | Covered by rows above | Arrow + `|` separator, option-click second zone, global hotkey, no daemon/network; v1.11.1 (2026-09-18) fixed macOS 27 hiding via a private framework, per-app not per-icon, and the MAS build still can't hide on 27; "Render with" offers Hidden Bar; sources: github.com/dwarvesf/hidden releases, MANUAL.md |
| Dozer (Mortennn, MPL-2.0, abandoned) | OSS (abandoned 2022; fork Dozer-X for AS/macOS 14+) | Covered by rows above | 2–3 dot separator groups; no hover/scroll/search; native ⌘-drag only; sources: github.com/Mortennn/Dozer, github.com/callebtc/Dozer-X |
| Bartender 7 Pro / Top Shelf extras | Paid extras (Pro ~$15-yr; Mega Supporter ~$80 lifetime; Setapp) | Called out where separate | 7.0.0 shipped 2026-09-14 — App Intents (Shortcuts/Siri), hotkey "Focus Mode" hides the whole bar, hide system items incl. clock, per-monitor preset sync; Golden Gate betas add disabled-items detection, text/emoji/SF spacers, "hide shown items when revealing hidden" (**shipped** — `hideShownWhileRevealing` covers the visible run while the Item Bar is open), expanded AppleScript, a Raycast extension. Top Shelf: notch widgets, Files shelf, Clipboard (100 items), Calendar/Music/Live Activities incl. Claude/Codex alerts; combined system item + agent state are still where we beat Bartender; sources: macbartender.com/Bartender7, /goldengate/releases |

## HUD capsules (vs MediaMate, BetterTouchTool, MewNotch, boring.notch)

| Feature | MediaMate (~€6.99 one-time) | BetterTouchTool (~$15/2yr, ~$25 lifetime) | MewNotch (GPL-3) | boring.notch (GPL-3) | JR-Bar HUD | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Volume / brightness / keyboard-backlight HUD replacement | yes (4 themes + Touch Bar) | DIY via Floating Menus/widgets | yes + auto-brightness + system-HUD kill | yes, full replacement | Done (volume, brightness, keyboard backlight) | `NX_SYSDEFINED` decode; Apple's HUD still shows too — hiding it needs the private `OSDUIHelper` kill; sources: wouter01.github.io/MediaMate, docs.folivora.ai, mew-notch repo |
| Caps Lock / Focus / display capsules | no / Focus Filters (hide HUDs) / partial | DIY via actions | no | partial | Done | See Notch table — Caps Lock, Focus, display connect/disconnect |
| Now Playing w/ scrubbing | yes (scrub; Music/Spotify/Chrome) | DIY widgets | title popups + controls | scrub yes | Done (both) | MediaRemote `seek` verb + LRCLIB synced lyrics on the media card |

## Shelf tray (vs Dropover, Yoink, Dropzone 4, boring.notch shelf)

| Feature | Dropover (free + Pro $6.99 IAP) | Yoink (~$8.99 Mac) | Dropzone 4 (Pro Lifetime ~$35 / Yearly ~$20) | boring.notch shelf (GPL-3) | JR-Bar Tray | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| File drop shelf | yes (shake-to-summon, multi-shelf) | yes (edge shelf + stacks + QuickLook + file icons) | yes (Drop Bar stash, detachable) | yes (Shelf 2.0: context menu, multi-select, move-by-default, drag-into-notch) | Done (tray + AirDrop + QuickLook + ⌃⌥D summon) | `NSSharingService` AirDrop on the tray chip's menu; `QLPreviewPanel` on double-click/menu; URL drops → `.webloc`, text drops → deterministic `.txt`; drag-to-notch summon; top-edge + ⌃⌥D hotkey summon; swipe-up fold; real file-type icons via `NSWorkspace.icon(forFile:)` + async Quick Look thumbnail upgrade; drop-onto-chip reorder persists; Folder Pop chips drag files OUT; the 40-item cap names the chip it evicted for a few seconds instead of letting it go silently. Stacks and shake-to-summon are in (rows below). Honest gap: no multi-shelf; sources: dropoverapp.com, Yoink MAS, aptonic.com, boring.notch v2.7 notes |
| Shelf with AirDrop | no (share links) | no (Handoff to iOS) | yes (AirDrop action grid) | yes (shelf + AirDrop) | Done | Same as above — direct Dropzone overlap |
| Drag-out copies, not moves | ? | yes (⌥ copy, ⌘ move) | ? | `copyOnDrag` | Done | `shelfDragOut` (Copy by default, Atoll #682's choice): the chip drags through `ShelfDragSource`, whose mask is copy outside JR-Bar; ⌘ held at the start of the drag moves; the Move setting makes move the default |
| Remove after dragging out | ? | yes | ? | `autoRemoveShelfItems` | Done | `shelfRemoveAfterDragOut`: only the dragged chip, only for a drop outside JR-Bar that landed |
| Multi-select, Clear Shelf | ? | yes | yes | yes (Shelf 2.0) | Done | ⌘- and ⇧-click pick chips (⌥-click splits a stack); every file verb on a picked chip (Remove, Quick Look, Reveal, AirDrop, Share, Hand to and the actions) acts on the pick; Clear Shelf drops every reference, files untouched. No marquee yet |
| Instant actions: ZIP, copy text, convert, copy/move to | yes (resize, extract text, ZIP) | no | yes (action grid) | no | Done | Compress (`ditto`, beside the files), Copy Text (Vision on-device; a PDF's own text), Convert to PNG / JPEG (ImageIO; only to a format the image is not already in), Copy to… / Move to… (off the main thread; a move that fails part-way keeps the moved chips); Finder's free names, never an overwrite |
| Shake sensitivity and app exclusions | yes | ignore apps | no | no | Done | `shelfShakeSensitivity` (three 20 pt swings … six 45 pt) and `shelfShakeExcludedBundleIDs` |
| Steps aside for another shelf app | — | — | — | — | Done | `shelfYieldToRivals` (on): while Dropover, Yoink or Dropzone runs, the shake summon stands down; dropping on the notch still works |
| Newest first; shelf off | no | no | no | yes (2.8 reverse order, disable Shelf) | Done | `shelfNewestFirst`; `shelfEnabled` off hides the tray and takes no drops — not on the island, the card, a paste or the Dock, whose Send to Shelf goes away |

## Keep-awake (vs Amphetamine, KeepingYouAwake, Atoll)

| Feature | Amphetamine (free, MAS) | KeepingYouAwake (MIT) | Atoll (GPL-3) | JR-Bar Keep Awake | Notes |
| --- | --- | --- | --- | --- | --- |
| Session presets (15 m … 4 h), indefinitely | yes | yes (custom list) | yes (cup in the notch header) | Done | `KeepAwakeMenu` on the Awake chip, the footer cup and the Screen Bar's ear; the presets are the person's own list (`jrbar.keepAwakeDurations`) |
| Until a time | yes | no | no | Done | Until 08:00, the panel's next-morning rule |
| While an app / process runs | yes | no | no | Done (agents) | Until the agents finish — the daemon's agents lease; the agents' own hold runs while any works |
| Keep the display on | yes | yes (allow display sleep) | yes | Done | App-local `keepAwakeDisplay`; the daemon rows add Keep display awake while agents run |
| Closed-display mode | yes | no | no | Done | Lid closed policy (daemon) |
| Battery floor, Low Power Mode | yes (battery) | yes (both) | no | Done (battery) / Planned (Low Power Mode) | The daemon yields at the battery floor; a `low_power` pause already reads "Low Power Mode is on" — the yield itself lands with the daemon lane |
| Triggers (display, app, Wi-Fi, schedule…) | yes | external display only | no | Planned | Through the menu bar's rule engine (its lane) |
| Who else holds the Mac awake | no | no | no | Done | The card's Other apps, read-only from `IOPMCopyAssertionsByProcess` |
| A card of its own | — | — | — | Done | Utilities › Keep Awake, after Dock |

## Mirror / Calendar / Reminders (vs Dato, Fantastical, NotchNook peek, Itsycal, boring.notch)

| Feature | Dato ($18 one-time) | Fantastical (Premium ~$7-mo) | NotchNook camera peek ($25) | Itsycal (MIT) | boring.notch (GPL-3) | JR-Bar | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Calendar: next event + join link | yes (Zoom/Meet/Teams join + shortcut) | yes (Mini Window + proposals) | widget yes (no join documented) | event list (no join) | yes | Done | EventKit; `ShelfCalendarModel` projection on Calendar tile; sources: MAS Dato, flexibits.com/fantastical, lo.cafe/notchnook, mowglii.com/itsycal |
| Reminders with write-back | yes (due-date create) | yes (tasks) | no | no | yes | Done | Check-off writes back; boring.notch doesn't |
| Mirror (camera preview) | — | — | yes (FaceTime Mirror) | — | yes | Done | `ShelfMirrorModel`, consent-gated, lens closes on fold; off by default |

## Control Center (vs One Switch, BetterTouchTool, OnlySwitch, macOS Control Center)

| Feature | One Switch ($4.99–16.99 lifetime) | BetterTouchTool (~$15/2yr) | OnlySwitch (MIT) | macOS Control Center (built-in) | JR-Bar Control Center | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| One-switch toggles | yes (~dozen: Hide Desktop, Dark Mode, Keep Awake, Saver, AirPods, DND, Night Shift…) | DIY triggers/actions | yes (toggles + Shortcuts gallery + widgets) | yes (Wi-Fi/BT/AirDrop/Focus/Mirror/Display/Sound) | Done (8-chip strip) | `SystemTogglesStore` on the notch card: keep-awake (IOPMAssertion — public, reversible), dark mode (AppleScript appearance prefs — no private `SLSSet` calls), desktop icons + hidden files (`defaults write` + Finder restart, warned), mute (CoreAudio `kAudioDevicePropertyMute`), screen saver (`open -b com.apple.ScreenSaver.Engine`, verified on 27), lock (`pmset displaysleepnow` — CGSession is gone on 27; locks on wake where a password is required), Dock autohide. Every chip reads truth back — a refused write says so, never claims the flip. Gaps kept honest: no DND/Night Shift/AirPods toggles yet |
| Creator Micro 2 Rail | — | Stream Deck-class DIY | — | — | Ships (pad verified powered off only) | ⌘K; see FEATURE-MATRIX.md |

## Menu-bar meters (vs iStat Menus, Stats, RunCat)

| Feature | iStat Menus (Single $11.99 / Family $14.99) | Stats (MIT, ~41k stars) | RunCat (free + IAP) | JR-Bar meters | Notes |
| --- | --- | --- | --- | --- | --- |
| Meter-in-the-bar (battery/Wi-Fi/sound/Focus) | yes (9 items + Combined stacked; 7.5 shipped 2026-09-14) | yes (9 modules: CPU/GPU/RAM/Disk/Sensors/Network/Battery/BT/Clock) | CPU runner only | Done | Combined system item in one popover; see Menu Bar table; sources: bjango.com/mac/istatmenus, mac-stats.com, kyome.io/runcat |
| Usage arc / session dots in bar item | — | — | ambient-pet instinct | Done | Where we beat them; RunCat is the "living menu-bar meter" inspiration, not a counterpart |
| Provider quota meters w/ forecast + pace | — | — | — | Done | Usage Center + ear ring + panel row share the same most-constrained-window number |

## Agents / Overview / Usage (vs Conductor, Terragon-class, CodexBar, ccusage, Crystal, Vibe Kanban, cmux, Claude Squad, Omnara, Happy)

| Feature | Conductor (free local; Pro $50-mo) | Terragon-class (shut down 2026-01-16; Apache-2.0 snapshot) | CodexBar (MIT, closest analogue) | ccusage / claude-monitor (MIT) | Crystal (MIT, deprecated → Nimbalyst) / Vibe Kanban (Apache-2.0, community) / cmux (OSS) / Claude Squad (AGPL-3.0) | Omnara (Apache-2.0) / Happy (MIT) | JR-Bar | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Parallel session dots + quota in menu bar | yes (parallel workspaces + status) | yes (parallel sandboxes + stream) | yes (69 providers, session + weekly meters) | CLI/terminal analytics | yes (worktrees/TUI/sidebar) | yes (fleet dashboard / multi-session relay) | Done | Sessions live in notch, bar, aquarium — ambient, not a dashboard; sources: conductor.build, terragon-oss, steipete/CodexBar, ccusage, Maciek-roboblog monitor, stravu/crystal, BloopAI/vibe-kanban, cmux.com, smtg-ai/claude-squad, omnara.com, slopus/happy |
| Usage forecast with pace + reset countdown | no (workspace, not forecast) | no (task stream, not forecast) | yes (reset countdowns + pace) | yes (forecast/P90/burn-rate) | no (workspaces/TUI/sidebar, not forecast) | no (fleet/relay, not forecast) | Done | Every provider (Claude, Codex, Gemini, Antigravity, Pi) in one forecast; ear ring / panel row / Usage Center agree |
| Ask approvals escalating (sound/pulse/capsule) | review → PR → merge | notifications | incident/stale indicator | live monitor | diff review / notify hooks / approvals | live approvals + push alerts | Done | Suppresses when the ask's own terminal is frontmost; force-directed graph removed — Obsidian view is not part of this utility |
| Multi-agent manager workspace | yes (worktree + branch + diff) | yes (branches + PRs) | no (meter only) | no | yes | yes | Won't (philosophy gap) | Those tools *are* the workspace; ours watches the workspaces you already have — nothing to migrate into |
| Incident badges from vendor status feeds | no | no | yes | no (CLI analytics) | no | no | Done | Ear flips to attention tone with feed text on hover |

## LED / Effect Studio / Deck (vs Govee, Nanoleaf, Hue Sync, SignalRGB, Elgato, WLED, OpenRGB, Hyperion/HyperHDR, Companion, Touch Portal, OpenDeck)

| Feature | Govee / Nanoleaf / Hue Sync / SignalRGB | Elgato Stream Deck ecosystem | WLED (EUPL-1.2) / OpenRGB (GPL-2.0) / Hyperion+HyperHDR (MIT) / Prismatik (GPL-3.0) | Bitfocus Companion (OSS) / Touch Portal (~$14–20) / OpenDeck (GPL-3.0) | JR-Bar | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LEDS format driving Pro/Dot strips + Creator Micro pad | scenes/scenes/gallery/effects | — | 200+ effects / per-device modes / bias lighting / ambilight | — | Done | The LEDS format is ours; WLED is the firmware lingua franca, Hyperion/Prismatik the ambient screen-sync lineage; sources: govee/nanoleaf/hue/signalrgb sites, kno.wled.ge, openrgb.org, hyperion.ng, Lightpack docs |
| Effect Studio w/ assignments + scenes + packs | DIY/AI scenes, playlists | — | segments/playlists/profiles | — | Done | Library, inspector, live preview, pack import/export; see FEATURE-MATRIX.md |
| Deck bindings for Creator Micro | — | yes (keys/dials/profiles/SDK) | — | yes (700+ modules / macro deck / OpenAction) | Done | Control Center + Rail for Creator Micro 2 (⌘K); sources: elgato.com, bitfocus.io/companion, touch-portal.com, OpenDeck repo |
| "Why did my light change" explainability | no | no | no | no | Done | Inspiration: Home Assistant automation trace/logbook |

## Aquarium, Notch Buddy, Confetti

No direct counterpart; measured against the inspiration bar in docs/TOYS.md.

| Ours | Inspiration | JR-Bar | Notes |
| --- | --- | --- | --- |
| Aquarium | Insaniquarium (PopCap) — feeding economy, growth stages, starvation costing a stage, while-you-were-away payouts | Done | Twist is ours: sessions are fish, raised fish become residents, sub-agents join as fry orbiting the parent; zen-tank screensaver layer (kelp, parallax fronds, treasure chest) |
| Notch Buddy | Tamagotchi (care/neglect: pet/treat counts) × Shimeji (roaming desktop pets) × Desktop Goose (meme energy) × Apollo's Pixel Pals (iOS Dynamic Island pet — direct ancestor) | Done | Creature living on the notch. Floating, it walks window tops and turns round (Shimeji's walk), with a "Time between walks" dial in the spirit of Desktop Goose's wander timing; turns, mood changes, the dangle, tucks and the hop out of the notch all ease, never pop |
| Confetti | Duolingo streaks × Raycast confetti (themed kinds, bottom-corner cannons) × iMessage confetti (drag ramp, sway and flutter waves, 3D planes, a far layer) × canvas-confetti (linear-drag spread, mixed sub-bursts, 60 fps) | Done | Triggers are ours, and so is the lip: the notch pops, pieces land on your window tops, glyph flecks are the provider's own mark. Kept closed-form in a Canvas (no private `CAEmitterBehavior`) so the landings, the room rules and frozen render proofs still work |
| Screensaver lineage | After Dark (Berkeley Systems flying toasters) · Aerial (Apple TV drone footage) | Removed | Obsolete — agent Overview + Aquarium are the ambient surfaces now |
| Overview force-graph | Obsidian graph view — force-directed constellation | Removed | Not part of the agent Overview utility; table + inspector only |
| "Why light" panel | Home Assistant automation trace / logbook | Done | Explainability for what fired an effect |
| Living meter | RunCat — CPU-speed cat | Done | Ambient-meters-as-pets instinct; see Menu-bar meters |

## New rivals found in the 2026-09-18 research pass

| Rival | Type | Why it matters | Notes |
| --- | --- | --- | --- |
| Atoll (Ebullioscopic, GPL-3) | OSS notch app | Ships an LLM Usage tab — Claude plan badges, Antigravity token/cost, New API providers, cache-aware pricing — a direct attack on our "no rival" island claim; also LRCLIB+NetEase synced lyrics, lock-screen panel, Screen Recording live activity, per-app volume mixer, clipboard tab, extension marketplace | sources: github.com/Ebullioscopic/Atoll CHANGELOG |
| Notchy (notchy.dev) | Free (claims ~13k installs) | AI Usage Tracker (Claude Code/Codex/Cursor/Copilot rate-limit windows, cost, alerts), LRCLIB synced lyrics, Face Unlock, claims full stock-HUD suppression on Tahoe, command palette, clipboard history | Vendor marketing page — claims unverified; source: notchy.dev |
| NotchIA (notchia.app) | Freemium (Pro €2.99/mo / €24.99 lifetime) | Claude Code/Codex tracking in the notch, on-device AI "Digest" summaries, screen-capture detection, 100-item clipboard, HUDs | Vendor page — claims unverified; source: notchia.app |
| SaneBar (sanebar.com) | OSS (MIT) | Menu-bar hider with second bar, Touch ID lock, 6 triggers, icon groups, profiles, Bartender/Ice migration import, AppleScript/Shortcuts | Direct OSS peer for the Menu Bar rows; source: sanebar.com |
| Brow (brow-app.com) | Free | Hover-notch command center: screenshots+OCR, focus timer w/ site blocker, live CPU/RAM/battery/fan meters, file staging, GIF recording, meeting joins | Vendor page — claims unverified; source: brow-app.com/notch |
| DockView (MacPlus) | Paid | HyperDock-class hover previews — 2.2.0 shipped 2026-09-18 with panel animations; covered by the DockDoor Free rows | source: noteifyapp.com |
| Badgeify (badgeify.app) | Paid | Menu-bar notification badges for any app — adjacent niche | source: badgeify.app |

## How rows change state

A row moves to **Done** in the same commit that lands the feature and its
test. A row moves to **Won't** only with a reason someone could argue
with. Nobody edits a rival's column from memory; cite the release note or
README that says the feature exists.
