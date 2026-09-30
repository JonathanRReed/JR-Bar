# Utility and toy repair handoff — 2026-09-26

> **Historical.** A point-in-time handoff from 2026-09-26, kept for provenance.
> Open work is tracked in [`docs/ROADMAP.md`](../ROADMAP.md) and implemented
> capabilities in [`docs/FEATURE-MATRIX.md`](../FEATURE-MATRIX.md).

This is a focused continuation of the attached repair plan, not a declaration
that all nine work packages are complete. Keep the repair PR unmerged until
Jonathan and Devin have run the native checks below. A portable test pass is
not evidence that a native window, permission prompt, sensor, or assertion
worked on a Mac.

## Baseline and preservation

- Inspected `main` at `f01cd232612fa3020831aadbeab720c22e5118e1`.
- Continued the existing `repair/utility-toy-completeness` branch and draft
  PR #14 from `a7ea62a62206ee28266a740723ad3b7d2f1119df`.
- Preserved the existing drag ownership changes and
  `MenuBarDragOwnershipRepairTests`, along with the archive fixes already on
  `main` from PR #13. No changes to the archive controller's close-selection,
  import-destination, or reload ownership fixes are part of this continuation.
- The working source was reconstructed from the branch's source snapshot.
  All 2,149 tracked snapshot blobs matched their Git hashes; adding the one
  intervening workflow produced exactly the remote head tree
  `7058317a57539e55ae0d4d08ce720baee66404b0`.
- No version, dependency, entitlement, signing, release, Python daemon, or
  hardware-writing changes. No main-branch write or merge is authorized here.
- The temporary source-snapshot and patch-transport workflows are removed
  from the resulting branch. The repository's read-only workflow contract
  remains intact; its tests were not weakened.

## Implemented in this continuation

### Menu-bar placement (MB-01)

The icon mirror's allocator now returns no seat when it cannot establish a
bounded, unoccupied interval. It no longer chooses the least-overlapping
position on a crowded row. The panel hides rather than taking another
control's pixels or clicks. Empty/unknown geometry, unusable widths, negative
screen origins, and undersized native slots are covered.

Native-slot and frozen-drag positions also pass occupancy and bounds
validation. A new control appearing at a frozen position makes the mirror
yield rather than move under the drag or cover that control. This continues
to use the existing listed-item, cover, and concealment model; it is not a
replacement for fresh AppKit/AX/CG observation.

Regression coverage: `MenuBarPlacementRepairTests` (eight cases), updated
`MenuBarIconMirrorTests`, and the existing render proof's optional-seat
handling. Native handle fallback, drag interaction, and actual hit regions
still require a Mac.

### Fold source ownership and readiness (FD-01 / FD-02)

Full frames, far-wall frames, card layouts, and errors now use the same
delivery-time ownership gate. The source must still be the toy's source,
match its display generation, and belong to an enabled, active JR-Bar Fold
session. A late error from a retired source cannot invalidate permission or
stop its replacement. Callbacks are detached and card layouts cleared when
a source retires. A startup that resumes after retirement closes its own
source rather than acting on the replacement.

The ScreenCaptureKit source rejects queued deliveries after a stop and does
not start the optional far stream after a full-stream startup was already
cancelled. Existing final startup cleanup remains in place. Readiness says
“Waiting for a screen frame” before it can say “parked,” including movement
mode; renderer and capture-error explanations retain their precedence.

Regression coverage: `FoldReadinessRepairTests` (four portable tests), plus
`FoldCaptureCallbacksRepairTests` using copied callbacks and a fake source.
The callback integration test is added but has not run on macOS in this
continuation. No lid sensor, anchor, hysteresis, movement threshold, or
renderer geometry was tuned without hardware evidence.

### Keep Awake control scope (KA-02; presentation portion of KA-01)

The card switch is visibly and accessibly labelled “Manual session,” not a
master switch for every sleep assertion. The menu action says “End manual
session.” Shared card/chip help explains that automatic agent holds and other
apps can remain active. Display-sleep help no longer promises to prevent
manual locking or override security policy. Existing lease, agent, grace,
and safeguard state remains authoritative; assertion ownership itself is
unchanged.

