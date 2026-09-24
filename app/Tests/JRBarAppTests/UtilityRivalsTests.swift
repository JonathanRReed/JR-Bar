import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The rivals table every utility card reads: a running app is matched
/// by bundle id, or by name where no id is pinned; each rival is named
/// once however many of its processes run; and a role only ever lists
/// the rivals that do that job.
@Suite("Utility rivals")
struct UtilityRivalsTests {
    @Test("a rival is found by its bundle id")
    func matchesByBundleID() {
        let found = UtilityRivals.running(for: .shelfGesture,
                                          in: [("me.damir.dropover-mac", "Dropover"), ("com.apple.Safari", "Safari")])
        #expect(found.map(\.name) == ["Dropover"])
    }

    @Test("a rival without a pinned id is found by its name, in any case")
    func matchesByName() {
        #expect(UtilityRivals.running(for: .notch, in: [(nil, "notchnook")]).map(\.name) == ["NotchNook"])
        #expect(UtilityRivals.running(for: .shelfGesture, in: [("io.example.side-load", "Dropzone 4")])
            .map(\.name) == ["Dropzone"])
        #expect(UtilityRivals.running(for: .notch, in: [("com.apple.Safari", "Safari")]).isEmpty)
    }

    @Test("roles only list the rivals that do that job")
    func filtersByRole() {
        let apps: [(bundleID: String?, name: String?)] = [
            ("me.damir.dropover-mac", "Dropover"),
            ("com.if.Amphetamine", "Amphetamine"),
            ("com.ethanbills.DockDoor", "DockDoor"),
            ("theboringteam.boringnotch", "boringNotch"),
        ]
        #expect(UtilityRivals.running(for: .shelfGesture, in: apps).map(\.name) == ["Dropover"])
        #expect(UtilityRivals.running(for: .keepAwake, in: apps).map(\.name) == ["Amphetamine"])
        #expect(UtilityRivals.running(for: .dockPreviews, in: apps).map(\.name) == ["DockDoor"])
        #expect(UtilityRivals.running(for: .switcher, in: apps).map(\.name) == ["DockDoor"])
        #expect(UtilityRivals.running(for: .notch, in: apps).map(\.name) == ["Boring Notch"])
        #expect(UtilityRivals.running(for: .hud, in: apps).map(\.name) == ["Boring Notch"])
        #expect(UtilityRivals.running(for: .menuBar, in: apps).isEmpty)
    }

    @Test("a rival running as two processes is listed once")
    func eachRivalOnce() {
        let apps: [(bundleID: String?, name: String?)] = [
            ("com.ethanbills.DockDoor", "DockDoor"),
            ("com.ejbills.DockDoor", "DockDoor"),
            (nil, "DockDoor"),
        ]
        #expect(UtilityRivals.running(for: .dockPreviews, in: apps).count == 1)
    }

    @Test("the table names each rival once, and every role has one")
    func tableIsClean() {
        let names = UtilityRivals.known.map(\.name)
        #expect(Set(names).count == names.count)
        for role in UtilityRivals.Role.allCases {
            #expect(UtilityRivals.known.contains { $0.roles.contains(role) }, "no rival for \(role)")
        }
    }

    @Test("the menu bar role reads the menu bar's own list")
    func menuBarRoleFollowsMenuBarRivals() {
        let found = UtilityRivals.running(for: .menuBar, in: [("com.surteesstudios.Bartender-5", "Bartender 5")])
        #expect(found.map(\.name) == ["Bartender"])
        #expect(found.first?.handoff(for: .menuBar) == .menuBar(.bartender))
        #expect(Set(UtilityRivals.known.filter { $0.roles.contains(.menuBar) }.map(\.name))
                == Set(MenuBarRivals.known.map(\.name)))
    }

    @Test("hand-overs point at the pickers that can take the surface")
    func handoffs() {
        let dockDoor = UtilityRivals.known.first { $0.name == "DockDoor" }
        #expect(dockDoor?.handoff(for: .dockPreviews) == .dock(.dockDoor))
        #expect(dockDoor?.handoff(for: .switcher) == .switcher(.dockDoor))
        let alcove = UtilityRivals.known.first { $0.name == "Alcove" }
        #expect(alcove?.handoff(for: .notch) == .notch(.alcove))
        #expect(UtilityRivals.known.first { $0.name == "Dropover" }?.handoff(for: .shelfGesture) == nil)
    }

    @Test("each role behaves as the coexistence rule says")
    func policies() {
        #expect(UtilityRivals.Role.dockPreviews.policy == .ask)
        #expect(UtilityRivals.Role.notch.policy == .ask)
        #expect(UtilityRivals.Role.shelfGesture.policy == .stepAside)
        #expect(UtilityRivals.Role.keepAwake.policy == .informOnly)
        let dropover = UtilityRivals.known.first { $0.name == "Dropover" }!
        #expect(UtilityRivals.note(for: dropover, role: .shelfGesture).contains("steps aside"))
    }
}
