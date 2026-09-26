import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Archive selection safety")
struct ArchiveSelectionTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func searchSelectsOnlyVisibleRecords() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let first = root.appending(path: "first.txt")
        let second = root.appending(path: "second.txt")
        try Data("first private payload".utf8).write(to: first)
        try Data("second private payload".utf8).write(to: second)
        let hidden = try await archive.importFile(first)
        let visible = try await archive.importFile(second)
        let model = DataHoarderModel(archive: archive)
        model.archiveWindowDidOpen()
        await model.reload()
        model.selectedID = hidden.id
        model.query = "second.txt"
        await model.runSearch()
        #expect(model.selectedID == visible.id)
        #expect(model.selected?.id == visible.id)
        await model.loadPreview()
        #expect(model.preview == "second private payload")

        // A stale list selection must not authorize an action on a hidden row.
        model.selectedID = hidden.id
        #expect(model.selected == nil)
        await model.moveSelectedToTrash()
        await model.loadPreview()
        #expect(model.preview.isEmpty)
        #expect(try await archive.trashedRecords().isEmpty)
        #expect(try await archive.records().count == 2)
        model.archiveWindowDidClose()
    }

    @Test func changedInputCannotUsePreviousSearchSelection() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "needle.txt")
        try Data("synthetic result".utf8).write(to: file)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let record = try await archive.importFile(file)
        let model = DataHoarderModel(archive: archive)
        model.query = "needle"
        await model.runSearch()
        #expect(model.selected?.id == record.id)
        model.query = "nothing matches this"
        #expect(model.selected == nil, "the new request has not returned yet")
        await model.runSearch()
        #expect(model.searchResults.isEmpty)
        #expect(model.selectedID == nil)
        #expect(model.selected == nil)
    }

    @Test func selectionChangeDropsPreviousTimelineBeforeTheViewReloads() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "trace.jsonl")
        try Data("{\"type\":\"synthetic\"}\n".utf8).write(to: file)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let first = try await archive.importFile(file)
        let second = ArchiveRecord(id: "second", name: "second.txt", sourcePath: "second.txt",
                                   byteCount: 0, importedAt: Date(), sourceModifiedAt: nil)
        let model = DataHoarderModel(archive: archive)
        model.records = [first, second]
        model.selectedID = first.id
        await model.loadDetail()
        #expect(model.reconstruction != nil)
        #expect(model.canExportMarkdown)
        model.preview = "first private preview"
        model.detailError = "old error"
        model.relatedRecords = [first]
        model.segmentNotes = ["old note"]

        model.selectedID = second.id
        #expect(model.preview.isEmpty)
        #expect(model.reconstruction == nil)
        #expect(!model.canExportMarkdown)
        #expect(model.detailKind == .plain)
        #expect(model.detailError == nil)
        #expect(model.relatedRecords.isEmpty)
        #expect(model.segmentNotes.isEmpty)
    }

    @Test func unchangedSelectionKeepsItsPreview() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))
        model.selectedID = "same"
        model.preview = "current preview"
        model.selectedID = "same"
        #expect(model.preview == "current preview")
        model.selectedID = nil
        #expect(model.preview.isEmpty)
    }

    @Test func clearingTheLastFilterReloadsTheArchive() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "saved.txt")
        try Data("synthetic saved file".utf8).write(to: file)
        let archive = DataHoarderArchive(root: root.appending(path: "archive"))
        let record = try await archive.importFile(file)
        let model = DataHoarderModel(archive: archive)
        model.archiveWindowDidOpen()
        model.searchFilter.states = [.live]
        let view = DataHoarderView(model: model)
        await view.refreshResults()
        #expect(model.searchResults.isEmpty)
        model.searchFilter = ArchiveSearchFilter()
        await view.refreshResults()
        #expect(model.records.map(\.id) == [record.id])
        #expect(model.selectedID == record.id)
        #expect(!model.enabled)
        model.archiveWindowDidClose()
    }

    @Test func busyViewDoesNotRefreshSearchResults() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))
        model.query = "synthetic"
        model.busy = true
        let record = ArchiveRecord(id: "existing", name: "existing.txt", sourcePath: "existing.txt",
                                   byteCount: 0, importedAt: Date(), sourceModifiedAt: nil)
        model.searchResults = [ArchiveSearchResult(record: record, snippets: [], rank: nil)]
        await DataHoarderView(model: model).refreshResults()
        #expect(model.searchResults.map { $0.record.id } == [record.id])
        #expect(!model.searching)
    }

    @Test func importSizeAccountingSaturatesInsteadOfOverflowing() {
        #expect(DataHoarderModel.totalBytes([Int64.max, 1]) == Int64.max)
        #expect(DataHoarderModel.totalBytes([-1, 12, 30]) == 42)
        #expect(DataHoarderModel.totalBytes([]) == 0)
    }
}
