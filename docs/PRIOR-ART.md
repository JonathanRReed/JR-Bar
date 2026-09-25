# Prior art and attribution

JR-Bar is MIT licensed and stands on work by others. This file records
what we studied, what we adopted, and under which terms — so a reader
can trace any design decision back to its source.

## CodexBar

Snapshot studied for P3.35: MIT, © 2026 Peter Steinberger, commit
`e8e275511105e6e76409f2ef308c9bbc8c2fbcdc`.

<https://github.com/steipete/CodexBar>

The closest analogue to this project: a macOS menu-bar app that reads
AI-coding-tool usage without asking the user to sign in again. We read
its source, docs, CHANGELOG, issues and pull requests in depth on
2026-08-27 and adopted these ideas (reimplemented in Python/PyObjC, no
code copied):

- **Claude OAuth token endpoint and client id.** `platform.claude.com`
  (not `console.anthropic.com`), form-encoded, using Claude Code's own
  public PKCE client id.
- **Refresh failure taxonomy.** Only a `400`/`401` whose body carries
  `error == "invalid_grant"` means the sign-in is dead; every other
  4xx is transient. Their `refreshFailureDisposition` makes exactly
  this distinction, and copying it stopped us wedging a provider behind
  a terminal gate for an hour over one bad request.
- **Keychain change detection by item attributes.** An attributes-only
  query (no secret requested, so no consent dialog) yields the item's
  modification and creation stamps, which is how a credential gate can
  notice a re-login it cannot see in any file. Throttled to 60s, as
  they throttle theirs.
- **Pre-emptive refresh.** Refresh from the stored expiry before the
  usage call rather than reactively after a 401.
- **Cadence that ignores quota level.** Their adaptive refresh
  deliberately does not poll harder when a meter runs low. We adopted
  that and kept one documented divergence: within 10 minutes of a reset
  boundary we still poll at 120s, because unlike CodexBar we celebrate
  resets and have to observe the crossing.
- **Same-origin redirect refusal** on requests that carry a bearer
  token, in the spirit of their `ProviderHTTPClient`.
- **Pure layout planning and generation fences.** For P3.35 specifically,
  we borrowed the discipline of immutable layout plans, stale-callback
  refusal, passive overlay behavior, Reduce Motion parity, and grouped
  accessibility metadata, then reimplemented it in Python and PyObjC.

**Where we deliberately diverge:** for Claude-CLI-owned credentials
CodexBar *delegates* refresh back to the CLI (driving `claude /status`
in a PTY) and never writes that Keychain item. JR-Bar refreshes
directly and writes the rotated tokens back, so it needs no PTY
subprocess and no dependency on `claude` being installed — at the cost
of owning that write-back. Their delegated path is reported unreliable
in steipete/CodexBar#1287.

## T3 Code

Snapshot studied for P3.35: MIT, © 2026 T3 Tools Inc., commit
`2daff8c25adf701fddd062ae93b94cc57d420ec2`.

<https://github.com/pingdotgg/t3code>

Studied for agent and session lifecycle reporting, stable creation-order
presentation, local read and visit receipts, and keyboard traversal
semantics. The P3.35 stack follows the same high-level rule that activity
may change selection priority without reordering the underlying identity map.

## SidePulse upstream

Snapshot studied for P3.35: MIT, © 2026 Peter Kuhar, commit
`044508556934f913ac555d555e35e19b23294773`.

<https://github.com/inteliwear/sidepulse>

This is the original product lineage. It provided negative evidence for the
old recency-style announcer behavior and positive evidence for keeping the
product fork attribution explicit even as JR-Bar diverges further.

### LED motions, 2026-09-24

Upstream studied again at `48a04b8` (MIT). Nothing was copied; the
programs are short data and were reimplemented as shapes.

