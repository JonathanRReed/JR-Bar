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
| Simulated notch toggle on notch-less Macs | yes (1.7.1) | sizing options | Planned (step 5) | |
| Now Playing: artwork, title/artist, transport | yes | yes | Done | perl-hosted MediaRemote helper |
| Now Playing: waveform/visualizer | yes (iOS-matched) | yes | Done (3 bars) | Upgrade to iOS-style waveform in step 5 |
| Now Playing: scrubbing, lyrics | yes / no | scrub yes | Planned (scrub, step 5) | Lyrics: Won't, needs a lyrics service |
| Audio format badge (Lossless/Atmos) | yes | no | Won't | Private API surface, low value |
| Charging / on battery / full capsule | yes | yes | Done | `AlcovePower` |
| Battery % in card | yes | yes | Done | |
| AirPods / Bluetooth connect capsule (with battery) | yes | roadmap | Planned (step 5) | IOBluetooth + `BatteryMonitor` pattern |
| Volume / brightness / keyboard-backlight HUD replacement | yes | yes | Planned (step 5) | CGEventTap on media keys or `NSEvent` system-defined events; must hide Apple's HUD (private `OSDUIHelper` kill) or accept both |
| Caps Lock indicator | yes | no | Planned (step 5) | |
| Focus mode change capsule | yes | no | Planned (step 5) | Read `~/Library/DoNotDisturb/DB/Assertions.json` |
| Display connect / disconnect capsule | yes | no | Planned (step 5) | `NSApplication.didChangeScreenParameters` |
| Screen recording indicator capsule | yes | no | Planned (step 5) | |
| Notification banners mirrored into the island | yes | under consideration | Won't | Needs private notification-center hooks; Alcove's own FAQ says these can break any release |
| Calendar: next event, join link | yes | yes | Done | EventKit, "Show calendar" grant |
| Reminders | no | yes | Planned (step 5) | EventKit reminders |
| Weather | yes | roadmap | Planned (step 5) | WeatherKit needs an entitlement; fall back to Open-Meteo, off by default |
| Timers / Pomodoro | via Live Activities | no | Done (timers) | Hide row when empty (step 1) |
| Shelf / file drop with AirDrop | no (Drop in 1.6) | yes | Done (tray) | AirDrop button: Planned (step 5) via `NSSharingService` |
| Mirror (camera preview) | no | yes | Planned (step 5) | AVFoundation, permission-gated |
| Swipe gestures on the island | yes | yes | Done | |
| Lock-screen widgets / mode | yes | roadmap | Won't | JR-Bar can't draw over the lock screen without private APIs |
| Duo mode (two islands) | yes (1.7) | no | Won't | Nothing in JR-Bar needs a second island |
| Agent sessions, asks, usage meters in the island | no | no | Done | The reason the toy exists |
| Screen Bar LED strip across the island | no | no | Done | |
| Menu bar icon hidden | Tahoe native | yes | Done | System setting, documented |
| Sound effects on capsule events | yes | yes | Planned (step 5) | Off by default |
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
| Pause-at-angle timeout (desktop returns after N s at rest) | no | no | yes (1–5 s) | Planned (step 2) | Off by default; Apple's Duo doesn't do it, but it stops a half-closed lid from being useless |
| Return-to-normal click sound | yes (0.3) | no | no | Planned (step 2) | Off by default |
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
| Hover a Dock icon → live window previews | yes | Done | AX hit-test of the Dock's `AXList`, `SCScreenshotManager` one-shots per window — no stream, no purple indicator |
| Click preview to raise, close / minimise / maximise buttons | yes | Done (raise, close ×, minimise/restore –) / Won't (maximise — a zoom button on a thumbnail is a mis-click magnet) | `AXRaise`/`AXMain`/`activateAllWindows` on click; `AXCloseButton` press; `AXMinimized` write |
| Middle-click to close | yes | Planned (P2) | |
| Drag a window between previews / to another app | yes | Planned (P2) | |
| Aero shake (shake a preview to minimise the rest) | yes | Planned (P5) | |
| Close-all / minimise-all from the app preview | yes | Done (Hide, Quit in the header) / Planned (minimise-all, P2) | |
| Compact list view past N windows | yes | Planned (P2) | |
| Large preview option | yes | Done | 208×130 cards |
| Folder Pop: hover a Dock folder → contents, sort, open | yes | Planned (P4) | |
| Option+Tab window switcher with previews and keyboard control | yes | Planned (P3) | Global hotkey via `CGEventTap` (Accessibility) |
| Cmd+Tab replacement overlay | yes | Planned (P3) | Same tap; off by default, it's aggressive |
| Trackpad gestures on previews (swipe to minimise/maximise) | yes | Planned (P5) | |
| Media widget on hover over Music/Spotify | yes | Planned (P5) | Reuse the Notch media helper |
| Synced lyrics | yes | Won't | Needs a lyrics service, local-only app |
| Calendar widget on hover over Calendar | yes | Planned (P5) | Reuse the Notch calendar row |
| Quick quit ⌘+right-click, force quit ⌘⌥ | yes | Planned (P2) | |
| App filters (hide apps from previews) | yes | Planned (P2) | |
| Dock locking to one display | yes | Planned (P5) | |
| Preview layouts / appearance settings | yes | Done (glass, card size, every-window toggle) | Glass per the material rule: previews float, so glass |
| AppleScript: show preview / show switcher | yes | Won't for now | Revisit if anyone asks |
| Localisation | yes | Won't for now | |

