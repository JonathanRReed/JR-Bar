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

## More sources

- [Where the usage numbers come from](usage-sources.md): OpenCode Go,
  more than one account home, token history, prices, reset credits and
  how resets are confirmed.
- [Claude Code's status line](claude-statusline.md).
- [CLIProxyAPI as a hub](cliproxy-hub.md).
