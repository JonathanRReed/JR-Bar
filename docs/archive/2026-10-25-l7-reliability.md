# L7 reliability and latency, 2026-10-25

Started from `59acbc0a`, the 0.10.0 plan commit. No installed app,
provider configuration, LED volume, Dock preference or MenuBar preference
was changed. No push or release was made. The full Swift suite was not run.

## Disk writes

The Oct 21 diagnostic records 2,147.63 MB dirtied in 27,160 seconds,
about 284.7 MB/hour. It names `os_write`, but no destination file.
`fs_usage -w -f filesys <pid>` refused with `'fs_usage' must be run as root...`.
No sudo attempt was made. These facts cannot establish which file caused
that historical total.

Read-only file stats on Oct 25 found a 608,291-byte `latest.json`, a
351,796-byte percent history, a 5,119,294-byte scan JSON cache, and larger
SQLite caches. Those sizes are observations, not write-rate measurements.

The [write-call inventory](2026-10-25-l7-evidence/write-paths.tsv) records
file writers and mutating SQL statements found in the Python source. It
includes low-level writers and command-only paths. It is a static inventory,
not a trace proving every listed writer ran in the live daemon.

| Files or family | Trigger and existing limit | L7 action |
| --- | --- | --- |
| `latest.json` | Changed canonical state; 30-second ordinary flush, one-second transition floor, trailing flush, digest deduplication, forced shutdown save | Already throttled at the starting commit. Kept its recovery contract. |
| `usage-percent-history.jsonl` | One-percent change or 30-minute observation heartbeat per lane | Append retained new rows. Compact expiry every 30 minutes; apply policy changes immediately. Unchanged retention no longer rewrites the file. |
| `usage-samples.json` | Dirty forecast samples, at most once per minute | Existing batching retained. |
| `provider-usage.json` | Completed provider refresh | Snapshot-sized rewrite. Left provider ownership with L3. |
| `provider-reset-events.json` | Candidate, delivery or app-receipt change | Coalesced on the serial writer. Added dirty revisions, bounded retries and visible failure status. |
| Provider `*.jsonl`, pending, rejected and dedupe files | Incoming hooks; append once per accepted event, dedupe at ingress | Existing ingress and byte/line caps retained. No synthetic live ingress. |
| `activity-ledger.json`, operator/capacity/effect history | Semantic activity or history changes; capacity history has a 60-second flush floor | Existing deduplication and batching retained. |
| `usage-scan-cache*.json`, file-index SQLite, transcript caches, graph-document cache | Changed corpus or requested graph cache entry | Large rewrite candidates reported for L4. No token-history changes in this lane. |
| `session-surfaces.json`, deck slots, triage, dismissals, clear-agent records | Relevant session mapping or person action; deck saves coalesce identical payloads | Retained existing change detection. |
| Settings, seals, credential health, integration choices, consent, pairing, import ledgers, effect/scene packs, firmware cache, clock calibration, keep-awake leases | Explicit command, permission/credential result, setup, or feature-state transition | Command-driven or small bounded files. No polling rewrite added. |
| Remote ledger and usage-sync packet/cache files | Opt-in publication or peer refresh | Existing opt-in gates retained. |
| Stdout/stderr, crash and stack logs | Log emission, launch/crash, or explicitly requested stack diagnostics | Routine LED success and linked-write timing now use Python debug logging. Errors remain visible. |
| `LEDS.LED`, `INIT.LED`, firmware files and HID reports | Admitted changed hardware program or explicit hardware command | Reviewed `device_writer` atomic/in-place/fsync paths. Programs are capped at 512 bytes. No real device writes were measured or performed. |
| Exports, backups, provider installation files, helper/plist setup | Explicit export/install/update operation | Not recurring refresh writes. No real provider install was run. |

### Synthetic byte measurement

[The script](../../scripts/measure_percent_history_writes.py) uses temporary
files and synthetic identities. It seeds 2,400 rows, then appends 240 valid
rows at injected 15-second observation intervals. Each side preserves all
2,640 expected rows and reports zero failures.

