# L4 token history handoff

Started at `59acbc0a`. The index and benchmark data path are pinned to
`79420269`. Later follow-ups isolate cache errors and tighten retained-byte
accounting.

Commits:

- `0b8d4a39`: bound collector transcript/log caches to 8 MiB combined and
  discard tool-result bodies after the parser classifies the event.
- `79420269`: persist deduplicated hour/day/model/session buckets for Claude,
  Codex, Pi, Grok, Gemini CLI and OpenClaw. History, Overview and provider token
  cards share the index. Retained range views have a 4 MiB byte limit.
- `f1d93c3a`: a broken history database cannot interrupt cached quota-card reads.
- `ff19d1e5`: include tuple attributes and object headers in the view byte limit.

Claude and Codex resume guarded offsets. Other adapters replace only changed
files. File identity, nanosecond modification/change times, parser versions,
source keys, timezone and OpenClaw WAL changes invalidate cached input.
Complete walks remove vanished files. Rewrites retract their old contributions.
Codex copies resolve through admitted ancestry before bucket updates. Duplicate
keys on different days preserve the old window-before-dedupe rule. Transactions
update canonical records and buckets together. A database generation invalidates
views held by another index reader.

`token_history_enabled` defaults true. It controls startup warming, minute
maintenance and History, Overview and per-session token requests. Off cancels
scan passes and clears retained token views. The off tests prove no thread,
parser, inventory or database creation starts while disabled, and that an
existing maintenance loop closes. Existing live quota collection remains separate.

The protocol adds `processed_tokens` and `estimated_cost_usd` to history buckets
and model rows, plus `processed_tokens` to `session_usage`. Context remains
`context_tokens`/`context_window`; quota percentages remain provider-window
readings. Existing token splits and compatible `cost_usd` fields stay available.
T3 Code `5b354026`, MIT, is credited in [PRIOR-ART.md](../PRIOR-ART.md).

The [benchmark script](../../scripts/benchmark-token-history.py) generates
200,000 records in a temporary home: 100 files per provider, 1,000 records per
file, Claude and Codex equally represented across 29 days. The legacy scanner
and new index feed the same history serializer. Each cold run starts with empty
caches; each warm run uses the preceding cold run's disk state in a fresh
process. Corpus generation and imports precede the CPU timer. Peak RSS includes
imports and uses a separate worker so cold allocations cannot inflate warm RSS.

Five alternating runs per side, process CPU seconds and peak RSS MiB:

- Warm legacy: median 1.430 s CPU, range 1.286–1.806; median 176.58 MiB RSS,
  range 159.84–177.78.
- Warm index: median 0.069 s CPU, range 0.068–0.109; median 38.88 MiB RSS,
  range 38.70–39.08.
- Cold legacy: median 2.614 s CPU, range 2.368–3.192; median 138.42 MiB RSS,
  range 112.88–142.13.
- Cold index: median 8.278 s CPU, range 5.910–10.918; median 41.72 MiB RSS,
  range 39.81–44.36.

Warm reads improve; cold indexing spends more CPU to build the persistent
buckets. All 20 scans returned 200,000 records, 29,000,000 processed tokens and
$179.35 estimated cost. The Mac had 14 logical CPUs and substantial competing
work, with load averages above 24 at the initial check and above 42 later.
These are process CPU measurements, not panel response times.

[Raw measurements](2026-10-25-token-history-benchmark.jsonl) retain every run.
A separate [profile](2026-10-25-token-history-profile.txt) identifies the work:
legacy warm reads decode cached records, resolve lineage and rebuild documents;
cold indexing spends time parsing and inserting/reconciling SQLite records;
new warm reads mainly stat files and open/query SQLite. Profile timings and RSS
are excluded from the reported measurements.

Verification:

- 416 focused Python tests passed across history, graphs, provider cards,
  settings, collector freshness and timing contracts.
- The cache and byte-accounting follow-ups passed 50 focused tests, including
  all index tests.
- Golden tests compare old and new documents using synthetic transcripts in
  temporary homes, including forks, copies, rotations, rewrites with restored
  mtime, local midnight, DST fallback, long-context prices and zero-token rows.
- Concurrent identical scans parse each file once. Unchanged reopens run with
  parsers replaced by failures. OpenClaw WAL growth and cross-reader generation
  invalidation have direct checks.
- `scripts/verify_fast.py` passed, using the main checkout's Python with this
  worktree on `PYTHONPATH`. Ruff and diff hygiene passed after the follow-up.
- `swift build` passed. The linker warned that a Command Line Tools framework
  search path was absent. Swift tests and rendered UI checks were withheld for L0.
- The benchmark harness also passed a 2,000-record smoke run.

Not proved: the installed daemon's 24-hour CPU/memory budgets, panel response
latency, rendered Settings behavior, Swift 6.3.3 CI, and fork-heavy incremental
scan performance. Copied Codex lineage is reconciled when input changes; the
large benchmark has independent sessions. SQLite/cache corruption makes an
active history request unavailable; automatic corruption repair is not added.
Quota-card reads fall back instead. No deployment, installation or device
writes were performed.

L0 should run Swift tests and render the Token history toggle after its window
guard lands. Its daemon refactor must preserve the settings setter's
`set_enabled`/`_sync_token_history` lifecycle hook, including initial loading
before provider collection. L5 should preserve the new settings key and apply provider Track
policy to the shared history inputs and maintenance provider list. No changelog
or What's New catalog was edited.
