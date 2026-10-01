# Recovery

Start with the visible state. JR-Bar keeps failures honest instead of turning
an old reading into a fresh one.

## Monitor offline

Quit JR-Bar and open the installed app again. If the panel still says the
monitor is offline, run:

```sh
jrbar doctor
```

The report names the daemon build and any failed checks. If the command is not
installed, open **Settings > Shortcuts > Command line** and install its link
first. Reinstall the app only after the same installed copy still fails to
start its daemon.

## Quota is stale

Open the Usage Center and read the source note on the affected provider.
`jrbar providers status` gives the same state in the terminal.

- For Codex local evidence, finish one Codex prompt so its rollout records a
  new reading.
- For a provider that says its sign-in is stale or required, press **Fix
  sign-in** on its card. For Claude it asks Claude Code to renew its own
  sign-in; for Grok, Codex and OpenCode it opens your terminal on the CLI's own
  login. [What it does for each provider](providers.md#fix-sign-in).
- A rate-limited provider needs time. JR-Bar backs off and retries later.

JR-Bar keeps a last good reading only when it can prove the account is the
same. An account switch may leave the card empty until the new account returns
a fresh reading.

## Hooks are missing

Open **Settings > Agents** and install or reinstall the affected provider.
Then run:

```sh
jrbar hooks doctor
```

The report shows the command in each provider config and whether JR-Bar's
sockets answer. Upgrades refresh only detector-proven managed hooks. A custom
or ambiguous hook is left alone for you to review.

## A permission is missing

Open JR-Bar's setup or the relevant feature settings. The permission row names
what the feature needs and opens the matching System Settings page when macOS
allows it. Grant only the features you want.

If a permission was granted to a development build, the installed app may ask
again. macOS ties grants to the signed app. The full list is in the
[permissions table](../../README.md#permissions).
