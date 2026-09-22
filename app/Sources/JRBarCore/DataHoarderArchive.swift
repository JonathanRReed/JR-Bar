import CryptoKit
import Darwin
import Foundation

/// How a record's content arrived (catalog v3). `snapshot` is the one-shot
/// import every pre-v3 record migrates to; `live` is being captured; `closed`
/// means the source stopped changing; `gap` marks a detected discontinuity —
/// the archive says so rather than presenting a partial record as whole.
public enum CaptureState: String, Codable, Sendable, Equatable, CaseIterable {
    case snapshot
    case live
    case closed
    case gap
}

public struct ArchiveRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let sourcePath: String
    public let byteCount: Int64
    public let importedAt: Date
    public let sourceModifiedAt: Date?
    /// "claude" / "codex" / "other" — nil on records the probe never classified.
    public let provider: String?
    public let sessionID: String?
    /// The session's working directory (or repo name) when the transcript says.
    public let project: String?
    public let model: String?
    /// First user prompt, only ever populated when full-content consent is on.
    public let title: String?
    public let startedAt: Date?
    public let lastActivityAt: Date?
    public let segmentCount: Int
    public let captureState: CaptureState
    /// When the record entered the trash — only stamped inside
    /// `removed_records.record_json`; live rows always decode nil.
    public let trashedAt: Date?

    public init(id: String, name: String, sourcePath: String, byteCount: Int64,
                importedAt: Date, sourceModifiedAt: Date?,
                provider: String? = nil, sessionID: String? = nil,
                project: String? = nil, model: String? = nil, title: String? = nil,
                startedAt: Date? = nil, lastActivityAt: Date? = nil,
                segmentCount: Int = 1, captureState: CaptureState = .snapshot,
                trashedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.byteCount = byteCount
        self.importedAt = importedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.provider = provider
        self.sessionID = sessionID
        self.project = project
        self.model = model
        self.title = title
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.segmentCount = segmentCount
        self.captureState = captureState
        self.trashedAt = trashedAt
    }

    /// `trashedAt` is trash-event metadata, not record identity — the same
    /// record is equal before and after its bin timestamp is stamped.
    public static func == (lhs: ArchiveRecord, rhs: ArchiveRecord) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.sourcePath == rhs.sourcePath
            && lhs.byteCount == rhs.byteCount && lhs.importedAt == rhs.importedAt
            && lhs.sourceModifiedAt == rhs.sourceModifiedAt && lhs.provider == rhs.provider
            && lhs.sessionID == rhs.sessionID && lhs.project == rhs.project
            && lhs.model == rhs.model && lhs.title == rhs.title
            && lhs.startedAt == rhs.startedAt && lhs.lastActivityAt == rhs.lastActivityAt
            && lhs.segmentCount == rhs.segmentCount && lhs.captureState == rhs.captureState
    }

    /// A copy lifted out of the trash — same identity, stamp cleared.
    /// Re-importing identical bytes revives the tombstoned record rather
    /// than minting a live twin the retention sweep would gut.
    public func restored() -> ArchiveRecord {
        ArchiveRecord(id: id, name: name, sourcePath: sourcePath,
                      byteCount: byteCount, importedAt: importedAt,
                      sourceModifiedAt: sourceModifiedAt, provider: provider,
                      sessionID: sessionID, project: project, model: model,
                      title: title, startedAt: startedAt,
                      lastActivityAt: lastActivityAt, segmentCount: segmentCount,
                      captureState: captureState, trashedAt: nil)
    }

    /// A copy stamped for the trash table — the retention sweep reads
    /// `trashedAt`, so entries written before the field existed stay put.
    public func markedTrashed(at date: Date) -> ArchiveRecord {
        ArchiveRecord(id: id, name: name, sourcePath: sourcePath,
                      byteCount: byteCount, importedAt: importedAt,
                      sourceModifiedAt: sourceModifiedAt, provider: provider,
                      sessionID: sessionID, project: project, model: model,
                      title: title, startedAt: startedAt,
                      lastActivityAt: lastActivityAt, segmentCount: segmentCount,
                      captureState: captureState, trashedAt: date)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourcePath, byteCount, importedAt, sourceModifiedAt
        case provider, sessionID, project, model, title, startedAt, lastActivityAt
        case segmentCount, captureState, trashedAt
    }

    /// Tolerant decode: records written before v3 (removed_records JSON,
    /// v1/v2 manifests) lack the capture fields and read as one-segment
    /// snapshots — exactly what the migration writes for them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        byteCount = try c.decode(Int64.self, forKey: .byteCount)
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        sourceModifiedAt = try? c.decodeIfPresent(Date.self, forKey: .sourceModifiedAt)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
        project = try? c.decodeIfPresent(String.self, forKey: .project)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        lastActivityAt = try? c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        segmentCount = (try? c.decodeIfPresent(Int.self, forKey: .segmentCount)) ?? 1
        captureState = (try? c.decodeIfPresent(CaptureState.self, forKey: .captureState)) ?? .snapshot
        trashedAt = try? c.decodeIfPresent(Date.self, forKey: .trashedAt)
    }
}

/// One slice of a record's content. `byteOffset` is where in the source file
/// the capture began (provenance — 0 for snapshots and gap restarts);
/// `byteLength` is the stored object's size, so `hash` + `byteLength` verify
/// the object without opening it. `rowid` is the catalog's FTS key.
public struct ArchiveSegment: Codable, Sendable, Equatable, Identifiable {
    public var rowid: Int64
    public var recordID: String
    public var ordinal: Int
    public var hash: String
    public var byteOffset: Int64
    public var byteLength: Int64
    public var capturedAt: Date
    /// e.g. "gap: source rewritten" — why a new chain link starts over.
    public var note: String?

    public var id: String { "\(recordID)#\(ordinal)" }

    public init(rowid: Int64 = 0, recordID: String, ordinal: Int, hash: String,
                byteOffset: Int64, byteLength: Int64, capturedAt: Date, note: String? = nil) {
        self.rowid = rowid
        self.recordID = recordID
        self.ordinal = ordinal
        self.hash = hash
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.capturedAt = capturedAt
        self.note = note
    }
}

/// The capture engine's persisted per-file position (catalog v3
/// `capture_state`). `recordID` is nil on files position-seeded before any
/// content was stored — pre-existing backlog waits for explicit import.
public struct CaptureStateRow: Sendable, Equatable {
    public var path: String
    public var sourceID: String
    public var inode: Int64
    public var size: Int64
    public var mtime: Date
    public var offset: Int64
    public var recordID: String?

