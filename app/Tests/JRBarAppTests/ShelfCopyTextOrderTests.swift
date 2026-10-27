import JRBarTestSupport
import AppKit
import Foundation
import Testing
@testable import JRBarApp

@Suite("Shelf Copy Text ordering", .temporaryDirectory, .timeLimit(.minutes(2)))
@MainActor
struct ShelfCopyTextOrderTests {
    private actor Reader {
        private var pending: [String: CheckedContinuation<ShelfActions.TextRead, Never>] = [:]
        private var arrivals: [String: CheckedContinuation<Void, Never>] = [:]

        func read(_ urls: [URL]) async -> ShelfActions.TextRead {
            let name = urls[0].lastPathComponent
            return await withCheckedContinuation { continuation in
                pending[name] = continuation
                arrivals.removeValue(forKey: name)?.resume()
            }
        }

        func waitFor(_ name: String) async {
            if pending[name] != nil { return }
            await withCheckedContinuation { arrivals[name] = $0 }
        }

        func finish(_ name: String, with result: ShelfActions.TextRead) {
            pending.removeValue(forKey: name)?.resume(returning: result)
        }
    }

    @MainActor
    private final class Fixture {
        let suite = "jrbar-copy-text-\(UUID().uuidString)"
        let defaults: UserDefaults
        let tray: ShelfTrayModel
        let board: NSPasteboard
        let root: URL

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            tray = ShelfTrayModel(defaults: defaults)
            board = NSPasteboard(name: .init(suite))
            root = TestTemporaryDirectory.currentURL.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            board.clearContents()
            board.setString("Previous clipboard", forType: .string)
        }

        func entry(_ name: String, text: String = "Synthetic text") async throws -> ShelfTrayModel.ShelfEntry {
            let folder = root.appendingPathComponent(name + "-source", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            tray.add([url])
            let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            let ownedEntry = try #require(tray.entries.first { entry in
                entry.items.contains { $0.path == canonicalPath }
            })
            #expect(await tray.presentURLs(of: [ownedEntry]).count == 1)
            return ownedEntry
        }

        func clean() {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("the newest request wins in either completion order", arguments: [true, false])
    func newestRequestWins(newFirst: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let reader = Reader()
        let oldEntry = try await f.entry("old.txt")
        let newEntry = try await f.entry("new.txt")
        let oldPending = f.tray.copyText([oldEntry], to: f.board, reader: { await reader.read($0) })
        let oldTask = try #require(oldPending)
        await reader.waitFor("old.txt")
        let newPending = f.tray.copyText([newEntry], to: f.board, reader: { await reader.read($0) })
        let newTask = try #require(newPending)
        await reader.waitFor("new.txt")
        if newFirst {
            await reader.finish("new.txt", with: .init(texts: ["New text"]))
            await newTask.value
            await reader.finish("old.txt", with: .init(texts: ["Old text"]))
            await oldTask.value
        } else {
            await reader.finish("old.txt", with: .init(texts: ["Old text"]))
            await oldTask.value
            #expect(f.board.string(forType: .string) == "Previous clipboard")
            #expect(f.tray.actionNotice == nil)
            await reader.finish("new.txt", with: .init(texts: ["New text"]))
            await newTask.value
        }
        #expect(f.board.string(forType: .string) == "New text")
        #expect(f.tray.actionNotice == "Copied the text")
    }

    @Test("an old empty or failed read cannot replace the newest notice", arguments: [false, true])
    func oldResultKeepsNewNotice(unreadable: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let reader = Reader()
        let oldPending = f.tray.copyText([try await f.entry("old.txt")], to: f.board,
                                        reader: { await reader.read($0) })
        let oldTask = try #require(oldPending)
        await reader.waitFor("old.txt")
        let newPending = f.tray.copyText([try await f.entry("new.txt")], to: f.board,
                                        reader: { await reader.read($0) })
        let newTask = try #require(newPending)
        await reader.waitFor("new.txt")
        await reader.finish("new.txt", with: .init(texts: ["New text"]))
        await newTask.value
        let oldResult = unreadable
            ? ShelfActions.TextRead(unreadable: ["old.txt"], reason: "Synthetic read error")
            : ShelfActions.TextRead()
        await reader.finish("old.txt", with: oldResult)
        await oldTask.value
        #expect(f.board.string(forType: .string) == "New text")
        #expect(f.tray.actionNotice == "Copied the text")
    }

    @Test("a clipboard write during the read keeps its text and notice")
    func interveningClipboardWriteSurvives() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let reader = Reader()
        f.tray.actionNotice = "Previous notice"
        let pending = f.tray.copyText([try await f.entry("pending.txt")], to: f.board,
                                     reader: { await reader.read($0) })
        let task = try #require(pending)
        await reader.waitFor("pending.txt")
        f.board.clearContents()
        f.board.setString("Later clipboard", forType: .string)
        await reader.finish("pending.txt", with: .init(texts: ["Pending text"]))
        await task.value
        #expect(f.board.string(forType: .string) == "Later clipboard")
        #expect(f.tray.actionNotice == "Previous notice")
    }

    @Test("a copy without valid text files keeps the pending valid request")
    func invalidCopyKeepsPendingRequest() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let reader = Reader()
        let validEntry = try await f.entry("valid.txt")
        let missingEntry = try await f.entry("missing.txt")
        try FileManager.default.removeItem(at: missingEntry.items[0].url)
        await f.tray.refreshMetadata()
        let pending = f.tray.copyText([validEntry], to: f.board,
                                     reader: { await reader.read($0) })
        let task = try #require(pending)
        await reader.waitFor("valid.txt")
        let emptyPending = f.tray.copyText([], to: f.board, reader: { await reader.read($0) })
        let missingPending = f.tray.copyText([missingEntry], to: f.board,
                                            reader: { await reader.read($0) })
        #expect(emptyPending == nil)
        #expect(missingPending == nil)
        await reader.finish("valid.txt", with: .init(texts: ["Valid text"]))
        await task.value
        #expect(f.board.string(forType: .string) == "Valid text")
        #expect(f.tray.actionNotice == "Copied the text")
    }

    @Test("a released tray cannot publish a pending read")
    func releasedTrayKeepsClipboard() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let reader = Reader()
        let entry = try await f.entry("released.txt")
        var tray: ShelfTrayModel? = ShelfTrayModel(defaults: f.defaults)
        weak var releasedTray = tray
        let pending = tray?.copyText([entry], to: f.board, reader: { await reader.read($0) })
        let task = try #require(pending)
        await reader.waitFor("released.txt")
        let before = f.board.changeCount
        tray = nil
        #expect(releasedTray == nil)
        await reader.finish("released.txt", with: .init(texts: ["Retired text"]))
        await task.value
        #expect(f.board.changeCount == before)
        #expect(f.board.string(forType: .string) == "Previous clipboard")
    }

    @Test("the default reader copies actual temporary file text")
    func defaultReaderCopiesFile() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let entry = try await f.entry("source.txt", text: "Actual temporary source text")
        let pending = f.tray.copyText([entry], to: f.board)
        let task = try #require(pending)
        await task.value
        #expect(f.board.string(forType: .string) == "Actual temporary source text")
        #expect(f.tray.actionNotice == "Copied the text")
    }
}
