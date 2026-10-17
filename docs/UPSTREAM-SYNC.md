# Upstream Sync Review

Reviewed on August 15, 2026 against the ten upstream commits added after merge base `f4dd7e0`. They are not merged wholesale because the JR fork is 160 commits ahead and its controller, installer, packaging, and session-navigation design have intentionally diverged.

| Upstream work | JR-fork disposition |
| --- | --- |
| Custom terminal selection and terminal-window reuse | Already superseded by `status_bar_launch.py`, `navigation_policy.py`, and `session_actions.py`, including Terminal, iTerm2, and verified direct Ghostty execution. |
| Missing ScriptingBridge dependency | Not applicable. This fork has no ScriptingBridge import. Adding the framework would add install weight without repairing reachable behavior. |
| Isolated user installer | Ported as a Python-only user installer for CLI users, then removed. The app's own Command Line link and `make clean-install` replaced it, and the sealed app-bundle, signed-package, and launch-agent paths stayed as they were. |
| Packaging and clean-install tests | Adopted through package-contract tests and `scripts/verify_clean_install.py`. |
| Hook stability and compatibility | Adopted through fail-open current and legacy hook-module entrypoints. |
| PR #31 display-sleep-safe keep-awake | Adapted as an explicit owner choice. JR-Bar defaults both ordinary and closed-lid `caffeinate` commands to no display assertion, adds `d` only when selected, and keeps battery and privileged closed-lid policy independent. |
| PR #32 hook-latency evidence | Adapted as a standard-library admission client plus one app-owned bounded FIFO. JR-Bar keeps ordering, tracked provider children, explicit overload receipts, and shutdown drain instead of adopting the PR's detached, potentially reordered process shape. |
| Version and post-build guards | Adopted through `scripts/validate_release_version.py`, Twine validation, clean-wheel installation, and checksum generation. |
| Status-bar UI patches | Not copied by file name. Upstream's controller is substantially different; any behavior must be ported with a fork-native regression test. |

Future upstream syncs should be reviewed commit by commit. Prefer porting a behavior and its test over merging a large controller diff.

PRs #31 and #32 were additionally reviewed on August 29, 2026. PR #31 reported the
`caffeinate -d` display assertion keeping the display on and preventing normal
locking. JR-Bar ports that behavior through its own power-policy and settings
architecture rather than copying the upstream controller patch.

The current-run local-health panel added on August 29, 2026 is fork-native. It
reuses JR-Bar's existing presentation, worker, and performance snapshots and
does not add upstream telemetry, cloud reporting, persistence, or a parallel
metrics framework.

The deeper Why this light context is also fork-native. It retains JR-Bar's
existing `DecisionTrace` semantic ladder, then adds one immutable projection of
cached policy, suppression, surface, accessibility, and timing facts. It does
not copy controller state, retain content-bearing identifiers, probe providers
or devices, persist explanation history, or add telemetry. Selection and scroll
position are preserved inside the existing selectable panel instead of
introducing a second diagnostics window.

## P5.72 research cadence

Recurring upstream review is source-controlled and manual. The exact schedule,
live source set, untrusted-input boundary, dated snapshot naming, disposition
vocabulary, evidence fields, no-mutation rules, and stale-ledger signaling are
defined in [UPSTREAM-RESEARCH-CADENCE.md](UPSTREAM-RESEARCH-CADENCE.md).
The first linked snapshot is the [2026-08-30 refresh](UPSTREAM-REFRESH-2026-08-30.md).
This is a review record, not authorization to merge, push, release, deploy,
change credentials, run an issue bot, or mutate hardware/system state.

## October 7, 2026 review

The latest review covers the 44 upstream commits after `0445085`, all 43 pull
requests and 15 issues with their comments, the new firmware packages, the
bridge and iPhone repositories, the three non-default branches and every fork
with commits of its own. Every item has a one-line disposition in
[the dated note](archive/UPSTREAM-REFRESH-2026-10-07.md). It is the current
reference; the [2026-08-30 refresh](UPSTREAM-REFRESH-2026-08-30.md) is
superseded by it.

| Upstream work | JR-fork disposition |
| --- | --- |
| Firmware published in the repository (Pro 1.1.0, Dot 1.1.0 / 1.1.14) and `sidepulse firmware version` | Ported as `jrbar firmware version` (`device_firmware.py`) and, 2026-10-07, as a user-started update (`jrbar firmware upgrade`, Settings > Devices & Lighting; [how it works](user/firmware.md)): pinned hashes, one download only when asked, writes held while the device restarts, the new version proved by `STATUS.TXT`. Both devices here were updated by hand the same day (Pro 1.1.0, Dot 1.1.14). |
| Keepalive as an uncached `STATUS.TXT` read | Already done first in `status_bar_legacy._keepalive_fresh_read`; `touch` is the fallback. |
| Read-only storage transports (READ2ME, SPC2) and the raw FAT12 writer | Not applicable / rejected: no managed storage policy here, and a `sudo` raw disk write is not something JR-Bar scripts do. |
| Pro 1.1.0 colour balance and 16-bit rounding | LED floors stay valid (conservative on 1.1.0). Owner channel gains may over-correct after the Pro is updated. See the note's LED review. |
| #42 mount-retry timer leak, `0445085` log churn | Ported to the eject guard (`sd_eject_guard.c`), tested through its plain-C retry table. |
| #48 tool output text read as failure | Ported (`collector._tool_response_looks_failed`). |
| #44 subagent stop and pending approvals | Already correct here; pinned by a regression test. |
| iPhone links, bridge, push, remote relay, Android pairing | Rejected: they send data off the Mac by default. |
| Closed-lid display sleep (`48a04b8`) and the WindowServer crash (#51) | The crash came from private framebuffer calls JR-Bar does not make. Display behaviour under `disablesleep` with the lid shut is a hand check. |
| Unanswered asks older than an hour | JR-Bar's monitor drops them. One owner decision across four modules; see the note's fork row for alex-fung. |
| Trademark policy in `sidepulse-ios` | JR-Bar's references are nominative; the eject-guard name and the icon are open questions. |
