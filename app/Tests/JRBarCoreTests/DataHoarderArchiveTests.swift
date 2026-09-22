import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing
@testable import JRBarCore

@Suite("Data Hoarder archive")
struct DataHoarderArchiveTests {
    @Test("Archive Trash preserves copies and restores the exact record after reopening")
    func trashAndRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let source = try fixture.file("trace.txt", data: Data("keep this trace".utf8))
        let record = try await archive.importFile(source)
        try await archive.moveToTrash(id: record.id)
        #expect(try await archive.records().isEmpty)
        #expect(try await archive.records(query: "keep this", inTrash: true) == [record])
        #expect(try Data(contentsOf: source) == Data("keep this trace".utf8))
        let reopened = DataHoarderArchive(root: fixture.archive)
        #expect(try await reopened.trashedRecords() == [record])
        #expect(try await reopened.preview(id: record.id, inTrash: true) == "keep this trace")
        let usage = try await reopened.storageUsage()
        #expect(usage.recordCount == 0 && usage.trashedRecordCount == 1)
        #expect(usage.trashedContentBytes == record.byteCount)
        try await reopened.restoreFromTrash(id: record.id)
        #expect(try await reopened.records() == [record])
        #expect(try await reopened.trashedRecords().isEmpty)
        #expect(try await reopened.emptyTrash(ids: [record.id]) == 0)
        #expect(try await reopened.preview(id: record.id) == "keep this trace")
    }

    @Test("legacy metadata cannot resurrect trashed or purged records")
    func legacyRespectsTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.file("legacy.txt", data: Data("legacy payload".utf8))
        let original = try fixture.legacyRecord(source: source)
        let manifest = fixture.archive.appendingPathComponent("manifest.json")
        var json = try Data(contentsOf: manifest)
        let archive = DataHoarderArchive(root: fixture.archive)
        try await archive.moveToTrash(id: original.id)
        json.append(32)
        try json.write(to: manifest)
        #expect(try await archive.records().isEmpty)
        #expect(try await archive.trashedRecords() == [original])
        #expect(try await archive.emptyTrash(ids: [original.id]) == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.archive.appendingPathComponent("objects/\(original.id)").path))
        json.append(32)
        try json.write(to: manifest)
        #expect(try await DataHoarderArchive(root: fixture.archive).records().isEmpty)
        #expect(try Data(contentsOf: source) == Data("legacy payload".utf8))
        let importedAgain = try await archive.importFile(source)
        json.append(32)
        try json.write(to: manifest)
        #expect(try await archive.records() == [importedAgain])
        #expect(try await archive.emptyTrash(ids: [original.id]) == 0)
        #expect(try await archive.preview(id: original.id) == "legacy payload")
    }

    @Test("complete exports preserve saved and trashed records independently")
    func exportPreservesTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let saved = try await archive.importFile(fixture.file("saved.txt", data: Data("saved".utf8)))
        let trashed = try await archive.importFile(fixture.file("trashed.txt", data: Data("recoverable".utf8)))
        try await archive.moveToTrash(id: trashed.id)
        let destination = fixture.root.appendingPathComponent("backup")
        #expect(try await archive.exportArchive(to: destination) == 2)
        try FileManager.default.removeItem(at: fixture.archive)
        let reopened = DataHoarderArchive(root: destination)
        #expect(try await reopened.records() == [saved])
        #expect(try await reopened.trashedRecords() == [trashed])
        try await reopened.restoreFromTrash(id: trashed.id)
        #expect(try await reopened.preview(id: trashed.id) == "recoverable")
    }

    @Test("v1 catalogs upgrade transactionally without changing saved records")
    func upgradesVersionOneCatalog() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let saved = try await archive.importFile(fixture.file("saved.txt", data: Data("saved".utf8)))
        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.archive.appendingPathComponent("catalog.sqlite3").path, &database) == SQLITE_OK)
        // A real v1 catalog: no trash, none of the v3 capture/FTS tables,
        // and records back in their six-column shape — not merely
        // user_version relabeled, which the integrity check rightly rejects.
        #expect(sqlite3_exec(database, """
            DROP TABLE removed_records;
            DROP TABLE segments;
            DROP TABLE capture_state;
            DROP TABLE capture_failures;
            DROP TABLE segments_fts;
            ALTER TABLE records RENAME TO records_v3;
            CREATE TABLE records(
                id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 64),
                name TEXT NOT NULL,
                source_path TEXT NOT NULL,
                byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
                imported_at REAL NOT NULL,
                source_modified_at REAL
            ) WITHOUT ROWID;
            INSERT INTO records
                SELECT id, name, source_path, byte_count, imported_at, source_modified_at
                FROM records_v3;
            DROP TABLE records_v3;
            PRAGMA user_version=1
            """, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close(database) == SQLITE_OK)
        let reopened = DataHoarderArchive(root: fixture.archive)
        let other = DataHoarderArchive(root: fixture.archive)
        async let firstRead = reopened.records()
        async let secondRead = other.records()
        let (first, second) = try await (firstRead, secondRead)
        #expect(first == [saved] && second == [saved])
        try await reopened.moveToTrash(id: saved.id)
        try await reopened.restoreFromTrash(id: saved.id)
        #expect(try await reopened.records() == [saved])
    }

    @Test("emptying trash rejects unexpected directories and preserves their contents")
    func trashRefusesDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.importFile(fixture.file("saved.txt", data: Data("saved".utf8)))
        try await archive.moveToTrash(id: record.id)
        let object = fixture.archive.appendingPathComponent("objects/\(record.id)")
        try FileManager.default.removeItem(at: object)
        try FileManager.default.createDirectory(at: object, withIntermediateDirectories: false)
        let unexpected = object.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: unexpected)
        await #expect(throws: DataHoarderArchiveError.objectCorrupt) { _ = try await archive.emptyTrash(ids: [record.id]) }
        #expect(try Data(contentsOf: unexpected) == Data("keep".utf8))
        #expect(try await archive.trashedRecords() == [record])
    }

    @Test("corrupt trash cannot be restored and cancelled purge leaves it intact")
    func trashIntegrityAndCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.importFile(fixture.file("saved.txt", data: Data("saved".utf8)))
        try await archive.moveToTrash(id: record.id)
        let object = fixture.archive.appendingPathComponent("objects/\(record.id)")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await archive.emptyTrash(ids: [record.id])
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try Data(contentsOf: object) == Data("saved".utf8))
        try Data("wrong".utf8).write(to: object)
        await #expect(throws: DataHoarderArchiveError.objectCorrupt) {
            try await archive.restoreFromTrash(id: record.id)
        }
        #expect(try await archive.records().isEmpty)
        #expect(try await archive.trashedRecords() == [record])
    }

    @Test("trash retention purges by trash date and keeps unstamped entries")
    func trashRetention() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let fresh = try await archive.importFile(fixture.file("fresh.txt", data: Data("fresh".utf8)))
        let stale = try await archive.importFile(fixture.file("stale.txt", data: Data("stale".utf8)))
        let legacy = try await archive.importFile(fixture.file("legacy.txt", data: Data("legacy".utf8)))
        try await archive.moveToTrash(id: fresh.id)
        try await archive.moveToTrash(id: stale.id,
                                     trashedAt: Date().addingTimeInterval(-40 * 86_400))
        try await archive.moveToTrash(id: legacy.id)
        // A trash row written before the stamp existed: strip trashedAt.
        let catalogPath = fixture.archive.appendingPathComponent("catalog.sqlite3")
        var database: OpaquePointer?
        #expect(sqlite3_open(catalogPath.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let select = "SELECT record_json FROM removed_records WHERE id = '\(legacy.id)'"
        #expect(sqlite3_prepare_v2(database, select, -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        var json = try #require(String(cString: sqlite3_column_text(statement, 0)))
        sqlite3_finalize(statement)
        var object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object.removeValue(forKey: "trashedAt")
        json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let update = "UPDATE removed_records SET record_json = '\(json)' WHERE id = '\(legacy.id)'"
        #expect(sqlite3_exec(database, update, nil, nil, nil) == SQLITE_OK)

        #expect(try await archive.purgeExpiredTrash(olderThanDays: 30) == 1)
        let remaining = try await archive.trashedRecords()
        #expect(remaining.map(\.id).sorted() == [fresh.id, legacy.id].sorted())
        #expect(remaining.first { $0.id == fresh.id }?.trashedAt != nil)
        #expect(remaining.first { $0.id == legacy.id }?.trashedAt == nil)
        let staleObject = fixture.archive.appendingPathComponent("objects/\(stale.id)")
        #expect(!FileManager.default.fileExists(atPath: staleObject.path))
        // Nothing expires twice and a disabled window is a no-op.
        #expect(try await archive.purgeExpiredTrash(olderThanDays: 30) == 0)
        #expect(try await archive.purgeExpiredTrash(olderThanDays: 0) == 0)
        // The stamp does not leak back into the live table on restore.
        try await archive.restoreFromTrash(id: fresh.id)
        #expect(try await archive.record(id: fresh.id)?.trashedAt == nil)
    }

    @Test("storage usage distinguishes saved content from allocated archive storage")
    func storageAccounting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let empty = try await archive.storageUsage()
        #expect(empty.recordCount == 0 && empty.contentBytes == 0 && empty.allocatedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.archive.path))
        let source = try fixture.file("trace.txt", data: Data("saved".utf8))
        _ = try await archive.importFile(source)
        _ = try await archive.importFile(source)
        let saved = try await archive.storageUsage()
        #expect(saved.recordCount == 1)
        #expect(saved.contentBytes == 5)
        #expect(saved.allocatedBytes >= saved.contentBytes)
        let temporary = fixture.archive.appendingPathComponent(".pending-copy")
        try Data(repeating: 65, count: 100_000).write(to: temporary)
        let pending = try await archive.storageUsage()
        #expect(pending.recordCount == 1 && pending.contentBytes == 5)
        #expect(pending.allocatedBytes > saved.allocatedBytes)

        // Following this directory link would count unrelated source files.
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.archive.appendingPathComponent("external-link"), withDestinationURL: outside)
        let beforeExternalWrite = try await archive.storageUsage()
        try Data(repeating: 66, count: 200_000).write(to: outside.appendingPathComponent("unrelated"))
        #expect(try await archive.storageUsage() == beforeExternalWrite)
    }

    @Test("storage measurement respects cancellation")
    func cancelledStorageMeasurement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        _ = try await archive.importFile(fixture.file("trace.txt", data: Data("saved".utf8)))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await archive.storageUsage()
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await archive.records().count == 1)
    }

    @Test("storage allocation counts hard-linked objects once")
    func storageHardLinks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.importFile(fixture.file("trace.txt", data: Data(repeating: 65, count: 16_384)))
        let objects = fixture.archive.appendingPathComponent("objects")
        let before = try await archive.storageUsage()
        var beforeDirectory = stat()
        try #require(lstat(objects.path, &beforeDirectory) == 0)
        try FileManager.default.linkItem(at: objects.appendingPathComponent(record.id),
                                        to: objects.appendingPathComponent("hard-link"))
        var afterDirectory = stat()
        try #require(lstat(objects.path, &afterDirectory) == 0)
        let after = try await archive.storageUsage()
        #expect(after.recordCount == before.recordCount)
        #expect(after.contentBytes == before.contentBytes)
        #expect(after.allocatedBytes == before.allocatedBytes
            + (afterDirectory.st_blocks - beforeDirectory.st_blocks) * 512)
    }

    @Test("complete export reopens independently with metadata and private permissions")
    func completeExportRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let text = try await archive.importFile(fixture.file("trace.txt", data: Data("saved trace".utf8)))
        let binary = try await archive.importFile(fixture.file("artifact.bin", data: Data([0, 255, 17])))
        let destination = fixture.root.appendingPathComponent("complete")
        #expect(try await archive.exportArchive(to: destination) == 2)
        #expect(try permissions(destination) == 0o700)
        #expect(try permissions(destination.appendingPathComponent("objects")) == 0o700)
        #expect(try permissions(destination.appendingPathComponent("manifest.json")) == 0o600)
        for record in [text, binary] {
            #expect(try permissions(destination.appendingPathComponent("objects/\(record.id)")) == 0o600)
        }
        try FileManager.default.removeItem(at: fixture.archive)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: text.sourcePath))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: binary.sourcePath))
        let reopened = DataHoarderArchive(root: destination)
        #expect(Set(try await reopened.records().map(\.id)) == Set([text.id, binary.id]))
        #expect(try await reopened.records().contains(text))
        #expect(try await reopened.records().contains(binary))
        #expect(try await reopened.preview(id: text.id) == "saved trace")
        let output = fixture.root.appendingPathComponent("restored.bin")
        try await reopened.export(id: binary.id, to: output)
        #expect(try Data(contentsOf: output) == Data([0, 255, 17]))
    }

    @Test("corrupt objects cannot publish a partial archive export")
    func completeExportRejectsCorruption() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.importFile(fixture.file("trace.txt", data: Data("saved".utf8)))
        try Data("wrong".utf8).write(to: fixture.archive.appendingPathComponent("objects/\(record.id)"))
        let destination = fixture.root.appendingPathComponent("complete")
        await #expect(throws: DataHoarderArchiveError.objectCorrupt) {
            _ = try await archive.exportArchive(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .allSatisfy { !$0.hasPrefix(".jrbar-archive-export-") })
    }

    @Test("complete export preserves existing destinations and rejects cancellation")
    func completeExportCollisionAndCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let destination = try fixture.file("existing", data: Data("keep".utf8))
        await #expect(throws: DataHoarderArchiveError.destinationExists) {
            _ = try await archive.exportArchive(to: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("keep".utf8))
        let dangling = fixture.root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/missing-jrbar-export-target")
        await #expect(throws: DataHoarderArchiveError.destinationExists) {
            _ = try await archive.exportArchive(to: dangling)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path) == "/missing-jrbar-export-target")
        let cancelled = fixture.root.appendingPathComponent("cancelled")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await archive.exportArchive(to: cancelled)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        #expect(try await archive.records().isEmpty)
    }

    @Test("a matching version with an invalid schema is rejected without modification")
    func invalidSchemaStaysUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.archive, withIntermediateDirectories: true)
        let path = fixture.archive.appending(path: "catalog.sqlite3")
        var database: OpaquePointer?
        #expect(sqlite3_open(path.path, &database) == SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        #expect(sqlite3_exec(database, "CREATE TABLE unrelated(value TEXT); PRAGMA user_version=1; PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close(database) == SQLITE_OK)
        database = nil
        let before = try Data(contentsOf: path)
        let archive = DataHoarderArchive(root: fixture.archive)
        await #expect(throws: DataHoarderArchiveError.corruptManifest) { _ = try await archive.records() }
        #expect(try Data(contentsOf: path) == before)
    }

    @Test("legacy changes are detected even when size and modification date are restored")
    func restoredLegacyTimestampCannotHideChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.file("legacy.txt", data: Data("legacy".utf8))
        _ = try fixture.legacyRecord(source: source)
        let archive = DataHoarderArchive(root: fixture.archive)
        _ = try await archive.records()
        let manifest = fixture.archive.appending(path: "manifest.json")
        var before = stat()
        try #require(manifest.path.withCString { lstat($0, &before) } == 0)
        let original = try String(contentsOf: manifest, encoding: .utf8)
        let changed = original.replacingOccurrences(of: "legacy.txt", with: "change.txt")
        #expect(original.utf8.count == changed.utf8.count)
        try Data(changed.utf8).write(to: manifest)
        let timestamps = [before.st_atimespec, before.st_mtimespec]
        let restoreResult = manifest.path.withCString { path in
            timestamps.withUnsafeBufferPointer { times in
                utimensat(AT_FDCWD, path, times.baseAddress, 0)
            }
        }
        try #require(restoreResult == 0)
        var after = stat()
        try #require(manifest.path.withCString { lstat($0, &after) } == 0)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
        #expect(after.st_size == before.st_size)
        #expect(after.st_ino == before.st_ino)
        await #expect(throws: DataHoarderArchiveError.corruptManifest) { _ = try await archive.records() }
    }

    @Test("unsupported catalog versions are rejected without changing their storage mode")
    func unsupportedCatalogStaysUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        _ = try await archive.importFile(fixture.file("first.txt", data: Data("fixture".utf8)))
        let path = fixture.archive.appending(path: "catalog.sqlite3")
        var database: OpaquePointer?
        #expect(sqlite3_open(path.path, &database) == SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        #expect(sqlite3_exec(database, "PRAGMA user_version=99; PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close(database) == SQLITE_OK)
        database = nil
        let before = try Data(contentsOf: path)
        await #expect(throws: DataHoarderArchiveError.corruptManifest) {
            _ = try await archive.records()
        }
        #expect(try Data(contentsOf: path) == before)
    }

    @Test("cancellation leaves completed records intact and removes the pending copy")
    func cancelledCopyKeepsCommittedRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let existing = try await archive.importFile(fixture.file("saved.txt", data: Data("saved".utf8)))
        let source = try fixture.file("pending.txt", data: Data(repeating: 65, count: 200_000))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await archive.importFile(source)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await archive.records() == [existing])
        #expect(try await archive.preview(id: existing.id) == "saved")
        let files = try FileManager.default.contentsOfDirectory(at: fixture.archive,
                                                                includingPropertiesForKeys: nil)
        #expect(!files.contains { $0.lastPathComponent.hasPrefix(".import-") })
    }

    @Test("empty listing does not create archive storage")
    func emptyListingIsReadOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try await DataHoarderArchive(root: fixture.archive).records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archive.path))
    }

    @Test("legacy manifest migrates without changing it and survives source removal")
    func migratesLegacyManifest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.file("legacy.txt", data: Data("legacy payload".utf8))
        let record = try fixture.legacyRecord(source: source)
        let manifest = fixture.archive.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: source)

        let archive = DataHoarderArchive(root: fixture.archive)
        #expect(try await archive.records() == [record])
        #expect(try await archive.preview(id: record.id) == "legacy payload")
        #expect(try Data(contentsOf: manifest) == before)
        #expect(FileManager.default.fileExists(
            atPath: fixture.archive.appendingPathComponent("catalog.sqlite3").path))
        #expect(try await DataHoarderArchive(root: fixture.archive).records() == [record])
    }

    @Test("migration deduplicates an incoming copy")
    func migratedDedup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.file("legacy.txt", data: Data("same legacy".utf8))
        let record = try fixture.legacyRecord(source: source)
        let duplicate = try fixture.file("duplicate.txt", data: Data("same legacy".utf8))
        let archive = DataHoarderArchive(root: fixture.archive)

        #expect(try await archive.importFile(duplicate) == record)
        #expect(try await archive.records() == [record])
    }

    @Test("legacy corruption after migration is not hidden by the catalog")
    func changedLegacyManifestFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.file("legacy.txt", data: Data("legacy".utf8))
        _ = try fixture.legacyRecord(source: source)
        let archive = DataHoarderArchive(root: fixture.archive)
        #expect(try await archive.records().count == 1)

        let manifest = fixture.archive.appendingPathComponent("manifest.json")
        try Data("corrupt changed legacy".utf8).write(to: manifest)
        await #expect(throws: DataHoarderArchiveError.corruptManifest) {
            _ = try await archive.records()
        }
    }

    @Test("corrupt SQLite catalog fails closed")
    func corruptCatalog() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        _ = try await archive.importFile(fixture.file("trace.txt", data: Data("trace".utf8)))
        try Data("not sqlite".utf8).write(
            to: fixture.archive.appendingPathComponent("catalog.sqlite3"))

        await #expect(throws: DataHoarderArchiveError.corruptManifest) {
            _ = try await DataHoarderArchive(root: fixture.archive).records()
        }
    }

    @Test("two archive actors publish a fresh catalog without losing concurrent imports")
    func concurrentFreshImports() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sameA = try fixture.file("same-a.txt", data: Data("same".utf8))
        let sameB = try fixture.file("same-b.txt", data: Data("same".utf8))
        let distinct = try fixture.file("distinct.txt", data: Data("distinct".utf8))
        let first = DataHoarderArchive(root: fixture.archive)
        let second = DataHoarderArchive(root: fixture.archive)

        async let one = first.importFile(sameA)
        async let two = second.importFile(sameB)
        async let three = second.importFile(distinct)
        _ = try await (one, two, three)

        let records = try await first.records()
        #expect(records.count == 2)
        try await verifyExports(records, archive: second, fixture: fixture)
    }

    @Test("two archive actors migrate and import concurrently without index loss")
    func concurrentMigrationImports() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacySource = try fixture.file("legacy.txt", data: Data("legacy".utf8))
        _ = try fixture.legacyRecord(source: legacySource)
        let same = try fixture.file("same.txt", data: Data("legacy".utf8))
        let distinct = try fixture.file("distinct.txt", data: Data("new".utf8))
        let first = DataHoarderArchive(root: fixture.archive)
        let second = DataHoarderArchive(root: fixture.archive)

        async let one = first.importFile(same)
        async let two = second.importFile(distinct)
        _ = try await (one, two)

        let records = try await DataHoarderArchive(root: fixture.archive).records()
        #expect(records.count == 2)
        try await verifyExports(records, archive: first, fixture: fixture)
    }

    @Test("damaged stored contents cannot masquerade as a valid preview or export")
    func rejectsDamagedPreviewAndExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.importFile(fixture.file("trace.txt", data: Data("original".utf8)))
        let object = fixture.archive.appending(path: "objects").appending(path: record.id)
        try Data("modified".utf8).write(to: object)
        await #expect(throws: DataHoarderArchiveError.objectCorrupt) {
            _ = try await archive.preview(id: record.id)
        }
        let destination = fixture.root.appending(path: "export.txt")
        await #expect(throws: DataHoarderArchiveError.objectCorrupt) {
            try await archive.export(id: record.id, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: object) == Data("modified".utf8))
    }

    @Test("imports once by content hash and survives source removal")
    func deduplicatesAndPreservesObject() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstSource = try fixture.file("first.txt", data: Data("same trace".utf8))
        let secondSource = try fixture.file("second.txt", data: Data("same trace".utf8))
        let archive = DataHoarderArchive(root: fixture.archive)

        let first = try await archive.importFile(firstSource)
        let duplicate = try await archive.importFile(secondSource)
        #expect(first == duplicate)
        #expect(try await archive.records().count == 1)

        try FileManager.default.removeItem(at: firstSource)
        #expect(try await archive.preview(id: first.id) == "same trace")
    }

    @Test("dedup restores a missing object and rejects a corrupt one")
    func dedupVerifiesObject() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.file("trace.txt", data: Data("durable trace".utf8))
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.importFile(source)
        let object = fixture.archive.appendingPathComponent("objects/").appendingPathComponent(record.id)

        try FileManager.default.removeItem(at: object)
        #expect(try await archive.importFile(source) == record)
        #expect(try await archive.preview(id: record.id) == "durable trace")

        try Data("tampered".utf8).write(to: object)
        await #expect(throws: DataHoarderArchiveError.objectCorrupt) {
            _ = try await archive.importFile(source)
        }
    }

    @Test("binary files import without loading as text")
    func binaryPreview() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.file("trace.bin", data: Data([0, 1, 2, 255]))
        let archive = DataHoarderArchive(root: fixture.archive)

        let record = try await archive.importFile(source)
        #expect(try await archive.preview(id: record.id) == "Binary file · 4 bytes")
        #expect(try await archive.records(query: "trace").map(\.id) == [record.id])
        #expect(try await archive.records(query: "missing").isEmpty)
    }

    @Test("search matches names, source paths, and text content")
    func search() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let alpha = try await archive.importFile(
            fixture.file("alpha.log", data: Data("ordinary output".utf8)))
        let content = try await archive.importFile(
            fixture.file("other.log", data: Data("Unique Session Marker".utf8)))

        #expect(try await archive.records(query: "ALPHA").map(\.id) == [alpha.id])
        #expect(try await archive.records(query: "session marker").map(\.id) == [content.id])
    }

    @Test("search scans the full file and carries split UTF-8 text")
    func fullStreamingSearch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        var late = Data(repeating: 65, count: 8 * 1024 * 1024 + 100)
        late.append(Data("marker after old limit".utf8))
        let lateRecord = try await archive.importFile(fixture.file("late.log", data: late))

        var split = Data(repeating: 66, count: 64 * 1024 - 2)
        split.append(Data("🧭boundary marker".utf8))
        let splitRecord = try await archive.importFile(fixture.file("split.log", data: split))

        #expect(try await archive.records(query: "after old limit").map(\.id) == [lateRecord.id])
        #expect(try await archive.records(query: "🧭boundary").map(\.id) == [splitRecord.id])
    }

    @Test("preview is bounded")
    func boundedPreview() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let source = try fixture.file("large.txt", data: Data(repeating: 65, count: 300_000))

        let record = try await archive.importFile(source)
        let preview = try await archive.preview(id: record.id)
        #expect(preview.hasSuffix("\n…"))
        #expect(preview.utf8.count == 256 * 1024 + 4)
    }

    @Test("preview completes a UTF-8 scalar split at its byte limit")
    func previewUTF8Boundary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        var bytes = Data(repeating: 65, count: 256 * 1024 - 1)
        bytes.append(Data("🧭tail".utf8))
        let record = try await archive.importFile(fixture.file("utf8.txt", data: bytes))

        let preview = try await archive.preview(id: record.id)
        #expect(preview.contains("🧭"))
        #expect(preview.hasSuffix("\n…"))
    }

    @Test("corrupt manifest fails closed and remains untouched")
    func corruptManifest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.archive,
                                                withIntermediateDirectories: true)
        let manifest = fixture.archive.appendingPathComponent("manifest.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: manifest)
        let archive = DataHoarderArchive(root: fixture.archive)
        let source = try fixture.file("source.txt", data: Data("payload".utf8))

        await #expect(throws: DataHoarderArchiveError.corruptManifest) {
            _ = try await archive.records()
        }
        await #expect(throws: DataHoarderArchiveError.corruptManifest) {
            _ = try await archive.importFile(source)
        }
        #expect(try Data(contentsOf: manifest) == corrupt)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.archive.appendingPathComponent("objects").path))
    }

    @Test("manifest rejects unsafe IDs, duplicates, negative sizes, and invalid dates")
    func validatesManifestRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.archive,
                                                withIntermediateDirectories: true)
        let manifest = fixture.archive.appendingPathComponent("manifest.json")
        let validID = String(repeating: "a", count: 64)
        let base: [String: Any] = [
            "id": validID, "name": "trace", "sourcePath": "/tmp/trace",
            "byteCount": 1, "importedAt": 0,
        ]
        let invalidRecords: [[Any]] = [
            [["id": "../outside", "name": "trace", "sourcePath": "/tmp/trace",
              "byteCount": 1, "importedAt": 0]],
            [base, base],
            [["id": validID, "name": "trace", "sourcePath": "/tmp/trace",
              "byteCount": -1, "importedAt": 0]],
            [["id": validID, "name": "bad\0name", "sourcePath": "/tmp/trace",
              "byteCount": 1, "importedAt": 0]],
        ]

        for records in invalidRecords {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "records": records])
            try data.write(to: manifest)
            let archive = DataHoarderArchive(root: fixture.archive)
            await #expect(throws: DataHoarderArchiveError.corruptManifest) {
                _ = try await archive.records()
            }
        }

        try Data(#"{"version":1,"records":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"trace","sourcePath":"/tmp/trace","byteCount":1,"importedAt":1e999}]}"#.utf8)
            .write(to: manifest)
        let archive = DataHoarderArchive(root: fixture.archive)
        await #expect(throws: DataHoarderArchiveError.corruptManifest) {
            _ = try await archive.records()
        }
    }

    @Test("directories and symbolic links are rejected")
    func rejectsUnsupportedKinds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let directory = fixture.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let target = try fixture.file("target.txt", data: Data("target".utf8))
        let link = fixture.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        await #expect(throws: DataHoarderArchiveError.unsupportedFile) {
            _ = try await archive.importFile(directory)
        }
        await #expect(throws: DataHoarderArchiveError.unsupportedFile) {
            _ = try await archive.importFile(link)
        }
    }

    @Test("storage is private")
    func privatePermissions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.importFile(
            fixture.file("private.txt", data: Data("private".utf8)))
        let objects = fixture.archive.appendingPathComponent("objects")
        let object = objects.appendingPathComponent(record.id)
        let catalog = fixture.archive.appendingPathComponent("catalog.sqlite3")

        #expect(try permissions(fixture.archive) == 0o700)
        #expect(try permissions(objects) == 0o700)
        #expect(try permissions(object) == 0o600)
        #expect(try permissions(catalog) == 0o600)
    }

    @Test("export preserves bytes and refuses collisions")
    func exportAndCollision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Data([4, 3, 2, 1])
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.importFile(fixture.file("source.bin", data: bytes))
        let destination = fixture.root.appendingPathComponent("export.bin")

        try await archive.export(id: record.id, to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        await #expect(throws: DataHoarderArchiveError.destinationExists) {
            try await archive.export(id: record.id, to: destination)
        }
        #expect(try Data(contentsOf: destination) == bytes)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func verifyExports(
        _ records: [ArchiveRecord], archive: DataHoarderArchive, fixture: Fixture
    ) async throws {
        for record in records {
            let destination = fixture.root.appendingPathComponent("verify-\(record.id)")
            try await archive.export(id: record.id, to: destination)
            let digest = SHA256.hash(data: try Data(contentsOf: destination))
                .map { String(format: "%02x", $0) }.joined()
            #expect(digest == record.id)
        }
    }
}

private struct Fixture {
    let root: URL
    let archive: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-hoarder-\(UUID().uuidString)", isDirectory: true)
        archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func file(_ name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func legacyRecord(source: URL) throws -> ArchiveRecord {
        let data = try Data(contentsOf: source)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let objects = archive.appendingPathComponent("objects", isDirectory: true)
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        try data.write(to: objects.appendingPathComponent(id))
        let record = ArchiveRecord(
            id: id, name: source.lastPathComponent, sourcePath: source.path,
            byteCount: Int64(data.count), importedAt: Date(timeIntervalSince1970: 2_000),
            sourceModifiedAt: Date(timeIntervalSince1970: 1_000))
        struct LegacyManifest: Codable { let version: Int; let records: [ArchiveRecord] }
        try JSONEncoder().encode(LegacyManifest(version: 1, records: [record]))
            .write(to: archive.appendingPathComponent("manifest.json"))
        return record
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
