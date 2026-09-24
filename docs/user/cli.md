# The command line

Install the `jrbar` link from Settings › Shortcuts › Command line
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
jrbar providers enable opencode        # enable, disable, refresh, configure
jrbar providers credential set cliproxy management --stdin   # a key into the Keychain
```

## Agents and hooks

```sh
jrbar status                   # sessions and asks right now (--json)
jrbar hooks doctor             # what each provider's config runs, its version, the sockets (--json)
jrbar agent-monitor install claude-statusline [--wrap]   # see claude-statusline.md
jrbar usage-hooks list         # see usage-hooks.md
```

`jrbar hooks doctor` shows each provider CLI's version beside the range
JR-Bar has been checked against. "Newer than verified" is a note, not a
failure: the hooks usually keep working, and they have just not been
checked on that version yet.

## Driving the app

```sh
jrbar quiet 1h --mode dim      # quiet JR-Bar; `jrbar quiet off` ends it
jrbar set global_brightness_scale 0.6   # any setting by dot path (values are JSON)
jrbar get usage_hooks          # read one
jrbar toggle dark              # a quick toggle; `jrbar awake 2h` keeps the Mac up
jrbar open panel/toggle        # any jrbar:// link, from the shell
jrbar doctor                   # daemon commit, memory, checks
```

The app also answers `jrbar://` links: `jrbar://panel/toggle`,
`jrbar://awake?for=2h`, `jrbar://quiet?mode=dim&for=1h`,
`jrbar://overview/graph`. Raycast Quicklinks, Alfred and Shortcuts' Open
URLs action can all use them. No link answers an ask.

## For other tools

`jrbar serve` and the examples built on it are in
[scripts and status](scripts-and-status.md).
