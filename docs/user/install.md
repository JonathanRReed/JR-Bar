# Install and remove

JR-Bar needs an Apple silicon Mac on macOS 26 or newer. It is one signed
app bundle that carries the daemon (`jrbar-core`) and the hook shim
(`jrbar-hook`). Nothing else is installed on the system.

## From a release

From [GitHub Releases](https://github.com/JonathanRReed/JR-Bar/releases),
download the current `JR-Bar-<version>.pkg` and open it. The installer's
default is your own `~/Applications`, which needs no password.

## From source

You need the Command Line Tools (Swift 6.2 or newer) and Python 3.12.

```sh
git clone https://github.com/JonathanRReed/JR-Bar.git && cd JR-Bar
make bootstrap               # the pinned Python environment the build uses
make package                 # dist/JR-Bar-<version>.pkg
make clean-install           # installs it into ~/Applications and opens it
```

`sudo installer -pkg dist/JR-Bar-<version>.pkg -target /` installs into
`/Applications` instead.

## First launch

On first launch the app:

- starts its daemon;
- records the installed build so later upgrades can identify it;
- registers itself as a login item.

It does not install provider hooks by itself. Open **Settings > Agents**,
review the detected providers, and install the ones you want JR-Bar to watch.
Later upgrades refresh only hooks the detector can prove JR-Bar manages.
Inactive hooks remain inactive, and a custom managed log path is preserved.

Click the icon for the panel, and right-click it for the menu. No
permission is asked for at launch. Each feature asks the first time it
needs one; the README's [permissions table](../../README.md#permissions)
lists them all.

Continue with the [quick start](quick-start.md). If the monitor or a provider
does not come online, use [recovery](recovery.md).

## The command line

The `jrbar` command lives inside the bundle. **Settings › Shortcuts ›
Command line › Install** links it as `~/.local/bin/jrbar`. Put
`~/.local/bin` on your `PATH` if it is not there already. The link follows
the app when it updates, and Remove takes it away again. What the command
does is in [the command line](cli.md).

## Remove it

```sh
sudo ./scripts/uninstall-macos.sh --dry-run   # show every step first
sudo ./scripts/uninstall-macos.sh
```

The script removes:

- the hooks JR-Bar wrote;
- its helpers;
- the `jrbar` link;
- the app, wherever it is (`~/Applications` or `/Applications`).

It removes a `jrbar` link only when that link points into a JR-Bar
bundle, so a `jrbar` of your own is left alone.

If a hook cannot be removed, for example because an agent's config is a
symlink into your dotfiles or holds comments JR-Bar cannot read, the
script names the config, exits 1 and keeps the app, the helpers and your
data. Every other agent is still cleaned first. Fix that config or remove
JR-Bar's entries from it by hand, then run the script again.

Options:

- `--keep-app` keeps the app.
- `--purge-state` also removes settings, logs and history.
- `--dry-run` needs no `sudo`.

To remove it by hand:

1. Quit the app.
2. Run `jrbar agent-monitor uninstall all`. It removes the hooks and puts
   back Claude Code's status line if JR-Bar's was in it. It names any
   config it could not clean and exits 1; clean those by hand and run it
   again before you go on.
3. Delete `JR-Bar.app`, once step 2 exits 0.
