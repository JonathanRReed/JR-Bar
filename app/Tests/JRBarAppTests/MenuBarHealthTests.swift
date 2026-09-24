import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp
import JRBarCore

/// Which engine hides the bar and whether it is healthy, the rival
/// managers that fight ours, and the spacer engine's diagnostics.
@Suite("Menu Bar — engine health and rivals")
struct MenuBarHealthTests {
    private func inputs(running: Bool = true, framework: Bool = true, forced: Bool = false,
                        notarized: Bool? = true, unnotarizedOK: Bool = false,
                        engineUp: Bool = false, live: Bool = false, failing: Bool = false,
                        grace: Bool = false, concealed: Int = 0) -> MenuBarEngineHealth.Inputs {
        .init(running: running, frameworkAvailable: framework, forced: forced,
              notarized: notarized, concealUnnotarized: unnotarizedOK, engineUp: engineUp,
              assertionLive: live, activationFailing: failing, inStartGrace: grace,
              concealedCount: concealed)
    }

    @Test("the concealer's states: live with a count, starting, failing, nothing to hide")
    func concealerStates() {
        #expect(MenuBarEngineHealth.assess(inputs(engineUp: true, live: true, concealed: 6))
                == .concealer(hidden: 6))
        #expect(MenuBarEngineHealth.assess(inputs(engineUp: true, grace: true, concealed: 3))
                == .concealerStarting)
        #expect(MenuBarEngineHealth.assess(inputs(engineUp: true, failing: true, concealed: 3))
                == .concealerFailing)
        #expect(MenuBarEngineHealth.assess(inputs(engineUp: true, live: true, failing: true,
                                                  concealed: 2)) == .concealer(hidden: 2),
                "a failed swap leaves the old assertion concealing — not an alert")
        #expect(MenuBarEngineHealth.assess(inputs(engineUp: true)) == .concealer(hidden: 0))
        #expect(MenuBarEngineHealth.assess(inputs(running: false, engineUp: true)) == .parked)
    }

    @Test("the spacer engine says why it stands in")
    func spacerReasons() {
        #expect(MenuBarEngineHealth.assess(inputs(framework: false)) == .spacer(.frameworkMissing))
        #expect(MenuBarEngineHealth.assess(inputs(forced: true)) == .spacer(.forced))
        #expect(MenuBarEngineHealth.assess(inputs(notarized: false)) == .spacer(.notNotarized))
        #expect(MenuBarEngineHealth.assess(inputs(notarized: false, unnotarizedOK: true))
                == .spacer(.pending))
        #expect(MenuBarEngineHealth.assess(inputs(notarized: nil)) == .spacer(.pending))
    }

    @Test("the lines read plainly, the spacer's with its edge, and only failure is an alert")
    func lines() {
        #expect(MenuBarEngineHealth.concealer(hidden: 1).line() == "macOS concealer · 1 app hidden")
        #expect(MenuBarEngineHealth.concealer(hidden: 6).line() == "macOS concealer · 6 apps hidden")
        #expect(MenuBarEngineHealth.concealer(hidden: 0).line() == "macOS concealer · nothing hidden")
        #expect(MenuBarEngineHealth.spacer(.frameworkMissing).line(fitEdge: 901.6)
                == "Spacer engine · macOS's concealer isn't available on this system · edge at 902 pt")
        #expect(MenuBarEngineHealth.spacer(.forced).line() == "Spacer engine · forced in Advanced")
        #expect(MenuBarEngineHealth.concealerFailing.isAlert)
        #expect(!MenuBarEngineHealth.concealer(hidden: 3).isAlert)
        #expect(!MenuBarEngineHealth.spacer(.notNotarized).isAlert)
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

    @Test("forcing the spacer engine persists; older files read as not forced")
    func forcedPersists() throws {
        var settings = MenuBarSettings()
        #expect(!settings.curation.forceSpacerEngine)
        settings.curation.forceSpacerEngine = true
        let back = try JSONDecoder().decode(MenuBarSettings.self,
                                            from: JSONEncoder().encode(settings))
        #expect(back.curation.forceSpacerEngine)
        let old = try JSONDecoder().decode(MenuBarCuration.self, from: Data("{}".utf8))
        #expect(!old.forceSpacerEngine)
    }
}
