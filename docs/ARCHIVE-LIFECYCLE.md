# Archive lifetime and read-only access

Data Hoarder separates the archive window from capture and imports. Turning
capture off does not remove saved files or prevent reading, searching, paging,
exporting, or managing Archive Trash. Existing consent and confirmation gates
still apply.

## Closing and reopening

Closing the archive releases its SwiftUI content, result rows, raw preview, and
reconstructed timeline. The window frame, query, selected record, and pending
import choices remain available on reopen. Close is not Cancel Review.

A closed window does not cancel a user-requested import or export, and it does
not stop capture that was separately enabled. Turning the utility off cancels
imports and index maintenance and stops capture. Already accepted file/database
work can finish; cancellation is not a rollback of saved content.

Read-only storage and status information loads when an archive is explicitly
opened with capture off. A disabled, closed utility starts neither status reads
nor indexing. Presentation generations reject results from windows that have
since closed; capture generations reject obsolete settings applications.

## Search

Each visible page requests at most 51 results and displays up to 50. The extra
row determines whether another page exists, without a second overlapping search
request. The offset advances only by the number displayed. Query, filter, and
Saved/Trash state identify the request: an older response cannot publish into a
replacement search, and an old page offset cannot be reused for a different
query. Multiple provider or state filters also activate search.

These changes reduce specific redundant work. They are not measurements of
startup time, physical memory footprint, battery life, or release artifact size.
No database schema, capture interval, dependency, packaging, or signing change is
part of this patch. Aquarium's separate proposed migration is not included.

## Maintainer verification

Run the repository's existing gates from a complete checkout on macOS 26:

```sh
./scripts/bootstrap-dev.sh
make fast
.venv/bin/python -m pytest tests -q
(cd app && swift build --build-tests && swift test)
```

The added `ArchiveRuntimeLifecycleTests` cover disabled access, closed content,
pending imports, filters, pagination, and canceled searches using scratch data.
Review the real app with capture off and on: search more than 100 saved records,
change a query before loading the next page, close during a preview read, reopen
an unfinished import review, and verify that intentional capture/export continues
with the window closed. Check keyboard focus and VoiceOver after reopening.

Native build, full tests, and matched release-build performance measurements are
required before merging or claiming resource improvements. A source-level review
or an extracted test with doubles is not equivalent to those checks.

Rollback is a normal revert of the patch. It does not require a data migration;
archive and application-settings formats are unchanged. See [project
attribution](../ATTRIBUTION.md) for JR-Bar's origin and retained license notices.
