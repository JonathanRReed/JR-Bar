# Local Verification

JR-Bar is verified on the owner's Mac. That is not a preference: the product is
a signed menu-bar app that supervises a frozen Python daemon, writes to physical
LED hardware, and depends on macOS permissions (Automation, Notifications,
Accessibility, Focus Status) that only exist in a logged-in window session.

Every gate below says what it proves *and what it does not*. A green suite is
evidence about source; it is not evidence about an installed bundle, a signature
or a device.

Receipts from the PyObjC status bar that 0.8 replaced are archived in
[`docs/archive/2026-08-30-pyobjc-verification-receipts.md`](archive/2026-08-30-pyobjc-verification-receipts.md).

## Setup

```sh
./scripts/bootstrap-dev.sh
```

Creates `.venv` from Python 3.12 — the same minor version the release freezes —
and installs the checkout with the reviewed constraints. It refuses to replace
an existing `.venv` built on a different interpreter rather than silently
rebuilding it, and it never touches the system Python.

## The four gates

| Gate | Command | Time |
| --- | --- | --- |
| Fast | `make fast` | seconds |
| Python suite | `.venv/bin/python -m pytest tests -q` | minutes |
| Swift | `cd app && swift build && swift test` | a minute |
| Full source gate | `./scripts/verify.sh` | minutes |

`make fast` (`scripts/verify_fast.py`) is the pre-commit gate, in order: Ruff,
an import smoke, the contract tests, a tracked-secret scan, fixture validation,
the focused tests, bytecode compilation, the dependency policy, the version
contract, and diff hygiene. It stops at the first failure and preserves that
step's exit status. It deliberately contains nothing expensive or mutating — no
pip, no build, no packaging, no notarization, no publication — so it can be run
on every change. `make fast-fix` prepends Ruff's safe fixes.

`./scripts/verify.sh` is the complete source gate: Ruff, bytecode and version
validation, the whole pytest suite, wheel and sdist builds with Twine metadata
checks, a clean-wheel install into a temporary virtual environment, and console
script, compatibility module, resource and repository hygiene checks. Useful
flags: `--no-bootstrap`, `--skip-build`, `--skip-clean-install`, `--portable`.

`swift test` covers the app's own model and the protocol round trips, which
spawn `app/scripts/mock-core.py` on a socket of their own. It does not need a
built daemon.

### What a green source suite does not prove

Signing, notarization, Gatekeeper, the installer, the installed bundle's
behaviour, TCC prompts, Notification Center presentation, VoiceOver speech,
Screen Bar rendering, physical LED output, hardware timing, updater behaviour,
or release readiness. Those have their own gates below.

## Portable verification

A non-macOS machine cannot certify AppKit, TCC, signing, or hardware. It can run
the deterministic subset:

```sh
./scripts/verify.sh --portable
```

## Hosted CI is informational

`.github/workflows/tests.yml` runs `make fast`, the full pytest suite and the
Swift build and tests on `macos-latest` for every push and pull request. A
hosted runner has no logged-in window session, no Screen Recording grant, no
`bun`, and shared-tenant timing, so a set of environment-coupled tests can fail
there while the same commit passes on a real Mac. The full Python suite job is
`continue-on-error` for exactly that reason.

There is no CI release path. The self-hosted macOS workflow was retired on
2026-09-10: its runner label never existed, and the only Mac that could have
hosted it is the one holding the Developer ID key.

## The installed app

```sh
make package                 # builds dist/JR-Bar-<version>.pkg
osascript -e 'tell application "JR-Bar" to quit'
make clean-install           # installs into ~/Applications, no password, and launches it
```

Then check the shape of what is actually running:

```sh
ps -o pid,ppid,rss,command -p "$(pgrep -x JR-Bar)"
pgrep -lP "$(pgrep -x JR-Bar)"
CORE=~/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core
"$CORE" doctor
"$CORE" hooks doctor
```

`Contents/MacOS/JR-Bar` is the Swift app and takes no arguments — it opens the
menu bar. Every command line is a subcommand of the bundled daemon. `hooks
doctor` is the one that catches the most common packaging mistake: it prints the
shim each provider's hook actually runs, which must be
`~/Applications/JR-Bar.app/Contents/Helpers/jrbar-hook` and not a path inside a
developer checkout.

The app must be supervising `jrbar-core core`, the panel must show live
sessions, the Screen Bar must show the daemon's program (the status menu's
Lights line says `core`), and the login item must be registered:

```sh
log show --last 5m --predicate 'process == "JR-Bar"' | grep "login item"
```

## Hardware

```sh
.venv/bin/python scripts/verify_hardware_release.py --require any            # discovery only
.venv/bin/python scripts/verify_hardware_release.py --require any --confirm-write
```

Without `--confirm-write` the script refuses to write. With it, it backs the
device's `LEDS.LED` up, writes one bounded program, and restores the original
bytes — and if the restore fails it says so rather than leaving the device
changed. Creator Micro 2 checks are in
[CONTROL-CENTER.md](CONTROL-CENTER.md#owner-acceptance-before-a-release).

## The release gate

`scripts/verify_macos_release.sh` is the authoritative gate and the only thing
that can produce a publishable candidate. Start with:

```sh
./scripts/verify_macos_release.sh --preflight
```

It reports what this Mac can and cannot certify — the Developer ID Application
identity, the Developer ID Installer identity, the `jrbar-notary` keychain
profile, the Sparkle signing account, and measured performance evidence — and
exits 0 either way. Anything missing becomes a printed `SKIP` with the reason in
a real run, not a failure, and starts working the moment it appears.

```sh
./scripts/verify_macos_release.sh --reuse-build   # verify what is already built
./scripts/verify_macos_release.sh                 # the authoritative run
```

The authoritative run requires a clean tree at freshly fetched `origin/main`,
rebuilds, and writes one candidate-bound receipt per claim under
`dist/release-evidence/`. Only a run that skipped nothing prints

```text
Authoritative JR-Bar macOS release gate passed.
```

and writes the fail-closed `dist/release-verification.json` that
`scripts/publish_release.sh` requires. The receipt table, every environment
knob, and what is currently missing on this Mac are in
[PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md).

Performance claims are the one thing the gate cannot measure for itself: warm
launch, menu-open p95, pane-switch p95, longest main-thread task, and idle CPU
come from a 300-second Instruments session recorded against the installed
candidate and handed over as `JRBAR_PERFORMANCE_EVIDENCE`. The budgets live in
`scripts/verify_performance_budget.py`.

## Publication

Publication is a separate, explicit action:

```sh
./scripts/publish_release.sh
```

It refuses a dirty tree, a branch that is not `main`, a local `main` that is not
exactly `origin/main`, an existing tag and an existing release; runs the release
gate; creates the version release as a draft, uploads every artifact, and only
then publishes it; and updates the durable `updates` feed metadata-first,
appcast-last. It does not publish to PyPI.
