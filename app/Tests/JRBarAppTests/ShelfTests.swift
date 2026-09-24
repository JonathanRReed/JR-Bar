import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// W12's shelf utilities: tray revalidation, persisted timers with
/// sleep/clock semantics, and the calendar's safe-URL rule.
@MainActor
@Suite struct ShelfTests {

    // MARK: - Tray (T49)

    /// Loose chips need their own folders — two files from the same
    /// folder are a stack now, and two in one drop always are.
    private func looseAdds(_ tray: ShelfTrayModel, _ paths: [String]) {
        for path in paths {
            tray.add([URL(fileURLWithPath: path)])
        }
    }

    @Test func trayAddsDedupesAndBounds() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        let paths = (0..<45).map { "/tmp/tray-dir-\($0)/file-\($0).txt" }
        looseAdds(tray, paths)
        #expect(tray.items.count == ShelfTrayModel.maxItems)
        // Bounded: the newest items win, the oldest drop off.
        #expect(tray.items.last?.name == "file-44.txt")
        #expect(tray.items.first?.name == "file-5.txt")

        // Re-adding paths still held is a no-op — no duplicates.
        for path in paths.suffix(5) {
            tray.add([URL(fileURLWithPath: path)])
        }
        #expect(tray.items.count == ShelfTrayModel.maxItems)
        #expect(Set(tray.items.map(\.path)).count == tray.items.count)
    }

    @Test func evictionSpeaksItsName() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        // The strip is bounded, but a dropped reference must be said
        // out loud — a shelf that silently forgets reads as data loss.
        #expect(tray.evictionNotice == nil)
        looseAdds(tray, (0..<45).map { "/tmp/evict-\($0)/f.txt" })
        #expect(tray.items.count == ShelfTrayModel.maxItems)
        // One file at a time: each add names the chip it pushed off.
        #expect(tray.evictionNotice?.contains("f.txt") == true)
        #expect(tray.evictionNotice?.contains("dropped off") == true)
        #expect(tray.evictionNotice?.contains("untouched") == true)

        // A multi-file drop onto a full shelf evicts a run — and the
        // sentence counts the items, not the entries they came in as.
        tray.add((0..<3).map {
            URL(fileURLWithPath: "/tmp/burst-dir/burst-\($0).txt") })
        #expect(tray.evictionNotice?.contains("3 oldest items") == true)

        // A non-evicting add clears the stale sentence.
        tray.remove(tray.entries.first!)
        #expect(tray.evictionNotice == nil)
        tray.add([URL(fileURLWithPath: "/tmp/evict-new-dir/f.txt")])
        #expect(tray.evictionNotice == nil)

        // Fill again and a single dropped chip names itself.
        looseAdds(tray, (0..<ShelfTrayModel.maxItems).map {
            "/tmp/refill-\($0)/refill-\($0).txt"
        })
        tray.add([URL(fileURLWithPath: "/tmp/one-more-dir/one-more.txt")])
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
        tray.add([real])
        tray.add([gone])

        tray.revalidate()
        #expect(tray.items.count == 2)
        #expect(tray.items.first { $0.path == real.path }?.missing == false)
        #expect(tray.items.first { $0.path == gone.path }?.missing == true)

        // Deleting after the add flips it on the next revalidation —
        // the entry stays, marked, until the user removes it.
        try? FileManager.default.removeItem(at: real)
        tray.revalidate()
        #expect(tray.items.first { $0.path == real.path }?.missing == true)
    }

    @Test func missingEntryCannotRevealOrShare() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        let gone = URL(fileURLWithPath: "/tmp/jrbar-gone-\(UUID().uuidString)")
        tray.add([gone])
        tray.revalidate()
        let entry = tray.entries.first!
        #expect(tray.provider(for: entry) == nil)
        #expect(tray.shareableURLs(for: entry).isEmpty)
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

        looseAdds(tray, ["/tmp/ra/a.txt", "/tmp/rb/b.txt", "/tmp/rc/c.txt"])
        let a = tray.entries[0], c = tray.entries[2]

        // Drag C onto A — C lands ahead of A.
        tray.move(c, before: a)
        #expect(tray.entries.map(\.displayName) == ["c.txt", "a.txt", "b.txt"])
        // The arrangement is the user's — it survives a reload.
        let reloaded = ShelfTrayModel()
        #expect(reloaded.entries.map(\.displayName) == ["c.txt", "a.txt", "b.txt"])

        // Moving onto itself is a no-op.
        tray.move(tray.entries[0], before: tray.entries[0])
        #expect(tray.entries.map(\.displayName) == ["c.txt", "a.txt", "b.txt"])
    }

    // MARK: - Stacks

    @Test func sameDropBecomesAStack() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        // Three files in one drop → one chip, named for the folder
        // they share.
        tray.add([URL(fileURLWithPath: "/tmp/shots/1.png"),
                  URL(fileURLWithPath: "/tmp/shots/2.png"),
                  URL(fileURLWithPath: "/tmp/shots/3.png")])
        #expect(tray.entries.count == 1)
        guard case .stack(let stack) = tray.entries[0] else {
            Issue.record("a same-drop add should stack")
            return
        }
        #expect(stack.items.count == 3)
        #expect(stack.name == "shots")
        #expect(stack.folder == "/tmp/shots")

        // A mixed-folder drop still stacks, named by its count.
        tray.add([URL(fileURLWithPath: "/tmp/x/m1.png"),
                  URL(fileURLWithPath: "/tmp/y/m2.png")])
        guard case .stack(let mixed) = tray.entries[1] else {
            Issue.record("a mixed drop should still stack")
            return
        }
        #expect(mixed.name == "2 items")
        #expect(mixed.folder == nil)
    }

    @Test func sameFolderSingleJoinsTheStackOrAPeer() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        // A second file from an existing loose chip's folder stacks
        // the pair where the first stood.
        looseAdds(tray, ["/tmp/keep/a.txt", "/tmp/else/z.txt"])
        tray.add([URL(fileURLWithPath: "/tmp/keep/b.txt")])
        #expect(tray.entries.count == 2)
        guard case .stack(let stack) = tray.entries[0] else {
            Issue.record("same-folder singles should stack")
            return
        }
        #expect(stack.items.map(\.name) == ["a.txt", "b.txt"])

        // And a third from the folder joins the stack itself.
        tray.add([URL(fileURLWithPath: "/tmp/keep/c.txt")])
        guard case .stack(let grown) = tray.entries[0] else {
            Issue.record("the stack should still be first")
            return
        }
        #expect(grown.items.count == 3)
    }

    @Test func dissolveSplitMergeAndDropOnto() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        tray.add([URL(fileURLWithPath: "/tmp/s/1.png"),
                  URL(fileURLWithPath: "/tmp/s/2.png"),
                  URL(fileURLWithPath: "/tmp/s/3.png")])
        let stackEntry = tray.entries[0]

        // Split lands the members where the stack stood.
        tray.dissolve(stackEntry)
        #expect(tray.entries.map(\.displayName) == ["1.png", "2.png", "3.png"])

        // Merge pulls the next chip into the first's stack.
        tray.mergeWithNext(tray.entries[0])
        #expect(tray.entries.count == 2)
        guard case .stack(let merged) = tray.entries[0] else {
            Issue.record("merge should leave a stack")
            return
        }
        #expect(merged.items.map(\.name) == ["1.png", "2.png"])

        // A drop onto a stack joins it rather than landing before it.
        tray.add([URL(fileURLWithPath: "/tmp/other/4.png")],
                 onto: tray.entries[0])
        guard case .stack(let grown) = tray.entries[0] else {
            Issue.record("the stack should survive a drop onto it")
            return
        }
        #expect(grown.items.count == 3)
        // The new member mixes folders, so the folder key is gone.
        #expect(grown.folder == nil)

        // Pulling members out thins to a loose chip at one.
        let stackID = grown.id
        tray.removeItem(grown.items[0], from: stackID)
        tray.removeItem(tray.entries[0].items[0], from: stackID)
        #expect(tray.entries.count == 2)
        if case .item(let last) = tray.entries[0] {
            #expect(last.name == "4.png")
        } else {
            Issue.record("a stack thinned to one should dissolve")
        }
    }

    @Test func stacksPersistAndFlatStoresMigrate() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "jrbar.shelfTray.paths")
        let tray = ShelfTrayModel()
        defer { defaults.removeObject(forKey: "jrbar.shelfTray.paths") }

        looseAdds(tray, ["/tmp/pa/a.txt"])
        tray.add([URL(fileURLWithPath: "/tmp/ps/1.png"),
                  URL(fileURLWithPath: "/tmp/ps/2.png")])
        let reloaded = ShelfTrayModel()
        #expect(reloaded.entries.count == 2)
        guard case .stack(let stack) = reloaded.entries[1] else {
            Issue.record("a stack should survive a reload")
            return
        }
        #expect(stack.items.map(\.name) == ["1.png", "2.png"])
        #expect(stack.name == "ps")

        // The pre-stacks store was a flat [String] — it loads as
        // loose items, nothing invented.
        defaults.set(["/tmp/old/one.txt", "/tmp/old/two.txt"],
                     forKey: "jrbar.shelfTray.paths")
        let migrated = ShelfTrayModel()
        #expect(migrated.entries.count == 2)
        #expect(migrated.entries.allSatisfy {
            if case .item = $0 { return true }
            return false
        })
        #expect(migrated.items.map(\.name) == ["one.txt", "two.txt"])

        // A record that is neither shape decodes to nothing rather
        // than sinking the load.
        defaults.set([["paths": ["/tmp/ok/a.txt", "/tmp/ok/b.txt"],
                       "id": "s1", "name": "ok"],
                      ["bogus": 1],
                      ["path": "/tmp/ok/loose.txt"]],
                     forKey: "jrbar.shelfTray.paths")
        let tolerant = ShelfTrayModel()
        #expect(tolerant.entries.count == 2)
        #expect(tolerant.items.count == 3)
    }

    // MARK: - Shake to summon

    private func samples(_ xs: [CGFloat],
                         dt: TimeInterval = 0.05) -> [ShelfShakeDetector.Sample] {
        xs.enumerated().map {
            ShelfShakeDetector.Sample(x: $0.element,
                                      at: Double($0.offset) * dt)
        }
    }

    @Test func aFastZigzagIsAShake() {
        // ±50 pt sweeps every 50 ms — six legs over 300 ms, five
        // reversals, each a full amplitude.
        #expect(ShelfShakeDetector.isShake(
            samples([0, 50, 0, 50, 0, 50, 0])) == true)
        // Exactly four reversals still counts.
        #expect(ShelfShakeDetector.isShake(
            samples([0, 50, 0, 50, 0, 50])) == true)
    }

    @Test func aStraightDragIsNotAShake() {
        #expect(ShelfShakeDetector.isShake(
            samples([0, 40, 80, 120, 160, 200])) == false)
    }

    @Test func aSlowWiggleIsNotAShake() {
        // The same zigzag spread over three seconds — no 600 ms
        // window holds four reversals.
        #expect(ShelfShakeDetector.isShake(
            samples([0, 50, 0, 50, 0, 50, 0], dt: 0.5)) == false)
    }

    @Test func aSmallJitterIsNotAShake() {
        // Fast but small — legs under the 30 pt amplitude never earn
        // a reversal.
        #expect(ShelfShakeDetector.isShake(
            samples([0, 10, 0, 10, 0, 10, 0, 10])) == false)
        // And a near-stationary drag with sub-deadband noise is calm.
        #expect(ShelfShakeDetector.isShake(
            samples([0, 1, 0, -1, 0, 1, 0])) == false)
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
        tray: ShelfTrayModel(),
        runtimeEnabled: false)
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
                              state: state, cardModel: cardModel,
                              notchRuntimeEnabled: false)
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

        let cardModel = NotchCardModel(timers: timers, tray: tray,
                                       runtimeEnabled: false)
        var state = ToysState()
        state.notch.enabled = true
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: state, cardModel: cardModel,
                              notchRuntimeEnabled: false)
        let presenter = NotchCardPresenter(model: cardModel)
        #expect(store.notch.cardModel.timers === presenter.model.timers)

        // Both surfaces sweep the one shared store — a second model would
        // have delivered the due entry again. The sweeps are run by hand
        // (the heartbeat is a main-runloop `Timer`, which a test runner
        // need not pump at all): what is proven is that the entry lands
        // exactly once however many sweeps see it, not when.
        timers.add(label: "tea", duration: 1)
        try await Task.sleep(for: .seconds(1.2))
        timers.sweep()
        presenter.model.timers.sweep()
        store.notch.cardModel.timers.sweep()
        #expect(delivered == 1)
    }
}
