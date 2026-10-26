# Packaging JR-Bar.app

`make package` (`packaging/build_macos_pkg.sh`) builds the whole product as
one signed bundle and the two artifacts that ship it:

```text
JR-Bar.app/
  Contents/MacOS/JR-Bar                        the Swift app (app/, SwiftPM, macOS 26+)
  Contents/Helpers/jrbar-core.app/             the Python daemon, frozen by PyInstaller 6.21
    Contents/MacOS/jrbar-core                  one binary: `core`, `agent-monitor install all`,
                                               `hooks doctor`, `doctor`, `-m jrbar.hook_client`
  Contents/Helpers/jrbar-hook                  the compiled hook shim (hook/jrbar-hook.c)
  Contents/Frameworks/Sparkle.framework        pinned Sparkle 2.9.6
  Contents/Resources/AppIcon.icns, ThirdPartyLicenses/Sparkle.txt
  Contents/Info.plist                          version from pyproject, build number from the
                                               commit count, SUFeedURL, SUPublicEDKey,
                                               LSMinimumSystemVersion 26.0, JRBarCommit

dist/JR-Bar-<version>.pkg                      the installer (component PKG in a product archive)
dist/JR-Bar-<version>.zip                      the Sparkle update archive of the same app
dist/appcast.xml + jr-bar-update-channel.json  the signed feed, when the Sparkle key is in the keychain
dist/release-environment.txt                   the frozen Python environment (pip freeze)
```

The daemon is a nested `.app` rather than a bare directory because
`codesign` treats every entry of `Contents/Helpers` as nested code: a plain
directory of Python files cannot be sealed, PyInstaller's bundle layout
(binaries in `Frameworks`, data in `Resources`) can. The app runs
`Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core core` as its
supervised child with `JRBAR_SUPERVISED=1`, `JRBAR_HOOK_EXEC` pointing at the
bundled shim and `JRBAR_COMMIT` from `JRBarCommit`. On the first launch it
registers itself as a login item (`SMAppService`); provider hooks are
installed from Settings > Agents & Usage, and an upgrade refreshes only the hooks it
already owns.

## What the builder does

1. Validates the source version (`scripts/validate_release_version.py`:
   pyproject and `jrbar.__version__` must agree) and derives
   the artifact names from `scripts/release_artifact_contract.py`.
   Publication and tag validation also require a matching `CHANGELOG.md` heading.
2. Makes a fresh Python 3.12 venv from the hash-locked
   `requirements/release-lock.txt` and installs the checkout into it.
3. Prepares Sparkle (`scripts/prepare_sparkle.py`, digest-pinned
   download), then builds the Swift app against it
   (`app/scripts/build-app.sh` with `JRBAR_SPARKLE_FRAMEWORK_DIR`, unsigned,
   framework not embedded), the shim (`hook/build.sh`) and the daemon
   (`pyinstaller --onedir --windowed`, entry `packaging/jrbar_entry.py`).
   The daemon excludes PyObjC and its GUI framework wrappers.
4. Assembles the bundle, embeds the Sparkle framework, writes the
   Info.plist keys.
5. Signs inside out (`packaging/sign_macos_app.py`): every Mach-O, then the
   nested bundles (the daemon bundle with `packaging/entitlements.plist`, it
   sends the Apple events), then the app with the entitlements (Apple events,
   and Location for the Wi-Fi network name Menu Bar rules read).
6. Verifies: `verify_macos_app.py` (identity, layout, every Mach-O links
   only Apple libraries or code inside the bundle, the Python runtime lives
   in the daemon bundle, no hard links or escaping symlinks),
   `verify_daemon_runtime.py`, `verify_entitlements.py`,
   `verify_sparkle_bundle.py`. The runtime check starts the frozen daemon in
   a temporary home on a temporary socket, with hardware discovery, external
   commands and Python network connections disabled. After the native fallback
   starts, four RSS samples and an in-process image/import inventory must
   contain no AppKit, WebKit or PyObjC images or GUI Python bridges.
   System `libobjc` and JavaScriptCore's C API remain allowed. The receipt
   goes to `release-evidence-raw/daemon-runtime.json`.
7. Notarizes and staples the app when it can (below), makes the ZIP
   (`scripts/package_sparkle_archive.py`), the PKG
   (`scripts/package_macos_artifact.py`), notarizes the PKG when it can, and
   signs the appcast (`scripts/generate_sparkle_channel.py`) when it can.

Every external step sits behind an overridable seam (`APP_BUILD_SCRIPT`,
`HOOK_BUILD_SCRIPT`, `BUILD_PYTHON`, `SECURITY_TOOL`, `CODESIGN_TOOL`,
`XCRUN_TOOL`, `BUILD_ROOT`, `OUTPUT_ROOT`), which is how
`tests/test_app_bundle_security.py` runs the whole script with doubles under
`make fast`.

