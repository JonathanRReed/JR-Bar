# Providers

A provider is an agent CLI whose hooks JR-Bar installs and whose usage it
reads. The README lists them in its
[providers table](../../README.md#providers). How each one is read is
in [NATIVE-PROVIDERS.md](../NATIVE-PROVIDERS.md).

## Hooks

The app installs hooks on first launch for every provider that has a
config on the Mac. Settings › Agents installs, reinstalls or removes them
one provider at a time.

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

## More sources

- [Where the usage numbers come from](usage-sources.md): OpenCode Go,
  more than one account home, token history, prices, reset credits and
  how resets are confirmed.
- [Claude Code's status line](claude-statusline.md).
- [CLIProxyAPI as a hub](cliproxy-hub.md).
