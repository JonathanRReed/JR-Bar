# Contributing to JR-Bar

JR-Bar is a personal project that happens to be public. Issues and pull
requests are welcome; there is no process beyond the checks below and a
clear description of what changed and why. Keep in mind what the software
touches: it edits other tools' hook configuration, reads private local
state, drives visible light, asks for macOS permissions, and ships as a
signed installer. Changes are reviewed with that in mind.

## Setup

An Apple silicon Mac on macOS 26 or newer, the Command Line Tools (Swift
6.2+, clang) and Python 3.12.

```sh
./scripts/bootstrap-dev.sh          # .venv with the pinned tools
make fast                           # lint, imports, contract and focused tests
.venv/bin/python -m pytest tests    # the full Python suite, about five minutes
cd app && swift build && swift test # the Swift package
make package                        # the bundle, PKG and Sparkle archive (signs with what the keychain has)
```

The same three checks run in CI on every push
([.github/workflows/tests.yml](.github/workflows/tests.yml)). Packaging,
hardware, permissions and notarization only happen on a real Mac.

Running the app from a checkout, against a checkout's daemon or the mock
daemon, is in [app/README.md](app/README.md). Install the result on your
own Mac with `make clean-install`; `docs/PLAN-0.8.md` has the definition of
done the owner uses (the Mac runs the commit you just made).

## Where things live

- `app/` is the Swift app. It owns every pixel and asks the daemon for
  every fact. Anything it decides on its own is listed at the end of
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- `src/jrbar/` is the daemon. New behaviour lands as a protocol document
  or command in [docs/CORE-PROTOCOL.md](docs/CORE-PROTOCOL.md) first; the
  app never reads the daemon's files behind its back. Additive fields are
  free; `v` bumps only for incompatible changes.
- `hook/` is the shim. It must never block a provider for more than 250 ms
  or lose a payload it could queue.
- `packaging/` builds and signs the bundle. Every external tool sits behind
  an overridable seam so `tests/test_app_bundle_security.py` can run the
  whole script with doubles.

## Rules that have earned their place

1. Provider and system adapters emit typed facts; policy modules do no I/O;
   the daemon's main thread does no blocking work during a refresh.
2. Bursty sources use bounded latest-wins or explicitly ordered queues.
3. Every LEDS program, first-party or user-authored, passes the
   presentation compiler and the firmware parser before a strip or the
   Screen Bar sees it.
4. New settings fields need encoder, decoder, migration and schema-coverage
   tests, and a `SettingsKey` in the app if the app is to show them.
5. Tests use synthetic data. No real prompts, transcripts, tokens, account
   identifiers, private project names or personal paths in tests or
   fixtures. `make fast` scans tracked files for secrets.
6. Dependencies are pinned (`requirements/release-constraints.txt`,
   hash-locked for the frozen daemon) and GitHub Actions are pinned to
   commits. Dependency bumps are their own change.
7. Logs and UI copy carry product-owned reason codes, never server bodies,
   credentials, hostnames or user content.

## The SidePulse name

0.8 renamed everything. The `sidepulse` command, the `sidepulse.*` import
shim and the `SIDEPULSE_*` environment fallbacks exist for this one release
so installs re-point themselves, and are deleted in the next. Do not add
to them, and do not add new dual names.

## Pull requests

Describe the change, what it does when the thing it talks to is missing or
wrong (a provider is signed out, a strip is ejected, the daemon is down),
and how you checked it. Screenshots for anything visible. Keep one change
per pull request. Security and privacy reports go to the address in
[SECURITY.md](SECURITY.md), not to an issue.
