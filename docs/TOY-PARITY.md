# Toy parity

The point of the native toys is that Jonathan can uninstall the apps they
stand in for. So each native toy is measured against the app it replaces,
feature by feature. A toy is not "done" until every row for its rivals
reads **Done** or **Won't** with a reason. External providers stay in every
card regardless; parity is about making them optional, not removing them.

Sources: tryalcove.com (v1.7.x release notes), TheBoredTeam/boring.notch
README roadmap, dockdoor.net, pro.dockdoor.net + gumroad listing, trybendy.app,
jh3y/lid-plane, macduo.dhananjaytech.app. Started 2026-09-14. Nothing here
is copied; DockDoor and Lid Plane are GPL-3, everything native is clean-room.

Labels: **Done** (shipped in the native toy, tested at its seam),
**Planned** (in scope, not yet built; the step that lands it), **Won't**
(out of scope, with the reason). Nothing else counts.

## Notch (vs Alcove, Boring Notch)

| Feature | Alcove | Boring Notch | JR-Bar Notch | Notes |
| --- | --- | --- | --- | --- |
| Notch-flush black island, hover to expand | yes | yes | Done | The island itself grows into the card, solid black and contiguous with the notch; Liquid Glass is fallback-only — the detached card under the band when the toy is off or an external provider owns the notch |
| Pill shape on notch-less displays | yes (1.7) | yes | Done | `Capsule` face |
| Simulated notch toggle on notch-less Macs | yes (1.7.1) | sizing options | Done | `ScreenBarGeometry.simulatedNotch` — the island hugs the top as a synthetic housing |
| Now Playing: artwork, title/artist, transport | yes | yes | Done | perl-hosted MediaRemote helper |
| Now Playing: waveform/visualizer | yes (iOS-matched) | yes | Done (3 bars) | Upgrade to iOS-style waveform in step 5 |
| Now Playing: scrubbing, lyrics | yes / no | scrub yes | Done (scrub) | Interpolated playhead + drag-to-seek through the MediaRemote `seek` verb; lyrics: Won't, needs a lyrics service |
| Audio format badge (Lossless/Atmos) | yes | no | Won't | Private API surface, low value |
| Charging / on battery / full capsule | yes | yes | Done | `AlcovePower` |
| Battery % in card | yes | yes | Done | |
| AirPods / Bluetooth connect capsule (with battery) | yes | roadmap | Done (name + battery %) | `IOBluetooth` watcher on a dedicated runloop thread — the CoreBluetooth handshake can never wedge launch again |
| Volume / brightness / keyboard-backlight HUD replacement | yes | yes | Done (volume, brightness, keyboard backlight) | `NX_SYSDEFINED` decode → CoreAudio / DisplayServices / CoreBrightness reads on a `.listenOnly` tap; Apple's HUD still shows too — hiding it needs the private `OSDUIHelper` kill |
| Caps Lock indicator | yes | no | Done | `flagsChanged` on the global stream and our own windows — fires while a JR-Bar panel is key |
| Focus mode change capsule | yes | no | Done | `~/Library/DoNotDisturb/DB/Assertions.json` + the daemon's `focus_sync` |
| Display connect / disconnect capsule | yes | no | Done | `NSApplication.didChangeScreenParameters` |
| Screen recording indicator capsule | yes | no | Won't | macOS 26 has no public capture signal — `kCGSSessionScreenIsCaptured` is gone, the purple indicator is WindowServer-composited (no window), and `replayd` keeps its state private; verified live against `screencapture`. Alcove reaches it through private API; we won't link private frameworks for a capsule |
| Notification banners mirrored into the island | yes | under consideration | Won't | Needs private notification-center hooks; Alcove's own FAQ says these can break any release |
| Calendar: next event, join link | yes | yes | Done | EventKit, "Show calendar" grant |
| Reminders | no | yes | Done | EventKit, "Show reminders" grant; check-off writes back |
| Weather | yes | roadmap | Done | Open-Meteo keyless (no WeatherKit entitlement), off by default |
| Timers / Pomodoro | via Live Activities | no | Done (timers) | Hide row when empty (step 1) |
| Shelf / file drop with AirDrop | no (Drop in 1.6) | yes | Done (tray + AirDrop verb) | `NSSharingService` AirDrop on the tray chip's menu |
| Mirror (camera preview) | no | yes | Done | `ShelfMirrorModel` — AVFoundation session on a private queue, consent asked on the toggle, lens closes when the card folds away; off by default |
| Swipe gestures on the island | yes | yes | Done | |
| Hover tell while bare | yes (ear swell) | peek | Done | The Screen Bar ear under the pointer swells outward — the wink the bare island could never draw |
| Hover-open delay: menu-bar drift vs direct | 0.3 s-ish | — | Done | 0.12 s onto the island, a third of a second arriving from the bar row; ear→island keeps the original deadline |
| Suppress hover-open under a fullscreen app | yes | no | Done | Frontmost app's presentation options; the wink still answers |
| Haptic on open | yes | no | Done | `NSHapticFeedbackManager` tick; Notch settings toggle |
| Ears as lobes of the notch | yes (wings drop below the bezel line) | ears | Done | Claimed ears hang below the menu-bar line as rounded lobes off the shared tray; an unclaimed side grows none, and the tray keeps the bezel's bottom-corner arcs scooped out (even-odd fill) |
| LED strip seated at the island's edge | — | — | Done | The band rides the island's live bottom edge — compact or grown card — instead of crossing its face at bezel depth |
| Lock-screen widgets / mode | yes | roadmap | Won't | JR-Bar can't draw over the lock screen without private APIs |
| Duo mode (two islands) | yes (1.7) | no | Won't | Nothing in JR-Bar needs a second island |
| Agent sessions, asks, usage meters in the island | no | no | Done | The reason the toy exists |
| Screen Bar LED strip across the island | no | no | Done | |
| Menu bar icon hidden | Tahoe native | yes | Done | System setting, documented |
| Sound effects on capsule events | yes | yes | Done | `NotchSounds.tick` on HUD/capsule events; on by default, toggle in Notch settings |
| Localisation | partial | Crowdin | Won't for now | English only |

