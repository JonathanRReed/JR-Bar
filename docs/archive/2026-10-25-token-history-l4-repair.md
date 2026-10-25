# Token history repair, round 2

Started from `1b1801b7` in the clean `t3/9f7d834d` worktree. This round
supersedes the earlier repair's implementation and measurements. The old
receipt remains in git history and the first benchmark artifact.

Cold CPU does not pass a strict 15-second maximum. The five final loaded
runs have a 13.145-second median, range 12.774 to 18.113.
Two exceed 15 seconds. The other measured targets pass. Nothing here proves
the installed 24-hour daemon budget or the actual 42 GB corpus.

## Changes

- Schema v7 rebuilds once and reclaims the old schema's allocated pages.
  Provider, session and model strings are interned. One facts table stores
  16-byte keys, integer file IDs, UTC quarter-hour buckets and token counts.
  Only duplicate records have extra copy rows. Codex lineage uses integer
  owners and 16-byte event digests. The events copy and its hour index are
  gone. Changed records add and subtract bucket totals. Timezone changes
  write nothing.
- Cold and full rebuilds run in an owned Utility child process. It commits
  offsets about every 50,000 records, reports cumulative progress and exits.
  Large single files resume after interruption. Off and quit stop the child
  and close the persistent writer. Frozen helpers can use their pipe file
  descriptors when Python standard streams are absent. The bundled entry
  point already supports `-m` and collects all JR-Bar modules.
- The daemon keeps its default QoS and a 6 MiB writer cache. Incremental
  passes use at most 50 ms of thread CPU before finishing the current small
  chunk. They retain committed reconciliation progress. SQLite temporary
  tables use disk. The disposable builder has a 64 MiB cache, released on
  exit. File metadata stays in memory. Recent files are checked every scan,
  older files every ten minutes, and directory changes discover new files.
- Lineage queries force the changed-key set outside the facts table.
  Parent links become dirty only when their value changes. One recursive
  query resolves a batch, including cycles and missing ancestors. Buckets
  wait for pending lineage before counting inherited copies. Removed own
  events also retract their lineage. Parser changes avoid repeated model
  normalization and numeric conversions and preserve the HMAC keys.
- Failures publish `failed`, `disk_full`, `damaged` or `over_cap` separately
  from `building`. One damaged database and its sidecars are retained.
  Over-cap files are not quarantined. Disk-full failures back off an hour.
  The protocol and Swift decoding tests cover these states. UI rendering of
  the new failure strings is not verified in this lane.
- N11 skips each malformed or non-object quota line and continues in the
  same file. N12 dates staleness from the last reading, including a busy
  card fallback. A short scan does not mark current data stale. N13 retires
  each provider's old caches when that provider completes. The headless
  controller cannot run its legacy transcript writer, and its graph command
  explicitly refuses legacy native capture.

## Measurements

The [receipt](2026-10-25-token-history-l4-round2-benchmark.jsonl) retains five
runs through `scan_provider_pass`, with two-second passes and the daemon's
half-second pause. A 5 ms ticker ran on the main thread while four separate
CPU burners ran. Each run used a fresh measurement process and database.
Other work on this Mac also competed for CPU. Profile runs are excluded.

The corpus contains 860,000 records, including 100 forks of a 1,000-event
Codex parent. Message and Codex thread IDs are 36-character UUIDs. Models
are `claude-sonnet-4-5` and `gpt-6.1-sol`. Transcripts occupy 230,605,223 bytes.
It has 760,000 canonical records and 121,540,000 processed tokens. A separate
isolated corpus matches every public 365-day history document field against
the legacy record pipeline.

- Cold child CPU, summed across both provider children: median 13.145 s,
  range 12.774 to 18.113 s. The strict 15 s maximum remains open.
- Cold wall time: median 15.350 s, range 14.286 to 133.909 s. Daemon CPU
  during the build: median 0.185 s, range 0.167 to 1.283 s.
- Database: median 94.781 MiB, range 94.730 to 94.840 MiB. It passes
  the 150 MiB limit and remains above the approximate 50 MiB aim.
- Active Codex: median 0.036244 CPU-s per simulated minute over 25 samples,
  range 0.030181 to 0.048251. Each sample completes six budgeted scans and
  sixty appended events. Every append verifies the new total and zero
  inherited resolutions. The limit is 0.1 CPU-s/min.
- Worst main-thread lateness: 22.661 ms. No tick exceeded 50, 100 or 250 ms.
- Peak measurement-daemon RSS: 44.359 MiB. Maximum increase during the cold
  build: 14.891 MiB, below the 40 MiB limit. Peak child RSS: 180.828 MiB.
  Its memory is separate and released on exit.
- Idle: 1,800 scans across five runs. Each hour's 360 scans commits zero
  SQLite changes, with unchanged `data_version` and exact database/WAL
  hashes. CPU per simulated idle hour: median 2.436 s, range 2.305 to 2.585 s.
  Physical filesystem traffic was not measured.

Reproduce with:

```sh
PYTHONPATH=$PWD/src /Users/jonathanreed/Downloads/JR-Bar/.venv/bin/python scripts/benchmark-token-history-scale.py --records 860000 --runs 5 --burners 4 --golden
```

Generation and the legacy golden comparison run outside the measured
processes. Child CPU covers indexing and close, excluding Python imports.
Cold wall time includes process startup. The measurement daemon and each
child report separate RSS and CPU. Both provider-home environment variables
are pinned to the synthetic fixture.
The harness checks row counts, token totals, completed appends and errors.
A 10,000-record run also exercises the final command with `--golden`.

## Verification

- Full Python suite in the foreground: **8,033 passed**, 15 subtests passed,
  four existing multiprocessing fork warnings. Runtime: 748.53 s.
- `scripts/verify_fast.py`: passed, including lint, imports, contracts,
  focused tests, documentation links and diff hygiene.
- Index and process regressions: 46 passed. The six tests covering the full
  suite's initial failures pass. The process entry point is registered in
  the reachability manifest. Legacy-cache corruption checks run before
  per-provider retirement; their assertions remain intact.
- `swift build`: passed. `swift test --filter
  'TokenHistory|ReplyDecodingOffMainTests'`: 10 tests passed in two suites.
  No full Swift suite or rendered UI checks were run.
- Full-corpus golden comparison: every public 365-day document field
  matches, including prices, models, record counts, days and hours.

Runtime commits:

- `978e536b`: usage: rebuild compact token history in a Utility child
- `effd2d1b`: usage: keep daemon scans at default QoS and block legacy writers
- `449f2636`: usage: avoid repeated token and model conversions

The final documentation commit contains this handoff, the benchmark command
and the source-pinned receipt.

L5 must preserve Track policy when selecting provider inputs. The history
failure states remain independent of quota freshness. No changelog,
What's New, installation, provider configuration, release or remote changes
are included. Installed rendering, packaged helper execution, Swift 6.3.3
CI, actual 42 GB I/O and a 24-hour installed run remain unproved.
