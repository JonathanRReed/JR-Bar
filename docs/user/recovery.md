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
- For Claude's official usage source, use **Reconnect Claude**. Claude Code
  owns the sign-in, so sign in there first if JR-Bar reports authentication
  required.
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

## A saved file could not be read

JR-Bar keeps your own choices (effect assignments, pins and snoozes,
acknowledged requests, cleared completions) in small files under
`~/.local/state/jrbar`. When one of them cannot be read, JR-Bar does not
overwrite it. It moves the file aside as `<name>.corrupt-<date and time>`
(for example `effect-assignments.json.corrupt-20260901T120000Z`) and starts
that list empty. If only some rows were damaged, it keeps the good rows and
leaves a copy of the original beside them. The three newest copies of each
file are kept, and each is private to you. The daemon log has one line
saying which file was set aside.

To get a file back, quit JR-Bar, copy the `.corrupt-` file over the original
name, and open JR-Bar again. If it is still unreadable it will be set aside
again.

Settings follow the same rule. A `settings.json` that cannot be read is set
aside as `settings.json.corrupt-<date and time>`, with the same three-newest
rule, and the next save writes a fresh one.

If `settings.json` is changed outside JR-Bar while it runs (by hand, by a
restore, or by `jrbar battery configure`), JR-Bar notices the next time it
saves a setting. If the file is whole, JR-Bar takes it as it is, shows it in
Settings, and keeps the settings it held as `settings.json.replaced` (one
backup, the latest replacement). A file that does not parse is not taken: JR-Bar
waits for the next refresh in case your editor is still saving, and if the file
has not changed by then it sets it aside as `settings.json.corrupt-<date and
time>` and writes the settings it holds out again. Until a setting is saved, an
edit made while JR-Bar runs is not seen.
