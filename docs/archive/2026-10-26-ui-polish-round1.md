# JR-Bar 0.10.0 polish round 1

Started at `7586e615ec4da66f5556bb1c5114a68de6c047d3` on `t3/1c69da40`.

The notch implementation and its parity tests are unchanged. This round changes layout, styling and display text. It adds no commands or features.

## Fixed findings

1. Settings groups supply the standard 8 pt vertical and 12 pt horizontal insets, including bare controls and custom rows. Rows that already use the shared inset modifier keep one set of padding.

   Before: `/tmp/jrbar-polish-round1-7586e615/before/u3-advanced-dark.png`
   After: `/tmp/jrbar-polish-round1-7586e615/after/u3-advanced-dark.png`

2. Release channel and Alerts profile use the shared labeled row. Pickers sit at the trailing edge, and Balanced is no longer truncated.

   Before: `/tmp/jrbar-polish-round1-7586e615/before/u3-alerts-light.png`
   After: `/tmp/jrbar-polish-round1-7586e615/after/u3-alerts-light.png`

3. Settings separators stop 12 pt from both edges. The same group component serves Settings and Studio.

   Before: `/tmp/jrbar-polish-round1-7586e615/before/u3-general-dark.png`
   After: `/tmp/jrbar-polish-round1-7586e615/after/u3-general-dark.png`

4. Older Settings labels use the body and caption tokens. Disclosure hover feedback uses the quick motion token.

   Before: `/tmp/jrbar-polish-round1-7586e615/before/u3-alerts-advanced-dark.png`
   After: `/tmp/jrbar-polish-round1-7586e615/after/u3-alerts-advanced-dark.png`

5. Panel usage rows have enough height for their gauges, stale age and recovery buttons. Normal, stale and action rows reserve 56, 64 and 88 pt. A layout test checks both panel widths.

   Before: `/tmp/jrbar-polish-round1-7586e615/before/panel-failure-320-light.png`
   After: `/tmp/jrbar-polish-round1-7586e615/after/panel-failure-320-light.png`

6. The panel editor uses provider display names while preserving account labels such as Claude Work.

   Before: `/tmp/jrbar-polish-round1-7586e615/before/panel-edit-accounts-372-light.png`
   After: `/tmp/jrbar-polish-round1-7586e615/after/panel-edit-accounts-372-light.png`

7. An empty panel says how to get a session. When an ask is already present, it says No other recent sessions.

   Before: `/tmp/jrbar-polish-round1-7586e615/before/panel-empty-320-dark.png`
   After: `/tmp/jrbar-polish-round1-7586e615/after/panel-empty-320-dark.png`

8. Palette actions, headings, toggle names and durations use sentence case. Action IDs and commands are unchanged.

   Before: `/tmp/jrbar-polish-round1-7586e615/before/palette-actions-light.png`
   After: `/tmp/jrbar-polish-round1-7586e615/after/palette-actions-light.png`

9. Creator Micro key and dial captions use type tokens. Key numbers have stronger contrast, and the pad uses the existing radius tokens.

   Before: `/tmp/jrbar-polish-round1-7586e615/before/control-center-light.png`
   After: `/tmp/jrbar-polish-round1-7586e615/after/control-center-light.png`

## Verification

- Full Swift suite, serial: 6,083 tests passed. `JRBAR_INTERACTIVE_TESTS` was unset. The 0.9.17.2 notch parity suite passed.
- Full Python suite: 15,886 tests and 15 subtests passed with four workers. Four existing multiprocessing deprecation warnings remain.
- The first Python run saw a retired Settings animation allowance before the baseline was pruned. The final complete run passed.
- Fast verification gate passed, including lint, imports, contracts and documentation links.
- Design literal guard: 1,143 allowances reduced to 1,122, with zero errors and no new exceptions.
- Broad render matrix: 24 tests in 11 suites passed. Final Settings recheck: one test passed after the picker adjustments.
- Inspected all 454 baseline PNGs and all 550 resulting PNGs through contact sheets, with full-size checks for the reported defects. Settings captures include 114 images across pages, details and scroll positions in the normal titled window.
- Panel fixtures cover 372 and 320 pt in light and dark. The matrix also covers Studio pages, Usage Center states and charts, Setup, What's New, alerts, HUDs, Shelf, Dock previews, switcher, palette, Control Center and toy settings. Extra foundation captures cover contrast, reduced transparency, reduced motion, hover and focus.

Logs, source hashes, image manifests and PNGs are under `/tmp/jrbar-polish-round1-7586e615`. The proof host pinned blue before AppKit initialized. Both temporary helper apps were deleted after rendering.

## Later round and proof limits

- Older styling remains in the 1,122 guarded allowances, including the protected notch. This round does not claim a complete token migration.
- Setup still has title-case buttons such as Get Started and Open Toys. The palette's Menu Bar App kind tag also needs sentence case.
- Scrolled Settings proofs show text behind the unified title bar, for example `/tmp/jrbar-polish-round1-7586e615/after/u3-alerts-scroll-1-light.png`. Confirm this in the running app before changing window chrome. These captures move the offscreen scroll view directly.
- Hover and focus evidence uses fixtures. Live pointer interaction and keyboard traversal were not exercised. Some nested toy disclosures remain collapsed in the page fixtures.
- These are local source and render checks. They do not establish installed-app, hardware or release qualification.

## Release bullets

- Settings groups keep text and controls inside their rounded edges.
- Panel quota rows leave room for stale readings and recovery actions.
- Provider names, palette labels and Creator Micro captions are easier to read.

## Code commits

- `47d494da` settings: keep grouped rows inside their edges
- `104c43d7` panel: leave room for quota rows and recovery actions
- `c3a696d6` creator-micro: use readable captions and shared radii
- `e2525768` palette: use sentence case for actions and durations
- `cc70fbc2` tests: capture active windows and scrolled settings pages
