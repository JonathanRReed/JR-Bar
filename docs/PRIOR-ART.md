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
  boundary we poll at 120s to observe the crossing. Current JR-Bar also
  schedules a read at a known reset boundary. CodexBar now supports reset
  celebrations too; the comparison below records its current scheduler.
- **Same-origin redirect refusal** on requests that carry a bearer
  token, in the spirit of their `ProviderHTTPClient`.
- **Pure layout planning and generation fences.** For P3.35 specifically,
  we borrowed the discipline of immutable layout plans, stale-callback
  refusal, passive overlay behavior, Reduce Motion parity, and grouped
  accessibility metadata, then reimplemented it in Python and PyObjC.

**Where we deliberately diverge:** for Claude-CLI-owned credentials
CodexBar *delegates* refresh back to the CLI (driving `claude /status`
in a PTY) and never writes that Keychain item. The 0.7 build of JR-Bar
refreshed directly and wrote the rotated tokens back. The current build
does neither: it reads the access token Claude Code already holds, never
consumes the refresh token or changes Claude's Keychain item, and asks
the person to sign in through Claude Code when the token is not usable
(`claude_quota.credential_needs_sign_in`). The ordinary read needs no PTY
subprocess and owns no write-back. The optional usage probe below also
does not renew credentials. CodexBar's delegated path is reported unreliable
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

### The 2026-10-07 pass (0.67.0 to 0.73.0)

Snapshot studied: MIT, commit `03a51bdcfc6f6804e005d7e5007de67bac82b494`
(CHANGELOG top 0.73.0, 458 non-merge commits since `e34fe618`). Reimplemented
in Python, no code copied; every rate below was checked against the maker's own
pricing page, not taken from CodexBar's table:

