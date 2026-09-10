# Releasing JR-Bar

Everything happens on the owner's Mac. `make package` builds the product,
`scripts/verify_macos_release.sh` proves what it built, and
`scripts/publish_release.sh` uploads it. There is no CI release path: the
self-hosted `macos-production` workflow was retired on 2026-09-10 because it
targeted a runner that never existed, and standing one up would have put the
Developer ID key, the notary profile and the Sparkle private key on a machine
that runs workflow code. GitHub Actions checks the source
(`.github/workflows/tests.yml`); the Mac makes the release.

## What ships

One signed `JR-Bar.app` carrying three programs:

```text
JR-Bar.app/Contents/MacOS/JR-Bar                   the Swift menu-bar app
JR-Bar.app/Contents/Helpers/jrbar-core.app         the frozen Python daemon
JR-Bar.app/Contents/Helpers/jrbar-hook             the compiled hook shim
JR-Bar.app/Contents/Frameworks/Sparkle.framework   pinned Sparkle 2.9.6
```

The daemon is a nested `.app` and not a bare directory because `codesign`
treats every entry of `Contents/Helpers` as nested code, and only a bundle
layout can be sealed. `Contents/MacOS/JR-Bar` takes no arguments — it opens
the menu bar. Every command line lives in the daemon:
`Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core`.

## 1. Build

```sh
make fast            # lint, contract tests (the builder runs against doubles), version contract
make package         # packaging/build_macos_pkg.sh
```

`make package` prepares the pinned Sparkle distribution, builds the Swift app
against it, builds the hook shim and the frozen daemon, assembles and signs
`build/macos-pkg/app/JR-Bar.app` inside out, verifies it, and writes:

```text
dist/JR-Bar-<version>.pkg        installer (system or home-directory domain)
dist/JR-Bar-<version>.zip        Sparkle update archive of the same bundle
dist/appcast.xml                 signed feed (only with the Sparkle key in the keychain)
dist/jr-bar-update-channel.json  what the feed binds: version, build, download URL, signature, hashes
dist/release-environment.txt     pip freeze of the frozen daemon's environment
```

Intermediate outputs, in case you need to look at one:
`build/macos-pkg/swift/JR-Bar.app` is the Swift build before assembly,
`build/macos-pkg/pyinstaller/jrbar-core.app` is PyInstaller's raw output, and
`build/macos-pkg/app/JR-Bar.app` is the assembled, signed candidate.

The summary at the end says exactly what happened:

```text
JR-Bar 0.8.0 (<commit>)
  JR-Bar-0.8.0.pkg: ... (20M)
  JR-Bar-0.8.0.zip: ... (20M)
  signed:     developer-id (Developer ID Application: Jonathan Reed (AJ9VWBRNZN))
  installer:  unsigned
  notarized:  not notarized
```

### What is signed when

`packaging/README.md` has the detail. In short:

- **App signing** uses the best identity in the keychain: Developer ID
  Application (hardened runtime, secure timestamp), else `Nautilus Local Dev`,
  else ad-hoc. Only a Developer ID build is distributable. An ad-hoc bundle is
  a *different app* to macOS: it loses the user's Notification and Automation
  grants.
- **Notarization** runs when the `jrbar-notary` keychain profile exists and
  the build is Developer ID signed:

  ```sh
  xcrun notarytool store-credentials jrbar-notary \
      --apple-id <apple-id> --team-id AJ9VWBRNZN --password <app-specific-password>
  ```

  The app is notarized and stapled *before* the ZIP and the PKG are cut, so
  both carry the ticket.
- **The PKG signature** needs a `Developer ID Installer` certificate. There
  is not one in this keychain yet, so the PKG is unsigned and cannot be
  notarized in its own right; the stapled app inside it still is. Create the
  certificate at developer.apple.com → Certificates → Developer ID Installer,
  download it, double-click it, and `make package` picks it up with no edit.
