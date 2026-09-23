import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Monitor-setup profiles: a desk is the set of displays attached at
/// once, and the bar takes its profile once, when that set arrives.
@Suite("Menu Bar — profiles per desk")
struct MenuBarDeskTests {
    private let laptop = MenuBarDesk.Display(builtin: true, vendor: 1552, model: 41_234, serial: 0,
                                             name: "Built-in Retina Display")
    private let studio = MenuBarDesk.Display(builtin: false, vendor: 1552, model: 44_033, serial: 12_345,
                                             name: "Studio Display")
    private let dell = MenuBarDesk.Display(builtin: false, vendor: 4268, model: 16_880, serial: 0,
                                           name: "DELL U2723QE")

    @Test("a desk is its displays, in any order; the lid shutting makes a different desk")
    func keys() {
        let docked = MenuBarDesk.key([laptop, studio])
        #expect(docked == MenuBarDesk.key([studio, laptop]))
        #expect(docked == "1552-44033-12345+builtin")
        #expect(MenuBarDesk.key([studio]) != docked, "clamshell drops the built-in")
        #expect(MenuBarDesk.key([dell, dell]) == "4268-16880-0+4268-16880-0",
                "two identical monitors without serials are still two")
        #expect(MenuBarDesk.key([]) == nil)
    }

    @Test("a desk is named built-in first, then the externals, and says when the lid is shut")
    func names() {
        #expect(MenuBarDesk.name([studio, laptop], lidClosed: false)
                == "Built-in Retina Display + Studio Display")
        #expect(MenuBarDesk.name([studio, dell], lidClosed: true)
                == "DELL U2723QE + Studio Display · lid closed")
        #expect(MenuBarDesk.name([laptop], lidClosed: true) == "Built-in Retina Display",
                "a lid read as shut with the built-in still listed is not clamshell")
    }

    @Test("only a change of desk applies its profile — the same desk again applies nothing")
    func arrivals() {
        let desks = [MenuBarDeskProfile(key: "desk", name: "Desk", profileID: "work")]
        #expect(MenuBarDesk.profileToApply(previousKey: "laptop", currentKey: "desk", desks: desks) == "work")
        #expect(MenuBarDesk.profileToApply(previousKey: nil, currentKey: "desk", desks: desks) == "work")
        #expect(MenuBarDesk.profileToApply(previousKey: "desk", currentKey: "desk", desks: desks) == nil)
        #expect(MenuBarDesk.profileToApply(previousKey: "desk", currentKey: "laptop", desks: desks) == nil)
    }

    @Test("mapping a desk keeps its place, renames it, and an empty pick forgets it")
    func setting() {
        var desks = MenuBarDesk.setting("work", forKey: "a", name: "A", in: [])
        desks = MenuBarDesk.setting("home", forKey: "b", name: "B", in: desks)
        desks = MenuBarDesk.setting("play", forKey: "a", name: "A2", in: desks)
        #expect(desks.map(\.key) == ["a", "b"])
        #expect(desks[0].profileID == "play" && desks[0].name == "A2")
        #expect(MenuBarDesk.setting("", forKey: "a", name: "A", in: desks).map(\.key) == ["b"])
    }

    @Test("the desks round-trip, and a file from before them reads as none")
    func codable() throws {
        let curation = MenuBarCuration(deskProfiles: [MenuBarDeskProfile(key: "k", name: "Desk", profileID: "p")],
                                       lastDeskKey: "k")
        let data = try JSONEncoder().encode(curation)
        #expect(try JSONDecoder().decode(MenuBarCuration.self, from: data) == curation)
        let old = try JSONDecoder().decode(MenuBarCuration.self, from: Data(#"{"profileModel":1}"#.utf8))
        #expect(old.deskProfiles.isEmpty && old.lastDeskKey == nil)
    }

    @MainActor
    @Test("the utility takes a desk's profile on arrival, once, and a hand pick holds until the desk changes")
    func utilityArrivals() {
        let utility = MenuBarUtility()
        var state = MenuBarSettings(enabled: true, profiles: [
            MenuBarSettings.Profile(id: "work", name: "Work", sections: ["X": .hidden]),
            MenuBarSettings.Profile(id: "home", name: "Home"),
        ])
        state.curation.deskProfiles = [MenuBarDeskProfile(key: MenuBarDesk.key([laptop, studio])!,
                                                          name: "old name", profileID: "work")]
        utility.settings = { state }
        utility.onSettingsChange = { draft in state = draft }

        utility.noteDesk([laptop], lidClosed: false)
        #expect(state.curation.lastDeskKey == "builtin")
        #expect(state.curation.activeProfileID == nil, "an unmapped desk changes nothing")

        utility.noteDesk([laptop, studio], lidClosed: false)
        #expect(state.curation.activeProfileID == "work")
        #expect(state.curation.deskProfiles[0].name == "Built-in Retina Display + Studio Display")

        // A hand pick at the same desk holds through another read of it.
        utility.applyProfile(id: "home")
        utility.noteDesk([studio, laptop], lidClosed: false)
        #expect(state.curation.activeProfileID == "home")

        // Mapping the desk you are at takes the pick now.
        utility.noteDesk([studio], lidClosed: true)
        utility.setProfileForCurrentDesk("home")
        #expect(state.curation.deskProfiles.map(\.profileID) == ["work", "home"])
        #expect(state.curation.deskProfiles[1].name == "Studio Display · lid closed")

        // A deleted profile's desks forget it; arriving there changes nothing.
        utility.deleteProfile(id: "work")
        #expect(state.curation.deskProfiles.map(\.profileID) == ["home"])
    }
}
