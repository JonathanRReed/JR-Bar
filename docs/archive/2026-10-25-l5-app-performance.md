L5 app performance receipt, 2026-10-25.

Started from `04bb0eb9`. Merged `t3/d9a53c5a` without conflicts as
`47d2c9d9`; `51b4783c` is an ancestor. The code snapshot for these receipts
is `25ad9778`. No daemon protocol or provider/history implementation changed.

Implementation commits, in order:

- `ba7a7f14` screen bar: precompute linked light and gradient colours
- `e1d7db32` fold: slow distant lid polling to two hertz
- `0398c187` menu bar: wake listing on events and debounce display changes
- `c189a0f5` app: refresh only when consumed core facts change
- `7f374392` app: refresh quota displays at their reset deadlines
- `39510155` tests: drain queued panel work in the state feed
- `72ce880d` app: preserve timed and local refresh inputs
- `573e09f9` screen bar: share repeated colours in keyframe tracks
- `25ad9778` tests: keep reproducible state and listing performance probes

The linked Screen Bar now samples PWM before converting to display light,
then prepares gradient values off-main in extended sRGB. Core Animation
plays the tracks at the original anchor. A plan that needs more than 900
keyframes keeps the frame clock at a maximum of 30 fps. Visibility, display
sleep and occlusion park that clock. A worker holds one current request and
the latest replacement. Repeated colours share a bounded cache in the worker.

App refreshes compare the facts their consumers read. Clock and health-only
frames leave the delegate's observation in place. One existing task carries
the remaining time inputs: ask age, provider turns, quota countdowns and
resets, snoozes, elapsed labels and the Screen Bar write grace period. Local
motion and Alcove changes still update the light-source description.

The lid reads at 2 Hz more than 20 degrees above its arming band, at 10 Hz
nearby, and at the existing 120 Hz inside the armed band. Movement mode and
failed reads retain 10 Hz. The menu listing listens to workspace and AX
activity, uses a 30-second calm fallback, and debounces display changes.
Incomplete scans and pending launch probes retain the short recovery pace.

Measured results:

- State feed, five alternating trials per strategy: median process CPU for
  10,000 decoded messages fell from 0.694 s to 0.494 s. Ranges were
  0.656 to 0.734 s and 0.473 to 0.502 s. Re-registrations and row reconstructions
  fell from 10,000 to zero. Every timed trial had zero retained malloc block
  and byte growth. Both strategies run in the same debug binary with one
  synthetic session. The fixture exercises decoding, CoreModel, PanelStore
  and the fields read by the delegate. Native controllers are outside
  this timing measurement.
- Screen Bar, five trials: 600 legacy frame updates representing ten virtual
  seconds used median 115.4 ms of main-thread CPU, range 104.8 to 127.8 ms.
  Prepared installation used median 0.243 ms, range 0.187 to 2.186 ms, followed
  by zero application frame-clock callbacks. Worker planning CPU and render
  server work are outside that main-thread installation measurement. This
  was an offscreen virtual-tick comparison, not a visible ten-second trace.
- A uniform gradient initially allocated 55 identical CGColor objects in
  the new worker. The regression test failed before pooling and now proves
  one shared object. The static linked render remained byte-identical:
  SHA-256 `179abea83c0dadb0c1c7fc4d2ac0a08b4f3bd19c43d491e21eb60b8f8cfefbd7`.
- Listing, actual old and new loop implementations driven by a virtual clock:
  117 to 22 scans over ten minutes. Steady scan cadence fell from 10 to 2 per
  minute; steady listing-wait wakeups fell from 30 to 2 per minute. This
  excludes the hider's existing 1 Hz timer and actual AX server latency.

Heap, leaks and vmmap ran against synthetic test processes. After 1,000 warm-up
messages and another 10,000 messages, the model probe retained 5 registrars
and 35 closure contexts at both checkpoints. The panel probe retained
11 registrars, 1,101 ordinary closure contexts and 602 contexts with unknown
layout at both checkpoints. Its timed live allocation delta was -8 blocks
and -8,656 bytes; profiled process CPU was 10.125 s for 10,000 offscreen layouts.
Leaks reported zero at both checkpoints in both probes. Physical footprint
was 12.3 to 12.8 MiB for the model and 24.1 to 24.6 MiB for the panel.

An initial synchronous panel loop retained two closures per layout. With
transaction commits and main-queue turns, that accumulation disappeared.
The stress loop did not model normal event delivery. The installed app's reported long-term growth remains unresolved.
The final CPU stack sample mostly caught the deliberate FIFO checkpoint;
an earlier sparse active sample of the unchanged feed path captured JSON
and CoreState decoding. No production-wide CPU percentage is inferred.

