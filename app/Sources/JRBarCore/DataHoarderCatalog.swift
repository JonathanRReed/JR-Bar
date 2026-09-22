import Foundation
import Darwin
import SQLite3

/// The archive's SQLite catalog (schema v3).
///
/// v3 adds segmented records — a record's content is the ordered
/// concatenation of its `segments` rows' objects — plus the live-capture
/// bookkeeping (`capture_state`, `capture_failures`) and a contentless-
/// delete FTS5 index (`segments_fts`, keyed by `segments.rowid`).
/// `segments` is a rowid table on purpose: the rowid is the stable key the
/// FTS index and snippet lookups share.
final class DataHoarderCatalog {
    static let schemaVersion: Int32 = 3
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var database: OpaquePointer?
    // The v2 records shape, kept so an on-disk v2 catalog validates before
    // its transactional upgrade. v3's text must equal what the migration's
    // ALTERs append — the normalized comparison in `validateSchema` is the
    // proof they agree.
    private static let recordsSchemaV2 = """
        CREATE TABLE records(
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 64),
            name TEXT NOT NULL,
            source_path TEXT NOT NULL,
            byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
            imported_at REAL NOT NULL,
            source_modified_at REAL
        ) WITHOUT ROWID
        """
    private static let recordsSchema = """
        CREATE TABLE records(
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 64),
            name TEXT NOT NULL,
            source_path TEXT NOT NULL,
            byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
            imported_at REAL NOT NULL,
            source_modified_at REAL,
            provider TEXT,
            session_id TEXT,
            project TEXT,
            model TEXT,
            title TEXT,
            started_at REAL,
            last_activity_at REAL,
            segment_count INTEGER NOT NULL DEFAULT 0 CHECK(segment_count >= 0),
            capture_state TEXT NOT NULL DEFAULT 'snapshot'
        ) WITHOUT ROWID
        """
    private static let metadataSchema = "CREATE TABLE metadata(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID"
    private static let removedSchema = "CREATE TABLE removed_records(id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 64), record_json TEXT) WITHOUT ROWID"
    private static let segmentsSchema = """
        CREATE TABLE segments(
            record_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            hash TEXT NOT NULL CHECK(length(hash) = 64),
            byte_offset INTEGER NOT NULL CHECK(byte_offset >= 0),
            byte_length INTEGER NOT NULL CHECK(byte_length >= 0),
            captured_at REAL NOT NULL,
            note TEXT,
            PRIMARY KEY(record_id, ordinal)
        )
        """
    private static let captureStateSchema = """
        CREATE TABLE capture_state(
            path TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL,
            inode INTEGER NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            offset INTEGER NOT NULL CHECK(offset >= 0),
            record_id TEXT
        ) WITHOUT ROWID
        """
    private static let captureFailuresSchema = """
        CREATE TABLE capture_failures(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL,
            source_id TEXT NOT NULL,
            at REAL NOT NULL,
            error TEXT NOT NULL
        )
        """
    // Plain FTS5: the index stores the segment text itself so snippet() can
    // reconstruct highlights — contentless modes delete the very text the
    // snippets pane needs (snippet() returns NULL there).
    private static let ftsSchema = "CREATE VIRTUAL TABLE segments_fts USING fts5(text)"

