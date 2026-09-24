import CoreServices.FSEvents
import Darwin
import Foundation

/// Live, incremental capture for enabled Data Hoarder sources.
///
/// Each enabled source root gets an `FSEventStream` (recursive file events)
/// plus a 30 s safety rescan — watchers buy latency, the rescan is the
/// correctness floor. File changes debounce 2 s, then the file's persisted
/// `capture_state` offset resumes: inode/size regressions mark the record
/// `.gap` and restart from 0; otherwise `[offset, EOF)` is read, cut at the
/// last newline for JSONL so segments hold whole lines, and appended as the
/// record's next segment object.
///
/// Consent is a write-time gate: `fullContent` off stores
/// `TranscriptRedactor`'s structural form — prompts and responses never
/// reach the archive, not even transiently. Every read/write error lands in
/// `capture_failures`; nothing is dropped silently.
///
/// Restart rule: `rescan` reconciles `capture_state` against the filesystem
/// before watching. Files that grew while the app was off continue from
/// their saved offset. A file with no row is pre-existing backlog unless its
/// mtime is newer than the source's last scan — those seed a position only;
/// importing their contents is the review flow's explicit choice.
///
/// Backfill window: a `start` given `backfillSince` lets a source's
/// first-ever scan read files modified since then from their start. Older
/// files still seed a position only, and later scans never backfill — the
/// window is what "keep the last 30 days" reads once, not a standing rule.
public actor DataHoarderCapture {
    private let archive: DataHoarderArchive
    private let debounceInterval: TimeInterval
    private let rescanInterval: TimeInterval
    /// A file quiet this long counts as ended — `.closed`, not `.live` forever.
    private let closeAfter: TimeInterval
    private let maximumVisitedEntries: Int
    private let fileManager = FileManager.default

    private var fullContent = false
    /// The backfill window's start for this run — nil reads no backlog.
    private var backfillSince: Date?
    private var sources: [String: ArchiveSource] = [:]
    private var streams: [String: SourceEventStream] = [:]
    private var rescanTasks: [String: Task<Void, Never>] = [:]
    private var pendingFiles: [String: Task<Void, Never>] = [:]
    /// Debounce tokens — a completed or superseded task drops its own
    /// entry so the map can't grow with every file ever changed.
    private var pendingTokens: [String: UUID] = [:]
    /// captureFile suspends on archive I/O, so the actor can interleave a
    /// second call for the same path. Without a gate both would read a nil
    /// recordID and mint duplicate records for one file — a debounced event
    /// racing a rescan does exactly that. Returning early is equally wrong:
    /// a rescan that "captured" a file only on paper lets the next pass
    /// backlog-seed it (offset = EOF, no record) and the queued capture then
    /// finds nothing new — silent data loss. Callers therefore wait for the
    /// in-flight runner and take their own turn, so a returned captureFile
    /// always means the file's delta was persisted.
    private var running: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Rescans are safe to overlap per file (the in-flight gate), but their
    /// vanished-file sweep is not: a second enumerator's partial `seen` set
    /// would reap rows the first rescan just wrote. Coalesce instead — a
    /// concurrent request marks the source pending and the finisher runs
    /// one fresh reconcile, which sees a complete tree.
    private var activeRescans: Set<String> = []
    private var pendingRescans: Set<String> = []
    /// Sources currently watched — the "disabled means no watchers" witness.
    public private(set) var activeSourceIDs: Set<String> = []

    public init(archive: DataHoarderArchive, debounceInterval: TimeInterval = 2,
                rescanInterval: TimeInterval = 30, closeAfter: TimeInterval = 24 * 3_600,
                maximumVisitedEntries: Int = 200_000) {
        self.archive = archive
        self.debounceInterval = max(0, debounceInterval)
        self.rescanInterval = max(1, rescanInterval)
        self.closeAfter = max(0, closeAfter)
        self.maximumVisitedEntries = max(1, maximumVisitedEntries)
    }

    /// Set by `stop`, cleared by `start`. Continuation-based waiters
    /// survive task cancellation, so a capture queued behind a cancelled
    /// runner re-checks this before becoming a runner itself — otherwise
    /// a stop could leave a write landing afterward. Starts false: a
    /// direct `captureFile` before any `start` is a legitimate one-shot.
    private var stopped = false

    /// Replaces any running capture: reconcile each root, then watch it.
    /// `backfillSince` opens the backfill window for sources scanned for
    /// the first time (see the type's doc). Cancelling the calling task
    /// ends the reconcile at its next file, leaves that source's scan
    /// unstamped so the backfill resumes later, and watches nothing.
    public func start(sources: [ArchiveSource], fullContent: Bool, backfillSince: Date? = nil) async {
        stop()
        stopped = false
        self.fullContent = fullContent
        self.backfillSince = backfillSince
        for source in sources {
            // FSEvents reports real paths — keep one canonical form so event
            // paths, capture_state keys and prefix checks all agree.
            let normalized = ArchiveSource(
                id: source.id, name: source.name,
                root: URL(fileURLWithPath: DataHoarderArchive.canonicalPath(source.root.path)),
                extensions: source.extensions)
            self.sources[source.id] = normalized
            activeSourceIDs.insert(source.id)
            await rescan(source: normalized)
            // A superseded start (the caller's task cancelled mid-backfill)
            // opens no stream and no timer — the newer plan owns the engine.
            guard !Task.isCancelled else { stop(); return }
            let stream = SourceEventStream { [weak self] paths in
                Task { await self?.noteChanged(paths: paths) }
            }
            if stream.start(root: normalized.root) { streams[source.id] = stream }
            rescanTasks[source.id] = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(self?.rescanInterval ?? 30))
                    guard !Task.isCancelled, let self else { return }
                    await self.rescan(source: normalized)
                }
            }
        }
    }

    /// Stops every watcher, timer and pending write — the utility being off
    /// or paused leaves nothing running.
    public func stop() {
        for stream in streams.values { stream.stop() }
        streams.removeAll()
        for task in rescanTasks.values { task.cancel() }
        rescanTasks.removeAll()
        for task in pendingFiles.values { task.cancel() }
        pendingFiles.removeAll()
        pendingTokens.removeAll()
        sources.removeAll()
        activeSourceIDs.removeAll()
        stopped = true
        // Wake queued waiters — the `stopped` check in captureFile turns
        // them back instead of letting them run captures after stop.
        let queued = waiters
        waiters.removeAll()
        for continuations in queued.values {
            for continuation in continuations { continuation.resume() }
        }
    }

    /// FSEvents-delivered paths. Each file debounces independently; a flood
    /// beyond the per-event cap degrades to a full source rescan.
    func noteChanged(paths: [String]) {
        var rescanNeeded = Set<String>()
        for rawPath in paths.prefix(2_000) {
            guard let source = source(for: rawPath) else { continue }
            let path = DataHoarderArchive.canonicalPath(rawPath)
            pendingFiles[path]?.cancel()
            let token = UUID()
            pendingTokens[path] = token
            pendingFiles[path] = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.debounceInterval))
                guard !Task.isCancelled else { return }
                await self.captureFile(at: URL(fileURLWithPath: path), source: source)
                await self.finishPending(path: path, token: token)
            }
        }
        if paths.count > 2_000 {
            for source in sources.values { rescanNeeded.insert(source.id) }
        }
        for id in rescanNeeded {
            if let source = sources[id] {
                Task { await rescan(source: source) }
            }
        }
    }

    /// A debounced task finished: drop its bookkeeping, unless a newer
    /// event already replaced it (the token no longer matching).
    private func finishPending(path: String, token: UUID) {
        guard pendingTokens[path] == token else { return }
        pendingFiles.removeValue(forKey: path)
        pendingTokens.removeValue(forKey: path)
    }

    private func source(for path: String) -> ArchiveSource? {
        sources.values.first {
            path == $0.root.path || path.hasPrefix($0.root.path + "/")
        }
    }

    // MARK: Reconcile

    /// Diff the source tree against `capture_state` and catch up whatever
    /// changed — the startup reconcile and the periodic safety net share it.
    /// Serialized per source: overlapping reconciles replay once so the
    /// vanished-file sweep never runs on a partial enumeration.
    public func rescan(source: ArchiveSource) async {
        guard activeRescans.insert(source.id).inserted else {
            pendingRescans.insert(source.id)
            return
        }
        await performRescan(source: source)
        activeRescans.remove(source.id)
        if pendingRescans.remove(source.id) != nil {
            await rescan(source: sources[source.id] ?? source)
        }
    }

    private func performRescan(source: ArchiveSource) async {
        let lastScan = (try? await archive.metadata(key: lastScanKey(source.id)))
            .flatMap { TimeInterval($0) } ?? 0
        var seen = Set<String>()
        var visited = 0
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
            .isPackageKey, .fileSizeKey, .contentModificationDateKey,
        ]
        // The enumerator yields real paths (e.g. /private/var for /var
        // roots); walk the canonical root so stored keys match event paths.
        let canonicalRoot = URL(fileURLWithPath:
            DataHoarderArchive.canonicalPath(source.root.path))
        // A walk that bailed early (entry cap) or skipped an unreadable
        // directory saw only part of the tree — the vanished-file sweep
        // must not run against a partial `seen` set, or every unvisited
        // tracked file would read as a gap.
        var walkIncomplete = false
        if let enumerator = fileManager.enumerator(
            at: canonicalRoot, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in walkIncomplete = true; return true }) {
            while let child = enumerator.nextObject() as? URL {
                if Task.isCancelled { return }
                if visited >= maximumVisitedEntries { walkIncomplete = true; break }
                visited += 1
                guard let values = try? child.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      values.isHidden != true, values.isPackage != true,
                      source.extensions.contains(child.pathExtension) else { continue }
                var info = stat()
                guard lstat(child.path, &info) == 0 else { continue }
                seen.insert(child.path)
                let size = max(0, Int64(info.st_size))
                let mtime = values.contentModificationDate
                    ?? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                let row: CaptureStateRow?
                do {
                    row = try await archive.captureState(path: child.path)
                } catch {
                    // A failed read is not "no row": seeding over a live
                    // ledger entry would drop the delta and the record link.
                    try? await archive.recordCaptureFailure(
                        path: child.path, sourceID: source.id, error: "\(error)")
                    continue
                }
                if let row {
                    let inode = Int64(info.st_ino)
                    // A same-size rewrite keeps inode and length — only the
                    // mtime moves (1s epsilon: FAT mtimes are 2s-granular and
                    // resourceValues/stat disagree in the nanoseconds).
                    if inode != row.inode || size != row.offset
                        || (size == row.offset
                            && abs(mtime.timeIntervalSince(row.mtime)) > 1.0) {
                        await captureFile(at: child, source: source)
                    } else {
                        await closeIfQuiet(row: row, mtime: mtime)
                    }
                } else if lastScan > 0, mtime.timeIntervalSince1970 > lastScan {
                    // Created since the source was last seen — while the
                    // engine was off or just now — captured from the start.
                    // The first-ever scan has no baseline, so everything it
                    // finds is pre-existing backlog, never fresh activity.
                    await captureFile(at: child, source: source)
                } else if lastScan == 0, let since = backfillSince, mtime >= since {
                    // Inside the backfill window on the source's first
                    // scan: the consented "last N days", read from 0.
                    await captureFile(at: child, source: source)
                } else {
                    // Pre-existing backlog: track the position only. Its
                    // contents import through the review flow by choice.
                    // Insert-only — a debounced capture may have written a
                    // live row between the nil read and this seed.
                    do {
                        try await archive.seedCaptureState(CaptureStateRow(
                            path: child.path, sourceID: source.id,
                            inode: Int64(info.st_ino), size: size, mtime: mtime,
                            offset: size, recordID: nil))
                    } catch {
                        try? await archive.recordCaptureFailure(
                            path: child.path, sourceID: source.id, error: "\(error)")
                    }
                }
            }
        }
        // Files that vanished since the last scan are discontinuities —
        // their records keep what was captured and say so. Skipped when the
        // walk was partial: unseen ≠ vanished.
        if !walkIncomplete, let tracked = try? await archive.capturePaths(sourceID: source.id) {
            for path in tracked where !seen.contains(path) {
                if let row = try? await archive.captureState(path: path),
                   let recordID = row.recordID {
                    try? await archive.setCaptureState(id: recordID, state: .gap)
                }
                try? await archive.removeCaptureState(path: path)
            }
        }
        try? await archive.setMetadata(
            key: lastScanKey(source.id), value: "\(Date().timeIntervalSince1970)")
    }

    private func lastScanKey(_ sourceID: String) -> String {
        "capture_last_scan:\(sourceID)"
    }

    /// When each source was last reconciled; a source never scanned is
    /// absent. Its first start reads the backfill window, while one scanned
    /// before resumes from its saved positions whatever the window says.
    public func lastScans(sourceIDs: [String]) async -> [String: Date] {
        var scans: [String: Date] = [:]
        for id in sourceIDs {
            guard let raw = try? await archive.metadata(key: lastScanKey(id)),
                  let seconds = TimeInterval(raw), seconds > 0 else { continue }
            scans[id] = Date(timeIntervalSince1970: seconds)
        }
        return scans
    }

    /// Per-pass ceiling on the bytes one capture pulls off disk. Anything
    /// past it waits for the next pass — the ledger offset makes resume
    /// exact, and a multi-GB catch-up never holds the whole delta at once.
    private static let maxDeltaBytesPerPass: Int64 = 64 * 1024 * 1024

    private func closeIfQuiet(row: CaptureStateRow, mtime: Date) async {
        guard let recordID = row.recordID,
              Date().timeIntervalSince(mtime) > closeAfter,
              let record = try? await archive.record(id: recordID),
              record.captureState == .live else { return }
        try? await archive.setCaptureState(id: recordID, state: .closed)
    }

    // MARK: Per-file capture

    /// Read whatever the file gained since its saved offset. Waits for any
    /// in-flight capture of the same path, then takes a turn — a returned
    /// call means the delta was persisted, unless `stop` interposed.
    /// Safe to call twice; the second pass re-stats and finds nothing new.
    func captureFile(at fileURL: URL, source: ArchiveSource) async {
        // capture_state keys live in canonical form — the same path an
        // enumerator child or an FSEvents payload reports.
        let url = URL(fileURLWithPath: DataHoarderArchive.canonicalPath(fileURL.path))
        // A failed insert and the waiter registration are one synchronous
        // turn, so no release can slip between them — every waiter is seen
        // by the runner that frees the path. `stopped` turns a waiter back
        // instead of letting it run a capture that outlives the watcher.
        while !running.insert(url.path).inserted {
            if stopped { return }
            await withCheckedContinuation { continuation in
                waiters[url.path, default: []].append(continuation)
            }
            if stopped { return }
        }
        if !stopped { await performCapture(at: url, source: source) }
        running.remove(url.path)
        for continuation in waiters.removeValue(forKey: url.path) ?? [] {
            continuation.resume()
        }
    }

    /// The single-runner half of `captureFile` — the in-flight gate above
    /// guarantees only one of these runs per path at a time.
    private func performCapture(at url: URL, source: ArchiveSource) async {
        do {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) else { return }
            let inode = Int64(info.st_ino)
            let size = max(0, Int64(info.st_size))
            let mtime = Date(timeIntervalSince1970:
                TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)

            var row = try await archive.captureState(path: url.path)
                ?? CaptureStateRow(path: url.path, sourceID: source.id, inode: inode,
                                   size: size, mtime: mtime, offset: 0, recordID: nil)
            row.sourceID = source.id

            var gapNote: String?
            if row.inode != inode {
                gapNote = "gap: source replaced (inode \(row.inode) → \(inode))"
            } else if size < row.offset {
                gapNote = "gap: source truncated (\(row.offset) → \(size) bytes)"
            } else if size == row.offset && size > 0
                        && abs(mtime.timeIntervalSince(row.mtime)) > 1.0 {
                // Same size, same inode, different mtime: rewritten in
                // place. The changed range is unknowable — re-read all of
                // it rather than stamp the change away.
                gapNote = "gap: source rewritten in place (\(size) bytes)"
            }
            if gapNote != nil {
                if let recordID = row.recordID {
                    try await archive.setCaptureState(id: recordID, state: .gap)
                }
                row.offset = 0
            }

            guard size > row.offset else {
                row.inode = inode
                row.size = size
                row.mtime = mtime
                try await archive.upsertCaptureState(row)
                await closeIfQuiet(row: row, mtime: mtime)
                return
            }

            // Read [offset, EOF) — looping, since read(upToCount:) may
            // short-read, and bounded per pass: a source that grew GBs
            // between scans must not land on the heap all at once. The
            // next pass picks up the remainder from the advanced offset.
            let handle = try FileHandle(forReadingFrom: url)
            var fresh = Data()
            do {
                try handle.seek(toOffset: UInt64(row.offset))
                let target = min(size - row.offset, Self.maxDeltaBytesPerPass)
                while fresh.count < target {
                    guard let chunk = try handle.read(
                        upToCount: min(Int(target) - fresh.count, 1 << 20)),
                          !chunk.isEmpty else { break }
                    fresh.append(chunk)
                }
            }
            try? handle.close()
            guard !fresh.isEmpty else {
                row.inode = inode
                row.size = size
                row.mtime = mtime
                try await archive.upsertCaptureState(row)
                return
            }

            // JSONL cuts at the last newline; the partial tail carries to the
            // next pass so segments always hold whole lines. Other file kinds
            // take the whole delta.
            var consumed = fresh.count
            if url.pathExtension.lowercased() == "jsonl" {
                consumed = fresh.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            }
            guard consumed > 0 else {
                row.inode = inode
                row.size = size
                row.mtime = mtime
                try await archive.upsertCaptureState(row)
                return
            }
            let payload = fresh.prefix(consumed)

            var recordID = row.recordID
            if let existing = recordID, try await archive.record(id: existing) == nil {
                // The record was purged — treat the file as new rather than
                // resurrecting something the user deleted.
                recordID = nil
            }
            if recordID == nil {
                recordID = try await archive.createLiveRecord(
                    name: url.lastPathComponent, sourcePath: url.path,
                    sourceModifiedAt: mtime).id
            }
            guard let recordID else { throw CocoaError(.fileWriteUnknown) }

            let stored = fullContent ? Data(payload) : TranscriptRedactor.redact(Data(payload))
            if !stored.isEmpty {
                try await archive.appendSegment(
                    recordID: recordID, data: stored,
                    byteOffset: row.offset, note: gapNote)
            }

            // Probe reads the source lines (not the stored form); the title
            // only exists when full-content consent covers it.
            var metadata = TranscriptMetadata()
            let lines = String(decoding: payload, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            TranscriptProbe.ingest(lines: lines, into: &metadata, includeTitle: fullContent)
            // Content the probe can't place still belongs to the agent
            // whose folder it came from, so the archive can filter by it.
            if metadata.provider == "other", let named = ArchiveSource.namedProvider(of: source.id) {
                metadata.provider = named
            }
            if metadata.provider != nil || metadata.sessionID != nil || metadata.lastActivityAt != nil {
                try await archive.updateRecordMetadata(
                    id: recordID, provider: metadata.provider, sessionID: metadata.sessionID,
                    project: metadata.project, model: metadata.model, title: metadata.title,
                    startedAt: metadata.startedAt, lastActivityAt: metadata.lastActivityAt)
            }

            row.offset += Int64(consumed)
            row.inode = inode
            row.size = size
            row.mtime = mtime
            row.recordID = recordID
            try await archive.upsertCaptureState(row)
        } catch {
            try? await archive.recordCaptureFailure(
                path: url.path, sourceID: source.id, error: "\(error)")
        }
    }
}

