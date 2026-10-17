# The command line

Install the `jrbar` link from Settings › Shortcuts › Advanced › Command line
([install](install.md#the-command-line)). Every command with `--json`
prints a stable document for scripts.

## Quota and usage

```sh
jrbar usage                    # one line per window: "Claude  5h 58% left · resets 2h14m"
jrbar usage --brief            # a table
jrbar usage --json             # the usage block, with "schema": 1
jrbar usage --provider codex   # one provider
```

`jrbar usage` reads what the running monitor already knows over its
socket. It never asks a provider anything itself. When no monitor
answers, it prints the last readings the monitor saved, and says so on
stderr. It exits 1 when any enabled provider is in error, so a script can
tell "something is broken" from "all fine".

A provider with no quota source says why in words instead of showing a
window: `OpenCode  no quota source: …`. The sources behind the numbers
are in [usage sources](usage-sources.md).

```sh
jrbar providers status --json          # every provider's state, source and reason
jrbar providers usage opencode on     # a provider's usage is off until you say so (off withdraws it)
jrbar providers enable opencode        # enable (and turn usage on), disable, refresh, configure
jrbar providers credential set cliproxy management --stdin   # a key into the Keychain
```

While the app has sealed your settings, turning something on from the command
line in a consent file (a provider's usage, a browser profile, an integration)
is put back and Settings shows a banner: press **Keep the change** there if you
meant it. Turning something off from the command line always works.

## Agents and hooks

```sh
jrbar status                   # sessions and asks right now (--json, with a linked Dot's dot_link timing)
jrbar hooks doctor             # what each provider's config runs, its version, the sockets, hooks turned off in the agent's own settings (--json)
jrbar agent-monitor install claude-statusline [--wrap]   # see claude-statusline.md
jrbar usage-hooks list         # see usage-hooks.md
```

`jrbar hooks doctor` shows each provider CLI's version beside the range
JR-Bar has been checked against. "Newer than verified" is a note, not a
failure: the hooks usually keep working, and they have just not been
checked on that version yet. It also says when JR-Bar's hooks are installed
but switched off in the agent's own settings.

`jrbar agent-monitor uninstall all` visits every provider and prints what
it did for each. A config it cannot clean, such as a symlinked file or one
with comments it cannot read, is named on stderr with the reason, and the
other providers are still cleaned. It exits 1 when any provider could not
be cleaned, and 0 otherwise. A config like that which never names JR-Bar
has nothing to remove and is passed over. `jrbar agent-monitor install all`
also skips and names a provider it cannot write, and still installs the
rest. It exits 0 when it wrote at least one provider and 1 when it wrote
none; `jrbar agent-monitor install <provider>` exits 1 when that provider
could not be written.

## Driving the app

```sh
jrbar quiet 1h --mode dim      # quiet JR-Bar; `jrbar quiet off` ends it
jrbar quiet --until 8am        # or until a time of day; modes: pause, dim, mute, asks-only, dark
jrbar snooze all 30m           # snooze the alerts of every asking session; a session id works too, `off` ends it
jrbar deepwork 50m             # asks-only quiet (25m by default), then what the agents did; `deepwork off` ends it
jrbar awake 2h                 # keep the Mac awake; `--until 8am` works, `awake off` lets go
jrbar toggle dark              # a quick toggle, flip or `on` / `off`
jrbar confetti --provider codex   # a burst in that provider's colours (--session, or --from-hook in a Stop hook)
jrbar set global_brightness_scale 0.6   # any setting by dot path (values are JSON)
jrbar get usage_hooks          # read one
jrbar open panel/toggle        # any jrbar:// link, from the shell
jrbar doctor                   # privacy-safe checks, and the monitor's timings when it runs
```

Durations take `90s`, `15m`, `2h`, `1h30m` or `off`; a time of day takes
`8am`, `8:30pm` or `20:30`, and means the next time the clock reads it. Give
a duration or `--until`, not both. Quiet and keep-awake last at most a day,
and deep work between a minute and a day. `jrbar toggle` takes `awake`,
`dark`, `desktop`, `hidden`, `mute`, `saver`, `lock`, `dock`, `mic`, `eject`
or `sleep`.

`quiet`, `snooze`, `set`, `get`, `confetti` and `status` talk to the
running monitor and exit 3 when none answers. `toggle`, `awake`, `deepwork`
and `open` hand a `jrbar://` link to the app without bringing it to the
front, so they run as a click would. A few of those links ask first, the way
a link from a web page does: ejecting disks, sleeping or locking the Mac,
starting the screen saver, restarting the Finder, changing whether the Dock
hides, unmuting the microphone, keeping the Mac awake with no end, and ending
a quiet from a link (`deepwork off`). Tick "Don't ask again" in that
prompt to let that kind through.

`jrbar confetti` only asks. The burst fires when the Confetti toy is on, and
a second ask within a few seconds joins the first. With `--from-hook` it
reads the session from the hook's JSON on stdin and never fails the hook.

`jrbar doctor --export FILE` also saves the findings as one private JSON
file, and `--json` prints them. It is safe to attach to a report.

The app also answers `jrbar://` links: `jrbar://panel/toggle`,
`jrbar://awake?for=2h`, `jrbar://quiet?mode=dim&for=1h`,
`jrbar://deepwork?for=50m`, `jrbar://settings/shortcuts`,
`jrbar://overview/graph`. Raycast Quicklinks, Alfred and Shortcuts' Open
URLs action can all use them. No link answers an ask.

## Your SidePulse hardware

```sh
jrbar firmware version         # which firmware each mounted Pro or Dot runs
jrbar firmware version --json  # one document per device, for scripts
jrbar firmware upgrade         # update the device that has an update
jrbar firmware upgrade --device SPP-000067 --yes
jrbar firmware upgrade --from ~/Downloads/sidepulse-pro-1.1.0-ota.zip
```

`jrbar firmware version` reads each device's own `STATUS.TXT` and says
whether a newer release is published. It never writes to the device and
never goes to the network: the newest releases it knows are a table in the
app, refreshed when the SidePulse project is reviewed.

`jrbar firmware upgrade` updates a device the way **Settings > Devices & Lighting** does
([what it does, step by step](firmware.md)). It prints what it will download
and write and waits for `yes` (or `--yes`), then shows each step. This is the
only command that fetches anything, once, from `raw.githubusercontent.com`; a
package already on this Mac, or one you name with `--from`, is checked against
the same built-in checksums and nothing is downloaded. With JR-Bar running it
asks JR-Bar to do the update, so the lights pause while the device restarts.
Exit status: 0 updated (or nothing to do), 1 failed, 2 not run, 3 the device
did not come back (check it).

A Pro on firmware 1.1.0 or later balances colour inside the device. If you
tuned channel gains in the Colors window for older firmware, reset them
after updating, or the two corrections stack.

## For other tools

`jrbar serve` and the examples built on it are in
[scripts and status](scripts-and-status.md). `jrbar integrations` turns on
and checks the T3 Code projection; see [integrations](../INTEGRATIONS.md).
