# Final testing for 0.8

0.8 is a Swift menu-bar app over a Python daemon. Both halves have to pass, and
the parts that matter most -- a real agent CLI, a real device, a real account --
cannot be proved by either test suite. This is the order to run them in, what
each one actually covers, and what is left over for the owner's own eyes.

Everything here runs on the owner's Mac from a clean `main`. Source-level
success is not a release certificate; [PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md)
is the separate gate for signing, notarization and publishing.

## The five gates

```sh
make fast                                          # 1. seconds
.venv/bin/python -m pytest -q -p no:cacheprovider tests   # 2. ~6 minutes
cd app && swift test && cd ..                      # 3. ~2 minutes
make package                                       # 4. ~4 minutes
.venv/bin/python scripts/verify_providers_live.py --asks   # 5. ~4 minutes
```

Nothing is skipped because it is slow. Gate 5 needs the packaged app installed
and running, so it comes after gate 4 and after the install below.

### 1. `make fast`

Ruff over `src tests packaging scripts` plus the contract tests that answer in
seconds: the deterministic-timing contract (no wall-clock sleeps or unbounded
joins in tests), the packaging and release-gate contracts, the provider fixture
and settings-schema coverage checks, the Creator Micro wire conformance. It is
the gate to run before every commit; the full suite is the gate before a push.

### 2. The full Python suite

`.venv/bin/python -m pytest -q -p no:cacheprovider tests`. `-p no:cacheprovider`
keeps the run from writing into the checkout. Clear any inherited
`PYTEST_ADDOPTS` first -- a filter turns final acceptance into an unnoticed
partial run. Python 3.12 or newer; `scripts/bootstrap-dev.sh` (via `make
bootstrap`) builds the pinned `.venv` and refuses an existing one of another
version rather than replacing it.

### 3. `swift test`

From `app/`. Protocol codec over fixture frames, the settings document, panel
layout, the LEDS parity and keyframe suites, supervisor restart and backoff, and
the mock-daemon integration tests that round-trip every command the app sends.
`app/scripts/mock-core.py` is the daemon stand-in; `swift test` never needs a
running JR-Bar. On a CLT-only machine see `app/README.md` for the swift-testing
macro plugin note.

### 4. `make package`

`packaging/build_macos_pkg.sh`: builds the Swift app in release, embeds the
Python daemon and the compiled hook shim, signs with the Developer ID identity,
verifies the bundle, entitlements and the Sparkle framework, and writes
`dist/JR-Bar-0.8.0.pkg`, the zip, and a signed appcast. It does not notarize.

Never run two at once -- `pgrep -f build_macos_pkg` before starting.

To put the build live, so the daemon under test is the one just built:

```sh
kill -TERM "$(pgrep -f 'JR-Bar.app/Contents/MacOS/JR-Bar')"
while pgrep -f 'jrbar-core core' >/dev/null; do sleep 1; done
installer -pkg dist/JR-Bar-0.8.0.pkg -target CurrentUserHomeDirectory
open ~/Applications/JR-Bar.app
```

`doctor` over the socket reports the commit the daemon is running; check it says
what you just built before trusting gate 5.

### 5. `scripts/verify_providers_live.py`

The only gate that runs real agents. It starts `scripts/mock_llm_server.py` -- a
stdlib-only OpenAI/Anthropic/Gemini endpoint that always answers the same way,
one shell tool call then "done" -- builds a scratch home per provider so the
owner's own configs are never touched, runs one turn, and asserts what the
daemon recorded in `~/.local/state/jrbar/<provider>.jsonl` and in `state`:

    session_start > user_prompt_submit > pre_tool_use > post_tool_use > stop > session_end

Then, for Codex, the same turn interrupted mid-tool with SIGINT
(`… > pre_tool_use > interrupt > session_end`), and `usage_history codex 7d`
answering with records and non-zero tokens.

`--asks` adds the approval drills: an interactive Codex under `-a on-request`
and an interactive Claude Code, each in a pty, each made to ask by the mock, and
`answer_ask` sent for the ask that appears in `state.asks`.

Flags: `--only codex pi claude gemini usage` restricts the run, `--keep` leaves
the scratch directory, `--shim` points at a different hook shim. It refuses to
start if a mock server is already running. Exit 0 when nothing failed.

What it will not prove: Gemini CLI is skipped because it refuses a local
endpoint ("Invalid auth method selected"), so its hooks are unexercised here.
`answer_ask` reaches `unsupported` on every provider -- the ask is seen and
listed, but no in-place answer handler is registered in the daemon, so nothing
can be approved from JR-Bar yet. Both are recorded as what they are, not as
passes.

## What no gate covers

These need the owner, the hardware and the accounts.

**Device.** Open **Control Center...** with no accessories, then with each.
Session state, stable slots, explicit banks, the compact rail on each edge,
saved across a restart. External displays, scaling, Dock placement, full-screen
Spaces, keyboard navigation, VoiceOver, reduced motion, increased contrast.
Before remapping a Creator Micro, close Input and every other device writer and
use **Export original keymap...**; apply only the previewed configuration;
storage is not activation, so reconnect if the firmware asks. Keep **Input
check: pause device actions** on while exercising every key, encoder and
joystick input. Test restore and interrupted-transfer recovery on a scratch
device configuration before trusting it with a real one, and restore the
original map before uninstalling.

**Providers.** For each enabled provider: a fresh observation, the executable
absent, an unsupported schema, offline and stale state, expired credentials, an
account switch, the integration disabled. No two accounts or sources may merge.
Every navigation action must reach the session it names.

**The app in use.** The menu bar at each width, the panel, the Usage window
against a cold and a warm scan, History, Effect Studio, Settings. Sleep, wake,
display changes, log out and back in.

**Release.** Signing, notarization, receipt installation, updater upgrade and
downgrade, uninstall. [PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md).

## Scope boundaries

The supported product is the monitor and the capability-scoped hardware control
center, including verified keymap transfers and supported auxiliary mappings. It
is not a general editor for every Input smart action, and not a firmware service
utility. Observing a provider grants no authority to act for it. T3 Code and
Alcove are the only external application integrations; CodexBar is an
engineering reference that is never launched, queried or required at runtime.
