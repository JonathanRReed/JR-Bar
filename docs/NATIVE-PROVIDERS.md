# Native provider usage

JR-Bar owns provider accounting directly. CodexBar is an engineering reference only; it is never launched, queried, imported, or required at runtime. The only external application integrations are T3 Code and Alcove.

## Supported providers

| Provider | Native sources | Main facts |
| --- | --- | --- |
| ChatGPT / Codex | Codex OAuth usage API, `codex app-server`, local Codex records | whichever of the five-hour and weekly account limits the plan actually has, plan name, dynamic sub-cap lanes such as Spark, credits, resets, tokens, models, and estimates |
| Claude | Claude OAuth usage API, [Claude Code status line](user/claude-statusline.md) (opt-in, stands in when the API is refused), consented Claude browser session, local Claude records | five-hour, weekly, arbitrary model- or feature-scoped limits such as Fable, credits, extra usage, tokens, cache savings, and estimates |
| Cursor | Cursor.app read-only SQLite auth, consented browser session | included plan, Auto/Composer, API/model usage, extra usage, resets, account identity |
| Devin | JR-Bar Keychain token or consented Firefox-family or Chromium browser session | daily and weekly quota, reset times, organization identity |
| Grok | `~/.grok/auth.json`, Grok billing API, local signals | subscription credit usage, cycle reset, account/plan, local token activity |
| Antigravity | running Antigravity or `agy` loopback quota server | Gemini session/weekly and Claude+GPT session/weekly pools, dynamic detail lanes |
| Factory | Validated API key in JR-Bar Keychain or a previously imported browser access token, Factory dashboard billing API | independent Standard windows, separate Core details, source-stated plan, account scope and reset times; browser access and usage require separate consent |
| OpenAI API | Admin API key in the Keychain | organization spend, tokens, requests, models, daily history for the last 30 days |
| OpenCode | OpenCode Go usage API (needs a Go key; on unless turned off), local OpenCode database | rolling 5-hour, weekly and monthly Go windows; token totals; no quota without a Go subscription (see [usage sources](user/usage-sources.md#opencode-and-opencode-go)) |
| Pi | lifecycle hooks only (`~/.pi/agent/extensions/jrbar.ts`, `jrbar agent-monitor install pi`); session logs under `~/.pi/agent/sessions` as transcript fallback | sessions, prompts, tool runs, turn ends; no asks (see below) and no quota source (pi bills through whichever model provider it is pointed at) |
| Gemini CLI | lifecycle hooks only (`hooks` in `~/.gemini/settings.json`, `jrbar agent-monitor install gemini`); chat logs under `~/.gemini/tmp/*/chats` as transcript fallback | sessions, prompts, tool runs, ToolPermission asks, turn ends |
| Gemini (quota) | `~/.gemini/oauth_creds.json` (in-memory token refresh, file never rewritten), Code Assist `retrieveUserQuota` | per-model quota buckets (model, remaining, reset) as detail lanes; needs a provisioned Code Assist project — see below |

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

**Answering an ask works for Claude Code and Codex, and only for them.** Approve and Deny -- from the panel, a notification action, the Screen Bar, a Creator Micro session key or a Stream Deck key -- take one of two routes.

*The decide lane.* Claude Code and Codex run a `PermissionRequest` hook before they ask. While the hook runs as `jrbar-hook --decide`, JR-Bar holds it for up to 45 seconds, and an Approve or Deny is the hook's own reply: nothing is typed, no Accessibility grant is needed, and it works in Ghostty, an IDE panel or a headless run. Claude's Always allow and its multiple-choice questions use the same lane. When the hold lapses nothing is printed and the agent's own prompt carries on. A sub-agent's request is not held while Sub-agent asks is off, and a Codex request is not held while its terminal is frontmost, since Codex shows its prompt only after its hooks return.

*The keystroke.* When no hold is open, Approve and Deny post the key that provider's own permission prompt takes into the session's terminal (`src/jrbar/answer_local.py`; the refusal vocabulary is in docs/CORE-PROTOCOL.md). The keys:

| provider | approve | deny | what the prompt shows |
| --- | --- | --- | --- |
| Claude Code 2.1.263 | `1` | `esc` | `Do you want to proceed?` with `1. Yes` first; the `No` row's number moves with how many always-allow rows the tool earns, and the footer offers `Esc to cancel`. So approve is the stable `1` and deny is Esc. |
| codex-cli 0.153.4 | `y` | `3` | `1. Yes, proceed (y)` / `2. …(p)` / `3. No, and tell Codex what to do differently (esc)`. Fixed numbering, so deny is the explicit `3` rather than Esc, which is also Codex's global interrupt. |

Both were measured, not guessed: `scripts/verify_providers_live.py --asks` raises the real prompt against the scripted endpoint, and the keys above are the ones that made the tool run (approve) or the request abort (deny).

The mechanism is a synthetic keystroke (`CGEventPostToPid`) to the process hosting the terminal, because macOS offers nothing better -- `TIOCSTI` refuses a tty that is not the caller's own controlling terminal, and Ghostty has no scripting interface. Because the key lands wherever focus is, JR-Bar refuses rather than risks it: the ask must still be live in canonical state, the session's process alive, the hosting application frontmost, the frontmost application's process an *ancestor* of the session's process, and (on Terminal.app and iTerm2, which will say) the focused tab's tty the session's tty. Any failure answers `not_frontmost` with the reason. There is no "type it anyway".

**The keystroke route needs Accessibility, and the row to turn on is `jrbar-core`, not JR-Bar.** The keystroke is posted by the daemon, which on an installed deployment is the `jrbar-core` helper app inside JR-Bar.app (`com.jonathanreed.jrbar.core`) -- a separate TCC client from JR-Bar itself. Without **System Settings > Privacy & Security > Accessibility > jrbar-core** turned on, the posted key silently goes nowhere, so JR-Bar checks `AXIsProcessTrusted()` first and refuses with `accessibility_required`, naming whichever row its own process needs, instead of pretending it answered. Measured 2026-09-10 on this Mac: not granted, and the refusal reads *"JR-Bar cannot answer this ask until macOS lets it send the keystroke. Turn on System Settings > Privacy & Security > Accessibility > jrbar-core."*

**Which window of one terminal has focus.** The ancestry check proves only that the frontmost *application process* is the one the session descends from. Terminal.app and iTerm2 close the rest by naming their focused tab's tty. Ghostty names no tty and shares one process across its windows, so its proof is that the focused terminal of its front window is the very surface JR-Bar recorded when the session started, still in the session's directory. A directory alone is never the proof, because a plain shell opened where the agent works reports the same directory. No record, another surface, or two terminals that cannot be told apart refuse. The window checks run twice, the second time immediately before the key is posted, so a tab switched mid-answer refuses instead of receiving the key.

**Opening a session finds the app that hosts it.** A click on a running session walks up the agent's parent processes until it meets an app it knows (`terminal_from_command` in `src/jrbar/core_projection.py`), by the executable's name or by the `.app` it lives in. Then it does the most exact thing that app allows:

| host | what comes forward |
| --- | --- |
| Codex desktop app (ships inside `ChatGPT.app`, bundle id `com.openai.codex`; its threads run under `codex app-server`) | the controller's own link, `codex://threads/<id>`, which lands on that thread |
| Claude desktop app (`com.anthropic.claudefordesktop`) | `claude://code/continue?session=…`, else the app |
| Terminal.app, iTerm2 | the tab, found by tty |
| Ghostty | the terminal surface recorded at SessionStart, else the only one in the directory |
| tmux | the pane, found by tty |
| T3 Code (`com.t3tools.t3code`), Devin (`com.exafunction.windsurf`), VS Code, Cursor, Windsurf, Antigravity, cmux, Warp, kitty, WezTerm | the app, brought forward; none of them offers a way to pick a session from outside |

The ancestry starts at the agent's parent, because the agent's own executable is named after its provider (`codex`) and would read as the desktop app. When the walk meets no known app, the hook's origin annotation (`Codex UI`, `Claude in VS Code`) names one. The Codex desktop app was once missed: its main process is `ChatGPT`, a name nothing mapped, so a thread it ran was treated as a terminal session with no terminal and refused.

When nothing comes forward the refusal says why instead of a generic line: the app it looked for and its bundle id, or the executables it looked through (names only, no paths), or the tmux pane it could not find, and always that nothing new was started. `SessionOpener.swift` shows the daemon's sentence as it is.

**Every other provider still means switching to the terminal.** `answer_ask` replies `unsupported` for them, and the contract says so: only `codex/hooks` and `claude/hooks` declare `ProductCapability.ANSWERING`, so the Approve button is never offered where it would do nothing.

**Gemini CLI could not be driven locally.** It refuses a base-URL override with "Invalid auth method selected" (exit 41), so its hook path is unverified against a scripted endpoint; it is exercised only by real use.

**Gemini quota was certified live 2026-09-13** against `cloudcode-pa.googleapis.com` on the owner's account. The collector reads `~/.gemini/oauth_creds.json`, refreshes the access token in memory with the Gemini CLI's own public OAuth client (the file is never rewritten), discovers the Code Assist project through `loadCodeAssist` (or `--option project_id=...` / `GOOGLE_CLOUD_PROJECT`), then reads `retrieveUserQuota`. Verified failure shapes: an account that never onboarded gets `allowedTiers`/`ineligibleTiers` and no project — the free tier answers `UNSUPPORTED_CLIENT` ("migrate to the Antigravity suite"), and Google retired it for this client; `retrieveUserQuota` on an unprovisioned account answers `403 PERMISSION_DENIED` "no valid license", which is classified as a license state (`quota_license_required`), never as a sign-in failure. Buckets are per-model pools, so every Gemini lane is a non-bindable detail lane — none can pose as an account ceiling.

## Consent

No provider's usage read runs until the person turns that provider on. The
settings document keeps one record per provider instance (`usage_consent_version`,
`usage_consent_source`, `usage_consented_at`); the build's version is
`USAGE_CONSENT_VERSION` in `provider_usage_settings.py`, and a later build that
changes what a read sends or reads raises it so every provider asks again. The
gate is `provider_usage_consent.ConsentGatedCollector`: every shipped collector
sits behind it, and without consent only a local-only path runs. That path is
handed no credential store and no transport.

Without consent a provider keeps what is read from files on this Mac and
nothing else: token totals (Codex, Claude, OpenCode), Codex's rollout windows
(source `codex-rollouts`), and Claude Code's status line (source
`claude-statusline`). It reads no Keychain item, no `auth.json`, no browser
store, no `~/.claude.json`, runs no `codex app-server`, and its credential
sources are not even stat-ed. Its snapshot is `needs_consent` with reason
`usage_not_turned_on`, no lane and the action "Turn on <Provider> usage", and
it is not counted as degraded. A saved reading from a gated source does not
outlive the consent that allowed it.

Upgrade migration (`migrate_usage_consent`): once per settings document, a
provider instance that is enabled and whose last saved reading came from a
gated source (READY or STALE, a lane not in `codex-rollouts`, `claude-statusline`
or `opencode-db`) gets a consent marked `migration`, with one log line each.
A fresh Mac writes nothing, and changing any consent seals the migration so an
old reading can never turn a provider back on.

## Basic setup

```bash
jrbar providers status
jrbar providers usage codex on        # one provider's usage; `off` withdraws it
jrbar providers enable codex
jrbar providers enable claude
jrbar providers enable cursor
jrbar providers enable devin
jrbar providers enable grok
jrbar providers enable gemini
jrbar providers enable antigravity
jrbar providers enable opencode
jrbar providers enable openai-api
```

Configure source and display policy:

```bash
jrbar providers configure claude --reset-celebrations on
jrbar providers configure claude --threshold-remaining 20
jrbar providers configure devin --option organization=org_example
jrbar providers configure gemini --option project_id=proj_example
jrbar providers configure opencode --option go_usage=off
```

Collect one bounded user-initiated snapshot:

```bash
jrbar providers refresh
jrbar providers refresh --json
```

## Manual credentials

Secrets are read from standard input and stored in the macOS Keychain, under a service JR-Bar owns. They never appear in configuration files, process arguments, diagnostics, exports, or command output.

```bash
printf '%s' "$DEVIN_BEARER_TOKEN" | \
  jrbar providers credential set devin token --stdin

printf '%s' "$OPENAI_ADMIN_KEY" | \
  jrbar providers credential set openai-api admin-key --stdin

jrbar providers credential list
jrbar providers credential remove devin token
```

## Browser-backed sources

Browser sources are disabled by default. Consent binds one provider, browser, profile, approved domains, approved field names, and optional background repair policy. Granting consent does not import anything. Import is a separate explicit action.

```bash
jrbar providers configure devin --browser-sources on
jrbar providers browser-consent grant devin \
  --browser chrome --profile Default --background-repair
jrbar providers browser-consent import devin \
  --browser chrome --profile Default \
  --profile-root "$HOME/Library/Application Support/Google/Chrome/Default"

jrbar providers browser-consent list
jrbar providers browser-consent revoke devin \
  --browser chrome --profile Default
```

`grant` and `revoke` take `devin` or `cursor`. The `import` subcommand is Devin's, and Chromium-only; the Import button on the Usage Center card also reads a Firefox-family profile you granted.

The packaged reader supports Chromium-family cookie/localStorage databases and Firefox-family cookies and localStorage. It copies stores to an isolated temporary directory before reading, never mutates browser data, restricts reads to the provider's allowlist, and stores validated imported values in the Keychain. Safari remains unavailable until a signed-bundle WebKit import path passes the same consent and account-isolation tests.

## Which windows an account actually has

Verified live 2026-09-10 against Codex 0.153.4 and Claude's OAuth usage endpoint on the owner's Mac. Full wire vocabulary in `docs/CORE-PROTOCOL.md`; the captured payloads are in `tests/fixtures/provider_usage/`.

**Window applicability is a property of the plan, not of what happened to arrive.** Each provider's `account.plan` is recorded from what that provider states — Codex's `rateLimits.planType` (or the `chatgpt_plan_type` claim in `~/.codex/auth.json`), Claude's `oauthAccount` tier words in `~/.claude.json`, Cursor's `membershipType` — so which windows an account has is derived rather than guessed, and the card can label the account.

**A window can be absent, unknown, or exhausted, and these are three different things.** Absent means the plan has no such window and nothing is drawn for it; providers say this explicitly (`"secondary": null` from Codex, `"seven_day_opus": null` from Claude) and it is never a zero. Unknown means the window exists and the provider stated no number: the row shows the window and its reset and withholds the balance. Exhausted means a stated 100 % used. Collapsing the first two into the third is what put a red "5-hour · 100%" on an account that has no 5-hour window.

**Codex reports several limit families side by side, and only one of them is the account's.** `account/rateLimits/read` answers with a default family under `rateLimits` and the whole set under `rateLimitsByLimitId`. `limitId: "codex"` is the account's own ceilings; `codex_bengalfox` (`limitName` "GPT-5.3-Codex-Spark") and anything under `additional_rate_limits[]` are model- or product-scoped sub-caps that reuse the same `primary`/`secondary` key names. A sub-cap gets its own dynamic lane named after the product — "Spark 5-hour", "Spark Weekly", not bindable — and can never occupy an account lane. A window's horizon comes from its stated `windowDurationMins` (300 = five-hour, 10080 = weekly), never from its position.

On this ChatGPT Pro account the `codex` family reports a weekly `primary` and `secondary: null` — a weekly ceiling and no 5-hour window at all — while the Spark family reports a 300-minute `primary`. A plan that does have a 5-hour window reports it as a 300-minute `primary` under the `codex` family, and still gets the `five-hour` lane it always did.

A rollout file carries exactly one family per record. When a live `codex app-server` read is available it enumerates every family, so for the families it covered it is the whole truth — including which windows a family does not have — and rollout evidence for those families is discarded rather than merged.

## Usage Center and quality-of-life behavior

The native Usage Center shows every account and quota lane, reset countdowns, model count, tokens, credits, incidents, source freshness, partial pricing coverage, local estimates, and cross-Mac totals. The menu shows the most constrained trustworthy lane without changing status-item width.

A reset celebration occurs only after a real lane is seen to refill and, unless the clock itself proves it, a second observation confirms the replenishment ([reset confirmation](user/usage-sources.md#reset-confirmation) has the rules). It is a finite, accessibility-safe cue and is deduplicated across restarts. Threshold and incident notifications are upward-only and use the same authoritative facts shown in the Usage Center.

Pricing is an explicitly versioned local estimate. Unknown models remain visible as unpriced usage and reduce pricing coverage rather than inheriting another model's price. The estimate follows how each maker bills: a Claude cache write is split into its five-minute (1.25x input) and one-hour (2x input) parts from `usage.cache_creation`, an OpenAI request whose prompt is over 272K tokens is repriced as a whole at 2x input and 1.5x output, and a Codex compaction request that the thread's token counter never added (a `token_usage_record` named by a `compacted` item) is counted once. A person's own price for a model is used as they set it.

## Cross-Mac sync

JR-Bar sync is local-first and peer-to-peer over SSH/SFTP, normally addressed through Tailscale. Envelopes are JSON signed with HMAC-SHA256 using the per-peer pairing secret — they are authenticated, not encrypted; confidentiality in transit comes from the SSH/SFTP channel. Packets stamped older than a bounded freshness window (7 days) are rejected on decode to blunt replays. Account-wide quota snapshots use the freshest valid observation and are never summed. Machine-local token events are deduplicated by device and provider, latest observation wins.

On the first Mac:

```bash
jrbar providers sync set-device mac-mini
jrbar providers sync set-categories quota,token_usage,agent_activity
jrbar providers sync export-pairing macbook \
  --secret-account sync-macbook --output ~/Desktop/jrbar-pairing.json
```

`export-pairing` takes the second Mac's device id and a name for the shared secret, which it generates and keeps in the Keychain on this Mac. Transfer the owner-private file directly to the second Mac. On the second Mac:

```bash
jrbar providers sync set-device macbook
jrbar providers sync import-pairing \
  --input ~/Desktop/jrbar-pairing.json \
  --host mac-mini.tailnet-name.ts.net \
  --remote-path ~/.local/state/jrbar/provider-sync/macbook.packet \
  --known-hosts ~/.ssh/known_hosts \
  --identity-file ~/.ssh/id_ed25519
jrbar providers sync enable
```

`jrbar providers sync status` (`--json`) shows the device, categories and peers, and `jrbar providers sync refresh` fetches once. `add-peer` and `remove-peer` manage a peer by hand. Each Mac publishes one signed packet per peer, named for that peer's device id (`provider-sync/macbook.packet` on the Mac mini above), so the remote path ends in the fetching Mac's own id. Repeat the export and import in the opposite direction so both Macs can fetch each other's packet. Delete pairing files after import. Agent activity sync is a separate metadata-only category and remains off by default.
