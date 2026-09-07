# Final testing from main

The September 7, 2026 integration consolidates the existing branch histories and
finishes the supported Control Center source work. Use `main`, not one of the
historical feature, production, or fix branches. The resolutions are recorded in
[the branch ledger](BRANCH-CONSOLIDATION-2026-09-07.md).

This is a candidate for final testing. Native macOS, physical device, live account,
and signed installed-release acceptance still require evidence from the owner's
Mac. Source-level success is not a release certificate.

## One command

Commit or stash local changes before switching branches. From the repository:

```sh
git fetch origin
git switch main
git pull --ff-only
make final-test
```

Python 3.12 must be installed and available to `scripts/bootstrap-dev.sh`.
The existing bootstrap accepts Homebrew's usual Python 3.12 paths or an explicit
base interpreter, for example `PYTHON=python3.12 make final-test`. It creates the
pinned `.venv`; final verification then uses that environment. It does not try to
bootstrap using a nonexistent virtual environment. An existing `.venv` of another
Python version is refused rather than silently replaced; set `SIDEPULSE_DEV_VENV`
to a new directory to preserve it.

`make final-test` runs the fast source gate, the full Mac pytest suite, wheel/sdist
builds, Twine checks, clean-venv installation, release-version/dependency/secret
checks and SBOM generation using the existing verification scripts. It does not
sign or publish a release, install a PKG, flash firmware, or exercise a real board.
The package build replaces the generated `build/` and `dist/` directories.
Inherited `PYTEST_ADDOPTS` filters are cleared so they cannot turn final acceptance
into an unnoticed partial run.

Results stay in the ignored, private `.jrbar-verification/` directory, separated
by timestamp and commit. Each run records the source SHA/worktree state, macOS
version, installed dependency versions, command log and exit code. The full test
suite writes `tests.xml` when it reaches pytest. An earlier gate failure will not
produce a full-suite XML file. Nothing is uploaded automatically.

For a correctly bootstrapped environment, `./scripts/final-test.sh --no-bootstrap`
reuses it. `--allow-dirty` is available only for explicitly non-candidate debugging.
A successful final candidate must start and end at the same clean source revision.
Never use `git reset --hard` to discard personal changes merely to satisfy this gate.

## Source changes in this integration

- Fix coalesced persistence when the newest state equals the previously written
  state while a different save is in progress. Pending saves drain on close.
- Persist compact-rail edge selection in the versioned board store; older saved
  boards migrate to rail-off. The saved edge is restored when Control Center is
  next opened. Display identity is not persisted and the rail does not independently
  launch before Control Center has been opened.
- Revoke queued actions and pending Shortcuts before a bank/pin/slot context change.
  Bind virtual-input confirmation to the connection generation, board revision and
  current mapping settings. Refuse input during termination; reap killed children.
- Refuse a new keymap apply while an interrupted-write recovery is outstanding.
  A verified original keymap can close that recovery without another device write.
- Repair the obsolete repository-name test and the portable test environment for
  injected battery subprocesses. Native menu/controller checks explicitly require
  AppKit instead of failing import on Linux; the Mac suite still runs them.
- Include Creator Micro and final-readiness regressions in both fast and portable
  gates. Preserve the older plan and reconcile all recorded historical branch tips.

## Verification already performed

Targeted portable execution used Linux, Python 3.13.5 and pytest 9.0.2, not the
release's pinned Mac environment. Across 65 selected test files, 644 checks passed
and three native AppKit checks were skipped. The new concurrency, stale-action,
recovery, child-reaping and fresh-checkout entrypoint regressions were observed
failing before their corresponding fixes. Python compilation and shell syntax
checks were also performed. These results do not substitute for `make final-test`
on the target Mac or prove behavior under every supported Python runtime.

## Device acceptance

Start without accessories and open **Control Center...** from the JR-Bar menu.
Check session state, stable slots and explicit banks. Change **Compact rail** to
each edge; close/reopen Control Center and restart the app to verify saved choice.
Check external displays, scaling, Dock placement, full-screen Spaces, keyboard
navigation, VoiceOver, reduced motion and contrast.

Before remapping the Creator Micro, close Input and any other device writer and
use **Export original keymap...**. Inspect the exact selected profile/layer and
unbound macros. Apply only the previewed configuration. Storage verification does
not prove the firmware has activated it; reconnect if required by the firmware.

Keep **Input check: pause device actions** on while exercising every key, encoder
and supported joystick input. Verify aggregate and per-session lighting, navigation,
bank changes, duplicate suppression, USB/Bluetooth identity, quiet-device shutdown,
sleep/wake and reconnect. Retest SidePulse Pro/Dot independently. Unsupported
firmware/control shapes must stay refused, not be overridden as a workaround.

Test restore and interrupted-transfer recovery on a scratch/test setup before
relying on it for a valuable device configuration. A pending recovery must be
resolved through Restore, not repeated Apply. Unrelated later edits must not be
silently overwritten. Restore the original firmware map before uninstalling JR-Bar.

## Provider and release acceptance

For each enabled provider, test a fresh observation, absent executable, unsupported
schema, offline/stale state, expired credentials, account switch and disabled
integration. Prove no account/source identities merge. Verify every exposed
navigation action reaches the intended session. No universal approval or interrupt
channel is assumed for externally owned sessions. T3 remains read-only; CodexBar
and Input are reference applications, not required runtime dependencies.

Use [PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md) only after source and device checks
pass for the actual candidate. Signing/notarization, package receipt installation,
updater upgrade/downgrade, uninstall and Instruments evidence remain separate.
No release tag, installer signing, account mutation or firmware update is part of
this consolidation.

## Intentional scope boundaries

The supported product is the standalone monitor and capability-scoped hardware
control center, including verified keymap transfers and supported auxiliary
mappings. It is not a generic editor for every Input smart action/macro or a
firmware flashing/service utility. Provider observation does not grant execution
authority. Those unsupported functions remain explicit rather than being presented
as features that only need testing. Details are in [CONTROL-CENTER.md](CONTROL-CENTER.md).
