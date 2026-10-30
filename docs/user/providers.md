# Providers

A provider is an agent CLI JR-Bar can watch through hooks, local evidence, or
a provider usage source. The README lists them in its
[providers table](../../README.md#providers). How each one is read is
in [NATIVE-PROVIDERS.md](../NATIVE-PROVIDERS.md).

## Hooks

The app detects provider configs without editing them. In **Settings >
Providers**, install, reinstall, or remove hooks one provider at a time. A later
upgrade refreshes only detector-proven JR-Bar-managed hooks. It preserves
inactive flags and custom managed log paths.

`jrbar hooks doctor` shows, for each provider:

- what its config runs today;
- the CLI's version, beside the range JR-Bar has been checked against;
- whether the sockets answer;
- whether the agent's own settings have turned its hooks off, which leaves
  them installed but silent.

"Newer than verified" is a note, not an error. It means nobody has
checked that version yet.

### Recheck hooks in the app

In Settings > Providers, click **Recheck hooks** after a provider turn
or a hook repair. It reads local hook settings, the hook receiver's status,
the last event arrival and queued event counts. It does not install hooks,
update providers or answer an ask. The button waits while a check is running
or the monitor is offline. Repair remains a separate action on each row.

If the hook receiver is not answering, the report says so. A failed check
keeps the previous readings marked **Last report**. Config-read errors appear
on the provider row instead of claiming the hooks are working.

The last event time proves only that an event arrived. To check approvals or
interruptions, use a real provider session and confirm its outcome there.
After reconnecting, recheck to see the new receiver report. The demo ask does
not test a provider integration.

### A moved Claude Code or Codex home

If you moved either one with `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, JR-Bar
installs, refreshes, removes and checks its hooks in that folder (`settings.json`
for Claude Code, `config.toml` for Codex), the same folder its usage scans
read, and leaves `~/.claude` and `~/.codex` alone. `jrbar hooks doctor --json`
names the file under `config_path` and says `"config_home": "environment"`.

The app starts its daemon with the environment the app itself has, and a
variable exported only in your shell profile is not in it when the app opens
from Finder or at login. Set it with `launchctl setenv CLAUDE_CONFIG_DIR
<folder>` and open JR-Bar again, or run `jrbar agent-monitor install claude`
from the shell that has it. Other account homes you list under
`provider_extra_homes` are read for usage only; JR-Bar installs no hooks into
them.

## Grok

Grok runs each sub-agent in a session of its own. JR-Bar groups it under the
session that started it, so it is not a second main session and does not hold
the Mac awake on its own. Grok's notifications show as Waiting and raise no
alert for any session; an approval ask that carries a request id follows the
Sub-agent asks setting, as OpenCode's do. A sub-agent that was already running
when JR-Bar started shows as a session of its own until it ends.

## OpenCode

OpenCode reports through a small plugin in `~/.config/opencode/plugins/`,
installed from **Settings > Providers**. It forwards session state and asks and
nothing else: no prompts, file paths or tool output. A permission prompt or a
question shows as Needs You and clears when you answer it. A plugin installed
by an earlier version keeps working and is still recognised, but it cannot
show a question as an ask. The app updates it the next time it refreshes its
hooks after an upgrade, or you can reinstall it from Settings > Providers.

OpenCode sub-agents group under their session, and their asks follow the
Sub-agent asks setting. With it off, a sub-agent's approval raises no card,
light, sound or banner. Its session keeps reading Working and says "1 worker
waiting" beside its workers, so a stuck sub-agent is not passed off as a busy
one; the agent still shows its own prompt. With it on, the approval is an
ordinary ask: it counts in the header and gets a row of its own in the panel.
Approve and Deny are offered on a row only where JR-Bar can deliver the answer,
which today means Claude and Codex. For every other agent (Gemini CLI, Devin,
Grok, OpenCode and the rest) the row never draws Approve or Deny. It says
"Answer this in Ghostty", naming the terminal or app the session runs in, and
its button opens that app. When JR-Bar does not know the app the line says "Answer
this in its own window" and the button reads "Open session". The same words
appear for Claude or Codex in a terminal that cannot prove which tab is
focused, because JR-Bar will not type into a window it cannot identify.

## Usage cards

```sh
jrbar providers status            # every provider's state and source (--json)
jrbar providers usage cursor on   # ask Cursor for usage; "off" withdraws it
jrbar providers enable cursor     # turns the provider and its usage on
jrbar providers disable cursor    # turns both off
jrbar providers refresh           # read now
```

Every provider's usage is off until you turn it on, so a new install shows
"off (not turned on)" for each. See
[usage-sources.md](usage-sources.md#usage-is-off-until-you-turn-a-provider-on).

A card, or a line of `jrbar usage`, is in one of these states:

| state | what it means | what to do |
| --- | --- | --- |
| off (not turned on) | you have not turned this provider's usage on; nothing was asked | turn it on in Settings > Providers, or `jrbar providers usage <provider> on` |
| ready | a fresh reading | nothing |
| stale | the last good reading, kept while a new one fails | usually nothing; it clears on the next good read |
| sign-in required | the provider's login is missing or expired | sign in with the provider's own CLI |
| needs permission | the source needs your consent first, such as reading a browser cookie | `jrbar providers browser-consent grant`, or leave it off |
| source not found | the provider's files or app are not on this Mac | nothing, unless you expected them |
| no quota source | the provider reports no quota; token totals only | nothing (see [OpenCode](usage-sources.md#opencode-and-opencode-go)) |
| rate limited | the provider asked JR-Bar to slow down | nothing; it retries later |
| error | the read failed | the card and `jrbar providers status` name the fix |

A window that can drive the lights is a 5-hour or weekly window the
provider states plainly. Any other window is shown as detail and never
lights anything.

### Room left elsewhere

When a card's window is nearly spent (90 percent or more used) and another
provider you use has at least half of the same kind of window left, the card
adds one line of numbers: "Codex has 82% left this 5h window." It only states
the fact. JR-Bar never switches anything for you, and a provider with no quota
source, a signed-out provider or a window that has already reset is never
quoted. If the other provider's reading is the last good one kept while a new
read fails, the line says so: "Codex had 80% left this 5h window (stale, read
2h 13m ago)."

### Devin browser sessions

Browser reading starts off. Grant one exact profile before importing a
session, for example:

```sh
jrbar providers configure devin --browser-sources on
jrbar providers browser-consent grant devin --browser zen --profile 'your-profile-name'
```

Use the exact folder name from
`~/Library/Application Support/zen/Profiles` for `--profile`. A Chrome
profile can be granted with `--browser chrome --profile Default` instead.
Granting imports nothing. Then use **Import Devin browser session** on
Devin's card in the Usage Center (the button shows once browser sources are
on): JR-Bar copies the granted browser store to a private temporary
directory, reads the session there, and saves its token in Keychain. For a
Chromium profile the command line can do the same import:

```sh
jrbar providers browser-consent import devin --browser chrome --profile Default \
    --profile-root "$HOME/Library/Application Support/Google/Chrome/Default"
```

The Usage Center card shows each grant and lets you revoke it; revoking also
removes the imported token while it is still the imported one. Background
repair is a separate `--background-repair` option on the grant command.

## Fix sign-in

When a card is stale or signed out, **Fix sign-in** is the button to press. It
re-reads the credential or offers the provider's sign-in route. The result tells
you what happened and what to do next. A current credential starts a fresh usage
read. Nothing runs until you click it.

- **Claude.** JR-Bar reads Claude's usage with a copy of the sign-in that
  Claude Code keeps in the Keychain. Fix sign-in copies a current access token
  after the required Keychain grant. If Claude Code replaces its Keychain item
  and JR-Bar loses access, the card asks to allow Keychain access instead of
  saying the account signed out. Background reads stop until you grant access
  again. If it has expired or Claude has rejected
  it, open Claude Code and let it renew the sign-in, then reconnect in JR-Bar.
  JR-Bar leaves renewal and the refresh token with Claude Code. A named Claude
  profile keeps its own credential; update that profile's credential instead of
  replacing it with the default Claude Code account.
- **Factory.** Choose Connect Factory on the affected account. Select the browser
  profile, approve Use this browser's Factory sign-in and click Connect.
  Factory may ask you to sign in again in that browser. JR-Bar renews through
  WorkOS and saves rotated tokens only in its own Keychain. Turn on Show
  Factory usage and Metering, then Refresh. Use API key is the fallback; a saved
  key takes priority until you remove it.
- **Grok.** Opens your terminal on `grok login`. JR-Bar notices on its own when
  the CLI saves the new sign-in.
- **Codex and OpenCode.** Opens your terminal on `codex login` or `opencode
  providers login`, but only when the card says signed out. A card that is stale
  for another reason is told so instead.
- **Devin and Cursor.** Their usage comes from a session or token JR-Bar holds,
  not from a CLI login, so Fix sign-in does what the card's old Reconnect button
  did: it imports a replacement where you have allowed that and otherwise
  opens the provider's token page and says what to copy. A failed import keeps
  the previous credential. When sign-in data lacks a usable access token,
  Devin offers its API-key editor and Cursor offers manual session-token import.
- **Gemini CLI and Antigravity.** Their sign-in does not go through a login
  command JR-Bar can open, so Fix sign-in says where to sign in.

The terminal is the one you used last (Ghostty, Terminal or iTerm), opened in
your home folder. JR-Bar types the CLI's full path and its login command; you
finish signing in there. A second account is only re-read, never signed in
through the CLI.

## Update a provider's CLI

**Settings > Providers** shows each installed agent CLI's version with an
**Update** button. Claude, Grok, Devin and OpenCode use their own updaters.
Codex and Gemini use the trusted global npm or Homebrew installation that owns
the CLI. npm keeps the original installation prefix. Unknown or project-local
installations receive instructions to use their original installer.

The result shows the version change, “Already up to date”, or why the update
failed. Commands use absolute paths, no input and a ten-minute limit. One update
per provider and at most two independent updates can run at once. Updates using
the same npm prefix or Homebrew installation run one at a time. Native updaters
that need a terminal open yours on the same command. A package manager that
needs a terminal supplies manual instructions instead. Devin always opens a
terminal because its updater asks before installing.

Only clicking Update starts an updater. The tool or package manager may contact
its registry to download the update. Background version checks are separate.

### Update available

A row can also say "2.1.290 available". That needs one more request, so it is
off. Turn on **Check for agent updates** in Settings > Providers and JR-Bar will ask
`registry.npmjs.org` for the latest version of each installed CLI that has an npm
package: Claude Code, Codex, Grok, Gemini CLI and OpenCode (Devin has none). It
asks every 6 hours and when you refresh the Agents page, with one plain request
that carries nothing about your Mac. Turn it off and no request is made. The
Update button never depends on it.

## More sources

- [Where the usage numbers come from](usage-sources.md): OpenCode Go,
  more than one account home, token history, prices, reset credits and
  how resets are confirmed.
- [Claude Code's status line](claude-statusline.md).
- [CLIProxyAPI as a hub](cliproxy-hub.md).
