import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The macOS 27 engine's pure half: which apps an assertion conceals for
/// a reveal state, the allowlist that does it, and the click bridge's
/// hit test. The private API itself is exercised only by the app (a
/// signed bundle).
@Suite("Menu Bar — concealer")
struct MenuBarConcealerTests {
    private func item(_ id: String, owner: String = "App", x: Double = 1000,
                      identifier: String? = nil) -> MenuBarItem {
        var item = MenuBarItem(id: id, ownerPID: 500, ownerName: owner,
                               bounds: CGRect(x: x, y: 0, width: 24, height: 24),
                               title: nil, windowID: 0)
        item.identifier = identifier
        return item
    }

    @Test("hidden apps are concealed until the hidden run is revealed; always-hidden until theirs is")
    func concealedForState() {
        let apps: [String: MenuBarItemSection] = ["a.hidden": .hidden, "b.always": .alwaysHidden, "c.shown": .shown]
        #expect(MenuBarConcealPlan.concealed(apps: apps, revealed: []) == ["a.hidden", "b.always"])
        #expect(MenuBarConcealPlan.concealed(apps: apps, revealed: [.hidden]) == ["b.always"])
        #expect(MenuBarConcealPlan.concealed(apps: apps, revealed: [.hidden, .alwaysHidden]).isEmpty)
    }

