# Late HID import loads AppKit

Build 3302's HID extension loads AppKit when imported. The native workspace
fallback fixed in the [earlier report](../2026-10-26-packaged-daemon/REPORT.md)
was a separate loader.

The installed daemon is PID 41786, build 3302, commit `3d9fd1ff`, launched
at 07:09:39 CDT on October 26. Read-only `vmmap -v` inspection confirms
loaded AppKit segments. The first retained install snapshot, at 07:09:48,
already contains them. The retained core log reports readiness at
07:09:40. The exact historical load instant was not captured.

## Culprit and reproduction

`coreLaunchDeferred_` starts the deck probe. Its worker calls
`deck_probe`, then `HidApiTransport.enumerate`, then
`creator_micro_hidapi.HidApiTransport._module`, which imports `hid`.
`hid_affinity._bind` also imports that extension. The packaged
`hid.cpython-312-darwin.so` directly links AppKit. Its only AppKit symbol
is `NSAppKitVersionNumber`, used by HIDAPI's `hid_init` to test whether
macOS is at least 10.10. Dyld loads AppKit when importing the extension,
before an explicit device operation is needed.

The installed frozen interpreter reproduced this in a temporary HOME,
with temporary XDG directories and its own core socket. The expanded probe
ran each adapter in sequence. Every step before HID stayed free of AppKit;
the HID import loaded it. A separate fresh-process import reproduced the
same transition. No HID device was opened or written.

The expanded probe driver and its image-reader helper were supplied as
source to the old frozen interpreter. Its old doctor was supplemented
with the new read-only image field inside that disposable process only.
The native adapters and HID extension under test remained the installed
frozen versions. The live daemon was never instrumented or changed.

## Framework checks

`otool -L` on the installed HID extension names AppKit directly. System
framework files live in the dyld shared cache on this Mac, so filesystem
`otool` checks for those paths failed. `xcrun dyld_info -dependents` supplied
their dependency lists instead. Scanning all 734 loaded text images found
only the HID extension with an AppKit dependency, apart from AppKit itself.
SecurityInterface also depends on AppKit, but was an unused cache mapping,
not a loaded image in this daemon.

The checked adapters were:

- `native_applications`: ApplicationServices and its LaunchServices and
  HIServices exports, including frontmost-app and URL lookups.
- `native_events` and `native_displays`: CoreGraphics and CoreFoundation.
- `native_process_info`: Foundation and Intents, including Focus status.
- `native_eventkit`: EventKit, store creation, authorization reads and
  synthetic event and reminder objects. Private calendar queries were faked.
- `native_sound`: AudioToolbox. Playback was blocked or faked.
- `native_run_loop`, `native_workspace` and `native_blocks`: CoreFoundation,
  IOKit, Foundation notifications and process-local completion callbacks.
- `native_apple_http`: Foundation and NSURLSession. Task resume was faked,
  so no request or DNS lookup was sent.
- `keychain_read`: Security bindings only, without opening a Keychain,
  reading an item or changing interaction policy.

Carbon, HIToolbox, CoreServices, LaunchServices, ApplicationServices,
Quartz, EventKit, IOBluetooth, CoreWLAN, DiskArbitration and the Security
framework candidates were included in the dependency inspection. None of
the exercised native adapters loaded AppKit before the HID import.

## Fix

Commit `d2d36e82` rebuilds the existing hash-locked
`hidapi==0.14.0.post4` source archive. It replaces the version-number
comparison with Clang's macOS availability check at the same 10.10
threshold and removes the AppKit linker flag. It keeps the generated
Python binding, device operations and nonexclusive-open policy. No
runtime dependency version changes and no Cython build dependency is added.
The rebuilt extension links IOKit, CoreFoundation and libSystem only.

The packaged runtime receipt is now schema 2. It requires all twelve native
steps, their actual Python imports, successful completion and clean image
inventories after each step. Physical discovery stays disabled. Input
posting, sound, launches, permission requests and HTTP are blocked or faked.
A missing step, failed step, missing import or forbidden image rejects the
build. A regression proves that a late HID image is rejected even if a
later receipt claims a clean final inventory.

The documented `doctor.appkit_loaded` field reads dyld's image list in the
daemon. It returns true, false or null when unavailable. It never loads
AppKit or exposes image paths. The packaged gate requires false.

## Verification

The final frozen helper passed all twelve steps without AppKit, WebKit,
WebKitLegacy or PyObjC images or GUI Python imports. Doctor reported
`appkit_loaded=false`. Embedded-source verification matched all 374 JR-Bar
modules and the entry script. The expanded probe rejects installed build
3302 at the HID step.

The final helper SHA-256 is
`d68a0e99b349acd28929cb05f6ca17c93a871233663c31dab7ae7f439c35b4e6`.
The installed helper SHA-256 is
`596ce64caaefd7146cafdcb19ce64907693c1c4d7ee7773d6d675903ba9f72b7`.
Source hashes, image inventories, dependency scans, the rebuilt wheel's
source and builder hashes, and command logs remain in
`/tmp/jrbar-late-appkit-6ec682bb`. The helper is in that directory's
`final-frozen/jrbar-core.app`.

- Focused packaging, probe and doctor checks passed 72 tests.
- The fast gate passed.
- `cd app && swift build --build-tests` passed.
- `cd app && swift test` passed 6,069 tests across four executables.
- The full Python suite passed 15,883 tests and 15 subtests. It reported
  four existing multiprocessing fork deprecation warnings.

The full Python command is
`PYTHONPATH=$PWD/src /Users/jonathanreed/Downloads/JR-Bar/.venv/bin/python -m pytest -q`.
The fast gate used that interpreter with `scripts/verify_fast.py` because
this worktree has no local `.venv`.

This is local frozen-helper proof. A signed whole-app package, installation,
hardware behavior and a new soak were not qualified. The installed daemon
still has its original PID and launch time. Nothing was installed,
restarted, pushed or published. No script wrote to either LED volume,
agent configuration, Dock preferences or menu-bar preferences.