Regression coverage: updated `KeepAwakeReadingTests` and
`KeepAwakeRepairTests`, with manual, automatic, grace, and suspended states.
These exercise production reading/presentation logic, not IOKit assertions.

### Aquarium accounting and visible semantics (part of AQ-02 / AQ-03)

Work-time rewards require a live core connection and an actually working
session. A monotonic, bounded work clock excludes disconnected intervals,
resets on connection changes, and does not backfill a reconnect gap. An
unchanged but live state remains eligible; no snapshot-age heuristic was
introduced. Pruning no longer treats a disconnected retained snapshot as
a current live roster.

The card reports working, idle, waiting, settled/leaving, and resident fish
separately. Disconnected data is labelled last-known, not confirmed working.
The existing switch is labelled “Tank window”; it has not been repurposed
as a master feature-disable control. Help distinguishes work-time pearls
from existing feeding/growth and deduplicated completion rewards. Those
other reward rules are unchanged.

Regression coverage: `AquariumWorkEligibilityRepairTests` (four tests) and
`AquariumActivityPresentationRepairTests` (three tests). The work clock's
regression probe reproduced the old fixed-interval behavior in isolation;
it was not a native run of the timer-driven toy. Native observer/timer and
persistence integration still need verification.

### Retained archive reads (AR-01)

History transcript search and Overview's saved timeline/proxy reads now use
shared weak-owner bindings that do not require capture to be enabled.
Turning capture off does not erase or hide saved evidence. The bindings do
not install watchers, import sources, start capture, or run indexing. The
Overview live-capture health probe remains gated by capture being enabled.

Regression coverage: `ArchiveReadBindingsRepairTests` seeds a scratch
archive, indexes its fixture explicitly, disables capture, reads through the
production bindings, and checks that no capture sources started. A second
test covers empty evidence and owner release. These native integration
tests are added, not yet executed here.

## Verification evidence and limits

Local host: Linux x86_64, Swift 6.2.1, Python 3.13.5. This is not the project's
pinned macOS/Python 3.12 environment.

| Check | Result in this continuation |
| --- | --- |
| Portable Swift scratch package, `swift test -j 2` | 33 tests passed in six suites. Exact production pure logic and geometry methods were compiled; AppKit windows/controllers were not. |
| `swiftc -frontend -parse` on all 26 changed/new Swift files | Passed syntax parsing. This is not a native build or type check. |
| Supplemental contract suite with available Python | 87 tests passed, including all four workflow contract tests after temporary workflows were removed. The original write-permission violation reproduced before removal. |
| Documentation links | All relative links resolve across 161 Markdown files. |
| Secret scan | Changed-file scan passed for 28 changed/new files. The whole-repository scan exceeded the local execution limit and is not claimed passed. |
| `git diff --cached --check` | Passed. |
| `./scripts/bootstrap-dev.sh` | Blocked: Python 3.12 is not installed (exit 2). No dependency pins were changed. |
| `make fast` | Blocked: pinned `.venv/bin/python` is unavailable (exit 2). |
| Available Python running `scripts/verify_fast.py` | Blocked at Ruff, which is not installed (exit 1). Not a passing fast gate. |
| Available Python running the full Python suite | Failed during collection: macOS/PyObjC/AppKit are unavailable (exit 3). Not a full-suite pass. |
| `cd app && swift build --build-tests -j 2` | Failed on macOS/Objective-C APIs unavailable on Linux (exit 1), before validating the app. |
| Native `swift test`, render proofs, signed app launch, hardware | Not executed in this environment. |

Portable tests were run in a separate temporary package, not by changing the
app's package manifest, framework imports, or platform floor. The scratch
package includes exact production Keep Awake readings, Fold readiness,
Aquarium accounting/presentation, and the mirror's pure geometry methods.
It is not a substitute for the checked-in native test targets. Review was a
single-agent source/diff review, not an independent native code review.

## Remaining code work — not merely hardware verification

