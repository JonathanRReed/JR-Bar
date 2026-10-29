# Where the usage numbers come from

JR-Bar reads each provider's quota and token history on this Mac. How
each provider is read in detail is in
[NATIVE-PROVIDERS.md](../NATIVE-PROVIDERS.md). This page covers the
sources you can turn on or tune yourself, and the rules that keep the
numbers honest.

## Available and planned providers

Supported usage integrations appear in Settings > Providers > Provider
usage. Coming soon is a searchable list of planned integrations. Entries
there are informational and become available as tested support ships.

## Factory subscription usage

In Settings > Providers or Usage Center, choose Add Factory API key for the
intended account. JR-Bar opens [Factory's API-key settings](https://app.factory.ai/settings/api-keys)
and the key sheet together. Create a key, paste it into the secure field and
choose Save API key. Save checks account and usage access at `api.factory.ai`
before storing the key in JR-Bar's Keychain. The sheet shows the result and stays
open. A failed check preserves any previously saved key.

Turn on Show Factory usage when you want ongoing readings, then choose Refresh.
Save checks the key once without turning on usage. A saved key takes priority
over any browser session imported by an older build.

Factory's current browser storage does not expose a usable access token, so
JR-Bar offers the API-key connection. Older imported access tokens remain usable
while valid, and a previously approved profile can supply a newer access token.
JR-Bar never spends browser refresh tokens or reads Droid's encrypted session.
Factory's documented device login belongs to Droid. No supported third-party
client registration or token export was found for JR-Bar. Signing in with
`droid` and `/login` connects Droid, not JR-Bar's usage reader.

Standard's five-hour, seven-day and monthly windows drive the subscription
headline. Factory's separate Core pool stays visible as detail and does not
constrain Standard's meter or lighting. Missing Core windows stay absent.
For a legacy billing account, the source may instead report Standard and
Premium organization allowances. Their labels keep that scope visible.

The plan's price is not a remaining balance. Extra-use money is not shown
as subscription headroom. A passed reset time does not invent a refill.
A failed read can keep an earlier reading stale only when the account
identity is proved. API access or an unavailable endpoint stays an explicit
error. This integration uses Factory's dashboard API; live access and the
particular account's allowance still need verification.

## Usage is off until you turn a provider on

A provider's quota read asks that provider's servers for a number, or reads the
sign-in another app keeps to do it. Both are **off on a fresh install, one
provider at a time**. Until you turn one on, its card says "Usage off. Turn on
to show quota." and shows no number. Automatic collection makes no request
and reads no Keychain item, auth file or browser session. An explicit
connection or import has its own approval and leaves usage off.

Turn a provider on in any of three places. Each says what it asks, of whom, and
with whose sign-in, in the same words:

- Setup, on the Agents step ("Show Claude usage?" with Turn on or Not now);
- Settings > Providers > Provider usage;
- `jrbar providers usage claude on` (and `off`).

| Provider | Asks | With |
| --- | --- | --- |
| Claude | `api.anthropic.com` | the sign-in Claude Code already has |
| Codex | `chatgpt.com`, through `codex app-server` | the sign-in Codex already has |
| Cursor | `cursor.com` | the sign-in the Cursor app already has |
| Devin | `app.devin.ai` | a token you gave JR-Bar, or a browser session you approved |
| Grok | `cli-chat-proxy.grok.com` | the sign-in in `~/.grok/auth.json` |
| Gemini | `cloudcode-pa.googleapis.com`, `oauth2.googleapis.com` | the sign-in in `~/.gemini/oauth_creds.json` |
| Antigravity | the running Antigravity app on `127.0.0.1` | the quota reading that app reports |
| OpenCode | `opencode.ai` | your OpenCode Go key |
| OpenAI API | `api.openai.com` | the Admin key you gave JR-Bar |

What stays on either way, because nothing leaves the Mac: token and cost
totals counted from files on this Mac, the numbers Codex's own rollout files
recorded, and Claude Code's [status line](claude-statusline.md) if you
installed it.

**If you already used JR-Bar.** The first start after the upgrade keeps a
provider on when it was enabled and had already returned a reading, so nothing
you relied on goes quiet. It writes that as a consent marked "migration" and
logs one line for it. A provider that never worked, or was never on, stays off.
It runs once.

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

Antigravity manages its own backend and quota cache. JR-Bar reads the running
app without forcing a backend refresh, so the time JR-Bar read it does not
establish when Antigravity last refreshed its cache. A separately reported
Argon pool gets its own windows and reset times. JR-Bar adds no Argon window
when the app reports none.

## Inspecting a quota window

In the Usage Center, click a quota ring or its Inspect label to open that
window's reading, reset time, reading age and forecast evidence. Each ring
opens its own window's details.

You can inspect the last reading while the monitor is disconnected. The
popover labels it as the last reading and pauses the forecast until the
monitor reconnects. Stale readings are also labelled, and forecasts wait
for a fresh reading.

## Reading the pace comparison

The Usage Center can show two rates for a quota window:

- **Recent pace** estimates how many percentage points of that window's
  quota were spent per hour.
- **To last until reset** divides the remaining quota by the hours until
  the provider's reported reset. Spending at or below that rate would leave
  quota until reset if the reading and reset time stay accurate.

Recent pace turns orange when it exceeds the rate to reset. This is an
estimate, and usage elsewhere on the account can change it. The comparison
needs a current reading, a future reset and enough evidence for a pace. It
stays hidden while readings are stale or the monitor is disconnected.

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

- you turned OpenCode's usage on (the switch above, or
  `jrbar providers usage opencode on`); it is **off by default**, even if you
  already use OpenCode, unless it had already returned Go data before the
  upgrade;
