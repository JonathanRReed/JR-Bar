# Data Hoarder implementation plan

Spec: `docs/product-design-2026-09-19.md`, approved by Jonathan with "lets do it".
Execution: continue in the current task, using bounded workers for independent
modules. Preserve current changes. Do not commit or publish.

## First usable archive

Build a native utility backed by a local Foundation archive actor. Manual import
copies explicitly selected files. A review step shows filename, size, and source
modification date before copying full contents. No background capture or proxy
configuration is enabled by this flow.

Storage lives below the user's JR-Bar state directory. Content hashes identify
duplicates. Immutable copied objects and an atomically replaced metadata index
survive original-file removal. A corrupt index must report failure and remain
untouched. Archive directories and files use private permissions.

The public core interface is `DataHoarderArchive`, initialized with `root: URL`.
It exposes actor methods `records(query: String) throws -> [ArchiveRecord]`,
`importFile(_ source: URL) throws -> ArchiveRecord`,
`preview(id: String) throws -> String`, and
`export(id: String, to destination: URL) throws`.
`ArchiveRecord` is Codable, Sendable, Equatable, Identifiable and carries
`id`, `name`, `sourcePath`, `byteCount: Int64`, `importedAt: Date`,
`sourceModifiedAt: Date?`. IDs are SHA-256 hex digests. Existing export targets
must never be overwritten silently.

- [x] Implement core storage and tests in `JRBarCore/DataHoarderArchive.swift`
  and `JRBarCoreTests/DataHoarderArchiveTests.swift`. Cover duplicates, binary
  files, source removal, corrupt indexes, unsupported file kinds, search,
  private permissions, and export collisions. Bound previews and memory use.
- [x] Add `DataHoarderUtility` and its native archive window under
  `JRBarApp/Utilities/DataHoarder`. Use the core actor off the main thread.
  Show import review, progress, errors, search, selection, preview, and export.
  A utility toggle persists in `UtilitiesState`; disabled means no monitoring.
- [x] Connect the utility to `UtilitiesStore` and `UtilitiesPage`, using the
  existing ToyCard conventions. Keep archived records when switched off.
- [x] Run archive and utility-state checks, build a signed local candidate,
  and verify selection/import/search/preview/export in the installed app with
  synthetic trace fixtures. Preserve user data and restore temporary settings.

Verified in installed build `goal-20260919-07`: explicit file-content consent,
import, content-only search, no-match search, duplicate prevention, byte-identical
export, and persistence across restart while the original fixture was absent.
Imports were restored to off; saved data remained readable. One clearly labeled
synthetic trace remains in the archive. Its original fixture was restored.

The full parallel suite passed 1,137 tests before final review changes. The final
archive regressions passed 16 checks. Optimized Notch lifecycle checks passed
45 tests after making the existing pinned Sparkle framework available to the
standalone test bundle. Live layout review caught and corrected empty-state
sizing and preview scroll alignment before the final install.

## Subsequent slices, still required

Bulk import improvements are installed in builds 09 and 10. A repeated serial
benchmark imported 1,000 distinct synthetic files totaling 4,139,890 bytes in
12.303 seconds with the JSON index and 5.092 seconds with SQLite, about 2.4 times
faster. This measures small-file imports, not throughput for the user's full corpus.

The SQLite catalog keeps the public archive API and hash-named objects. Legacy
v1 metadata is validated and migrated transactionally; the original manifest and
objects remain untouched. Migration, cancellation, concurrent imports, corruption,
locking, schema validation, and changed legacy metadata have regression coverage.
The full suite passed 1,160 checks before final catalog review fixes; all 39 focused
checks passed afterward. Stop Import, bounded failure reporting, cancellable query
refresh, search progress, and Clear search are installed.

Installed verification stopped a synthetic 6,000-file import with 460 committed
and 5,540 pending. Committed content remained available. The 1,460 synthetic bulk
records from both runs were then removed with hash and purpose validation, leaving
the two original fixtures and the unchanged legacy manifest. Imports remain off.
No real history contents were imported. Receipts are in
`.jrbar-verification/goal-20260919-09/bulk-ui-verification.json`.

History discovery is installed in build 08. `DataHoarderSources.swift` scans only file
metadata in Codex sessions, Codex archived sessions, Claude Code projects, or a
chosen folder. Environment overrides are honored. Traversal skips hidden files,
packages, and symbolic links and reports missing folders and capped results.
The native source review shows file counts, byte sizes, modification-date ranges,
and date filters. No sources start selected. Choosing sources opens the existing
per-file review and resets full-content consent. Discovery does not start future
capture. Scanner and model tests use synthetic directories and unreadable-content
fixtures to verify that discovery does not need conversation access.

All 25 focused checks passed. Installed source selection, modification-date
filtering, content consent, and fixture import passed. Real source metadata was
listed with no sources selected and no real history imported. The available
corpus is tens of gigabytes, so the next capture slice must avoid repeatedly
copying whole growing transcripts and must keep large imports responsive.

Add enabled source capture with restart-safe progress. Integrate CLIProxyAPI optionally;
persist structured records independently of its transient queue. Keep full
prompt/response capture explicit. Expose provenance, missing data, and failures.
Complete archive export is installed in build 19. Export > Entire Archive saves
a portable manifest and verified objects regardless of the current search or
import toggle. Exclusive publication preserves existing destinations, and failed
or cancelled exports do not publish partial archives. Core tests reopen the copy
after removing the original archive and source fixtures. The installed app
exported both synthetic records while search showed no matches and imports were
off. Metadata, hashes, permissions, and unchanged source state were verified.
The final visual check also fixed search moving downward in the empty state.
Receipts are in `.jrbar-verification/goal-20260919-19/`.

Storage visibility is installed in build 20. The footer reports all saved
records, content bytes, and allocated disk space independently of search.
Metadata-only disk accounting includes catalog and temporary files, skips
symlink targets, and counts hard links once. Installed refresh matched filesystem
measurements before, during, and after a temporary allocation fixture. Settings
and archived records were unchanged. The full Swift suite passed with 1,198
reported tests. Receipts are in `.jrbar-verification/goal-20260919-20/`.

Recoverable cleanup is installed in build 22. Archive Trash retains copied
objects and exact metadata until restored or explicitly deleted. Native permanent
deletion confirmation defaults to Cancel. Catalog v2 tracks removals so legacy
metadata cannot resurrect them, and stale purge IDs cannot remove restored copies.
Full snapshot exports preserve trash state in a v2 manifest when needed.

The full Swift suite passed with 1,206 reported tests before the final selector
and empty-action polish. Installed move, preview, cancel, snapshot export, and
restore passed using the synthetic fixture. The final candidate verified action
enablement and the rendered layout. Permanent deletion passed core/model tests;
the installed confirmation was cancelled. The original records, objects, source
files, legacy manifest, and settings were preserved. A v1 archive backup is in
`.jrbar-verification/goal-20260919-21/archive-before-migration/`; older app builds
cannot read the new v2 catalog. Receipts are in the goal 21 and 22 folders.

Incremental capture, restart-safe progress, optional CLI proxy ingestion, and
large-corpus search improvements remain required. No real history capture is on.

The broader design also retains Notch motion, Menu Bar and Dock reliability,
settings persistence, and every toy's installed behavior/performance gates.
The first archive does not satisfy those remaining requirements by itself.
