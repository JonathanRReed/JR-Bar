import Foundation
import Testing
@testable import JRBarApp

/// The /Applications listing is read once and kept briefly, not once per
/// card-body probe.
@Suite("Applications folder index")
struct ApplicationsFolderIndexTests {
    private final class Folder: @unchecked Sendable {
        let lock = NSLock()
        var listings = 0
        var uptime: TimeInterval = 100
        var apps = [URL(fileURLWithPath: "/Applications/Ice.app")]
    }

    private func index(_ folder: Folder) -> ApplicationsFolderIndex {
        ApplicationsFolderIndex(
            list: { folder.listings += 1; return folder.apps },
            now: { folder.uptime })
    }

    @Test("many asks inside the lifetime read the folder once")
    func readsOnce() async {
        let folder = Folder()
        let index = index(folder)
        _ = await index.load()
        for _ in 0..<50 { _ = index.entries() }
        #expect(folder.listings == 1)
        #expect(index.entries().map(\.lastPathComponent) == ["Ice.app"])
    }

    @Test("past its lifetime the folder is listed again and a new install appears")
    func expires() async {
        let folder = Folder()
        let index = index(folder)
        _ = await index.load()
        folder.uptime += ApplicationsFolderIndex.lifetime - 1
        _ = await index.load()
        #expect(folder.listings == 1)
        folder.apps.append(URL(fileURLWithPath: "/Applications/DockDoor.app"))
        folder.uptime += 2
        #expect(await index.load().count == 2)
        #expect(folder.listings == 2)
    }

    @Test("invalidate forces the next ask to read the folder")
    func invalidates() async {
        let folder = Folder()
        let index = index(folder)
        _ = await index.load()
        index.invalidate()
        _ = await index.load()
        #expect(folder.listings == 2)
    }

    @Test("a clock that steps backward does not serve a listing forever")
    func backwardClock() async {
        let folder = Folder()
        let index = index(folder)
        _ = await index.load()
        folder.uptime -= 500
        _ = await index.load()
        #expect(folder.listings == 2)
    }
}

/// A row's app name is worked out once per bundle id, not on every redraw.
@Suite("App display names")
struct AppDisplayNamesTests {
    private final class Lookups: @unchecked Sendable {
        let lock = NSLock()
        var ids: [String] = []
        func note(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    }

    @Test("a name is looked up once and reused")
    func looksUpOnce() {
        let lookups = Lookups()
        let names = AppDisplayNames(resolve: { id in lookups.note(id); return "Name of \(id)" })
        for _ in 0..<20 { _ = names.name(of: "io.example.a") }
        #expect(names.name(of: "io.example.b") == "Name of io.example.b")
        #expect(lookups.ids == ["io.example.a", "io.example.b"])
    }

    @Test("an app that is not installed reads as the bundle id's last word")
    func notInstalled() {
        #expect(AppDisplayNames.lookUp("com.example.jrbar-no-such-app.Keynote") == "Keynote")
    }
}