- a key exists;
- you have not turned it off
  (`jrbar providers configure opencode --option go_usage=off`).

With usage off, OpenCode's card says "Usage off". JR-Bar schedules no
collection job and reads neither the key nor the local quota database.

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

Turn it on in Settings › Providers › Advanced › Incidents › Provider status pages, or:

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

Only absolute paths count, up to eight per provider. Two entries that are
the same real folder (a symlink, a trailing slash) count once, so a
duplicate never doubles a total.

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
  seconds on a very busy one. On a Mac with gigabytes of large transcripts it
  reads in short low-priority passes and can take a few minutes, and the card
  waits until the whole month has been read. JR-Bar then keeps what it worked
  out, so a restart does not repeat it.
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
  30 days, a timestamp no calendar day holds, or a project folder JR-Bar has
  no permission to read. The scan then writes no totals, and the Claude card
  shows nothing instead of a total that leaves those days out. The usage graph is not affected: it reads the full scan.

## Very large transcripts

A long agent session can leave a transcript of several gigabytes. JR-Bar
reads every one of them. Nothing is skipped for being big.

- **Read once, then only what was added.** A transcript is read a piece at a
  time, so a multi-gigabyte file never sits in memory. JR-Bar remembers how far
  it got in each file. Next time it looks at the file's size and the last few
  kilobytes it already read, and reads only the new lines. If the file shrank
  or was rewritten, it reads that file from the start.
- **Reading is done in short passes.** Each pass is about two seconds and runs
  at low priority, then stops on a whole line and saves where it stopped. The
  first time over a Mac with many large transcripts takes several passes. Until
  it finishes, the Usage Center and the usage graph show what has been read so
  far and say "Still reading N files". Newest files are read first, so the
  recent days fill in first. Nothing waits on it: the menu bar and the app start
  as usual.
- **Complete means complete.** The sources line says "partial" only while files
  are still being read, or when a line could not be read. A single line over
  16 MiB, or a message whose usage cannot be read, is skipped by itself and
  counted. The rest of that transcript still counts. A row that only mentions
  usage, such as an attachment, is not a message and is not counted as a
  problem. A transcript over 8 GiB is skipped as too large and the line says so.
