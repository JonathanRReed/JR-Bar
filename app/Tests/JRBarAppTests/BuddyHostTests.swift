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
        floating.drawsBuddy = true      // the free panel presents
        let onDesktop = sizes()
        #expect(onDesktop.floating.height > 0)
        #expect(onDesktop.docked == .zero)

        // Docking crossfades: the free panel keeps its figure while it
        // fades, the notch pill fades in with its own, and the free one
        // lets go once the fade has played.
        toy.dock()
        let crossing = sizes()
        #expect(crossing.floating.height > 0)
        #expect(crossing.docked.height > 0)
        floating.drawsBuddy = false
        #expect(sizes().floating == .zero)

        // Switched off from the card, the figure fades out with the panel.
        toy.parkFree(at: CGPoint(x: 120, y: 300))
        floating.drawsBuddy = true
        toy.isOn = false
        #expect(sizes().floating.height > 0)
        toy.isOn = true

        // A nap that has finished ducking out is never drawn again by a
        // panel still fading: it went already.
        toy.tuckAway()
        toy.finishTuck()
        let asleep = sizes()
        #expect(asleep.floating == .zero && asleep.docked == .zero)
    }

    /// The panel re-centres on its parked spot at every present, so a
    /// row that came and went with "Caption on hover" moved the pet. The
    /// row keeps its height either way; off, it keeps no width, so the
    /// panel is the pet alone and takes no clicks beside it, however long
    /// the line it would have shown.
    @Test func captionToggleKeepsTheFloatingPanelsHeight() {
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: ToysState(), cardModel: makeTestCardModel())
        let toy = store.notchBuddy
        let floating = BuddyPanelModel()
        floating.toy = toy
        floating.drawsBuddy = true
        toy.isOn = true
        toy.parkFree(at: CGPoint(x: 120, y: 300))
        store.state.notchBuddy.scale = 2
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "long", provider: "claude",
                        label: "a very long session name that fills the caption row right to its edge",
                        mode: "tool_running", lifecycle: "active"),
        ])))
        #expect(toy.caption().count > 60)
        let shown = NSHostingView(rootView: BuddyPanelView(model: floating)).fittingSize
        toy.toggleCaption()
        #expect(toy.showsCaption == false)
        let hidden = NSHostingView(rootView: BuddyPanelView(model: floating)).fittingSize
        #expect(shown.height == hidden.height)
        #expect(shown.height > 0)
        #expect(shown.width >= 150, "on, the row lays out the whole line for the hover")
        #expect(hidden.width <= 36 * 2 + 0.5, "off, the panel is the pet and its padding, no wider")
    }
}
