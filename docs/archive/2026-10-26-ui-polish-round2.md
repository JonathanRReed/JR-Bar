# JR-Bar 0.10.0 polish round 2

Started at `db3cfe62ad8d3a344e390ce9dceb54f2dc62ed00` on `t3/18cdb3f5`.
This round changes layout, display labels and accessibility. The notch implementation is unchanged. Its shared gauge keeps the 64 pt default, and notch cards keep the existing disclosure style.

Proofs and logs are under `/tmp/jrbar-polish-round2-db3cfe62`. In the paths below, `before3303` means `/Users/jonathanreed/Library/Logs/JR-Bar/interim-3303-20261026`, `before1` means `/tmp/jrbar-polish-round1-7586e615/after`, and `after` means `/tmp/jrbar-polish-round2-db3cfe62/after`.

## Fixed findings

1. Overview keeps the provider name and logo when quota availability is `absent`. Every row button has an explicit accessible name. Providers without a logo use the shared fallback mark. The tests cover all catalogue IDs, registered providers and an unknown fallback sample, 109 IDs in total, across absent, ready and not-found states. The absent cases also check pixels inside the mark.

   Before: `before3303/usage-overview.png`, `before3303/usage-overview-history.png`.
   After: `after/round2-overview-table-light.png`, `after/round2-overview-table-dark.png`, and `after/round2-provider-catalogue-0-light.png` through `after/round2-provider-catalogue-4-dark.png`.

2. Overview quota headers use at most two complete lines. The column width comes from the longest rendered line, and the header tooltip retains the full window name and "used". Gauge columns use that same width. Tests cover Fable and the longer Gemini and Claude window names without changing the default gauge layout elsewhere.

   Before: `before3303/usage-overview.png`.
   After: `after/round2-window-headers-light.png`, `after/round2-window-headers-dark.png`, `after/round2-overview-table-light.png`.

3. Changing provider recreates the detail scroll view at the top. A test scrolls Overview to 400 pt, selects Codex and checks the new scroll position. Native window captures repeat the switch at 980 × 720, with a real synthetic quota reading so Codex's header is visible.

   Before: `before3303/usage-codex.png`.
   After: `after/round2-switch-after-light.png`, `after/round2-switch-after-dark.png`. The preceding scrolled Overview is in `after/round2-switch-before-light.png` and its dark counterpart.

4. Devices' full-screen picker uses the shared labeled row and keeps its intrinsic width. Its choices are Hidden, Except video and Always. Shortening the text alone still produced "Ex…" in the narrow proof; the row layout fixes that too.

   Before: `before3303/settings-devices-bottom.png`.
   After: `after/round2-screen-bar-settings-light.png`, `after/round2-screen-bar-settings-dark.png`. These use a 549 pt pane, narrower than the default Settings detail pane. The intermediate failure is preserved at `/tmp/jrbar-polish-round2-db3cfe62/intermediate-picker-truncation-light.png`.

5. Inner toy disclosures become visible sections inside Settings. Aquarium Fine-tune, Confetti Adjust, Dock options and exclusions, and Menu Bar extras, overrides, advanced controls and profile editors no longer add another expansion step. The notch retains its existing presentation. Confetti's two 12 pt corner literals now use the matching group radius token.

   Before: `before1/u3-detail-confetti-scroll-1-light.png`, `before1/u3-detail-dock-scroll-1-light.png`.
   After: `after/u3-detail-confetti-scroll-1-light.png`, `after/u3-detail-aquarium-scroll-1-light.png`, `after/u3-detail-dock-scroll-1-light.png`, `after/u3-detail-menuBar-scroll-2-light.png`, with dark counterparts.

6. Remaining display labels use sentence case: Get started, Open toys, Menu bar app, Run setup again…, Show a demo ask and Blend in. Commands and saved values are unchanged.

   Before: `before1/setup-1-welcome-light.png`, `before1/setup-6-done-light.png`, `before1/palette-query-light.png`, `before1/u3-advanced-light.png`, `before1/u3-agents-scroll-1-light.png`, `before1/u3-detail-menuBar-scroll-2-light.png`.
   After: the same filenames under `after`.

7. The live Settings check found the Focus Rule checkbox wrapping its word into separate lines at the preserved window width. It now keeps its intrinsic size.

   Before: observed in installed build 3303 through Computer Use. The existing row capture is `before1/u3-alerts-scroll-1-light.png`; that wider capture does not reproduce the live wrapping.
   After: `after/round2-focus-rules-light.png`, `after/round2-focus-rules-dark.png`, at a 549 pt pane width.

## Verification

- Full Swift suite, serial, with `JRBAR_INTERACTIVE_TESTS` unset: 6,092 reported tests passed. The final log is `swift-final.log`. The 0.9.17.2 notch parity suite passed. All 43 checked notch implementation files match the base revision.
- Full Python suite with one worker: 15,901 tests and 15 subtests passed, with four existing multiprocessing deprecation warnings. See `python-serial-final.log`. The preceding four-worker run passed 15,900 tests but lost one worker to a segmentation fault in the WASM firmware parser. Its three isolated keyframe cases also passed. No Python or firmware source changed in this round.
- The fast gate passed after the final picker change, including lint, contracts, fixtures, documentation links and diff hygiene. See `fast-verified.log`.
- Design token guard: 1,122 allowances reduced to 1,120, zero errors, no new exceptions.
- All 729 final PNGs were opened through contact sheets, with full-size checks for the reported defects. The manifest and hashes are in `final-image-hashes.json`; source hashes are in `final-source-hashes.json`.
- The final focused layout run passed four tests in three suites. The expanded window and dialog run passed 30 tests in 13 suites. See `final-layout.log` and `remaining-matrix.log`.
- The temporary `JRBarPolishProof.app` was deleted. See `helper-cleanup.json`.

The sweep covers Panel at 320 and 372 pt; Settings pages, details and scroll positions in the normal titled window; Usage Center content and native 980 × 720 windows; Studio pages, inspectors and assignment dialogs; History activity and events; Setup; What's New; palette; Control Center; Dock previews; switcher; Item Bar; provider sign-in and credential dialogs; firmware dialogs; login-item states; Keep Awake; Aquarium, its inspector and shop; and shared components in both appearances. Additional component captures cover contrast, reduced transparency, reduced motion and fixture hover/focus states. The shop's long captures were also inspected in overlapping viewport-sized crops.

## Settings title bar and proof limits

Settings scrolling was checked live in installed build 3303 through Computer Use. Native blur kept the title readable while rows passed beneath it. Window chrome is unchanged. Settings was returned to General and closed without editing a setting.

Offscreen cache captures can show sharp rows behind Settings' title bar and black selected segments in Usage Center's native toolbar. Those captures establish content layout and scroll position; they do not qualify native material compositing. The supplied build 3303 screenshots show the unchanged toolbar drawing normally.

The first broad render run lacked Studio's `daemon-programs.json` and stalled waiting for History's mock Events reply. Studio was rerendered with round 1's synthetic fixture, and History's activity and Events views were captured with detached synthetic rows. These are local source and render checks. They do not establish a new installed build, physical input traversal, hardware operation or release qualification.

## Code commits

- `f6aca3a5` settings: flatten toy groups and keep controls readable
- `25bc699d` usage: keep provider identities and reset provider scrolling
- `beabd052` ui: finish sentence case in setup and the palette

## Release bullets

- Usage Center keeps every provider visible and starts each detail view at the top.
- Long quota names and full-screen choices stay readable.
- Toy controls have one expansion level in Settings.
- Setup and palette labels use sentence case.