- **Compaction records.** Codex writes a "compacted" line that holds a whole
  replaced history, often several megabytes. JR-Bar never loads one. It reads
  the start and the end of the line, which is where the timestamp and the
  compaction id are, and counts the compaction once.

## Token history for Pi, Grok, Gemini CLI and OpenClaw

The usage graph and the Usage Center read each agent's own session
files, read-only:

| agent | folder |
| --- | --- |
| Pi | `$PI_CODING_AGENT_DIR/sessions` (or `$PI_AGENT_DIR`), else `~/.pi/agent/sessions` |
| Grok | `$GROK_HOME/sessions`, else `~/.grok/sessions` |
| Gemini CLI | `~/.gemini/tmp` (`$GEMINI_DATA_DIR/tmp` when set) |
| OpenClaw | `$OPENCLAW_DIR`, else `~/.openclaw` (its session files and agent database) |

These session files are read a line at a time as well, so a large one is
read, not skipped. A single line over 16 MiB is skipped by itself. Only
Gemini CLI's chat files, which are one JSON document each, are left alone when
they pass 64 MiB.

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

A rate may carry `input`, `output`, `cache_read` and `cache_write`. A key
matches when it appears inside the model name, and the longest key wins. An
override always beats the snapshot. Models missing from both stay unpriced in
the cost graph. Local-history cards in Usage Center may use a provider reference
rate, labeled approximate, when a model lacks its own quote.

The cost graph shows how many positive-token records have prices and how many
sessions contain unpriced usage. Unpriced tokens are excluded from the estimate;
their input, cache-read, cache-write and output counts are shown separately.
These counts follow the selected providers and date range. A session containing
both priced and unpriced records counts once among the affected sessions.

T3 Code's stored turn usage does not identify the model for each turn. JR-Bar
keeps it unpriced rather than applying the thread's current model to older turns.
Incomplete local history is reported separately from missing prices.

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


JR-Bar schedules a read at a known reset time. If that read fails temporarily
or still reports the ended window, it keeps one recovery read 15 seconds later.
The recovery is cancelled when the window advances or disappears. It never
bypasses sign-in, permission or rate-limit restrictions, and it does not loop
if the provider still reports the old window.

A reset is celebrated, sent to the app, and passed to
[usage hooks](usage-hooks.md) only when JR-Bar is sure of it:

- **The reset time passed.** When a window's reset time passes between
  two reads and the remaining amount rises by more than 5 points, the clock
  proves it, and the reset is announced at once.
  If the provider briefly reports the ended window at the boundary, a new
  active window observed within 30 seconds uses the same clock evidence.
  Account, source and refill checks still apply.
- **The remaining amount jumped.** When remaining jumps by 50 points or
  more before the reset time, one odd read could explain it.
- **A weekly window started over early.** When a weekly window moves to a
  new reset time before the old one, and remaining rises by 5 points or
  more (or comes back full), it is a candidate too.
- **A late read found the new window.** A provider can keep quoting an
  ended window, with its reset time in the past, until the next message opens
  a new one. When the first read after that shows a new window at 90 percent
  or more remaining, it is a candidate even if the refill was under 50
  points or hours late.
- **An unused window is not a reset.** A window nobody has started quotes
  "now plus one window" as its reset time on every read, so that time
  moves with the clock. JR-Bar never counts that as a reset.

A candidate waits for a second read at least a minute later that still shows
the refill and names the same reset time, within two minutes. JR-Bar asks
for that read within half an hour, and a later one up to a day on still
counts, so a Mac that slept through the half hour does not lose the reset.

A reset waiting for its second read survives a restart. The celebration,
the `quota_reset` event and the hooks share one `event_id`, so one reset
is never announced twice. A confirmed reset the app was not connected for
is offered again when it connects, for 24 hours, and celebrates once.

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
  Claude's usage endpoint is rate limited or signed out, and shows Claude's
  windows while its usage is off if you installed it.
- [CLIProxyAPI](cliproxy-hub.md) adds the accounts the proxy signs in to.
