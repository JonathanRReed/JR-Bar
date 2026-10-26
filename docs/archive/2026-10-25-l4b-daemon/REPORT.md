# L4b daemon efficiency

The final synthetic workload meets the CPU, RSS and traffic budgets, and
no sampled loop delay exceeded 250 ms. The baseline is
`299988d6`. Runtime code ends at `b7cec932`; the reproducible tool ends at
`b467952c`. Timed probes freeze their own script, whose hashes are recorded.
The final child-exit check was verified separately. Nothing was installed,
pushed or released. JRBarUI and the panel, Settings, notch and Usage Center
views were untouched.

## Measurements

Both runs used the production CLI, three live dummy processes registered
as synthetic Claude sessions, two temporary LED volumes, a temporary home,
30 seconds of warm-up and 600 measured seconds. Both accepted all 372 hook
submissions. The fixture sends prompt, tool, tool-result and stop events
every five seconds. It exercises the real collector, process registry,
projection, socket, firmware validation and LED writer.

- CPU, one core at 100%: **2.225% before, 0.742% after**.
- Current RSS, mean/peak: **65.1/139.2 MiB before, 68.2/100.8 MiB after**.
  The mean did not fall in these shared-host runs; both the mean and peak
  after are below the 150 MB budget. macOS memory compression makes RSS
  different from physical footprint.
- State traffic: **514,890 before, 30,195 bytes/minute after**, a **17.1x**
  reduction. State messages fell from 31.4 to 20.5 per minute.
- Lights traffic: 86,741 before, 50,252 bytes/minute after. All wire traffic
  fell from about 607 KB to 84 KB per minute.
- Main-loop probe: **32.4 ms before, 10.0 ms after**, with no sampled
  round-trip above 250 ms. There were 575 and 581 samples respectively.
  These are sampled queue delays, not a formal bound on every callback.
- Separate 60-second allocation-tracing runs: **49.1 MiB before,
  43.3 MiB after** retained traced allocations. Tracing starts before imports
  with one frame. This excludes native engine allocations and is not a
  total-Python-heap measurement. Traced CPU/RSS do not qualify the budgets.
- Process-table forks: **30 `ps` launches before, zero after**. The ten
  remaining `touch` launches write only the fake volumes' keepalive files.

The final source hash matches the committed Python sources. The packaged
firmware hash is identical before and after. See [source hashes](source-hashes.json),
[baseline](before.json), [final run](after.json), and the
[before](before-heap.json) and [after](after-heap.json) tracing receipts.

## Import time

`python -X importtime` reported these cumulative import times:

- `jrbar.cli_entry`: 363.7 ms before, 131.9 ms after.
- `jrbar.core_runtime`: 606.0 ms before, 328.9 ms after.
- Before: `objc` 133.7 ms, `AppKit` 77.9 ms, and the JavaScriptCore Python
  wrapper 9.5 ms. None of these Python modules loaded after.

The loader image inventory also found AppKit and WebKit before and neither
after. The firmware still runs through JavaScriptCore's C API. Import times
are individual cold-source observations on a shared host, not a repeated
startup benchmark. [Raw times](import-times.json),
[before log](before-importtime.log), [after log](after-importtime.log).

## What changed

- The controller moved to `daemon_controller.py` as a plain Python class.
  `daemon_loop.py` owns serial callbacks and timers. Narrow native adapters
  cover process information, Focus, display reads, EventKit fallbacks,
  LaunchServices, keyboard delivery, sound and HTTP. Apple HTTP keeps its
  native TLS stack, ephemeral sessions and same-origin redirect rule.
- The native app reports workspace events and accessibility preferences
  over its authenticated socket. Unavailable accessibility readings fail
  conservatively. No new window or status item was added.
- libproc replaces process-table and process-start `ps` calls. Directory
  kqueue watches catch settings-file replacement; a 30-second safety poll
  recovers missed notifications.
- Connections opt into generation-stamped state slices after a full
  snapshot. Session edits and object patches send changed fields. Each
  connection owns its baseline, including across a delayed greeting.
  LED write health travels with lights. Older clients still receive full
  states, and the app still accepts full states from older daemons.