| Source | Bytes written per synthetic hour | Successful writes | Runs |
| --- | ---: | ---: | ---: |
| Starting commit | 80,997,615 | 240 | 5 |
| L7 append path | 32,130 | 240 | 5 |

Five alternating before/after pairs returned the same byte count on each side. That is a 99.9603%
reduction for this workload. Raw results are retained
[before](2026-10-25-l7-evidence/percent-history-before.json) and
[after](2026-10-25-l7-evidence/percent-history-after.json).

The counter wraps successful `os.write` calls during appends. It excludes
seed writes, APFS metadata, dirty-page accounting, unrelated daemon writes
and device traffic. The removed cost is copying the retained file for each
sample. This is not a daemon-wide disk or latency benchmark. The revised
script also ran against an extracted copy of the starting commit and
reproduced the baseline. Expiry batching has a separate injected-clock test.

## Behavior repaired

- Full refills can be consumed before confirmation. The traces
  95 → 100 → 99, 80 → 100 → 97 and 50 → 100 → 97 now confirm, as does
  80 → 99 → 97. Existing account/source, rolling-window and reverted-boundary
  defenses still pass. A full refill must remain near full and above its
  old reading; it need not remain at its peak.
- `CoreModel.readEvents` reports retained-tail overflow. Usage Center
  reconciles history and current provider rows once on a gap, with no old
  decorative pulses. Reopening reconciles before resuming event feedback.
  Panel, History, Overview and Replay consumers use sequence progress.
- Confetti detects held-fact capacity loss and queries bounded `reset_status`
  pages when it has room again. It also reconciles after reconnect. The
  daemon remains the pending-reset authority. Off does not start this query.
- A refused or failed reset save stays dirty. Retries wait 1, 5 and 30 seconds
  after failures, then stop with the failure retained. New state or explicit
  Retry starts another attempt set. Completion returns to the owner loop;
  an old revision cannot clear a newer one. A persistence deadline can
  replace a later delivery timer, including after the final delivery ends.
- `reset_status` returns at most 16 pending resets, original timestamps and
  canonical IDs, remaining count, and save state. Usage Center shows a save
  failure and Retry. A receipt acknowledgment distinguishes memory/queue
  acceptance from durable completion.
- Fold compiles outside its cache lock. Busy callers return “preparing”.
  One readiness callback per toy wakes reconciliation; failed compilation
  retains the existing cooldown. Tests block compilation behind a barrier,
  read the cache on the main actor, release it, then verify the cached result.
- Standalone `--allow-answers` requires the daemon's existing sealed
  `serve_answer_enabled` consent. Stream Deck setup exposes that opt-in with
  an explicit confirmation. It defaults off. Answering still requires a
  person's key press and the existing request/ownership checks.
- Asks interrupt ordinary notch notices, including timer and meeting notices.
  Ask banners observe state and have one deadline instead of polling every
  50 ms. Hook, liveness and transcript lifecycle/ask edges bypass the
  250 ms refresh floor; ordinary chatter keeps its trailing refresh.
- The Screen Bar holds the first paint's destination color while its
  keyframe plan is pending. The existing strip-transfer playback path stays
  separate. Tests cover the color helper and an injected plan-queue barrier.
- One-shot layout diagnostics report hosting view type, proposed frame or
  bounds, and SwiftUI proposal/result size. Reports are capped at 64 distinct
  type/phase pairs. Subtraction sites in Dock zoom and shelf row sizing now
  clamp at zero. No supplied backtrace identifies the historical offending
  inner view, so these guards are not proof those faults are fixed.
- Signpost intervals cover synchronous Settings, Studio and panel opening
  and Screen Bar wake handling under `devin.jrbar`, Points of Interest.
  They measure handler work, not time to the first visible pixel.

No info-level display-change success logger was found in the reviewed
current daemon paths. The app's display watcher offers a notice without
logging a routine success. Its user-facing announcement behavior was kept.

