# Packaged daemon AppKit load, 2026-10-26

The AppKit loader was the native workspace compatibility fallback, restored
in the [L4b fix round](../2026-10-25-l4b-daemon/fix-round.md). Its constructor
explicitly called `ctypes.CDLL` on AppKit, then created `NSWorkspace`.
`EnvironmentFallback.tick` starts it after a two-second grace when no
capable app has reported, or after the reporting connection disappears.
Closing that observer later does not unload AppKit. The original
[source-tree report](../2026-10-25-l4b-daemon/REPORT.md) predates that change.

## Evidence

The installed app is build 3301, commit
`98ba9d0e72e9e3cf9ad8787ecff9575c4cc5e018`. Read-only inspection found daemon
PID 75458, parent 75434, started at 05:28:53 CDT. `vmmap`, `vmmap --summary`,
`lsof -p` and a one-second `sample` captured its images. AppKit has actual
loaded segments and appears in Binary Images. No PyObjC bridge or WebKit
image was loaded. An unused shared-cache WebKit page does not count as an
image.

`otool -L` shows no direct AppKit dependency in either the frozen launcher
or embedded Python. The launcher links Carbon and ApplicationServices;
Python links CoreFoundation and SystemConfiguration. A probe run through
the installed binary's `-m pdb` entry starts without AppKit. Constructing
its frozen `NativeWorkspace` loads AppKit, and a traced `ctypes.CDLL` call
names `jrbar/native_workspace.py:27`. Both snapshots have no `objc`,
`AppKit` or `WebKit` Python modules. The bundle contains Cocoa/PyObjC
wrappers but no `.pth` files. Those wrappers were not the active loader.

A second probe runs the real frozen CLI's `core --socket <temporary-path>`
in a temporary home, with hardware discovery and external effects disabled.
It reproduces AppKit with the fallback active. This confirms the loader
and its reachable production path. The live process was not instrumented
at its historical startup, so the particular late report or reconnect
that first triggered its fallback was not observed.

## Fix

Commit `3bccf2c4` replaces the AppKit fallback with IOKit sleep/wake
notifications, CoreGraphics display/session readings and Foundation clock
notifications. Sleep requests are acknowledged immediately, including when
Python delivery fails. Display, session and accessibility values refresh
once a second; the native run loop still pumps every 100 ms.

Available boolean accessibility preferences replace the previous reading.
Missing or unsupported values keep the last known flag, or conservatively
reduce effects until the app supplies an exact snapshot. This is a fallback
for old apps and standalone use. The current app continues to supply the
exact AppKit readings over the existing authenticated command. A valid
report closes the fallback; disconnection restores it.

Packaging now excludes PyObjC framework modules instead of collecting
Cocoa. Before making archives, `verify_daemon_runtime.py` starts the frozen
core in an isolated home on its own socket. It samples after startup with
the native fallback active, then rejects AppKit, WebKit, WebKitLegacy and
PyObjC images or GUI Python imports. It permits system `libobjc` and the
JavaScriptCore C API. The probe disables LED and HID discovery, external
commands, sockets outside its home and Python file writes outside its home.
A regression runs the source daemon and checks those refusals.

## RSS comparison

Five alternating trials per side used the installed frozen binary before
and the rebuilt frozen binary after. Both used the same frozen probe file,
the same `-m pdb` wrapper, fresh empty homes and temporary sockets. Each
trial records four current RSS readings from libproc at about six through
nine seconds, with its native fallback active and socket open. No tracer
or profiler ran during measurement. Every before trial loaded AppKit;
every after trial loaded no forbidden image or Python bridge.

The median of the five per-trial means was 79.46 MiB before and 76.56 MiB
after, an observed 2.91 MiB reduction. Before ranged from 73.88 to 80.08 MiB;
after ranged from 76.29 to 76.81 MiB. These ranges overlap. The RSS benefit
is inconclusive on this shared host, whose one-minute load ranged from
8.49 to 13.48 on 14 logical CPUs. RSS includes shared pages and changes
with memory pressure. No allocation-level attribution or long-running
installed-product budget was measured.

[Results](results.json) retain the trials, helper hashes and probe hash.
The after helper is an ad-hoc PyInstaller daemon bundle, built with the
packager's flags and pinned 6.21.0 environment. All 372 embedded JR-Bar
modules and the entry script match current source bytecode semantics.
The source base is `76c59a9e`; it differs from installed `98ba9d0e` only
in the package version string before this fix. It retains version 0.9.17.2;
no release version was changed for this task. This is frozen-daemon proof,
not a signed whole-app package, install, hardware or release qualification.

## Verification

- 78 focused Python checks passed, including source-daemon isolation,
  native callbacks, app reporting, package rejection and timing contracts.
- 98 adjacent packaging and embedded-source checks passed.
- The final native/import/environment rerun passed all 14 checks.
- The fast gate passed, including 187 contract, 77 fixture and 346 focused
  tests, Ruff, dependency policy, source compilation and diff hygiene.
- The final frozen runtime verifier passed and its embedded-source check
  matched all 372 modules and the entry point.
- Full serial Swift verification passed 6,061 tests across four executables,
  with interactive tests unset. The log retains compiler and linker warnings.
- Documentation links and diff hygiene passed after writing this report.

Raw inspection, loader traces, runtime inventories, build logs and test
logs remain in `/tmp/jrbar-appkit-20261026-aba515f3`. The final comparison is
in its `final-comparison` directory. The first exploratory comparison uses
an earlier probe revision and is not the reported result.

The installed app and daemon were not restarted, killed or replaced.
Nothing was installed, pushed or published. No physical LED volume was
written. Kernel sleep/wake registration ran, but tests delivered synthetic
messages only to process-local callbacks with a fake acknowledgement
function. The Mac was not put to sleep.