- **The feed** is signed when the private half of
  `packaging/sparkle_public_ed_key.txt` is in the login keychain (accounts
  tried, in order: `SPARKLE_KEY_ACCOUNT`, `ed25519`, `io.jrbar.app`,
  `com.jonathanreed.jrbar`). On this Mac that is the login keychain item
  "Private key for signing Sparkle updates", account `com.jonathanreed.jrbar`,
  generated 2026-09-10 with Sparkle 2.9.6's `generate_keys --account
  com.jonathanreed.jrbar`; its public half is
  `HOglzj7oHy/NF0HMxpSkOzP036QpoaD+6YzwAGr5iIg=`. (The older `ed25519` account
  holds an unrelated July key; nothing trusts it.) Back the private key up
  with `generate_keys --account com.jonathanreed.jrbar -x <file>` — losing it
  means every installed app stops trusting the feed forever. Without it there
  is no `appcast.xml` and installed apps never see the release.

  The public key is baked into every app as `SUPublicEDKey`. Changing keys
  means changing `packaging/sparkle_public_ed_key.txt`,
  `scripts/generate_sparkle_channel.py`, `src/jrbar/sparkle_updater.py` and
  the tests (`tests/test_sparkle_channel.py` pins its SHA-256 fingerprint)
  before the first release that uses it.
- **The in-app updater** is `app/Sources/JRBarApp/SparkleUpdater.swift` over
  the embedded framework: "Check for Updates…" in the app menu, automatic
  checks off until Settings › General turns them on, and the `stable` / `beta`
  channel from the same page. `JRBAR_RELEASE_CHANNEL=beta make package`
  produces a `<sparkle:channel>beta</sparkle:channel>` item; stable entries
  roll out over one day, beta entries immediately.

Retaining earlier releases in the feed: put the currently published
`appcast.xml` and every `JR-Bar-*.zip` it references in one directory and set
`JRBAR_SPARKLE_HISTORY_DIR` to it. The builder verifies each retained archive
against the key before signing the replacement feed.

## 2. Prove it

`scripts/verify_macos_release.sh` is the authoritative gate. It rebuilds from
a clean checkout of freshly fetched `origin/main`, then records one signed
*receipt* per claim under `dist/release-evidence/`, each bound to the
candidate's SHA-256 so a receipt cannot be reused for a different build.

```sh
./scripts/verify_macos_release.sh --preflight     # what can and cannot run here
./scripts/verify_macos_release.sh --reuse-build   # verify what is already built
./scripts/verify_macos_release.sh                 # the authoritative run
```

**Capabilities are discovered, not demanded.** The gate looks in the keychain
for the Developer ID Application identity (required — it refuses to certify an
ad-hoc candidate), the Developer ID Installer identity, the `jrbar-notary`
profile and the Sparkle account. Anything missing turns its phases into a
printed `SKIP` with the reason, and the run ends with

```text
This candidate was verified but is NOT publishable:
  - installer unsigned (no 'Developer ID Installer' identity in the keychain)
  - not notarized (no 'jrbar-notary' notarytool keychain profile ...)
```

rather than a failure. The moment the certificate or the profile appears those
phases run on their own, with no edit to the script. Only a run in which
*nothing* was skipped prints

```text
Authoritative JR-Bar macOS release gate passed.
```

and writes `dist/release-verification.json`. That manifest is fail-closed:
`scripts/release_evidence.py` refuses to build one unless every receipt kind
is present, passed, and bound to the same candidate — which is what makes
"skipped" and "published" mutually exclusive.

What the receipts cover:

| Receipt | Claim |
| --- | --- |
| `source-gate` | `./scripts/verify.sh` passed on this exact source |
| `performance` | measured warm launch, menu p95, idle CPU inside budget |
| `app-signature` | `codesign --verify --deep --strict`, and `jrbar-core.app` and `jrbar-hook` are each sealed and signed by the same team |
| `app-gatekeeper` | `spctl` accepts the app (needs the notarization ticket) |
| `bundle-closure` | every Mach-O links only Apple system libraries or code inside the bundle |
| `entitlements` | the shipped entitlements are the reviewed ones |
| `sparkle-nested-signing` | the embedded Sparkle framework and its XPC services are signed by this team |
| `pkg-signature`, `pkg-gatekeeper` | the installer is signed and accepted (needs Developer ID Installer) |
| `notarization`, `stapling`, `app-notarization`, `app-stapling` | Apple's ticket, its log, and a validated staple |
| `package-contents` | the PKG payload is the candidate and nothing else |
| `update-archive` | the Sparkle ZIP unpacks to exactly the candidate app |
| `signed-appcast` | the feed and channel metadata verify against the public key and name this candidate |
| `hardware-smoke` | a reversible LED write on a real device, restored byte-for-byte |
| `installed-upgrade`, `settings-preservation` | an older install upgraded in place and kept every existing setting |
| `clean-install` | the installed tree hashes equal to the candidate, and the *installed* daemon's `doctor` and `hooks doctor` pass with every provider hook pointing at the shim inside that bundle |
| `uninstall` | the supported uninstaller removed only JR-Bar's own state |
| `sbom` | a CycloneDX SBOM covering every published artifact |

Environment knobs:

| Variable | Effect |
| --- | --- |
| `JRBAR_PERFORMANCE_EVIDENCE` | path to measured JSON; the performance receipt is skipped without it |
| `JRBAR_REQUIRED_HARDWARE` | `software` (default), `any`, `pro`, `dot`, `both`; anything but `software` also needs `JRBAR_HARDWARE_CONFIRM=1` |
| `JRBAR_INSTALL_SCOPE` | `home` (default: `~/Applications`, no password) or `system` (`/Applications`, `sudo`) |
| `JRBAR_RUN_UNINSTALL=1` | authorize removing and reinstalling JR-Bar; the supported uninstaller is root-only, so this needs `JRBAR_INSTALL_SCOPE=system` |
| `JRBAR_RELEASE_CHANNEL` | `stable` or `beta` |
| `JRBAR_SPARKLE_HISTORY_DIR` | retained previous `appcast.xml` and archives |
| `APP_SIGN_IDENTITY`, `INSTALLER_SIGN_IDENTITY`, `NOTARY_PROFILE`, `SPARKLE_KEY_ACCOUNT` | override discovery |

The gate installs into `~/Applications` by default. The product archive
enables the `currentUserHome` domain precisely so the install needs no
administrator password and no `sudo` prompt can stall the run. Use
`JRBAR_INSTALL_SCOPE=system` when you want to exercise the `/Applications`
path and the root-only uninstaller.

It quits a running JR-Bar for the install phase and relaunches it afterwards.
That is deliberate: a running app rewrites its own settings as devices and
sessions come and go, so a field that moved on its own could not be told apart
from an installer that damaged it — and replacing a bundle underneath a live
process is not what an upgrade looks like. `--skip-install` leaves the installed
app alone entirely.

## 3. Check it by hand

```sh
osascript -e 'tell application "JR-Bar" to quit'   # the app stops its daemon
make clean-install           # installs the PKG into ~/Applications and launches it
ps -o pid,ppid,rss,command -p "$(pgrep -x JR-Bar)"; pgrep -lP "$(pgrep -x JR-Bar)"
CORE=~/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core
"$CORE" hooks doctor
"$CORE" doctor
```

The app must be supervising `Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core core`,
every provider's hook must run `Contents/Helpers/jrbar-hook` *from the
installed bundle*, the panel must show live sessions, the Screen Bar must show
the daemon's program (the status menu's Lights line says `core`), and the
login item must be registered:

```sh
log show --last 5m --predicate 'process == "JR-Bar"' | grep "login item"
```

## 4. Publish

Releases live at `https://github.com/JonathanRReed/JR-Bar/releases`. The feed
URL baked into every app is fixed:

