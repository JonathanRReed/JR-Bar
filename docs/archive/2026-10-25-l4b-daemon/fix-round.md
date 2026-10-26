# L4b fix round, 2026-10-26

Resumed at `11da0b81` after the merge of `work/next-release`. Runtime and
regression-test changes finish at `70c38837`. The remaining production fix
was one missing `_core_environment_fallback: None` controller declaration.
The full Python run caught it through the existing attribute contract.
The focused contract and environment rerun passed all 10 tests after the fix.

The pending prior-art credit was checked against the pinned Apple sources
and committed. The [credit](../../PRIOR-ART.md#process-launch-identity-2026-10-26)
names both source commits and licences. No upstream code was copied.

The four requested checks are covered as follows.

- Process identity preserves the saved launch path separately from libproc's
  resolved executable. Both the reviewer's native fixture and the repository
  test select the `claude` symlink parent rather than its Node child. Both
  readers keep the parent's record alive after the child exits. libproc adds
  subsecond start times and a separate resolved path; provider matching uses
  the launch basename. Zombies are omitted, whereas `ps` can show a defunct
  row. `EPERM` or `EACCES` retains an unknown PID with no name or start time,
  so a denied read cannot prove death or supply a provider match. If only
  the argument query is denied, matching falls back to the resolved path or
  kernel name, as available. It cannot recover a launch alias the OS hides.
  Start-time checks reject recycled PIDs.
- Every state delta names its previous transmitted generation. Python tests
  cover skipped and reordered publications and independent greeting baselines.
  Swift tests reject the entire mismatched batch and preserve the prior facts.
  Two real socket cases prove the app reconnects and receives a full state.
  The adapted reviewer probe applies 10,000 stamped updates with one roster
  observer registration and zero unrelated callbacks. A later roster update
  fires it once. A skipped object patch leaves generation 2 rejected and not
  live. The [protocol](../../CORE-PROTOCOL.md#subscribe) describes recovery.
- An old client or no app keeps native observations after the two-second
  grace. A successful accessibility report stops them; disconnection restores
  them. Tests cover both cases, an early capable reporter, real native
  accessibility reads, repeated local sleep/wake notifications, LED reassert
  clock reset, and observer teardown. These tests post notifications only
  inside the test process. They do not sleep the Mac or write physical LEDs.
- A separate 60-second tracing run captures allocations at each newly sampled
  RSS peak. Its final peak is 232.2 MiB at 14.8 measured seconds, with 22.1 MiB
  of tracer bookkeeping. Maximum retained traced allocations are 43.8 MiB.
  The largest allocation line is imported code at 14.1 MiB, followed by
  dataclass-generated code at 4.5 MiB. The largest JR-Bar source line is
  animation sample tuples in `dot_continue.py`, at 1.8 MiB. No safe, small
  removal of the imported-code allocation was identified. No additional RSS
  optimization is claimed. Tracing omits native allocation attribution and
  changes the process being measured; its RSS does not qualify the budget.
  See [peak receipt](fix-peak.json). It replaces the local interpreter path
  with `<python>`. The binary snapshot remains at
  `/tmp/jrb-l4b-peak-final/peak-tracemalloc.snapshot`.

The fresh untraced runs use baseline `299988d6` and current source `70c38837`,
respectively. Each has 30 warm-up seconds and 600 measured seconds, three
live dummy processes, a temporary home and fake LED volumes. Both accept
all 372 hooks, observe all three sessions, and report no workload errors.
The frozen probe hash is the same on both sides. The current source hash
matches both the after receipt and the final tracing receipt.

- CPU, one core at 100%: 1.545% before, 0.887% after.
- RSS mean/peak: 105.6/155.0 MiB before, 96.1/113.5 MiB after.
- State traffic: 512,370 bytes/minute before, 30,695 after, counting full
  states and deltas together.
- Maximum sampled main-loop queue delay: 16.2 ms before, 4.0 ms after.
  Neither run has a sample over 250 ms, from 577 and 581 samples.

The after run is inside the synthetic CPU, RSS, traffic and sampled-delay
budgets. This is one sequential pair on a shared host, with verification
jobs running. The one-minute load average ranged from about 5 to 63 on
14 logical CPUs. It does not establish repeatable CPU or RSS improvement,
or the installed application's 24-hour budget. Sampled queue delays are
not a bound on every callback. The original report's installed-product,
provider, packaging and physical-device limits still apply.

The after run loads no PyObjC framework wrappers. With no capable app,
the compatibility fallback loads AppKit through its C ABI; that image
remains resident. The original report's AppKit-free image inventory is
historical. A capable app reporting during the startup grace avoids this
fallback, as the regression test verifies.

See the complete [before](fix-before.json), [after](fix-after.json), and
[validation](fix-validation.json) receipts. The original report's reproduce
commands still apply. Supply the baseline's `revision.txt` beside an
archived `src` directory so the probe records its actual source revision.
Use `--seconds 60 --trace` separately for allocation attribution.

The final foreground Python run passed 15,769 tests and 15 subtests in
1,212.76 seconds, with four existing multiprocessing fork warnings.
Serial Swift verification passed 6,023 tests across four targets with
`JRBAR_INTERACTIVE_TESTS` unset. The fast gate passed after the controller
declaration fix. Doc links, receipt consistency, tracked-secret scanning
and diff hygiene passed after writing these files. The validation receipt
lists all ten fix-round commits before this documentation commit.
No app was installed and no change was pushed or released.