## Signing, notarization, the feed: with and without

The builder looks in the login keychain and says what it found:

| Found | Result |
| --- | --- |
| `Developer ID Application` identity | hardened runtime, timestamp; `signing: developer-id` |
| only `Nautilus Local Dev` | signed with it, hardened runtime off (no Team ID, so library validation would refuse the app's own frameworks); local testing |
| neither | ad-hoc; local testing only, TCC grants do not survive |
| `Developer ID Installer` identity | the PKG is signed (`productbuild --sign`) |
| notarytool profile `jrbar-notary` (`NOTARY_PROFILE`) and Developer ID | app notarized and stapled before the ZIP and PKG are made; the PKG notarized and stapled when it is signed too; otherwise `notarized: not notarized` |
| the private half of `packaging/sparkle_public_ed_key.txt` under keychain account `SPARKLE_KEY_ACCOUNT`, `ed25519`, `io.jrbar.app` or `com.jonathanreed.jrbar` | `dist/appcast.xml` signed; otherwise `appcast not signed: ...` and no feed |

`APP_SIGN_IDENTITY` / `INSTALLER_SIGN_IDENTITY` override the search.
`ALLOW_UNSIGNED=1` skips the keychain entirely (ad-hoc, no notarization, no
feed): the local-only mode the contract tests use.

Requirements on the build Mac: Command Line Tools (Swift 6.2+, clang),
Python 3.12 (`/opt/homebrew/bin/python3.12`, `python3.12` on `PATH`, or
`BUILD_PYTHON`), the full git history (the build number is the commit count;
a shallow clone needs `JRBAR_BUILD_NUMBER`), network access for the pinned Sparkle download (or
`SPARKLE_ARCHIVE=/path/Sparkle-2.9.6.tar.xz`).

To turn notarization on:

```sh
xcrun notarytool store-credentials jrbar-notary \
  --apple-id <apple-id> --team-id AJ9VWBRNZN     # app-specific password at the prompt
```

To turn the feed on, the private key for the committed public key must be
in the login keychain: on this Mac it is under account
`com.jonathanreed.jrbar` (`build/macos-pkg/sparkle-distribution/bin/generate_keys
--account com.jonathanreed.jrbar -p` prints the public half,
`HOglzj7oHy/NF0HMxpSkOzP036QpoaD+6YzwAGr5iIg=`). A new key means committing
its public half to `packaging/sparkle_public_ed_key.txt`,
`EXPECTED_PUBLIC_KEY` in `scripts/generate_sparkle_channel.py` and the tests
(`tests/test_sparkle_channel.py` pins the key and its SHA-256 fingerprint,
`tests/test_app_bundle_security.py` the key); nothing published yet trusts
the old one.

## Installing

```sh
make clean-install     # installer -pkg dist/JR-Bar-<version>.pkg -target CurrentUserHomeDirectory
                       # -> ~/Applications/JR-Bar.app, no password, then launches it
sudo installer -pkg dist/JR-Bar-<version>.pkg -target /    # /Applications
scripts/install-agents.sh --pkg [SOURCE]                   # what make clean-install runs
```

The product archive allows both the system domain and the home directory
(`enable_currentUserHome`). The postinstall only checks the payload: no
LaunchAgents, no `/usr/local` links, no hooks, no receipts outside the
package's own. The app does the rest on launch. For the command line, alias
the bundled binary:

```sh
alias jrbar='~/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core'
jrbar hooks doctor
```

`scripts/install-agents.sh --pkg` also boots out and parks the two
development LaunchAgents (`com.jonathanreed.jrbar.core` / `.ui`); plain
`scripts/install-agents.sh` puts the dev layout back and turns the login
item off (`JRBAR_LOGIN_ITEM=off`, an app switch that only touches the login
item and exits).

The Python wheel and sdist are `make package-python`; they are developer
artifacts, not the app.


### Headless HID build

The upstream `hidapi==0.14.0.post4` wheel links AppKit to check the macOS
version. Packaging rebuilds that same pinned source with
`build_headless_hidapi.py`, using a compiler availability check instead.
The source archive's SHA-256 must match the reviewed digest. The build
uses its generated C and the already pinned setuptools and wheel.
`headless-hidapi/headless-hidapi.json` records the source, builder and wheel
hashes in the build directory.

The packaged runtime verifier exercises every native adapter and imports
the actual HID extension, even though physical device discovery remains
disabled. Each step records loaded images and Python imports. An omitted
step, an exception, a missing native import or a GUI image fails the gate.
The daemon's read-only `doctor.appkit_loaded` value must also be false.
The probe never posts input, plays sound, launches an app, sends HTTP,
reads Keychain items or exchanges HID reports with a device.
