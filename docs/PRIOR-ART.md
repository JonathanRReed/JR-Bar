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

### The 2026-09-24 pass (hooks v2, reset confirmation, fixture contract)

Snapshot studied: MIT, commit `e34fe618` (CHANGELOG top 0.66.0). Reimplemented
in Python and Swift, no code copied:

- **External event hooks v2** (`docs/configuration.md`, `HookRunner.swift`,
  `HookRateLimiter.swift`): rules instead of one path, commands run without a
  shell, an environment allowlist plus the event's own variables, JSON on
  stdin with sorted keys, seven events, a 600 s limiter on the chatty ones, and
  hard limits that fail closed. Ours is `usage_event_hooks.py` and
  `jrbar usage-hooks`; the legacy single path keeps its argv.
- **Reset confirmation** (`CodexWeeklyResetConfirmation.swift`, #3248,
  #3851): a jump waits for a confirming read 60 s to 30 min later with a
  matching boundary, and a rolling unused window is not a reset. Ours is
  `provider_usage_qol.confirm_reset_events`, shared by the celebration, the
  wire event and the hooks.
- **Provider quota fixture contract** (`ProviderQuotaFixtureContractTests`):
  one invariant suite over every provider fixture
  (`tests/test_provider_usage_fixture_contract.py`).
- **"Count each source once"** for Pi (#3246) and claude-swap homes without
  double counting (#2954): `local_token_history.py`, `provider_homes.py`.
- The **plugin manifest and approval model** (`docs/plugins.md`) informs the
  provider-pack design, which is deferred.

## T3 Code

Snapshot studied for P3.35: MIT, © 2026 T3 Tools Inc., commit
`2daff8c25adf701fddd062ae93b94cc57d420ec2`.

<https://github.com/pingdotgg/t3code>

Studied for agent and session lifecycle reporting, stable creation-order
presentation, local read and visit receipts, and keyboard traversal
semantics. The P3.35 stack follows the same high-level rule that activity
may change selection priority without reordering the underlying identity map.

### The 2026-09-24 pass

Snapshot studied: MIT, commit `cb1a3f34` (tag
`v0.0.43-nightly.20260924.2200`). Reimplemented, no code copied:

- **OpenCode Go usage** (`openCodeUsageLimits.ts`, #12115): the
  `opencode.ai/zen/go/v1/usage` endpoint, the Go key in `auth.json`, and a 403
  meaning "a Zen key without a Go subscription", not an error
  (`collect_opencode`).
- **The CLIProxyAPI hub** (`apps/server/src/usage/cliproxyApi.ts`, #10395):
  `auth-files` plus `api-call` with `Bearer $TOKEN$`, so the proxy fills in its
  own token (`cliproxy_hub.py`). We never call its reset or consume routes.
- **Harness compatibility ranges** (`model-manifest.json`, #13130): the
  `{provider, recommended, ranges}` shape of
  `resources/provider_hook_compatibility.json`.
- **Account homes** (#11485): `CODEX_HOME` and `CLAUDE_CONFIG_DIR` per
  account, homes sharing a folder counted once.
- **Docs layout** (`docs/README.md` over `docs/user/*`, an `AGENTS.md` with the
  doc rules).

## CLIProxyAPI

Snapshot studied 2026-09-24: MIT, © Luis Pater, commit `c404af96` (v7.3.16).

<https://github.com/router-for-me/CLIProxyAPI>

Read for its management API (`internal/api/server_management.go`): the
`auth-files`, `api-call` and 7.3's `quota/providers` and `quota/fetch` routes
the hub uses, and the declarative quota-probe mapping
(`plugin_quota.go`, `sdk/pluginapi/types.go`) that shaped the
deferred provider-pack format. Its request-log naming change (`e6fcfa3`,
an 8-hex counter and `_N` suffixes) is covered by a Data Hoarder test. No
code copied.

## ccusage

Snapshot studied 2026-09-24: MIT, © ryoppippi, commit `03f421fa` (v20.0.25).

<https://github.com/ryoppippi/ccusage>

Read as format documentation, no code copied: the Pi, Grok, Gemini CLI and
OpenClaw adapters (`rust/adapters/*`) describe the session files
`local_token_history.py` reads; its Claude Code statusline guide pointed at
the `rate_limits` block `claude_statusline_source.py` keeps; and its LiteLLM
pricing snapshot is the model for `scripts/update_model_pricing.py`, which
reads LiteLLM's MIT `model_prices_and_context_window.json` by hand, never at
runtime.

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

## Provider marks — Simple Icons, LobeHub Icons, OpenClaw, T3 Code, Hermes Agent

Added 2026-09-25, so every surface that names a provider draws that
provider's real mark. Unlike the rest of this file, these are not ideas
reimplemented: the marks themselves ship as path data, used under each
source's licence. The pinned SVGs are in
[app/Resources/ProviderLogos/](../app/Resources/ProviderLogos/),
[scripts/gen_provider_logos.py](../scripts/gen_provider_logos.py) turns
them into `app/Sources/JRBarUI/ProviderLogoData.swift`, and
[NOTICE.txt](../app/Resources/ProviderLogos/NOTICE.txt) carries the
licence texts into the app bundle
(`Contents/Resources/ThirdPartyLicenses/ProviderLogos.txt`).

- **Simple Icons** 16.32.0, commit `3173436c1255ab7cdc9c38ab85ca0fca333688d9`,
  CC0-1.0 (<https://github.com/simple-icons/simple-icons>): Claude,
  Gemini, Pi, OpenCode and Cursor. CC0 covers the SVG data, not the
  trademarks.
- **LobeHub Icons** (`@lobehub/icons-static-svg` 1.95.1), commit
  `49a2130df7bfa5eb1b088261bff20a37e2967789`, MIT © 2023 LobeHub
  (<https://github.com/lobehub/lobe-icons>): the OpenAI blossom (Codex
  and the OpenAI API), the Codex app mark, Grok, xAI, Devin, Antigravity,
  Hermes Agent, Kiro and the newer Gemini sparkle. Simple Icons has no
  OpenAI, Grok or xAI entry.
- **OpenClaw**, commit `956cca8af6751929df2174b119f2340efaa2418c`, MIT ©
  2026 OpenClaw Foundation (<https://github.com/openclaw/openclaw>): its
  18 pt menu-bar critter (`apps/linux/src-tauri/icons/tray-template.svg`)
  and the full Molty (`apps/macos/Icon.icon/Assets/molty.svg`).
- **T3 Code**, commit `99641fd09a509feb644b3c8ef718c12c60cf436c`, MIT ©
  2026 T3 Tools Inc. (<https://github.com/pingdotgg/t3code>): the T3
  letter mark (`apps/mobile/assets/widget/T3Mark.svg`).
- **Hermes Agent**, commit `99a16153`, MIT
  (<https://github.com/NousResearch/hermes-agent>): the official
  portrait (`assets/icon-master.svg`) we checked LobeHub's path against.
  No Hermes Agent file ships.

We cross-checked the Claude, OpenAI and Gemini paths against the copies
CodexBar 0.53.0 bundles (they match) and took none of CodexBar's files.
Each mark is its owner's trademark and is used only to name that
provider. None of them appears in JR-Bar's own icon or branding.
