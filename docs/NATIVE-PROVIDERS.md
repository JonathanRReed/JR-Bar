# Native provider usage

JR-Bar owns provider accounting directly. CodexBar is an engineering reference only; it is never launched, queried, imported, or required at runtime. The only external application integrations are T3 Code and Alcove.

## Supported providers

| Provider | Native sources | Main facts |
| --- | --- | --- |
| ChatGPT / Codex | Codex OAuth usage API, `codex app-server`, local Codex records | whichever of the five-hour and weekly account limits the plan actually has, plan name, dynamic sub-cap lanes such as Spark, credits, resets, tokens, models, and estimates |
| Claude | Claude OAuth usage API, consented Claude browser session, local Claude records | five-hour, weekly, arbitrary model- or feature-scoped limits such as Fable, credits, extra usage, tokens, cache savings, and estimates |
| Cursor | Cursor.app read-only SQLite auth, consented browser session | included plan, Auto/Composer, API/model usage, extra usage, resets, account identity |
| Devin | encrypted JR-Bar manual bearer or consented Chromium localStorage | daily and weekly quota, reset times, organization identity |
| Grok | `~/.grok/auth.json`, Grok billing API, local signals | subscription credit usage, cycle reset, account/plan, local token activity |
| Antigravity | running Antigravity or `agy` loopback quota server | Gemini session/weekly and Claude+GPT session/weekly pools, dynamic detail lanes |
| OpenAI API | encrypted JR-Bar Admin API key | organization/project spend, tokens, requests, models, daily history |
| Pi | lifecycle hooks only (`~/.pi/agent/extensions/jrbar.ts`, `jrbar agent-monitor install pi`); session logs under `~/.pi/agent/sessions` as transcript fallback | sessions, prompts, tool runs, turn ends; no asks (see below) and no quota source (pi bills through whichever model provider it is pointed at) |
| Gemini CLI | lifecycle hooks only (`hooks` in `~/.gemini/settings.json`, `jrbar agent-monitor install gemini`); chat logs under `~/.gemini/tmp/*/chats` as transcript fallback | sessions, prompts, tool runs, ToolPermission asks, turn ends; the Code Assist quota endpoint (`retrieveUserQuota`) is documented in `docs/research/gemini-cli-and-pi-hooks.md` and not read yet |

Unknown provider-owned quota lanes remain visible in detail views but cannot trigger hardware or interruption alerts until their effect is declared. Missing data, measured zero, stale data, last-known-good data, permission failures, and unsupported sources are separate states.

## What the CLIs actually emit

`scripts/verify_providers_live.py` runs each installed CLI through one real turn against `scripts/mock_llm_server.py` -- a scripted local endpoint, no quota, no network -- in a scratch home, and checks what the daemon recorded. Last run on the owner's Mac, 2026-09-10, against Codex 0.153.4, pi 0.73.1, Claude Code 2.1.263 and Gemini CLI 0.46.0.

| Provider | One turn | Interrupted mid-tool | Tool permission |
| --- | --- | --- | --- |
| Codex | `SessionStart > UserPromptSubmit > PreToolUse > PostToolUse > Stop > SessionEnd` | `… > PreToolUse > Interrupt > SessionEnd` | `PermissionRequest` under `-a on-request`, listed in `state.asks` |
| Claude Code | the same six | not drilled | `PermissionRequest`, listed in `state.asks` |
| Pi | the same six | not drilled | none: pi has no human permission event at all |
| Gemini CLI | not exercised | not drilled | `Notification` with `notification_type: "ToolPermission"` |

Two things worth knowing before reading a quiet menu bar as a bug.

**Codex hook trust is keyed by the resolved config path.** Codex looks up `hooks.state."<config>:<event>:<group>:<handler>"` after canonicalizing the config path, so a `CODEX_HOME` reached through a symlink needs the resolved spelling. Written any other way, Codex finds no trusted hash and runs no hook: no error, no record, nothing at all to see. `jrbar agent-monitor install codex` resolves it.

**Pi cannot ask.** The `ui_prompt_start`/`ui_prompt_end` events an earlier note attributed to pi do not exist in 0.73.1's `ExtensionEvent` union. Pi's tool gate is `tool_call`, and it asks an *extension* -- a handler returns `{block, reason}` and pi obeys -- never a person. So pi sessions show working and done, and never needs-you.

**Answering an ask works for Claude Code and Codex, and only for them.** Approve and Deny -- from the panel, a notification action, the Screen Bar or a Creator Micro session key -- post the key that provider's own permission prompt takes into the session's terminal (`src/jrbar/answer_local.py`; the refusal vocabulary is in docs/CORE-PROTOCOL.md).

