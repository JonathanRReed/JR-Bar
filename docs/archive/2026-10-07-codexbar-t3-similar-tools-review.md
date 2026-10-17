# CodexBar, T3 Code and similar tools: review of 2026-10-07

> **Historical.** A dated research note. The live cadence is
> [UPSTREAM-RESEARCH-CADENCE.md](../UPSTREAM-RESEARCH-CADENCE.md) and the
> ledger for this pass is [UPSTREAM-REFRESH-2026-10-07-02.md](../UPSTREAM-REFRESH-2026-10-07-02.md).

Reviewed 2026-10-07 (America/Chicago). Read-only: GitHub through `gh`, scratch
clones under `/tmp`, the pricing pages and the Claude Code and Codex changelogs.
Everything fetched is untrusted data; none of it was run. No upstream code was
copied; each port below was written test-first against synthetic fixtures.

The installed versions on this Mac:

| Tool | Version | Source |
| --- | --- | --- |
| Claude Code | 2.1.292 | `claude --version` |
| Codex CLI | codex-cli 0.159.2 | `codex --version` |
| T3 Code Nightly | 0.0.46-nightly.20261006.2752 | `/Applications/T3 Code (Nightly).app` Info.plist, read only |

What was compared:

- CodexBar `e34fe618` (0.66.0, last reviewed 2026-09-24) to `03a51bdc`
  (0.73.0): 816 commits, 458 non-merge, 77 issues opened since 2026-09-24.
- T3 Code `cb1a3f34` (0.0.43 nightly, last reviewed 2026-09-24) to `611132c1`
  (0.0.46 nightly): 569 commits.
- ccusage `03f421fa` (20.0.25) to `f3b78d10` (20.0.26).
- The Claude Code changelog 2.1.170 to 2.1.292 and the Codex release notes and
  source 0.136.0 to 0.160.1.
- OpenUsage, ccstatusline, ClaudeBar, cmux, Stats and the other tools named in
  section 5.

## Dispositions

- **ported**: JR-Bar now does it; the commit is named.
- **superseded**: JR-Bar already had it, or has a stronger version; where.
- **not applicable**: the reason it does not reach JR-Bar.
- **risk**: not fixed here; what could go wrong and what would fix it.
- **waiting**: plausible, but it needs a live drill, a payload sample or the
  owner's decision. These match the cadence's "waiting on evidence".

## 1. T3 Code