    init(url: URL, create: Bool) throws {
        // Foundation may normalize /private/var back to /var. SQLite's
        // NOFOLLOW flag checks every component, so use the physical parent.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw DataHoarderArchiveError.catalogUnavailable
        }
        let path = String(cString: parent) + "/" + url.lastPathComponent
        free(parent)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
            | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            let error = databaseError()
            sqlite3_close(database)
            database = nil
            throw error
        }
        do {
            guard sqlite3_busy_timeout(database, 2_000) == SQLITE_OK else { throw databaseError() }
            try execute("PRAGMA foreign_keys = ON")
            if !create {
                var version = try validateSchema(allowLegacy: true)
                if version == 1 {
                    try transaction {
                        if try validateSchema(allowLegacy: true) == 1 {
                            try execute(Self.removedSchema)
                            try execute("PRAGMA user_version = 2")
                        }
                    }
                    version = 2
                }
                if version == 2 {
                    try transaction {
                        if try validateSchema(allowLegacy: true) == 2 {
                            try migrateToVersion3()
                        }
                    }
                }
            }
            try execute("PRAGMA journal_mode = DELETE")
            if create { try createSchema() }
            try validateSchema()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    func close() {
        sqlite3_close(database)
        database = nil
    }

    /// Re-checks user_version and the schema on an already-open handle —
    /// the archive caches one connection, so the per-call integrity the
    /// open path used to pay for with a fresh `sqlite3_open` happens here
    /// instead. An external `PRAGMA user_version` bump is still caught:
    /// SQLite notices the file's change counter moved.
    func checkIntegrity() throws {
        _ = try validateSchema()
    }

    // MARK: - Records

    private static let recordColumns = """
        id, name, source_path, byte_count, imported_at, source_modified_at,
        provider, session_id, project, model, title, started_at,
        last_activity_at, segment_count, capture_state
        """

    private func readRecord(_ statement: OpaquePointer?) throws -> ArchiveRecord? {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let id = text(statement, 0), let name = text(statement, 1),
                  let sourcePath = text(statement, 2) else { throw corrupt() }
            func date(_ column: Int32) -> Date? {
                sqlite3_column_type(statement, column) == SQLITE_NULL
                    ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
            }
            let record = ArchiveRecord(
                id: id, name: name, sourcePath: sourcePath,
                byteCount: sqlite3_column_int64(statement, 3),
                importedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)),
                sourceModifiedAt: date(5),
                provider: text(statement, 6), sessionID: text(statement, 7),
                project: text(statement, 8), model: text(statement, 9),
                title: text(statement, 10), startedAt: date(11),
                lastActivityAt: date(12),
                segmentCount: Int(sqlite3_column_int64(statement, 13)),
                captureState: CaptureState(rawValue: text(statement, 14) ?? "") ?? .snapshot)
            guard Self.valid(record) else { throw corrupt() }
            return record
        case SQLITE_DONE:
            return nil
        default:
            throw databaseError()
        }
    }

    func records() throws -> [ArchiveRecord] {
        let statement = try prepare("""
        SELECT \(Self.recordColumns)
        FROM records ORDER BY imported_at DESC, name COLLATE NOCASE ASC
        """)
        defer { sqlite3_finalize(statement) }
        var result: [ArchiveRecord] = []
        while let record = try readRecord(statement) { result.append(record) }
        return result
    }

    func record(id: String) throws -> ArchiveRecord? {
        let statement = try prepare("SELECT \(Self.recordColumns) FROM records WHERE id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        return try readRecord(statement)
    }

    /// Every record matching a loose name/title/project/source substring —
    /// the metadata half of archive search, complementing the FTS index.
    func recordsMatchingMetadata(_ needle: String, limit: Int = 50) throws -> [ArchiveRecord] {
        let statement = try prepare("""
        SELECT \(Self.recordColumns) FROM records
        WHERE name LIKE ?1 ESCAPE '\\' OR source_path LIKE ?1 ESCAPE '\\'
           OR title LIKE ?1 ESCAPE '\\' OR project LIKE ?1 ESCAPE '\\'
        ORDER BY imported_at DESC LIMIT ?2
        """)
        defer { sqlite3_finalize(statement) }
        let pattern = "%" + needle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        try bind(pattern, to: statement, at: 1)
        guard sqlite3_bind_int64(statement, 2, Int64(limit)) == SQLITE_OK else { throw databaseError() }
        var result: [ArchiveRecord] = []
        while let record = try readRecord(statement) { result.append(record) }
        return result
    }

    func insert(_ record: ArchiveRecord) throws {
        guard Self.valid(record) else { throw corrupt() }
        let statement = try prepare("""
        INSERT INTO records(\(Self.recordColumns))
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
        """)
        defer { sqlite3_finalize(statement) }
        try bind(record, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        // One-shot records carry their whole content in the object named by
        // the record id. Backfill that segment lazily here so imports,
        // restores and pre-v3 manifest merges all end up chained without a
        // second write path. A real ordinal-0 row wins the IGNORE — and a
        // live record (which owns no whole-content object) gets nothing.
        if record.captureState == .snapshot {
            let segment = try prepare("""
            INSERT OR IGNORE INTO segments(record_id, ordinal, hash, byte_offset, byte_length, captured_at)
            VALUES(?1, 0, ?1, 0, ?2, ?3)
            """)
            defer { sqlite3_finalize(segment) }
            try bind(record.id, to: segment, at: 1)
            guard sqlite3_bind_int64(segment, 2, record.byteCount) == SQLITE_OK,
                  sqlite3_bind_double(segment, 3, record.importedAt.timeIntervalSinceReferenceDate) == SQLITE_OK else {
                throw databaseError()
            }
            guard sqlite3_step(segment) == SQLITE_DONE else { throw databaseError() }
        }
        let count = try prepare("""
        UPDATE records SET segment_count = (SELECT COUNT(*) FROM segments WHERE record_id = ?1)
        WHERE id = ?1
        """)
        defer { sqlite3_finalize(count) }
        try bind(record.id, to: count, at: 1)
        guard sqlite3_step(count) == SQLITE_DONE else { throw databaseError() }
        try markRemovalComplete(id: record.id)
    }

    /// Live-capture metadata learned from fresh lines; nil leaves the column.
    func updateRecordMetadata(
        id: String, provider: String?, sessionID: String?, project: String?,
        model: String?, title: String?, startedAt: Date?, lastActivityAt: Date?,
        captureState: CaptureState? = nil
    ) throws {
        let statement = try prepare("""
        UPDATE records SET
            -- 'other' means "unrecognised content", not an identification:
            -- it must never displace a provider an earlier segment named.
            provider = CASE WHEN ?2 = 'other' AND provider IS NOT NULL
                            THEN provider ELSE COALESCE(?2, provider) END,
            session_id = COALESCE(?3, session_id),
            project = COALESCE(?4, project),
            model = COALESCE(?5, model),
            title = COALESCE(?6, title),
            started_at = COALESCE(?7, started_at),
            last_activity_at = COALESCE(?8, last_activity_at),
            capture_state = COALESCE(?9, capture_state)
        WHERE id = ?1
        """)
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try bindOptional(provider, to: statement, at: 2)
        try bindOptional(sessionID, to: statement, at: 3)
        try bindOptional(project, to: statement, at: 4)
        try bindOptional(model, to: statement, at: 5)
        try bindOptional(title, to: statement, at: 6)
        try bindOptional(startedAt?.timeIntervalSinceReferenceDate, to: statement, at: 7)
        try bindOptional(lastActivityAt?.timeIntervalSinceReferenceDate, to: statement, at: 8)
        try bindOptional(captureState?.rawValue, to: statement, at: 9)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func addBytes(id: String, delta: Int64, lastActivityAt: Date?) throws {
        let statement = try prepare("""
        UPDATE records SET
            byte_count = byte_count + ?2,
            last_activity_at = COALESCE(?3, last_activity_at)
        WHERE id = ?1
        """)
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        guard sqlite3_bind_int64(statement, 2, delta) == SQLITE_OK else { throw databaseError() }
        try bindOptional(lastActivityAt?.timeIntervalSinceReferenceDate, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    /// A fresh segment means the record is capturing again — unless it is
    /// already `.gap`, which is a historical marker, not a transient state.
    func markLiveUnlessGap(id: String) throws {
        let statement = try prepare("UPDATE records SET capture_state = 'live' WHERE id = ?1 AND capture_state != 'gap'")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func setCaptureState(id: String, state: CaptureState) throws {
        let statement = try prepare("UPDATE records SET capture_state = ?2 WHERE id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try bind(state.rawValue, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    // MARK: - Segments

    func segments(recordID: String) throws -> [ArchiveSegment] {
        let statement = try prepare("""
        SELECT rowid, record_id, ordinal, hash, byte_offset, byte_length, captured_at, note
        FROM segments WHERE record_id = ?1 ORDER BY ordinal
        """)
        defer { sqlite3_finalize(statement) }
        try bind(recordID, to: statement, at: 1)
        var result: [ArchiveSegment] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let record = text(statement, 1), let hash = text(statement, 3) else { throw corrupt() }
                result.append(ArchiveSegment(
                    rowid: sqlite3_column_int64(statement, 0),
                    recordID: record,
                    ordinal: Int(sqlite3_column_int64(statement, 2)),
                    hash: hash,
                    byteOffset: sqlite3_column_int64(statement, 4),
                    byteLength: sqlite3_column_int64(statement, 5),
                    capturedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)),
                    note: text(statement, 7)))
            case SQLITE_DONE:
                return result
            default:
                throw databaseError()
            }
        }
    }

    /// Appends a segment row and returns its rowid (the FTS key).
    @discardableResult
    func insertSegment(_ segment: ArchiveSegment) throws -> Int64 {
        let statement = try prepare("""
        INSERT INTO segments(record_id, ordinal, hash, byte_offset, byte_length, captured_at, note)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """)
        defer { sqlite3_finalize(statement) }
        try bind(segment.recordID, to: statement, at: 1)
        guard sqlite3_bind_int64(statement, 2, Int64(segment.ordinal)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, segment.byteOffset) == SQLITE_OK,
              sqlite3_bind_int64(statement, 5, segment.byteLength) == SQLITE_OK,
              sqlite3_bind_double(statement, 6, segment.capturedAt.timeIntervalSinceReferenceDate) == SQLITE_OK else {
            throw databaseError()
        }
        try bind(segment.hash, to: statement, at: 3)
        try bindOptional(segment.note, to: statement, at: 7)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        let count = try prepare("""
        UPDATE records SET segment_count = (SELECT COUNT(*) FROM segments WHERE record_id = ?1)
        WHERE id = ?1
        """)
        defer { sqlite3_finalize(count) }
        try bind(segment.recordID, to: count, at: 1)
        guard sqlite3_step(count) == SQLITE_DONE else { throw databaseError() }
        return sqlite3_last_insert_rowid(database)
    }

    /// Removes a record's segment rows and FTS index entries; returns the
    /// deleted rows so the caller can unlink their (possibly shared) objects.
    func deleteSegments(recordID: String) throws -> [ArchiveSegment] {
        let removed = try segments(recordID: recordID)
        for segment in removed { try ftsDelete(rowid: segment.rowid) }
        let statement = try prepare("DELETE FROM segments WHERE record_id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(recordID, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        return removed
    }

    /// Other records still referencing this object hash (dedup shares objects).
    func segmentRefs(hash: String, excludingRecordID: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM segments WHERE hash = ?1 AND record_id != ?2")
        defer { sqlite3_finalize(statement) }
        try bind(hash, to: statement, at: 1)
        try bind(excludingRecordID, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Capture bookkeeping

    func captureState(path: String) throws -> CaptureStateRow? {
        let statement = try prepare("""
        SELECT path, source_id, inode, size, mtime, offset, record_id
        FROM capture_state WHERE path = ?1
        """)
        defer { sqlite3_finalize(statement) }
        try bind(path, to: statement, at: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let storedPath = text(statement, 0), let sourceID = text(statement, 1) else { throw corrupt() }
            return CaptureStateRow(
                path: storedPath, sourceID: sourceID,
                inode: sqlite3_column_int64(statement, 2),
                size: sqlite3_column_int64(statement, 3),
                mtime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                offset: sqlite3_column_int64(statement, 5),
                recordID: text(statement, 6))
        case SQLITE_DONE: return nil
        default: throw databaseError()
        }
    }

    func upsertCaptureState(_ row: CaptureStateRow) throws {
        let statement = try prepare("""
        INSERT INTO capture_state(path, source_id, inode, size, mtime, offset, record_id)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(path) DO UPDATE SET
            source_id = excluded.source_id, inode = excluded.inode,
            size = excluded.size, mtime = excluded.mtime,
            offset = excluded.offset, record_id = excluded.record_id
        """)
        defer { sqlite3_finalize(statement) }
        try bind(row.path, to: statement, at: 1)
        try bind(row.sourceID, to: statement, at: 2)
        guard sqlite3_bind_int64(statement, 3, row.inode) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, row.size) == SQLITE_OK,
              sqlite3_bind_double(statement, 5, row.mtime.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int64(statement, 6, row.offset) == SQLITE_OK else {
            throw databaseError()
        }
        try bindOptional(row.recordID, to: statement, at: 7)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    /// Backlog seeding only: inserts a tracking row when the path has
    /// none, and leaves a live row — one a racing capture just wrote —
    /// untouched. ``upsertCaptureState`` here would roll the offset to
    /// EOF over bytes a debounced capture already handled.
    func seedCaptureState(_ row: CaptureStateRow) throws {
        let statement = try prepare("""
        INSERT OR IGNORE INTO capture_state(path, source_id, inode, size, mtime, offset, record_id)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """)
        defer { sqlite3_finalize(statement) }
        try bind(row.path, to: statement, at: 1)
        try bind(row.sourceID, to: statement, at: 2)
        guard sqlite3_bind_int64(statement, 3, row.inode) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, row.size) == SQLITE_OK,
              sqlite3_bind_double(statement, 5, row.mtime.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_int64(statement, 6, row.offset) == SQLITE_OK else {
            throw databaseError()
        }
        try bindOptional(row.recordID, to: statement, at: 7)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func removeCaptureState(path: String) throws {
        let statement = try prepare("DELETE FROM capture_state WHERE path = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(path, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    /// Every tracked path for one source — the rescan diffs this against the
    /// filesystem to notice files removed while the engine was off.
    func capturePaths(sourceID: String) throws -> Set<String> {
        let statement = try prepare("SELECT path FROM capture_state WHERE source_id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(sourceID, to: statement, at: 1)
        var result = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let path = text(statement, 0) { result.insert(path) }
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    func recordCaptureFailure(path: String, sourceID: String, error: String) throws {
        let statement = try prepare("""
        INSERT INTO capture_failures(path, source_id, at, error) VALUES(?1, ?2, ?3, ?4)
        """)
        defer { sqlite3_finalize(statement) }
        try bind(path, to: statement, at: 1)
        try bind(sourceID, to: statement, at: 2)
        guard sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970) == SQLITE_OK else {
            throw databaseError()
        }
        try bind(String(error.prefix(500)), to: statement, at: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        // A permanently-unreadable live file would otherwise log a row per
        // rescan — keep the newest 1,000 and let the count carry the rest.
        let prune = try prepare("""
        DELETE FROM capture_failures WHERE id NOT IN (
            SELECT id FROM capture_failures ORDER BY id DESC LIMIT 1000)
        """)
        defer { sqlite3_finalize(prune) }
        guard sqlite3_step(prune) == SQLITE_DONE else { throw databaseError() }
    }

    func captureFailures(limit: Int = 100) throws -> [CaptureFailure] {
        let statement = try prepare("""
        SELECT id, path, source_id, at, error FROM capture_failures
        ORDER BY id DESC LIMIT ?1
        """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, Int64(limit)) == SQLITE_OK else { throw databaseError() }
        var result: [CaptureFailure] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let path = text(statement, 1), let sourceID = text(statement, 2),
                      let error = text(statement, 4) else { throw corrupt() }
                result.append(CaptureFailure(
                    id: sqlite3_column_int64(statement, 0), path: path, sourceID: sourceID,
                    at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    error: error))
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    func captureFailureCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM capture_failures")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - FTS index

    func ftsInsert(rowid: Int64, text: String) throws {
        let statement = try prepare("INSERT INTO segments_fts(rowid, text) VALUES(?1, ?2)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, rowid) == SQLITE_OK else { throw databaseError() }
        try bind(text, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func ftsDelete(rowid: Int64) throws {
        let statement = try prepare("DELETE FROM segments_fts WHERE rowid = ?1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, rowid) == SQLITE_OK else { throw databaseError() }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    /// Segments whose objects still need indexing — the background backfill
    /// after a v2→v3 migration or an interrupted index pass.
    func unindexedSegments(limit: Int) throws -> [ArchiveSegment] {
        let statement = try prepare("""
        SELECT rowid, record_id, ordinal, hash, byte_offset, byte_length, captured_at, note
        FROM segments
        WHERE rowid NOT IN (SELECT rowid FROM segments_fts)
        ORDER BY rowid LIMIT ?1
        """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, Int64(limit)) == SQLITE_OK else { throw databaseError() }
        var result: [ArchiveSegment] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let recordID = text(statement, 1), let hash = text(statement, 3) else { throw corrupt() }
                result.append(ArchiveSegment(
                    rowid: sqlite3_column_int64(statement, 0),
                    recordID: recordID,
                    ordinal: Int(sqlite3_column_int64(statement, 2)),
                    hash: hash,
                    byteOffset: sqlite3_column_int64(statement, 4),
                    byteLength: sqlite3_column_int64(statement, 5),
                    capturedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)),
                    note: text(statement, 7)))
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    func ftsProgress() throws -> (indexed: Int, total: Int) {
        let total = try prepare("SELECT COUNT(*) FROM segments")
        defer { sqlite3_finalize(total) }
        guard sqlite3_step(total) == SQLITE_ROW else { throw databaseError() }
        let indexed = try prepare("SELECT COUNT(*) FROM segments_fts")
        defer { sqlite3_finalize(indexed) }
        guard sqlite3_step(indexed) == SQLITE_ROW else { throw databaseError() }
        return (Int(sqlite3_column_int64(indexed, 0)), Int(sqlite3_column_int64(total, 0)))
    }

    /// One page of best-ranked records for a prepared MATCH expression.
    /// `min(bm25)` picks each record's best segment row; SQLite's bare-column
    /// rule puts that row's record_id in the result.
    func ftsSearch(
        match: String, providers: [String], project: String?,
        from: Date?, to: Date?, states: [String],
        limit: Int, offset: Int
    ) throws -> [(recordID: String, rank: Double)] {
        enum Bound { case text(String); case date(Date) }
        var clause = "segments_fts MATCH ?1"
        var binds: [(Int32, Bound)] = []
        var next: Int32 = 2
        func slotList(_ count: Int) -> String {
            (0..<count).map { "?\(next + Int32($0))" }.joined(separator: ",")
        }
        if !providers.isEmpty {
            clause += " AND r.provider IN (\(slotList(providers.count)))"
            for (offset, provider) in providers.enumerated() {
                binds.append((next + Int32(offset), .text(provider)))
            }
            next += Int32(providers.count)
        }
        if let project {
            clause += " AND r.project = ?\(next)"
            binds.append((next, .text(project)))
            next += 1
        }
        if let from {
            clause += " AND COALESCE(r.last_activity_at, r.imported_at) >= ?\(next)"
            binds.append((next, .date(from)))
            next += 1
        }
        if let to {
            clause += " AND COALESCE(r.last_activity_at, r.imported_at) <= ?\(next)"
            binds.append((next, .date(to)))
            next += 1
        }
        if !states.isEmpty {
            clause += " AND r.capture_state IN (\(slotList(states.count)))"
            for (offset, state) in states.enumerated() {
                binds.append((next + Int32(offset), .text(state)))
            }
            next += Int32(states.count)
        }
        // bm25 is only legal where the FTS table is in scope — never inside
        // an aggregate or across a subquery boundary — so rank per segment
        // and fold to best-per-record while stepping (rows arrive ranked).
        let sql = """
        SELECT s.record_id, bm25(segments_fts) AS rank
        FROM segments_fts
        JOIN segments s ON s.rowid = segments_fts.rowid
        JOIN records r ON r.id = s.record_id
        WHERE \(clause)
        ORDER BY rank, s.record_id
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(match, to: statement, at: 1)
        for (at, value) in binds {
            switch value {
            case .text(let text):
                try bind(text, to: statement, at: at)
            case .date(let date):
                guard sqlite3_bind_double(statement, at, date.timeIntervalSinceReferenceDate) == SQLITE_OK else {
                    throw databaseError()
                }
            }
        }
        var result: [(recordID: String, rank: Double)] = []
        var seen = Set<String>()
        var skipped = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let recordID = text(statement, 0) else { throw corrupt() }
                guard seen.insert(recordID).inserted else { continue }
                if skipped < offset { skipped += 1; continue }
                result.append((recordID, sqlite3_column_double(statement, 1)))
                if result.count >= limit { return result }
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    /// Up to `limit` highlighted snippets for one record, best segments first.
    func ftsSnippets(match: String, recordID: String, limit: Int = 2) throws -> [String] {
        let statement = try prepare("""
        SELECT snippet(segments_fts, 0, '«', '»', '…', 12)
        FROM segments_fts
        JOIN segments s ON s.rowid = segments_fts.rowid
        WHERE segments_fts MATCH ?1 AND s.record_id = ?2
        ORDER BY bm25(segments_fts) LIMIT ?3
        """)
        defer { sqlite3_finalize(statement) }
        try bind(match, to: statement, at: 1)
        try bind(recordID, to: statement, at: 2)
        guard sqlite3_bind_int64(statement, 3, Int64(limit)) == SQLITE_OK else { throw databaseError() }
        var result: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let snippet = text(statement, 0) { result.append(snippet) }
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    func distinctProjects() throws -> [String] {
        let statement = try prepare("""
        SELECT DISTINCT project FROM records
        WHERE project IS NOT NULL AND project != '' ORDER BY project COLLATE NOCASE
        """)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let project = text(statement, 0) { result.append(project) }
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    // MARK: - Trash

    func trashedRecords(id: String? = nil) throws -> [ArchiveRecord] {
        let statement = try prepare("SELECT id, record_json FROM removed_records WHERE record_json IS NOT NULL"
            + (id == nil ? " ORDER BY id" : " AND id = ?1"))
        defer { sqlite3_finalize(statement) }
        if let id { try bind(id, to: statement, at: 1) }
        var result: [ArchiveRecord] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let id = text(statement, 0), let json = text(statement, 1),
                  let value = try? JSONDecoder().decode(ArchiveRecord.self, from: Data(json.utf8)),
                  value.id == id, Self.valid(value) else { throw corrupt() }
            result.append(value)
        }
    }

    /// Stores the record as given — callers stamp `trashedAt` themselves so
    /// the retention clock reflects the event they are recording.
    func trash(_ record: ArchiveRecord) throws {
        guard Self.valid(record) else { throw corrupt() }
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        let statement = try prepare("INSERT INTO removed_records(id, record_json) VALUES(?1, ?2) ON CONFLICT(id) DO UPDATE SET record_json = excluded.record_json")
        defer { sqlite3_finalize(statement) }
        try bind(record.id, to: statement, at: 1)
        try bind(json, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        let deletion = try prepare("DELETE FROM records WHERE id = ?1")
        defer { sqlite3_finalize(deletion) }
        try bind(record.id, to: deletion, at: 1)
        guard sqlite3_step(deletion) == SQLITE_DONE else { throw databaseError() }
        // Segments and their FTS rows stay: restore needs the chain, and the
        // join against `records` keeps a trashed record out of search anyway.
    }

    /// Keep the ID after restore or purge so legacy metadata cannot undo intent.
    func markRemovalComplete(id: String) throws {
        let statement = try prepare("UPDATE removed_records SET record_json = NULL WHERE id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func hasRemoval(id: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM removed_records WHERE id = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError()
        }
    }

    func mergeLegacy(_ records: [ArchiveRecord], trashed: [ArchiveRecord] = [],
                     segments: [ArchiveSegment] = [], fingerprint: String, signature: String) throws {
        try transaction {
            let manifestSegments = Dictionary(grouping: segments, by: \.recordID)
            for record in records + trashed {
                // Explicit manifest segment rows land first so the insert's
                // own backfill stands down (IGNORE loses to the real chain).
                for segment in (manifestSegments[record.id] ?? []).sorted(by: { $0.ordinal < $1.ordinal }) {
                    try self.insertSegmentIfAbsent(segment)
                }
            }
            for record in records {
                if try self.hasRemoval(id: record.id) { continue }
                if let existing = try self.record(id: record.id) {
                    guard existing == record else { throw DataHoarderArchiveError.corruptManifest }
                } else {
                    try self.insert(record)
                }
            }
            for record in trashed {
                if try self.hasRemoval(id: record.id) { continue }
                guard try self.record(id: record.id) == nil else { throw self.corrupt() }
                // Migration is when this catalog's trash received them — the
                // retention clock starts here, not at a guessed earlier date.
                try self.trash(record.trashedAt == nil ? record.markedTrashed(at: Date()) : record)
            }
            try self.setMetadata(key: "legacy_manifest_sha256", value: fingerprint)
            try self.setMetadata(key: "legacy_manifest_signature", value: signature)
        }
    }

    private func insertSegmentIfAbsent(_ segment: ArchiveSegment) throws {
        let statement = try prepare("""
        INSERT OR IGNORE INTO segments(record_id, ordinal, hash, byte_offset, byte_length, captured_at, note)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """)
        defer { sqlite3_finalize(statement) }
        try bind(segment.recordID, to: statement, at: 1)
        guard sqlite3_bind_int64(statement, 2, Int64(segment.ordinal)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, segment.byteOffset) == SQLITE_OK,
              sqlite3_bind_int64(statement, 5, segment.byteLength) == SQLITE_OK,
              sqlite3_bind_double(statement, 6, segment.capturedAt.timeIntervalSinceReferenceDate) == SQLITE_OK else {
            throw databaseError()
        }
        try bind(segment.hash, to: statement, at: 3)
        try bindOptional(segment.note, to: statement, at: 7)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func legacyFingerprint() throws -> String? {
        try metadata(key: "legacy_manifest_sha256")
    }

    func legacySignature() throws -> String? {
        try metadata(key: "legacy_manifest_signature")
    }

    func metadata(key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?1")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return text(statement, 0)
        case SQLITE_DONE: return nil
        default: throw databaseError()
        }
    }

    func setMetadata(key: String, value: String) throws {
        let statement = try prepare("""
        INSERT INTO metadata(key, value) VALUES(?1, ?2)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """)
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1)
        try bind(value, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    static func valid(_ record: ArchiveRecord) -> Bool {
        validID(record.id) && !record.name.contains("\0") && !record.sourcePath.contains("\0")
            && record.byteCount >= 0 && record.segmentCount >= 0
            && record.importedAt.timeIntervalSinceReferenceDate.isFinite
            && (record.sourceModifiedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && (record.startedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && (record.lastActivityAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && !(record.provider?.contains("\0") ?? false)
            && !(record.sessionID?.contains("\0") ?? false)
            && !(record.project?.contains("\0") ?? false)
            && !(record.model?.contains("\0") ?? false)
            && !(record.title?.contains("\0") ?? false)
    }

    static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    /// v2 → v3 inside one transaction: the new record columns arrive as
    /// ALTERs (their appended text is exactly what `recordsSchema` declares),
    /// every existing record gains its single whole-object segment, and the
    /// capture + FTS tables start empty.
    private func migrateToVersion3() throws {
        for column in [
            "provider TEXT", "session_id TEXT", "project TEXT", "model TEXT",
            "title TEXT", "started_at REAL", "last_activity_at REAL",
            "segment_count INTEGER NOT NULL DEFAULT 0 CHECK(segment_count >= 0)",
            "capture_state TEXT NOT NULL DEFAULT 'snapshot'",
        ] {
            try execute("ALTER TABLE records ADD COLUMN \(column)")
        }
        try execute(Self.segmentsSchema)
        try execute("""
        INSERT INTO segments(record_id, ordinal, hash, byte_offset, byte_length, captured_at)
        SELECT id, 0, id, 0, byte_count, imported_at FROM records
        """)
        try execute("""
        UPDATE records SET segment_count = (SELECT COUNT(*) FROM segments WHERE record_id = records.id)
        """)
        try execute(Self.captureStateSchema)
        try execute(Self.captureFailuresSchema)
        try execute(Self.ftsSchema)
        try execute("PRAGMA user_version = 3")
    }

    private func createSchema() throws {
        try execute(Self.recordsSchema)
        try execute(Self.metadataSchema)
        try execute(Self.removedSchema)
        try execute(Self.segmentsSchema)
        try execute(Self.captureStateSchema)
        try execute(Self.captureFailuresSchema)
        try execute(Self.ftsSchema)
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    @discardableResult
    private func validateSchema(allowLegacy: Bool = false) throws -> Int32 {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        let version = sqlite3_column_int(statement, 0)
        let legacyOK = allowLegacy && (version == 1 || version == 2)
        guard version == Self.schemaVersion || legacyOK else { throw corrupt() }
        let schema = try prepare("""
        SELECT name, type, sql FROM sqlite_master
        WHERE name IN ('records', 'metadata', 'removed_records', 'segments',
                       'capture_state', 'capture_failures', 'segments_fts')
           OR type = 'trigger'
        """)
        defer { sqlite3_finalize(schema) }
        var expected: [String: String] = [
            // v1 and v2 share the records shape; v3's ALTERs append columns.
            "records": version >= 3 ? Self.recordsSchema : Self.recordsSchemaV2,
            "metadata": Self.metadataSchema,
        ]
        if version >= 2 { expected["removed_records"] = Self.removedSchema }
        if version >= 3 {
            expected["segments"] = Self.segmentsSchema
            expected["capture_state"] = Self.captureStateSchema
            expected["capture_failures"] = Self.captureFailuresSchema
            expected["segments_fts"] = Self.ftsSchema
        }
        var names = Set<String>()
        func normalized(_ sql: String) -> String { sql.filter { !$0.isWhitespace }.lowercased() }
        while true {
            let result = sqlite3_step(schema)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let name = text(schema, 0), text(schema, 1) == "table",
                  let sql = text(schema, 2), let required = expected[name],
                  normalized(sql) == normalized(required) else { throw corrupt() }
            names.insert(name)
        }
        guard names == Set(expected.keys) else { throw corrupt() }
        return version
    }

    private func bind(_ record: ArchiveRecord, to statement: OpaquePointer?) throws {
        try bind(record.id, to: statement, at: 1)
        try bind(record.name, to: statement, at: 2)
        try bind(record.sourcePath, to: statement, at: 3)
        guard sqlite3_bind_int64(statement, 4, record.byteCount) == SQLITE_OK,
              sqlite3_bind_double(statement, 5, record.importedAt.timeIntervalSinceReferenceDate) == SQLITE_OK else {
            throw databaseError()
        }
        try bindOptional(record.sourceModifiedAt?.timeIntervalSinceReferenceDate, to: statement, at: 6)
        try bindOptional(record.provider, to: statement, at: 7)
        try bindOptional(record.sessionID, to: statement, at: 8)
        try bindOptional(record.project, to: statement, at: 9)
        try bindOptional(record.model, to: statement, at: 10)
        try bindOptional(record.title, to: statement, at: 11)
        try bindOptional(record.startedAt?.timeIntervalSinceReferenceDate, to: statement, at: 12)
        try bindOptional(record.lastActivityAt?.timeIntervalSinceReferenceDate, to: statement, at: 13)
        guard sqlite3_bind_int64(statement, 14, Int64(record.segmentCount)) == SQLITE_OK else {
            throw databaseError()
        }
        try bind(record.captureState.rawValue, to: statement, at: 15)
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, Int32(value.utf8.count), Self.transient)
        }
        guard result == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func bindOptional(_ value: String?, to statement: OpaquePointer?, at index: Int32) throws {
        if let value {
            try bind(value, to: statement, at: index)
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw databaseError() }
        }
    }

    private func bindOptional(_ value: TimeInterval?, to statement: OpaquePointer?, at index: Int32) throws {
        if let value {
            guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw databaseError() }
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw databaseError() }
        }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(data: Data(bytes: pointer, count: count), encoding: .utf8)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func corrupt() -> DataHoarderArchiveError { .corruptManifest }

    private func databaseError() -> DataHoarderArchiveError {
        let code = sqlite3_extended_errcode(database) & 0xff
        switch code {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .catalogBusy
        case SQLITE_FULL, SQLITE_READONLY, SQLITE_IOERR, SQLITE_CANTOPEN:
            return .catalogUnavailable
        default:
            return .corruptManifest
        }
    }
}
