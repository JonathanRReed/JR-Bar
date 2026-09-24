import AppKit
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Buddy host ownership")
@MainActor
struct BuddyHostTests {
    @Test func onlyTheCurrentHomeBuildsTheBuddy() {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: ToysState(), cardModel: makeTestCardModel())
        let toy = store.notchBuddy
        let floating = BuddyPanelModel()
        floating.toy = toy
        let docked = NotchHUDModel()
        docked.buddy = toy

        func sizes() -> (floating: NSSize, docked: NSSize) {
            let freeHost = NSHostingView(rootView: BuddyPanelView(model: floating))
            let dockHost = NSHostingView(rootView: NotchHUDView(model: docked))
            return (freeHost.fittingSize, dockHost.fittingSize)
        }

        toy.isOn = true
        let atNotch = sizes()
        #expect(atNotch.floating == .zero)
        #expect(atNotch.docked.height > 0)

        toy.parkFree(at: CGPoint(x: 120, y: 300))
        let onDesktop = sizes()
        #expect(onDesktop.floating.height > 0)
        #expect(onDesktop.docked == .zero)

        toy.dock()
        #expect(sizes().floating == .zero)
        toy.tuckAway()
        toy.finishTuck()
        let asleep = sizes()
        #expect(asleep.floating == .zero && asleep.docked == .zero)
    }
}
