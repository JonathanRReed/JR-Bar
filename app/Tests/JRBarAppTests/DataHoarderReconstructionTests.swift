import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Data Hoarder record detail")
@MainActor
struct DataHoarderReconstructionTests {
    private func makeArchive() throws -> (URL, DataHoarderArchive) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, DataHoarderArchive(root: root.appending(path: "archive")))
    }

    private func claudeTranscript(intent: String) -> Data {
        Data("""
        {"type":"user","sessionId":"sess-1","cwd":"/tmp/proj","timestamp":"2026-09-19T10:00:00Z","uuid":"u1","message":{"role":"user","content":"\(intent)"}}
        {"type":"assistant","timestamp":"2026-09-19T10:00:01Z","uuid":"a1","parentUuid":"u1","message":{"model":"claude-test","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"deploy --force"}}]}}
        {"type":"user","timestamp":"2026-09-19T10:00:02Z","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom: permission denied"}]}}

        """.utf8)
    }

    private func cliproxyLog(status: Int, at stamp: String = "2026-09-19T10:00:00Z") -> Data {
        Data("""
        === REQUEST INFO ===
        Version: 1.0
        URL: http://localhost:8317/v1/messages?x=1
        Method: POST
        Timestamp: \(stamp)
        === HEADERS ===
        User-Agent: claude-cli/2.1.222 (external)
        X-Claude-Code-Session-Id: sess-1
        === REQUEST BODY ===
        {"model":"claude-test","session_id":"sess-1"}
        === API REQUEST 1 ===
        Upstream URL: https://api.anthropic.com/v1/messages?key=secret
        HTTP Method: POST
        Headers:
        Authorization: Bearer sk-secret
        Body:
        {"model":"claude-test"}
        === RESPONSE ===
        Status: \(status)
        Content-Type: application/json

        {"error":{"message":"overloaded"}}
        """.utf8)
    }

    private func transcriptRecord(
        in archive: DataHoarderArchive, intent: String,
        sessionID: String? = "sess-1", provider: String? = "claude"
    ) async throws -> ArchiveRecord {
        let record = try await archive.createLiveRecord(
            name: "t-\(UUID().uuidString).jsonl", sourcePath: "/tmp/t.jsonl",
            provider: provider, sessionID: sessionID)
        _ = try await archive.appendSegment(
            recordID: record.id, data: claudeTranscript(intent: intent), byteOffset: 0)
        return record
    }

    @Test func reconstructionLoadsForAClaudeTranscriptRecord() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await transcriptRecord(in: archive, intent: "please deploy the build")
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        model.selectedID = record.id
        await model.loadDetail()
        #expect(model.detailKind == .transcript)
        #expect(model.detailError == nil)
        let reconstruction = try #require(model.reconstruction)
        #expect(!reconstruction.items.isEmpty)
        #expect(reconstruction.items.contains { $0.kind == .toolUse && $0.name == "Bash" })
        #expect(reconstruction.items.contains { $0.kind == .toolResult && $0.isError })
        #expect(reconstruction.story.failed)
        #expect(reconstruction.story.errorCount == 1)
        #expect(reconstruction.story.lastUserIntent == "please deploy the build")
        #expect(reconstruction.story.lastErrorSummary == "tool `Bash` failed")
        #expect(reconstruction.story.diedMidTurn)
        #expect(reconstruction.story.failedToolNames == ["Bash"])
    }

    @Test func redactedSegmentsFlagItemsWithoutCrashing() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await archive.createLiveRecord(
            name: "redacted.jsonl", sourcePath: "/tmp/redacted.jsonl", provider: "claude")
        let redacted = TranscriptRedactor.redact(claudeTranscript(intent: "secret ask"))
        _ = try await archive.appendSegment(recordID: record.id, data: redacted, byteOffset: 0)
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        model.selectedID = record.id
        await model.loadDetail()
        #expect(model.detailKind == .transcript)
        #expect(model.detailError == nil)
        let reconstruction = try #require(model.reconstruction)
        #expect(reconstruction.redactedLines > 0)
        #expect(reconstruction.items.contains { $0.redacted })
        // Structure survives: tool names and error flags are not content.
        #expect(reconstruction.items.contains { $0.kind == .toolUse && $0.name == "Bash" })
        #expect(reconstruction.story.errorCount >= 1)
    }

    @Test func cliProxyRecordParsesItsCardFromARedactedCopy() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        // No provider metadata — the segment content itself must classify it.
        let record = try await archive.createLiveRecord(
            name: "req.log", sourcePath: "/tmp/req.log")
        _ = try await archive.appendSegment(
            recordID: record.id, data: CLIProxyRedactor.redact(cliproxyLog(status: 503)),
            byteOffset: 0)
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        model.selectedID = record.id
        await model.loadDetail()
        #expect(model.detailKind == .cliProxy)
        let request = try #require(model.cliProxyRequest)
        #expect(request.method == "POST")
        #expect(request.path == "localhost:8317/v1/messages")
        #expect(request.status == 503)
        #expect(request.client == "claude-cli/2.1.222")
        #expect(request.sessionID == "sess-1")
        #expect(request.upstreamURL == "api.anthropic.com/v1/messages")
        #expect(request.attemptCount == 1)
        #expect(request.errorSummary?.hasPrefix("HTTP 503") == true)
        // The redacted copy keeps the skeleton, not the bodies — model is content.
        #expect(request.model == nil)
        #expect(model.reconstruction == nil)
    }

    @Test func relatedRecordsWireTranscriptsAndProxiedRequests() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = try await transcriptRecord(in: archive, intent: "ask")
        var proxies: [ArchiveRecord] = []
        for index in 0..<2 {
            let proxy = try await archive.createLiveRecord(
                name: "req-\(index).log", sourcePath: "/tmp/req-\(index).log",
                provider: "cliproxy", sessionID: "sess-1")
            _ = try await archive.appendSegment(
                recordID: proxy.id, data: cliproxyLog(status: 200), byteOffset: 0)
            proxies.append(proxy)
        }
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        model.selectedID = transcript.id
        await model.loadDetail()
        #expect(model.relatedRecords.count == 2)
        #expect(Set(model.relatedRecords.map(\.id)) == Set(proxies.map(\.id)))

        model.selectedID = proxies[0].id
        await model.loadDetail()
        #expect(model.relatedRecords.contains { $0.id == transcript.id })
        #expect(model.relatedRecords.contains { $0.id == proxies[1].id })

        // Clicking a related row selects that record in the saved list.
        model.openRelated(transcript)
        #expect(model.selectedID == transcript.id)
    }

    @Test func aTranscriptCarriesItsProxiedRequestsBetweenTheTurns() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = try await transcriptRecord(in: archive, intent: "ask")
        for (index, (status, stamp)) in [(529, "2026-09-19T10:00:00.500Z"), (200, "2026-09-19T10:00:01.500Z")].enumerated() {
            let proxy = try await archive.createLiveRecord(
                name: "req-\(index).log", sourcePath: "/tmp/req-\(index).log",
                provider: "cliproxy", sessionID: "sess-1")
            _ = try await archive.appendSegment(
                recordID: proxy.id, data: cliproxyLog(status: status, at: stamp), byteOffset: 0)
        }
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        model.selectedID = transcript.id
        await model.loadDetail()
        let reconstruction = try #require(model.reconstruction)
        #expect(reconstruction.proxyRequests.map(\.status) == [529, 200])
        #expect(SessionProxyEvidence.summary(reconstruction.proxyRequests) == "1 × HTTP 529, then it went through")
        // The 529 lands after the ask and before the reply's tool call.
        let kinds = reconstruction.entries.map { entry -> String in
            switch entry {
            case .item(let item): item.kind.rawValue
            case .request(_, let request): "request:\(request.status ?? 0)"
            }
        }
        #expect(kinds == ["message", "request:529", "toolUse", "request:200", "toolResult"])

        // The Overview's archived fallback carries the same evidence.
        let archived = try #require(await DataHoarderModel.archivedTimeline(in: archive, sessionID: "sess-1"))
        #expect(archived.0.proxyRequests.count == 2)
        #expect(await DataHoarderModel.proxyRequests(in: archive, sessionID: "sess-1").count == 2)
        #expect(await DataHoarderModel.proxyRequests(in: archive, sessionID: "nobody").isEmpty)
    }

    @Test func aTranscriptExportsAsReadableMarkdown() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await transcriptRecord(in: archive, intent: "please deploy the build")
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        #expect(!model.canExportMarkdown)
        model.selectedID = record.id
        await model.loadDetail()
        #expect(model.canExportMarkdown)
        let selected = try #require(model.selected)
        let text = DataHoarderModel.markdown(for: selected, reconstruction: try #require(model.reconstruction))
        #expect(text.contains("- **Provider:** Claude"))
        #expect(text.contains("- **Session:** sess-1"))
        #expect(text.contains("- **Archived file:** \(selected.name)"))
        #expect(text.contains("## What happened\n\nLast asked: please deploy the build. Then tool `Bash` failed."))
        #expect(text.contains("tool `Bash`"))
        #expect(text.contains("boom: permission denied"))
    }

    @Test func historySearchReadsWhatTranscriptsSaid() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await transcriptRecord(in: archive, intent: "please rotate the signing keys")
        let proxy = try await archive.createLiveRecord(
            name: "req.log", sourcePath: "/tmp/req.log", provider: "cliproxy", sessionID: "sess-proxy")
        _ = try await archive.appendSegment(recordID: proxy.id, data: cliproxyLog(status: 200), byteOffset: 0)
        _ = try await archive.indexPendingSegments()
        let hits = await DataHoarderModel.transcriptHits(in: archive, query: "signing")
        #expect(Array(hits.keys) == ["sess-1"])
        #expect(hits["sess-1"]?.contains("«signing»") == true)
        // Proxy logs are not transcripts, and a miss is empty, not an error.
        #expect(await DataHoarderModel.transcriptHits(in: archive, query: "overloaded").isEmpty)
        #expect(await DataHoarderModel.transcriptHits(in: archive, query: "nothing-like-this").isEmpty)
    }

    @Test func gapStateAndSegmentNotesAreSurfaced() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await transcriptRecord(in: archive, intent: "ask")
        _ = try await archive.appendSegment(
            recordID: record.id, data: claudeTranscript(intent: "ask again"),
            byteOffset: 0, note: "gap: source rewritten")
        try await archive.setCaptureState(id: record.id, state: .gap)
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        model.selectedID = record.id
        #expect(model.selected?.captureState == .gap)
        await model.loadDetail()
        #expect(model.segmentNotes == ["gap: source rewritten"])
        #expect(model.detailError == nil)
        #expect(model.reconstruction != nil)
    }

    @Test func anUnlabelledJSONLRecordStillGetsAnHonestTimeline() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        // Provider unset and not a claude/codex shape — the cheap JSONL check
        // should still offer the Timeline pane, with the gap named.
        let record = try await archive.createLiveRecord(
            name: "mystery.jsonl", sourcePath: "/tmp/mystery.jsonl")
        _ = try await archive.appendSegment(
            recordID: record.id,
            data: Data("{\"kind\":\"something-else\"}\n".utf8), byteOffset: 0)
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        model.selectedID = record.id
        await model.loadDetail()
        #expect(model.detailKind == .transcript)
        let reconstruction = try #require(model.reconstruction)
        #expect(reconstruction.gaps.contains("unsupported_provider"))
    }

    @Test func aSelectionChangeMidLoadCannotPaintTheWrongRecord() async throws {
        let (root, archive) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await transcriptRecord(in: archive, intent: "first record intent")
        let second = try await transcriptRecord(in: archive, intent: "second record intent")
        let model = DataHoarderModel(archive: archive)
        await model.reload()

        model.selectedID = first.id
        let staleLoad = Task { await model.loadDetail() }
        await Task.yield()
        model.selectedID = second.id
        let freshLoad = Task { await model.loadDetail() }
        await staleLoad.value
        await freshLoad.value

        let reconstruction = try #require(model.reconstruction)
        #expect(reconstruction.story.lastUserIntent == "second record intent")
        #expect(model.detailError == nil)
        #expect(model.detailLoading == false)
    }
}