| Item | Upstream | Disposition | JR-Bar |
| --- | --- | --- | --- |
| Live threads, runs, requests and plans moved to `userdata/statev2.sqlite`; the `projection_*` tables in `state.sqlite` are a frozen copy | [`de343914`](https://github.com/pingdotgg/t3code/commit/de343914273eceb852a1d1d739cd1d38df7796ee) (#2829), first in `v0.0.46-nightly.20261003.2610` | **ported** | `2ddc7c04`. On this Mac the legacy file last changed Oct 2 while the v2 file is live, so the T3 list was five days old and one stale plan read "Plan ready" for good. |
| Stable 0.0.45 still writes `state.sqlite` | upstream docs, `docs/internals/legacy-orchestration-migration.md` | **ported** | The fresher of the two files (database or write-ahead log) is read, so going back to stable reads the right one. |
| Provider-native subagent threads are separate top-level rows | `packages/contracts/src/orchestrationV2.ts`, `ThreadNotificationCoordinator.tsx` skips them | **ported** | `2ddc7c04`: 79 of 119 thread rows here are subagents and are not listed. |
| A held queued run is a note to itself, not work | `Orchestrator.ts` (`queueHeld`) | **ported** | `2ddc7c04`. |
| No `pending_approval_count` / `has_actionable_proposed_plan` columns in v2 | `ProjectionStore.ts` `threadShellFromProjection` | **ported** | `2ddc7c04` derives them from pending `runtime_requests` (anything but `user_input` is an approval) and active `proposed_plan` plans. |
| `modelSelection.options` is an array of `{id, value}` | `packages/contracts/src/model.ts` | **ported** | `2ddc7c04`: reasoning effort was always empty on real data. |
| `claudeAgent` and `acpRegistry_<name>` drivers read as "other" | `model.ts`, `acpRegistry.ts` | **ported** | `2ddc7c04`: Claude and Devin threads (12 here) now carry their provider. |
| Desktop reads `T3CODE_HOME`, not `T3_HOME` | `apps/desktop/src/app/DesktopConfig.ts` | **ported** | `2ddc7c04`; `T3_HOME` still works as the fallback. |
| Activity statistics need the v2 per-turn usage | `providerRuntime.ts` `TurnTokenUsage` (input includes cache reads and writes) | **ported** | `ba3f113f`. |
| Migrations 054 to 058 | `010967041` and later | **not applicable** | Additive tables and dropped indexes; no column JR-Bar reads moved. |
| `/ws` needs `orchestrationProtocol=2` (HTTP 426), auth scopes, rotating desktop bootstrap token, OAuth for the T3 MCP server, port 3773 | `ws.ts`, auth PRs #9785 to #10298 | **not applicable** | JR-Bar never uses T3's API, credentials or MCP. |
| Delegate tasks, queues, merge-back, worktree handoff, scheduled and webhook tasks, PR watches, secret requests | `orchestratorMcp.ts`, migrations 057 and 058 | **not applicable** | JR-Bar stays read-only and calls none of it. |
| A waiting `secret_request` card counts as pending input in T3's shell | `ProjectionStore.ts` | **waiting** | Not read; the card lives in turn items, and needs a sample from a real run. |
| `t3code://threads/<env>/<thread>` is not handled by the desktop app (only auth hand-off and `t3code://app/`) | `DesktopClerk.ts` | **risk** | The link stays an experimental, unverified candidate. If Settings ever offers it as a click, test it first. |
| SQLite write-ahead log shrink and write-lock changes | `8aa5be2f0`, `0fe4fa40f`, `d06f0ff10` | **risk (low)** | JR-Bar opens, reads and closes in about 5 to 30 ms warm (293 ms the first cold time, under its 0.5 s budget) and keeps the last good list when a read fails. |
| Dual-version setups (stable and a nightly side by side) | | **risk** | The newer write wins; if both are live the choice is a heuristic. |
| v2 `payload_json` fields can still change in nightlies | | **risk** | Everything else is read from stable columns, unknown fields are ignored, and a missing required column fails closed as unsupported. |
| Pull-request metadata now sits in thread payloads (`linkedPullRequest`, `pullRequests`) | | **waiting** | Not read. INTEGRATIONS.md no longer says T3 exposes none. |

## 2. CodexBar 0.67.0 to 0.73.0

Releases: [0.67.0](https://github.com/steipete/CodexBar/releases/tag/v0.67.0),
[0.68.0](https://github.com/steipete/CodexBar/releases/tag/v0.68.0),
[0.69.0](https://github.com/steipete/CodexBar/releases/tag/v0.69.0),
[0.70.0](https://github.com/steipete/CodexBar/releases/tag/v0.70.0),
[0.71.0](https://github.com/steipete/CodexBar/releases/tag/v0.71.0),
[0.71.1](https://github.com/steipete/CodexBar/releases/tag/v0.71.1),
[0.72.0](https://github.com/steipete/CodexBar/releases/tag/v0.72.0),
[0.73.0](https://github.com/steipete/CodexBar/releases/tag/v0.73.0).

Providers JR-Bar collects natively are Codex, Claude, Cursor, Devin, Grok,
Antigravity, Gemini, OpenCode Go and the OpenAI API org. CodexBar's other 80
providers (Kimi, Ollama, JetBrains, Vertex, Mistral, Langdock, WorkBuddy, Muse,
LithosAI, Nous, xKiro, Raycast, Aixy, ClinePass and the rest) are **not
applicable**: JR-Bar has no collector for them, and a new one is a product
decision, not a port.

### Cost and token accounting

| Item | CodexBar | Disposition | JR-Bar |
| --- | --- | --- | --- |
| Claude one-hour cache writes bill at 2x input | `CostUsageScanner+Claude.swift`, `CostUsagePricing.swift` | **ported** | `646808a0`: split from `usage.cache_creation.ephemeral_1h_input_tokens`, to the 30-day card, graph, history and per-session cost. |
| Pi / OMP one-hour cache-write counters (`cttl.ephemeral1h`) | [`43c1e338`](https://github.com/steipete/CodexBar/commit/43c1e338eaee58f0ec5e9282b0eebc0a8e97a2a1), #4121, #4176 | **ported** | `fb53b827`. |
| Long-context threshold is 272K input for GPT-6 and GPT-5.4 to 5.6 families, the whole request repriced | [`04b23bed`](https://github.com/steipete/CodexBar/commit/04b23bed620dfbad985ca3a30848f798eaa9c62c), #4302 | **ported** | `646808a0`; the old price-table comment said "not modelled". |
| New model rows (GPT-6 Sol, 6.1 Sol, Luna, GPT-5.5 and Pro, Cyber) | `CostUsagePricing.swift` | **ported** | `6a3d6728`, but every rate was checked against OpenAI's page, not copied. The old `gpt-6` marker priced Sol and Luna at Astra's $10/$50 and GPT-5.1 to 5.5 at $2.50/$15. |
| Resumed sessions recover usage after a counter reset; request ledger (`token_usage_record`) with mirrors that drift | #3303, #4195, #4289, #4290 | **superseded** | JR-Bar derives each request from `last_token_usage` and only falls back to the cumulative counter, so a reset does not erase usage; `tests/test_codex_usage_lineage.py` covers copies and forks. CodexBar's SQLite request ledger and mirror pairing are not needed. |
| Compaction requests the counter never added | #4195 and ccusage #1821 | **ported** | `d51ca634`, and `244a7307` for the compacted items that are over the one-megabyte line cap (24 of the 70 in the last 30 days on this Mac, up to 3 MB: they would have made coverage partial). A record whose marker lands in a later scan than the record itself is missed until the next full rescan; both land within milliseconds of each other. |
| Priority / Fast service tier priced at 2x (2.5x for GPT-5.5), from `thread_settings_applied.service_tier` | #4274, #4276, `7da388e1` | **waiting** | Not implemented: the field spelling (`priority`, `fast`, `standard`, `default`) needs a rollout sample from a real Fast turn on this Mac before pricing from it. |
| Partial estimates when a request is unpriced (priced subtotal plus an unpriced count) | #4273, #4278, #4279 | **superseded** | `PricingCoverage` and `priced_records` already keep an unpriced model visible and a partial estimate marked. |
| Dated Sol repricing (August 21), Cyber fallback rates, model aliases | `122051e0`, `fb7d4a91` | **waiting** | History before 2026-08-21 priced at the old Sol $5/$30 is not modelled; a flat current price is used. |
| Cost scans use less memory and CPU (streamed SQLite rows, shared strings, reused decoders) | many `perf(cost)` commits | **not applicable** | JR-Bar's scanner is Python, marker-gated and incremental; its own measurements are in `tests/test_usage_card_busy_month.py`. |
| Local history older than the scan cap | | **risk** | `USAGE_FILE_MAX_BYTES` is 64 MiB. On this Mac 3 Claude transcripts and 151 Codex rollouts exceed it, 5 of them written in the last 30 days (two today, up to 3.8 GB). Coverage is flagged partial, honestly, but the heaviest sessions are missing from the totals. |

### Claude

| Item | CodexBar | Disposition | JR-Bar |
| --- | --- | --- | --- |
| Usage request identifies the installed Claude Code version | `ProviderVersionDetector`, #4292 neighbours | **ported** | `e2f27ede`. It sent `claude-code/2.1.0` forever. OpenUsage [`00189454`](https://github.com/robinebers/openusage/commit/00189454816cc3d815a166fa1369d6fe67dd2405) saw the stale `2.1.69` answered "ineligible" on the reset-grants query. |
| Saved limit resets (`cedar_ember`) and cloud-session credits | `05a6a434`, `a701a0de`, #4194, #4232, #4048 | **waiting** | The reset query is an undocumented `?cedar_ember=1` parameter on Anthropic's endpoint. JR-Bar's Claude request stays parameter-free until there is a documented way. |
| Unmeasured session placeholder is "unavailable", not 100 % | #4107, `f2db790e` | **superseded** | `claude_quota.windows_from_payload` carries a window with no percentage as "present, no reading" (`utilization: None`). |
| Model-scoped weekly quota stands in when the regular windows are absent | #4126, #4159 | **superseded** | `limits[]` scoped windows become their own lanes with tests; which lane the menu bar shows is the app's choice. |
| Usage probes skip user hooks; CLI `/usage` breaks on 2.1.281; PTY trust dialogs; MCP servers in the `/usage` fallback | #4292, #4083, #4115, #4112 | **not applicable** | JR-Bar reads the OAuth endpoint and the status line; it never starts `claude` to scrape `/usage`. |
| Keychain: cache-write recovery through token refresh, bounded signature check, explicit-refresh prompts | #4242, #4271, #4089, #4257 | **not applicable** | JR-Bar does not consume Claude's refresh token or write its Keychain item (`credential_needs_sign_in`); reads are bounded (`credentials._SECURITY_PROMPT_TIMEOUT_SECONDS`) and never prompt in the background. The older PRIOR-ART text about direct refresh describes the 0.7 build. |
| 429 gate keyed by token, honouring Retry-After, five-minute default | `ClaudeOAuthUsageRateLimitGate` | **superseded** | `provider_usage_codex_claude` rests OAuth after a failure and stands in the status line meanwhile; the runtime's backoff ladder covers `RATE_LIMITED`. |
| Plan-usage history splits on each refresh-token rotation | #4322 (open) | **not applicable** | `usage_percent_history` deduplicates at the exact account source, not by token. |
| Claude Enterprise extra usage missing from the compact overview | #4320 (open) | **waiting** | Needs an Enterprise payload; none on this Mac. |

### Codex

| Item | CodexBar | Disposition | JR-Bar |
| --- | --- | --- | --- |
| "Auto source consumes the 5-hour allowance while idle; OAuth-only does not" | [#4283](https://github.com/steipete/CodexBar/issues/4283) (closed by bot review, cause unproven) | **risk** | JR-Bar spawns `codex -s read-only -a never app-server` for `account/rateLimits/read` and `account/read` only: no thread or turn is started, so it should cost no inference. Unproven either way; the owner can compare the Codex usage page across an idle day. |
| Codex discovery refuses unsafe Node environments and relative PATH entries | #4136, #4143, `3ce4da88` | **ported** | `23d97c9c`: absolute PATH entries only, in the live probe and the version lookup. |
| Weekly quota recovers after a reset when the previous snapshot lacked credit inventory | #4210 | **not applicable** | JR-Bar takes a fresh app-server read each time and confirms resets by a second read (`provider_usage_qol.confirm_reset_events`). |
| Plan upgrade discards the old plan's quota baseline | #3635, #3389 | **waiting** | A plan change mid-window is not special-cased in the pace forecast. |
| Managed account list and promotion CLI, dashboard schema | #3191, #4234, #4184 | **not applicable** | JR-Bar's account homes are read-only (`provider_homes.py`) and it never swaps credentials. |
| Adaptive refresh keys off rollout modification times | #4119 | **not applicable** | JR-Bar polls on its own cadence and hook events. |
| Codex System Account switch restarts the app-server | #3990, #4018 | **not applicable** | JR-Bar spawns its own short-lived app-server per probe. |

### Cursor, Grok, Antigravity, Gemini, OpenCode

| Item | CodexBar | Disposition | JR-Bar |
| --- | --- | --- | --- |
| Antigravity quota-summary bucket states its cadence (`window`: `weekly` / `5h`); Starter accounts have weekly groups only | [`62acfd8e`](https://github.com/steipete/CodexBar/commit/62acfd8ead86a3ae443ec2d76c30c93ec72e09b4), #4084 | **ported** | `cb398d1e`: a bucket named "Limit Remaining" was read as a 5-hour lane; weekly-only groups invent no 5-hour lane. |
| Antigravity consumer OAuth client, per-account `agy` sessions, Hub user agent | #4293, #4103, #4229 | **not applicable** | JR-Bar reads the running app's or `agy`'s loopback server and never signs in. |
| Antigravity local token totals: model ids excluded, schema budget per database | #4124, #4133 | **waiting** | Needs a look at JR-Bar's Antigravity history reader against a 2.19 database. |
| Cursor "Grok Bot" weekly allowance (`/api/dashboard/get-sand-usage-status`) and its pace | #4207, #4221, #4222 | **waiting** | Adds a second undocumented dashboard call; it needs the owner's consent and a check that Cursor.app's token is accepted by it. |
| Grok purchased credits in the usage export; local scans skip artifact trees | #4239, #4209 | **not applicable** | JR-Bar's Grok history reads only `updates.jsonl` turn-completed events. |
| Gemini: Flash-Lite-only accounts show the third window | #4128 | **not applicable** | Gemini lanes are per-model detail lanes, shown as they come. |
| OpenCode Go local token counts without inventing costs | #3995 | **superseded** | `collect_opencode` and `_scan_opencode_records` read only the token counts OpenCode recorded; a model no table knows stays unpriced. |
| OpenCode Console migrated workspaces | #4131, #4139 | **not applicable** | JR-Bar uses the Go key endpoint only. |

### Status, sessions, settings, security, menu bar

| Item | CodexBar | Disposition | JR-Bar |
| --- | --- | --- | --- |
| An older status request must not replace a newer incident | [`09537336`](https://github.com/steipete/CodexBar/commit/0953733615b929805e8c86ac58d5d1f94284bd3b), #4175 | **ported** | `60330d16`. |
| Agent sessions started before an in-place CLI update stay listed | [`73e73789`](https://github.com/steipete/CodexBar/commit/73e7378949b1b566b22fc965d1e20252c2b08175), #4120 | **not applicable** | JR-Bar finds processes by `ps` command name and `sessions/<pid>.json`, not `proc_pidpath`, so a deleted binary does not hide a session. |
| Empty config file reads as missing | #4071, #4081 | **superseded** | An empty settings file is set aside as unreadable and defaults load; usage keeps working. |
| Redact stored process environments in diagnostics | #4097, #4106 | **superseded** | `doctor.py` reads no environment values into its output. |
| Reset notifications with remembered boundaries | #4138, `6c070c72` | **superseded** | `provider_usage_qol.confirm_reset_events`, `provider_usage_event_store` and the usage hooks. |
| Stay Awake while a local agent is live; credential-expiry alerts | #2740, #2512 | **superseded** | `core_power` keep-awake and the Fix sign-in flow. |
| Widgets keep the last good reading after a failed refresh | #4095 | **superseded** | JR-Bar keeps the last good reading and marks it stale. |
| Status-item identities, blank slots after quit on macOS 26.6.2, Dock icon on macOS 27.0, high CPU from a hidden blink timer | #4021, #3201, #4101, #4244 | **not applicable** | Menu bar work belongs to another lane; JR-Bar owns one status item. Worth a look when the menu-bar lane next verifies macOS 27. |
| Linux snapshots, plugins, 80 more providers, iCloud sync, Homebrew updates, portable preferences, currency choices, QuickJS bundles | many | **not applicable** | Not in JR-Bar's product. |

## 3. Claude Code 2.1.170 to 2.1.292 and Codex 0.136 to 0.160

Sources: the [Claude Code changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md),
the [hooks guide](https://code.claude.com/docs/en/hooks), the
[status line guide](https://code.claude.com/docs/en/statusline), the
[Codex releases](https://github.com/openai/codex/releases) and the
`codex-rs` hook schemas, rollout policy and approval source. The hook docs came
through a summarising fetch, and two summaries disagreed on `StopFailure`
(`error` or `error_type`) and `SessionEnd` (`reason` or `exit_status`). JR-Bar
reads none of those fields.

| Item | Version | Disposition | JR-Bar |
| --- | --- | --- | --- |
| Esc interrupt fires no Claude hook; a live process outranks the silence timer, so the row stayed Working | long-standing; `sessions/<pid>.json` now carries `status` (`busy` / `idle`), `statusUpdatedAt` | **ported** | `bb35c378`: the liveness sweep ends the turn with an `Interrupt` when the file went idle after the last hook. Shape checked on this Mac (keys and the two status values only). |
| Codex `turn_aborted` (reason `interrupted`, `replaced`, `review_ended`, `budget_limited`) and typed `task_complete.error` (`codex_error_info`) | `protocol.rs` | **ported** | `9c79546d`, for the rollout fallback used when hooks are untrusted. Free-form error text still reads as a normal stop. |
| New top-level rollout item `token_usage_record` (response id, `usage`, `thread_token_usage`) | Codex 0.153 | **ported** | `d51ca634` (compaction only); ordinary responses are still counted from `token_count`. |
| 1-hour cache writes in Claude transcripts | 2.1.x | **ported** | `646808a0`. |
| `SessionStart` with `source: "compact"` fires mid-turn | Codex #34396, Claude docs | **waiting** | Mapping it to Working would stick a manually compacted session as Working (no Stop follows). Needs a live compaction drill; `PostCompact` already sets Working. |
| `Stop` carries `background_tasks[]` and `session_crons[]`; Agent spawns run in the background by default | 2.1.145, 2.1.232 | **risk** | The main row can read Completed while a background agent runs. The worker rows keep the aggregate active, so the cost is a misleading parent row. |
| Codex `request_user_input`, `request_user_input_async`, `request_permissions` have no hook | 0.153 | **risk** | The ask shows as Working, then "ended unconfirmed" after 240 s. The call is in the rollout as a `function_call`; mapping it needs a live sample. |
| Codex runs `PermissionRequest` hooks before the reviewer | `core/src/tools/approvals.rs` | **risk** | With `approvals_reviewer` other than `user`, every approval would stall up to 45 s and show a false Needs-you card. This Mac uses `user`. |
| New `rate_limits` fields: `rate_limit_reached_type`, `spend_control_reached`, `individual_limit` | Codex rollouts | **waiting** | A blocked team or enterprise account could look healthy; needs a payload from one. |
| Rollout compression to `.jsonl.zst` | Codex, feature off by default | **risk (latent)** | None on this Mac (5,812 `.jsonl`). If enabled, 7 to 30 day history would vanish from the card; the scanner only reads `*.jsonl`. |
| Stacked permission prompts ("2 of 5"); a subagent's prompt surfaces in the main session | 2.1.186, 2.1.286, 2.1.287 | **risk** | The in-place keystroke fallback lands on the displayed prompt. The decide lane is unaffected. |
| New Claude Notification types (`elicitation_complete`, `agent_completed`, `quota_auto_resume_*`) | 2.1.234 | **superseded** | Unknown types are inert; `agent_needs_input` and the elicitation dialogs are mapped. |
| `usage.iterations[]`, `speed: "fast"`, `service_tier`, `fallback_credit`; Opus fast mode $8 to $10 input | 2.1.x | **waiting** | None in the last 400 transcripts here; confirm with a real sample before pricing. |
| Managed settings `allowManagedHooksOnly` / `disableAllHooks`, Codex `requirements.toml` | | **risk (low)** | `jrbar hooks doctor` does not check managed policy. |
| Hook compatibility manifest lists only `=2.1.263` and `=0.153.4` | | **risk (low)** | Doctor says "newer than verified" for 2.1.292 and 0.159.2. A live drill (`scripts/verify_providers_live.py`) is the owner's to run and was not run here. |
| Codex hook trust hash, event list, `PermissionRequest` output, `agent_id`, session source `fork`, `CLAUDE_CONFIG_DIR` / `CODEX_HOME` | | **superseded** | All 12 hashes JR-Bar computes match the `trusted_hash` values in this Mac's `config.toml`; the 12 hook events equal `EVENT_KEYS`. |
| Status line `rate_limits.five_hour` / `seven_day`; `spend_limit`, `prompt_cache` | 2.1.243 and later | **superseded** | `claude_statusline_source.py` keeps the windows, drops expired ones, ignores the rest on purpose. |

## 4. Pricing

Checked 2026-10-07 against
[Anthropic](https://platform.claude.com/docs/en/about-claude/pricing),
[OpenAI](https://developers.openai.com/api/docs/pricing) and
[Gemini](https://ai.google.dev/gemini-api/docs/pricing). The table is
`jrbar-rates-v4`; `scripts/update_model_pricing.py` takes a local LiteLLM file or
the hand table and cannot add a row, and against today's LiteLLM file every
marker disagrees across Bedrock and regional entries, so it would only have
bumped the date. The rows were added by hand, then the script wrote the
snapshot with `--from-table`.

| Model | Was | Now |
| --- | --- | --- |
| Claude Opus 5.5 | generic Opus $5/$25, cache read 0.1x | $4/$20, cache read 0.05x |
| Claude Sonnet 5.5 | Sonnet 5 row ($2/$10) by accident | explicit row |
| GPT-6.1 Sol, GPT-6 Sol | `gpt-6` Astra $10/$50 | $2/$10, cache read $0.10 (6.1) or $0.20 |
| GPT-6 Luna | $10/$50 | $0.10/$0.50 |
| GPT-5.5, 5.5 Pro, 5.4 Pro | `gpt-5` $2.50/$15 | $5/$30, $30/$180 |
| GPT-5.3-Codex, 5.2 | $2.50/$15 | $1.75/$14 |
| GPT-5.1, GPT-5, 5-Codex | $2.50/$15 | $1.25/$10 |
| GPT-5.1-Codex-mini, GPT-5 mini / nano / Pro, GPT-5.2 Pro, Cyber | `gpt-5` | their own rows |
| Gemini 3.5 Flash / Flash-Lite, 2.5 Pro / Flash / Flash-Lite | `flash` / `pro` | their own rows |

Not modelled: Opus fast mode, Gemini 3.1 and 2.5 Pro prompts over 200K, the 1.1x
US data-residency multiplier, the end-of-2026 Gemini Flash price rise, the
GPT-5.6 Sol promotional price ending 2026-11-21, and Priority / Fast tiers.
`gpt-5.3-codex-spark` is a research preview with no API price; it now matches
the GPT-5.3 row and is an overestimate (it matched `gpt-5` before).

## 5. Similar tools

| Tool | Notable change | Disposition | JR-Bar |
| --- | --- | --- | --- |
| [ccusage](https://github.com/ryoppippi/ccusage) 20.0.26 | Codex compaction usage by `response_id` (#1821, [`8f32f3c`](https://github.com/ryoppippi/ccusage/commit/8f32f3c)); about 310 of 328 commits are automatic price refreshes | **ported** | `d51ca634`, `244a7307`. |
| ccusage | Requestless Claude dedupe keyed on message id, session and timestamp (#1799) | **waiting** | JR-Bar skips a message without an id rather than guess. |
| ccusage | Fast and flex tiers, over-272K tiers | **ported** (272K) / **waiting** (tiers) | `646808a0`; tiers need samples. |
| ccusage | OpenCode fork copied-history cutoff (#1782); Pi `pricingOverrides`; mtime pruning | **not applicable** | JR-Bar has its own overrides and file-index pruning. |
| [OpenUsage](https://github.com/robinebers/openusage) (MIT) | A stale user agent was answered "ineligible" on the reset-grants query | **ported** | `e2f27ede`. |
| OpenUsage, CodexBar | Keep the whole credential document on rotation | **not applicable** | JR-Bar never rotates or writes Claude's Keychain item. |
| ccstatusline 2.2.23 to 2.2.30 | A scoped weekly window at 0 % with no `resets_at` is a real zero | **superseded** | `windows_from_payload` keeps a stated 0 as a reading. |
| brow, other trackers | Within one `resets_at` window usage only grows, so a lower reading keeps the higher one | **not applicable** | JR-Bar does not merge the OAuth reading with the status line; the status line stands in only while OAuth rests. (Licence GPL-3: idea only, nothing read.) |
| ClaudeBar, cmux | `StopFailure` clears a stuck Working row; probe sessions are tagged and ignored; no notifications after an interrupt | **superseded** | `StopFailure` maps to a failed turn; JR-Bar starts no probe sessions. |
| claude-notch | A hook shared secret; "too late to answer" | **superseded** | The hook shim speaks to a private same-user socket; the too-late path exists. Any answer still comes from a person. |
| Stats (exelban) | macOS 26 / 27 status-item popup fix for hidden Dock icons (#3587) | **not applicable** | Menu bar lane. |
| Claude-Code-Usage-Monitor, CCometixLine, disler's hook collections, vibetunnel, Raycast extensions, Stream Deck plugins | Dormant, build-only or nothing JR-Bar lacks in the window | **not applicable** | |

## 6. Open items, in the order they matter

1. Heavy local history: raise or replace the 64 MiB scan cap so the biggest
   Codex rollouts count (**risk**).
2. A live Claude and Codex hook drill against 2.1.292 and 0.159.2, then bump
   `provider_hook_compatibility.json`.
3. Codex Priority / Fast pricing, once a real Fast rollout is on hand.
4. Codex `request_user_input` asks and `approvals_reviewer` other than `user`.
5. Whether to add the Cursor Grok Bot lane and Claude saved resets, which both
   need an undocumented request and the owner's consent.
