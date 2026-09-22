# JR-Bar systems audit — 2026-09-21

Six parallel subsystem audits plus live verification on the owner's Mac.
Goal restated: replace **Alcove** (notch island), **Dock Door** (dock
previews/switcher), **CodexBar** (usage meters), **Bartender/Ice** (menu bar),
while the toys stay fun. Scale: ~69k lines of Swift, ~197k lines of Python
daemon, 653 Swift tests + 3,587 pytest cases (3,584 passing after this
session's contract fix — see below).

---

## Verified live tonight (menu-bar concealment chain)

The saga from earlier sessions is now closed, end-to-end, on the installed
notarized build:

- Foreign `jrbar-asserter` spawned with
  `responsibility_spawnattrs_setdisclaim` holds the assertion; our icon
  stays visible; 7 apps concealed.
- Slim anchor (28 pt) holds the ~34 pt notch niche; 39 pt restored when
  concealment stops.
- Position seeds now `synchronize()` before registration and re-seat
  names overwrite — the buffered-write race that parked every re-seat is
  gone.
- The parked oracle is frame-first: off-row AX → parked; drawn-vs-AX
  drift → parked; on-row under our own windows → not parked (the island
  face legitimately owns those pixels); pixel capture only arbitrates
  uncovered slots. Steady state logs `parked=false iconStale=false`,
  zero churn.
- `terminate()` = stdin EOF + SIGKILL + reap. Exactly one asserter alive;
  the 7-process accumulation is dead (SIGTERM inherits the app's ignored
  disposition).

Also fixed during the audit: `MenuBarUtility.swift` `hotFrames` returned
the « control's Quartz frame unconverted for the spacer engine, so
hover-reveal on it never fired (AppKit `mouseLocation` never matches).
And the packaging contract suite: the asserter now rides the
`APP_BUILD_SCRIPT` seam instead of a bare `cd $ROOT_DIR/app` — the three
`test_app_bundle_security.py` failures are green again.

---

## Menu Bar vs Bartender/Ice — ahead on machinery, behind on edges

**Ahead of parity**: three-section model (shown/hidden/always-hidden),
two engines (spacer + macOS-27 assessment concealer), ⌘-drag with LCS
minimal-move replay, two reveal styles (Item Bar panel + inline reflow),
⌘⇧K fuzzy command palette, profiles, per-display auto-profiles, triggers
(battery/Wi-Fi/lock/app-activation/time/mic/Focus + shell-script action),
show-for-updates, spacing presets, cover material/tint/roundness/
separator paint, combined system item (battery/Wi-Fi/Focus + popover),
custom spacers, external-provider delegation (bartender/ice/hiddenBar),
system-item click bridge that lifts the assertion for clock/battery.

**Fixable gaps found**
1. `combinedStatusItem` is a dead setting — persisted, decoded, captured
   by profiles, consumed by nothing (live feature is
   `combinedSystemItem`). `MenuBarUtility.swift`/`MenuBarProfiles.swift`.
2. `toggleReveal` hotkey never re-hides — reveal-only despite the name.
3. Profiles capture only sections + appearance — not revealStyle,
   rehideSeconds, spacing, spacers, triggers, hotkeys.
4. "Show until clicked elsewhere" is timed only (`rehideSeconds`), not
   click-scoped.
5. `hotkeyBindings.failedActions` recorded but never surfaced in UI.
6. System-click bridge silently dead without Accessibility — needs a UI
   surface, not just a log line.
7. Spacing = 4 presets; no arbitrary value / true no-gap.
8. Item Bar tiles aren't draggable into sections; no per-item context
   menu on tiles.
9. No icon display modes (can't hide/replace the JR-Bar boundary glyph;
   Ice's no-icon mode absent).
10. Always-hidden has no dedicated reveal gesture.

## Dock vs Dock Door — feature-complete for stills, deliberately not live

**Ahead**: AX hover tracking with rest-delay/grace, preview panel
pre-warmed off-screen, per-window close/minimize/fullscreen + middle-click
+ ⌘ verbs, click-to-focus (un-minimizes), ⌥⇥ switcher with fuzzy
type-ahead + ⌘⇥ app mode + drill-down, badge counts, Folder Pop, Now
Playing transport row, Calendar next-event row, ⌘-right-click quit /
⌘⌥ force-quit, Aero shake, trackpad flick minimize, Tile-To, dock
auto-hide hold with crash-recovery marker, per-app exclusions.

**Gaps**
1. Thumbnails are 30 s stills — no SCStream (deliberate: avoids the
   persistent recording indicator). Windows opened/closed while the panel
   is up don't refresh.
2. **Bug**: magnification anchor re-centers on `pointer.x` — correct for
   bottom Dock, wrong axis for left/right Docks (`DockEnhance.swift:1108`).
3. Switcher panel lacks `.fullScreenAuxiliary` — may not appear over
   fullscreen spaces (`DockSwitcher.swift:928` vs `DockEnhancePanel.swift:128`).
4. Worst-case first-hover ~500 ms (4 Hz far-poll + delay + tick).
5. Preview keyboard walk only while pointer is inside the panel.
6. Dead `previewOpen`/`onPreviewKey` tap surface (`DockSwitcher.swift:334`).
7. No panel styling/position/size options beyond the Large-cards toggle.
8. Minimized-window Dock tiles and Trash get no previews.
9. ⌘⇥ session tap may lose to WindowServer on some macOS builds —
   unverified, off by default.

## Notch island vs Alcove — deep, a few indicator gaps

**Ahead/equal**: island lifecycle (idle/capsule/card), hover wink,
pull-flick morph at 120 Hz spring substeps, capsule queue with priority
eviction, notch-less floating pill, MediaRemote now-playing + transport +
scrub + artwork (perl-helper entitlement fallback, SHA-pinned dylib),
six-band audio visualizer (AudioHardwareCreateProcessTap + Goertzel),
LRCLIB synced lyrics, shelf/tray model (stacks, .webloc/.txt drop
materialization, AirDrop-send, Quick Look, shake-to-summon), battery
charging capsules, weather (Open-Meteo keyless + ipapi fallback), calendar
+ reminders models, quick toggles, media-key HUD replacement, Screen Bar
band phase-locked to the LED program + island silhouette coupling +
ear-wing gestures, Alcove-capsule follower for coexistence.

**Gaps**
1. No active camera/mic indicator in the island (mic detection exists as
   a menu-bar trigger; not surfaced).
2. System notifications arrive as HUD pills *under* the notch, not in the
   island.
3. No pinch/squeeze gesture (pull-flick only).
4. No inbound AirDrop progress capsule.
5. MediaRemote helper path unverified at runtime; weather/EventKit
   models untested at the seam.

## Usage meters vs CodexBar — strong spine, shallow edges

**Ahead**: 9 first-party collectors (claude OAuth endpoint, codex
rollout+app-server merge, gemini, grok, devin, antigravity, opencode,
cursor, openai-api), failure-typed readings, adaptive refresh ladder
(idle 30 min → menu-open 2 min), least-squares forecast with
pace/exhausts_at, 7d–365d token/cost history + sparkline, Usage Center
rings + combined card + forecast, Overview multi-provider chart + heatmap,
quota-crossed/reset events → banners + confetti, per-instance plumbing.

**Gaps**
1. `meteredProviders` (`AppDelegate.swift:1254`) returns *only* the
   preferred list when non-empty — daemon default is `("claude","codex")`,
   so a Gemini/Grok/Devin-only user gets an empty meter strip; docstring
   claims otherwise; untested.
2. Multi-account ForEach identity collision — `CoreProviderUsage.id` is
   the raw provider id; two accounts of one provider duplicate keys in
   `UsageCenterView`/`PanelStore`.
3. No menu-open refresh signal from the Swift app — meters can sit at
   the 30-min idle cadence while CodexBar refreshes on open.
4. `quota_alerts_enabled` gate asymmetric: daemon default false, app gate
   defaults true — banners can fire before settings land.
5. No add-account UI; second instances materialize only via hand-edited
   `source_instance_id`.
6. Widget pipeline is dead — snapshot writer + decoder exist, no
   extension target.
7. Token/cost history is Claude/Codex-only (transcript scans);
   percent-history covers all providers.

## Toys — expansive and well-tested; small honesty leaks

- **Aquarium** (~7k app + ~2.7k core lines): sessions→fish with fry,
  completion corkscrews dropping edible meals, pearl economy, growth/
  starvation (never kills), 48-item shop, levels/streaks/goals/16
  achievements, 3 visitor triggers, buried treasure, tap-to-feed,
  inspector + Open-session link, day/night, Reduce-Motion heartbeat.
  Findings: `away.feedings`/`away.dropsCollected` are unreachable
  (`windowOpen == isOn` always); "off" still mutates+persists the game
  doc (comment lies, behavior is load-bearing for the away panel);
  disk writes from inside the Canvas draw closure; 5.4k-line view file.
- **Notch Buddy**: 10 characters, moods/asks/petting/roaming/naming —
  but docked it's always `MiniFigure`, a 7-pt dot. The entire character
  roster is floating-only; the signature feature hides behind an
  undiscoverable drag-out. Consider a docked-size character.
- **Fold**: HID lid-angle sensor (two-rate poll), dual SCK capture,
  Metal portal renderer, slew-limited tracker, arming band so capture
  only lives while a fold is plausible. Hardware-gated by design.
- **Confetti**: trigger policy pure + dedup ring + edge tracker; physics
  closed-form; three landing modes. Single-screen only.
- `docs/TOYS.md` drift: still specifies removed external-app toys;
  stale defaults (jitter 0 vs shipped 1.5) and stale blurbs.

## Platform — hardened packaging, hygiene debt around it

**Solid**: fail-closed packaging pipeline (identity ladder, entitlement +
rpath + dependency + symlink verification, hash-locked Python inputs,
seam-able tools), setup walkthrough with honest permission probes,
notification permission lazily requested, single-instance flock, daemon
supervision with backoff, settings pending-overlay with clamp reporting,
contract tests for the whole packaging script.

**Debt**
1. **202 uncommitted files** (~14k insertions) — the whole concealment
   engine + Data Hoarder + Overview graph work sits dirty on top of
   `8b8f09f` (2026-09-19). Release artifacts in `dist/` are stamped
   `-dirty`; no `v0.9.9` tag exists. `publish_release.sh` would refuse
   this tree.
2. **No GitHub release has ever been published** — the Sparkle appcast
   is signed but the feed URL 404s until a release exists; auto-update
   is configured dead.
3. **PKG unsigned** — no Developer ID Installer identity; app inside is
   stapled but the PKG itself carries no ticket (cannot be notarized).
4. `status_bar_legacy.py` is **19,840 lines of load-bearing production
   code** misnamed "legacy"; ~24k lines of dormant PyObjC UI still ship
   inside the notarized daemon.
5. ~20 orphaned `lid-hold-renewal` watchdog loops accumulate — each
   daemon lifetime leaves one, and a fresh renewal marker means they
   never see staleness. ~1 MB of sleeping shells; cosmetic but real.
6. Setup covers 5 of ~9 TCC surfaces — missing Reminders, Camera,
   Bluetooth, audio capture, and the separate INFocusStatusCenter grant
   (FDA row claims it buys Focus sync — it doesn't).
7. `menu_bar_icon_style` setting: daemon accepts with `ok` and never
   applies.
8. CI `macos` job still `continue-on-error: true` ("flip after first
   clean run" — never flipped).
9. Stale docs: README references `dist/JR-Bar-0.8.0.pkg` + misassigns
   Screen Recording to Alcove-following (it's Fold); FEATURE-MATRIX is
   titled 0.8.0 and lacks Toys/Utilities/Aquarium/Buddy/Fold/Hoarder;
   ROADMAP still claims the PKG can't be distributed.
10. Stray `1/` empty dir at root; `.jrbar-verification/` is 483 MB.
11. `src/sidepulse/` transitional shim overdue ("one release" — still
    here at 0.9.9).

---

## Prioritized list

**P0 — commit the tree.** Everything shipped/experimental sits uncommitted;
a bad edit loses the concealment work. Then tag `v0.9.9` and cut the first
GitHub release so Sparkle has something to serve.

**P1 — quick correctness wins (all evidence-backed):**
- `meteredProviders` empty-default + dedup bug (meters invisible for
  non-Claude/Codex users).
- Dock side-dock magnification anchor axis.
- Switcher `.fullScreenAuxiliary`.
- `toggleReveal` semantics; dead `combinedStatusItem`; surface
  `failedActions`.
- `menu_bar_icon_style` write goes nowhere — wire or remove.
- Aquarium away-counters dead; buddy docked-character discoverability.
- Lid-hold watchdog accumulation (pid-file or startup reclaim).

**P2 — parity gaps worth building:**
- Menu-open refresh trigger for usage surfaces (protocol command).
- In-island mic/camera indicators (infra exists).
- Add-account UX for provider instances.
- Custom spacing values; icon display modes; until-click temp-show;
  per-item Item-Bar context menu; always-hidden dedicated gesture.
- Live dock thumbnails (opt-in, behind the purple-indicator tradeoff).

**P3 — hygiene:**
- `status_bar_legacy.py` rename or split (it's the daemon's controller).
- Dormant PyObjC UI: retire or officially keep; 24k lines ride every
  notarized build.
- Setup rows for Reminders/Camera/BT/audio/FocusStatus.
- CI `continue-on-error` flip; README/FEATURE-MATRIX refresh; delete `1/`.
- Developer ID Installer identity → signed + notarized PKG.

**Verified this session:** 653 Swift tests + 3,584/3,587 pytest pass;
packaged, Developer-ID signed, notarized, stapled, installed; concealment
steady-state healthy under the island.
