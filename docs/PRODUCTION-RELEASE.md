# Releasing JR-Bar

One command builds the product; the rest is checking what it printed and
uploading three files. The old multi-receipt release gate
(`scripts/verify_macos_release.sh`, `scripts/publish_release.sh`,
`scripts/release_evidence.py`) predates the Swift app and is not part of
this flow; it is kept only until its tests are retired.

## Build

```sh
make fast            # lint, contract tests (the builder runs against doubles), version contract
make package         # packaging/build_macos_pkg.sh
```

`make package` prepares the pinned Sparkle distribution, builds the Swift
app against it, the compiled hook shim and the frozen daemon, assembles and
signs `build/macos-pkg/app/JR-Bar.app` inside out, verifies it, and writes:

```text
dist/JR-Bar-<version>.pkg        installer (system or home-directory domain)
dist/JR-Bar-<version>.zip        Sparkle update archive of the same bundle
dist/appcast.xml                 signed feed (only with the Sparkle key in the keychain)
dist/jr-bar-update-channel.json  what the feed binds: version, build, download URL, signature, hashes
dist/release-environment.txt     pip freeze of the frozen daemon's environment
```

The summary at the end says exactly what happened:

```text
JR-Bar 0.8.0 (<commit>)
  JR-Bar-0.8.0.pkg: ... (20M)
  JR-Bar-0.8.0.zip: ... (20M)
  signed:     developer-id (Developer ID Application: Jonathan Reed (AJ9VWBRNZN))
  installer:  unsigned
  notarized:  not notarized
```

`packaging/README.md` lists what each line depends on. In short:

- **Signing** happens with whatever the keychain has, best first: Developer
  ID Application (hardened runtime, timestamp), then `Nautilus Local Dev`,
  then ad-hoc. Only a Developer ID build is distributable.
- **Notarization** runs when the `jrbar-notary` keychain profile exists
  (`xcrun notarytool store-credentials jrbar-notary --apple-id … --team-id
  AJ9VWBRNZN`) and the build is Developer ID signed. The app is notarized
  and stapled before the ZIP and PKG are cut, so both carry the ticket. A
  PKG is notarized only when it is also signed, which needs a `Developer ID
  Installer` certificate in the keychain. Without notarization the summary
  says `not notarized`; Gatekeeper on another Mac will refuse the app until
  it is.
- **The feed** is signed when the private half of
  `packaging/sparkle_public_ed_key.txt` is in the login keychain (accounts
  tried: `SPARKLE_KEY_ACCOUNT`, `ed25519`, `io.jrbar.app`,
  `com.jonathanreed.jrbar`). On this Mac that is the login keychain item
  "Private key for signing Sparkle updates", account
  `com.jonathanreed.jrbar`, generated 2026-09-10 with Sparkle 2.9.6's
  `generate_keys --account com.jonathanreed.jrbar`; its public half is
  `HOglzj7oHy/NF0HMxpSkOzP036QpoaD+6YzwAGr5iIg=`. (The older `ed25519`
  account holds an unrelated key from July; nothing trusts it.) Back the
  private key up with `generate_keys --account com.jonathanreed.jrbar -x
  <file>`: losing it means every installed app stops trusting the feed.
  Otherwise there is no `appcast.xml`, and installed apps will not see the
  release. The public key is baked into every app as `SUPublicEDKey`;
  changing keys means changing it in `packaging/sparkle_public_ed_key.txt`,
  `scripts/generate_sparkle_channel.py`, `src/jrbar/sparkle_updater.py` and
  the tests (`tests/test_sparkle_channel.py` also pins its SHA-256
  fingerprint) before the first release that uses it.
- **The in-app updater** is `app/Sources/JRBarApp/SparkleUpdater.swift`
  over the embedded framework: "Check for Updates…" in the app menu,
  automatic checks off until Settings › General turns them on, the
  `stable` / `beta` channel from the same page (`beta` allows
  `<sparkle:channel>beta</sparkle:channel>` items, which
  `JRBAR_RELEASE_CHANNEL=beta make package` produces). The Swift build links
  the framework from the distribution the packaging script prepares first
  (`JRBAR_SPARKLE_FRAMEWORK_DIR`; `app/README.md`).

Retaining earlier releases in the feed: put the currently published
`appcast.xml` and every `JR-Bar-*.zip` it references in a directory and set
`JRBAR_SPARKLE_HISTORY_DIR` to it; the builder verifies them with the key
before signing the replacement feed. `JRBAR_RELEASE_CHANNEL=beta` makes a
beta entry (no phased rollout); stable entries roll out over one day.

## Check it on this Mac

```sh
osascript -e 'tell application "JR-Bar" to quit'   # if it is running: the app stops its daemon
make clean-install           # installs the PKG into ~/Applications (no password) and launches it
ps -o pid,ppid,rss,command -p "$(pgrep -x JR-Bar)"; pgrep -lP "$(pgrep -x JR-Bar)"
~/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core hooks doctor
~/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core doctor   # commit, memory
```

The app must be supervising `Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core core`,
every provider's hook must run `Contents/Helpers/jrbar-hook`, the panel must
show live sessions and the Screen Bar the daemon's program (the status
menu's Lights line says `core`), and the login item must be registered
(`log show --last 5m --predicate 'process == "JR-Bar"' | grep "login item"`).

## Publish

Releases live at `https://github.com/JonathanRReed/JR-Bar/releases`. The
app's feed URL is fixed:
`https://github.com/JonathanRReed/JR-Bar/releases/download/updates/appcast.xml`,
so the feed is an asset of one durable release tagged `updates`, and each
version's archive is an asset of its own `v<version>` release (the appcast
enclosure URL is
`https://github.com/JonathanRReed/JR-Bar/releases/download/v<version>/JR-Bar-<version>.zip`).

1. Commit and push the version bump (`pyproject.toml`,
   `src/jrbar/__init__.py`, the `## <version>` heading in `CHANGELOG.md`).
2. `make package` from that commit (the summary must say `developer-id`,
   `notarized: yes` and a signed appcast for a public release).
3. The version release: `gh release create v<version> dist/JR-Bar-<version>.pkg
   dist/JR-Bar-<version>.zip --title "JR-Bar <version>" --notes-file <notes>`.
   Upload the ZIP under exactly the name the appcast enclosure uses.
4. The feed, only after the version release is public: `gh release upload
   updates dist/jr-bar-update-channel.json dist/appcast.xml --clobber`
   (create the `updates` release once, as a plain release with no tag
   semantics: `gh release create updates --title "Update feed" --notes
   "Sparkle appcast; do not delete."`). Uploading the metadata first and the
   appcast last means a half-finished upload never advertises an archive
   that is not there yet.
5. Install the PKG on a Mac that has the previous version and confirm
   Sparkle offers the update (Settings › General › Software Update).

Do not edit a published `appcast.xml` by hand: it carries an Ed25519
signature over its bytes (`sign_update --verify`) and the app rejects a feed
that does not verify.
