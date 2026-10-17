# JR-Bar upstream refresh, 2026-10-07 (CodexBar, T3 Code and similar tools)

Status: **current**. Supersedes [UPSTREAM-REFRESH-2026-08-30.md](UPSTREAM-REFRESH-2026-08-30.md)
for CodexBar and T3 Code. The SidePulse sources of the cadence are not covered
here; they stay with the 2026-08-30 ledger until their own review lands.

- review_date: 2026-10-07
- timezone: America/Chicago
- reviewer: Claude Sonnet 5.5 (Claude Code), for Jonathan
- source_availability: every source below was checked live; none was
  unavailable.

The per-item dispositions, with the JR-Bar commit that ports each one, are in
[the dated note](archive/2026-10-07-codexbar-t3-similar-tools-review.md). This
file keeps the cadence's source identity and ledger fields.

## Source identity

| Source | Live identity checked | Direct source |
| --- | --- | --- |
| CodexBar | `steipete/CodexBar` at `03a51bdcfc6f6804e005d7e5007de67bac82b494` (`main`, 2026-10-07), latest release `v0.73.0` (2026-10-07), 458 non-merge commits since `e34fe618` | [release](https://github.com/steipete/CodexBar/releases/tag/v0.73.0), [CHANGELOG](https://github.com/steipete/CodexBar/blob/main/CHANGELOG.md) |
| T3 Code | `pingdotgg/t3code` at `611132c171f3a821bd2e32f22261135cef6330ac` (`main`, 2026-10-07, tag `v0.0.46-nightly.20261007.2774`), 569 commits since `cb1a3f34`; stable is `v0.0.45` | [repository](https://github.com/pingdotgg/t3code), [`de343914`](https://github.com/pingdotgg/t3code/commit/de343914273eceb852a1d1d739cd1d38df7796ee) |
| ccusage | `ryoppippi/ccusage` at `f3b78d10938456b8a51d85034b2a1c3008e29f50` (v20.0.26) | [repository](https://github.com/ryoppippi/ccusage) |
| OpenUsage | `robinebers/openusage`, commit `00189454816cc3d815a166fa1369d6fe67dd2405` (MIT) | [commit](https://github.com/robinebers/openusage/commit/00189454816cc3d815a166fa1369d6fe67dd2405) |
| Claude Code | 2.1.292 installed; changelog read from 2.1.170 | [changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md) |
| Codex CLI | codex-cli 0.159.2 installed; releases and source read from 0.136.0 to 0.160.1 | [releases](https://github.com/openai/codex/releases) |
| JR-Bar | worktree branch `lane/upstream-codexbar-t3`, from `main` at `3864d179` | local only |

## Ledger

| source | finding | reachability | disposition | local_touchpoints | evidence_kind | next_action |
| --- | --- | --- | --- | --- | --- | --- |
| T3 Code `de343914` | 0.0.46 nightlies write live threads to `statev2.sqlite`; the legacy file is a frozen copy | confirmed on this Mac: the legacy file last changed Oct 2 | adopt | `t3_compat.py`, `usage_graph_worker.py`, `integration_compatibility.json` | read-only run of the reader against the owner's data; `tests/test_t3_v2_compat.py` | Re-run the probe on the next T3 release. |
| T3 Code orchestrator, MCP, auth, queues, scheduled tasks | Large new write-capable surface | none: JR-Bar reads SQLite only | reject | none | source review | None. |
| CodexBar one-hour cache writes, 272K long context, Pi cttl | Cost estimate rules | confirmed in transcripts | adapt | `usage_stats.py`, `session_usage.py`, `core_usage_history.py`, `local_token_history.py` | unit tests; Anthropic and OpenAI price pages | Priority / Fast tier needs a real sample. |
| CodexBar Antigravity bucket cadence, status ordering, relative PATH | Parser and ordering fixes | confirmed in code | adapt | `provider_usage_parsers.py`, `status_feeds.py`, `provider_reconnect.py`, `hook_compatibility.py` | unit tests | None. |
| CodexBar `cedar_ember` resets, Cursor Grok Bot | Undocumented request parameters / endpoints | needs the owner's consent and a payload | waiting on evidence | `claude_quota.py`, `provider_usage_collectors.py` | source review | Owner decision. |
| CodexBar Claude / Codex credential recovery, PTY probes | Paths JR-Bar does not have | none | reject | none | source review | None. |
| CodexBar #4283 idle Codex quota use | Unproven report | JR-Bar's probe sends two read RPCs and no turn | waiting on evidence | `provider_reconnect.codex_app_server_probe` | issue text | Owner can compare the Codex usage page over an idle day. |
| ccusage 20.0.26 compaction usage | Remote compaction requests missing from the counter | confirmed from two projects | adopt | `usage_stats._scan_codex_lines` | unit tests | None. |
| Claude Code sessions file `status` | Esc interrupt fires no hook | confirmed on this Mac | adopt | `process_registry.py`, `liveness_sweep.py`, `provider_adapters.py` | unit tests; key and status names read from two live files | Live drill with a real Esc. |
| Codex `turn_aborted`, typed turn failures | Rollout fallback | confirmed in source | adopt | `collector.py` | unit tests | None. |
| Hook shapes of Claude Code 2.1.292 and codex-cli 0.159.2 | Unchanged for what JR-Bar reads; Codex trust hashes match | source review | adopted/surpassed | `provider_hook_compatibility.json` | trust-hash comparison against this Mac's config | Live drill, then bump the manifest. |

## Action queue

1. Run `scripts/verify_providers_live.py` for Claude Code 2.1.292 and codex-cli
   0.159.2 and bump the hook compatibility manifest (owner's Mac, real
   sessions).
2. Decide about the heavy-history scan cap, Codex Priority pricing and the two
   undocumented requests listed above.
3. Next off-cycle trigger: a T3 Code stable release past 0.0.45, or a CodexBar
   release after 0.73.0.

This refresh does not authorize a merge, push, release, deployment, credential
change, telemetry, or hardware mutation.
