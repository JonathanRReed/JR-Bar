import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The macOS 27 engine's pure half: which apps an assertion conceals for
/// a reveal state, the allowlist that does it, the one-time seed from
/// the spacer plan, and the click bridge's hit test. The private API
/// itself is exercised only by the app (a signed bundle).
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

    @Test("the allowlist is everything running that is not concealed, sorted")
    func allowlist() {
        let running: Set<String> = ["z.app", "a.app", "m.app", "h.app"]
        #expect(MenuBarConcealPlan.allowlist(running: running, concealed: ["h.app", "gone.app"])
                == ["a.app", "m.app", "z.app"])
    }

    @Test("the seed takes the spacer plan's hidden apps, never ours, the system's, or a bundle-less helper")
    func seed() {
        let map = MenuBarConcealPlan.seed(
            hidden: [(item("ChatGPT"), "com.openai.chat"),
                     (item("Clock", owner: "MenuBarAgent"), "com.apple.controlcenter"),
                     (item("Helper"), nil),
                     (item("JR-Bar", owner: "JR-Bar"), "com.jonathanreed.jrbar")],
            alwaysHidden: [(item("Shottr"), "cc.ffitch.shottr")],
            own: "com.jonathanreed.jrbar")
        #expect(map == ["com.openai.chat": .hidden, "cc.ffitch.shottr": .alwaysHidden])
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

    @MainActor
    @Test("the controller activates the new assertion before invalidating the old, and releases on an empty set")
    func controllerOrder() async {
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
        // Back-to-back applies coalesce to the latest target; spaced
        // out, each one lands.
        concealer.apply(concealed: ["h.app"], running: ["h.app", "s.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        concealer.apply(concealed: ["h.app", "s.app"], running: ["h.app", "s.app", "t.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        concealer.apply(concealed: [], running: ["h.app"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(fake.log == ["activate 1: s.app", "activate 2: t.app", "invalidate 1", "invalidate 2"], "\(fake.log)")
        #expect(!concealer.isConcealing)
    }
}
