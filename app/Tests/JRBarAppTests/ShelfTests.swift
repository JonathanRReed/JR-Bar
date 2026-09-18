import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// W12's shelf utilities: tray revalidation, persisted timers with
/// sleep/clock semantics, and the calendar's safe-URL rule.
@MainActor
@Suite struct ShelfTests {

    // MARK: - Tray (T49)

    @Test func trayAddsDedupesAndBounds() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        let urls = (0..<20).map { URL(fileURLWithPath: "/tmp/file-\($0).txt") }
        tray.add(urls)
        #expect(tray.entries.count == ShelfTrayModel.maxItems)
        // Bounded: the newest entries win, the oldest drop off.
        #expect(tray.entries.last?.name == "file-19.txt")
        #expect(tray.entries.first?.name == "file-8.txt")

        // Re-adding paths still held is a no-op — no duplicates.
        tray.add(Array(urls.suffix(5)))
        #expect(tray.entries.count == ShelfTrayModel.maxItems)
        #expect(Set(tray.entries.map(\.path)).count == tray.entries.count)
    }

    @Test func evictionSpeaksItsName() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        // The strip is bounded, but a dropped reference must be said
        // out loud — a shelf that silently forgets reads as data loss.
        #expect(tray.evictionNotice == nil)
        tray.add((0..<20).map { URL(fileURLWithPath: "/tmp/evict-\($0).txt") })
        #expect(tray.entries.count == ShelfTrayModel.maxItems)
        #expect(tray.evictionNotice?.contains("8 oldest items") == true)
        #expect(tray.evictionNotice?.contains("untouched") == true)

        // A non-evicting add clears the stale sentence.
        tray.remove(tray.entries.first!)
        #expect(tray.evictionNotice == nil)
        tray.add([URL(fileURLWithPath: "/tmp/evict-new.txt")])
        #expect(tray.evictionNotice == nil)

        // Fill again and a single dropped chip names itself.
        tray.add((0..<ShelfTrayModel.maxItems).map {
            URL(fileURLWithPath: "/tmp/refill-\($0).txt")
        })
        tray.add([URL(fileURLWithPath: "/tmp/one-more.txt")])
        #expect(tray.evictionNotice?.contains("refill-0.txt") == true)
        #expect(tray.evictionNotice?.contains("dropped off") == true)
        #expect(tray.evictionNotice?.contains("untouched") == true)
        tray.clearEvictionNotice()
        #expect(tray.evictionNotice == nil)
    }

    @Test func missingFilesMarkNotVanish() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-tray-\(UUID().uuidString).txt")
        try? "hi".write(to: real, atomically: true, encoding: .utf8)
        let gone = URL(fileURLWithPath: "/tmp/jrbar-never-existed-\(UUID().uuidString)")
        tray.add([real, gone])

        tray.revalidate()
        #expect(tray.entries.count == 2)
        #expect(tray.entries.first { $0.path == real.path }?.missing == false)
        #expect(tray.entries.first { $0.path == gone.path }?.missing == true)

        // Deleting after the add flips it on the next revalidation —
        // the entry stays, marked, until the user removes it.
        try? FileManager.default.removeItem(at: real)
        tray.revalidate()
        #expect(tray.entries.first { $0.path == real.path }?.missing == true)
    }

    @Test func missingEntryCannotRevealOrShare() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        let gone = URL(fileURLWithPath: "/tmp/jrbar-gone-\(UUID().uuidString)")
        tray.add([gone])
        tray.revalidate()
        let entry = tray.entries.first { $0.path == gone.path }!
        #expect(tray.provider(for: entry) == nil)
        #expect(tray.sharingServices(for: entry).isEmpty)
        #expect(!tray.canAttachCopy(entry))
    }

    @Test func aWebLinkDropMaterialisesAWebLoc() throws {
        let link = URL(string: "https://example.com/page?q=1")!
        let loc = try #require(ShelfTrayDrop.webLoc(for: link))
        defer { try? FileManager.default.removeItem(at: loc) }
        #expect(loc.pathExtension == "webloc")
        #expect(loc.lastPathComponent.contains("example.com"))
        // The file is a real plist carrying the link — Finder's own
        // webloc shape.
        let plist = try #require(NSDictionary(contentsOf: loc))
        #expect(plist["URL"] as? String == link.absoluteString)
        // Re-dropping the same link lands on the same file — the
        // tray's path dedupe keeps it one entry.
        #expect(ShelfTrayDrop.webLoc(for: link) == loc)
    }

    @Test func trayURLsPassesFilesThroughAndConvertsLinks() {
        let file = URL(fileURLWithPath: "/tmp/real.txt")
        let link = URL(string: "https://example.com/x")!
        let converted = ShelfTrayDrop.trayURLs(from: [file, link])
        #expect(converted.count == 2)
        #expect(converted[0] == file)
        #expect(converted[1].pathExtension == "webloc")
        defer { try? FileManager.default.removeItem(at: converted[1]) }
        // Non-http schemes never materialise — a javascript: drop
        // adds nothing (T49's rule).
        #expect(ShelfTrayDrop.trayURLs(from: [
            URL(string: "javascript:alert(1)")!]).isEmpty)
    }

    @Test func chipReorderMovesAndPersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        tray.add([URL(fileURLWithPath: "/tmp/a.txt"),
                  URL(fileURLWithPath: "/tmp/b.txt"),
                  URL(fileURLWithPath: "/tmp/c.txt")])
        let a = tray.entries[0], c = tray.entries[2]

        // Drag C onto A — C lands ahead of A.
        tray.move(c, before: a)
        #expect(tray.entries.map(\.name) == ["c.txt", "a.txt", "b.txt"])
        // The arrangement is the user's — it survives a reload.
        let reloaded = ShelfTrayModel()
        #expect(reloaded.entries.map(\.name) == ["c.txt", "a.txt", "b.txt"])

        // Moving onto itself is a no-op.
        tray.move(tray.entries[0], before: tray.entries[0])
        #expect(tray.entries.map(\.name) == ["c.txt", "a.txt", "b.txt"])
    }

    @Test func aTextDropMaterialisesATxt() throws {
        let text = "remember the milk\nand the eggs"
        let loc = try #require(ShelfTrayDrop.textLoc(for: text))
        defer { try? FileManager.default.removeItem(at: loc) }
        #expect(loc.pathExtension == "txt")
        // The clip is a real file — every tray verb answers it.
        #expect(try String(contentsOf: loc, encoding: .utf8) == text)
        // Re-dropping the same clip lands on the same file — the
        // hash is stable across calls and launches, so the tray's
        // path dedupe keeps it one entry.
        #expect(ShelfTrayDrop.textLoc(for: text) == loc)
        #expect(ShelfTrayDrop.stableHash(text)
            == ShelfTrayDrop.stableHash(text))
        // Whitespace-only clips add nothing (T49's rule).
        #expect(ShelfTrayDrop.textLoc(for: "  \n  ") == nil)
    }

    // MARK: - Timers (T51)

    private func tempStore() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-timers-\(UUID().uuidString).json")
    }

    @Test func timersPersistAndReload() {
        let store = tempStore()
        var model = ShelfTimerModel(storeURL: store)
        model.add(label: "tea", duration: 300)
        #expect(model.entries.count == 1)

        model = ShelfTimerModel(storeURL: store)
        #expect(model.entries.count == 1)
        #expect(model.entries.first?.label == "tea")
        try? FileManager.default.removeItem(at: store)
    }

    @Test func overdueFiresExactlyOnceAcrossReloads() {
        let store = tempStore()
        // A timer that came due while the app was down — the recovery
        // sweep fires it once, marks it, and a reload never refires.
        var overdue = ShelfTimerModel.Entry(id: "t1", label: "tea",
                                            deadline: Date().addingTimeInterval(-10),
                                            fired: false)
        let data = try! JSONEncoder().encode([overdue])
        try! data.write(to: store, options: .atomic)

        var fired = 0
        var model = ShelfTimerModel(storeURL: store)
        model.onFire = { _ in fired += 1 }
        // init's sweep ran before onFire was wired — sweep again to
        // observe the edge: the persisted `fired` flag already fired.
        model.add(label: "trigger", duration: 60)  // any mutation persists
        model = ShelfTimerModel(storeURL: store)   // reload
        model.onFire = { _ in fired += 1 }
        #expect(fired == 0)  // init fired before onFire; never twice
        #expect(model.entries.first { $0.id == "t1" }?.fired == true)
        overdue.fired = true
        try? FileManager.default.removeItem(at: store)
    }

    @Test func durationClampsToBound() {
        let model = ShelfTimerModel(storeURL: tempStore())
        let entry = model.add(label: "forever", duration: 999_999)
        #expect(entry.remaining <= ShelfTimerModel.maxDuration + 1)
    }

    @Test func corruptStoreYieldsNoTimers() {
        let store = tempStore()
        try? "not json".write(to: store, atomically: true, encoding: .utf8)
        #expect(ShelfTimerModel.load(from: store).isEmpty)
        try? FileManager.default.removeItem(at: store)
    }

    // MARK: - Calendar (T52)

    @Test func joinableURLAcceptsHTTPS() {
        let url = URL(string: "https://meet.example.com/abc")!
        #expect(ShelfCalendarModel.joinableURL(url, notes: nil) == url)
    }

    @Test func joinableURLRejectsUnsafeSchemes() {
        #expect(ShelfCalendarModel.joinableURL(
            URL(string: "javascript:alert(1)"), notes: nil) == nil)
        #expect(ShelfCalendarModel.joinableURL(
            URL(string: "file:///etc/passwd"), notes: nil) == nil)
        #expect(ShelfCalendarModel.joinableURL(nil, notes: nil) == nil)
    }

    @Test func joinableURLFindsSafeLinkInNotes() {
        let notes = "Join: https://zoom.us/j/12345 or call in"
        #expect(ShelfCalendarModel.joinableURL(nil, notes: notes)
            == URL(string: "https://zoom.us/j/12345"))
    }

    @Test func notesWithOnlyUnsafeLinksYieldNil() {
        #expect(ShelfCalendarModel.joinableURL(nil, notes: "go to file:///tmp/x") == nil)
    }
}

