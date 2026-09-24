import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import JRBarCore

/// Segmented records, the live capture engine, the transcript probe/redactor,
/// and the FTS5 search path (catalog v3).
@Suite("Data Hoarder capture")
struct DataHoarderCaptureTests {

    // MARK: v2 → v3 migration

    @Test("a v2 catalog upgrades transactionally: every record, trash entry and object survives as one segment")
    func migratesVersionTwoCatalog() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let savedData = Data("saved v2 trace".utf8)
        let trashedData = Data("trashed v2 trace".utf8)
        let saved = try fixture.v2Record(name: "saved.jsonl", data: savedData)
        let trashed = try fixture.v2Record(name: "trashed.jsonl", data: trashedData)
        try fixture.writeV2Catalog(saved: [saved], trashed: [trashed])

        let archive = DataHoarderArchive(root: fixture.archive)
        #expect(try await archive.records() == [saved])
        #expect(try await archive.trashedRecords() == [trashed])
        for record in [saved, trashed] {
            let segments = try await archive.segments(id: record.id)
            #expect(segments.count == 1)
            #expect(segments.first?.ordinal == 0)
            #expect(segments.first?.hash == record.id)
            #expect(segments.first?.byteLength == record.byteCount)
            #expect(record.segmentCount == 1 && record.captureState == .snapshot)
        }
        #expect(try await archive.preview(id: saved.id) == "saved v2 trace")
        #expect(try await archive.preview(id: trashed.id, inTrash: true) == "trashed v2 trace")
        // The objects moved nowhere and still verify against the segment hash.
        #expect(try Data(contentsOf: fixture.archive.appendingPathComponent("objects/\(saved.id)")) == savedData)
        // A second open sees the migrated catalog as plain v3.
        let reopened = DataHoarderArchive(root: fixture.archive)
        #expect(try await reopened.records() == [saved])
    }

    @Test("a v2→v3 export writes a v3 manifest that lists the migrated segments")
    func migratedExportManifest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.v2Record(name: "trace.jsonl", data: Data("payload".utf8))
        try fixture.writeV2Catalog(saved: [record], trashed: [])
        let archive = DataHoarderArchive(root: fixture.archive)
        let destination = fixture.root.appendingPathComponent("export")
        #expect(try await archive.exportArchive(to: destination) == 1)
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as? [String: Any]
        #expect(manifest?["version"] as? Int == 3)
        let segments = manifest?["segments"] as? [[String: Any]]
        #expect(segments?.count == 1)
        #expect(segments?.first?["recordID"] as? String == record.id)
        #expect(segments?.first?["hash"] as? String == record.id)
    }

    // MARK: Segments

    @Test("appended segments chain in order and preview/export read the concatenation")
    func segmentChainReadAndExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.createLiveRecord(
            name: "session.jsonl", sourcePath: fixture.root.appendingPathComponent("session.jsonl").path)
        #expect(record.captureState == .live && record.segmentCount == 0)
        // A live record with no segments previews as empty, not corrupt.
        #expect(try await archive.preview(id: record.id) == "")

        try await archive.appendSegment(recordID: record.id, data: Data("first\n".utf8), byteOffset: 0)
        let second = try await archive.appendSegment(recordID: record.id, data: Data("second\n".utf8), byteOffset: 6)

        let segments = try await archive.segments(id: record.id)
        #expect(segments.map(\.ordinal) == [0, 1])
        #expect(segments.map(\.hash) == [segments[0].hash, second.hash])
        #expect(try await archive.preview(id: record.id) == "first\nsecond\n")

        let export = fixture.root.appendingPathComponent("export.jsonl")
        try await archive.export(id: record.id, to: export)
        #expect(try Data(contentsOf: export) == Data("first\nsecond\n".utf8))

        let grown = try #require(try await archive.record(id: record.id))
        #expect(grown.segmentCount == 2 && grown.byteCount == 13)
    }

    @Test("a corrupt segment object fails the chain's integrity check")
    func segmentIntegrity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.createLiveRecord(name: "s.jsonl", sourcePath: "/tmp/s.jsonl")
        let segment = try await archive.appendSegment(recordID: record.id, data: Data("bytes".utf8), byteOffset: 0)
        try Data("tampered".utf8).write(
            to: fixture.archive.appendingPathComponent("objects/\(segment.hash)"))
        await #expect(throws: DataHoarderArchiveError.objectCorrupt) {
            _ = try await archive.preview(id: record.id)
        }
        await #expect(throws: DataHoarderArchiveError.objectCorrupt) {
            try await archive.export(id: record.id, to: fixture.root.appendingPathComponent("out"))
        }
    }

    @Test("trashing keeps the chain, emptying removes unreferenced segment objects only")
    func trashKeepsChain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.createLiveRecord(name: "s.jsonl", sourcePath: "/tmp/s.jsonl")
        let shared = Data("shared bytes".utf8)
        let sharedDigest = SHA256.hash(data: shared).map { String(format: "%02x", $0) }.joined()
        let other = try await archive.createLiveRecord(name: "other.jsonl", sourcePath: "/tmp/o.jsonl")
        _ = try await archive.appendSegment(recordID: record.id, data: shared, byteOffset: 0)
        _ = try await archive.appendSegment(recordID: other.id, data: shared, byteOffset: 0)
        _ = try await archive.appendSegment(recordID: record.id, data: Data("solo".utf8), byteOffset: 12)

        try await archive.moveToTrash(id: record.id)
        #expect(try await archive.preview(id: record.id, inTrash: true) == "shared bytessolo")
        try await archive.restoreFromTrash(id: record.id)
        try await archive.moveToTrash(id: record.id)
        #expect(try await archive.emptyTrash(ids: [record.id]) == 1)
        // The deduplicated object survives through the other record's chain.
        #expect(FileManager.default.fileExists(
            atPath: fixture.archive.appendingPathComponent("objects/\(sharedDigest)").path))
        #expect(try await archive.preview(id: other.id) == "shared bytes")
    }

    // MARK: Capture engine

    @Test("the first scan seeds positions only; appended lines then capture incrementally")
    func firstScanSeedsBacklogThenCaptures() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let file = try fixture.file("a.jsonl", data: Data("old line\n".utf8))
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)

        await capture.start(sources: [source], fullContent: true)
        #expect(await capture.activeSourceIDs == [source.id])
        // Backlog: tracked but not imported — capture of pre-existing files
        // is the review flow's explicit choice.
        #expect(try await archive.records().isEmpty)
        let stored = try await archive.captureState(path: file.path)
        #expect(try await archive.captureFailures().isEmpty)
        let row = try #require(stored)
        #expect(row.offset == 9 && row.recordID == nil)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"assistant","sessionId":"s1","cwd":"/work/repo","timestamp":"2026-09-19T10:00:00Z","message":{"role":"assistant","model":"claude-test","content":[{"type":"text","text":"hi"}]}}"# + "\n").utf8))
        try handle.close()
        await capture.rescan(source: source)

        let records = try await archive.records()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.captureState == .live)
        #expect(record.provider == "claude" && record.sessionID == "s1")
        #expect(record.project == "/work/repo" && record.model == "claude-test")
        // The segment holds only the appended bytes — never the backlog prefix.
        #expect(try await archive.preview(id: record.id).contains("old line") == false)
        #expect(try await archive.preview(id: record.id).contains(#""sessionId":"s1""#))
        let updated = try #require(try await archive.captureState(path: file.path))
        #expect(updated.offset > 9 && updated.recordID == record.id)
        await capture.stop()
    }

    @Test("a backfill window reads recent files from their start on the first scan only")
    func backfillWindowReadsRecentFilesOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let recent = try fixture.file("recent.jsonl", data: Data("recent line\n".utf8))
        let old = try fixture.file("old.jsonl", data: Data("old line\n".utf8))
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60 * 86_400)], ofItemAtPath: old.path)
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)
        #expect(await capture.lastScans(sourceIDs: [source.id]).isEmpty, "never scanned: the window applies")

        await capture.start(sources: [source], fullContent: true,
                            backfillSince: now.addingTimeInterval(-30 * 86_400))
        #expect(await capture.lastScans(sourceIDs: [source.id, "unknown"]).keys.sorted() == [source.id])
        let records = try await archive.records()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(try await archive.preview(id: record.id) == "recent line\n")
        // Outside the window: positioned at its end, never read.
        let oldRow = try #require(try await archive.captureState(path: old.path))
        #expect(oldRow.offset == 9 && oldRow.recordID == nil)
        #expect(try await archive.captureState(path: recent.path)?.recordID == record.id)
        await capture.stop()

        // A later start with a wider window never reaches back: the window
        // is the first scan's, and every file already has its position.
        let restarted = DataHoarderCapture(archive: archive)
        await restarted.start(sources: [source], fullContent: true, backfillSince: .distantPast)
        #expect(try await archive.records().count == 1)
        #expect(try await archive.captureState(path: old.path)?.recordID == nil)
        await restarted.stop()
    }

    @Test("a cancelled start stops mid-backfill: no watcher, no scan stamp, the window kept")
    func cancelledStartWatchesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        _ = try fixture.file("a.jsonl", data: Data("first\n".utf8))
        _ = try fixture.file("b.jsonl", data: Data("second\n".utf8))
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)

        // The task cancels itself before the engine runs — a pause landing
        // mid-backfill, with nothing timed to race.
        let superseded = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await capture.start(sources: [source], fullContent: true, backfillSince: .distantPast)
        }
        await superseded.value
        #expect(await capture.activeSourceIDs.isEmpty)
        #expect(try await archive.records().isEmpty)
        #expect(try await archive.metadata(key: "capture_last_scan:test-source") == nil)

        // Unstamped, the source is still on its first scan: the next start
        // reads the whole window it never finished.
        await capture.start(sources: [source], fullContent: true, backfillSince: .distantPast)
        #expect(try await archive.records().count == 2)
        await capture.stop()
    }

    @Test("a file created while the engine was off captures from its start on the next scan")
    func offlineGrowthReconciles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)

        await capture.start(sources: [source], fullContent: true)
        // The file appears between scans — mtime newer than the stored scan.
        try await Task.sleep(for: .milliseconds(20))
        let file = try fixture.file("new.jsonl", data: Data("fresh line\n".utf8))
        await capture.rescan(source: source)

        let records = try await archive.records()
        #expect(records.count == 1)
        #expect(try await archive.preview(id: try #require(records.first).id) == "fresh line\n")

        // A second engine on the same archive (a relaunch) resumes the offset.
        await capture.stop()
        let restarted = DataHoarderCapture(archive: archive)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("more\n".utf8))
        try handle.close()
        // start() performs the restart reconcile itself: growth while the
        // engine was off continues from the saved offset, not a re-read.
        await restarted.start(sources: [source], fullContent: true)
        #expect(try await archive.preview(id: records[0].id) == "fresh line\nmore\n")
        await restarted.stop()
    }

    @Test("truncation marks the record .gap and restarts a segment at offset 0")
    func truncationMarksGap() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let file = try fixture.file("log.jsonl", data: Data("".utf8))
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)
        await capture.start(sources: [source], fullContent: true)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("first chunk\n".utf8))
        try handle.close()
        await capture.rescan(source: source)
        let record = try #require(try await archive.records().first)
        #expect(record.captureState == .live)

        // Rewrite shorter — the offset regresses and the archive says so.
        try Data("x\n".utf8).write(to: file)
        await capture.rescan(source: source)
        let marked = try #require(try await archive.record(id: record.id))
        #expect(marked.captureState == .gap)
        let segments = try await archive.segments(id: record.id)
        #expect(segments.count == 2)
        #expect(segments[1].byteOffset == 0)
        #expect(segments[1].note?.contains("gap") == true)
        // Content is the honest chain: what was captured, then the restart.
        #expect(try await archive.preview(id: record.id) == "first chunk\nx\n")
        await capture.stop()
    }

    @Test("a JSONL partial tail carries to the next pass — segments hold whole lines")
    func partialLineCarry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let file = try fixture.file("partial.jsonl", data: Data("".utf8))
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)
        await capture.start(sources: [source], fullContent: true)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("line one\nincomplete".utf8))
        try handle.close()
        await capture.rescan(source: source)
        var record = try #require(try await archive.records().first)
        // Only the complete line landed; the tail waits.
        #expect(try await archive.preview(id: record.id) == "line one\n")
        var row = try #require(try await archive.captureState(path: file.path))
        #expect(row.offset == 9)

        let second = try FileHandle(forWritingTo: file)
        try second.seekToEnd()
        try second.write(contentsOf: Data(" line\n".utf8))
        try second.close()
        await capture.rescan(source: source)
        record = try #require(try await archive.record(id: record.id))
        #expect(try await archive.preview(id: record.id) == "line one\nincomplete line\n")
        row = try #require(try await archive.captureState(path: file.path))
        let segments = try await archive.segments(id: record.id)
        #expect(segments.count == 2)
        await capture.stop()
    }

    @Test("redacted capture stores structure, not prompts — verbatim only with consent")
    func redactedCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)
        await capture.start(sources: [source], fullContent: false)

        let line = #"{"type":"assistant","sessionId":"s9","timestamp":"2026-09-19T11:00:00Z","message":{"role":"assistant","model":"claude-test","content":[{"type":"text","text":"the secret answer"}],"usage":{"input_tokens":7}}}"#
        try await Task.sleep(for: .milliseconds(20))
        _ = try fixture.file("redacted.jsonl", data: Data((line + "\n").utf8))
        await capture.rescan(source: source)

        let record = try #require(try await archive.records().first)
        let stored = try await archive.preview(id: record.id)
        #expect(!stored.contains("the secret answer"))
        #expect(stored.contains("[redacted 17 chars]"))
        #expect(stored.contains(#""type":"assistant""#) && stored.contains(#""sessionId":"s9""#))
        #expect(stored.contains(#""input_tokens":7"#) || stored.contains("\"input_tokens\": 7"))
        // Metadata still lands — but never the prompt-derived title.
        #expect(record.provider == "claude" && record.title == nil)
        await capture.stop()
    }

    @Test("an unreadable file records a capture failure and keeps its offset")
    func unreadableFileRecordsFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let file = try fixture.file("blocked.jsonl", data: Data("line\n".utf8))
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        await capture.captureFile(at: file, source: source)
        #expect(try await archive.captureFailureCount() == 1)
        let failures = try await archive.captureFailures()
        #expect(failures.first?.path == file.path)
        #expect(failures.first?.sourceID == source.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    @Test("no enabled sources means no watchers — and stop clears them")
    func disabledModuleStartsNoWatchers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source()
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)

        #expect(await capture.activeSourceIDs.isEmpty)
        await capture.start(sources: [], fullContent: false)
        #expect(await capture.activeSourceIDs.isEmpty)
        await capture.start(sources: [source], fullContent: false)
        #expect(await capture.activeSourceIDs == [source.id])
        await capture.stop()
        #expect(await capture.activeSourceIDs.isEmpty)
    }

    // MARK: Redactor

    @Test("redactLine keeps Claude structure and hides text")
    func redactClaudeLine() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-19T10:00:00Z","sessionId":"abc","message":{"role":"assistant","model":"m","content":[{"type":"text","text":"hidden words"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":3,"output_tokens":9}}}"#
        let redacted = try #require(try JSONSerialization.jsonObject(
            with: Data(TranscriptRedactor.redactLine(line).utf8)) as? [String: Any])
        #expect(redacted["type"] as? String == "assistant")
        #expect(redacted["timestamp"] as? String == "2026-09-19T10:00:00Z")
        #expect(redacted["sessionId"] as? String == "abc")
        let message = try #require(redacted["message"] as? [String: Any])
        #expect(message["model"] as? String == "m")
        let usage = try #require(message["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 3 && usage["output_tokens"] as? Int == 9)
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "[redacted 12 chars]")
        #expect(content[1]["name"] as? String == "Bash")
        let input = try #require(content[1]["input"] as? [String: Any])
        #expect(input["command"] as? String == "[redacted 2 chars]")
    }

    @Test("redactLine keeps Codex structure and hides message text")
    func redactCodexLine() throws {
        let line = #"{"timestamp":"2026-09-19T10:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"secret prompt"},{"type":"output_text","text":"secret reply"}]},"ok":true}"#
        let redacted = try #require(try JSONSerialization.jsonObject(
            with: Data(TranscriptRedactor.redactLine(line).utf8)) as? [String: Any])
        #expect(redacted["type"] as? String == "response_item")
        #expect(redacted["ok"] as? Bool == true)
        let payload = try #require(redacted["payload"] as? [String: Any])
        #expect(payload["role"] as? String == "user")
        let content = try #require(payload["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "input_text")
        #expect(content[0]["text"] as? String == "[redacted 13 chars]")
        #expect(content[1]["text"] as? String == "[redacted 12 chars]")
    }

    @Test("a malformed line stores an unparsed marker, never fabricated JSON")
    func redactMalformedLine() {
        let redacted = TranscriptRedactor.redactLine("not json at all {")
        #expect(redacted == #""[unparsed 17 bytes]""#)
        // …and a whole redact pass keeps line boundaries.
        let data = Data("good line\n".utf8) + Data(#"{"type":"x"}"#.utf8) + Data("\n".utf8)
        let out = String(decoding: TranscriptRedactor.redact(data), as: UTF8.self)
        #expect(out.hasPrefix(#""[unparsed 9 bytes]""# + "\n"))
        #expect(out.hasSuffix(#"{"type":"x"}"# + "\n"))
    }

    @Test("strings under unknown keys redact at any depth — only metadata keys stay")
    func redactUnknownKeys() throws {
        // An unrecognised row shape fails closed: `notes` could carry a
        // prompt, `custom` is no safer two levels down. Safe keys keep
        // their values at any depth.
        let line = #"{"custom":{"notes":"sk-secret"},"type":"assistant","message":{"role":"assistant","model":"m","free":"hidden"},"deep":{"deeper":{"note":"also hidden"}}}"#
        let redacted = try #require(try JSONSerialization.jsonObject(
            with: Data(TranscriptRedactor.redactLine(line).utf8)) as? [String: Any])
        #expect(redacted["type"] as? String == "assistant")
        let custom = try #require(redacted["custom"] as? [String: Any])
        #expect(custom["notes"] as? String == "[redacted 9 chars]")
        let message = try #require(redacted["message"] as? [String: Any])
        #expect(message["role"] as? String == "assistant")
        #expect(message["model"] as? String == "m")
        #expect(message["free"] as? String == "[redacted 6 chars]")
        let deep = try #require(redacted["deep"] as? [String: Any])
        let deeper = try #require(deep["deeper"] as? [String: Any])
        #expect(deeper["note"] as? String == "[redacted 11 chars]")
        // A bare array line is content, not structure.
        let arrayLine = TranscriptRedactor.redactLine(#"[{"text":"hi","type":"text"}]"#)
        #expect(arrayLine.contains("[redacted 2 chars]"))
        #expect(arrayLine.contains(#""type":"text""#))
    }

    // MARK: Probe

    @Test("the probe reads Claude session metadata")
    func probeClaude() {
        var metadata = TranscriptMetadata()
        TranscriptProbe.ingest(lines: [
            #"{"type":"user","sessionId":"sess-1","cwd":"/work/repo","timestamp":"2026-09-19T10:00:00Z","message":{"role":"user","content":"Fix the flaky test"}}"#,
            #"{"type":"assistant","sessionId":"sess-1","cwd":"/work/repo","timestamp":"2026-09-19T10:01:00Z","message":{"role":"assistant","model":"claude-test","content":[{"type":"text","text":"sure"}],"usage":{}}}"#,
        ], into: &metadata, includeTitle: true)
        #expect(metadata.provider == "claude")
        #expect(metadata.sessionID == "sess-1")
        #expect(metadata.project == "/work/repo")
        #expect(metadata.model == "claude-test")
        #expect(metadata.title == "Fix the flaky test")
        #expect(metadata.startedAt != nil && metadata.lastActivityAt != nil)
        #expect(metadata.lastActivityAt! > metadata.startedAt!)
        // Consent off: structure still learned, the prompt never becomes a title.
        var consented = TranscriptMetadata()
        TranscriptProbe.ingest(lines: [
            #"{"type":"user","sessionId":"sess-1","cwd":"/w","message":{"role":"user","content":"private"}}"#,
        ], into: &consented, includeTitle: false)
        #expect(consented.title == nil && consented.sessionID == "sess-1")
    }

    @Test("the probe reads Codex session metadata")
    func probeCodex() {
        var metadata = TranscriptMetadata()
        TranscriptProbe.ingest(lines: [
            #"{"timestamp":"2026-09-19T09:00:00Z","type":"session_meta","payload":{"id":"rollout-7","timestamp":"2026-09-19T09:00:00Z","cwd":"/src/app"}}"#,
            #"{"timestamp":"2026-09-19T09:00:05Z","type":"turn_context","payload":{"model":"gpt-test","cwd":"/src/app"}}"#,
            #"{"timestamp":"2026-09-19T09:00:10Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ship it"}]}}"#,
        ], into: &metadata, includeTitle: true)
        #expect(metadata.provider == "codex")
        #expect(metadata.sessionID == "rollout-7")
        #expect(metadata.project == "/src/app")
        #expect(metadata.model == "gpt-test")
        #expect(metadata.title == "ship it")
        #expect(metadata.startedAt != nil && metadata.lastActivityAt != nil)
    }

    @Test("unknown shapes report provider other with no metadata")
    func probeUnknown() {
        var metadata = TranscriptMetadata()
        TranscriptProbe.ingest(lines: ["plain text", #"{"unrelated":true}"#, "broken {"],
                               into: &metadata, includeTitle: true)
        #expect(metadata.provider == "other")
        #expect(metadata.sessionID == nil && metadata.model == nil && metadata.title == nil)
    }

    // MARK: FTS search

    @Test("FTS search ranks, snippets, filters and pages")
    func ftsSearch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let needle = "zelquix unique token"
        let first = try await archive.createLiveRecord(name: "a.jsonl", sourcePath: "/tmp/a.jsonl")
        try await archive.updateRecordMetadata(id: first.id, provider: "claude", project: "alpha")
        _ = try await archive.appendSegment(
            recordID: first.id, data: Data("line with \(needle) here\n".utf8), byteOffset: 0)
        let second = try await archive.createLiveRecord(name: "b.jsonl", sourcePath: "/tmp/b.jsonl")
        try await archive.updateRecordMetadata(id: second.id, provider: "codex", project: "beta")
        _ = try await archive.appendSegment(
            recordID: second.id, data: Data("\(needle) \(needle) \(needle)\n".utf8), byteOffset: 0)

        // Live appends index inline; the pending pump is a no-op for them.
        #expect(try await archive.indexPendingSegments() == 0)
        let results = try await archive.search(query: "zelquix")
        #expect(results.count == 2)
        #expect(results.first?.record.id == second.id, "the denser match ranks first")
        #expect(results.first?.snippets.first?.contains("«") == true)

        let filtered = try await archive.search(
            query: "zelquix", filter: ArchiveSearchFilter(providers: ["claude"]))
        #expect(filtered.map(\.record.id) == [first.id])
        let byProject = try await archive.search(
            query: "zelquix", filter: ArchiveSearchFilter(project: "beta"))
        #expect(byProject.map(\.record.id) == [second.id])
        let byState = try await archive.search(
            query: "", filter: ArchiveSearchFilter(states: [.live]))
        #expect(Set(byState.map(\.record.id)) == [first.id, second.id])

        // Paging: a two-result page then the remainder.
        let pageOne = try await archive.search(query: "zelquix", limit: 1)
        #expect(pageOne.count == 1)
        #expect(try await archive.searchHasMore(query: "zelquix", offset: 0, limit: 1))
        let pageTwo = try await archive.search(query: "zelquix", offset: 1, limit: 1)
        #expect(pageTwo.count == 1 && pageTwo.first?.record.id != pageOne.first?.record.id)
        #expect(try await archive.searchableProjects() == ["alpha", "beta"])
    }

    @Test("the backfill indexes objects written before the FTS pass ran")
    func ftsBackfill() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = DataHoarderArchive(root: fixture.archive)
        let record = try await archive.createLiveRecord(name: "old.jsonl", sourcePath: "/tmp/old.jsonl")
        let segment = try await archive.appendSegment(
            recordID: record.id, data: Data("preindex zelmark content\n".utf8), byteOffset: 0)
        // Simulate a segment that predates indexing: drop its FTS row directly.
        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.archive.appendingPathComponent("catalog.sqlite3").path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database,
            "DELETE FROM segments_fts WHERE rowid = \(segment.rowid)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close(database) == SQLITE_OK)
        var progress = try await archive.indexProgress()
        #expect(progress.indexed == 0 && progress.total == 1)
        #expect(try await archive.indexPendingSegments() == 1)
        progress = try await archive.indexProgress()
        #expect(progress.indexed == 1 && progress.total == 1)
        #expect(try await archive.search(query: "zelmark").map(\.record.id) == [record.id])
    }

    // MARK: Settings

    @Test("capture settings round-trip and decode tolerantly")
    func settingsDecode() throws {
        var settings = DataHoarderSettings()
        settings.captureSources = ["claude-projects": true, "codex-sessions": false]
        settings.fullContent = true
        settings.paused = true
        let decoded = try JSONDecoder().decode(
            DataHoarderSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.enabledSources == ["claude-projects"])

        let tolerant = try JSONDecoder().decode(DataHoarderSettings.self, from: Data(
            #"{"captureSources": "all", "fullContent": "yes", "paused": 1, "future": true}"#.utf8))
        #expect(tolerant == DataHoarderSettings())

        // The backfill window round-trips; a zero, negative or junk value
        // reads as no window rather than failing the struct.
        settings.backfillDays = 30
        let windowed = try JSONDecoder().decode(
            DataHoarderSettings.self, from: JSONEncoder().encode(settings))
        #expect(windowed.backfillDays == 30)
        for junk in [#"{"backfillDays": 0}"#, #"{"backfillDays": -5}"#, #"{"backfillDays": "30"}"#] {
            #expect(try JSONDecoder().decode(DataHoarderSettings.self, from: Data(junk.utf8)).backfillDays == nil)
        }

        var state = UtilitiesState()
        state.dataHoarder.fullContent = true
        state.dataHoarder.captureSources = ["x": true]
        let roundTrip = try JSONDecoder().decode(
            UtilitiesState.self, from: JSONEncoder().encode(state))
        #expect(roundTrip.dataHoarder == state.dataHoarder)
        let missing = try JSONDecoder().decode(UtilitiesState.self, from: Data(
            #"{"dataHoarderEnabled": true, "dataHoarder": "junk"}"#.utf8))
        #expect(missing.dataHoarderEnabled && missing.dataHoarder == DataHoarderSettings())
    }

    // MARK: Backfill estimate

    @Test("the backfill estimate counts only files inside the window, and saturates")
    func backfillEstimate() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let root = URL(fileURLWithPath: "/tmp/jrbar-estimate")
        let source = ArchiveSource(id: "s", name: "S", root: root, extensions: ["jsonl"])
        func file(_ name: String, bytes: Int64, daysAgo: Double?) -> ArchiveSourceFile {
            ArchiveSourceFile(url: root.appendingPathComponent(name), byteCount: bytes,
                              modifiedAt: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
        }
        let inventory = ArchiveSourceInventory(source: source, files: [
            file("a", bytes: 100, daysAgo: 1), file("b", bytes: 200, daysAgo: 29.9),
            file("c", bytes: 400, daysAgo: 31), file("d", bytes: 800, daysAgo: nil),
        ], warnings: [])
        #expect(ArchiveBackfillEstimate.of(inventory, days: 30, now: now)
                == ArchiveBackfillEstimate(fileCount: 2, byteCount: 300))
        #expect(ArchiveBackfillEstimate.of(inventory, days: 7, now: now)
                == ArchiveBackfillEstimate(fileCount: 1, byteCount: 100))
        // No window: every file, dated or not.
        #expect(ArchiveBackfillEstimate.of(inventory, days: 0, now: now)
                == ArchiveBackfillEstimate(fileCount: 4, byteCount: 1_500))
        let huge = ArchiveBackfillEstimate(fileCount: 1, byteCount: .max)
        #expect(ArchiveBackfillEstimate.total([huge, huge]).byteCount == .max)
        #expect(ArchiveBackfillEstimate.total([]) == .zero)
    }

    // MARK: Fixture

    private struct Fixture {
        let root: URL
        let archive: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("jrbar-capture-\(UUID().uuidString)", isDirectory: true)
            archive = root.appendingPathComponent("archive", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func source() throws -> ArchiveSource {
            let dir = root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            return ArchiveSource(id: "test-source", name: "Test", root: dir, extensions: ["jsonl"])
        }

        /// A file inside the watched source root, returned in the canonical
        /// (/private/var) form the capture engine keys capture_state by.
        func file(_ name: String, data: Data) throws -> URL {
            let dir = root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return URL(fileURLWithPath: DataHoarderArchive.canonicalPath(url.path))
        }

        /// Writes the object store entry and returns its v2-shaped record.
        func v2Record(name: String, data: Data) throws -> ArchiveRecord {
            let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let objects = archive.appendingPathComponent("objects", isDirectory: true)
            try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
            try data.write(to: objects.appendingPathComponent(id))
            return ArchiveRecord(
                id: id, name: name, sourcePath: root.appendingPathComponent(name).path,
                byteCount: Int64(data.count), importedAt: Date(timeIntervalSince1970: 2_000),
                sourceModifiedAt: Date(timeIntervalSince1970: 1_000))
        }

        /// Hand-builds the v2 catalog the migration upgrades: records,
        /// metadata, removed_records at `user_version = 2` — nothing more.
        func writeV2Catalog(saved: [ArchiveRecord], trashed: [ArchiveRecord]) throws {
            let path = archive.appendingPathComponent("catalog.sqlite3")
            var database: OpaquePointer?
            guard sqlite3_open(path.path, &database) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { sqlite3_close(database) }
            func exec(_ sql: String) throws {
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try exec("""
            CREATE TABLE records(
                id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 64),
                name TEXT NOT NULL,
                source_path TEXT NOT NULL,
                byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
                imported_at REAL NOT NULL,
                source_modified_at REAL
            ) WITHOUT ROWID
            """)
            try exec("CREATE TABLE metadata(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID")
            try exec("CREATE TABLE removed_records(id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 64), record_json TEXT) WITHOUT ROWID")
            for record in saved {
                try exec("""
                INSERT INTO records VALUES('\(record.id)', '\(record.name)', '\(record.sourcePath)',
                    \(record.byteCount), \(record.importedAt.timeIntervalSinceReferenceDate),
                    \(record.sourceModifiedAt?.timeIntervalSinceReferenceDate ?? 0))
                """)
            }
            for record in trashed {
                // A v2 trash row carries the old six-field record shape.
                let json = """
                {"id":"\(record.id)","name":"\(record.name)","sourcePath":"\(record.sourcePath)","byteCount":\(record.byteCount),"importedAt":\(record.importedAt.timeIntervalSinceReferenceDate),"sourceModifiedAt":\(record.sourceModifiedAt?.timeIntervalSinceReferenceDate ?? 0)}
                """
                try exec("INSERT INTO removed_records VALUES('\(record.id)', '\(json)')")
            }
            try exec("PRAGMA user_version = 2")
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
