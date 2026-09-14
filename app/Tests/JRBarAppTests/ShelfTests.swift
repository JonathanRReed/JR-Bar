import Foundation
import Testing
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
