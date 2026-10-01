# Providers

A provider is an agent CLI JR-Bar can watch through hooks, local evidence, or
a provider usage source. The README lists them in its
[providers table](../../README.md#providers). How each one is read is
in [NATIVE-PROVIDERS.md](../NATIVE-PROVIDERS.md).

## Hooks

The app detects provider configs without editing them. In **Settings >
Agents**, install, reinstall, or remove hooks one provider at a time. A later
upgrade refreshes only detector-proven JR-Bar-managed hooks. It preserves
inactive flags and custom managed log paths.

`jrbar hooks doctor` shows, for each provider:

- what its config runs today;
- the CLI's version, beside the range JR-Bar has been checked against;
- whether the sockets answer.

"Newer than verified" is a note, not an error. It means nobody has
checked that version yet.

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

## OpenCode

OpenCode reports through a small plugin in `~/.config/opencode/plugins/`,
installed from **Settings > Agents**. It forwards session state and asks and
nothing else: no prompts, file paths or tool output. A permission prompt or a
question shows as Needs You and clears when you answer it. A plugin installed
by an earlier version keeps working and is still recognised, but it cannot
show a question as an ask. The app updates it the next time it refreshes its
hooks after an upgrade, or you can reinstall it from Settings > Agents.

OpenCode sub-agents group under their session, and their asks follow the
Sub-agent asks setting. With it off, a sub-agent's approval raises no card,
light, sound or banner. Its session keeps reading Working and says "1 worker
waiting" beside its workers, so a stuck sub-agent is not passed off as a busy
one; the agent still shows its own prompt. With it on, the approval is an
ordinary ask: it counts in the header and gets a row of its own in the panel,
with Approve and Deny.

## Usage cards

```sh
jrbar providers status            # every provider's state and source (--json)
jrbar providers enable cursor     # or disable
jrbar providers refresh           # read now
```

A card, or a line of `jrbar usage`, is in one of these states:

| state | what it means | what to do |
| --- | --- | --- |
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

### Devin browser sessions

Browser reading starts off. Grant one exact profile before importing a
session, for example:

```sh
jrbar providers configure devin --browser-sources on
jrbar providers browser-consent grant devin --browser zen --profile 'your-profile-name'
```

Use the exact folder name from
`~/Library/Application Support/zen/Profiles` for `--profile`.
Then use **Import Devin browser session** in Usage Center. JR-Bar copies
the selected browser store to a private temporary directory, reads the
session there, and saves its token in Keychain. A Chrome profile can be
granted with `--browser chrome --profile Default` instead. The same card
shows the grant and lets you revoke it. Background repair is a separate
`--background-repair` option on the grant command.

## Fix sign-in

When a card is stale or signed out, **Fix sign-in** is the button to press. It
does the best automatic thing for that provider, tells you in one sentence what
it did, and starts a fresh read so the card recovers within seconds. Nothing
runs until you click it.

- **Claude.** JR-Bar reads Claude's usage with a copy of the sign-in that
  Claude Code keeps in the Keychain. If you mostly use the Claude desktop app,
  nothing renews that copy and it goes stale after a few hours. When that has
  happened and Claude Code says you are logged in, Fix sign-in asks Claude Code
  to renew its own sign-in. It runs one tiny `claude -p` call in a throwaway
  folder, with a 90 second limit. The call spends a handful of tokens, registers
  no session in JR-Bar, and its output is neither kept nor shown. JR-Bar never
  touches Claude Code's refresh token. If Claude Code is logged out, JR-Bar opens
  your terminal on `claude auth login` instead.
- **Grok.** Opens your terminal on `grok login`. JR-Bar notices on its own when
  the CLI saves the new sign-in.
- **Codex and OpenCode.** Opens your terminal on `codex login` or `opencode
  providers login`, but only when the card says signed out. A card that is stale
  for another reason is told so instead.
- **Devin and Cursor.** Their usage comes from a session or token JR-Bar holds,
  not from a CLI login, so Fix sign-in does what the card's old Reconnect button
  did: it clears the rejected stored token, imports your browser session again
  where you have allowed that, and otherwise opens the provider's token page and
  says what to copy.
- **Gemini CLI and Antigravity.** Their sign-in does not go through a login
  command JR-Bar can open, so Fix sign-in says where to sign in.

The terminal is the one you used last (Ghostty, Terminal or iTerm), opened in
your home folder. JR-Bar types the CLI's full path and its login command; you
finish signing in there. A second account is only re-read, never signed in
through the CLI.

## Update a provider's CLI

**Settings > Agents** shows each installed agent CLI's version with an **Update**
button. It runs the CLI's own updater (`claude update`, `codex update`, `grok
update`, `devin update`, `opencode upgrade`) and then shows the result in one
line: "Updated 2.1.285 to 2.1.290", "Already up to date", or why it failed. The
updater runs with the full path to the CLI, no input and a ten minute limit, and
only one per provider and two at a time. If an updater asks for a terminal,
JR-Bar opens yours on the same command. Devin's updater asks before it installs,
so its Update button always opens your terminal on `devin update`. Gemini CLI has no updater of its own, so
its row says how to update it the way you installed it.

JR-Bar contacts nothing for this. The button only runs the tool already on your
Mac, and only when you click it.

### Update available

A row can also say "2.1.290 available". That needs one more request, so it is
off. Turn on **Check for agent updates** in Settings > Agents and JR-Bar will ask
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