- `CoreModel` applies each validated batch to its existing storage and
  changes only the relevant observable slices. Its stored state name stays
  compatible with the app's unobserved snapshot reader.
- Hook publications share a 40 ms window. Urgency survives the batch;
  acknowledgements and commands remain immediate. Linked-curve fitting
  reuses exact samples. All 28 frozen rotations are byte-identical, and
  firmware parity tests pass. The isolated fitting microbenchmark improved
  from 9.42 to 1.17 CPU seconds per 140 rotations, median of five alternating
  runs. [Micro receipt](curve-fit-micro.json).
- History warming covers graph preferences and the roster, rather than
  every provider. Fresh scan results are reused. Other providers still
  scan on demand, and disabling history stops the maintenance loop.

The first passing CPU run was 0.837%; its confirmation was 1.170%, so it
did not establish reliable CPU headroom. Job and thread CPU counts identified
additional background history work. After that change the 180-second
check measured 0.955%, followed by the final 600-second result of 0.742%.
These earlier results remain in [first pass](after-first.json),
[confirmation](after-before-history-selection.json), [short check](after-short.json),
[job census](cpu-census.json) and [thread census](thread-census.json).
Nested job timings overlap and must not be summed.

## Verification

- Full foreground Python suite: **15,760 passed**, 15 subtests passed,
  four existing multiprocessing fork warnings.
- Full Swift suite with `JRBAR_INTERACTIVE_TESTS` unset and explicit
  `--no-parallel`: **5,956 tests reported passed** across all four targets.
  Default parallel runs repeatedly hit shared-suite timeouts; the complete
  serial run and isolated provider-list tests passed. No UI test assertions
  were weakened to make the run pass.
- Fast gate: Ruff, contracts, dependency policy, fixtures, focused tests,
  source compilation, tracked-secret scan, version and diff hygiene passed.
- Native/controller smoke: 133 passed. History/index regression checks:
  45 passed. Linked fitting and firmware checks: 79 passed.

Commands and counts are in [validation.json](validation.json).

## Reproduce

Use the pinned project interpreter. Each destination must be new. The
[tool](../../../scripts/daemon-performance-probe.py) freezes `src` and its
own script before starting the child.

```sh
PYTHONPATH=$PWD/src /path/to/JR-Bar/.venv/bin/python \
  scripts/daemon-performance-probe.py /tmp/jrbar-after --seconds 600

baseline_src=$(mktemp -d /tmp/jrbar-before-src.XXXXXX)
git archive 299988d6 src | tar -x -C "$baseline_src"
/path/to/JR-Bar/.venv/bin/python scripts/daemon-performance-probe.py \
  /tmp/jrbar-before --seconds 600 --source "$baseline_src/src"
```

`--sessions` accepts 3 through 6. `--trace` is a separate allocation run.
`--census` records job/thread CPU. `--profile` uses Yappi in a separate
diagnostic run; Yappi 1.7.6 was installed only in a temporary environment,
not added to the project dependencies.

## Limits and deferred work

This qualifies one synthetic workload, not the installed 24-hour release
budget. The installed build's reported 473 MB footprint and 266 MB heap
were not reproduced by this fixture. App RSS, growth over 24 hours, real
provider transcripts, remote quota reads, signed-helper permission prompts,
physical LED timing and packaging remain separate checks.

The fixture rejects non-Unix Python socket connections and blocks external
Keychain, power-assertion and desktop-automation commands. HID discovery is
disabled. Read-only OS power, Focus and process queries remain real.
Provider consent starts off in the temporary home. Fixed accessibility
preferences and fake volumes keep both sides comparable. Real keep-awake
assertions are not created; blocked command attempts are counted in each
receipt.

No persistent Codex app-server was added. This workload launched Codex zero
times, so it provides no measured benefit to justify another persistent
process. Profiling the consented real Codex path remains deferred.

The implementation's [commit sequence](commits.json) records each code and
measurement step. The final documentation commit contains these receipts.