## Menu Bar (vs Ice, Bartender 7)

Ice is GPL-3 — clean-room, like DockDoor. Bartender 7's feature list is the
parity bar; "Pro" extras (Top Shelf) are called out where they're separate.

| Feature | Ice | Bartender 7 | JR-Bar Menu Bar | Notes |
| --- | --- | --- | --- | --- |
| Hide menu bar items (separator section) | yes | yes | Done | The chevron is the separator; its own `length` grows to push the run left of it into macOS 26's native overflow (the only push the OS allows — see docs/UTILITIES.md) |
| Always-hidden section | yes | yes | Done | |
| Show hidden on hover over menu bar | yes | yes | Done | |
| Show hidden on empty-space click | yes | yes | Done | |
| Show hidden on scroll/swipe | yes | yes | Done | |
| Auto-rehide after N s | yes | yes | Done | |
| Hide app menus when they overlap items | yes | yes | Planned (phase 2) | |
| Drag-and-drop arrange | yes | yes | Done (explicit arrange mode) | ⌘-drag `CGEvent`s on the real items, AX-gated, banner + Esc cancel; never in the background |
| Hidden items in a separate bar (Ice Bar / Bartender Bar) | yes | yes (Liquid Glass) | Done | The "Item Bar" — glass, floats under the menu bar; live `SCScreenshotManager` tiles with icon fallback |
| Search menu bar items | yes | yes (Command Bar + clipboard history) | Done (⌘⇧K) | Clipboard history: Won't — a second product |
| Item spacing control | yes (beta) | yes (3 presets + custom) | Planned | Best-effort; macOS can refuse per item |
| Spacer / label items in the bar | roadmap | yes | Planned | Our own status items as spacers/labels/emoji |
| Menu bar tint, gradient, shadow, border, rounded | yes | yes (incl. themed bar) | Done (cover tint/material/rounding) / Planned (full-bar underlay) | Underlay panel at `statusBar - 1` |
| Profiles (named bar layouts) | roadmap | yes | Done | Trigger-switchable; per-display override Planned |
| Triggers (unplug → show battery, VPN on public Wi-Fi, mic in meetings…) | partial (roadmap) | yes | Done (lock/unlock/app/time/charger) | Wi-Fi/mic/Focus triggers Planned |
| Hotkeys for sections / bar / search | yes | yes | Done | Carbon `RegisterEventHotKey`, same as panel hotkey |
| AppleScript / Shortcuts / Siri control | no | yes | Won't for now | Revisit if asked |
| Custom menu bar widgets (scripts, data sources) | roadmap | yes | Won't | Third-party code in our process; a whole ecosystem |
| Menu bar widgets (clock/stats built-ins) | roadmap | yes | Planned | Covered by the combined Status item |
| **Combined system item replacing Apple's Battery/Wi-Fi/BT/Sound/Focus** | no | no | Planned | Where we beat them — `com.apple.controlcenter` visibility defaults, save + restore, Fold/Strip/Agent/Text variants, one popover |
| Agent state in the bar item (usage arc, session dots) | no | no | Planned | Where we beat them |
| Notch-aware hiding (items under the notch → hidden) | partial | yes ("Beat the notch") | Planned | `ScreenBarGeometry.slotWidth` |
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
