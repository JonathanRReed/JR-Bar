import AppKit
import Testing
@testable import JRBarApp

@Suite("Shelf thumbnail ownership")
@MainActor
struct ShelfThumbnailOrderTests {
    @MainActor
    private final class Fixture {
        let root: URL
        let suite = "jrbar-thumbnail-\(UUID().uuidString)"
        let defaults: UserDefaults
        let tray: ShelfTrayModel
        var replies: [@MainActor @Sendable (NSImage?) -> Void] = []

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            tray = ShelfTrayModel(defaults: defaults)
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            tray.loadThumbnail = { [weak self] _, completion in self?.replies.append(completion) }
        }

        func file(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("Synthetic thumbnail fixture".utf8).write(to: url)
            return url
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("an old thumbnail cannot overwrite the new request after re-adding a path")
    func readdedPathKeepsNewReply() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let url = try f.file("file.txt")
        f.tray.add([url])
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: f.tray.entries[0].items[0])
        f.tray.remove(f.tray.entries[0])
        f.tray.add([url])
        let current = f.tray.entries[0].items[0]
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: current)
        #expect(f.replies.count == 2)
        let newer = NSImage(size: NSSize(width: 32, height: 32))
        f.replies[1](newer)
        f.replies[0](NSImage(size: NSSize(width: 32, height: 32)))
        #expect(f.tray.icon(for: current) === newer)
    }

    @Test("a removed reference's late reply cannot warm the cache for a fresh add")
    func removedReplyIsRetired() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let url = try f.file("file.txt")
        f.tray.add([url])
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: f.tray.entries[0].items[0])
        f.tray.remove(f.tray.entries[0])
        f.replies[0](NSImage(size: NSSize(width: 32, height: 32)))
        f.tray.add([url])
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: f.tray.entries[0].items[0])
        #expect(f.replies.count == 2)
    }

    @Test("a failed thumbnail keeps its generic icon without a retry loop")
    func failureKeepsGenericIcon() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.tray.add([try f.file("file.txt")])
        let entry = f.tray.entries[0].items[0]
        await f.tray.refreshMetadata()
        let generic = f.tray.icon(for: entry)
        f.replies[0](nil)
        #expect(f.tray.icon(for: entry) === generic)
        #expect(f.replies.count == 1)
    }

    @Test("clear retires thumbnail replies before a path is re-added")
    func clearRetiresReplies() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let url = try f.file("file.txt")
        f.tray.add([url])
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: f.tray.entries[0].items[0])
        f.tray.removeAll()
        f.replies[0](NSImage(size: NSSize(width: 32, height: 32)))
        f.tray.add([url])
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: f.tray.entries[0].items[0])
        #expect(f.replies.count == 2)
    }

    @Test("relocation retires the request for the old path")
    func relocationRetiresReply() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let old = try f.file("old.txt")
        let new = try f.file("new.txt")
        f.tray.add([old])
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: f.tray.entries[0].items[0])
        f.tray.relocate(from: old.path, to: new.path)
        f.replies[0](NSImage(size: NSSize(width: 32, height: 32)))
        f.tray.add([old])
        let entry = try #require(f.tray.entries.flatMap(\.items).first { $0.path == old.path })
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: entry)
        #expect(f.replies.count == 2)
    }

    @Test("removing a stack member retires its thumbnail")
    func removedMemberRetiresReply() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("first.txt")
        f.tray.add([first, try f.file("second.txt")])
        let stack = f.tray.entries[0]
        let item = try #require(stack.items.first { $0.path == first.path })
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: item)
        f.tray.removeItem(item, from: stack.id)
        f.replies[0](NSImage(size: NSSize(width: 32, height: 32)))
        f.tray.add([first])
        let current = try #require(f.tray.entries.flatMap(\.items).first { $0.path == first.path })
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: current)
        #expect(f.replies.count == 2)
    }

    @Test("capacity eviction retires pending thumbnails for dropped references")
    func evictionRetiresReply() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let old = try f.file("old.txt")
        f.tray.add([old])
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: f.tray.entries[0].items[0])
        let files = try (0..<ShelfTrayModel.maxItems).map { try f.file("new-\($0).txt") }
        f.tray.add(files)
        #expect(!f.tray.entries.flatMap(\.items).contains { $0.path == old.path })
        f.replies[0](NSImage(size: NSSize(width: 32, height: 32)))
        f.tray.add([old])
        let current = try #require(f.tray.entries.flatMap(\.items).first { $0.path == old.path })
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: current)
        #expect(f.replies.count == 2)
    }

    @Test("removing an old stack snapshot retires thumbnails for its current members")
    func staleStackRemovalRetiresCurrentMembers() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = try f.file("first.txt")
        let old = try f.file("old.txt")
        let currentURL = try f.file("current.txt")
        f.tray.add([first, old])
        let menuEntry = f.tray.entries[0]
        f.tray.relocate(from: old.path, to: currentURL.path)
        let item = try #require(f.tray.entries[0].items.first { $0.path == currentURL.path })
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: item)
        f.tray.remove(menuEntry)
        f.replies[0](NSImage(size: NSSize(width: 32, height: 32)))
        f.tray.add([currentURL])
        await f.tray.refreshMetadata()
        _ = f.tray.icon(for: f.tray.entries[0].items[0])
        #expect(f.replies.count == 2)
    }
}
