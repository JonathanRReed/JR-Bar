import ApplicationServices
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The "show for updates" pass: a changed hidden item reveals its section,
/// and once anything is marked only the items you mark interrupt.
@Suite("Menu Bar — show for updates")
struct MenuBarLiftTests {
    private func item(_ id: String, bundle: String?) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 1, ownerName: id,
                    bounds: CGRect(x: 0, y: 0, width: 24, height: 24),
                    title: nil, windowID: 1, bundleID: bundle)
    }

    @Test("every change reveals its section")
    func updateRevealSections() {
        let reveal = MenuBarUtility.updateReveal(
            changed: [(item("vpn", bundle: "com.vpn"), .hidden), (item("helper", bundle: nil), .alwaysHidden)],
            watch: [])
        #expect(reveal == [.hidden, .alwaysHidden])
    }

    @Test("once anything is marked, only the marked items interrupt")
    func watchList() {
        let vpn = item("vpn", bundle: "com.vpn")
        let clock = item("clock", bundle: "com.clock")
        let helper = item("helper·x", bundle: nil)
        let reveal = MenuBarUtility.updateReveal(
            changed: [(vpn, .hidden), (clock, .alwaysHidden), (helper, .hidden)],
            watch: ["com.vpn", "helper·x"])
        #expect(reveal == [.hidden], "the marked VPN and helper reveal; the clock does not")
        let quiet = MenuBarUtility.updateReveal(changed: [(clock, .hidden)], watch: ["com.vpn"])
        #expect(quiet.isEmpty)
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