| provider | approve | deny | what the prompt shows |
| --- | --- | --- | --- |
| Claude Code 2.1.263 | `1` | `esc` | `Do you want to proceed?` with `1. Yes` first; the `No` row's number moves with how many always-allow rows the tool earns, and the footer offers `Esc to cancel`. So approve is the stable `1` and deny is Esc. |
| codex-cli 0.153.4 | `y` | `3` | `1. Yes, proceed (y)` / `2. …(p)` / `3. No, and tell Codex what to do differently (esc)`. Fixed numbering, so deny is the explicit `3` rather than Esc, which is also Codex's global interrupt. |

Both were measured, not guessed: `scripts/verify_providers_live.py --asks` raises the real prompt against the scripted endpoint, and the keys above are the ones that made the tool run (approve) or the request abort (deny).

The mechanism is a synthetic keystroke (`CGEventPostToPid`) to the process hosting the terminal, because macOS offers nothing better -- `TIOCSTI` refuses a tty that is not the caller's own controlling terminal, and Ghostty has no scripting interface. Because the key lands wherever focus is, JR-Bar refuses rather than risks it: the ask must still be live in canonical state, the session's process alive, the hosting application frontmost, the frontmost application's process an *ancestor* of the session's process, and (on Terminal.app and iTerm2, which will say) the focused tab's tty the session's tty. Any failure answers `not_frontmost` with the reason. There is no "type it anyway".

**This needs Accessibility, and the row to turn on is `jrbar-core`, not JR-Bar.** The keystroke is posted by the daemon, which on an installed deployment is the `jrbar-core` helper app inside JR-Bar.app (`com.jonathanreed.jrbar.core`) -- a separate TCC client from JR-Bar itself. Without **System Settings > Privacy & Security > Accessibility > jrbar-core** turned on, the posted key silently goes nowhere, so JR-Bar checks `AXIsProcessTrusted()` first and refuses with `accessibility_required`, naming whichever row its own process needs, instead of pretending it answered. Measured 2026-09-10 on this Mac: not granted, and the refusal reads *"JR-Bar cannot answer this ask until macOS lets it send the keystroke. Turn on System Settings > Privacy & Security > Accessibility > jrbar-core."*

**What the checks still cannot see: which window of one terminal has focus.** The ancestry check proves the frontmost *application process* is the one the session descends from. Inside a single Ghostty instance, several windows and tabs share that process, and Ghostty exposes neither a scripting interface nor a usable window title (its `AXTitle` is empty unless the running program sets one -- Codex does, Claude Code does not), so a second Ghostty window in front of the session's own would still pass. Terminal.app and iTerm2 close that gap by naming their focused tab's tty. macOS window restoration makes this concrete: a restored Ghostty window can hold focus while the session's window is merely visible.

**Every other provider still means switching to the terminal.** `answer_ask` replies `unsupported` for them, and the contract says so: only `codex/hooks` and `claude/hooks` declare `ProductCapability.ANSWERING`, so the Approve button is never offered where it would do nothing.

**Gemini CLI could not be driven locally.** It refuses a base-URL override with "Invalid auth method selected" (exit 41), so its hook path is unverified against a scripted endpoint; it is exercised only by real use.

## Basic setup

```bash
jrbar providers status
jrbar providers enable codex
jrbar providers enable claude
jrbar providers enable cursor
jrbar providers enable devin
jrbar providers enable grok
jrbar providers enable antigravity
jrbar providers enable openai-api
```

Configure source and display policy:

```bash
jrbar providers configure claude --source-mode auto
jrbar providers configure claude --dynamic-lanes on
jrbar providers configure claude --reset-celebrations on
jrbar providers configure claude --threshold-remaining 20
jrbar providers configure devin --option organization=org_example
jrbar providers configure openai-api --option project_id=proj_example
```

Collect one bounded user-initiated snapshot:

```bash
jrbar providers refresh
jrbar providers refresh --json
```

## Manual credentials

Secrets are read from standard input and stored in JR-Bar's encrypted owner-private credential store. They never appear in configuration files, process arguments, diagnostics, exports, or command output.

```bash
printf '%s' "$DEVIN_BEARER_TOKEN" | \
  jrbar providers credential set devin --stdin \
  --option organization=org_example

printf '%s' "$OPENAI_ADMIN_KEY" | \
  jrbar providers credential set openai-api --stdin \
  --option project_id=proj_example

jrbar providers credential list
jrbar providers credential remove devin
```

## Browser-backed sources

Browser sources are disabled by default. Consent binds one provider, browser, profile, approved domains, approved field names, and optional background repair policy. Granting consent does not import anything. Import is a separate explicit action.

```bash
jrbar providers configure cursor --browser-sources on
jrbar providers browser-consent grant cursor \
  --browser chrome --profile Default --background-repair
jrbar providers browser-consent import cursor \
  --browser chrome --profile Default \
  --profile-root "$HOME/Library/Application Support/Google/Chrome/Default"

jrbar providers browser-consent list
jrbar providers browser-consent revoke cursor \
  --browser chrome --profile Default
```

