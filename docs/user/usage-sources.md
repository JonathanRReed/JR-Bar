# Where the usage numbers come from

JR-Bar reads each provider's quota and token history on this Mac. How
each provider is read in detail is in
[NATIVE-PROVIDERS.md](../NATIVE-PROVIDERS.md). This page covers the
sources you can turn on or tune yourself, and the rules that keep the
numbers honest.

## OpenCode and OpenCode Go

OpenCode itself reports no quota. Its card shows token totals from
OpenCode's local database and says "no quota source".

The one real quota source is an **OpenCode Go** subscription. When the
OpenCode provider is enabled and a Go key exists, JR-Bar asks
`opencode.ai` for three windows:

- the rolling 5-hour window, which can drive the lights;
- the weekly window, which can drive the lights;
- the monthly window, shown as detail.

The key is read from `opencode-go` in OpenCode's `auth.json`, else from
`OPENCODE_API_KEY`. It never appears in a reading or a log.

This is a request that leaves your Mac, so it happens only while all
three are true:

- the provider is on (`jrbar providers enable opencode`);
- a key exists;
- you have not turned it off
  (`jrbar providers configure opencode --option go_usage=off`).

A Zen key with no Go subscription gets a 403, which the card shows as
"no quota source", not as an error.

OpenCode's data folder follows XDG: `$XDG_DATA_HOME/opencode`, else
`~/.local/share/opencode`.

## More than one account home

Claude Code and Codex both let you move their data: `CLAUDE_CONFIG_DIR`
and `CODEX_HOME`, and tools such as claude-swap keep one home per account.
JR-Bar reads, in order:

1. the home the environment names;
2. the default (`~/.claude`, `~/.codex`);
3. any folders you list.

```sh
jrbar set provider_extra_homes.claude '["/Users/me/.claude-work"]'
jrbar set provider_extra_homes.codex '["/Users/me/.codex-personal"]'
```

Two entries that are the same real folder (a symlink, a trailing slash)
count once, so a duplicate never doubles a total.

## How far back the token totals reach

The Claude and Codex cards show tokens and cost for the last 30 days. They
read the cache that JR-Bar's usage scans already keep and never scan the
transcripts themselves, so what a card can show depends on the last scan
that wrote the cache.

- **Claude shows a whole total or nothing.** The card appears once the
  cache reaches back a full 30 days across every home. JR-Bar's core scans
  30 days a few seconds after it starts, and that fills the card.
- **A shorter scan can blank it.** The usage graph keeps only the range it
  was asked for, plus three days. On the default 7-day graph that is about
  ten days, so after a graph scan the cache no longer reaches back 30 days
  and the Claude card goes empty instead of showing a total with days
  missing. It fills again after the next 30-day scan: a restart, the Usage
  window's 30-day range, or a graph set to 30 days or more. While you use
  the 7-day graph the card and the graph can take turns.
- **A very busy month can blank it too.** The cache is capped at 8 MiB.
  When 30 days of entries do not fit, a scan leaves out the oldest, largest
  ones and writes down how far back the cache is still whole. The Claude
  card then shows nothing, because a total with those days missing would
  read as complete. The usage graph is not affected: it reads the full scan,
  not this cache.
- **Codex counts the days the cache still holds.** After a shorter scan, or
  a busy month that did not fit, the Codex card adds up only the days that
  are whole (about ten after a 7-day graph scan) and the card does not say
  so. Its quota reading is kept either way, because that lives in the same
  cache.
- **Claude adds every home or none.** If a home you listed under
  `provider_extra_homes` has not been scanned yet, or JR-Bar cannot list
  your extra homes, the Claude card waits instead of showing one home's
  share. Codex keeps the primary home in that case.

The graph does not keep 30 days on every scan because the cache is capped
at 8 MiB, which keeps JR-Bar's own memory small. On a very busy machine 30
days of entries are already more than that cap holds, so a 7-day graph that
tried to keep them would write a much bigger file on every refresh for no
gain to the graph. The graph keeps its own range, and the cards say nothing
rather than guess.

## Token history for Pi, Grok, Gemini CLI and OpenClaw

The usage graph and the Usage Center read each agent's own session
files, read-only:

| agent | folder |
| --- | --- |
| Pi | `$PI_CODING_AGENT_DIR`, else `~/.pi/agent/sessions` |
| Grok | `$GROK_HOME/sessions`, else `~/.grok/sessions` |
| Gemini CLI | `~/.gemini/tmp` (`$GEMINI_DATA_DIR/tmp` when set) |
| OpenClaw | `$OPENCLAW_DIR`, else `~/.openclaw` (its session files and agent database) |

Each source counts once. Pi and OpenClaw can run on a Claude or Codex
subscription, but their tokens stay Pi's and OpenClaw's. They are never
added to the Claude or Codex totals, which come only from those CLIs' own
files.

## Prices

Cost estimates use a price snapshot that ships with the app
(`src/jrbar/resources/model_pricing.json`). JR-Bar never fetches a price
while it runs. `scripts/update_model_pricing.py` refreshes the snapshot
by hand, from the built-in table or a downloaded copy of LiteLLM's MIT
price list.

To price a model your own way, such as a negotiated rate or a model the
table does not know yet, add an override in USD per million tokens:

```sh
jrbar set pricing_overrides '{"my-model": {"input": 1.5, "output": 6, "cache_read": 0.15}}'
```

A key matches when it appears inside the model name, and the longest key
wins. An override always beats the snapshot. A model neither knows stays
unpriced, never $0.

## Reset credits

Some providers give an account a few credits that reset a limit early.
When a source reports a count, the Usage Center and `jrbar usage` show it
("2 reset credits"). The sources are:

- Codex's own rate-limit read;
- the CLIProxyAPI hub, for a hub account;
- a Grok billing answer that carries coupons.

It is a count only. Nothing in JR-Bar redeems a credit.

## Reset confirmation

A reset is celebrated, sent to the app, and passed to
[usage hooks](usage-hooks.md) only when JR-Bar is sure of it:

- **The reset time passed.** When a window's reset time passes between
  two reads and the remaining amount rises, the clock proves it, and the
  reset is announced at once.
- **The remaining amount jumped.** When remaining jumps by 50 points or
  more before the reset time, one odd read could explain it. JR-Bar waits
  for a second read 1 to 30 minutes later that still shows the jump and
  names the same reset time, within two minutes.
- **An unused window is not a reset.** A window nobody has started quotes
  "now plus one window" as its reset time on every read, so that time
  moves with the clock. JR-Bar never counts that as a reset.

A reset waiting for its second read survives a restart. The celebration,
the `quota_reset` event and the hooks share one `event_id`, so one reset
is never announced twice.

## Two more sources

- [Claude Code's status line](claude-statusline.md) stands in when
  Claude's usage endpoint is rate limited or signed out.
- [CLIProxyAPI](cliproxy-hub.md) adds the accounts the proxy signs in to.