## Fold (vs Bendy, Lid Plane, Mac Duo)

| Feature | Bendy | Lid Plane | Mac Duo | JR-Bar Fold | Notes |
| --- | --- | --- | --- | --- | --- |
| Reads the hinge sensor | yes | yes | yes | Done | IOKit HID, 10/120 Hz |
| Duo-style fold (scale toward hinge, progressive blur, dissolve) | yes | blur only | yes (default) | Done | Portal model: wallpaper far wall + per-window depth cards, Vogel blur toward the hinge |
| Rigid held plane | yes | no | yes (Ghost) | Done | The portal's Perspective knob at the shallow end |
| Alternate effects (Roll, Shutter, Flex, Iris) | 3 styles | 1 | 5 | Won't | One correct effect beats five |
| Perspective / blur / shade sliders | yes | no | no | Done | Kept as the Duo knobs |
| Activation angle | yes | yes | yes | Done | |
| Simulate slider (no sensor) | drag | no | Replay | Done | |
| Pause-at-angle timeout (desktop returns after N s at rest) | no | no | yes (1–5 s) | Done | Off by default; a half-closed lid stops being useless |
| Return-to-normal click sound | yes (0.3) | no | no | Done | Off by default; `NotchSounds` tick on restore |
| Screen-capture indicator only while folding | ? | ? | ? | Done | Streams live only inside `FoldArming`'s band (activation + 12°, 2 s linger) |
| Capture at 60 fps | ? | ? | ? | Done | Both streams at `minimumFrameInterval = 1/60` |
| External display / mirrored safety | yes | ? | yes | Done | |
| Reduce Motion honoured | ? | ? | ? | Done | |
| Menu bar pause / Esc | yes | ? | ? | Won't | JR-Bar's card toggle is the pause |

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
| Hover a Dock icon → live window previews | yes | Done | AX hit-test of the Dock's `AXList`, `SCScreenshotManager` one-shots per window — no stream, no purple indicator; captures alpha-trimmed to content so a purged margin can't drift the image off-centre |
| Delegate to an installed counterpart | n/a | Done | "Render with" on the card: JR-Bar, DockDoor (free), ActiveDock (paid) — an external pick parks the watcher, live install/run probe + Open button |
| Dock stays raised while a preview is up | yes (auto-hide off while hovering) | Done | Private `CoreDockSetAutoHideEnabled` — no `killall Dock`, restored on close/crash; `DockHold` |
| Fullscreen / New Window verbs on cards | yes | Done | `AXFullScreenButton` press / `document.new` AppleEvent; windowless apps get Open — the old `onOpenApp` dead-ended |
| Click preview to raise, close / minimise / maximise buttons | yes | Done (raise, close ×, minimise/restore –) / Won't (maximise — a zoom button on a thumbnail is a mis-click magnet) | `AXRaise`/`AXMain`/`activateAllWindows` on click; `AXCloseButton` press; `AXMinimized` write |
| Middle-click to close | yes | Done | `otherMouseDown` on a card presses its `AXCloseButton` |
| Drag a window between previews / to another app | yes | Done | A card carrying `AXDocument` is a file drag source — onto another app's Dock tile, or onto that app's preview, which opens the file there |
| Aero shake (shake a preview to minimise the rest) | yes | Done | `ShakeDetector` on continuous hover → `AXMinimized` on the app's other windows |
| Close-all / minimise-all from the app preview | yes | Done | Hide / Quit always in the header; "Min all" appears on multi-window previews and writes `AXMinimized` across the set |
| Compact list view past N windows | yes | Done | Configurable limit; a tile past it renders a row-per-window list |
| Large preview option | yes | Done | 208×130 cards |
| Folder Pop: hover a Dock folder → contents, sort, open | yes | Done | `AXFolderDockItem` tiles pop a capped, dirs-first strip; POSIX `readdir` off-main — a TCC consent pend or stuck vnode can't reach the UI; denied folders get a Settings shortcut, not a spinner |
| Option+Tab window switcher with previews and keyboard control | yes | Done | `DockSwitcher` — `CGEventTap` on ⌥⇥ (Accessibility), centred strip of live window cards, type-ahead filtering while the chord is held |
| Cmd+Tab replacement overlay | yes | Done | Same tap, app-level mode; off by default, it's aggressive |
| Trackpad gestures on previews (swipe to minimise/maximise) | yes | Done (swipe to minimise/restore) | `SwipeCatcher` claims vertical flicks only — horizontal scroll still reaches the strip |
| Media widget on hover over Music/Spotify | yes | Done | `MediaFeed` row on player-bundle tiles — artwork, track, transport |
| Synced lyrics | yes | Won't | Needs a lyrics service, local-only app |
| Calendar widget on hover over Calendar | yes | Done | `ShelfCalendarModel` projection on the Calendar tile — next event + Join link |
| Quick quit ⌘+right-click, force quit ⌘⌥ | yes | Done | Global `rightMouseDown` monitor — the Dock keeps its menu, ours rides the press |
| App filters (hide apps from previews) | yes | Done | `excludedBundleIDs` in the Dock settings card — an excluded tile rests without a preview |
| Dock locking to one display | yes | Won't | Needs a private `CoreDock` pin — DockDoor links private calls for it |
| Preview layouts / appearance settings | yes | Done (glass, card size, every-window toggle) | Glass per the material rule: previews float, so glass |
| AppleScript: show preview / show switcher | yes | Won't for now | Revisit if anyone asks |
| Localisation | yes | Won't for now | |

