import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Dock utility's ownership: which halves run for which settings,
/// and the card copy that explains a shared chord.
@MainActor
struct DockUtilityTests {
    @Test("the key tap runs for the switcher alone and for the watcher's keys")
    func halves() {
        func halves(_ s: DockSettings) -> [Bool] {
            let h = DockUtility.halves(for: s)
            return [h.watcher, h.tap]
        }
        var s = DockSettings(enabled: true)
        #expect(halves(s) == [true, true])
        s.provider = .dockDoor
        #expect(halves(s) == [false, true],
                "DockDoor draws the previews; our ⌥⇥ keeps its tap")
        s.enhance.windowSwitcher = false
        #expect(halves(s) == [false, false])
        s.provider = .jrbar
        #expect(halves(s) == [true, true],
                "the watcher's preview keys still need the tap")
    }

    @Test("the watcher borrows the utility's switcher rather than owning one")
    func sharedSwitcher() {
        let utility = DockUtility()
        #expect(utility.enhance.switcher === utility.switcher)
    }

    @Test("a running rival names the chord it may share")
    func conflictNote() {
        #expect(DockUtility.conflictNote(running: [], windowChord: true, appChord: false) == nil)
        #expect(DockUtility.conflictNote(running: ["AltTab"], windowChord: true, appChord: false)
                == "AltTab is running and may also take ⌥⇥")
        #expect(DockUtility.conflictNote(running: ["AltTab", "Witch"], windowChord: true, appChord: true)
                == "AltTab and Witch are running and may also take ⌥⇥ or ⌘⇥")
        #expect(DockUtility.conflictNote(running: ["Witch"], windowChord: false, appChord: false) == nil)
    }

    @Test("a counterpart pick for the switcher has a probe; JR-Bar has none")
    func switcherProbes() {
        #expect(DockUtility.probe(for: .jrbar) == nil)
        for provider in DockSwitcherProvider.allCases where provider != .jrbar {
            #expect(DockUtility.probe(for: provider) != nil)
            #expect(!DockUtility.displayName(provider).isEmpty)
        }
    }
}
