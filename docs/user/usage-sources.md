# Where the usage numbers come from

JR-Bar reads each provider's quota and token history on this Mac. How
each provider is read in detail is in
[NATIVE-PROVIDERS.md](../NATIVE-PROVIDERS.md). This page covers the
sources you can turn on or tune yourself, and the rules that keep the
numbers honest.

## How a refresh runs

JR-Bar asks up to four providers at a time, so one slow provider never holds
up the others. A refresh that finishes in a second or two shows all its
answers at once. A slower one shows the providers that have answered after
about a second and a half, and each of the others as it lands; a provider
still being asked keeps the reading it had until its answer arrives.

Each provider has 75 seconds to answer. A provider that does not is given up
on for that refresh only: its card keeps its last good reading, marked stale,
with "response timed out" as the reason, and JR-Bar asks again later on the
same backoff as any other failure. A provider that fails or is rate limited
backs off alone, too.

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

## Provider status pages

When a provider is having an outage, its usage numbers can fail for a
reason that has nothing to do with your setup. JR-Bar can check the
providers' public status pages so the card says "incident" instead of
looking like your fetch broke. This is a request that leaves your Mac, so
it is **off until you turn it on**.

Turn it on in Settings › Usage › Provider status pages, or:

```sh
jrbar set provider_status_feeds_enabled true
```

While it is on, JR-Bar asks these three addresses once every 10 minutes,
and only for a provider it found on this Mac:

- `status.anthropic.com` for Claude;
- `status.openai.com` for Codex;
- `status.cursor.com` for Cursor.

Each request is a plain public read. It carries no key, prompt, account
or path, only a fixed `JR-Bar/status-feed` user agent. The status page
sees your network address, as any website does. An answer that cannot be
read is treated as silence, never as an alarm.

Turn the setting off and the next usage refresh stops the checks and
clears any incident they showed. Nothing is asked again until you turn it
back on.

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

The Claude and Codex cards show tokens and cost for the last 30 days: today
and the 29 days before it, by this Mac's own calendar. Those are the same
days the usage graph draws for its 30-day range, so the card and the graph
count the same month. Each message or turn is counted once, however many
times a resumed or forked session copied it. The cards read what JR-Bar's
usage scans already worked out and never scan the transcripts themselves.

- **Every scan keeps the whole 30 days.** However short a range a scan was
  asked for, it reads back at least 30 days and writes that month's totals,
  a few numbers for each day and model, into its cache. The 7-day graph, the
  Usage window's ranges and the core's own 30-day scan after it starts all
  leave the cards whole. The graph is still given only its own range.
- **A busy month is counted whole.** The cache's per-file records are capped
  at 8 MiB, which keeps JR-Bar's own memory small, and a month of heavy use
  on a busy Mac does not fit in that. The cards do not read those records.
  The month's totals are worked out from every message the scan saw, and
  they take a few kilobytes however busy the month was.
- **Claude shows a whole total or nothing.** The card appears once a scan
  has covered the 30 days, across every home. After JR-Bar updates, the
  first scan starts over from the transcripts, so the Claude card is empty
  until the core's own 30-day scan finishes. That scan starts about 8
  seconds after the core does and takes seconds on a quiet Mac and tens of
  seconds on a very busy one. JR-Bar then keeps what it worked out, so a
  restart does not repeat it.
- **Codex counts the days its caches cover.** If a cache has no totals for
  the whole 30 days (it was never scanned that far back, or a home you added
  has not been scanned yet), Codex adds up only the days it does have and the
  card does not say so. Its quota reading is kept either way, because that
  lives in the same cache.
- **Claude adds every home or none.** If a home you listed under
  `provider_extra_homes` has not been scanned yet, or JR-Bar cannot list
  your extra homes, the Claude card waits instead of showing one home's
  share. Codex keeps the primary home in that case.
- **A month it cannot hold says so.** On rare input the month's totals
  cannot be kept: a transcript that names more than 256 different models in
  30 days, or a timestamp no calendar day holds. The scan then writes no
  totals, and the Claude card shows nothing instead of a total that leaves
  those days out. The usage graph is not affected: it reads the full scan.

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

Each record is priced by the model it ran, not by the agent that wrote it.
Pi, OpenClaw and OpenCode run models from several makers, so a GPT model
takes OpenAI's prices, a Gemini model Google's, and a Claude model
Anthropic's, whichever agent ran it. The Gemini CLI uses Google's and Codex
OpenAI's. When the cost graph meets a model with no price, its summary line
says "No price for" and names it: those tokens are still counted, and only
their dollars are left out.

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

## When Claude's usage read is refused

Claude's usage endpoint answers three kinds of "no", and the card tells
them apart:

- **Rate limited** (a 429): wait. JR-Bar backs off and asks again later.
- **Signed out** (a 401): the sign-in is not accepted any more. The card
  says "Reconnect Claude · authentication required".
- **No usage permission** (a 403 that carries Claude's own error
  message): the sign-in is known, but it was not granted the permission
  that reading usage needs, for example a token made for running prompts
  only. The card says "Reconnect Claude · usage permission missing".
  Asking again with the same token gets the same answer, so JR-Bar waits
  until the sign-in changes, and signing in to Claude again is the fix.

A 403 whose body is not Claude's own error, such as a web page from a proxy
or a network filter, is not Claude refusing the sign-in, so it is treated
like any other failure. So is every other answer that is not a success, a
401, a 403 or a 429, and so is a network failure: the card says "network
unavailable" and JR-Bar asks again on a timer.

## Two more sources

- [Claude Code's status line](claude-statusline.md) stands in when
  Claude's usage endpoint is rate limited or signed out.
- [CLIProxyAPI](cliproxy-hub.md) adds the accounts the proxy signs in to.