- **One-hour cache writes** (`CostUsageScanner+Claude.swift`,
  `CostUsagePricing.swift`): a Claude cache write for an hour bills at 2x
  input, from `usage.cache_creation.ephemeral_1h_input_tokens`. Ours is
  `usage_stats.one_hour_cache_writes` and `ONE_HOUR_WRITE_SUFFIX`; Pi and its
  OMP fork's `cttl.ephemeral1h` follows
  [`43c1e338`](https://github.com/steipete/CodexBar/commit/43c1e338eaee58f0ec5e9282b0eebc0a8e97a2a1)
  (#4121) in `local_token_history._split_one_hour`.
- **Long-context requests** ([`04b23bed`](https://github.com/steipete/CodexBar/commit/04b23bed620dfbad985ca3a30848f798eaa9c62c),
  #4302): OpenAI reprices a whole request over 272K prompt tokens.
  Ours is `usage_stats.is_long_context_request`.
- **Antigravity bucket cadence** ([`62acfd8e`](https://github.com/steipete/CodexBar/commit/62acfd8ead86a3ae443ec2d76c30c93ec72e09b4),
  #4084): a bucket's `window` field is its cadence; Starter accounts have
  weekly groups only. Ours is in `provider_usage_parsers.parse_antigravity_usage`.
- **Status ordering** ([`09537336`](https://github.com/steipete/CodexBar/commit/0953733615b929805e8c86ac58d5d1f94284bd3b),
  #4175): an older incident request cannot replace a newer one
  (`status_feeds.StatusFeedPoller.poll_once`).
- **Executable discovery** ([`3ce4da88`](https://github.com/steipete/CodexBar/commit/3ce4da881d58fc457e3a5bb945321a040bcd46ed),
  #4136): no relative PATH entry resolves a binary
  (`provider_reconnect._resolved_codex_binary`,
  `hook_compatibility._search_path`).
- **Installed Claude Code version in the usage request**
  (`ProviderVersionDetector`): ours reads it from `sessions/<pid>.json`
  instead of running `claude --version` (`claude_quota._installed_claude_version`).

Studied and left alone (reasons in
[the dated note](archive/2026-10-07-codexbar-t3-similar-tools-review.md)): the
`cedar_ember` saved-reset query, Cursor's Grok Bot lane, Priority / Fast
pricing, and the request ledger, which JR-Bar's `last_token_usage` deltas make
unnecessary.

### The 2026-10-25 pass, Claude usage recovery

Snapshot studied: MIT, commit `d34fbb47afe73f81dd591bae28a60f72c39a9fe4`.
Read `ClaudeStatusProbe.swift` and `ClaudeCLISession.swift` for the PTY
`/usage` probe, bounded lifetime, launch settings and labelled quota sections.
JR-Bar reimplements its parsing and process lifetime in Python. No code was copied. The fallback does not ship in
0.10.0. Its reserved setting has no effect and Settings hides it.
The probe never answers a trust or sign-in question or delegates token refresh.
The probe uses a temporary config directory and a stored access token;
it cannot recover a missing token. We did not run it with a real account.
We also studied the Grok and Kimi credential-location readers for their
`GROK_HOME` and `KIMI_CODE_HOME` overrides.

The production probe stays disabled until command-only dispatch is verified.
The [CLI reference](https://code.claude.com/docs/en/cli-reference) documents
positional text as an initial prompt. Tests drive a synthetic TUI through an
inherited token descriptor.
The L3c live check stopped at credential preflight with `access_lost`;
no interactive CLI started. It does not prove installed-CLI compatibility.
See the [L3c handoff](archive/2026-10-25-claude-cli-usage-l3c.md).

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

### The 2026-10-07 pass

Snapshot studied: MIT, © 2026 T3 Tools Inc., commit
`611132c171f3a821bd2e32f22261135cef6330ac` (tag
`v0.0.46-nightly.20261007.2774`). Reimplemented, no code copied:

- **The orchestrator v2 database** ([`de343914`](https://github.com/pingdotgg/t3code/commit/de343914273eceb852a1d1d739cd1d38df7796ee),
  #2829): live threads, runs, runtime requests and plans in
  `userdata/statev2.sqlite`. What JR-Bar reads from it follows
  `apps/server/src/orchestration-v2/ProjectionStore.ts`
  (`threadShellFromProjection`) and
  `packages/contracts/src/orchestrationV2.ts`; ours is
  `t3_compat._read_v2_snapshot`.
- **Per-turn token usage** (`packages/contracts/src/providerRuntime.ts`,
  `TurnTokenUsage`): ours is `usage_graph_worker._scan_t3code_v2_records`.
- `T3CODE_HOME` (`apps/desktop/src/app/DesktopConfig.ts`), the `{id, value}`
  shape of model options (`packages/contracts/src/model.ts`) and the
  `claudeAgent` / `acpRegistry_*` driver names.

## CLIProxyAPI

Snapshot studied 2026-09-24: MIT, © Luis Pater, commit `c404af96` (v7.3.16).

<https://github.com/router-for-me/CLIProxyAPI>

Read for its management API (`internal/api/server_management.go`): the
`auth-files`, `api-call` and 7.3's `quota/providers` and `quota/fetch` routes
the hub uses, and the declarative quota-probe mapping
(`plugin_quota.go`, `sdk/pluginapi/types.go`) that shaped the
deferred provider-pack format. Its request-log naming change (`e6fcfa3`,
an 8-hex counter and `_N` suffixes) was read for the retired Data Hoarder's
proxy-log import. No code copied.

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

The 2026-10-07 pass read ccusage at `f3b78d10938456b8a51d85034b2a1c3008e29f50`
(v20.0.26, MIT, © ryoppippi): `rust/adapters/codex/src/README.md` and
`parser.rs` describe how a Codex compaction request is recorded
(`token_usage_record` named by a `compacted` item, absent from the cumulative
counter in remote compactions); ours is the rule in
`usage_stats._scan_codex_lines`, written from that description, with no code
copied.

## OpenUsage

Studied 2026-10-07: MIT, commit
[`00189454`](https://github.com/robinebers/openusage/commit/00189454816cc3d815a166fa1369d6fe67dd2405)
(<https://github.com/robinebers/openusage>). Its note that a stale
`claude-code/2.1.69` user agent was answered "ineligible" on the reset-grants
query is why our usage request now names the installed Claude Code version. No
code copied.

## SidePulse upstream

Snapshot studied for P3.35: MIT, © 2026 Peter Kuhar, commit
`044508556934f913ac555d555e35e19b23294773`.

<https://github.com/inteliwear/sidepulse>

This is the original product lineage. It provided negative evidence for the
old recency-style announcer behavior and positive evidence for keeping the
product fork attribution explicit even as JR-Bar diverges further.

### Upstream refresh, 2026-10-16

Reviewed `main` at
[`ffb1d3c2`](https://github.com/inteliwear/sidepulse/commit/ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb),
MIT, against the last reviewed `6d55225f` snapshot. Also reviewed the
experimental Rust branch at `75265ac340bc04ed400f24ea1ce164d9e163812f` against
its earlier `18f574ee` checkpoint. Keep Awake and lid-sleep source did not
change in either range.

Reimplemented the eject-guard recovery idea from
[`b99c029c`](https://github.com/inteliwear/sidepulse/commit/b99c029c866c7cbe38e696e2de6eeeb66ed086fb).
A changed Disk Arbitration daemon PID makes the guard exit once, so its
existing launchd policy creates a fresh session. JR-Bar retains explicit
volume selection and bounded mount retries. Synthetic PID and retry tests
cover the policy; a real service restart was not exercised.

The upstream Codex restart reminder remains a documentation candidate.
Its OpenCode LaunchServices icon fix does not apply to JR-Bar's bundled
provider mark. Android pairing and FCM delivery were not added in this
launch batch. The Rust branch's preview and editor changes remain
experimental upstream work rather than a migration target for this app.

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

### October 2026 review

Upstream studied again at `6d55225fed20a82521b23d86a4df2c4a15dff295` (MIT),
with the sibling repositories `sidepulse-bridge` at
`e8e363df51388a000c03c8e693a531235f7d63d8` (GPL-3.0-or-later) and
`sidepulse-ios` at `5eec8b41377925d95a47845ea265d8c2b223f848` (MPL-2.0).
Nothing was copied; the GPL and MPL repositories were read for documented LED
syntax and policy only. The full ledger is
[archive/UPSTREAM-REFRESH-2026-10-07.md](archive/UPSTREAM-REFRESH-2026-10-07.md).

- **Tool output is not a verdict.** [PR #48](https://github.com/inteliwear/sidepulse/pull/48):
  a plain-string tool result that merely mentions a traceback is not a failed
  tool. JR-Bar's transcript reader had the same text match and dropped it.
- **One retry timer per disk.** [PR #42](https://github.com/inteliwear/sidepulse/pull/42)
  and `0445085`: a vetoed eject must not stack a mount-retry timer, and the
  guard should not log every dissent. JR-Bar's guard keeps a small slot table
  keyed by BSD name, a 240-try cap and a 10 MB log trim, written fresh.
- **Firmware identity.** `src/sidepulse/firmware.py` names a Dot by
  `app_version` and a Pro by `release_version` in `STATUS.TXT`. JR-Bar's
  `device_firmware.py` reads the same two fields, read-only, and compares them
  to a table of the published releases.
- **Firmware install procedure.** `firmware/README.md` at `6d55225` (copy only
  `FIRMWARE.BIN` to the drive, wait 10 seconds, check `release_version` or
  `app_version`) and the release notes with their SHA256SUMS. JR-Bar's
  `firmware_update.py`, `firmware_package.py` and `firmware_drive.py` run that
  procedure written fresh, with the hashes pinned in the app instead of read
  from the place that serves the file, the root-directory arithmetic learnt by
  updating a Pro and a Dot by hand, and an explicit write hold. Nothing of
  upstream's `firmware upgrade` command was copied.
- **Pro 1.1.0 release notes** (`firmware/v1.1.0/.../RELEASE_NOTES.txt`):
  calibrated per-channel gains, brightness and balance applied together with
  one rounding to 16-bit output. Used to check the LED floors, not copied.

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
(`MenuBarConcealer.swift`, since retired in favour of the position model
below): no code was copied from any of them. Our probe on this Mac
confirmed the concealment and the allowlist rule.

## Ice, Thaw, Pelmet, Stash, Ellipsis, Hidden Bar, SaneBar, Dozer, Bartender — the position model

Studied 2026-10-07 for the Menu Bar utility's divider engine; the notes,
sources and what was adopted or rejected are in
[archive/research/2026-10-07-menu-bar-ice-model.md](archive/research/2026-10-07-menu-bar-ice-model.md).
Ice (jordanbaird/Ice, GPL-3.0, `11edd391`, last commit 2025-09-20) is the
model: the manager's own status item is a divider, items left of it are
hidden, and the person ⌘-drags across it. Thaw (GPL-3.0, `897b6225`),
Pelmet (GPL-3.0, `3f757c96`), Stash (MIT, `10596c43`), Ellipsis
(Apache-2.0, `be2df6a7`), Hidden Bar (MIT, `47937b9d`), SaneBar (MIT,
`2311b237`) and Dozer (MPL-2.0, `b0540378`) were read for how they hide
on macOS 26 and 27 and for their limits: the system drops a status item
wider than half the screen (Ice issue 954), apps hide whole under the
assertion, the agent reorders the bar, and a notch Mac needs a panel for
what does not fit. Bartender is closed; only its public release notes were
read. We adopted the facts and the habits (the divider and the ⌘-drag, a
reveal that draws the hidden run, a panel under the bar for the overflow)
and wrote our own implementation: no code was copied from any of them.

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

## Mac Duo motion comparison, 2026-09-27

Studied [Mac Duo](https://github.com/DhananjayBhosale/MacDuo) at commit
`f6862c85f02964ac4720fd9c7a2979d812a1b627`, MIT, to compare its resting-lid
reference, stillness detection and Metal effects with JR-Bar's Fold.
Mac Duo separates its expanding Duo effect from its held-plane Ghost effect.
That distinction matters when assessing JR-Bar's current Duo look, which
uses a held-plane model. This comparison does not establish visual parity;
animation changes require rendered and physical checks. No Mac Duo code was
copied into JR-Bar.

## Fold capture and blur, 2026-10-27

Studied for the 0.10.1 Fold pass: the Duo's capture at the panel's own
pixels and colour, its blur in linear light, and the front-shaped blur.
JR-Bar reimplements each idea in its own code; nothing was copied, and the
GPL-3.0 projects in the research (Lid Plane, NUEM) were read only as far as
their READMEs.

- [Mac-Duo](https://github.com/sumimakito/Mac-Duo) by sumimakito,
  Apache-2.0, at
  [`2a9fa18b`](https://github.com/sumimakito/Mac-Duo/commit/2a9fa18bea0e92293bf59227b539fe3de0e91328):
  capturing at `contentRect × pointPixelScale` with the best capture
  resolution, filming and tagging the layer in Display P3, and keeping the
  blur pyramid in an sRGB format so it filters light.
- [iphone-duo-motion-study](https://github.com/bravohenry/iphone-duo-motion-study)
  by bravohenry, no licence (all rights reserved), at
  [`6dcc18fe`](https://github.com/bravohenry/iphone-duo-motion-study/commit/6dcc18feb73ac6a725589ec04e08cca0aec90ff2):
  its replay of the Wipe on Apple's iPhone Duo product page, where the
  pyramid level rises in a straight line with distance from the hinge and
  with progress, saturating, so the blur clears as a front. Only the shape
  was taken, as numbers in our own model; none of its shader code.
- [iphone-duo](https://github.com/jal-co/iphone-duo) by jal-co, MIT, at
  [`3674f334`](https://github.com/jal-co/iphone-duo/commit/3674f3343d20a72fd6c7277bdd5cfeffc9216f7d):
  its frame-by-frame review of real footage, which describes the focus
  boundary moving across the display with the hinge side readable first.
- Empirical Health's
  [technical notes](https://www.empirical.health/blog/iphone-duo-comparison/technical-notes.html)
  on their fit to filmed footage (σ ∝ sin θ · d³): independent support for
  a sharp hinge side and a heavily blurred outer band.
- [iphone-duo](https://github.com/chuspeeism/iphone-duo) by chuspeeism
  (© 2026 jadon7), MIT, at
  [`2662ebbe`](https://github.com/chuspeeism/iphone-duo/commit/2662ebbeb6aa844cd4f6888f7d6f8958662249fd):
  an independent animation study against the community's 3D model of the
  device, and the source of the Duo's darkening and its classic blur
  (`72·motion·e^1.35`, darkening at twice the motion past a 0.2 dead
  zone). Its numbers are that study's estimates, not Apple's.

## Notch island motion, 2026-10-07

Studied to find out why the island did not feel like Alcove. Behaviour and
numbers were read; nothing was copied, and the code that came of it
(`NotchMotion`, `NotchStage`, `NotchReveal`) is our own. The full note, with
what was adopted and what was turned down, is
[docs/archive/2026-10-07-notch-premium-research.md](archive/2026-10-07-notch-premium-research.md).

- **Boring Notch**, commit `e2654ee41b0b9aee72c5a8113a11ab855896d6e6`,
  GPL-3.0 (<https://github.com/TheBoredTeam/boring.notch>): spring
  parameters for open and close, the fixed-panel architecture, the
  content scale-and-fade, the hover and leave delays.
- **DynamicNotchKit**, commit `cd0b3e52d537db115ad3a9d89601f20e0bee8d27`,
  MIT (<https://github.com/MrKai77/DynamicNotchKit>): the blur, scale and
  opacity content transition, the overshoot-hiding backing, and its
  maintainer's account of `ignoresMouseEvents` and click-through of
  transparent pixels (issue 48).
- **Mew Notch**, commit `2b909a58b0fa22fc647738c107705e14c65affba`,
  GPL-3.0 (<https://github.com/monuk7735/mew-notch>): the hover scale and
  hover haptic.
- **Atoll**, commit `903d1ed3f8afb2a672bdf6d3b57704d3a07603a0`, GPL-3.0
  (<https://github.com/Ebullioscopic/Atoll>): the blur-replace content swap
  and its critically damped springs, for contrast.
- **Alcove** 1.7.x (closed source; public page and release notes at
  <https://tryalcove.com> and
  <https://github.com/henrikruscon/alcove-releases>) and **NotchNook**
  (closed; public pages): which motion problems their release notes say
  took a release each, and that Alcove draws inside one fixed window.
  Nothing of either app was disassembled.
- Apple's WWDC23 session "Animate with springs" (10158) for retargeting
  and velocity, and the SwiftUI animation documentation for the presets.

## Aquarium schools, 2026-10-27

The tank's fry and tetra school flock with boids, reimplemented from
Craig Reynolds' paper "Flocks, Herds, and Schools: A Distributed
Behavioral Model" (SIGGRAPH 1987, [red3d.com/cwr/boids](https://www.red3d.com/cwr/boids/)):
separation, alignment and cohesion over a bounded set of neighbours. The
walls and the bigger fish take their share of the turn first, the
prioritised steering in Reynolds' "Steering Behaviors For Autonomous
Characters" (GDC 1999, [red3d.com/cwr/steer](https://www.red3d.com/cwr/steer/)).
The design audit pointed at [beneater/boids](https://github.com/beneater/boids)
at `86b4cb9896f4` (MIT) as a small reference; `SchoolFlock` was written
from the papers, and no code was copied from it.

## Grok credential expiry, 2026-10-12

- **Grok Build**, commit `2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8`, Apache-2.0
  (<https://github.com/xai-org/grok-build>): the credential model declares
  `expires_at` as an optional UTC date, serialized as a date string.
  This informed JR-Bar's expiry input handling; no implementation was copied.
  The installed CLI is 1.0.50 and its local expiry field is a string. Public
  source was not mapped to that binary revision, so renewal commands and
  token lifetimes were not inferred from it.

## Noninteractive Keychain reads, 2026-10-12

- Apple's Security framework declarations for
  [SecKeychainSetUserInteractionAllowed](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:))
  and [authentication UI suppression](https://developer.apple.com/documentation/security/ksecuseauthenticationuifail).
  The local SDK warns that the older query flag alone does not suppress UI
  for legacy Keychain items. JR-Bar disables interaction in an isolated
  reader process and also requests a noninteractive query.
- JR-Bar's pinned keyring 25.7.0 macOS binding, MIT, supplies the existing
  CoreFoundation and Security function declarations. The helper uses this
  dependency without copying its implementation.

## REA competitor scouting, 2026-10-12

- [REA](https://github.com/morluto/rea) 6.4.0, MIT, inspected installed
  Alcove 1.7.9, Bartender 7.0.5 and CodexBar 0.53.0 bundles. Static metadata
  and compiled controls informed comparison targets. No competitor code or
  assets were copied, and runtime animation timing was not measured.
- [CodexBar](https://github.com/steipete/CodexBar), MIT, at installed commit
  `f844f9882458b41c1dc919b48776cfc4957d0009`: credential recovery outcomes,
  reset scheduling and account-card state handling were compared with
  JR-Bar's existing behavior.
- [Hidden Bar](https://github.com/dwarvesf/hidden), MIT, at
  `47937b9d8aede0325ca87a7880af13433e7c5cf8`: source-only comparison of
  spacer, hover and multi-display behavior. No installed runtime was found.

### The 2026-10-13 source reconnaissance

Studied CodexBar, MIT © 2026 Peter Steinberger, at
[`8ec60334`](https://github.com/steipete/CodexBar/commit/8ec6033461e4717dd7501f922a93584ad6a0f713),
and T3 Code, MIT © 2026 T3 Tools Inc., at
[`380bba36`](https://github.com/pingdotgg/t3code/commit/380bba368a9071828616b1b03bde1876cc0af4c8).
No code was copied or executed.

CodexBar's reset scheduler refreshes after a 30-second grace, subject to
ordinary cadence and power constraints. Its celebrations require confirmed
reset events. JR-Bar's current source schedules a known boundary directly;
this comparison does not explain delayed notifications in an older install.
The current source keeps one 15-second recovery when the provider still quotes
the ended window. A new active window reported within 30 seconds of that
boundary retains clock-backed reset eligibility. These changes preserve
account, source and refill checks; synthetic tests do not prove live latency.

T3 Code resolves provider update commands from installation provenance,
including package-manager prefixes, and serializes shared manager operations.
Its usage charts also show unpriced-record coverage and cost categories.
These are targeted improvements to study alongside JR-Bar's existing updater
and usage charts, rather than evidence that either app has runtime parity.

### The 2026-10-14 source comparison

Studied [T3 Code](https://github.com/pingdotgg/t3code), MIT, at
[`11fd54fc`](https://github.com/pingdotgg/t3code/commit/11fd54fcbbfb39f824bb4c908d428c20d801267c)
for usage presentation, provider maintenance and registry metadata. JR-Bar's
provider comparison and daily composition use its own data and native views.
T3 Code is a compatibility integration. Imported usage keeps its source
separate from actual provider identity, and ACP registration does not grant
an account-quota capability. No competitor code was copied.

Rechecked [CodexBar](https://github.com/steipete/CodexBar), MIT, at
[`3bfbf4a5`](https://github.com/steipete/CodexBar/commit/3bfbf4a51d3af6c7307d5aa189e85b3e94390fe8).
The ten reviewed reset and celebration files match the earlier source
comparison. This deeper delivery review does not establish natural reset
accuracy in either installed app.

Studied [Mac Duo](https://github.com/DhananjayBhosale/MacDuo), MIT, at
[`f6862c85`](https://github.com/DhananjayBhosale/MacDuo/commit/f6862c85f02964ac4720fd9c7a2979d812a1b627)
for effect-scoped Escape dismissal. JR-Bar implements its own temporary key
lease and physical-gesture rearm policy.

Studied [Boring Notch](https://github.com/TheBoredTeam/boring.notch), GPL-3.0,
at [`64b54592`](https://github.com/TheBoredTeam/boring.notch/commit/64b545929cf31681e09b5c375859c1eceeb733eb)
for interaction and geometry comparison on macOS 27 Golden Gate. This was
source inspection only, with no copied code or runtime parity claim.


Studied [CodexBar](https://github.com/steipete/CodexBar), MIT, at
[`8ec6033461`](https://github.com/steipete/CodexBar/commit/8ec6033461e4717dd7501f922a93584ad6a0f713)
for Factory's API-key billing endpoints and response fields. JR-Bar
reimplements its own collector and parser. It keeps Standard and Core pools
separate, does not infer replenishment from an expired timestamp, and does
not treat extra-use money as subscription allowance. No browser extraction,
WorkOS login, or competitor runtime is used by this integration.

Consulted [SwiftNIO's syscall handling](https://github.com/apple/swift-nio/blob/3bd6c86af3f269ac91df7c1fbb8f6566f111bcc7/Sources/NIOPosix/System.swift),
Apache-2.0, at
[`3bd6c86a`](https://github.com/apple/swift-nio/commit/3bd6c86af3f269ac91df7c1fbb8f6566f111bcc7)
for capturing `errno` immediately after a syscall. JR-Bar's child-output
reader uses its own per-process state and the existing supervisor queue.
No implementation was copied and no dependency was added.


## Antigravity Argon quota compatibility

Checked Google's [model documentation](https://antigravity.google/docs/models)
and [quota command documentation](https://antigravity.google/docs/cli/commands/usage/)
on 2026-10-16. Also inspected the embedded quota protobuf descriptors in
Antigravity 2.23.1's local language server. The compatibility change uses
reported groups and buckets, keeps Argon separate from legacy Gemini lanes,
and sends the declared request envelope. No vendor implementation was copied.

Argon lanes exist only when the source reports them. The collector does not
force a backend refresh, and the descriptor does not establish the vendor
cache's expiration behavior. Synthetic schema-based fixtures are not captured
live replies.

### Factory browser sessions, 2026-10-16

Studied CodexBar commit `7e60198d7bb31b03a703bd04481011a59e8eb808`,
MIT licensed, including `docs/factory.md`, `FactoryStatusProbe.swift`,
`FactoryLocalStorageImporter.swift`, and `FactorySessionStore.swift`.
Reimplemented the selected Factory local-storage keys, WorkOS refresh
endpoint and public client identifier, JWT organization routing hint,
JWT subject fallback after successful account authentication, scoped
legacy usage queries, and bearer-based Factory billing requests. No code
was copied. CodexBar issue [626](https://github.com/steipete/CodexBar/issues/626)
documents successful account responses that omit `userProfile.id`.

JR-Bar imports only a browser profile the person selects and confirms.
It stores its own session in Keychain, asks separately before usage
requests, verifies the returned account, and never switches to an API
key after a saved browser session fails. Firefox-family imports use
JR-Bar's bounded SQLite snapshot reader. Chromium imports use its
existing bounded LevelDB snapshot reader.

## Runtime notices

The packaged app includes the build interpreter's original Python license.
For Python 3.12.13, the upstream terms are in
[CPython's release license](https://github.com/python/cpython/blob/v3.12.13/LICENSE).
The PyObjC core 12.2.1 wheel omits its license file, so packaging includes
the unchanged MIT notice from
[`pyobjc-core/License.txt`](https://github.com/ronaldoussoren/pyobjc/blob/cb525f3e7f433c851b68725dea54bc70d35681b8/pyobjc-core/License.txt),
commit `cb525f3e7f433c851b68725dea54bc70d35681b8`.
The build checks the PyObjC version and notice hash before copying it.
`ThirdPartyLicenses/runtime-notices.json` records both versions and file hashes.
These notices do not establish complete coverage of statically linked dependencies.

The standalone Python runtime profile comes from Astral's
[`20260602` release](https://github.com/astral-sh/python-build-standalone/releases/tag/20260602),
commit `9150a58ba8fbf6e9f0683ec3d66365e9b3d1d8e8` of the MPL-2.0 build project.
We used its build metadata to select nine original notices for the static
libraries present in our Python 3.12.13 runtime. Each notice keeps its own
upstream terms. No build-system code was copied.
Packaging checks the runtime's version and all executable text sections
before assigning that profile. Other runtimes retain their base notices and
are marked unverified. This profile covers the selected Python runtime,
not every dependency in JR-Bar.

Packaging also preserves the notices supplied with setuptools's vendored
libraries. It checks their original RECORD hashes and sizes before copying,
then records each vendor's name, version and relative source path.
The notice manifest leaves runtime membership unverified; bundled code is
attributed separately. Wheel's metadata and original notice are included
because the runtime inventory found its code in the daemon.


### The 2026-10-17 provider and reset pass

Studied [CodexBar](https://github.com/steipete/CodexBar) at
[`6480977b47`](https://github.com/steipete/CodexBar/commit/6480977b47f6e4ffd5dcaae1cb0c7fdf34ee449e),
MIT, copyright 2026 Peter Steinberger. The registered provider catalog,
Kimi Code, Kilo and Kiro fetchers, credential sources and reset-detection paths
were inspected from this snapshot. Their endpoint and response contracts
informed independent Python collectors and synthetic tests. No code or
provider artwork was copied.

Kimi Code allowances remain separate from Moonshot developer balances.
Kilo credit balances and subscription allowances remain separate, with
reset dates only where the source supplies them. JR-Bar retains its own
consent gate, instance isolation and credential-safe transport.

CodexBar's reviewed celebration path detects session and weekly resets.
JR-Bar's broader confirmed-window trigger follows the owner's request and
also covers daily, monthly and model-specific windows where measured.
Its durable reset journal remains the delivery authority.

The planned-provider list uses product names from the same pinned manifest.


Kiro's `KiroUsageLimitsAPI.swift` and `KiroStatusProbe.swift` at that pinned
MIT snapshot informed the read-only SQLite keys, regional API requests,
plan/overage separation, Unix-second reset validation and CLI-owned login
route. JR-Bar independently implements those contracts in Python. It does
not copy upstream code or assets, invoke the CLI's chat for background
usage, refresh the CLI token, or claim separable trial and bonus usage
from an ambiguous API total.

### Credential ownership and closed-lid review, 2026-10-22

Rechecked CodexBar at
[`aa232d7f`](https://github.com/steipete/CodexBar/tree/aa232d7f9ffce83dcb559bf7a56abc93c477b40c),
MIT, including `docs/claude.md`, `ClaudeOAuthCredentials.swift` and
`FactoryStatusProbe.swift`. Claude Code can recreate its Keychain item and
remove another app's grant. JR-Bar now distinguishes lost access from a
rejected account and stops background reads after access is lost.
CodexBar tries the current browser access token before renewing Factory.
JR-Bar uses an explicit exact-profile permission for continued local reads
and never consumes the browser's refresh token. This replaces the WorkOS
refresh path described in the earlier Factory review above. WorkOS documents
rotation and the retirement of the old token in its
[session resilience guide](https://workos.com/docs/authkit/session-resilience).
No upstream code was copied.

SidePulse `main` remains at the MIT-licensed
[`ffb1d3c2`](https://github.com/inteliwear/sidepulse/tree/ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb).
Its closed-lid controller combines a scoped `pmset disablesleep` helper
with `caffeinate -ims`. Its status controller explicitly requests display
sleep after the lid closes, provided no external display is active.
JR-Bar now makes that guarded request once per lid closure and removes the
closed-lid hold's user-activity assertion. It keeps display and computer
sleep separate, releases the hold when agents finish, and retains its
renewal watchdog. The policy, display-sleep and release tests were rerun.
A physical closed-lid run remains separate from those tests.

### ACP registry identity, 2026-10-25

The ACP Registry at
[`ee673c9d`](https://github.com/agentclientprotocol/registry/tree/ee673c9d848a53717c69ffea5fe2dd1e7286eafa),
Apache-2.0, defines the registry IDs `factory-droid` and `devin`.
JR-Bar reads those IDs from T3's local provider configuration to identify
a generic ACP binding. Custom instance labels do not establish identity.
No upstream code was copied. The daemon makes no registry request.

## Native worker lineage adapters

Cursor's [hooks reference](https://cursor.com/docs/hooks#subagentstart),
checked 2026-10-25, documents `subagent_id` and `parent_conversation_id`.
No Cursor executable or app was available to version locally. The synthetic
fixture names the documentation date. Cursor is proprietary. Its cited
hooks documentation states no open-source licence. The reference was used
for field names only. No Cursor source code was copied.

Hermes' [subagent hook reference](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks#subagent_start)
and local `sessions` table columns were checked on 2026-10-25. The local CLI
was unavailable, so the fixture identifies the schema observation date.
The adapter reads `id`, `parent_session_id` and `started_at` only. Hermes
Agent is MIT licensed. The source reference is commit
[`99a161531cc7b6ce8d91869666ea19cee0610156`](https://github.com/NousResearch/hermes-agent/tree/99a161531cc7b6ce8d91869666ea19cee0610156).
No source code was copied.

OpenCode 1.19.3 was checked with `--version` and read-only SQLite schema
inspection. Its `session.parent_id` and millisecond `time_updated` fields
supply restart recovery. The existing bridge reads `info.id` and
`info.parentID` on session events. The [plugin reference](https://opencode.ai/docs/plugins/)
describes those events. OpenCode is MIT licensed. Version 1.19.3 points to
commit [`e3c4eb242585dcd77be1a867391b7c25fd47ce52`](https://github.com/anomalyco/opencode/tree/e3c4eb242585dcd77be1a867391b7c25fd47ce52).
No source code was copied.

OpenClaw 2026.3.2's installed hook and session declarations document
`event.sessionKey`, `context` and `SessionEntry.spawnedBy`. The
[nesting reference](https://docs.openclaw.ai/tools/subagents/nesting), checked
2026-10-25, also names `spawnedBySessionId`. The local registry maps that
native ID back to the hook's session key. The fixture for the newer field
names the documentation date, since it is absent from the installed version.
OpenClaw is MIT licensed. Version 2026.3.2 points to commit
[`85377a28175695c224f6589eb5c1460841ecd65c`](https://github.com/openclaw/openclaw/tree/85377a28175695c224f6589eb5c1460841ecd65c).
No source code was copied.

Gemini CLI's installed 0.46.0 bundle, `ChatRecordingService.initialize`,
writes subagent metadata to `tmp/<project>/chats/<parentSessionId>/<child>.jsonl`.
The reader requires `kind: subagent` and matching header and filename IDs,
then reads the immediate parent directory. It reads no message records.
The [upstream version](https://github.com/google-gemini/gemini-cli/tree/v0.46.0)
is Apache-2.0 licensed and points to commit
[`85b0c55c126a4992b51d140e357ae9db5f9c2d7f`](https://github.com/google-gemini/gemini-cli/tree/85b0c55c126a4992b51d140e357ae9db5f9c2d7f).
No source code was copied.

Grok 1.0.70, commit `f50904eaee6c`, was checked with `--version`. Its
`SubagentStart` shape matches the synthetic 1.0.44 hook capture already
recorded in `tests/test_grok_subagents.py`. Recovery uses JR-Bar's own
content-free normalized logs, including older `parent_work_id` records.
No Grok source code was copied. A start absent from every source remains
unlinked.

### Incremental token history, 2026-10-25

Reviewed T3 Code at
[`5b354026`](https://github.com/pingdotgg/t3code/tree/5b354026),
[MIT](https://github.com/pingdotgg/t3code/blob/5b354026/LICENSE), especially
`apps/server/src/usage/UsageService.ts` and `usageAggregation.ts`.
Its shared usage service and provider/model/source buckets informed JR-Bar's
persistent hour/day/model index and shared range views. JR-Bar retains its
own transcript parsers, guarded resume offsets, Codex lineage rules and
pricing. SQLite transactions update deduplicated records and buckets together.
No upstream code or assets were copied.

### Process launch identity, 2026-10-26

Reviewed Apple's [XNU process-argument query](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_sysctl.c),
commit `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`, under APSL 2.0,
and the [Darwin ps command reader](https://github.com/apple-oss-distributions/adv_cmds/blob/6bed8737a34dbb54782a18f47dccf933a9967a12/ps/print.c),
commit `6bed8737a34dbb54782a18f47dccf933a9967a12`, under its BSD licence.
The query returns the top of the argument area when the buffer is short,
so JR-Bar queries the required size before decoding the saved launch path.
It keeps that path separate from libproc's resolved executable and erases
the transient argument buffer. No source code was copied.

### Headless power observations, 2026-10-26

Reviewed Apple's [IOPMLib declarations](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/pwr_mgt.subproj/IOPMLib.h),
commit `323ead896d04424f87184d8f6ff0cce811aab106`, under APSL 2.0.
The daemon acknowledges only the two sleep requests that require it, then
closes the notifier, notification port and connection in the documented
order. CoreGraphics display and session declarations were checked against
the local macOS SDK. No source code was copied.


## Headless HID backend

JR-Bar compiles its existing `hidapi==0.14.0.post4` dependency from the
reviewed source archive, SHA-256
`48fce253e526d17b663fbf9989c71c7ef7653ced5f4be65f1437c313fb3dbdf6`.
The Darwin implementation studied is
[HIDAPI commit d3013f0](https://github.com/libusb/hidapi/blob/d3013f0af3f4029d82872c1a9487ea461a56dee4/mac/hid.c),
under its BSD 3-Clause licence. The Python wrapper and its generated C
come from the pinned cython-hidapi archive. Its licence files remain in
the rebuilt wheel and the packaged notices.

`packaging/build_headless_hidapi.py` replaces the Darwin backend's
`NSAppKitVersionNumber` comparison with Clang's macOS availability check
and removes the AppKit linker flag. It keeps the same OS threshold,
Python binding and HID operations. It builds the archive's generated C
without adding Cython to the release build environment.

### Provider identity and marks, 2026-10-26

Factory's emblem comes from `docs/logo/dark.svg` in
[Factory-AI/factory at 892925c655a97e7a0bc7d558236015ebb22cb214](https://github.com/Factory-AI/factory/blob/892925c655a97e7a0bc7d558236015ebb22cb214/docs/logo/dark.svg).
Factory retains all rights. JR-Bar uses the emblem to identify Factory,
with the upstream wordmark and attribution retained in the provider assets.
Kimi and Kilo use the existing LobeHub Icons source at
`49a2130df7bfa5eb1b088261bff20a37e2967789`, under its MIT licence.

## DockDoor native app previews, 2026-10-27

Studied DockDoor 1.41.0, commit
[`3d6a3cbaa9bbee17959122da7f0a349ca43056d0`](https://github.com/ejbills/DockDoor/commit/3d6a3cbaa9bbee17959122da7f0a349ca43056d0),
GPL-3.0. Read only its
[README](https://github.com/ejbills/DockDoor/blob/1.41.0/README.md),
[website](https://dockdoor.net/), and
[release notes](https://github.com/ejbills/DockDoor/releases/tag/1.41.0).
The website identifies the licence and describes independent widget switches.
The README describes Calendar events and a player on the app playing audio.
These behaviors informed JR-Bar's Dock cards and their separate switches.
JR-Bar reuses its shelf calendar reader and shared Alcove MediaRemote feed.
No DockDoor implementation source or assets were read or copied.

## JavaScriptCore value ownership, 2026-10-27

Studied WebKit's
[JSValue.mm](https://github.com/WebKit/WebKit/blob/321def29e1c8634b4a5ef5299981ab00850e50fe/Source/JavaScriptCore/API/JSValue.mm)
and
[JSContext.mm](https://github.com/WebKit/WebKit/blob/321def29e1c8634b4a5ef5299981ab00850e50fe/Source/JavaScriptCore/API/JSContext.mm)
at commit `321def29e1c8634b4a5ef5299981ab00850e50fe`, under their BSD 2-Clause licence.
`JSValue` protects its JavaScript value and retains its context before returning
to the caller. JR-Bar calls these public native APIs through its existing
Objective-C adapter so unprotected values never cross into Python. No WebKit
implementation code was copied.

## Core Audio tap permissions, 2026-10-29

Studied the entitlement file and build settings in Apple's
[Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
sample. The sample enables the hardened runtime and includes
`com.apple.security.device.audio-input`. This informed the visualizer's
resource entitlement. No implementation code was copied.

The official sample archive has no published Git commit. Its SHA-256 is
`46edc0114dd5ecb11fdfd1b87b1f57628be71988a460c5cb0b831a237a5fe657`.
The archive's `LICENSE.txt` is MIT, copyright 2024 Apple Inc.


## Factory API-key authentication, 0.10.2

Reviewed Factory's [Analytics API authentication](https://docs.factory.com/api-reference/analytics)
on October 29, 2026. It documents `Authorization: Bearer` for keys created at
[Factory's API-key settings](https://app.factory.ai/settings/api-keys).
The [Droid CLI reference](https://docs.factory.com/droid-cli/cli-reference)
documents `FACTORY_API_KEY`. These are provider documentation, with no pinned
source commit or source licence; no code was copied. The earlier pinned
CodexBar reviews above remain the source credit for the dashboard endpoints.

JR-Bar sends the selected key to `/api/app/auth/me`, `/api/billing/limits` and,
for legacy billing, `/api/organization/subscription/usage` on `api.factory.ai`.
The public documentation does not guarantee these dashboard endpoints or their
response shapes for API keys. Synthetic tests verify request construction and
parsing; a real key must still confirm account access and reported allowances.
JR-Bar does not consume browser-owned WorkOS refresh tokens.