## Menu Bar (vs Ice, Bartender 7)

Ice is GPL-3 — clean-room, like DockDoor. Bartender 7's feature list is the
parity bar; "Pro" extras (Top Shelf) are called out where they're separate.

| Feature | Ice | Bartender 7 | JR-Bar Menu Bar | Notes |
| --- | --- | --- | --- | --- |
| Hide menu bar items (separator section) | yes | yes | Done | The boundary is the JR-Bar icon's own item: a 30 pt drop zone with a standing ‹ mark claims the bar's left edge permanently while the utility is on — a separator you can see, not a blank stretch (the only push the OS allows is macOS 26's native overflow — see docs/UTILITIES.md) |
| ⌘-drag an item across the separator to hide/show | yes | yes | Done | ⌘-recency gate + largest-mover discriminator — only a real drag writes `concealedApps`; space churn and reveals can't fake one |
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
| Search menu bar items | yes | yes (Command Bar + clipboard history) | Done (⌘⇧K) | Clipboard history: Won't — a second product |
| Item spacing control | yes (beta) | yes (3 presets + custom) | Done (4 presets) | `MenuBarSpacing` writes `NSStatusItemSpacing`/`SelectionPadding` — the same global pref Bartender writes; running items pick it up on relaunch |
| Spacer / label items in the bar | roadmap | yes | Done | Our own status items as spacers/labels/emoji — click reveals the run |
| Menu bar tint, gradient, shadow, border, rounded | yes | yes (incl. themed bar) | Done (cover tint/material/rounding + full-bar underlay) | Underlay panel at `statusBar - 1` |
| Profiles (named bar layouts) | roadmap | yes | Done | Trigger-switchable; per-display override follows the pointer's screen |
| Triggers (unplug → show battery, VPN on public Wi-Fi, mic in meetings…) | partial (roadmap) | yes | Done (lock/unlock/app/time/charger/Wi-Fi/mic/Focus) | `CWEventType.ssidDidChange`, AVCaptureDevice mic poll, Focus DB watch |
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

## Aquarium, Notch Buddy, Confetti

No rival app; measured against the idle-game bar set in the Toys contract
(docs/TOYS.md) instead. Step 3 covers the Aquarium rebuild.

## How rows change state

A row moves to **Done** in the same commit that lands the feature and its
test. A row moves to **Won't** only with a reason someone could argue
with. Nobody edits a rival's column from memory; cite the release note or
README that says the feature exists.
