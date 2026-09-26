import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Saved evidence stays readable with capture disabled")
@MainActor
struct ArchiveReadBindingsRepairTests {
    @Test func disabledModelReadsThroughTheProductionHistoryAndOverviewBindings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = DataHoarderArchive(root: root)
        let transcript = try await archive.createLiveRecord(
            name: "fixture.jsonl", sourcePath: "/fixture/transcript.jsonl",
            provider: "claude", sessionID: "saved-session")
        let data = Data("""
        {"type":"user","sessionId":"saved-session","timestamp":"2026-09-19T10:00:00Z","uuid":"u1","message":{"role":"user","content":"repair the signing flow"}}

        """.utf8)
        _ = try await archive.appendSegment(recordID: transcript.id, data: data, byteOffset: 0)
        let proxy = try await archive.createLiveRecord(
            name: "request.log", sourcePath: "/fixture/request.log",
            provider: "cliproxy", sessionID: "saved-session")
        let request = Data("""
        === REQUEST INFO ===
        Version: 1.0
        URL: http://localhost:8317/v1/messages
        Method: POST
        Timestamp: 2026-09-19T10:00:00Z
        === HEADERS ===
        X-Claude-Code-Session-Id: saved-session
        === RESPONSE ===
        Status: 503
        Content-Type: application/json

        {"error":{"message":"fixture overload"}}
        """.utf8)
        _ = try await archive.appendSegment(recordID: proxy.id, data: request, byteOffset: 0)
        _ = try await archive.indexPendingSegments()
        let model = DataHoarderModel(archive: archive)
        #expect(!model.enabled)
        let core = CoreModel()
        let history = HistoryStore(core: core), overview = OverviewStore(core: core)
        ArchiveReadBindings.install(history: history, model: model)
        ArchiveReadBindings.install(overview: overview, model: model)
        #expect(history.canSearchTranscripts)
        let search = try #require(history.archiveSearch)
        let hits = await search("signing")
        #expect(hits["saved-session"] != nil)
        let timeline = try #require(overview.archiveTimeline)
        let saved = try #require(await timeline("saved-session"))
        #expect(saved.1.id == transcript.id)
        let evidence = try #require(overview.archiveProxyEvidence)
        let requests = await evidence("saved-session")
        #expect(requests.count == 1)
        #expect(requests.first?.status == 503)
        #expect(!model.enabled && !model.busy)
        let watched = await model.capture.activeSourceIDs
        #expect(watched.isEmpty)
    }

    @Test func emptyAndReleasedArchivesDoNotStartCaptureOrRetainTheirOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var model: DataHoarderModel? = DataHoarderModel(archive: DataHoarderArchive(root: root))
        weak var weakModel = model
        let core = CoreModel()
        let history = HistoryStore(core: core), overview = OverviewStore(core: core)
        ArchiveReadBindings.install(history: history, model: try #require(model))
        ArchiveReadBindings.install(overview: overview, model: try #require(model))
        let search = try #require(history.archiveSearch)
        let timeline = try #require(overview.archiveTimeline)
        let evidence = try #require(overview.archiveProxyEvidence)
        #expect(await search("missing").isEmpty)
        #expect(await timeline("missing") == nil)
        #expect(await evidence("missing").isEmpty)
        #expect(model?.enabled == false)
        model = nil
        #expect(weakModel == nil)
        #expect(!history.canSearchTranscripts)
        #expect(await search("missing").isEmpty)
        #expect(await timeline("missing") == nil)
        #expect(await evidence("missing").isEmpty)
    }
}
