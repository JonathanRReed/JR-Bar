import AppKit
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

// MARK: - Shelf parity (lane utilities)

/// The shelf as good as Dropover and Yoink: a drag out copies unless ⌘
/// asks for the move, remove-after-drag takes only the dragged chip, the
/// instant actions never overwrite a file, Copy Text reads an image on
/// this Mac, and the shake's sensitivity only ever loosens as it rises.
extension ShelfTests {
    /// A tray on its own defaults key, cleared before and after.
    private func freshTray() -> ShelfTrayModel {
        UserDefaults.standard.removeObject(forKey: "jrbar.shelfTray.paths")
        return ShelfTrayModel()
    }

    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-shelf-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aDragOutCopiesUnlessCommandAsksForTheMove() {
        #expect(ShelfDragOutRule.mask(policy: .copy, commandHeld: false, context: .outsideApplication) == .copy)
        #expect(ShelfDragOutRule.mask(policy: .copy, commandHeld: true, context: .outsideApplication) == .move)
        #expect(ShelfDragOutRule.mask(policy: .move, commandHeld: false, context: .outsideApplication) == .move)
        // Inside JR-Bar the strip's own rearranging keeps every operation.
        #expect(ShelfDragOutRule.mask(policy: .copy, commandHeld: false, context: .withinApplication)
                .contains(.move))
        #expect(NotchSettings().shelfDragOut == .copy, "copy is the default")
    }

    @Test func removeAfterDragTakesOnlyTheDraggedChip() {
        let tray = freshTray()
        defer { UserDefaults.standard.removeObject(forKey: "jrbar.shelfTray.paths") }
        looseAdds(tray, ["/tmp/drag-a/a.txt", "/tmp/drag-b/b.txt", "/tmp/drag-c/c.txt"])
        let dragged = tray.entries[1]
        // Off: nothing leaves.
        tray.finishDragOut(dragged, operation: .copy, outside: true)
        #expect(tray.entries.count == 3)
        tray.removeAfterDragOut = { true }
        // A drop back inside JR-Bar, or a refused drop, keeps it.
        tray.finishDragOut(dragged, operation: .copy, outside: false)
        tray.finishDragOut(dragged, operation: [], outside: true)
        #expect(tray.entries.count == 3)
        tray.finishDragOut(dragged, operation: .copy, outside: true)
        #expect(tray.entries.map(\.displayName) == ["a.txt", "c.txt"])
    }

    @Test func newestFirstLandsAtTheFrontAndEvictsFromTheBack() {
        let tray = freshTray()
        defer { UserDefaults.standard.removeObject(forKey: "jrbar.shelfTray.paths") }
        tray.newestFirst = { true }
        looseAdds(tray, (0..<(ShelfTrayModel.maxItems + 2)).map { "/tmp/newest-\($0)/n\($0).txt" })
        #expect(tray.items.first?.name == "n\(ShelfTrayModel.maxItems + 1).txt")
        #expect(tray.items.count == ShelfTrayModel.maxItems)
        #expect(!tray.items.contains { $0.name == "n0.txt" }, "the oldest went, from the back")
    }

    @Test func commandAndShiftClickPickChipsAndClearShelfTakesAll() {
        let tray = freshTray()
        defer { UserDefaults.standard.removeObject(forKey: "jrbar.shelfTray.paths") }
        looseAdds(tray, (0..<5).map { "/tmp/pick-\($0)/p\($0).txt" })
        let chips = tray.entries
        tray.toggleSelection(chips[1])
        tray.extendSelection(to: chips[3])
        #expect(tray.selectedIDs == Set(chips[1...3].map(\.id)))
        tray.toggleSelection(chips[2])
        #expect(tray.selectedIDs == [chips[1].id, chips[3].id])
        // A verb on a picked chip acts on the whole pick, in strip order.
        #expect(tray.targets(for: chips[3]).map(\.id) == [chips[1].id, chips[3].id])
        #expect(tray.targets(for: chips[0]).map(\.id) == [chips[0].id], "an unpicked chip is itself")
        tray.removeAll()
        #expect(tray.entries.isEmpty)
        #expect(tray.selectedIDs.isEmpty)
    }

    @Test func compressNamesUniquelyAndNeverOverwrites() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try "keep me".write(to: file, atomically: true, encoding: .utf8)
        // Two names already taken, one of them by a file that must survive.
        let taken = folder.appendingPathComponent("notes.txt.zip")
        try "not a zip".write(to: taken, atomically: true, encoding: .utf8)
        try "also taken".write(to: folder.appendingPathComponent("notes.txt 2.zip"),
                               atomically: true, encoding: .utf8)
        let zip = try await ShelfActions.compress([file])
        #expect(zip.lastPathComponent == "notes.txt 3.zip")
        #expect(try String(contentsOf: taken, encoding: .utf8) == "not a zip", "never overwritten")
        let again = try await ShelfActions.compress([file])
        #expect(again.lastPathComponent == "notes.txt 4.zip")
        // Several files go into one Archive.zip beside the first.
        let other = folder.appendingPathComponent("more.txt")
        try "more".write(to: other, atomically: true, encoding: .utf8)
        let archive = try await ShelfActions.compress([file, other])
        #expect(archive.lastPathComponent == "Archive.zip")
        let size = try #require(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 100)
        #expect(FileManager.default.fileExists(atPath: file.path), "the original stays")
    }

    @Test func copyTextReadsAnImageOnThisMac() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("words.png")
        try Self.drawText("SHELF READS THIS", to: png)
        #expect(ShelfActions.hasText(png))
        let text = try #require(try ShelfActions.text(of: png))
        #expect(text.uppercased().contains("SHELF"), "read: \(text)")
        #expect(text.uppercased().contains("READS"), "read: \(text)")
    }

    @Test func convertWritesBesideTheOriginalUnderAFreeName() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("shot.png")
        try Self.drawText("JPEG", to: png)
        try "taken".write(to: folder.appendingPathComponent("shot.jpg"), atomically: true, encoding: .utf8)
        let jpeg = try ShelfActions.convert(png, to: .jpeg)
        #expect(jpeg.lastPathComponent == "shot 2.jpg")
        #expect(try String(contentsOf: folder.appendingPathComponent("shot.jpg"), encoding: .utf8) == "taken")
        #expect(NSImage(contentsOf: jpeg) != nil)
        #expect(ShelfActionMenu.verbs(for: [png]).contains(.convert(.jpeg)))
        #expect(!ShelfActionMenu.verbs(for: [folder.appendingPathComponent("a.zip")]).contains(.copyText))
    }

    @Test func convertOffersAndMakesOnlyAnotherFormat() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("shot.png")
        let jpg = folder.appendingPathComponent("photo.jpg")
        // A PNG alone offers JPEG only; a PNG beside a JPEG offers both.
        let pngVerbs = ShelfActionMenu.verbs(for: [png])
        #expect(pngVerbs.contains(.convert(.jpeg)))
        #expect(!pngVerbs.contains(.convert(.png)), "a PNG is never offered as a PNG")
        #expect(ShelfActionMenu.verbs(for: [jpg]).contains(.convert(.png)))
        #expect(!ShelfActionMenu.verbs(for: [jpg]).contains(.convert(.jpeg)))
        #expect(ShelfActionMenu.verbs(for: [png, jpg]).contains(.convert(.png)))
        #expect(ShelfActionMenu.verbs(for: [png, jpg]).contains(.convert(.jpeg)))
        // Convert to PNG over a PNG writes nothing beside it.
        try Self.drawText("PNG", to: png)
        let result = ShelfActions.convert([png], to: .png)
        #expect(result.made.isEmpty && result.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("shot 2.png").path))
        #expect(throws: ShelfActions.ActionError.self) { try ShelfActions.convert(png, to: .png) }
    }

    @Test func aMoveThatFailsPartWayKeepsTheChipsThatMoved() throws {
        let tray = freshTray()
        defer { UserDefaults.standard.removeObject(forKey: "jrbar.shelfTray.paths") }
        let from = try scratchFolder()
        let to = try scratchFolder()
        defer {
            try? FileManager.default.removeItem(at: from)
            try? FileManager.default.removeItem(at: to)
        }
        let first = from.appendingPathComponent("first.txt")
        try "one".write(to: first, atomically: true, encoding: .utf8)
        // The second is gone before the move reaches it.
        let second = from.appendingPathComponent("second.txt")
        let result = ShelfActions.transfer([first, second], to: to, move: true)
        #expect(result.landed.count == 1)
        #expect(result.failure != nil)
        #expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("first.txt").path))

        tray.add([first])
        tray.finishTransfer(result, to: to, move: true)
        #expect(tray.items.map(\.path) == [to.appendingPathComponent("first.txt").path],
                "the moved chip follows its file")
        #expect(tray.items.allSatisfy { !$0.missing })
        #expect(tray.actionNotice?.hasPrefix("Moved 1, then couldn't move the next") == true,
                "\(tray.actionNotice ?? "")")
    }

    @Test func theShelfSwitchedOffTakesNoFiles() {
        let tray = freshTray()
        defer { UserDefaults.standard.removeObject(forKey: "jrbar.shelfTray.paths") }
        tray.shelfEnabled = { false }
        tray.add([URL(fileURLWithPath: "/tmp/shelf-off/a.txt")])
        #expect(tray.entries.isEmpty)
        tray.shelfEnabled = { true }
        tray.add([URL(fileURLWithPath: "/tmp/shelf-off/a.txt")])
        #expect(tray.entries.count == 1)
    }

    @Test func moveToCarriesTheChipAlong() throws {
        let tray = freshTray()
        defer { UserDefaults.standard.removeObject(forKey: "jrbar.shelfTray.paths") }
        tray.add([URL(fileURLWithPath: "/tmp/move-from/m.txt")])
        tray.relocate(from: "/tmp/move-from/m.txt", to: "/tmp/move-to/m.txt")
        #expect(tray.items.map(\.path) == ["/tmp/move-to/m.txt"])
    }

    @Test func shakeSensitivityOnlyLoosensAsItRises() {
        var previous = ShelfShakeDetector.thresholds(sensitivity: 0)
        #expect(previous.reversals == 6 && previous.amplitude == 45)
        let middle = ShelfShakeDetector.thresholds(sensitivity: 0.5)
        #expect(middle.reversals == 4 && middle.amplitude == 30, "the middle is today's shake")
        let easiest = ShelfShakeDetector.thresholds(sensitivity: 1)
        #expect(easiest.reversals == 3 && easiest.amplitude == 20)
        for step in 1...20 {
            let next = ShelfShakeDetector.thresholds(sensitivity: Double(step) / 20)
            #expect(next.reversals <= previous.reversals)
            #expect(next.amplitude <= previous.amplitude)
            previous = next
        }
        // Four 25-point swings: too small for the default, a shake when easy.
        let small = (0..<9).map {
            ShelfShakeDetector.Sample(x: $0.isMultiple(of: 2) ? 100 : 125, at: Double($0) * 0.05)
        }
        #expect(!ShelfShakeDetector.isShake(small, sensitivity: 0.5))
        #expect(ShelfShakeDetector.isShake(small, sensitivity: 1))
    }

    /// Black words on white, large enough for Vision to read.
    static func drawText(_ text: String, to url: URL) throws {
        let size = NSSize(width: 900, height: 200)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
