import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Data Hoarder import review")
@MainActor
struct DataHoarderModelTests {
    @Test func emptyTrashRequiresConfirmationAndIncludesSearchHiddenEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "trace.jsonl")
        try Data("fixture".utf8).write(to: source)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let record = try await archive.importFile(source)
        try await archive.moveToTrash(id: record.id)
        let model = DataHoarderModel(archive: archive)
        model.showTrash = true
        model.query = "no matches"
        await model.reload()
        #expect(model.records.isEmpty)
        await model.confirmEmptyTrash { records in
            #expect(records == [record])
            return false
        }?.value
        #expect(try await archive.trashedRecords() == [record])
        #expect(model.busy == false)
        await model.confirmEmptyTrash { records in
            #expect(records == [record])
            return true
        }?.value
        #expect(try await archive.trashedRecords().isEmpty)
        #expect(try Data(contentsOf: source) == Data("fixture".utf8))
        #expect(model.message == "Deleted 1 archived copy.")
        #expect(model.busy == false && model.error == nil)
    }

    @Test func archiveTrashActionsWorkWhileImportsAreOff() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "trace.jsonl")
        try Data("fixture".utf8).write(to: source)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let record = try await archive.importFile(source)
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        await model.moveSelectedToTrash()
        await model.reload()
        #expect(model.records.isEmpty)
        #expect(model.message?.contains("Archive Trash") == true)
        model.showTrash = true
        #expect(model.selectedID == nil)
        await model.reload()
        await model.loadPreview()
        #expect(model.records == [record])
        #expect(model.preview == "fixture")
        await model.restoreSelected()
        await model.reload()
        #expect(model.records.isEmpty)
        model.showTrash = false
        await model.reload()
        #expect(model.records == [record])
        #expect(model.busy == false && model.enabled == false)
    }

    @Test func storageTotalsIgnoreSearchAndReportCatalogFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "trace.jsonl")
        try Data("fixture".utf8).write(to: source)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        _ = try await archive.importFile(source)
        let model = DataHoarderModel(archive: archive)
        model.enabled = false
        model.query = "no matches"
        await model.reload()
        await model.refreshStorage()
        #expect(model.records.isEmpty)
        #expect(model.storageUsage?.recordCount == 1)
        #expect(model.storageUsage?.contentBytes == 7)
        #expect(model.storageError == nil)
        #expect(model.measuringStorage == false)
        try Data("invalid".utf8).write(to: root.appending(path: "archive/catalog.sqlite3"))
        await model.refreshStorage()
        #expect(model.storageUsage == nil)
        #expect(model.storageError != nil)
        #expect(model.measuringStorage == false)
    }

    @Test func completeExportIncludesSearchHiddenRecordsWhileImportsAreOff() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "trace.jsonl")
        try Data("saved fixture".utf8).write(to: source)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let record = try await archive.importFile(source)
        let model = DataHoarderModel(archive: archive)
        model.enabled = false
        model.query = "no matches"
        model.records = []
        let destination = root.appending(path: "complete")
        await model.exportArchive(to: destination)
        #expect(model.busy == false)
        #expect(model.exportingArchive == false)
        #expect(model.error == nil)
        #expect(model.message == "Exported 1 file with archive metadata.")
        #expect(try await DataHoarderArchive(root: destination).records() == [record])
        // The model's only caller is post-NSSavePanel "Replace?" consent —
        // a second export overwrites rather than refusing.
        await model.exportArchive(to: destination)
        #expect(model.error == nil)
        #expect(model.message == "Exported 1 file with archive metadata.")
        #expect(model.busy == false)
        #expect(try await archive.records() == [record])
    }

    @Test func aCancelledImportKeepsFilesAvailableForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "trace.jsonl")
        try Data("synthetic cancellation fixture".utf8).write(to: source)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let model = DataHoarderModel(archive: archive)
        model.enabled = true
        model.copyContents = true
        model.candidates = [ArchiveImportCandidate(url: source, size: 30, modified: nil)]
        let job = Task { await model.importSelected() }
        job.cancel()
        await job.value
        #expect(try await archive.records().isEmpty)
        #expect(model.candidates.count == 1)
        #expect(model.busy == false)
        #expect(model.error == nil)
        #expect(model.message?.contains("stopped") == true)
    }

    @Test func bulkFailuresStayBoundedAndDoNotRemovePendingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))
        model.enabled = true
        model.copyContents = true
        model.candidates = (0..<20).map {
            ArchiveImportCandidate(url: root.appending(path: "missing-\($0).jsonl"), size: 0, modified: nil)
        }
        await model.importSelected()
        #expect(model.candidates.count == 20)
        #expect(model.error?.contains("20 files could not be archived") == true)
        #expect(model.error?.contains("missing-19.jsonl") == false)
        #expect(model.error?.contains("remain in review") == true)
        #expect(model.busy == false)
        model.cancelReview()
        #expect(model.error == nil)
        #expect(model.candidates.isEmpty)
    }

    @Test func stoppingDoesNotLaunchAnUnrelatedContentSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("unreadable index".utf8).write(to: root.appending(path: "manifest.json"))
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root))
        model.enabled = true
        model.copyContents = true
        model.query = "payload"
        model.candidates = [ArchiveImportCandidate(url: root.appending(path: "pending.jsonl"), size: 10, modified: nil)]
        let job = Task { await model.importSelected() }
        job.cancel()
        await job.value
        #expect(model.busy == false)
        #expect(model.importProgress == nil)
        #expect(model.searchError == nil)
        #expect(model.message?.contains("stopped") == true)
    }

    @Test func byteTotalsCannotOverflow() {
        #expect(DataHoarderModel.totalBytes([12, 30]) == 42)
        #expect(DataHoarderModel.totalBytes([.max, 1]) == .max)
    }

    @Test func aDisabledUtilityOrPausedCaptureStartsNoWatchers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = root.appending(path: "watch")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))

        // Capture toggled on for a source, but the utility is off → nothing runs.
        model.captureSettings.captureSources = [watch.path: true]
        await model.applyCaptureNow()
        #expect(await model.capture.activeSourceIDs.isEmpty)
        #expect(model.captureRunning == false)

        // Paused first, then enabled — every reconcile converges on stopped.
        model.captureSettings.paused = true
        model.enabled = true
        await model.applyCaptureNow()
        #expect(await model.capture.activeSourceIDs.isEmpty)

        // Live: unpause → the custom-path source starts watching.
        model.captureSettings.paused = false
        await model.applyCaptureNow()
        #expect(await model.capture.activeSourceIDs == [watch.path])
        #expect(model.captureRunning == true)

        // Off again → everything stops.
        model.enabled = false
        await model.applyCaptureNow()
        #expect(await model.capture.activeSourceIDs.isEmpty)
        #expect(model.captureRunning == false)
    }

    @Test func pausingDuringTheFirstBackfillCancelsItInsteadOfWaiting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = root.appending(path: "watch")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try Data("inside the window\n".utf8).write(to: watch.appending(path: "a.jsonl"))
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let model = DataHoarderModel(archive: archive)
        model.captureSettings.captureSources = [watch.path: true]
        model.captureSettings.backfillDays = 30
        await model.applyCaptureNow()

        // Turn On queues a start that would read the backfill; Pause lands
        // before it runs. The pause cancels the start instead of queueing
        // behind the whole window.
        model.enabled = true
        model.captureSettings.paused = true
        await model.applyCaptureNow()
        #expect(await model.capture.activeSourceIDs.isEmpty)
        #expect(model.captureRunning == false)
        // Nothing read, and the scan left unstamped — the next start
        // reads the window from its beginning.
        #expect(try await archive.records().isEmpty)
        #expect(try await archive.metadata(key: "capture_last_scan:" + watch.path) == nil)
    }

    @Test func switchingOnTwiceStartsTheEngineOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = root.appending(path: "watch")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))
        model.captureSettings.captureSources = [watch.path: true]
        await model.applyCaptureNow()
        let before = model.captureApplies

        // The utility's setter, then the store's echo of the same value.
        model.enabled = true
        model.enabled = true
        #expect(model.captureApplies == before + 1)
        await model.applyCaptureNow()
        #expect(model.captureApplies == before + 1)
        #expect(await model.capture.activeSourceIDs == [watch.path])

        // A real change while an apply is on its way still queues behind it.
        model.enabled = false
        model.enabled = true
        model.enabled = false
        await model.applyCaptureNow()
        #expect(model.captureApplies == before + 4)
        #expect(await model.capture.activeSourceIDs.isEmpty)
        #expect(model.captureRunning == false)
    }

    @Test func captureTogglesPersistThroughTheStoreCallback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var persisted = UtilitiesState()
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))
        model.onCaptureSettingsChange = { persisted.dataHoarder = $0 }

        model.setCapture(true, sourceID: "codex-sessions")
        #expect(persisted.dataHoarder.captureSources["codex-sessions"] == true)
        #expect(model.backfillOffer == "codex-sessions")
        model.captureSettings.fullContent = true
        #expect(persisted.dataHoarder.fullContent == true)
        model.captureSettings.paused = true
        #expect(persisted.dataHoarder.paused == true)

        // A store-side apply mirrors in without echoing back out.
        var mirrored = false
        model.onCaptureSettingsChange = { _ in mirrored = true }
        var incoming = DataHoarderSettings()
        incoming.captureSources = ["claude-projects": true]
        model.applyCaptureSettings(incoming)
        #expect(model.captureSettings.captureSources == ["claude-projects": true])
        #expect(mirrored == false, "mirroring must not bounce the same settings back")

        // Every persisted dial mirrors in — trash retention included, or a
        // relaunch would show "keep forever" and the next edit would save it.
        incoming.trashRetentionDays = 30
        model.applyCaptureSettings(incoming)
        #expect(model.captureSettings == incoming)
        #expect(mirrored == false)
    }

    @Test func historyOfferTurnsAgentSourcesOnWithABackfillWindowAndNoReview() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var persisted = UtilitiesState()
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))
        model.onCaptureSettingsChange = { persisted.dataHoarder = $0 }
        #expect(model.keepsAgentTranscripts == false)
        #expect(model.offersImportReviewOnCapture)

        model.keepAgentTranscripts(sourceIDs: ["claude-projects", "codex-sessions"], backfillDays: 30)
        #expect(persisted.dataHoarder.captureSources == ["claude-projects": true, "codex-sessions": true])
        #expect(persisted.dataHoarder.backfillDays == 30)
        // Consent covers structure only: full content stays off.
        #expect(persisted.dataHoarder.fullContent == false)
        // The window reads the recent files itself — no import review that
        // would archive them a second time.
        #expect(model.backfillOffer == nil)
        #expect(model.offersImportReviewOnCapture == false)
        model.setCapture(true, sourceID: "gemini-chats")
        #expect(model.backfillOffer == nil)
        // Settings alone do not count: the utility must be on. Paused
        // first, so switching on never watches this Mac's real agent
        // folders from a test — and a paused capture still counts.
        #expect(model.keepsAgentTranscripts == false)
        model.captureSettings.paused = true
        model.enabled = true
        #expect(model.keepsAgentTranscripts)

        let now = Date(timeIntervalSince1970: 5_000_000)
        #expect(model.backfillSince(now: now) == now.addingTimeInterval(-30 * 86_400))
        model.captureSettings.backfillDays = nil
        #expect(model.backfillSince(now: now) == nil)

        // The proxy's request logs are not a session source.
        let other = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "other")))
        other.captureSettings.paused = true
        other.enabled = true
        other.captureSettings.captureSources = [ArchiveSource.cliProxyAPILogs: true]
        #expect(other.keepsAgentTranscripts == false)
        #expect(!DataHoarderModel.agentSources().map(\.id).contains(ArchiveSource.cliProxyAPILogs))
        await model.applyCaptureNow()
        await other.applyCaptureNow()
        #expect(await model.capture.activeSourceIDs.isEmpty)
        #expect(await other.capture.activeSourceIDs.isEmpty)
    }

    @Test func searchRunsCancellablePagesAndLoadMore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let record = try await archive.createLiveRecord(name: "s.jsonl", sourcePath: "/tmp/s.jsonl")
        _ = try await archive.appendSegment(
            recordID: record.id, data: Data("zzq marker token\n".utf8), byteOffset: 0)
        let model = DataHoarderModel(archive: archive)
        model.enabled = true
        model.query = "zzq"
        await model.runSearch()
        #expect(model.searchError == nil, "searchError=\(model.searchError ?? "nil")")
        #expect(model.searchResults.map(\.record.id) == [record.id])
        #expect(model.searchHasMore == false)
        await model.loadMoreSearch()
        #expect(model.searchResults.count == 1)
        // A stale revision can't overwrite a newer query's results.
        model.query = "nothing-matches-this"
        await model.runSearch()
        #expect(model.searchResults.isEmpty)
    }
    @Test func historyDiscoveryNeedsSelectionAndSeparateContentConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appending(path: "history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let sourceFile = history.appending(path: "session.jsonl")
        try Data("{\"event\":\"fixture\"}".utf8).write(to: sourceFile)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let model = DataHoarderModel(archive: archive)
        let source = ArchiveSource(id: "fixture", name: "Fixture", root: history, extensions: ["jsonl"])
        await model.discoverHistory(sources: [source])
        #expect(model.sourceInventories.isEmpty)
        model.enabled = true
        await model.discoverHistory(sources: [source])
        #expect(model.sourceInventories.first?.files.count == 1)
        #expect(model.selectedHistoryFiles.isEmpty)
        #expect(try await archive.records().isEmpty)
        model.selectedSources = [source.id]
        model.copyContents = true
        model.reviewHistorySelection()
        #expect(model.copyContents == false)
        #expect(model.candidates.count == 1)
        await model.importSelected()
        #expect(try await archive.records().isEmpty)
        model.copyContents = true
        await model.importSelected()
        #expect(try await archive.records().count == 1)
        #expect(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    @Test func modificationFilterAndOverlappingSourcesDoNotDuplicateReviewFiles() {
        let model = DataHoarderModel()
        let root = URL(fileURLWithPath: "/tmp/jrbar-source-fixture")
        let source = ArchiveSource(id: "one", name: "One", root: root, extensions: ["jsonl"])
        let second = ArchiveSource(id: "two", name: "Two", root: root, extensions: ["jsonl"])
        let fresh = ArchiveSourceFile(url: root.appending(path: "new.jsonl"), byteCount: 10, modifiedAt: Date())
        let old = ArchiveSourceFile(url: root.appending(path: "old.jsonl"), byteCount: 20,
                                    modifiedAt: Date().addingTimeInterval(-90 * 86_400))
        model.sourceInventories = [ArchiveSourceInventory(source: source, files: [fresh, old], warnings: []),
                                  ArchiveSourceInventory(source: second, files: [fresh], warnings: [])]
        model.selectedSources = ["one", "two"]
        #expect(model.selectedHistoryFiles.count == 1)
        model.historyWindowDays = 0
        #expect(model.selectedHistoryFiles.count == 2)
    }

    @Test func searchDoesNotErasePreviewIntegrityErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "trace.txt")
        let archiveRoot = root.appending(path: "archive")
        let archive = DataHoarderArchive(root: archiveRoot)
        try Data("original".utf8).write(to: source)
        let damaged = try await archive.importFile(source)
        try Data("changed".utf8).write(to: archiveRoot.appending(path: "objects").appending(path: damaged.id))
        try Data("healthy".utf8).write(to: source)
        let healthy = try await archive.importFile(source)
        let model = DataHoarderModel(archive: archive)
        await model.reload()
        model.selectedID = damaged.id
        await model.loadPreview()
        #expect(model.previewError != nil)
        await model.reload()
        #expect(model.displayedError == model.previewError)
        #expect(model.preview.contains("unavailable"))
        model.selectedID = healthy.id
        await model.loadPreview()
        #expect(model.previewError == nil)
        #expect(model.preview == "healthy")
        await model.reload()
        model.selectedID = damaged.id
        await model.loadPreview()
        #expect(model.displayedError != nil)
    }

    @Test func selectedFilesRequireEnablementAndContentsConsent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "trace.jsonl")
        try Data("{\"event\":\"test\"}".utf8).write(to: source)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let model = DataHoarderModel(archive: archive)
        model.candidates = [ArchiveImportCandidate(url: source, size: 16, modified: nil)]

        model.copyContents = true
        await model.importSelected()
        #expect(try await archive.records().isEmpty)

        model.enabled = true
        model.copyContents = false
        await model.importSelected()
        #expect(try await archive.records().isEmpty)

        model.copyContents = true
        await model.importSelected()
        #expect(model.error == nil)
        #expect(model.records.count == 1)
        #expect(model.candidates.isEmpty)
        #expect(model.busy == false)
        #expect(FileManager.default.fileExists(atPath: source.path))

        model.enabled = false
        await model.reload()
        await model.loadPreview()
        #expect(model.records.count == 1)
        #expect(model.preview.contains("test"))
    }

    @Test func failedImportsRemainSelectedForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))
        model.enabled = true
        model.copyContents = true
        model.candidates = [ArchiveImportCandidate(url: root.appending(path: "missing.json"), size: 0, modified: nil)]
        await model.importSelected()
        #expect(model.error != nil)
        #expect(model.candidates.count == 1)
        #expect(model.records.isEmpty)
        #expect(model.busy == false)
    }

    // MARK: lane utilities

    @Test func theProviderPickerListsEveryCapturingSourcesAgent() {
        #expect(DataHoarderProviders.choices(enabledSources: []) == ["claude", "codex", "other"])
        let all = ArchiveSource.defaults().map(\.id)
        #expect(DataHoarderProviders.choices(enabledSources: all)
                == ["claude", "codex", "pi", "gemini", "grok", "cliproxy", "other"])
        #expect(DataHoarderProviders.choices(enabledSources: ["grok-sessions", "/Users/jr/logs"])
                == ["claude", "codex", "grok", "other"])
        #expect(DataHoarderProviders.title("gemini") == ProviderStyle.style(for: "gemini").name)
        #expect(DataHoarderProviders.title("other") == "Other")
        #expect(DataHoarderProviders.title("cliproxy") == "CLIProxyAPI")
    }

    @Test func importedAgentsAndASavedPickKeepTheirRowsWithCaptureOff() {
        // Find History brought in pi and Grok files; no source captures.
        let found = DataHoarderProviders.choices(enabledSources: [],
                                                 archived: ["claude", "pi", nil, "grok", "pi", "other", ""])
        #expect(Array(found.prefix(2)) == ["claude", "codex"])
        #expect(found.last == "other")
        #expect(Set(found) == ["claude", "codex", "pi", "grok", "other"], "each agent once: \(found)")
        // A saved Gemini filter whose source was switched off keeps its row.
        #expect(DataHoarderProviders.choices(enabledSources: [], selected: "gemini")
                == ["claude", "codex", "gemini", "other"])
        // A capturing source's agent keeps its place in the sources' order.
        #expect(DataHoarderProviders.choices(enabledSources: ["grok-sessions"], archived: ["grok", "pi"])
                == ["claude", "codex", "grok", "pi", "other"])

        let model = DataHoarderModel(archive: DataHoarderArchive(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
        model.records = [ArchiveRecord(id: "r1", name: "r1.jsonl", sourcePath: "/tmp/r1.jsonl", byteCount: 1,
                                       importedAt: Date(), sourceModifiedAt: nil, provider: "pi")]
        #expect(model.providerChoices.contains("pi"), "the imported pi record is findable by name")
    }

    @Test func theResumeCommandIsRightPerProvider() {
        let id = "5f1c9a2e-7d41-4b8e-9a0c-2f6e1d3b4a55"
        #expect(DataHoarderProviders.resumeCommand(provider: "claude", sessionID: id, project: nil)
                == "claude --resume \(id)")
        #expect(DataHoarderProviders.resumeCommand(provider: "codex", sessionID: id, project: "/Users/jr/JR-Bar")
                == "cd '/Users/jr/JR-Bar' && codex resume \(id)")
        #expect(DataHoarderProviders.resumeCommand(provider: "cursor", sessionID: id, project: "JR-Bar")
                == "cursor-agent --resume \(id)", "a bare repo name is not a folder to cd into")
        #expect(DataHoarderProviders.resumeCommand(provider: "claude", sessionID: id, project: "/Users/jr/it's")
                == "cd '/Users/jr/it'\\''s' && claude --resume \(id)")
        #expect(DataHoarderProviders.resumeCommand(provider: "pi", sessionID: id, project: nil) == nil)
        #expect(DataHoarderProviders.resumeCommand(provider: "claude", sessionID: nil, project: nil) == nil)
        #expect(DataHoarderProviders.resumeCommand(provider: "claude", sessionID: "x; rm -rf ~", project: nil) == nil)
        #expect(DataHoarderProviders.agentID(provider: "claude", sessionID: id) == "claude:session:\(id)")
    }

    @Test func copyResumeCommandPutsTheLineOnThePasteboard() {
        let model = DataHoarderModel(archive: DataHoarderArchive(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
        let record = ArchiveRecord(id: "r1", name: "r1.jsonl", sourcePath: "/tmp/r1.jsonl", byteCount: 1,
                                   importedAt: Date(), sourceModifiedAt: nil, provider: "codex",
                                   sessionID: "abc-123", project: nil)
        let board = NSPasteboard(name: NSPasteboard.Name("jrbar-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        model.copyResumeCommand(record, to: board)
        #expect(board.string(forType: .string) == "codex resume abc-123")
        #expect(model.message?.contains("codex resume abc-123") == true)
    }

    @Test func piRecordsCaptureUnderPiAndOldOnesAreRelabelled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sessions = root.appending(path: "pi-sessions-root")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let source = ArchiveSource(id: "pi-sessions", name: "pi sessions", root: sessions, extensions: ["jsonl"])
        let file = sessions.appending(path: "run.jsonl")
        try Data("seed\n".utf8).write(to: file)
        let capture = DataHoarderCapture(archive: archive)
        await capture.start(sources: [source], fullContent: false)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"message","role":"user","content":"hi"}"# + "\n").utf8))
        try handle.close()
        await capture.rescan(source: source)
        await capture.stop()
        let captured = try #require(try await archive.records().first)
        #expect(captured.provider == "pi", "the folder names the agent the probe could not")

        // A record from before the stamp reads "other" until relabelled.
        try await archive.updateRecordMetadata(id: captured.id, provider: "other")
        let imported = try await archive.importFile(file)
        #expect(imported.provider == nil || imported.provider == "other")
        let model = DataHoarderModel(archive: archive, capture: capture)
        model.enabled = true
        let suite = "DataHoarderModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        await model.relabelSourceRecords(sources: [source], defaults: defaults)
        let providers = try await archive.records().map(\.provider)
        #expect(providers.allSatisfy { $0 == "pi" }, "\(providers)")

        // Once per Mac: a second opening reads nothing and changes nothing.
        let later = sessions.appending(path: "later.jsonl")
        try Data("seed\n".utf8).write(to: later)
        let unstamped = try await archive.importFile(later)
        #expect(unstamped.provider == nil || unstamped.provider == "other")
        await model.relabelSourceRecords(sources: [source], defaults: defaults)
        #expect(try await archive.records().first { $0.id == unstamped.id }?.provider == unstamped.provider)
        // An import is stamped as it lands instead.
        #expect(await model.stampSourceProvider(unstamped, sources: [source]))
        #expect(try await archive.records().first { $0.id == unstamped.id }?.provider == "pi")
        #expect(DataHoarderProviders.sourceProvider(forPath: "/elsewhere/run.jsonl", sources: [source]) == nil)
    }

    @Test func theCLIProxyConfigIsTheFirstThatExists() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jrbar-cliproxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let brew = folder.appending(path: "cliproxyapi.conf")
        try "port: 8317\n".write(to: brew, atomically: true, encoding: .utf8)
        let missing = folder.appending(path: "config.yaml").path
        #expect(DataHoarderProviders.cliProxyConfig(paths: [missing, brew.path]) == "port: 8317\n")
        #expect(DataHoarderProviders.cliProxyConfig(paths: [missing]) == nil)
    }

    @Test func aResumeTheDaemonCannotPlacePointsAtTheCopy() {
        let unknown = CoreReplyError(code: "not_found", message: "JR-Bar has no record of where that session ran.")
        #expect(DataHoarderProviders.resumeRefusal(unknown, title: "review")
                == "JR-Bar has no record of where that session ran — Copy Resume Command instead.")
        let remote = CoreReplyError(code: "unsupported", message: "A session on another Mac resumes on that Mac.")
        #expect(DataHoarderProviders.resumeRefusal(remote, title: "review") == remote.message)
        #expect(DataHoarderProviders.resumeRefusal(nil, title: "review") == "Could not resume review")
    }
}
