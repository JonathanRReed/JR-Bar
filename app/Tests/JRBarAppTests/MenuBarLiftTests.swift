import ApplicationServices
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Lifts — one app standing alone on the row for a moment — and the
/// "show for updates" pass that uses them: a changed app stands alone
/// instead of the whole run, and only the items you mark interrupt.
@Suite("Menu Bar — lifts and show for updates")
struct MenuBarLiftTests {
    private func item(_ id: String, bundle: String?) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 1, ownerName: id,
                    bounds: CGRect(x: 0, y: 0, width: 24, height: 24),
                    title: nil, windowID: 1, bundleID: bundle)
    }

    @Test("a live lift leaves its app out of the target; an expired one does not; ours never join")
    func liveTarget() {
        let now = Date(timeIntervalSince1970: 1_000)
        let target: Set<String> = ["com.a", "com.b", Bundle.main.bundleIdentifier ?? "com.jonathanreed.jrbar"]
        let lifted = MenuBarUtility.liveTarget(target, lifts: ["com.a": now.addingTimeInterval(5),
                                                               "com.b": now.addingTimeInterval(-1)],
                                               now: now)
        #expect(!lifted.contains("com.a"))
        #expect(lifted.contains("com.b"), "an expired lift conceals again")
        if let own = Bundle.main.bundleIdentifier {
            #expect(!lifted.contains(own))
        }
    }

    @Test("under the concealer a changed app is lifted alone; an extra or a helper reveals its section")
    func updateRevealConcealing() {
        let vpn = item("vpn", bundle: "com.vpn")
        let clock = item("clock", bundle: "com.apple.menuextra.clock")
        let helper = item("helper", bundle: nil)
        let reveal = MenuBarUtility.updateReveal(
            changed: [(vpn, .hidden), (clock, .hidden), (helper, .alwaysHidden)],
            watch: [], concealing: true)
        #expect(reveal.lifts == ["com.vpn"])
        #expect(reveal.sections == [.hidden, .alwaysHidden])
    }

    @Test("under the spacer engine every change reveals its section, as before")
    func updateRevealSpacer() {
        let reveal = MenuBarUtility.updateReveal(changed: [(item("vpn", bundle: "com.vpn"), .hidden)],
                                                 watch: [], concealing: false)
        #expect(reveal.lifts.isEmpty && reveal.sections == [.hidden])
    }

    @Test("once anything is marked, only the marked items interrupt")
    func watchList() {
        let vpn = item("vpn", bundle: "com.vpn")
        let clock = item("clock", bundle: "com.clock")
        let helper = item("helper·x", bundle: nil)
        let reveal = MenuBarUtility.updateReveal(
            changed: [(vpn, .hidden), (clock, .hidden), (helper, .hidden)],
            watch: ["com.vpn", "helper·x"], concealing: true)
        #expect(reveal.lifts == ["com.vpn"])
        #expect(reveal.sections == [.hidden], "the marked helper still reveals")
        let quiet = MenuBarUtility.updateReveal(changed: [(clock, .hidden)],
                                                watch: ["com.vpn"], concealing: true)
        #expect(quiet.lifts.isEmpty && quiet.sections.isEmpty)
    }

    @MainActor
    @Test("marking an item watches its owner, and the mark round-trips through the file")
    func marking() throws {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: true)
        utility.settings = { state }
        utility.onSettingsChange = { draft in state = draft }
        let vpn = item("vpn·a", bundle: "com.vpn")
        #expect(!utility.watchesUpdates(of: vpn))
        utility.setWatchesUpdates(true, for: vpn)
        utility.setWatchesUpdates(true, for: vpn)
        #expect(state.curation.updateWatch == ["com.vpn"])
        #expect(utility.watchesUpdates(of: item("vpn·b", bundle: "com.vpn")), "the app, not the one item")
        let decoded = try JSONDecoder().decode(MenuBarSettings.self, from: JSONEncoder().encode(state))
        #expect(decoded.curation.updateWatch == ["com.vpn"])
        utility.setWatchesUpdates(false, for: vpn)
        #expect(state.curation.updateWatch.isEmpty)
    }
}

/// The tile's press: what counts as the app having got it.
@Suite("Menu Bar — the tile's press")
struct MenuBarPressTests {
    @Test("a press the app answers late while tracking its menu counts as delivered")
    func pressDelivered() {
        #expect(MenuBarAX.delivered(.success))
        #expect(MenuBarAX.delivered(.cannotComplete), "the menu is open — no fallback over it")
        #expect(!MenuBarAX.delivered(.actionUnsupported), "no press offered: try AXShowMenu, then raise")
        #expect(!MenuBarAX.delivered(.invalidUIElement))
        #expect(!MenuBarAX.delivered(.apiDisabled))
    }
}
