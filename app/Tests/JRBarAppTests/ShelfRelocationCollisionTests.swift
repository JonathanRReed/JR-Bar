import JRBarTestSupport
import AppKit
import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Shelf relocation collisions", .temporaryDirectory)
struct ShelfRelocationCollisionTests {
    @MainActor
    private struct Fixture {
        let root = TestTemporaryDirectory.currentURL.appendingPathComponent(UUID().uuidString)
        let suite = "jrbar-shelf-collision-\(UUID().uuidString)"
        let defaults: UserDefaults
        let tray: ShelfTrayModel

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            tray = ShelfTrayModel(defaults: defaults)
        }

        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: url)
            return url
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Moves retain one reference per path and remap selected chips", arguments: [false, true], [false, true])
    func fileCollision(destinationFirst: Bool, cleared: Bool) async throws {
        for layout in 0...2 {
            try await checkFileCollision(destinationFirst: destinationFirst, cleared: cleared, layout: layout)
        }
    }

    private func checkFileCollision(destinationFirst: Bool, cleared: Bool, layout: Int) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let source = try f.file("source/note.txt")
        let destination = try f.file("destination/note.txt")
        let companion = try f.file(layout == 1 ? "destination/other.txt" : "source/other.txt")
        let neighbor = try f.file("neighbor/end.txt")
        let sourceURLs = layout == 2 ? [source, companion] : [source]
        let destinationURLs = layout == 1 ? [destination, companion] : [destination]
        if destinationFirst {
            f.tray.add(destinationURLs)
            f.tray.add(sourceURLs)
        } else {
            f.tray.add(sourceURLs)
            f.tray.add(destinationURLs)
        }
        f.tray.add([neighbor])
        let sourceChip = try #require(f.tray.entries.first { $0.items.contains { $0.path == source.path } })
        let destinationChip = try #require(f.tray.entries.first { $0.items.contains { $0.path == destination.path } })
        f.tray.toggleSelection(sourceChip)
        f.tray.beginKeyboardSelection()
        try FileManager.default.removeItem(at: destination)
        await f.tray.refreshMetadata()
        await f.tray.refreshMetadata()
        #expect(f.tray.items.first { $0.path == destination.path }?.missing == true)
        if cleared { f.tray.removeAll() }
        let result = ShelfActions.transfer([source], to: destination.deletingLastPathComponent(), move: true)
        #expect(result.failure == nil)
        f.tray.finishTransfer(result, to: destination.deletingLastPathComponent(), move: true)
        if cleared {
            #expect(f.tray.entries.isEmpty)
            f.tray.undoClear()
        }
        let paths = f.tray.items.map(\.path)
        let expectedPaths = Set([destination.path, neighbor.path] + (layout == 0 ? [] : [companion.path]))
        #expect(Set(paths) == expectedPaths)
        #expect(paths.count == expectedPaths.count)
        await f.tray.refreshMetadata()
        #expect(f.tray.items.allSatisfy { !$0.missing })
        #expect(try Data(contentsOf: destination) == Data("source/note.txt".utf8))
        if layout != 0 { #expect(try Data(contentsOf: companion) == Data(companion.path.replacingOccurrences(of: f.root.path + "/", with: "").utf8)) }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let owners = f.tray.entries.filter { entry in
            entry.items.contains { $0.path == destination.path || (layout == 2 && $0.path == companion.path) }
        }
        #expect(f.tray.selectedIDs == Set(owners.map(\.id)))
        let cursor = try #require(f.tray.keyboardSelectionID)
        #expect(owners.contains { $0.id == cursor })
        if layout == 1 {
            let surviving = try #require(f.tray.entries.first { $0.id == destinationChip.id })
            #expect(surviving.displayName == destinationChip.displayName)
            #expect(surviving.items.count == 2)
        }
        if layout == 2 { #expect(!f.tray.entries.contains { $0.id == sourceChip.id }) }
        let cursorIndex = try #require(f.tray.entries.firstIndex { $0.id == cursor })
        let last = try #require(f.tray.entries.last)
        let expectedSelection = f.tray.selectedIDs.union(f.tray.entries[cursorIndex...].map(\.id))
        f.tray.extendSelection(to: last)
        #expect(f.tray.selectedIDs == expectedSelection)
        let reloaded = ShelfTrayModel(defaults: f.defaults)
        #expect(Set(reloaded.items.map(\.path)) == expectedPaths)
        #expect(reloaded.items.count == expectedPaths.count)
    }

    @Test("Moving a directory deduplicates descendant references and keeps neighboring bytes", arguments: [false, true])
    func descendantCollision(cleared: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let child = try f.file("source/Project/note.txt")
        let sourceFolder = child.deletingLastPathComponent()
        let destinationChild = try f.file("destination/Project/note.txt")
        let neighbor = try f.file("source/Project2/neighbor.txt")
        f.tray.add([destinationChild])
        f.tray.add([sourceFolder, child])
        f.tray.add([neighbor])
        try FileManager.default.removeItem(at: destinationChild.deletingLastPathComponent())
        await f.tray.refreshMetadata()
        if cleared { f.tray.removeAll() }
        let destinationFolder = destinationChild.deletingLastPathComponent().deletingLastPathComponent()
        let result = ShelfActions.transfer([sourceFolder, child], to: destinationFolder, move: true)
        #expect(result.failure == nil)
        #expect(result.landed.count == 1)
        f.tray.finishTransfer(result, to: destinationFolder, move: true)
        if cleared { f.tray.undoClear() }
        let expected = Set([destinationChild.path, destinationChild.deletingLastPathComponent().path, neighbor.path])
        #expect(Set(f.tray.items.map(\.path)) == expected)
        #expect(f.tray.items.count == expected.count)
        await f.tray.refreshMetadata()
        #expect(f.tray.items.allSatisfy { !$0.missing })
        #expect(try Data(contentsOf: destinationChild) == Data("source/Project/note.txt".utf8))
        #expect(try Data(contentsOf: neighbor) == Data("source/Project2/neighbor.txt".utf8))
    }
    @Test("Loading old duplicate references keeps every distinct file and surviving stack metadata")
    func persistedDuplicates() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("files/first.txt")
        let second = try f.file("files/second.txt")
        let third = try f.file("files/third.txt")
        let records: [[String: Any]] = [
            ["path": first.path],
            ["id": "stack-synthetic", "name": "Saved group", "paths": [first.path, second.path, second.path, third.path]],
            ["path": third.path]
        ]
        f.defaults.set(records, forKey: "jrbar.shelfTray.paths")
        let loaded = ShelfTrayModel(defaults: f.defaults)
        #expect(loaded.items.map(\.path) == [first.path, second.path, third.path])
        let stack = try #require(loaded.entries.first { $0.id == "stack-synthetic" })
        #expect(stack.displayName == "Saved group")
        #expect(stack.items.map(\.path) == [second.path, third.path])
        let reloaded = ShelfTrayModel(defaults: f.defaults)
        #expect(reloaded.entries == loaded.entries)
        let stored = try #require(f.defaults.array(forKey: "jrbar.shelfTray.paths") as? [[String: Any]])
        let paths = stored.flatMap { record -> [String] in
            if let path = record["path"] as? String { return [path] }
            return record["paths"] as? [String] ?? []
        }
        #expect(paths == [first.path, second.path, third.path])
    }

    @Test("Moving a directory keeps an absent descendant missing", arguments: [false, true])
    func absentDescendant(cleared: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let child = try f.file("source/Project/present.txt")
        let absent = try f.file("source/Project/absent.txt")
        let folder = child.deletingLastPathComponent()
        let destination = f.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        f.tray.add([folder, child, absent])
        try FileManager.default.removeItem(at: absent)
        await f.tray.refreshMetadata()
        if cleared { f.tray.removeAll() }
        let result = ShelfActions.transfer([folder], to: destination, move: true)
        #expect(result.failure == nil)
        f.tray.finishTransfer(result, to: destination, move: true)
        if cleared { f.tray.undoClear() }
        let moved = destination.appendingPathComponent("Project")
        await f.tray.refreshMetadata()
        #expect(f.tray.items.first { $0.path == moved.appendingPathComponent("absent.txt").path }?.missing == true)
        await f.tray.refreshMetadata()
        #expect(f.tray.items.first { $0.path == moved.appendingPathComponent("present.txt").path }?.missing == false)
        #expect(try Data(contentsOf: moved.appendingPathComponent("present.txt")) == Data("source/Project/present.txt".utf8))
    }

    @Test("Loading an unchanged shelf does not rewrite its store")
    func unchangedLoadDoesNotPersist() async throws {
        let f = try Fixture()
        defer { f.clean() }
        #expect(f.defaults.object(forKey: "jrbar.shelfTray.paths") == nil)
        let file = try f.file("files/note.txt")
        f.defaults.set([file.path], forKey: "jrbar.shelfTray.paths")
        let loaded = ShelfTrayModel(defaults: f.defaults)
        #expect(loaded.items.map(\.path) == [file.path])
        #expect(f.defaults.stringArray(forKey: "jrbar.shelfTray.paths") == [file.path])
    }

    @Test("Replacing a missing destination retires its old thumbnail", arguments: [false, true])
    func replacedDestinationThumbnail(cached: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let source = try f.file("source/note.txt")
        let destination = try f.file("destination/note.txt")
        var replies: [@MainActor @Sendable (NSImage?) -> Void] = []
        f.tray.loadThumbnail = { _, completion in replies.append(completion) }
        f.tray.add([destination])
        f.tray.add([source])
        let original = try #require(f.tray.items.first { $0.path == destination.path })
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: original)
        #expect(replies.count == 1)
        let staleImage = NSImage(size: NSSize(width: 32, height: 32))
        if cached { replies[0](staleImage) }
        try FileManager.default.removeItem(at: destination)
        await f.tray.refreshMetadata()
        let folder = destination.deletingLastPathComponent()
        let result = ShelfActions.transfer([source], to: folder, move: true)
        #expect(result.failure == nil)
        f.tray.finishTransfer(result, to: folder, move: true)
        let current = try #require(f.tray.items.first { $0.path == destination.path })
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: current)
        #expect(replies.count == 2)
        guard replies.count == 2 else { return }
        let replacement = NSImage(size: NSSize(width: 32, height: 32))
        replies[1](replacement)
        replies[0](staleImage)
        #expect(f.tray.icon(for: current) === replacement)
        #expect(try Data(contentsOf: destination) == Data("source/note.txt".utf8))
    }

}