## Verification

The final test commands use the main checkout's Python with this worktree's
`src` on `PYTHONPATH`. Swift commands run from `app`. The fast gate uses
`scripts/verify_fast.py`, the same entry point as `make fast`.

- Final Python focused run: 418 passed. It includes refill adversaries,
  expiry batching, reset retries/status, consent, real controller methods
  with fake schedulers, and the deterministic timing contract.
- Python fast gate passed. Ruff and `git diff --check` passed.
- Fresh `swift build --build-tests` passed.
- Selected Swift suites passed 43 core tests and 69 app tests. The suites
  were checked for window presentation. Fold uses offscreen Metal draws;
  Confetti replaces overlay presentation with counters. The full suite
  was not run.
- The new render fixture uses ImageRenderer and creates no window. Light
  and dark PNGs were opened and inspected. An initial substring filter also
  ran the existing Setup reliability render fixtures; their generated PNGs
  were inspected too. The final render run selects only the new test method.

The source and fixtures do not prove the Oct 21 destination file, a 24-hour
installed disk budget, the cause of the Oct 22 AppKit faults, cold/warm
first-pixel latency, a real Stream Deck key, or live provider answer delivery.
No such claim is made.

## Commits

- `fb4f1ca7` history: append percent samples without rewriting retained rows
- `094e08a7` usage: confirm full refills after consumption resumes
- `35be25f8` resets: retain dirty receipts and retry failed saves
- `c4c4ad4c` runtime: refresh lifecycle edges immediately and quiet write successes
- `0378a360` history: batch expiry compaction between percent samples
- `d6890d30` serve: require answering consent before exposing answer routes
- `0bf586aa` runtime: refresh transcript lifecycle edges immediately
- `f946b260` fold: compile shaders outside the cache lock
- `00dfc477` events: recover queue gaps and expose reset save failures
- `a59be45b` asks: interrupt notch news and observe banner readiness
- `ab90b111` screen-bar: show state color while keyframes prepare
- `26e7b24a` layout: report invalid sizes and signpost window opening
- `6b1c0b09` serve: keep consent controls and endpoint readable
- `5b0d571a` test: cover L7 latency and render recovery states

The following evidence commit retains this report, the write inventory and
the byte-measurement script/results. `git log 59acbc0a..HEAD` lists the
complete lane, including that commit.

## Merge notes

L7 touches narrow methods in `core_runtime.py`, `_status_bar_production.py`,
`status_bar_legacy.py`, `provider_usage_status_bar.py`, `CoreModel.swift`,
`ScreenBarController.swift` and the window controllers. Other lanes may
have changes in those files. Preserve both sides when integrating.

L3 owns provider persistence and Keychain work. L4 owns the multi-megabyte
token scan and graph caches. This lane changes percent history, not token
history. No lights-engine, ambient-cue or agent-group behavior was changed.

The release owner can report these bullets in the changelog: lower percent
history writes; refills survive resumed use; event-gap recovery; visible,
retryable reset saves; explicit endpoint answering consent; asks appear
promptly; Fold startup avoids the cache lock; layout and open/wake diagnostics.


## Verification follow-up

Started this repair from `d7b814f2` on `t3/3354892a`, with a clean tree.
All eleven verification findings are addressed in this worktree. This
section supersedes the earlier Screen Bar destination-hold behavior and
reopen reconciliation described above.

1. Added the event-refresh and reset-persistence names to the controller
   attribute registry, including the computed retry-deadline exception.
   Updated the hook-refresh and reset-receipt contract expectations.
2. The second-ask Fold test awaits its own cache and injects that cache
   into the renderer. Parallel shared-cache warming cannot change its result.
3. An ask parks the interrupted notice if it is fresh and outranks the
   waiting notice. Otherwise it reports eviction for fallback delivery.
   The original age is preserved. Tests resolve the ask, call `finish`,
   and check notice resumption, expiry and eviction.