- **MB-03:** complete bounded wake/display/Accessibility-generation recovery
  and prove final post-cancellation observation through the native runtime.
  Preserve the existing branch's drag-ownership work while doing so.
- **KA-01:** audit the full async lease handoff/detach path in
  `SystemTogglesStore`; this continuation changes control scope and wording,
  not that state machine.
- **NB-01 / NB-02:** complete provider/cup role-specific hit routing and
  constrained notch geometry/compact-layout work.
- **AQ-01 and remaining AQ-02:** implement the planned demand-driven runtime,
  explicit master disable/migration, load/save ownership, and remaining
  filters/inspector. The existing closed-window event observers and ambient
  preferences remain; “Tank window” is an honest label, not a completed
  runtime redesign.
- **DK-01:** complete thumbnail-first Dock preview header sizing against the
  preview's target display.
- **FD-03:** use measured hardware results to determine whether physical
  movement changes are justified; any required code changes remain open.
- Complete the plan's full feature/resource inventory and observed idle-cost
  measurements. No CPU, wakeup, GPU, energy, or hardware-success claim is
  supported by this continuation.

## Devin / native Mac acceptance checklist

Use this PR's branch, not `main`. Keep all mock daemons, state, archives,
render output, and fixture configuration in scratch locations as required
by [AGENTS](../../AGENTS.md). Do not synthesize input or write global Dock/menu
preferences. Hardware interaction here is a human-driven acceptance pass.

First run the documented gates in the pinned environment:

```sh
./scripts/bootstrap-dev.sh
make fast
.venv/bin/python -m pytest tests -q
cd app
swift build --build-tests
swift test
```

Run focused suites during diagnosis rather than repeatedly rerunning every
suite. Existing `MenuBarDragOwnershipRepairTests`, the placement/render
suites, all Fold repair suites, Keep Awake readings, Aquarium repair suites,
and archive-read tests are particularly relevant. For render proofs, use
`JRBAR_RENDER_PROOF=1` and `JRBAR_RENDER_PROOF_DIR` pointing to a scratch
folder; open and inspect each produced PNG.

1. **Menu bar:** crowded row; Control Center, clock, and native overflow
   controls; permission missing/revoked; narrow/undersized slot; negative
   display origin; second display; Spaces/wake/display changes. Verify that
   a no-seat decision leaves native controls clickable and JR-Bar still
   recoverable. During a human Command-drag, introduce a crowded boundary,
   cancel, cross displays, and verify that old callbacks cannot reclaim the
   drag or return the mirror over another control.
2. **Fold:** simulation first, then real lid/sensor movement. Exercise
   enable/disable, Duo/Room swaps, screen permission grant/revocation,
   display changes, sleep/lock/user-session changes, and a start/stop/start
   race. A frameless source must say it is waiting. Old full/far/card/error
   callbacks must not affect the replacement. Confirm stream indicators,
   capture teardown, card clearing, first-frame delivery, and visual motion.
3. **Keep Awake:** start/end manual sessions from the card, notch, and menu;
   automatic work plus grace with no manual lease; manual expiry;
   disconnect/reconnect; battery/thermal suspension. Verify that all
   surfaces agree on scope, and ending manual does not promise to release
   automatic or external holds. Test system locking normally; no UI should
   claim that security policy is bypassed.
4. **Aquarium:** idle-only, working parent/subagent, waiting, completed and
   resident fish; leave a working snapshot unchanged while live; disconnect
   across several ticks; reconnect without catch-up reward; toggle the tank
   window; restart with a scratch save. Work-time pearls must not accrue from
   disconnected snapshots, and completion/feeding rules must remain intact.
   Verify the visible card text and observe resource ownership without
   treating this partial runtime work as the planned master-off feature.
5. **Archive:** with capture disabled, search saved transcripts, open a
   saved timeline, and read proxy evidence; inspect that no capture source
   starts. Repeat with empty storage, an unavailable owner, and a fresh
   temporary archive. Recheck PR #13's explicit destination, reload, and
   selection/close behavior. Never use the person's live archive as a test
   fixture.