The packaged reader supports Chromium-family cookie/localStorage databases and Firefox cookies. It copies stores to an isolated temporary directory before reading, never mutates browser data, restricts reads to the provider's allowlist, and stores validated imported values encrypted. Safari remains unavailable until a signed-bundle WebKit import path passes the same consent and account-isolation tests.

## Which windows an account actually has

Verified live 2026-09-10 against Codex 0.153.4 and Claude's OAuth usage endpoint on the owner's Mac. Full wire vocabulary in `docs/CORE-PROTOCOL.md`; the captured payloads are in `tests/fixtures/provider_usage/`.

**Window applicability is a property of the plan, not of what happened to arrive.** Each provider's `account.plan` is recorded from what that provider states — Codex's `rateLimits.planType` (or the `chatgpt_plan_type` claim in `~/.codex/auth.json`), Claude's `oauthAccount` tier words in `~/.claude.json`, Cursor's `membershipType` — so which windows an account has is derived rather than guessed, and the card can label the account.

**A window can be absent, unknown, or exhausted, and these are three different things.** Absent means the plan has no such window and nothing is drawn for it; providers say this explicitly (`"secondary": null` from Codex, `"seven_day_opus": null` from Claude) and it is never a zero. Unknown means the window exists and the provider stated no number: the row shows the window and its reset and withholds the balance. Exhausted means a stated 100 % used. Collapsing the first two into the third is what put a red "5-hour · 100%" on an account that has no 5-hour window.

**Codex reports several limit families side by side, and only one of them is the account's.** `account/rateLimits/read` answers with a default family under `rateLimits` and the whole set under `rateLimitsByLimitId`. `limitId: "codex"` is the account's own ceilings; `codex_bengalfox` (`limitName` "GPT-5.3-Codex-Spark") and anything under `additional_rate_limits[]` are model- or product-scoped sub-caps that reuse the same `primary`/`secondary` key names. A sub-cap gets its own dynamic lane named after the product — "Spark 5-hour", "Spark Weekly", not bindable — and can never occupy an account lane. A window's horizon comes from its stated `windowDurationMins` (300 = five-hour, 10080 = weekly), never from its position.

On this ChatGPT Pro account the `codex` family reports a weekly `primary` and `secondary: null` — a weekly ceiling and no 5-hour window at all — while the Spark family reports a 300-minute `primary`. A plan that does have a 5-hour window reports it as a 300-minute `primary` under the `codex` family, and still gets the `five-hour` lane it always did.

A rollout file carries exactly one family per record. When a live `codex app-server` read is available it enumerates every family, so for the families it covered it is the whole truth — including which windows a family does not have — and rollout evidence for those families is discarded rather than merged.

## Usage Center and quality-of-life behavior

The native Usage Center shows every account and quota lane, reset countdowns, model count, tokens, credits, incidents, source freshness, partial pricing coverage, local estimates, and cross-Mac totals. The menu shows the most constrained trustworthy lane without changing status-item width.

A reset celebration occurs only after a real lane transitions across its recorded reset boundary and a fresh observation confirms replenishment. It is a finite, accessibility-safe cue and is deduplicated across restarts. Threshold and incident notifications are upward-only and use the same authoritative facts shown in the Usage Center.

Pricing is an explicitly versioned local estimate. Unknown models remain visible as unpriced usage and reduce pricing coverage rather than inheriting another model's price.

## Cross-Mac sync

JR-Bar sync is local-first and peer-to-peer over SSH/SFTP, normally addressed through Tailscale. Envelopes are JSON signed with HMAC-SHA256 using the per-peer pairing secret — they are authenticated, not encrypted; confidentiality in transit comes from the SSH/SFTP channel. Packets stamped older than a bounded freshness window (7 days) are rejected on decode to blunt replays. Account-wide quota snapshots use the freshest valid observation and are never summed. Machine-local token events are deduplicated by device and provider, latest observation wins.

On the first Mac:

```bash
jrbar providers sync set-device mac-mini
jrbar providers sync set-categories quota,token_usage,agent_activity
jrbar providers sync export-pairing --output ~/Desktop/jrbar-pairing.json
```

Transfer that owner-private file directly to the second Mac. On the second Mac:

```bash
jrbar providers sync set-device macbook
jrbar providers sync import-pairing \
  --input ~/Desktop/jrbar-pairing.json \
  --host mac-mini.tailnet-name.ts.net \
  --remote-path ~/.local/state/jrbar/provider-sync/local.json \
  --known-hosts ~/.ssh/known_hosts \
  --identity-file ~/.ssh/id_ed25519
jrbar providers sync enable
```

Repeat the pairing import in the opposite direction so both Macs can fetch each other's signed packet. Delete pairing files after import. Agent activity sync is a separate metadata-only category and remains off by default.
