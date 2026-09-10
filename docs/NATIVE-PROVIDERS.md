# Native provider usage

JR-Bar owns provider accounting directly. CodexBar is an engineering reference only; it is never launched, queried, imported, or required at runtime. The only external application integrations are T3 Code and Alcove.

## Supported providers

| Provider | Native sources | Main facts |
| --- | --- | --- |
| ChatGPT / Codex | Codex OAuth usage API, `codex app-server`, local Codex records | five-hour and weekly limits, dynamic additional lanes such as Spark, credits, resets, tokens, models, and estimates |
| Claude | Claude OAuth usage API, consented Claude browser session, local Claude records | five-hour, weekly, arbitrary model- or feature-scoped limits such as Fable, credits, extra usage, tokens, cache savings, and estimates |
| Cursor | Cursor.app read-only SQLite auth, consented browser session | included plan, Auto/Composer, API/model usage, extra usage, resets, account identity |
| Devin | encrypted JR-Bar manual bearer or consented Chromium localStorage | daily and weekly quota, reset times, organization identity |
| Grok | `~/.grok/auth.json`, Grok billing API, local signals | subscription credit usage, cycle reset, account/plan, local token activity |
| Antigravity | running Antigravity or `agy` loopback quota server | Gemini session/weekly and Claude+GPT session/weekly pools, dynamic detail lanes |
| OpenAI API | encrypted JR-Bar Admin API key | organization/project spend, tokens, requests, models, daily history |
| Pi | lifecycle hooks only (`~/.pi/agent/extensions/jrbar.ts`, `jrbar agent-monitor install pi`); session logs under `~/.pi/agent/sessions` as transcript fallback | sessions, prompts, tool runs, turn ends; no quota source (pi bills through whichever model provider it is pointed at) |
| Gemini CLI | lifecycle hooks only (`hooks` in `~/.gemini/settings.json`, `jrbar agent-monitor install gemini`); chat logs under `~/.gemini/tmp/*/chats` as transcript fallback | sessions, prompts, tool runs, ToolPermission asks, turn ends; the Code Assist quota endpoint (`retrieveUserQuota`) is documented in `docs/research/gemini-cli-and-pi-hooks.md` and not read yet |

Unknown provider-owned quota lanes remain visible in detail views but cannot trigger hardware or interruption alerts until their effect is declared. Missing data, measured zero, stale data, last-known-good data, permission failures, and unsupported sources are separate states.

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