    public init(path: String, sourceID: String, inode: Int64, size: Int64,
                mtime: Date, offset: Int64, recordID: String?) {
        self.path = path
        self.sourceID = sourceID
        self.inode = inode
        self.size = size
        self.mtime = mtime
        self.offset = offset
        self.recordID = recordID
    }
}

public struct CaptureFailure: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let path: String
    public let sourceID: String
    public let at: Date
    public let error: String

    public init(id: Int64 = 0, path: String, sourceID: String, at: Date, error: String) {
        self.id = id
        self.path = path
        self.sourceID = sourceID
        self.at = at
        self.error = error
    }
}

/// The search pane's filter set; empty means unfiltered on that axis.
public struct ArchiveSearchFilter: Sendable, Equatable {
    public var providers: Set<String> = []
    public var project: String?
    public var from: Date?
    public var to: Date?
    public var states: Set<CaptureState> = []

    public init(providers: Set<String> = [], project: String? = nil,
                from: Date? = nil, to: Date? = nil, states: Set<CaptureState> = []) {
        self.providers = providers
        self.project = project
        self.from = from
        self.to = to
        self.states = states
    }

    public var isEmpty: Bool {
        providers.isEmpty && project == nil && from == nil && to == nil && states.isEmpty
    }

    /// The UI's chip pickers are single-select; these fold one pick into
    /// the set (and stay nil when the set can't express a single pick).
    public var provider: String? {
        get { providers.count == 1 ? providers.first : nil }
        set { providers = newValue.map { [$0] } ?? [] }
    }
    public var state: CaptureState? {
        get { states.count == 1 ? states.first : nil }
        set { states = newValue.map { [$0] } ?? [] }
    }
}

/// One ranked hit: the record plus up to two «highlighted» snippets.
public struct ArchiveSearchResult: Sendable, Equatable, Identifiable {
    public let record: ArchiveRecord
    public let snippets: [String]
    /// Nil on metadata-only matches (name/title/project hits, not content).
    public let rank: Double?

    public var id: String { record.id }

    public init(record: ArchiveRecord, snippets: [String], rank: Double? = nil) {
        self.record = record
        self.snippets = snippets
        self.rank = rank
    }
}

public struct ArchiveStorageUsage: Sendable, Equatable {
    public let recordCount: Int
    public let contentBytes: Int64
    public let allocatedBytes: Int64
    public var trashedRecordCount: Int = 0
    public var trashedContentBytes: Int64 = 0
}

public enum DataHoarderArchiveError: Error, Equatable, LocalizedError {
    case unsupportedFile
    case corruptManifest
    case recordNotFound
    case objectMissing
    case objectCorrupt
    case destinationExists
    case catalogBusy
    case catalogUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Choose a regular file. Folders and symbolic links are not supported."
        case .corruptManifest: "The Data Hoarder index is damaged or contains unsafe records."
        case .recordNotFound: "That archived record no longer exists."
        case .objectMissing: "The archived file is missing."
        case .objectCorrupt: "The archived file does not match its recorded content hash."
        case .destinationExists: "A file already exists at the export destination."
        case .catalogBusy: "The Data Hoarder archive is busy. Try again in a moment."
        case .catalogUnavailable: "The Data Hoarder archive could not be read or written."
        }
    }
}

