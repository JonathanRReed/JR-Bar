# Token history repair verification

The repair started at `2c4bc4c2` on `t3/9f7d834d`. All changes stay in the
existing worktree. The index completed five cold builds of 860,000 synthetic
usage records without reaching its cap. The full Python suite passes.

The implementation changes these paths:

- Storage uses integer file IDs, `WITHOUT ROWID` raw and event tables,
  16-byte keys, and null Codex fields for other providers. The database cap
  is 4 GiB. Files older than 368 days are skipped. A daily pass prunes
  rows at that cutoff. Each source processes its newest files first.
  Raw timestamps remain UTC epochs.
  A timezone change rebuilds buckets without parsing transcripts.
- Canonical own events and fork dependencies have indexed tables. Changes
  resolve affected copies instead of every inherited row. Bounded passes
  use batches of 256 resolutions and 4,096 dirty keys. Saved offsets and
  pending reconciliation survive a stopped pass. SQL checks cancellation,
  including during the writer's integrity check.
- Cold event loading uses set operations. The first hour totals use one
  `GROUP BY`, and the event lookup index follows bulk loading. The unused
  day table and triggers are gone. WAL, `synchronous=NORMAL`, memory-backed
  temporary tables, and a 32 MiB writer cache replace the old settings.
  Unchanged metadata does not rewrite rows. Reopens do not fsync through
  `ensure_private_file`.
- Card reads use read-only connections and sums by day and model. They do not run
  the writer's integrity check or rebuild views of sessions and hours. Busy and
  incomplete reads use the last index reading marked stale, or show that
  history is building. Retired JSON caches never replace index readings.
  Cleanup removes those caches after Claude and Codex indexing completes.
- Corrupt caches are preserved under a damaged-file name. Recovery waits
  at least a minute. `SQLITE_FULL` publishes unavailable history and backs
  off for an hour. Size and file identity checks guard connection setup.
- Turning history off stops the index. Codex still reads bounded rollout
  tails for quota percentages, and `session_usage` still supplies context.
  Scan work uses Utility QoS and restores its caller's previous class.
  The app handles disabled replies with "Token history is off" and a
  **Turn on** button in History and Overview. Session rows also handle the
  disabled reply from older daemons.

The [protocol](../CORE-PROTOCOL.md) describes the optional
`token_history_state` field. L5 must preserve provider Track policy when
selecting index inputs and maintenance providers. No changelog, What's New
catalog, release, installation, or provider configuration changes are included.

The [scale harness](../../scripts/benchmark-token-history-scale.py) and
[measurement receipt](2026-10-25-token-history-l4-repair-benchmark.jsonl)
retain the test configuration and results. The base corpus has 759,000 Claude
records and 101,000 Codex records. One hundred forks copy a 1,000-event parent.
There are 760,000 canonical events and 121,540,000 processed tokens. Exactly
516,000 base records are older than 30 days. All are within the retention
window. Synthetic transcript payloads total 215,308,173 bytes, not 42 GB.

Measured on this Mac with 14 logical CPUs and substantial competing work:

- Cold CPU median: 37.205 seconds across five runs, range 27.256 to 39.091.
  Wall time ranges from 29.822 to 133.403 seconds. Cold main database files
  occupy about 402.3 MiB. These runs use source `a1a3c97f`.
- Active Codex CPU median: 0.581 seconds per simulated minute across five
  samples, range 0.520 to 1.435. Each sample completes six Codex-only scans and
  60 new events. Every scan verifies the new token total and zero inherited
  resolutions. Completion timing has no pass deadline. Budgeted pending
  state and resumption have separate regression tests.
- Steady idle: 360 scans across both roots change zero rows. Database and
  WAL hashes and the witness connection's `data_version` remain unchanged.
  This proves zero committed SQLite payload bytes per simulated idle hour.
  It does not count filesystem metadata or sidecar lifecycle traffic.
- The main database occupies 435,625,984 bytes, about 415.45 MiB, after the
  warm stress. Direct SQL checks confirm 860,620 raw rows and 760,620
  canonical events.

The warm and idle measurements use runtime source `66583efc`. They resume
the validated cold fixture after an optional full profile was cancelled.
A common `/var` versus `/private/var` ordering alias was settled before the
timer. Setup attempts added 320 events. The five timed samples add 300 more.
Both provider scopes settle before idle measurement. The completed 10,000-row
smoke run exercises the final harness end to end. The numbers describe absolute costs. Physical disk traffic was not measured.

Verification at `6e5470ac`:

- Full Python suite: **8,020 passed**, 15 subtests passed, four existing
  multiprocessing fork warnings. Runtime: 1,829.44 seconds.
- `scripts/verify_fast.py`: passed, including contracts, focused tests,
  documentation links, lint, imports, and diff hygiene.
- Focused history and lineage tests: 55 passed. Native QoS checks verify
  Utility during a scan and restoration afterward. Off also interrupts
  the writer's integrity check.
- `swift build`: passed. `swift test --filter TokenHistoryDisabledTests`:
  three tests passed, including disabled replies for all three commands.
  The app source is unchanged after these checks. The full Swift suite
  and rendered UI checks were not run, as requested.
- The busy-month tests verify matching totals. Cached reads take 9 ms for
  Claude and 3 ms for Codex in the final full-suite run.

The full run exposed an unrelated timing dependency in concurrent salt
publication. Commit `7b65615c` changes test coordination only. Both callers
read after publication completes, and exactly one exclusive creator must
win. The separate peer-publication-refusal test still covers retries.
Provider identity production code is unchanged.

The actual 42 GB transcript corpus, installed app rendering, Swift 6.3.3 CI,
physical filesystem writes, and installed 24-hour CPU and memory budgets
remain unproved. No actual transcript content was printed.

The implementation and test commits are:

- `32cd9ff5`: usage: compact and retain the token history index
- `a0d50b79`: usage: resolve only affected Codex fork events
- `ac138b26`: usage: recover damaged history and back off disk failures
- `3c19bd80`: usage: checkpoint history work within each scan budget
- `60354671`: usage: keep quota and context independent of token history
- `9b39f67b`: app: explain disabled token history and offer to turn it on
- `a1a3c97f`: usage: build the cold event index after loading records
- `c96eca54`: usage: restore caller QoS after token indexing
- `66583efc`: usage: keep integrity checks off cached card reads
- `7b65615c`: tests: wait for concurrent salt publication to finish
- `6e5470ac`: usage: measure completed Codex work and settled idle scans
