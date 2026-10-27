import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// Whether the divider is hiding the bar, the rival managers that fight
/// ours, and the divider's diagnostics.
@Suite("Menu Bar — engine health and rivals")
struct MenuBarHealthTests {
    @Test("the engine is the divider while the utility runs, parked otherwise")
    func states() {
        #expect(MenuBarEngineHealth.assess(running: true) == .divider)
        #expect(MenuBarEngineHealth.assess(running: false) == .parked)
    }

    @Test("the lines read plainly, the divider's with its edge")
    func lines() {
        #expect(MenuBarEngineHealth.parked.line() == "Not hiding anything: the switch is off or another app draws the menu bar")
        #expect(MenuBarEngineHealth.divider.line()
                == "Divider · the icon is the divider, position is the setting")
        #expect(MenuBarEngineHealth.divider.line(fitEdge: 901.6)
                == "Divider · the icon is the divider, position is the setting · edge at 902 pt")
    }

    @Test("rivals match by bundle id, or by name where the id is not pinned — each once")
    func rivals() {
        let apps: [(bundleID: String?, name: String?)] = [
            ("com.jordanbaird.Ice", "Ice"),
            ("com.jordanbaird.Ice", "Ice"),
            (nil, "SaneBar"),
            ("com.example.tuck", "tuck"),
            ("com.apple.finder", "Finder"),
        ]
        let found = MenuBarRivals.running(in: apps)
        #expect(found.map(\.name) == ["Ice", "Tuck", "SaneBar"])
        #expect(found.first?.handoff == .ice)
        #expect(MenuBarRivals.running(in: [("com.surteesstudios.Bartender-5", "Bartender 5")])
            .first?.handoff == .bartender)
        #expect(MenuBarRivals.running(in: [("com.apple.Safari", "Safari")]).isEmpty)
    }

    @MainActor
    @Test("Hand over finds every rival release the rival check knows, newest first")
    func handoverProbesFollowTheRivals() {
        #expect(ExternalProviders.bartender.bundleIDs == [
            "com.surteesstudios.Bartender-7", "com.surteesstudios.Bartender-6",
            "com.surteesstudios.Bartender-5", "com.surteesstudios.Bartender-4",
            "com.surteesstudios.Bartender",
        ])
        for (probe, name) in [(ExternalProviders.bartender, "Bartender"), (ExternalProviders.ice, "Ice"),
                              (ExternalProviders.hiddenBar, "Hidden Bar")] {
            let rival = MenuBarRivals.known.first { $0.name == name }
            #expect(Set(probe.bundleIDs) == rival?.bundleIDs, "\(name)")
            #expect(!probe.bundleIDs.isEmpty, "\(name)")
        }
        #expect(MenuBarRivals.bundleIDs(of: "Nobody").isEmpty)
    }

    @MainActor
    @Test("the fit-edge dial nudges the learned edge and the reset forgets it")
    func fitEdgeDial() {
        let hider = MenuBarItemHider()
        let store = MenuBarMemoryFitEdgeStore()
        hider.edgeStore = store
        hider.edgeKey = { "screen" }
        hider.guessedFitEdge = { 900 }
        hider.listItems = { [] }
        #expect(hider.fitEdge == 900)
        #expect(!hider.fitEdgeLearned)
        hider.nudgeFitEdge(by: 4)
        #expect(hider.fitEdge == 904)
        #expect(hider.fitEdgeLearned)
        #expect(store.edges["screen"] == 904)
        hider.nudgeFitEdge(by: -8)
        #expect(hider.fitEdge == 896)
        hider.forgetFitEdge()
        #expect(hider.fitEdge == 900)
        #expect(store.edges["screen"] == nil)
    }
}