    @Test("the allowlist is everything running that is not concealed plus the system-item owners, sorted")
    func allowlist() {
        let running: Set<String> = ["z.app", "a.app", "m.app", "h.app"]
        let expected = running.union(MenuBarConcealPlan.systemItemOwners)
            .subtracting(["h.app", "gone.app"]).sorted()
        #expect(MenuBarConcealPlan.allowlist(running: running, concealed: ["h.app", "gone.app"])
                == expected)
        // The system family survives conceal-all: Focus and friends
        // are MenuBarAgent extras, never ours to park.
        #expect(MenuBarConcealPlan.allowlist(running: running, concealed: running)
                == MenuBarConcealPlan.systemItemOwners.sorted())
    }

    @Test("a click bridges only on the system's clock, battery and Wi-Fi — never Control Center or an app")
    func bridgedItems() {
        let items = [
            item("clock", owner: "MenuBarAgent", x: 1400, identifier: "com.apple.menuextra.clock"),
            item("cc", owner: "MenuBarAgent", x: 1300, identifier: "com.apple.menuextra.controlcenter"),
            item("app", owner: "ChatGPT", x: 1000),
        ]
        #expect(MenuBarConcealPlan.bridgedItem(at: CGPoint(x: 1410, y: 10), items: items)?.id == "clock")
        #expect(MenuBarConcealPlan.bridgedItem(at: CGPoint(x: 1310, y: 10), items: items) == nil)
        #expect(MenuBarConcealPlan.bridgedItem(at: CGPoint(x: 1010, y: 10), items: items) == nil)
    }

    /// Records what the controller asks of the agent: every
    /// activation's allowlist, every invalidation, in order.
    @MainActor
    private final class FakeBackend: MenuBarConcealBackend {
        var log: [String] = []
        var allowlists: [[String]] = []
        var n = 0
        func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
            n += 1
            allowlists.append(allowedBundleIDs)
            log.append("activate \(n): \(allowedBundleIDs.joined(separator: ","))")
            return MenuBarAssertionToken(NSNumber(value: n))
        }
        func invalidate(_ token: MenuBarAssertionToken) {
            log.append("invalidate \((token.object as! NSNumber).intValue)")
        }
    }

    /// The allowlist universe this test's concealer sees: the running
    /// set plus our own bundle, which `seenRunning` always carries.
    private func universe(_ running: Set<String>) -> Set<String> {
        var ids = running
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }

    @MainActor
    @Test("the controller activates the new assertion before invalidating the old, and releases on an empty set")
    func controllerOrder() async {
        let fake = FakeBackend()
        let concealer = MenuBarConcealer(backend: fake)
        // Back-to-back applies coalesce to the latest target; spaced
        // out, each one lands.
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        concealer.apply(concealed: ["h.app", "s.app"], running: ["h.app", "s.app", "t.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        concealer.apply(concealed: [], running: ["h.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        // The allowlist carries the system-item owners (Focus, Now
        // Playing — MenuBarAgent extras that are never running apps)
        // and our own bundle ahead of every foreign id, sorted.
        let first = MenuBarConcealPlan.allowlist(
            running: universe(["h.app", "s.app"]), concealed: ["h.app"]).joined(separator: ",")
        let second = MenuBarConcealPlan.allowlist(
            running: universe(["h.app", "s.app", "t.app"]), concealed: ["h.app", "s.app"]).joined(separator: ",")
        #expect(fake.log == ["activate 1: \(first)", "activate 2: \(second)",
                             "invalidate 1", "invalidate 2"], "\(fake.log)")
        #expect(!concealer.isConcealing)
    }

    @MainActor
    @Test("reassert re-activates the live allowlist before invalidating — no concealment gap")
    func reassertResweeps() async {
        final class Fake: MenuBarConcealBackend {
            var log: [String] = []
            var n = 0
            func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
                n += 1
                log.append("activate \(n): \(allowedBundleIDs.joined(separator: ","))")
                return MenuBarAssertionToken(NSNumber(value: n))
            }
            func invalidate(_ token: MenuBarAssertionToken) {
                log.append("invalidate \((token.object as! NSNumber).intValue)")
            }
        }
        let fake = Fake()
        let concealer = MenuBarConcealer(backend: fake)
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        concealer.reassert()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Same concealed set, same allowlist — a second activation
        // lands before the first token dies so concealment never lifts.
        let owners = MenuBarConcealPlan.systemItemOwners.sorted().joined(separator: ",")
        #expect(fake.log == ["activate 1: \(owners),s.app",
                             "activate 2: \(owners),s.app",
                             "invalidate 1"], "\(fake.log)")
        #expect(concealer.isConcealing)
        // No live assertion → reassert is a no-op.
        let idle = MenuBarConcealer(backend: fake)
        idle.reassert()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.log.count == 3, "\(fake.log)")
    }

    @MainActor
    @Test("the allowlist universe is monotonic: a launch re-asserts once, a quit never, a concealed change once")
    func monotonicAllowlist() async {
        let fake = FakeBackend()
        let concealer = MenuBarConcealer(backend: fake)
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.n == 1, "\(fake.log)")
        // A launch joins the universe — one re-assert, the newcomer named.
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app", "n.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.n == 2, "\(fake.log)")
        #expect(fake.allowlists[1].contains("n.app"), "\(fake.allowlists[1])")
        // A quit removes nothing — the dead id stays allowlisted
        // rather than churning the assertion, and even the concealed
        // app leaving keeps the target: no activation either way.
        concealer.apply(concealed: ["h.app"], running: ["s.app", "n.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        concealer.apply(concealed: ["h.app"], running: ["s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.n == 2, "a quit must not re-assert: \(fake.log)")
        // A concealed-set change is real news — one activation, and
        // the quit app's dead id still counts as concealed.
        concealer.apply(concealed: ["h.app", "n.app"], running: ["s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.n == 3, "\(fake.log)")
        #expect(concealer.concealedApps == ["h.app", "n.app"])
        #expect(!fake.allowlists[2].contains("h.app") && !fake.allowlists[2].contains("n.app"))
    }

    @MainActor
    @Test("a scoped tile click narrows the target by exactly the opened app, then restores it")
    func scopedClickTarget() async {
        let fake = FakeBackend()
        let concealer = MenuBarConcealer(backend: fake)
        concealer.apply(concealed: ["a.app", "b.app"], running: ["a.app", "b.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Opening "a.app" stands only it — the assertion's target is
        // the full set minus exactly that bundle.
        concealer.apply(concealed: Set(["a.app", "b.app"]).subtracting(["a.app"]),
                        running: ["a.app", "b.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.n == 2, "\(fake.log)")
        #expect(concealer.concealedApps == ["b.app"])
        #expect(fake.allowlists[1].contains("a.app"), "only the opened app stands: \(fake.allowlists[1])")
        #expect(!fake.allowlists[1].contains("b.app"))
        // The rehide window ends: the full target goes back up.
        concealer.apply(concealed: ["a.app", "b.app"], running: ["a.app", "b.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.n == 3, "\(fake.log)")
        #expect(concealer.concealedApps == ["a.app", "b.app"])
        #expect(!fake.allowlists[2].contains("a.app"))
    }

    @MainActor
    @Test("an apply landing inside a suspend window defers to the restore, never converges mid-lift")
    func deferredApplyDuringSuspend() async {
        let fake = FakeBackend()
        let concealer = MenuBarConcealer(backend: fake)
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.n == 1)
        // The lift lands, then the window stays open. The restore can
        // start no sooner than the window after this moment, so a look
        // taken before that is provably mid-window.
        let window: Duration = .seconds(4)
        let suspended = ContinuousClock.now
        await concealer.suspend(for: 4)
        #expect(!concealer.isConcealing)
        // An apply inside the window waits for the restore — the bar
        // must not see a concealment flash mid-click.
        concealer.apply(concealed: ["h.app", "s.app"], running: ["h.app", "s.app"])
        // A runner stalled past the whole window before the apply went
        // in has nothing to judge: the premise is an apply inside it.
        guard ContinuousClock.now - suspended < window else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let midWindow = fake.n
        if ContinuousClock.now - suspended < window {
            #expect(midWindow == 1, "mid-window apply must not activate: \(fake.log)")
        }
        // Wait for the restore itself rather than guessing its moment.
        let start = ContinuousClock.now
        while fake.n < 2, ContinuousClock.now - start < .seconds(15) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        // The restore converged once with the deferred target — the
        // queued apply found nothing left to do.
        #expect(fake.n == 2, "\(fake.log)")
        #expect(concealer.concealedApps == ["h.app", "s.app"])
        #expect(!fake.allowlists[1].contains("h.app") && !fake.allowlists[1].contains("s.app"))
    }

    @MainActor
    @Test("an activation that throws with nothing live marks the engine failing until one lands or the target empties")
    func activationFailingSignal() async {
        final class Flaky: MenuBarConcealBackend {
            var refuse = true
            var n = 0
            func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
                n += 1
                if refuse { throw MenuBarAssessmentBackend.Failure.timedOut }
                return MenuBarAssertionToken(NSNumber(value: n))
            }
            func invalidate(_ token: MenuBarAssertionToken) {}
        }
        let flaky = Flaky()
        let concealer = MenuBarConcealer(backend: flaky)
        #expect(!concealer.activationFailing, "a fresh engine is starting, not failing")
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!concealer.isConcealing)
        #expect(concealer.activationFailing)
        // The agent takes the next one: the flag clears with it.
        flaky.refuse = false
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(concealer.isConcealing)
        #expect(!concealer.activationFailing)
        // A failed swap keeps the old assertion concealing — not failing.
        flaky.refuse = true
        concealer.apply(concealed: ["h.app", "s.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(concealer.isConcealing)
        #expect(!concealer.activationFailing)
        // Dropped, then failing again; an empty target ends it.
        await concealer.releaseAll()
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(concealer.activationFailing)
        concealer.apply(concealed: [], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!concealer.activationFailing)
    }

    @MainActor
    @Test("releaseAll drops the live assertion immediately, then unwinds queued work")
    func releaseAllDrops() async {
        let fake = FakeBackend()
        let concealer = MenuBarConcealer(backend: fake)
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        await concealer.releaseAll()
        // Synchronous enough for a quit: by the time releaseAll
        // returns the token is already gone — not queued behind
        // pending work.
        #expect(!concealer.isConcealing)
        #expect(fake.log.last == "invalidate 1", "\(fake.log)")
    }

    // MARK: lane menubar — the ⌘-drag's bridge, Apple's extras, the clock

    /// What the bridge reported, hop by hop.
    @MainActor
    private final class BridgeLog {
        var bridged: [CGPoint] = []
        var presses: [CGPoint] = []
        var releases: [(point: CGPoint, flags: CGEventFlags)] = []
    }

    /// Wait, bounded, for the bridge's main-actor hops to land.
    @MainActor
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func event(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type,
                                         mouseCursorPosition: point, mouseButton: .left))
        event.flags = flags
        return event
    }

    @Test("a plain press bridges; a ⌘-press never does")
    func bridgesFlags() {
        #expect(MenuBarConcealPlan.bridges(flags: []))
        #expect(MenuBarConcealPlan.bridges(flags: .maskAlternate))
        #expect(!MenuBarConcealPlan.bridges(flags: .maskCommand))
        #expect(!MenuBarConcealPlan.bridges(flags: [.maskCommand, .maskAlternate]))
    }

    @MainActor
    @Test("a ⌘-press on a bridged system item passes through and is never replayed")
    func commandPressPassesThrough() async throws {
        let log = BridgeLog()
        let bridge = MenuBarSystemClickBridge(
            onBridge: { log.bridged.append($0) },
            onCommandPress: { point, _ in log.presses.append(point) },
            onCommandRelease: { point, flags in log.releases.append((point, flags)) })
        let wifi = item("wifi", owner: "MenuBarAgent", x: 1165, identifier: "com.apple.menuextra.wifi")
        bridge.update(items: [wifi], concealing: true)
        let press = CGPoint(x: 1170, y: 10)
        let drop = CGPoint(x: 1000, y: 10)
        // Built, never posted: the tap's own decision, read directly.
        #expect(bridge.handle(type: .leftMouseDown, event: try event(.leftMouseDown, at: press,
                                                                     flags: .maskCommand)) != nil,
                "the ⌘-press goes straight through to the agent")
        // ⌘ let go mid-drag: the release still ends it, ⌥ held at the drop.
        #expect(bridge.handle(type: .leftMouseUp, event: try event(.leftMouseUp, at: drop,
                                                                   flags: .maskAlternate)) != nil)
        await settle { log.releases.count == 1 }
        #expect(log.presses == [press])
        #expect(log.releases.map(\.point) == [drop])
        #expect(log.releases.first?.flags.contains(.maskAlternate) == true)
        #expect(log.bridged.isEmpty, "never lifted, never replayed")
        // A plain click on the same item is still the bridge's.
        #expect(bridge.handle(type: .leftMouseDown, event: try event(.leftMouseDown, at: press)) == nil,
                "held back for the lift")
        #expect(bridge.handle(type: .leftMouseUp, event: try event(.leftMouseUp, at: press)) == nil,
                "its release goes with it")
        await settle { log.bridged.count == 1 }
        #expect(log.bridged == [press])
        #expect(log.releases.count == 1, "a plain click is no drag")
    }

    @Test("Apple's extras conceal like apps only with the flag; the system's own owners never")
    func appleExtras() {
        #expect(MenuBarConcealPlan.canConcealApp("com.tinyspeck.slackmacgap"))
        #expect(!MenuBarConcealPlan.canConcealApp("com.apple.weather.menu"))
        #expect(MenuBarConcealPlan.canConcealApp("com.apple.weather.menu", appleExtras: true))
        #expect(MenuBarConcealPlan.canConcealApp("com.apple.Passwords.MenuBarExtra", appleExtras: true))
        #expect(!MenuBarConcealPlan.canConcealApp("com.apple.menuextra.clock", appleExtras: true),
                "a system item's key is concealSystemItems's alone")
        for owner in ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.TextInputMenuAgent",
                      "com.apple.Spotlight", "com.apple.Siri"] {
            #expect(!MenuBarConcealPlan.canConcealApp(owner, appleExtras: true), "\(owner)")
        }
    }

    @Test("with the flag on a covered extra's pick becomes its app's section, and back when it goes off")
    func appleExtrasMigration() {
        var weather = item("Weather", owner: "Weather", x: 1300)
        weather.bundleID = "com.apple.weather.menu"
        var slack = item("Slack", owner: "Slack", x: 1000)
        slack.bundleID = "com.tinyspeck.slackmacgap"
        let on = MenuBarUtility.migrateAppleExtras(on: true, sections: ["Weather": .alwaysHidden],
                                                  concealedApps: ["com.tinyspeck.slackmacgap": .hidden],
                                                  items: [weather, slack])
        #expect(on.sections.isEmpty)
        #expect(on.concealedApps == ["com.tinyspeck.slackmacgap": .hidden,
                                     "com.apple.weather.menu": .alwaysHidden])
        let off = MenuBarUtility.migrateAppleExtras(on: false, sections: on.sections,
                                                   concealedApps: on.concealedApps, items: [weather, slack])
        #expect(off.sections == ["Weather": .alwaysHidden], "a cover where it sits again")
        #expect(off.concealedApps == ["com.tinyspeck.slackmacgap": .hidden])
        // An extra not listed right now keeps its pick where it is.
        let unlisted = MenuBarUtility.migrateAppleExtras(on: true, sections: ["Weather": .hidden],
                                                        concealedApps: [:], items: [slack])
        #expect(unlisted.sections == ["Weather": .hidden])
        // The filter keeps what today's flags can act on.
        var curation = MenuBarCuration()
        let apps: [String: MenuBarItemSection] = ["com.apple.weather.menu": .hidden, "x.app": .hidden,
                                                  "com.apple.menuextra.clock": .hidden]
        #expect(MenuBarUtility.supportedConcealed(apps, curation: curation) == ["x.app": .hidden])
        // In a file that never chose, an extra's entry is old learning's
        // and goes; once the person turned the flag off on the card, a
        // migration keeps an unlisted extra's pick, so it becomes a cover
        // once the extra is listed again.
        #expect(MenuBarUtility.keptConcealed(apps, curation: curation) == ["x.app": .hidden])
        var turnedOff = MenuBarCuration()
        turnedOff.concealAppleExtras = false
        #expect(MenuBarUtility.keptConcealed(apps, curation: turnedOff)
                == ["com.apple.weather.menu": .hidden, "x.app": .hidden])
        let offUnlisted = MenuBarUtility.migrateAppleExtras(on: false, sections: [:],
                                                           concealedApps: ["com.apple.weather.menu": .hidden],
                                                           items: [slack])
        #expect(MenuBarUtility.keptConcealed(offUnlisted.concealedApps, curation: turnedOff)
                == ["com.apple.weather.menu": .hidden], "the pick waits for its item")
        let listedAgain = MenuBarUtility.migrateAppleExtras(on: false, sections: offUnlisted.sections,
                                                           concealedApps: offUnlisted.concealedApps,
                                                           items: [weather, slack])
        #expect(listedAgain.sections == ["Weather": .hidden], "a cover where it sits")
        #expect(listedAgain.concealedApps.isEmpty)
        curation.concealAppleExtras = true
        curation.concealSystemItems = true
        #expect(MenuBarUtility.supportedConcealed(apps, curation: curation) == apps)
    }

    @Test("the clock and Control Center leave the system-item list only with the flag; Wi-Fi never")
    func systemItemsTable() {
        let all = MenuBarConcealPlan.allSystemItems
        #expect(all == Array(0...8))
        let hidden: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter",
                                   "com.apple.menuextra.wifi"]
        #expect(MenuBarConcealPlan.allowedSystemItems(concealed: hidden, enabled: false) == all)
        #expect(MenuBarConcealPlan.allowedSystemItems(concealed: hidden, enabled: true)
                == all.filter { $0 != 2 && $0 != 8 })
        #expect(MenuBarConcealPlan.concealableSystemItems["com.apple.menuextra.wifi"] == nil)
        #expect(MenuBarConcealPlan.concealableSystemItems["com.apple.menuextra.battery"] == nil)
        #expect(MenuBarUtility.systemKeys(in: hidden.union(["x.app"]))
                == ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"])
    }

    @Test("the helper hears the plain allowlist while every system item stays, the object otherwise")
    func helperRequestLine() throws {
        let plain = try #require(MenuBarAsserterBackend.requestLine(
            allowedBundleIDs: ["a.app"], allowedSystemItems: MenuBarConcealPlan.allSystemItems))
        #expect(plain == #"["a.app"]"#)
        let object = try #require(MenuBarAsserterBackend.requestLine(
            allowedBundleIDs: ["a.app"], allowedSystemItems: [0, 1, 3]))
        #expect(object == #"{"bundles":["a.app"],"systemItems":[0,1,3]}"#)
    }

    @MainActor
    @Test("a concealed clock rides the system-item list, never the allowlist")
    func controllerSystemItems() async {
        final class Recorder: MenuBarConcealBackend {
            var calls: [(bundles: [String], system: [Int])] = []
            func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
                try await activate(allowedBundleIDs: allowedBundleIDs,
                                   allowedSystemItems: MenuBarConcealPlan.allSystemItems)
            }
            func activate(allowedBundleIDs: [String], allowedSystemItems: [Int]) async throws -> MenuBarAssertionToken {
                calls.append((allowedBundleIDs, allowedSystemItems))
                return MenuBarAssertionToken(NSNumber(value: calls.count))
            }
            func invalidate(_ token: MenuBarAssertionToken) {}
        }
        let recorder = Recorder()
        let concealer = MenuBarConcealer(backend: recorder)
        // Nothing concealed but the clock: an assertion still goes up.
        concealer.apply(concealed: [], running: ["s.app"], systemItems: [0, 1, 3, 4, 5, 6, 7, 8])
        for _ in 0..<200 where recorder.calls.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.system == [0, 1, 3, 4, 5, 6, 7, 8])
        #expect(recorder.calls.first?.bundles.contains("s.app") == true)
        #expect(concealer.isConcealing)
        // Back to every item: the assertion drops.
        concealer.apply(concealed: [], running: ["s.app"])
        for _ in 0..<200 where concealer.isConcealing { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(!concealer.isConcealing)
    }
}
