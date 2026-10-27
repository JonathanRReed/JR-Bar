import JRBarTestSupport
import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Shelf clear during move", .temporaryDirectory)
struct ShelfClearMoveRecoveryTests {
    @MainActor
    private struct Fixture {
        let root: URL
        let suite = "jrbar-shelf-clear-move-\(UUID().uuidString)"
        let defaults: UserDefaults
        let tray: ShelfTrayModel

        init() throws {
            root = TestTemporaryDirectory.currentURL.appendingPathComponent(UUID().uuidString)
            defaults = try #require(UserDefaults(suiteName: suite))
            tray = ShelfTrayModel(defaults: defaults)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Synthetic shelf content".utf8).write(to: url)
            return url
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Undo follows a completed move, including success before another file fails", arguments: [false, true])
    func undoFollowsCompletedMove(partial: Bool) throws {
        let f = try Fixture()
        defer { f.clean() }
        let file = try f.file("source/note.txt")
        let destination = try f.folder("destination")
        f.tray.add([file])
        f.tray.beginKeyboardSelection()
        f.tray.removeAll()
        let urls = partial ? [file, f.root.appendingPathComponent("missing.txt")] : [file]
        let result = ShelfActions.transfer(urls, to: destination, move: true)
        #expect(result.landed.count == 1)
        #expect((result.failure != nil) == partial)
        f.tray.finishTransfer(result, to: destination, move: true)
        #expect(f.tray.entries.isEmpty)
        #expect(f.tray.canUndoClear)
        f.tray.undoClear()
        let moved = destination.appendingPathComponent("note.txt")
        #expect(f.tray.items.map(\.path) == [moved.path])
        #expect(f.tray.items.allSatisfy { !$0.missing })
        #expect(f.tray.selectedIDs == [moved.path])
        #expect(f.tray.keyboardSelectionID == moved.path)
        #expect(try Data(contentsOf: moved) == Data("Synthetic shelf content".utf8))
        let restored = ShelfTrayModel(defaults: f.defaults)
        #expect(restored.items.map(\.path) == [moved.path])
    }

    @Test("Undo follows moved descendants while retaining stack identity and unaffected neighbors")
    func undoFollowsFolderAndStack() throws {
        let f = try Fixture()
        defer { f.clean() }
        let folder = try f.folder("source/Project")
        let loose = try f.file("source/Project/loose.txt")
        let first = try f.file("source/Project/stack/first.txt")
        let second = try f.file("source/Project/stack/second.txt")
        let neighbor = try f.file("source/Project2/neighbor.txt")
        let destination = try f.folder("destination")
        f.tray.add([folder])
        f.tray.add([loose])
        f.tray.add([first, second])
        f.tray.add([neighbor])
        let stack = try #require(f.tray.entries.first { $0.items.count == 2 })
        let looseEntry = try #require(f.tray.entries.first { $0.id == loose.path })
        f.tray.toggleSelection(looseEntry)
        f.tray.beginKeyboardSelection()
        f.tray.removeAll()
        let result = ShelfActions.transfer([folder], to: destination, move: true)
        #expect(result.failure == nil)
        f.tray.finishTransfer(result, to: destination, move: true)
        #expect(f.tray.entries.isEmpty)
        f.tray.undoClear()
        let movedFolder = destination.appendingPathComponent("Project")
        let movedLoose = movedFolder.appendingPathComponent("loose.txt")
        let expected = [movedFolder.path, movedLoose.path,
                        movedFolder.appendingPathComponent("stack/first.txt").path,
                        movedFolder.appendingPathComponent("stack/second.txt").path, neighbor.path]
        #expect(f.tray.items.map(\.path) == expected)
        #expect(f.tray.items.allSatisfy { !$0.missing })
        #expect(f.tray.entries.contains { $0.id == stack.id && $0.items.count == 2 })
        #expect(f.tray.selectedIDs == [movedLoose.path])
        #expect(f.tray.keyboardSelectionID == movedLoose.path)
        let neighborEntry = try #require(f.tray.entries.first { $0.id == neighbor.path })
        f.tray.extendSelection(to: neighborEntry)
        #expect(f.tray.selectedIDs == [movedLoose.path, stack.id, neighbor.path])
    }
}