/// One recursive `FSEventStream` on a source root. Falls back cleanly —
/// `start` returning false leaves the 30 s rescan as the only trigger, which
/// is slower but still correct.
private final class SourceEventStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "devin.jrbar.hoarder.fsevents")
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([String]) -> Void

    init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
    }

    func start(root: URL) -> Bool {
        var context = FSEventStreamContext()
        // Retained until the stream is released — a callback already queued
        // when teardown runs must still find a live box.
        let box = Unmanaged.passRetained(self)
        context.info = box.toOpaque()
        context.release = { info in
            guard let info else { return }
            Unmanaged<SourceEventStream>.fromOpaque(info).release()
        }
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<SourceEventStream>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
            var delivered: [String] = []
            delivered.reserveCapacity(count)
            for index in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
                // With UseCFTypes + FileEvents each entry is the changed
                // item's path as a CFString (the dictionary form requires
                // UseExtendedData, which we don't set).
                delivered.append(
                    Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String)
            }
            box.handler(delivered)
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagNoDefer)) else {
            box.release()
            return false
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            queue.sync {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
            }
            stream = nil
            return false
        }
        return true
    }

    /// Teardown hops onto the stream's own queue so a callback that was
    /// queued but not yet run finishes before the context — and with it the
    /// retained box — goes away.
    func stop() {
        guard let stream else { return }
        self.stream = nil
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    deinit { stop() }
}
