# Install and remove

JR-Bar needs an Apple silicon Mac on macOS 26 or newer. It is one signed
app bundle that carries the daemon (`jrbar-core`) and the hook shim
(`jrbar-hook`). Nothing else is installed on the system.

## From a release

Once a release is published on
[GitHub](https://github.com/JonathanRReed/JR-Bar/releases), download
`JR-Bar-<version>.pkg` and open it. The installer's default is your own
`~/Applications`, which needs no password.

## From source

You need the Command Line Tools (Swift 6.2 or newer) and Python 3.12.

```sh
git clone https://github.com/JonathanRReed/JR-Bar.git && cd JR-Bar
./scripts/bootstrap-dev.sh   # the Python venv the build uses
make package                 # dist/JR-Bar-<version>.pkg, signed with whatever identity the keychain has
make clean-install           # installs it into ~/Applications and opens it
```

`sudo installer -pkg dist/JR-Bar-<version>.pkg -target /` installs into
`/Applications` instead.

## First launch

On first launch the app:

- starts its daemon;
- points the hook of every provider it finds on the Mac at the bundled shim
  (Settings › Agents installs, reinstalls or removes them per provider);
- registers itself as a login item.

Click the icon for the panel, and right-click it for the menu. No
permission is asked for at launch. Each feature asks the first time it
needs one; the README's [permissions table](../../README.md#permissions)
lists them all.

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

Options:

- `--keep-app` keeps the app.
- `--purge-state` also removes settings, logs and history.
- `--dry-run` needs no `sudo`.

To remove it by hand:

1. Quit the app.
2. Run `jrbar agent-monitor uninstall all`. It removes the hooks and puts
   back Claude Code's status line if JR-Bar's was in it.
3. Delete `JR-Bar.app`.
