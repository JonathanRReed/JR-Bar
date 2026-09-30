# JR-Bar audit and release preparation, 2026-09-26

The source changes are on `main`, with version 0.9.10 prepared. Release
publication remains gated by packaging, signing, performance and physical
acceptance checks. This audit does not certify the installed app.

## Scope and branch decisions

The priorities were Fold's resting-angle mode, provider-reset confetti, and
retaining useful repairs before consolidating the branches.

- The seven performance branches were already integrated into `main`.
  The archive branch had the same source tree as the merged PR #13.
- [PR #14](https://github.com/JonathanRReed/JR-Bar/pull/14) was integrated
  with its history, including capture ownership, menu placement, manual
  Keep Awake state, Aquarium accounting and archive reads.
- The alternate utility lifecycle branch supplied useful scan invalidation,
  callback ownership and pending-command guards. Its competing placement
  and drag implementations were not retained.
- Older architecture and transport branches were archived. No transport
  workflows or encoded repair payloads were added to `main`.
- Only `main` remains locally and on origin. Nine unused worktrees, nine
  local branches and 22 remote branches were retired. All branch tips and
  their complete histories were preserved in a verified local Git bundle.
  The untracked daemon worktree environment symlink was preserved too.

The recovery bundle and verification receipts live in the ignored
`.jrbar-verification/audit-20260926/` directory.

## Repairs

- [Fold](../../../app/Sources/JRBarApp/Toys/Fold/FoldToy.swift) seeds a
  changed anchor mode from the parked reading before a sensor or simulation
  update replaces it. Repeated reconciles keep a live fold's reference.
  Tests cover the first close after switching modes and returning from a
  previously used movement reference.
- [CoreModel](../../../app/Sources/JRBarCore/CoreModel.swift) deduplicates
  events by cursor, with a stream-scoped fallback. A new daemon's `ev-1`
  can no longer collide with the previous daemon's event.
- [CoreServer](../../../src/jrbar/core_server.py) sends retained quota
  resets less than five minutes old after its initial documents. Original
  cursors prevent duplicate delivery. Other event kinds, expired resets,
  future timestamps and oversize frames are excluded. Recovery uses the
  current daemon's bounded journal, which does not survive a daemon restart.
- Menu-bar scans reject cancelled reads and obsolete display geometry.
  Retired concealers cannot publish callbacks. A refused system click
  bridge releases concealment and uses spacers, with a 30-second retry gap.
- Keep Awake rejects repeated commands while a manual-session change is
  pending. Cancelled holder reads cannot update the card.
- Version metadata, release notes and What's New were updated to 0.9.10.
  Lyrics requests now read their version from the app bundle.

Confetti still follows its switches and quiet/fullscreen rules. Weekly
resets use the weekly trigger; shorter windows require a selected provider
trigger. These repairs do not enable a toy or override a person's settings.

## Verification

| Check | Result |
| --- | --- |
| `make fast` | Passed, including lint, secret scanning, contracts, doc links and focused tests |
| `.venv/bin/python -m pytest tests -q` | 4,272 passed and 17 subtests passed; four existing multiprocessing fork warnings |
| `cd app && swift test` | All four targets passed, 3,567 tests total on the committed source |
| Final changed-path Swift checks | Passed for Fold, lyrics, reconnects, confetti and What's New |
| Final Python reset and release checks | 25 passed, including reset expiry and oversize-frame handling |
| Fold, confetti and menu-drag render proofs | 66 tests passed; 154 PNGs opened and visually reviewed |
| Wheel and source archive build, Twine | Passed for 0.9.10 |
| Fresh wheel installation | Passed, using temporary state directories |
| Local native development bundle | Built and signature verification passed; no bundled daemon or Sparkle |
| `make release-check` | Passed; no release was published |
| Release preflight | Ran successfully and reported the blockers below |

The new CoreModel and initial-reset tests failed before their fixes and
passed afterward. The full suites passed after integration. The final
source changes received another full Swift run and focused Python checks.
Render proof uses synthetic desktops, windows and events. It does not
prove physical hinge behavior, real menu-bar gestures or device writes.
The source review was bounded to these repairs and branch integration,
rather than an exhaustive security assessment.

## Remaining release gates

- This Mac has a Developer ID Application identity and the `jrbar-notary`
  profile, but no Developer ID Installer identity.
- The development bundle relies on an external core and has no Sparkle
  framework. Build the full package, validate the frozen daemon and hook,
  and generate signed update assets before publication.
- Record the release gate's performance evidence. Test timings and render
  proofs are not measurements of installed-app CPU, wakeups or energy.
- Perform the human-driven hinge, permissions, display/session and
  device acceptance checks. Tests did not write to real LED devices or
  replace the installed app.

The older [repair handoff](../REPAIR-HANDOFF-2026-09-26.md) records
broader product plans. Aquarium runtime redesign, notch geometry work and
Dock thumbnail sizing remain separate follow-up work, not completion
claims for this release preparation.