4. The Screen Bar samples the running program while its keyframes prepare.
   Both paths keep the same anchor. The test compares a green-to-red fade
   with sampler and keyframe values around a simulated 300 ms compile delay,
   within the keyframe renderer's existing three-code interpolation tolerance.
5. Standalone serve warns when answering is unavailable and keeps serving
   status. Each answering request reads fresh consent. The scripts-and-status
   page documents this behavior. Authentication and answer refusals remain.
6. Usage Center retains the close cursor even when observations run while
   closed. Reopening reloads all ranges and reset status only after a gap;
   otherwise it force-reloads the current range. Closed gap observations
   defer recovery until reopen.
7. Urgent refreshes have a 50 ms floor. An injected-clock test sends twenty
   starts and verifies one trailing refresh at the floor, preserving the
   urgent request instead of waiting for ordinary chatter coalescing.
8. Percent-history appends inspect one trailing byte and prefix a newline
   after a torn row. Tests cover both append paths without rewriting history.
9. Fold caches compile failures through the retry cooldown, including builds
   with no readiness waiter. The next overlay attempt observes the failure,
   and overlay creation honors the toy's cooldown. Tests cover failure,
   repeated requests and a retry after the injected clock advances.
10. Layout diagnostics evaluate the reflected type name only after detecting
    an invalid size. A counter proves healthy sizes do not evaluate it.
11. Overview requires a selected session before scheduling a timeline refresh.
    Panel replay IDs are deduplicated. Delivered reset receipts supersede
    dropped receipts in either arrival order and survive persistence.

Fresh checks:

- Full Python suite, using this worktree's `src` on `PYTHONPATH` and the main
  checkout's interpreter: **8005 passed, 15 subtests passed, 4 warnings**.
  Command arguments were `-m pytest tests -q`. Exit status was zero.
- Selected Swift run: **34 core tests and 49 app tests passed**, all eight
  permitted suites. The filter was
  `EventGapTests|AlcoveEventsTests|ReliabilityLatencyTests|UsageCenterStoreTests|ResetSaveStatusTests|FoldRendererTests|FoldShaderCacheTests|ConfettiDaemonEventsTests`.
- Ten consecutive `swift test --skip-build --filter 'FoldRendererTests|FoldShaderCacheTests'`
  runs passed. Each ran 13 tests, including `aSecondAskCompilesNothing`,
  alongside shared-cache renderer warming. All ten exited zero.
- Repository-wide Ruff passed for `src tests packaging scripts`. Doc links
  and `git diff --check` passed.

Swift ran locally with Apple Swift 6.4. The full Swift suite was not run.
The selected suites present no windows; the new Screen Bar test leaves its
panel hidden, and Fold renders offscreen. No installed app, real LED device
or provider answer was exercised. The phase test proves sampled color
agreement, not measured synchronization with physical LEDs. Swift 6.3.3 CI,
first-pixel latency, the historical write destination and the 24-hour budgets
remain unproved. Nothing was pushed or released.

Follow-up code and test commits:

- `20747461` runtime: declare L7 controller state and update test contracts
- `0213a103` runtime: coalesce urgent refresh bursts within fifty milliseconds
- `3ceab43b` serve: keep status available while answering is unavailable
- `fc8591a5` history: separate torn percent samples before appending
- `24a0cbfa` resets: let delivery win over racing dropped receipts
- `a19d5d7f` history: keep percent history imports ordered
- `596b00e8` fold: isolate and await the cache used by the second ask test
- `43e7b507` fold: retain overlay compile failures through the retry cooldown
- `5031f404` screen-bar: keep the live fallback at the hardware program phase
- `160cd89a` layout: reflect hosting view types only for invalid sizes
- `5cf6b727` events: skip empty timeline refreshes and deduplicate panel replays
- `dd98fa9d` asks: resume fresh notices after an ask interrupts them
- `2a08b779` usage: reconcile closed-window gaps without reloading every range on open