/// A local, immutable content-addressed archive.
///
/// Preview reads at most 256 KiB plus one UTF-8 boundary. Content search scans
/// complete valid UTF-8 objects in 64 KiB chunks while retaining only enough
/// text to match across a chunk boundary.
public actor DataHoarderArchive {
    private struct Manifest: Codable {
        var version = 1
        var records: [ArchiveRecord] = []
        var trashedRecords: [ArchiveRecord]?
        /// v3: the saved+trashed records' chains. Older manifests lack it —
        /// their records get the one-segment backfill on import.
        var segments: [ArchiveSegment]?
    }

    private static let chunkSize = 64 * 1024
    private static let previewLimit = 256 * 1024

    private let root: URL
    private let objects: URL
    private let manifestURL: URL
    private let catalogURL: URL
    private let fileManager: FileManager

    public init(root: URL) {
        self.root = root
        objects = root.appendingPathComponent("objects", isDirectory: true)
        manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        catalogURL = root.appendingPathComponent("catalog.sqlite3", isDirectory: false)
        fileManager = .default
    }

    /// Metadata-only accounting. Includes the catalog and temporary files in
    /// disk allocation, does not follow symlinks, and counts hard links once.
    public func storageUsage() throws -> ArchiveStorageUsage {
        try Task.checkCancellation()
        let saved = try records()
        let trashed = try trashedRecords()
        let contentBytes = saved.reduce(Int64(0)) { Self.addBytes($0, $1.byteCount) }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else {
            if errno == ENOENT, saved.isEmpty {
                return ArchiveStorageUsage(recordCount: 0, contentBytes: 0, allocatedBytes: 0)
            }
            throw DataHoarderArchiveError.catalogUnavailable
        }
        guard rootInfo.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else {
            throw DataHoarderArchiveError.catalogUnavailable
        }
        var pending = [root]
        var seen = Set<String>()
        var allocated: Int64 = 0
        while let url = pending.popLast() {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw DataHoarderArchiveError.catalogUnavailable
            }
            guard seen.insert("\(info.st_dev):\(info.st_ino)").inserted else { continue }
            let (bytes, overflow) = max(0, info.st_blocks).multipliedReportingOverflow(by: 512)
            allocated = Self.addBytes(allocated, overflow ? .max : bytes)
            if info.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) {
                pending.append(contentsOf: try fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil))
            }
        }
        return ArchiveStorageUsage(recordCount: saved.count,
                                   contentBytes: contentBytes, allocatedBytes: allocated,
                                   trashedRecordCount: trashed.count,
                                   trashedContentBytes: trashed.reduce(0) { Self.addBytes($0, $1.byteCount) })
    }

    private static func addBytes(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? .max : value
    }

    /// Free capacity on the archive volume, or nil when the volume can't be
    /// queried. `importantUsage` counts space the system can reclaim, which
    /// is what "will this import fit" actually means to a user.
    public func availableCapacity() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public func records(query: String = "", inTrash: Bool = false) throws -> [ArchiveRecord] {
        guard let catalog = try openCatalogIfPresent() else { return [] }
        let catalogRecords = try inTrash ? catalog.trashedRecords() : catalog.records()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return catalogRecords }

        var matches: [ArchiveRecord] = []
        for record in catalogRecords {
            let metadataMatch = record.name.localizedCaseInsensitiveContains(needle)
                || record.sourcePath.localizedCaseInsensitiveContains(needle)
                || (record.title?.localizedCaseInsensitiveContains(needle) ?? false)
                || (record.project?.localizedCaseInsensitiveContains(needle) ?? false)
            if try metadataMatch || recordContains(record: record, inTrash: inTrash, query: needle) {
                matches.append(record)
            }
        }
        return sorted(matches)
    }

    public func trashedRecords() throws -> [ArchiveRecord] {
        try openCatalogIfPresent()?.trashedRecords() ?? []
    }

    public func moveToTrash(id: String) throws {
        try moveToTrash(id: id, trashedAt: Date())
    }

    /// The trash stamp is the retention clock — tests inject it to age an
    /// entry without waiting.
    func moveToTrash(id: String, trashedAt: Date) throws {
        try Task.checkCancellation()
        guard let catalog = try openCatalogIfPresent() else { throw DataHoarderArchiveError.recordNotFound }
        try catalog.transaction {
            guard let record = try catalog.record(id: id) else { throw DataHoarderArchiveError.recordNotFound }
            try catalog.trash(record.markedTrashed(at: trashedAt))
        }
    }

    public func restoreFromTrash(id: String) throws {
        try Task.checkCancellation()
        guard let catalog = try openCatalogIfPresent() else { throw DataHoarderArchiveError.recordNotFound }
        try catalog.transaction {
            guard let record = try catalog.trashedRecords(id: id).first else { throw DataHoarderArchiveError.recordNotFound }
            try verifyChain(catalog: catalog, record: record)
            try catalog.insert(record)
        }
    }

    /// Deletes only the IDs reviewed by the caller. Each committed removal is
    /// independent; a failure leaves remaining entries available for retry.
    public func emptyTrash(ids: [String]) throws -> Int {
        guard let catalog = try openCatalogIfPresent() else { return 0 }
        var count = 0
        for id in Set(ids) {
            try Task.checkCancellation()
            try catalog.transaction {
                guard let record = try catalog.trashedRecords(id: id).first else { return }
                guard try catalog.record(id: id) == nil else { throw DataHoarderArchiveError.corruptManifest }
                let removed = try catalog.deleteSegments(recordID: record.id)
                for segment in removed
                    where try catalog.segmentRefs(hash: segment.hash, excludingRecordID: record.id) == 0 {
                    let object = objectURL(hash: segment.hash)
                    var info = stat()
                    if lstat(object.path, &info) == 0 {
                        let kind = info.st_mode & UInt16(S_IFMT)
                        guard kind == UInt16(S_IFREG) || kind == UInt16(S_IFLNK) else {
                            throw DataHoarderArchiveError.objectCorrupt
                        }
                        try fileManager.removeItem(at: object)
                    } else if errno != ENOENT {
                        throw DataHoarderArchiveError.catalogUnavailable
                    }
                }
                // Do not check cancellation after unlink: finish recording the
                // authorized deletion. A failed commit can be retried safely.
                try catalog.markRemovalComplete(id: id)
                count += 1
            }
        }
        return count
    }

    /// Permanently removes trash entries whose `trashedAt` stamp predates the
    /// retention window. Entries written before the stamp existed carry no
    /// age proof, so they are kept — deletion needs a known age, not a guess.
    /// Returns the number of records purged.
    @discardableResult
    public func purgeExpiredTrash(olderThanDays days: Int, now: Date = Date()) throws -> Int {
        guard days > 0, let catalog = try openCatalogIfPresent() else { return 0 }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let expired = try catalog.trashedRecords().filter {
            guard let trashedAt = $0.trashedAt else { return false }
            return trashedAt < cutoff
        }
        return try emptyTrash(ids: expired.map(\.id))
    }

    public func importFile(_ source: URL) throws -> ArchiveRecord {
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DataHoarderArchiveError.unsupportedFile
        }

        let catalog = try catalogForMutation()
        let temporary = root.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        let digest = try copyAndHash(from: source, to: temporary)
        try Task.checkCancellation()
        var result: ArchiveRecord?
        var createdObject = false
        do {
            try catalog.transaction {
                if let existing = try catalog.record(id: digest) {
                    try ensureObject(id: digest, incoming: temporary, created: &createdObject)
                    result = existing
                    return
                }
                // Identical bytes sitting in the trash: the tombstone IS
                // this record. Reviving keeps one identity — a fresh live
                // row beside the tombstone would let the retention sweep
                // delete segments the live record still chains to.
                if let tombstone = try catalog.trashedRecords(id: digest).first {
                    try ensureObject(id: digest, incoming: temporary, created: &createdObject)
                    try verifyChain(catalog: catalog, record: tombstone)
                    let revived = tombstone.restored()
                    try catalog.insert(revived)
                    result = revived
                    return
                }
                try ensureObject(id: digest, incoming: temporary, created: &createdObject)
                let object = objectURL(hash: digest)
                let attributes = try fileManager.attributesOfItem(atPath: object.path)
                let byteCount = (attributes[.size] as? NSNumber)?.int64Value
                    ?? Int64(values.fileSize ?? 0)
                let record = ArchiveRecord(
                    id: digest, name: source.lastPathComponent, sourcePath: source.path,
                    byteCount: byteCount, importedAt: Date(),
                    sourceModifiedAt: values.contentModificationDate)
                try Task.checkCancellation()
                try catalog.insert(record)
                if let segment = try catalog.segments(recordID: digest).first {
                    try indexObject(catalog: catalog, segment: segment)
                }
                result = record
            }
        } catch {
            if createdObject {
                // Keep the index check and cleanup under the same writer lock.
                // Another importer may have adopted this object after rollback.
                try? catalog.transaction {
                    if try catalog.record(id: digest) == nil,
                       try catalog.trashedRecords(id: digest).isEmpty {
                        try? fileManager.removeItem(at: objectURL(hash: digest))
                    }
                }
            }
            throw error
        }
        guard let result else { throw DataHoarderArchiveError.catalogUnavailable }
        return result
    }

    public func preview(id: String, inTrash: Bool = false) throws -> String {
        let record = try record(id: id, inTrash: inTrash)
        guard let catalog = try openCatalogIfPresent() else { throw DataHoarderArchiveError.recordNotFound }
        let segments = try chain(catalog: catalog, record: record)
        var data = Data()
        for segment in segments {
            let object = objectURL(hash: segment.hash)
            try ensureRegularObject(object)
            guard try hash(of: object) == segment.hash else { throw DataHoarderArchiveError.objectCorrupt }
            guard data.count < Self.previewLimit + 3 else { break }
            let handle = try FileHandle(forReadingFrom: object)
            let remaining = Self.previewLimit + 3 - data.count
            if let chunk = try handle.read(upToCount: remaining) { data.append(chunk) }
            try? handle.close()
            try Task.checkCancellation()
        }
        guard !data.contains(0), let (text, consumed) = previewText(data, byteCount: record.byteCount) else {
            return "Binary file · \(record.byteCount) bytes"
        }
        return record.byteCount > Int64(consumed) ? text + "\n…" : text
    }

    /// `overwriting` is for a caller that already holds overwrite consent
    /// (an NSSavePanel "Replace?" answer). It publishes with an atomic
    /// swap — the old destination survives a failed export — instead of
    /// the check-then-move race the plain path uses to refuse clobbering.
    public func export(id: String, to destination: URL, inTrash: Bool = false,
                       overwriting: Bool = false) throws {
        guard overwriting || !fileManager.fileExists(atPath: destination.path) else {
            throw DataHoarderArchiveError.destinationExists
        }
        let record = try record(id: id, inTrash: inTrash)
        guard let catalog = try openCatalogIfPresent() else { throw DataHoarderArchiveError.recordNotFound }
        let segments = try chain(catalog: catalog, record: record)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".jrbar-export-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(atPath: temporary.path, contents: nil,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        for segment in segments {
            try Task.checkCancellation()
            let object = objectURL(hash: segment.hash)
            try ensureRegularObject(object)
            try appendVerified(from: object, hash: segment.hash, to: output)
        }
        try output.synchronize()
        if fileManager.fileExists(atPath: destination.path) {
            guard overwriting else { throw DataHoarderArchiveError.destinationExists }
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    /// Publishes a portable snapshot only after every object passes its hash
    /// check. A v3 manifest lists every record's segments; a v2 manifest
    /// preserves trash state; exports without trash or segments retain the
    /// v1 format. The archive reader accepts all three.
    /// An interrupted or failed export leaves no partial destination.
    public func exportArchive(to destination: URL, overwriting: Bool = false) throws -> Int {
        try Task.checkCancellation()
        guard overwriting || !fileManager.fileExists(atPath: destination.path) else {
            throw DataHoarderArchiveError.destinationExists
        }
        var snapshot: [ArchiveRecord] = []
        var trashed: [ArchiveRecord] = []
        var chains: [ArchiveSegment] = []
        if let catalog = try openCatalogIfPresent() {
            try catalog.transaction {
                snapshot = try catalog.records()
                trashed = try catalog.trashedRecords()
                for record in snapshot + trashed {
                    chains.append(contentsOf: try catalog.segments(recordID: record.id))
                }
            }
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".jrbar-archive-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: staging) }
        let exportedObjects = staging.appendingPathComponent("objects", isDirectory: true)
        try fileManager.createDirectory(at: exportedObjects, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        var copied = Set<String>()
        for segment in chains {
            try Task.checkCancellation()
            guard copied.insert(segment.hash).inserted else { continue }
            let source = objectURL(hash: segment.hash)
            try ensureRegularObject(source)
            guard try copyAndHash(from: source, to: exportedObjects.appendingPathComponent(segment.hash)) == segment.hash else {
                throw DataHoarderArchiveError.objectCorrupt
            }
        }
        let manifest = try JSONEncoder().encode(Manifest(
            version: chains.isEmpty ? (trashed.isEmpty ? 1 : 2) : 3,
            records: snapshot,
            trashedRecords: trashed.isEmpty ? nil : trashed,
            segments: chains.isEmpty ? nil : chains))
        let metadata = staging.appendingPathComponent("manifest.json")
        guard fileManager.createFile(atPath: metadata.path, contents: manifest,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: metadata)
        defer { try? handle.close() }
        try handle.synchronize()
        try Task.checkCancellation()
        // Exclusive rename also rejects a destination created during the
        // copy, including a dangling symbolic link that fileExists does
        // not detect. With overwrite consent, RENAME_SWAP exchanges the
        // trees atomically — the old archive lands on the staging path
        // the defer above removes, so a failed publish never leaves the
        // destination half-old half-new.
        // lstat, not fileExists: a dangling symlink still counts as an
        // existing destination for the swap decision.
        var targetInfo = stat()
        let targetExists = lstat(destination.path, &targetInfo) == 0
        let flags = UInt32(overwriting && targetExists ? RENAME_SWAP : RENAME_EXCL)
        let result = staging.path.withCString { source in
            destination.path.withCString { target in renamex_np(source, target, flags) }
        }
        if result != 0, overwriting, targetExists, errno == ENOTSUP {
            // Filesystems without swap: move the old tree aside, publish,
            // and only then remove it — the failure window leaves the
            // original intact rather than deleted.
            let aside = destination.deletingLastPathComponent()
                .appendingPathComponent(".jrbar-archive-aside-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.moveItem(at: destination, to: aside)
                try fileManager.moveItem(at: staging, to: destination)
                try? fileManager.removeItem(at: aside)
            } catch {
                try? fileManager.moveItem(at: aside, to: destination)
                throw error
            }
        } else if result != 0 {
            if errno == EEXIST { throw DataHoarderArchiveError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return snapshot.count + trashed.count
    }

    // MARK: - Segmented records (catalog v3) and live capture

    public func record(id: String) throws -> ArchiveRecord? {
        guard DataHoarderCatalog.validID(id),
              let catalog = try openCatalogIfPresent() else { return nil }
        return try catalog.record(id: id)
    }

    public func segments(id: String) throws -> [ArchiveSegment] {
        guard let catalog = try openCatalogIfPresent() else { return [] }
        guard let record = try catalog.record(id: id) ?? catalog.trashedRecords(id: id).first else { return [] }
        return try chain(catalog: catalog, record: record)
    }

    /// Saved records sharing a session id — a captured transcript and the
    /// CLIProxyAPI request log that carried the same session link up here.
    /// `excluding` drops one record (typically the caller's own) from the list.
    public func relatedRecords(sessionID: String, excluding id: String? = nil) throws -> [ArchiveRecord] {
        guard !sessionID.isEmpty, let catalog = try openCatalogIfPresent() else { return [] }
        return try catalog.records().filter { $0.sessionID == sessionID && $0.id != id }
    }

    /// The record's ordered segment payloads — the input session
    /// reconstruction consumes. Every object is verified against its
    /// recorded hash before it is handed out; a corrupt or missing object
    /// fails the whole read rather than returning partial content as whole.
    public func segmentData(id: String, inTrash: Bool = false) throws -> [Data] {
        let record = try record(id: id, inTrash: inTrash)
        guard let catalog = try openCatalogIfPresent() else {
            throw DataHoarderArchiveError.recordNotFound
        }
        var payloads: [Data] = []
        for segment in try chain(catalog: catalog, record: record) {
            try Task.checkCancellation()
            let object = objectURL(hash: segment.hash)
            try ensureRegularObject(object)
            let data = try Data(contentsOf: object)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == segment.hash else {
                throw DataHoarderArchiveError.objectCorrupt
            }
            payloads.append(data)
        }
        return payloads
    }

    /// The live record a captured file grows into. The id is a random
    /// content-namespace token — segment objects still dedup by hash.
    public func createLiveRecord(
        name: String, sourcePath: String, provider: String? = nil,
        sessionID: String? = nil, project: String? = nil, model: String? = nil,
        title: String? = nil, startedAt: Date? = nil, sourceModifiedAt: Date? = nil
    ) throws -> ArchiveRecord {
        let catalog = try catalogForMutation()
        let id = SHA256.hash(data: Data("jrbar-live-record:\(UUID().uuidString)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let record = ArchiveRecord(
            id: id, name: name, sourcePath: sourcePath, byteCount: 0,
            importedAt: Date(), sourceModifiedAt: sourceModifiedAt,
            provider: provider, sessionID: sessionID, project: project,
            model: model, title: title, startedAt: startedAt,
            lastActivityAt: nil, segmentCount: 0, captureState: .live)
        try catalog.transaction {
            try catalog.insert(record)
        }
        return record
    }

    /// Metadata learned from fresh transcript lines; nil leaves fields alone.
    public func updateRecordMetadata(
        id: String, provider: String? = nil, sessionID: String? = nil,
        project: String? = nil, model: String? = nil, title: String? = nil,
        startedAt: Date? = nil, lastActivityAt: Date? = nil
    ) throws {
        guard let catalog = try openCatalogIfPresent() else { throw DataHoarderArchiveError.recordNotFound }
        try catalog.transaction {
            try catalog.updateRecordMetadata(
                id: id, provider: provider, sessionID: sessionID, project: project,
                model: model, title: title, startedAt: startedAt, lastActivityAt: lastActivityAt)
        }
    }

    public func setCaptureState(id: String, state: CaptureState) throws {
        guard let catalog = try openCatalogIfPresent() else { throw DataHoarderArchiveError.recordNotFound }
        try catalog.transaction {
            guard try catalog.record(id: id) != nil else { throw DataHoarderArchiveError.recordNotFound }
            try catalog.setCaptureState(id: id, state: state)
        }
    }

    /// Stores `data` as the record's next segment: the content-addressed
    /// object dedups by hash, the segment row, byte count and FTS index
    /// commit together.
    @discardableResult
    public func appendSegment(
        recordID: String, data: Data, byteOffset: Int64, note: String? = nil,
        capturedAt: Date = Date()
    ) throws -> ArchiveSegment {
        let catalog = try catalogForMutation()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let temporary = root.appendingPathComponent(".segment-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var segment: ArchiveSegment?
        var createdObject = false
        do {
            try catalog.transaction {
                guard try catalog.record(id: recordID) != nil else { throw DataHoarderArchiveError.recordNotFound }
                try ensureObject(id: digest, incoming: temporary, created: &createdObject)
                let ordinal = try catalog.segments(recordID: recordID).count
                let rowid = try catalog.insertSegment(ArchiveSegment(
                    recordID: recordID, ordinal: ordinal, hash: digest,
                    byteOffset: byteOffset, byteLength: Int64(data.count),
                    capturedAt: capturedAt, note: note))
                try catalog.addBytes(id: recordID, delta: Int64(data.count), lastActivityAt: capturedAt)
                try catalog.markLiveUnlessGap(id: recordID)
                let fresh = ArchiveSegment(
                    rowid: rowid, recordID: recordID, ordinal: ordinal, hash: digest,
                    byteOffset: byteOffset, byteLength: Int64(data.count),
                    capturedAt: capturedAt, note: note)
                try indexObject(catalog: catalog, segment: fresh, data: data)
                segment = fresh
            }
        } catch {
            if createdObject {
                // The move into objects/ survived a rolled-back insert —
                // reclaim the orphan unless another segment references it.
                try? catalog.transaction {
                    if try catalog.segmentRefs(hash: digest, excludingRecordID: recordID) == 0 {
                        try? fileManager.removeItem(at: objectURL(hash: digest))
                    }
                }
            }
            throw error
        }
        guard let segment else { throw DataHoarderArchiveError.catalogUnavailable }
        return segment
    }

    /// Indexes a segment's object for search — valid UTF-8 with no NULs, the
    /// same rule the content scanner applies. An unindexable (binary or
    /// missing) object still gets a row — with empty text — so it leaves
    /// the pending set and `indexPendingSegments` converges instead of
    /// re-reading the same bytes forever.
    private func indexObject(catalog: DataHoarderCatalog, segment: ArchiveSegment,
                           data: Data? = nil) throws {
        let payload: Data
        if let data {
            payload = data
        } else {
            let object = objectURL(hash: segment.hash)
            guard let handle = try? FileHandle(forReadingFrom: object),
                  let read = try? handle.readToEnd() else {
                try catalog.ftsInsert(rowid: segment.rowid, text: "")
                return
            }
            try? handle.close()
            payload = read
        }
        let text = (!payload.contains(0) ? String(data: payload, encoding: .utf8) : nil) ?? ""
        try catalog.ftsInsert(rowid: segment.rowid, text: text)
    }

    // MARK: - Capture bookkeeping

    /// The capture ledger keys files by real path: the directory enumerator
    /// and FSEvents both report /private/var where Foundation's own
    /// `resolvingSymlinksInPath` may leave /var unresolved — mixing the two
    /// forms would split one file's state across two keys and the
    /// vanished-file sweep would reap the live row. `realpath(3)` agrees
    /// with both reporters; a vanished leaf resolves through its parent.
    static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let nsPath = path as NSString
        if let parent = realpath(nsPath.deletingLastPathComponent, nil) {
            defer { free(parent) }
            return String(cString: parent) + "/" + nsPath.lastPathComponent
        }
        return nsPath.resolvingSymlinksInPath
    }

    public func captureState(path: String) throws -> CaptureStateRow? {
        try openCatalogIfPresent()?.captureState(path: Self.canonicalPath(path))
    }

    /// Every path the capture ledger tracks under a source prefix — the
    /// rescan reconciles this against what still exists on disk.
    public func capturePaths(sourceID: String) throws -> [String] {
        try (openCatalogIfPresent()?.capturePaths(sourceID: sourceID) ?? []).sorted()
    }

    public func upsertCaptureState(_ row: CaptureStateRow) throws {
        var row = row
        row.path = Self.canonicalPath(row.path)
        let catalog = try catalogForMutation()
        try catalog.transaction {
            try catalog.upsertCaptureState(row)
        }
    }

    /// The rescan's backlog seed — insert-only, so a capture that landed
    /// between the nil read and this write is never overwritten.
    public func seedCaptureState(_ row: CaptureStateRow) throws {
        var row = row
        row.path = Self.canonicalPath(row.path)
        let catalog = try catalogForMutation()
        try catalog.transaction {
            try catalog.seedCaptureState(row)
        }
    }

    public func removeCaptureState(path: String) throws {
        guard let catalog = try openCatalogIfPresent() else { return }
        try catalog.transaction {
            try catalog.removeCaptureState(path: Self.canonicalPath(path))
        }
    }

    /// A capture attempt failed — surfaced, never silently dropped.
    public func recordCaptureFailure(path: String, sourceID: String, error: String) throws {
        let catalog = try catalogForMutation()
        try catalog.transaction {
            try catalog.recordCaptureFailure(path: path, sourceID: sourceID, error: error)
        }
    }

    public func captureFailures(limit: Int = 100) throws -> [CaptureFailure] {
        try openCatalogIfPresent()?.captureFailures(limit: limit) ?? []
    }

    public func captureFailureCount() throws -> Int {
        try openCatalogIfPresent()?.captureFailureCount() ?? 0
    }

    public func setMetadata(key: String, value: String) throws {
        let catalog = try catalogForMutation()
        try catalog.transaction {
            try catalog.setMetadata(key: key, value: value)
        }
    }

    public func metadata(key: String) throws -> String? {
        try openCatalogIfPresent()?.metadata(key: key)
    }

    // MARK: - Full-text search

    /// Indexes up to `limit` pending segment objects — the v2→v3 backfill
    /// and anything an earlier pass skipped. Returns how many were indexed.
    @discardableResult
    public func indexPendingSegments(limit: Int = 100) throws -> Int {
        guard let catalog = try openCatalogIfPresent() else { return 0 }
        var indexed = 0
        try catalog.transaction {
            for segment in try catalog.unindexedSegments(limit: limit) {
                try Task.checkCancellation()
                try indexObject(catalog: catalog, segment: segment)
                indexed += 1
            }
        }
        return indexed
    }

    /// (indexed, total) segment counts — the backfill's progress display.
    public func indexProgress() throws -> (indexed: Int, total: Int) {
        try openCatalogIfPresent()?.ftsProgress() ?? (0, 0)
    }

    public func searchableProjects() throws -> [String] {
        try openCatalogIfPresent()?.distinctProjects() ?? []
    }

    /// FTS5 `bm25` search over segment text plus metadata substring hits.
    /// An empty query returns metadata-only matches for the active filters;
    /// each term is phrase-quoted so arbitrary user text can't reach MATCH.
    public func search(
        query: String, filter: ArchiveSearchFilter = ArchiveSearchFilter(),
        offset: Int = 0, limit: Int = 50
    ) throws -> [ArchiveSearchResult] {
        guard let catalog = try openCatalogIfPresent() else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var ordered: [(recordID: String, rank: Double?)] = []
        var seen = Set<String>()
        let match = Self.ftsMatchExpression(needle)
        if !match.isEmpty {
            // Fetch from 0 — metadata hits sort after ALL content hits,
            // so the merged stream's `offset` must be applied below,
            // not inside ftsSearch, or meta hits occupying early page
            // slots make later pages silently skip records.
            for hit in try catalog.ftsSearch(
                match: match, providers: filter.providers.sorted(), project: filter.project,
                from: filter.from, to: filter.to,
                states: filter.states.map(\.rawValue).sorted(),
                limit: offset + limit + 1, offset: 0) {
                guard seen.insert(hit.recordID).inserted else { continue }
                ordered.append((hit.recordID, hit.rank))
            }
        }
        // Metadata matches (name/title/project/source) rank after content
        // hits on every page — dropping them past page 0 would make them
        // unreachable once a full first page trimmed them.
        if !needle.isEmpty {
            // Dupes against `seen` and filter rejects consume rows of the
            // bounded meta list — overfetch so the window can't run dry.
            for record in try catalog.recordsMatchingMetadata(
                needle, limit: offset + limit + 1 + seen.count) {
                guard seen.insert(record.id).inserted else { continue }
                if !Self.matches(filter: filter, record: record) { continue }
                ordered.append((record.id, nil))
                if ordered.count >= offset + limit + 1 { break }
            }
        }
        // Filter-only browsing (no query text): the filtered record list,
        // newest activity first. `offset` applies here too — without it a
        // filtered browse can never reach past the first page.
        if needle.isEmpty {
            var skipped = 0
            for record in try catalog.records() where Self.matches(filter: filter, record: record) {
                if skipped < offset { skipped += 1; continue }
                ordered.append((record.id, nil))
                if ordered.count >= limit { break }
            }
        }
        let page = Array(ordered.dropFirst(needle.isEmpty ? 0 : offset).prefix(limit))
        var results: [ArchiveSearchResult] = []
        for entry in page {
            try Task.checkCancellation()
            guard let record = try catalog.record(id: entry.recordID) else { continue }
            let snippets = match.isEmpty ? [] : try catalog.ftsSnippets(match: match, recordID: record.id)
            results.append(ArchiveSearchResult(record: record, snippets: snippets, rank: entry.rank))
        }
        return results
    }

    /// Whether another page exists past `offset` — the caller re-runs
    /// `search` with `offset + limit` and compares.
    public func searchHasMore(
        query: String, filter: ArchiveSearchFilter = ArchiveSearchFilter(), offset: Int = 0, limit: Int = 50
    ) throws -> Bool {
        guard let catalog = try openCatalogIfPresent() else { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = Self.ftsMatchExpression(needle)
        guard !match.isEmpty else {
            // Filter-only browsing: is there a record past this page?
            var remaining = 0
            for record in try catalog.records() where Self.matches(filter: filter, record: record) {
                remaining += 1
                if remaining > offset + limit { return true }
            }
            return false
        }
        // The merged stream is [FTS hits] ++ [metadata hits minus FTS
        // dupes]: "more" exists when either leg reaches past the window —
        // an FTS-only probe misses metadata hits a full first page hid.
        let ftsHits = try catalog.ftsSearch(
            match: match, providers: filter.providers.sorted(), project: filter.project,
            from: filter.from, to: filter.to, states: filter.states.map(\.rawValue).sorted(),
            limit: offset + limit + 1, offset: 0)
        if ftsHits.count > offset + limit { return true }
        let seen = Set(ftsHits.map(\.recordID))
        let needed = offset + limit - ftsHits.count
        var metaCount = 0
        for record in try catalog.recordsMatchingMetadata(
            needle, limit: needed + 1 + seen.count) {
            if seen.contains(record.id) { continue }
            if !Self.matches(filter: filter, record: record) { continue }
            metaCount += 1
            if metaCount > needed { return true }
        }
        return false
    }

    /// Every whitespace-separated term becomes one quoted FTS phrase —
    /// operator characters inside the quotes are literal text.
    static func ftsMatchExpression(_ query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }

    private static func matches(filter: ArchiveSearchFilter, record: ArchiveRecord) -> Bool {
        if !filter.providers.isEmpty {
            guard let provider = record.provider, filter.providers.contains(provider) else { return false }
        }
        if let project = filter.project, record.project != project { return false }
        if !filter.states.isEmpty, !filter.states.contains(record.captureState) { return false }
        let activity = record.lastActivityAt ?? record.importedAt
        if let from = filter.from, activity < from { return false }
        if let to = filter.to, activity > to { return false }
        return true
    }

    private func record(id: String, inTrash: Bool = false) throws -> ArchiveRecord {
        guard DataHoarderCatalog.validID(id),
              let catalog = try openCatalogIfPresent(),
              let record = try inTrash ? catalog.trashedRecords(id: id).first : catalog.record(id: id) else {
            throw DataHoarderArchiveError.recordNotFound
        }
        return record
    }

    private func loadLegacyManifest() throws
        -> (manifest: Manifest, fingerprint: String, signature: String)? {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        do {
            let signatureBefore = try legacySignature()
            let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            let signatureAfter = try legacySignature()
            guard signatureBefore == signatureAfter else {
                throw DataHoarderArchiveError.corruptManifest
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            let trashed = manifest.trashedRecords ?? []
            let knownIDs = Set(manifest.records.map(\.id) + trashed.map(\.id))
            let listedSegments = manifest.segments ?? []
            let segmentsValid = listedSegments.allSatisfy {
                DataHoarderCatalog.validID($0.recordID) && DataHoarderCatalog.validID($0.hash)
                    && $0.ordinal >= 0 && $0.byteOffset >= 0 && $0.byteLength >= 0
                    && knownIDs.contains($0.recordID)
            }
            // A record's declared byteCount is the sum of its segments'
            // byteLength — a mismatch means a truncated or invented chain,
            // which is corruption, not a format the importer can guess at.
            let segmentsByRecord = Dictionary(grouping: listedSegments, by: \.recordID)
            let totalsValid = (manifest.records + trashed).allSatisfy { record in
                guard let segments = segmentsByRecord[record.id] else { return true }
                var total: Int64 = 0
                for segment in segments {
                    let (sum, overflow) = total.addingReportingOverflow(segment.byteLength)
                    guard !overflow else { return false }
                    total = sum
                }
                return total == record.byteCount
            }
            guard (manifest.version == 1 && trashed.isEmpty && manifest.segments == nil)
                    || (manifest.version == 2 && manifest.segments == nil)
                    || manifest.version == 3,
                  valid(records: manifest.records + trashed), segmentsValid, totalsValid else {
                throw DataHoarderArchiveError.corruptManifest
            }
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (manifest, fingerprint, signatureAfter)
        } catch let error as DataHoarderArchiveError {
            throw error
        } catch {
            throw DataHoarderArchiveError.corruptManifest
        }
    }

    /// The one catalog connection this archive holds. Opening per call put
    /// a sqlite3_open + legacy reconcile on every keystroke of a search.
    /// Actor isolation serializes access, and nothing else publishes this
    /// file — `publishCatalog` opens the winner and hands it back here.
    private var catalog: DataHoarderCatalog?

    private func openCatalogIfPresent() throws -> DataHoarderCatalog? {
        if let catalog {
            // Caching must not blind the integrity contract: a schema
            // rewrite or a legacy-manifest edit between calls still fails
            // closed — the checks just no longer cost a connection each.
            try catalog.checkIntegrity()
            try reconcileLegacy(with: catalog)
            return catalog
        }
        if fileManager.fileExists(atPath: catalogURL.path) {
            let catalog = try DataHoarderCatalog(url: catalogURL, create: false)
            try setPermissions(0o600, at: catalogURL)
            try reconcileLegacy(with: catalog)
            self.catalog = catalog
            return catalog
        }
        guard let legacy = try loadLegacyManifest() else { return nil }
        let migrated = try migrateLegacy(legacy)
        catalog = migrated
        return migrated
    }

    private func catalogForMutation() throws -> DataHoarderCatalog {
        if let catalog = try openCatalogIfPresent() { return catalog }
        try prepareStorage()
        let temporary = root.appendingPathComponent(".catalog-create-\(UUID().uuidString).sqlite3")
        defer { try? fileManager.removeItem(at: temporary) }
        let candidate = try DataHoarderCatalog(url: temporary, create: true)
        try setPermissions(0o600, at: temporary)
        candidate.close()
        let published = try publishCatalog(temporary)
        catalog = published
        return published
    }

    private func migrateLegacy(_ legacy: (manifest: Manifest, fingerprint: String, signature: String)) throws
        -> DataHoarderCatalog {
        try prepareStorage()
        let temporary = root.appendingPathComponent(".catalog-migration-\(UUID().uuidString).sqlite3")
        defer { try? fileManager.removeItem(at: temporary) }
        let temporaryCatalog = try DataHoarderCatalog(url: temporary, create: true)
        do {
            try temporaryCatalog.mergeLegacy(
                legacy.manifest.records, trashed: legacy.manifest.trashedRecords ?? [],
                segments: legacy.manifest.segments ?? [],
                fingerprint: legacy.fingerprint, signature: legacy.signature)
            try setPermissions(0o600, at: temporary)
            temporaryCatalog.close()
            return try publishCatalog(temporary, legacy: legacy)
        } catch {
            temporaryCatalog.close()
            throw error
        }
    }

    private func reconcileLegacy(with catalog: DataHoarderCatalog) throws {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return }
        if try catalog.legacySignature() == legacySignature() { return }
        guard let legacy = try loadLegacyManifest() else { return }
        try catalog.mergeLegacy(
            legacy.manifest.records, trashed: legacy.manifest.trashedRecords ?? [],
            segments: legacy.manifest.segments ?? [],
            fingerprint: legacy.fingerprint, signature: legacy.signature)
    }

    private func legacySignature() throws -> String {
        var info = stat()
        guard lstat(manifestURL.path, &info) == 0,
              (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else {
            throw DataHoarderArchiveError.corruptManifest
        }
        // ctime and inode detect edits even when size and mtime are preserved.
        return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private func publishCatalog(
        _ temporary: URL,
        legacy: (manifest: Manifest, fingerprint: String, signature: String)? = nil
    ) throws -> DataHoarderCatalog {
        // Publish without an overwrite or a temporary hard-link alias. macOS
        // SQLite can reject writes if an alias is unlinked after opening.
        if Darwin.renamex_np(temporary.path, catalogURL.path, UInt32(RENAME_EXCL)) == 0 {
            return try DataHoarderCatalog(url: catalogURL, create: false)
        }
        guard errno == EEXIST else {
            throw DataHoarderArchiveError.catalogUnavailable
        }
        let winner = try DataHoarderCatalog(url: catalogURL, create: false)
        if let legacy {
            try winner.mergeLegacy(
                legacy.manifest.records, trashed: legacy.manifest.trashedRecords ?? [],
                segments: legacy.manifest.segments ?? [],
                fingerprint: legacy.fingerprint, signature: legacy.signature)
        }
        return winner
    }

    private func ensureObject(id: String, incoming: URL, created: inout Bool) throws {
        let object = objectURL(hash: id)
        if fileManager.fileExists(atPath: object.path) {
            try ensureRegularObject(object)
            guard try hash(of: object) == id else { throw DataHoarderArchiveError.objectCorrupt }
            return
        }
        try fileManager.moveItem(at: incoming, to: object)
        try setPermissions(0o600, at: object)
        created = true
    }

    private func prepareStorage() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try setPermissions(0o700, at: root)
        try fileManager.createDirectory(at: objects, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try setPermissions(0o700, at: objects)
    }

    private func copyAndHash(from source: URL, to destination: URL) throws -> String {
        guard fileManager.createFile(atPath: destination.path, contents: nil,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var hasher = SHA256()
        while let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Scans the record's whole chain as one stream: segment objects in
    /// ordinal order, carrying the UTF-8 boundary and match window across
    /// links so a hit spanning two segments still lands.
    private func recordContains(record: ArchiveRecord, inTrash: Bool, query: String) throws -> Bool {
        guard let catalog = try openCatalogIfPresent() else { return false }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var utf8Carry = Data()
        var textCarry = ""
        for segment in try chain(catalog: catalog, record: record) {
            let url = objectURL(hash: segment.hash)
            try ensureRegularObject(url)
            let handle = try FileHandle(forReadingFrom: url)
            var binary = false
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
                if chunk.isEmpty { break }
                if chunk.contains(0) { binary = true; break }
                var combined = utf8Carry
                combined.append(chunk)
                guard let decoded = decodeUTF8Chunk(combined) else { binary = true; break }
                utf8Carry = decoded.remainder
                let folded = (textCarry + decoded.text)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if folded.contains(needle) { try? handle.close(); return true }
                textCarry = String(folded.suffix(max(0, needle.count - 1)))
            }
            try? handle.close()
            if binary { return false }
        }
        return false
    }

    private func hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func previewText(_ data: Data, byteCount: Int64) -> (String, Int)? {
        if byteCount <= Int64(Self.previewLimit) {
            return String(data: data, encoding: .utf8).map { ($0, data.count) }
        }
        let upper = min(data.count, Self.previewLimit + 3)
        // A truncated object can return fewer bytes than the limit while
        // the record claims more — `limit...upper` would be an inverted
        // range. Decode what came back rather than crash on it.
        guard upper >= Self.previewLimit else {
            return String(data: data, encoding: .utf8).map { ($0, data.count) }
        }
        for count in Self.previewLimit...upper {
            if let text = String(data: data.prefix(count), encoding: .utf8) {
                return (text, count)
            }
        }
        return nil
    }

    private func decodeUTF8Chunk(_ data: Data) -> (text: String, remainder: Data)? {
        for remainderCount in 0...min(3, data.count) {
            let prefix = data.dropLast(remainderCount)
            if let text = String(data: prefix, encoding: .utf8) {
                return (text, Data(data.suffix(remainderCount)))
            }
        }
        return nil
    }

    private func ensureRegularObject(_ url: URL) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw DataHoarderArchiveError.objectMissing
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DataHoarderArchiveError.objectMissing
        }
    }

    private func objectURL(hash: String) -> URL {
        objects.appendingPathComponent(hash, isDirectory: false)
    }

    /// The record's ordered segment chain. A catalog record with no segment
    /// rows (only possible before migration completes) still reads through
    /// the object named by its id — the same bytes the backfill would chain.
    private func chain(catalog: DataHoarderCatalog, record: ArchiveRecord) throws -> [ArchiveSegment] {
        let segments = try catalog.segments(recordID: record.id)
        if segments.isEmpty {
            // Only a snapshot can fall back to the whole-content object its
            // id names — a live record with no segments simply has nothing yet.
            guard record.captureState == .snapshot else { return [] }
            return [ArchiveSegment(recordID: record.id, ordinal: 0, hash: record.id,
                                   byteOffset: 0, byteLength: record.byteCount,
                                   capturedAt: record.importedAt)]
        }
        return segments
    }

    /// Every segment object present and matching its recorded hash.
    private func verifyChain(catalog: DataHoarderCatalog, record: ArchiveRecord) throws {
        for segment in try chain(catalog: catalog, record: record) {
            let object = objectURL(hash: segment.hash)
            try ensureRegularObject(object)
            guard try hash(of: object) == segment.hash else { throw DataHoarderArchiveError.objectCorrupt }
            try Task.checkCancellation()
        }
    }

    /// Streams one verified object into an open output handle.
    private func appendVerified(from source: URL, hash expected: String, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var hasher = SHA256()
        while let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
            try output.write(contentsOf: data)
        }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw DataHoarderArchiveError.objectCorrupt
        }
    }

    private func valid(records: [ArchiveRecord]) -> Bool {
        var ids = Set<String>()
        return records.allSatisfy { record in
            DataHoarderCatalog.valid(record) && ids.insert(record.id).inserted
        }
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func sorted(_ records: [ArchiveRecord]) -> [ArchiveRecord] {
        records.sorted {
            if $0.importedAt != $1.importedAt { return $0.importedAt > $1.importedAt }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