Verification:

- `env -u JRBAR_INTERACTIVE_TESTS swift build --build-tests -j 2` passed.
- Required WindowPresenter suite passed all 6 tests before the other suites.
- Focused Swift run passed 938 tests across the four targets.
- Final `env -u JRBAR_INTERACTIVE_TESTS swift test --skip-build` passed
  5,865 tests: 101 LEDS, 67 UI, 1,364 Core and 4,333 app tests.
- Screen Bar proof run passed all 7 tests with render proofs enabled. The
  generated PNG was opened and inspected.
- Relevant Python run passed 28 tests across
  `test_screen_bar_colour_matches_hardware.py`, `test_headless_screen_bar.py`,
  `test_lid_poll_idle.py`, `test_lid_presets.py` and
  `test_deterministic_timing_contract.py`.

Earlier full runs had timing-sensitive failures in login-item, presence,
Mirror-start and calendar fixtures. The login-item suite passed 5 tests in
isolation; presence/Mirror passed 17. Their failed full-run receipts remain
under `/tmp/jrbar-l5-full.log`, `/tmp/jrbar-l5-clock-full.log` and
`/tmp/jrbar-l5-release-full.log`. The final full pass is
`/tmp/jrbar-l5-accepted-full.log`. Host load varied from about 12 to 171 on
14 cores. Toolchain was Apple Swift 6.4 on arm64 macOS 27.2. CI's Swift 6.3.3
was not exercised here.

Reproduce from the worktree root after building tests:

```sh
PYTHONPATH=$PWD/src /Users/jonathanreed/Downloads/JR-Bar/.venv/bin/python scripts/app-performance-probe.py /tmp/new-state-receipt --profile
PYTHONPATH=$PWD/src /Users/jonathanreed/Downloads/JR-Bar/.venv/bin/python scripts/app-performance-probe.py /tmp/new-ui-receipt --runs 0 --render --profile
cd app
env -u JRBAR_INTERACTIVE_TESTS JRBAR_PERF_ISOLATED=1 JRBAR_RENDER_PROOF=1 JRBAR_RENDER_PROOF_DIR=/tmp/new-screen-proof swift test --skip-build --filter ScreenBarKeyframePerformanceTests
```

Each output directory must be fresh. The default state probe alternates both
strategies five times, then profiles a separate run. Profiling uses bounded
FIFO checkpoints and terminates its own test process if a tool fails.

For listing, compile [the synthetic driver](../../app/scripts/listing-performance-probe.swift)
with the loop source from `47d2c9d9`, then with the current loop source:

```sh
probe_dir=$(mktemp -d)
git show 47d2c9d9:app/Sources/JRBarApp/Utilities/MenuBar/MenuBarListingLoop.swift > "$probe_dir/before.swift"
env -u JRBAR_INTERACTIVE_TESTS swiftc -parse-as-library "$probe_dir/before.swift" app/scripts/listing-performance-probe.swift -o "$probe_dir/before"
env -u JRBAR_INTERACTIVE_TESTS "$probe_dir/before"
env -u JRBAR_INTERACTIVE_TESTS swiftc -parse-as-library app/Sources/JRBarApp/Utilities/MenuBar/MenuBarListingLoop.swift app/scripts/listing-performance-probe.swift -o "$probe_dir/after"
env -u JRBAR_INTERACTIVE_TESTS "$probe_dir/after"
```

Final raw receipts are in `/tmp/jrbar-l5-receipts-state`,
`/tmp/jrbar-l5-receipts-ui`, `/tmp/jrbar-l5-listing-probe` and
`/tmp/jrbar-l5-accepted-render`. The complete Python receipt is
`/tmp/jrbar-l5-receipts-python.log`.

For the merge: L4b should preserve the added escalation, unseen-completion and
hidden-count app slices, including disconnect clearing. L6 should account for
the new bounded gradient worker and prepared-value cache when destroying the
Screen Bar. Stopping keyframes invalidates its pending installation; active
pure planning can finish. L7 should preserve the immediate frame path and
anchor when merging its Screen Bar latency change. Panel row/group and
history implementations were left to their owners.

Physical hardware phase, live AX notification coverage and actual menu-app
wakeups remain unmeasured. The installed-product memory issue, real visible
animation CPU and the 24-hour CPU/memory budgets still need the owner's
runtime validation. These receipts do not qualify an installed release.