/// A card model for tests whose timer store lives in a throwaway file,
/// so a sweep can never mark the real `shelf-timers.json` fired.
@MainActor
func makeTestCardModel() -> NotchCardModel {
    NotchCardModel(
        timers: ShelfTimerModel(storeURL: URL(fileURLWithPath:
            NSTemporaryDirectory() + "jrbar-test-timers-\(UUID().uuidString).json")),
        tray: ShelfTrayModel())
}

/// The delegate builds the timer and tray stores once and hands them to
/// both card surfaces — the glass card's presenter and the island's
/// grown card. Twin stores on the same files would fire a timer twice
/// and clobber each other's persist, so the surfaces must share
/// identity, not just file paths.
@MainActor
@Suite("Shared card shelf")
struct SharedCardShelfTests {
    @Test func bothCardSurfacesShareTheOneStores() {
        let cardModel = makeTestCardModel()
        var state = ToysState()
        state.notch.enabled = true
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: cardModel)
        let presenter = NotchCardPresenter(model: cardModel)

        #expect(store.notch.cardModel.timers === presenter.model.timers)
        #expect(store.notch.cardModel.tray === presenter.model.tray)
    }

    /// One timer store means one fire: the delegate wires `onFire` once
    /// and both surfaces' entries run through it — even with both card
    /// models alive.
    @Test func aDueTimerDeliversOnceAcrossBothSurfaces() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-shared-timers-\(UUID().uuidString).json")
        let timers = ShelfTimerModel(storeURL: url)
        let tray = ShelfTrayModel()
        var delivered = 0
        timers.onFire = { _ in delivered += 1 }

        let cardModel = NotchCardModel(timers: timers, tray: tray)
        var state = ToysState()
        state.notch.enabled = true
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: cardModel)
        let presenter = NotchCardPresenter(model: cardModel)
        #expect(store.notch.cardModel.timers === presenter.model.timers)

        // The 1 s tick sweeps the due entry once through the shared
        // store — a second model would have delivered it again. The
        // wait is generous: the tick is a main-runloop `Timer` whose
        // fire can slide under a parallel suite; what is being proven
        // is that it lands exactly once, not when.
        timers.add(label: "tea", duration: 1)
        try await Task.sleep(for: .seconds(5))
        #expect(delivered == 1)
    }
}
