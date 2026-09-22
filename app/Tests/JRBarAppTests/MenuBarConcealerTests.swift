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
        // The lift lands, then the window stays open ~0.5 s.
        await concealer.suspend(for: 0.5)
        #expect(!concealer.isConcealing)
        // An apply inside the window waits for the restore — the bar
        // must not see a concealment flash mid-click.
        concealer.apply(concealed: ["h.app", "s.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(fake.n == 1, "mid-window apply must not activate: \(fake.log)")
        try? await Task.sleep(nanoseconds: 600_000_000)
        // The restore converged once with the deferred target — the
        // queued apply found nothing left to do.
        #expect(fake.n == 2, "\(fake.log)")
        #expect(concealer.concealedApps == ["h.app", "s.app"])
        #expect(!fake.allowlists[1].contains("h.app") && !fake.allowlists[1].contains("s.app"))
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
}