- **Iris lid looks.** [PR #38](https://github.com/inteliwear/sidepulse/pull/38)
  (`e0d578f`, "Polish animations and add customization support") ships a
  lid-open program that opens from the centre pair outward, ramping from
  the working cyan to the done green, and a lid-close program that shuts
  from the edges inward, each as an eight-LED and a two-LED file. JR-Bar's
  Iris and Iris (active) looks (`motion_shapes.iris_open`/`iris_close`,
  `lid_presets`) are drawn for each device's LED count instead.
- **Tool tint.** bizantl/sidepulse, branch `luka`,
  [`faace13`](https://github.com/bizantl/sidepulse/commit/faace135494de480ea5e369e15f2848d4698607c):
  the working comet's head takes the hue of the tool family (shell, edit,
  read, web/MCP, task, plan) and rewrites only on a family change.
  JR-Bar's `colors.tint_by_tool` is the same idea, opt-in, head only, with
  a 3 s floor between tint-only rewrites.
- **The Dot's wipe.** zschwendi/sidepuls-z-swift (MIT),
  [`878c245`](https://github.com/zschwendi/sidepuls-z-swift/commit/878c245e711e48f1aab5434cadf351ebc85eebc5)
  `LightingEngine.swift`: a two-LED directional breathe (0 up, 1 up, 0
  down, 1 down). `motion_shapes.dot_wipe` is JR-Bar's version, the Dot's
  default way to travel.
- **Write-rate caution.** gourneau/sidepulse (MIT)
  [`LEARNINGS.md`](https://github.com/gourneau/sidepulse/blob/9e3d29fc5016a17aa896c71790ee3a3f99b85e8f/LEARNINGS.md):
  the emulated FAT volume can wedge under a write storm, which is why the
  tool tint dedupes on the family and never rewrites faster than every
  three seconds.

## SidePulse fleet fork

Snapshot studied for P3.35: MIT, © 2026 Peter Kuhar, fork commit
`e5161c47885e1246216a5dd98fa4317ad434ef7e`.

<https://github.com/adamstambouli/sidepulse>

Studied for sticky identity slots and coalescing behavior. We did not copy
code. We reused the idea that stable visual positions are easier to trust
than recency-driven reshuffles when several asks coexist.

## T3Notch

Snapshot studied conceptually for P3.35: commit
`f334abd225cd872b87b72a351800bc06ba064a7d`.

<https://github.com/zortos293/T3Notch>

Studied **conceptually only**. At the time of reading this repository
published no license, so all rights are reserved by its author and none
of its code is used here. Our notch-adjacent geometry (choosing the
notched display, observing
`NSApplicationDidChangeScreenParametersNotification`) is written from
Apple's public AppKit contracts.

## Product lineage

JR-Bar began as a fork of SidePulse and has since diverged substantially.
P3.35 continues that pattern: original implementation, explicit attribution,
and ideas adapted from upstream and peers without code copying. See `LICENSE`.

## Pelmet, Ice (PR #995), Thaw, Barometer — macOS 27 menu bar concealment

Studied 2026-09-16 for the Menu Bar utility's macOS 27 engine.
Pelmet (<https://github.com/fif7y/pelmet>, GPL-3), Thaw and Barometer
(GPL-3) and Ice's pending macOS 27 branch
(<https://github.com/jordanbaird/Ice/pull/995>, MIT, with GPL-derived
files) all document the same fact about the OS: the only mechanism that
removes another app's item from the macOS 27 menu bar is
`MenuBarAgent`'s assessment (exam-lockdown) mode, driven through the
private `MenuBarClientCore` framework — `MBAssessmentModeConfiguration`
(`initWithAllowedSystemItems:allowedBundleIdentifiers:`, system items
numbered 0–8) and `MBAssessmentModeAssertion`
(`activateWithConfiguration:completionHandler:`, `invalidate`). We
adopted the *facts* they measured — only a signed bundle's allowlist is
honoured, assertions union their allowlists so a change activates the
new one before invalidating the old, the agent ignores clicks on its
own clock/battery/Wi-Fi under any assertion (Control Center answers an
AX press), concealed items leave or go stale in Accessibility, the
agent reorders the bar on its own — and wrote our own implementation
(`MenuBarConcealer.swift`): no code was copied from any of them. Our
probe on this Mac confirmed the concealment and the allowlist rule.

## TinyCast

Flagged by the owner as the golden-example reference for overlapping
features (<https://github.com/abue-ammar/tinycast>). No snapshot studied
yet, no ideas adopted, no code copied. Recorded here so the attribution
trail stays complete; a future entry should cite the commit, license, and
what was taken or deliberately left.