```text
https://github.com/JonathanRReed/JR-Bar/releases/download/updates/appcast.xml
```

So the feed is an asset of one durable release tagged `updates`, and each
version's archive is an asset of its own `v<version>` release — the appcast
enclosure points at
`https://github.com/JonathanRReed/JR-Bar/releases/download/v<version>/JR-Bar-<version>.zip`.

```sh
./scripts/publish_release.sh
```

That script is the supported path and it does the ordering correctly:

1. Refuses a dirty tree, a branch that is not `main`, a local `main` that is
   not exactly `origin/main`, an existing `v<version>` tag, and an existing
   release.
2. Runs `scripts/verify_macos_release.sh`. Without
   `dist/release-verification.json` there is nothing to publish.
3. Writes `dist/SHA256SUMS` bound to the evidence manifest.
4. Creates `v<version>` **as a draft**, uploads the PKG, the ZIP, the wheel,
   the sdist, the environment snapshot, the performance evidence, the SBOM,
   the manifest and the checksums, and only then flips the draft off. If any
   upload fails, the draft release and its tag are deleted.
5. Confirms the archive is actually published under the exact name the
   appcast enclosure uses.
6. Uploads `jr-bar-update-channel.json` first and `appcast.xml` last to the
   `updates` release. Metadata before pointer means a half-finished upload
   never advertises an archive that is not there yet.

Then install the PKG on a Mac running the previous version and confirm
Sparkle offers the update (Settings › General › Software Update).

Do not edit a published `appcast.xml` by hand: it carries an Ed25519 signature
over its bytes (`sign_update --verify`) and the app rejects a feed that does
not verify.

## Version bump checklist

`scripts/validate_release_version.py` is the single source of truth and both
the packager and the publisher call it. Before building a release, bump:

- `pyproject.toml` → `version`
- `src/jrbar/__init__.py` → `__version__`
- `CHANGELOG.md` → a `## <version>` heading

## What is still missing on this Mac

As of 2026-09-10, `./scripts/verify_macos_release.sh --preflight` reports:

- **no Developer ID Installer identity** — the PKG is unsigned, so
  `pkg-signature` and `pkg-gatekeeper` are skipped.
- **no `jrbar-notary` keychain profile** — nothing is notarized or stapled,
  and `spctl` would reject the app as "Unnotarized Developer ID".
- **no measured performance evidence** — set `JRBAR_PERFORMANCE_EVIDENCE`.

The Developer ID Application identity and the Sparkle signing key are both
present. Until the other three are, the gate verifies but does not certify,
and `publish_release.sh` cannot ship anything.