Record Mac model, macOS/Xcode version, displays/scales, permissions, branch
SHA, observed result, and relevant diagnostics for failures. Leave the PR
unmerged until these results and any remaining scope decisions are reviewed.

## Native verification — Devin run, this Mac

Host: Mac16,8 (Apple M4 Pro), macOS 27.2 (26B5091g), arm64. Toolchain is
Command Line Tools only — no Xcode is installed or selected — with Apple
Swift 6.4.0.34.1 (swift-driver 1.168.6), target arm64-apple-macosx27.2.0.
CI builds with the older Swift 6.3.3 toolchain, so the local compiler is
newer, not identical. Python 3.12.13 via the worktree's own `.venv`
(`./scripts/bootstrap-dev.sh`). One display: 3024×1964 Retina, main, not
mirrored. Worktree: `.claude/worktrees/repair-pr14`.

| Check | Native result |
| --- | --- |
| `./scripts/bootstrap-dev.sh` | Passed. Pinned pip 26.1.2 and all constrained dependencies; `pip check` clean. |
| `make fast` | Passed in 44.23 s at `9eff18e6` and 61.30 s at `c48da3cd`: 87 contract tests, 2161-file secret scan, 161 Markdown link check, 37 fixture tests, 288 focused tests, bytecode, dependency policy, version contract, diff hygiene. |
| `.venv/bin/python -m pytest tests -q` | 4271 passed, 4 warnings, 17 subtests, 345.52 s at `9eff18e6`. |
| `swift build --build-tests` | Passed at `9eff18e6` and `c48da3cd`; warnings only (pre-existing sendable-capture and missing CLT search paths). |
| `swift test` (all four targets) | 3560/3560 passed at `9eff18e6`, and again at `c48da3cd` (76 + 45 + 985 + 2454). The four repair suites the prior run could not execute natively — `FoldCaptureCallbacksRepairTests`, `ArchiveReadBindingsRepairTests`, and the placement/drag/mirror suites — all ran and passed. |
| Render proofs | `JRBAR_RENDER_PROOF=1` wrote ~995 PNGs to `/tmp/jrbar-proofs-pr14` at `9eff18e6`. Inspected: the Keep Awake card reads "Manual session" with both disclaimers; the Aquarium card shows "Tank window" and the honest "Disconnected · 0 confirmed working" line; the notch menu says "End manual session"; the menu-bar drag frames show the frozen icon mid-drag and the covered-control note; the LED strip proof's layer render matches its SwiftUI still pixel-for-pixel. |

### CI flake comparison against main

The failed Swift check at `9eff18e6` reported four issues, all in files
this branch does not touch: `LEDPreviewStripTests` (two frames identical),
`PanelPulseTests` (no pulse registered), `ScreenBarEarTests` ("1h 00m" read
back as "59m"), and `PanelUsageTests` (the sparkline ask never landed).
Main's own push run at `f01cd232` failed the same way — the same suites,
plus a mock-core socket that took over ten seconds to appear — while the
prior head `9bea0661` passed, so the failures are environment-sensitive,
not a regression of this diff. The mechanism for each is concrete: the CI
image forces Reduce Motion (still frames, still marks), the ear formats a
fresh `Date()` on each read and crossed a minute boundary under starvation,
and two waits had deadlines inside what the loaded runner needed.

`c48da3cd` hardens those tests without weakening any assertion: the probe
hosts the layer view with Reduce Motion pinned off, the ear's reset is
seeded mid-bucket in the day-scaled wording, and the condition-bounded
waits are raised to ninety seconds (socket wait to thirty). Locally at
`f01cd232` all four suites already passed; the fixes exist so the required
CI check measures the code rather than the host.

### Still pending on this Mac

- Human-driven acceptance: the checklist's Command-drag supersession,
  physical lid movement, screen-permission grant/revoke, Spaces/wake, and
  second-display steps need a person; they have not been run.
- Full Xcode-specific validation is unavailable (CLT only).
- GitHub checks must re-run on `c48da3cd`; merging waits on them and on
  the human acceptance above.
