import AppKit
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Archive runtime lifecycle")
struct ArchiveRuntimeLifecycleTests {
    @Test func disabledArchiveNeverCreatesItsDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root))
        model.applyCapture()
        await model.applyCaptureNow()
        await model.refreshCaptureStatus()
        model.pumpSearchIndex()
        #expect(model.captureApplies == 0)
        #expect(!model.captureRunning)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func archiveCloseDetachesContentAndReopenKeepsGeometry() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root))
        model.query = "synthetic query"
        let controller = DataHoarderWindowController(model: model)
        let window = controller.makeWindow()
        let frame = window.frame
        let minimum = window.minSize
        weak var originalHost: NSViewController?
        autoreleasepool {
            let first = controller.attachContent(to: window)
            originalHost = first
            #expect(controller.attachContent(to: window) === first)
        }
        autoreleasepool {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        }
        for _ in 0..<3 { await Task.yield() }
        #expect(window.contentViewController == nil)
        #expect(originalHost == nil)
        #expect(model.query == "synthetic query")
        #expect(window.frame == frame)
        #expect(window.minSize == minimum)
        #expect(!window.isVisible)
        controller.attachContent(to: window)
        #expect(window.contentViewController != nil)
        #expect(window.frame == frame)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    @Test func disablingCaptureKeepsAnOpenArchiveReadable() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root))
        let record = ArchiveRecord(id: "saved", name: "synthetic.txt", sourcePath: "synthetic.txt",
                                   byteCount: 12, importedAt: Date(), sourceModifiedAt: nil)
        model.enabled = true
        model.archiveWindowDidOpen()
        model.records = [record]
        model.selectedID = record.id
        model.preview = "synthetic preview"
        model.enabled = false
        #expect(model.records == [record])
        #expect(model.selectedID == record.id)
        #expect(model.preview == "synthetic preview")
        model.archiveWindowDidClose()
        #expect(model.records.isEmpty)
        #expect(model.preview.isEmpty)
        #expect(model.selectedID == record.id, "navigation state survives a close")
        await model.applyCaptureNow()
    }

    @Test func savedArchiveSearchWorksWithCaptureDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "needle.txt")
        try Data("synthetic archive content".utf8).write(to: file)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let record = try await archive.importFile(file)
        let model = DataHoarderModel(archive: archive)
        model.archiveWindowDidOpen()
        model.query = "needle"
        await model.runSearch()
        #expect(!model.enabled)
        #expect(model.searchResults.contains { $0.record.id == record.id })
        #expect(!model.searching)
        model.archiveWindowDidClose()
        #expect(model.searchResults.isEmpty)
    }

    @Test func multipleProviderFiltersActivateSearch() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root))
        model.searchFilter.providers = ["claude", "codex"]
        #expect(model.searchActive)
        model.searchFilter.providers = []
        model.searchFilter.states = [.live, .closed]
        #expect(model.searchActive)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func lookaheadPaginationKeepsEverySavedRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        var expected = Set<String>()
        for index in 0..<101 {
            let file = root.appending(path: "needle-\(index).txt")
            let text = index.isMultiple(of: 2) ? "needle content \(index)" : "metadata match \(index)"
            try Data(text.utf8).write(to: file)
            expected.insert(try await archive.importFile(file).id)
        }
        let model = DataHoarderModel(archive: archive)
        model.archiveWindowDidOpen()
        model.query = "needle"
        await model.runSearch()
        #expect(model.searchResults.count == 50)
        #expect(model.searchHasMore)
        await model.loadMoreSearch()
        #expect(model.searchResults.count == 100)
        #expect(model.searchHasMore)
        await model.loadMoreSearch()
        #expect(model.searchResults.count == 101)
        #expect(!model.searchHasMore)
        #expect(Set(model.searchResults.map { $0.record.id }) == expected)
        #expect(!model.enabled)
        model.archiveWindowDidClose()
    }

    @Test func readOnlyArchiveLoadsStoredStatusWithoutStartingCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = DataHoarderArchive(root: root)
        try await archive.recordCaptureFailure(path: "synthetic.txt", sourceID: "synthetic",
                                               error: "synthetic failure")
        let model = DataHoarderModel(archive: archive)
        model.archiveWindowDidOpen()
        await model.refreshCaptureStatus()
        #expect(model.captureFailureCount == 1)
        #expect(model.captureFailures.count == 1)
        #expect(model.indexProgress != nil)
        #expect(!model.enabled)
        #expect(!model.captureRunning)
        #expect(model.captureApplies == 0)
        model.archiveWindowDidClose()
    }


    @Test func closingArchivePreservesPendingImportChoices() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root))
        let source = root.appending(path: "reviewed.txt")
        model.candidates = [ArchiveImportCandidate(url: source, size: 12, modified: nil)]
        model.copyContents = true
        model.archiveWindowDidOpen()
        model.archiveWindowDidClose()
        model.archiveWindowDidOpen()
        #expect(model.candidates.map(\.url) == [source])
        #expect(model.copyContents)
        #expect(!model.busy)
        model.cancelReview()
        #expect(model.candidates.isEmpty, "only explicit cancel discards the review")
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(arguments: [false, true])
    func paginationCannotReuseAnotherSearchOffset(changeFilter: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        for index in 0..<51 {
            let file = root.appending(path: "needle-\(index).txt")
            try Data("synthetic record \(index)".utf8).write(to: file)
            _ = try await archive.importFile(file)
        }
        let model = DataHoarderModel(archive: archive)
        model.archiveWindowDidOpen()
        model.query = "needle"
        await model.runSearch()
        let previousIDs = model.searchResults.map { $0.record.id }
        #expect(previousIDs.count == 50)
        #expect(model.searchHasMore)
        if changeFilter {
            model.searchFilter.states = [.snapshot]
        } else {
            model.query = "synthetic"
        }
        // The view has not started its replacement task yet.
        await model.loadMoreSearch()
        #expect(model.searchResults.map { $0.record.id } == previousIDs)
        #expect(model.searchOffset == 50)
        await model.runSearch()
        await model.loadMoreSearch()
        #expect(model.searchResults.count == 51)
        #expect(!model.searchHasMore)
        model.archiveWindowDidClose()
    }

    @Test func canceledSearchDoesNotLeaveTheLoadingIndicatorActive() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root))
        model.query = "synthetic"
        let job = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.runSearch()
        }
        await job.value
        #expect(!model.searching)
        #expect(model.searchError == nil)
        #expect(model.searchResults.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
