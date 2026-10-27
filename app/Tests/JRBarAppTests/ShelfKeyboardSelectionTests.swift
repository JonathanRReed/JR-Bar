import JRBarTestSupport
import AppKit
import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Shelf keyboard selection", .temporaryDirectory)
struct ShelfKeyboardSelectionTests {
    @Test("Clear retires the keyboard cursor and Undo restores the same selected tile")
    func clearUndoRestoresKeyboardCursor() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("first.txt", folder: "one")
        let second = try f.file("second.txt", folder: "two")
        f.tray.add([first])
        f.tray.add([second])
        f.tray.beginKeyboardSelection()
        f.tray.moveKeyboardSelection(by: 1)
        #expect(f.tray.keyboardSelectionID == second.path)
        f.tray.removeAll()
        #expect(f.tray.keyboardSelectionID == nil)
        f.tray.beginKeyboardSelection()
        #expect(f.tray.keyboardSelectionID == nil)
        f.tray.undoClear()
        #expect(f.tray.selectedIDs == [second.path])
        #expect(f.tray.keyboardSelectionID == second.path)
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        #expect(await f.tray.openKeyboardSelection() == nil)
        #expect(opened == [second])
        f.tray.removeAll()
        f.tray.clearSelection()
        f.tray.undoClear()
        #expect(f.tray.selectedIDs.isEmpty)
        #expect(f.tray.keyboardSelectionID == nil)
    }

    @Test("clipboard changes preserve a file cursor and retire a withdrawn Paste action")
    func changingPasteOffer() throws {
        let f = try Fixture()
        defer { f.clean() }
        let file = try f.file("file.txt", folder: "one")
        f.tray.add([file])
        f.tray.beginKeyboardSelection()
        let board = NSPasteboard(name: .init("jrbar-shelf-changing-paste-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])
        f.tray.notePasteboard(board)
        #expect(f.tray.keyboardSelectionID == file.path)
        ShelfKeyboardInput.handle(.backTab, tray: f.tray)
        #expect(f.tray.keyboardSelectionID == ShelfTrayModel.pasteKeyboardID)
        board.clearContents()
        f.tray.notePasteboard(board)
        #expect(f.tray.keyboardSelectionID == nil)
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        ShelfKeyboardInput.handle(.activate, tray: f.tray, pasteboard: board)
        #expect(opened.isEmpty)
        ShelfKeyboardInput.handle(.tab, tray: f.tray)
        #expect(f.tray.keyboardSelectionID == file.path)
    }

    @Test("arrows respect rows when Paste leads a two-row grid")
    func pasteGridNavigation() throws {
        let f = try Fixture()
        defer { f.clean() }
        for index in 0..<4 { f.tray.add([try f.file("file.txt", folder: "\(index)")]) }
        let board = NSPasteboard(name: .init("jrbar-shelf-grid-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.writeObjects([try f.file("copied.txt", folder: "copied") as NSURL])
        f.tray.notePasteboard(board)
        f.tray.beginKeyboardSelection()
        let ids = f.tray.entries.map(\.id)
        ShelfKeyboardInput.handle(.down, tray: f.tray)
        #expect(f.tray.keyboardSelectionID == ids[0], "Down must stop at the bottom of this column")
        ShelfKeyboardInput.handle(.right, tray: f.tray)
        #expect(f.tray.keyboardSelectionID == ids[2])
        ShelfKeyboardInput.handle(.right, tray: f.tray)
        #expect(f.tray.keyboardSelectionID == ids[2], "The last column has no bottom tile")
        ShelfKeyboardInput.handle(.up, tray: f.tray)
        #expect(f.tray.keyboardSelectionID == ids[1])
        ShelfKeyboardInput.handle(.left, tray: f.tray)
        #expect(f.tray.selectedIDs.isEmpty, "Paste is an action, not a selected file")
        ShelfKeyboardInput.handle(.tab, tray: f.tray)
        #expect(f.tray.keyboardSelectionID == ids[0])
    }

    @Test("Return can paste from an empty Shelf without opening a file")
    func keyboardPaste() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let copied = try f.file("copied.txt", folder: "copied")
        let board = NSPasteboard(name: .init("jrbar-shelf-paste-key-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.writeObjects([copied as NSURL])
        f.tray.notePasteboard(board)
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        f.tray.beginKeyboardSelection()
        #expect(f.tray.keyboardSelectionID != nil)
        ShelfKeyboardInput.handle(.activate, tray: f.tray, pasteboard: board)
        #expect(f.tray.entries.map(\.id) == [copied.path])
        #expect(!f.tray.pasteOffered)
        #expect(f.tray.keyboardSelectionID == copied.path)
        #expect(opened.isEmpty)
        await ShelfKeyboardInput.handle(.activate, tray: f.tray, pasteboard: board)?.value
        #expect(opened == [copied])
    }

    @Test("a stale menu entry dissolves only the stack's current members")
    func staleStackDoesNotRestoreRemovedMember() throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("first.txt", folder: "stack")
        let second = try f.file("second.txt", folder: "stack")
        let removed = try f.file("removed.txt", folder: "stack")
        f.tray.add([first, second, removed])
        let menuEntry = f.tray.entries[0]
        f.tray.removeItem(menuEntry.items[2], from: menuEntry.id)
        f.tray.dissolve(menuEntry)
        #expect(f.tray.entries.map(\.id) == [first.path, second.path])
    }

    @Test("dissolving a selected stack keeps its files selected and usable from the keyboard")
    func dissolveKeepsSelection() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("first.txt", folder: "stack")
        let second = try f.file("second.txt", folder: "stack")
        f.tray.add([first, second])
        f.tray.add([try f.file("third.txt", folder: "other")])
        f.tray.beginKeyboardSelection()
        f.tray.dissolve(f.tray.entries[0])
        #expect(f.tray.selectedIDs == [first.path, second.path])
        #expect(f.tray.keyboardSelectionID == first.path)
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        #expect(await f.tray.openKeyboardSelection() == nil)
        #expect(opened == [first, second])
        f.tray.extendSelection(to: f.tray.entries[2])
        #expect(f.tray.selectedIDs == Set(f.tray.entries.map(\.id)))
    }

    @Test("merging either selected neighbor transfers selection to the new stack")
    func mergeKeepsSelection() async throws {
        for pickSecond in [false, true] {
            let f = try Fixture()
            defer { f.clean() }
            let first = try f.file("first.txt", folder: "one")
            let second = try f.file("second.txt", folder: "two")
            f.tray.add([first])
            f.tray.add([second])
            f.tray.add([try f.file("third.txt", folder: "other")])
            f.tray.beginKeyboardSelection()
            if pickSecond { f.tray.moveKeyboardSelection(by: 1) }
            f.tray.mergeWithNext(f.tray.entries[0])
            let id = f.tray.entries[0].id
            #expect(f.tray.selectedIDs == [id])
            #expect(f.tray.keyboardSelectionID == id)
            var opened: [URL] = []
            f.tray.openURL = { opened.append($0); return true }
            #expect(await f.tray.openKeyboardSelection() == nil)
            #expect(opened == [first, second])
            f.tray.extendSelection(to: f.tray.entries[1])
            #expect(f.tray.selectedIDs == Set(f.tray.entries.map(\.id)))
        }
    }

    @Test("a stack thinned to one file keeps that file selected")
    func removingStackMemberKeepsSelection() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("first.txt", folder: "stack")
        let second = try f.file("second.txt", folder: "stack")
        f.tray.add([first, second])
        f.tray.beginKeyboardSelection()
        let stack = f.tray.entries[0]
        f.tray.removeItem(stack.items[0], from: stack.id)
        #expect(f.tray.selectedIDs == [second.path])
        #expect(f.tray.keyboardSelectionID == second.path)
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        #expect(await f.tray.openKeyboardSelection() == nil)
        #expect(opened == [second])
    }

    @Test("dissolving an unselected stack does not select its files")
    func unselectedStackStaysUnselected() throws {
        let f = try Fixture()
        defer { f.clean() }
        f.tray.add([try f.file("first.txt", folder: "stack"), try f.file("second.txt", folder: "stack")])
        let selected = try f.file("selected.txt", folder: "other")
        f.tray.add([selected])
        f.tray.beginKeyboardSelection()
        f.tray.moveKeyboardSelection(by: 1)
        f.tray.dissolve(f.tray.entries[0])
        #expect(f.tray.selectedIDs == [selected.path])
        #expect(f.tray.keyboardSelectionID == selected.path)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let tray: ShelfTrayModel

        init() throws {
            suite = "jrbar-shelf-selection-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            root = TestTemporaryDirectory.currentURL.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            tray = ShelfTrayModel(defaults: defaults)
        }

        func file(_ name: String, folder: String) throws -> URL {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name)
            try Data("Synthetic fixture".utf8).write(to: file)
            return file
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("arrows follow tray order and stop at both ends")
    func arrowsAndExistingSelection() throws {
        let f = try Fixture()
        defer { f.clean() }
        for index in 0..<3 { f.tray.add([try f.file("file.txt", folder: "\(index)")]) }
        f.tray.beginKeyboardSelection()
        #expect(f.tray.selectedIDs == [f.tray.entries[0].id])
        #expect(f.tray.keyboardSelectionID == f.tray.entries[0].id)
        f.tray.moveKeyboardSelection(by: -1)
        #expect(f.tray.selectedIDs == [f.tray.entries[0].id])
        f.tray.moveKeyboardSelection(by: 1)
        #expect(f.tray.selectedIDs == [f.tray.entries[1].id])
        f.tray.moveKeyboardSelection(by: Int.max)
        #expect(f.tray.selectedIDs == [f.tray.entries[2].id])
        f.tray.moveKeyboardSelection(by: Int.min)
        #expect(f.tray.selectedIDs == [f.tray.entries[0].id])
        f.tray.clearSelection()
        f.tray.toggleSelection(f.tray.entries[2])
        f.tray.beginKeyboardSelection()
        #expect(f.tray.selectedIDs == [f.tray.entries[2].id])
        #expect(f.tray.keyboardSelectionID == f.tray.entries[2].id)
        f.tray.endKeyboardSelection()
        #expect(f.tray.keyboardSelectionID == nil)
        #expect(f.tray.selectedIDs == [f.tray.entries[2].id])
    }

    @Test("Return uses the injected opener and reports a refused open")
    func selectedOpenAndRefusal() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let file = try f.file("file.txt", folder: "one")
        f.tray.add([file])
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        f.tray.beginKeyboardSelection()
        #expect(await f.tray.openKeyboardSelection() == nil)
        #expect(opened == [file])
        f.tray.openURL = { _ in false }
        #expect(await f.tray.openKeyboardSelection() == "Some selected files could not be opened.")
        #expect(f.tray.actionNotice == "Some selected files could not be opened.")
    }

    @Test("a mixed selection reports missing files even when the remaining files open",
          arguments: [false, true])
    func partialSelectionOpenIsReported(_ refused: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let missing = try f.file("missing.txt", folder: "one")
        let present = try f.file("present.txt", folder: "two")
        f.tray.add([missing])
        f.tray.add([present])
        for entry in f.tray.entries { f.tray.toggleSelection(entry) }
        f.tray.beginKeyboardSelection()
        try FileManager.default.removeItem(at: missing)
        await f.tray.refreshMetadata()
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return !refused }
        let expected = refused
            ? "Some selected files moved, were deleted, or could not be opened."
            : "Some selected files moved or were deleted."
        #expect(await f.tray.openKeyboardSelection() == expected)
        #expect(f.tray.actionNotice == expected)
        #expect(opened == [present])
    }

    @Test("a deleted file is revalidated and never passed to the opener")
    func deletedFileAndRemovedSelection() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("first.txt", folder: "one")
        let second = try f.file("second.txt", folder: "two")
        f.tray.add([first])
        f.tray.add([second])
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        f.tray.beginKeyboardSelection()
        try FileManager.default.removeItem(at: first)
        await f.tray.refreshMetadata()
        #expect(await f.tray.openKeyboardSelection() == "The selected files moved or were deleted.")
        #expect(f.tray.actionNotice == "The selected files moved or were deleted.")
        #expect(opened.isEmpty)
        f.tray.remove(f.tray.entries[0])
        f.tray.beginKeyboardSelection()
        #expect(f.tray.selectedIDs == [f.tray.entries[0].id])
        #expect(await f.tray.openKeyboardSelection() == nil)
        #expect(f.tray.actionNotice == nil)
        #expect(opened == [second])
    }

    @Test("Return opens live stack members and reports missing ones")
    func stackSelection() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("first.txt", folder: "stack")
        let second = try f.file("second.txt", folder: "stack")
        f.tray.add([first, second])
        #expect(f.tray.entries.count == 1)
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        f.tray.beginKeyboardSelection()
        try FileManager.default.removeItem(at: first)
        await f.tray.refreshMetadata()
        #expect(await f.tray.openKeyboardSelection() == "Some selected files moved or were deleted.")
        #expect(f.tray.actionNotice == "Some selected files moved or were deleted.")
        #expect(opened == [second])
    }

    @Test("an empty or disabled Shelf refuses without opening files")
    func emptyAndDisabled() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.tray.openURL = { _ in Issue.record("unexpected open"); return false }
        f.tray.beginKeyboardSelection()
        #expect(f.tray.selectedIDs.isEmpty)
        #expect(await f.tray.openKeyboardSelection() == "The Shelf has no files to open.")
        f.tray.shelfEnabled = { false }
        #expect(await f.tray.openKeyboardSelection() == "The Shelf is turned off.")
    }

    @Test("removing the selected entry before Return never opens a different file")
    func removalBeforeReturnDoesNotChooseAnotherFile() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.tray.add([try f.file("selected.txt", folder: "one")])
        f.tray.add([try f.file("unrelated.txt", folder: "two")])
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        f.tray.beginKeyboardSelection()
        f.tray.remove(f.tray.entries[0])
        #expect(await f.tray.openKeyboardSelection() == "No Shelf files are selected.")
        #expect(f.tray.actionNotice == "No Shelf files are selected.")
        #expect(opened.isEmpty)
        #expect(f.tray.selectedIDs.isEmpty)
    }

    @Test("a file moved through Shelf keeps keyboard selection and the shift-selection anchor")
    func ownMoveKeepsSelection() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("selected.txt", folder: "one")
        f.tray.add([first])
        f.tray.add([try f.file("second.txt", folder: "two")])
        f.tray.add([try f.file("third.txt", folder: "three")])
        f.tray.beginKeyboardSelection()
        let directory = f.root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("selected.txt")
        try FileManager.default.moveItem(at: first, to: destination)
        f.tray.relocate(from: first.path, to: destination.path)
        #expect(f.tray.selectedIDs == [destination.path])
        #expect(f.tray.keyboardSelectionID == destination.path)
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        #expect(await f.tray.openKeyboardSelection() == nil)
        #expect(opened == [destination])
        f.tray.extendSelection(to: f.tray.entries[2])
        #expect(f.tray.selectedIDs == Set(f.tray.entries.map(\.id)))
    }

    @Test("moving one stack member keeps the stack's selection identity")
    func ownStackMoveKeepsSelection() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("first.txt", folder: "stack")
        let second = try f.file("second.txt", folder: "stack")
        f.tray.add([first, second])
        f.tray.beginKeyboardSelection()
        let id = f.tray.entries[0].id
        let directory = f.root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("first.txt")
        try FileManager.default.moveItem(at: first, to: destination)
        f.tray.relocate(from: first.path, to: destination.path)
        #expect(f.tray.selectedIDs == [id] && f.tray.keyboardSelectionID == id)
        var opened: [URL] = []
        f.tray.openURL = { opened.append($0); return true }
        #expect(await f.tray.openKeyboardSelection() == nil)
        #expect(Set(opened) == Set([destination, second]))
    }
}
