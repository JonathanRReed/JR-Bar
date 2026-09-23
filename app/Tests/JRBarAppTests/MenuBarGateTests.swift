import AppKit
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// What the utility refuses to offer where it cannot work — Arrange under
/// the concealer, the extra status items macOS does not draw — and the
/// safety gates around them.
@Suite("Menu Bar — gates under the concealer")
struct MenuBarGateTests {
    @MainActor
    private final class NullBackend: MenuBarConcealBackend {
        func activate(allowedBundleIDs: [String]) async throws -> MenuBarAssertionToken {
            MenuBarAssertionToken(NSObject())
        }
        func invalidate(_ token: MenuBarAssertionToken) {}
    }

    @Test("Arrange only exists for the spacer engine")
    func arrangeGate() {
        #expect(MenuBarUtility.arrangeAvailable(concealing: false))
        #expect(!MenuBarUtility.arrangeAvailable(concealing: true))
    }

    @MainActor
    @Test("under the concealer the palette's Arrange row has no order to drive and arrangeNow is a no-op")
    func arrangeNoOpUnderConcealer() async {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: false, arrangeOrder: ["A", "B"])
        utility.settings = { state }
        utility.onSettingsChange = { state = $0 }
        #expect(utility.menuBarArrangeOrder(for: utility.actions) == ["A", "B"])
        utility.concealer = MenuBarConcealer(backend: NullBackend())
        #expect(!utility.arrangeAvailable)
        #expect(utility.menuBarArrangeOrder(for: utility.actions).isEmpty)
        #expect(await utility.actions.arrangeMenuBar() == .alreadyInOrder)
        utility.arrangeNow()
        #expect(!utility.arranging, "no run starts — the cursor never moves")
        utility.concealer = nil
    }
}
