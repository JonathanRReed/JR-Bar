import AppKit
import Carbon
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The one registry every JR-Bar shortcut goes through, the chord rules
/// the recorder enforces, and the recorder's key grammar — all over a
/// recording registrar, never real Carbon.
@Suite struct HotkeyCenterTests {
    /// The registrar a test injects: records every call, can refuse.
    final class Recorder: MenuBarHotkeyRegistering {
        var onHotKey: ((UInt32) -> Void)?
        var registered: [(chord: HotkeyChord, id: UInt32)] = []
        var unregistered = 0
        var uninstalled = 0
        /// Chords the "system" refuses, as another app owning them would.
        var taken: Set<HotkeyChord> = []

        func register(keyCode: UInt32, modifiers: UInt32, hotKeyID: UInt32) -> MenuBarHotkeyToken? {
            let chord = HotkeyChord(keyCode: keyCode, modifiers: modifiers)
            if taken.contains(chord) { return nil }
            registered.append((chord, hotKeyID))
            return MenuBarHotkeyToken()
        }
        func unregister(_ token: MenuBarHotkeyToken) { unregistered += 1 }
        func uninstall() { uninstalled += 1 }
    }

    static let controlOption = UInt32(controlKey | optionKey)
    static let chordJ = HotkeyChord(keyCode: UInt32(kVK_ANSI_J), modifiers: controlOption)
    static let chordD = HotkeyChord(keyCode: UInt32(kVK_ANSI_D), modifiers: controlOption)

    // MARK: Chord rules

    @Test func aChordNeedsAModifierThatIsNotShiftAlone() {
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_ANSI_K), modifiers: 0) == .needsModifier)
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(shiftKey)) == .needsModifier)
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_ANSI_K), modifiers: Self.controlOption) == nil)
    }

    @Test func commandAloneIsEveryAppsMenuSpace() {
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey)) == .commandAlone)
        // ⌘⇧K is the shipped command bar: ⌘ with ⇧ is fine.
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey)) == nil)
    }

    @Test func aFunctionKeyStandsAlone() {
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_F13), modifiers: 0) == nil)
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_F5), modifiers: UInt32(shiftKey)) == nil)
    }

    @Test func theSystemsOwnChordsAreNamed() {
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)) == .reserved("Spotlight"))
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)) == .reserved("screenshots"))
        #expect(HotkeyChord.problem(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | cmdKey)) == .reserved("locking the screen"))
    }

    @Test func aChordRoundTripsThroughItsStorageForm() {
        #expect(HotkeyChord(storageString: Self.chordJ.storageString) == Self.chordJ)
        #expect(HotkeyChord(storageString: "banana") == nil)
        #expect(HotkeyChord(storageString: "38") == nil)
        #expect(Self.chordJ.displayString == "⌃⌥J")
    }

    @Test func theDefaultsDistinguishNeverSetFromCleared() throws {
        let suite = "HotkeyCenterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(HotkeyChordDefaults.chord(for: "panel", fallback: Self.chordJ, defaults: defaults) == Self.chordJ)
        HotkeyChordDefaults.set(Self.chordD, for: "panel", defaults: defaults)
        #expect(HotkeyChordDefaults.chord(for: "panel", fallback: Self.chordJ, defaults: defaults) == Self.chordD)
        HotkeyChordDefaults.set(nil, for: "panel", defaults: defaults)
        #expect(HotkeyChordDefaults.chord(for: "panel", fallback: Self.chordJ, defaults: defaults) == nil)
        defaults.set("garbage", forKey: HotkeyChordDefaults.key(for: "panel"))
        #expect(HotkeyChordDefaults.chord(for: "panel", fallback: Self.chordJ, defaults: defaults) == Self.chordJ)
    }

    // MARK: The registry

    @MainActor
    @Test func aPressFiresOnlyItsOwnAction() async throws {
        let recorder = Recorder()
        let center = HotkeyCenter(registrar: recorder)
        var fired: [String] = []
        #expect(center.register("panel", title: "Show the panel", chord: Self.chordJ) { fired.append("panel") } == .registered)
        #expect(center.register("shelf", title: "Open the shelf", chord: Self.chordD) { fired.append("shelf") } == .registered)
        let shelfID = try #require(recorder.registered.first { $0.chord == Self.chordD }?.id)
        recorder.onHotKey?(shelfID)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(fired == ["shelf"])
        #expect(center.status(of: "panel") == .active(Self.chordJ))
    }

    @MainActor
    @Test func aChordAnotherEntryHoldsIsAConflictAndChangesNothing() {
        let recorder = Recorder()
        let center = HotkeyCenter(registrar: recorder)
        center.register("panel", title: "Show the panel", chord: Self.chordJ) {}
        let outcome = center.register("action.quiet", title: "Quiet for an hour", chord: Self.chordJ) {}
        guard case .conflict(let holder) = outcome else {
            Issue.record("expected a conflict, got \(outcome)")
            return
        }
        #expect(holder.id == "panel")
        #expect(recorder.registered.count == 1)
        #expect(center.status(of: "action.quiet") == .conflict(Self.chordJ, holder: "Show the panel"))
        // The holder still works.
        #expect(center.status(of: "panel") == .active(Self.chordJ))
    }

    @MainActor
    @Test func aChordTheSystemRefusesIsKeptAsARefusal() {
        let recorder = Recorder()
        recorder.taken = [Self.chordJ]
        let center = HotkeyCenter(registrar: recorder)
        #expect(center.register("panel", title: "Show the panel", chord: Self.chordJ) {} == .refused)
        #expect(center.status(of: "panel") == .refused(Self.chordJ))
        // A refusal holds nothing: another entry may still ask for it.
        #expect(center.owner(of: Self.chordJ) == nil)
        center.unregister("panel")
        #expect(center.status(of: "panel") == .inactive)
    }

    @MainActor
    @Test func aRebindReplacesTheOldRegistration() {
        let recorder = Recorder()
        let center = HotkeyCenter(registrar: recorder)
        center.register("panel", title: "Show the panel", chord: Self.chordJ) {}
        center.register("panel", title: "Show the panel", chord: Self.chordD) {}
        #expect(recorder.unregistered == 1)
        #expect(center.entries["panel"]?.chord == Self.chordD)
        #expect(center.owner(of: Self.chordJ) == nil)
    }

    @MainActor
    @Test func theHandlerLivesOnlyWhileSomethingIsRegistered() {
        let recorder = Recorder()
        let center = HotkeyCenter(registrar: recorder)
        center.register("panel", title: "Show the panel", chord: Self.chordJ) {}
        center.register("shelf", title: "Open the shelf", chord: Self.chordD) {}
        center.unregister("panel")
        #expect(recorder.uninstalled == 0)
        #expect(recorder.onHotKey != nil)
        center.unregister("shelf")
        #expect(recorder.uninstalled == 1)
        #expect(recorder.onHotKey == nil)
    }

    @MainActor
    @Test func suspendingForARecorderTakesEverythingOutAndPutsItBack() async throws {
        let recorder = Recorder()
        let center = HotkeyCenter(registrar: recorder)
        var fired = 0
        center.register("panel", title: "Show the panel", chord: Self.chordJ) { fired += 1 }
        center.suspend()
        #expect(recorder.unregistered == 1)
        // Still listed — Settings shows the key while it is recorded over.
        #expect(center.entries["panel"]?.chord == Self.chordJ)
        // Registering while suspended parks the entry too.
        #expect(center.register("shelf", title: "Open the shelf", chord: Self.chordD) {} == .registered)
        #expect(recorder.registered.count == 1)
        center.resume()
        #expect(recorder.registered.count == 3)
        let panelID = try #require(recorder.registered.last { $0.chord == Self.chordJ }?.id)
        recorder.onHotKey?(panelID)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(fired == 1)
    }

    @MainActor
    @Test func aKeyTakenWhileSuspendedBecomesARefusalOnResume() {
        let recorder = Recorder()
        let center = HotkeyCenter(registrar: recorder)
        center.register("panel", title: "Show the panel", chord: Self.chordJ) {}
        center.suspend()
        recorder.taken = [Self.chordJ]
        center.resume()
        #expect(center.status(of: "panel") == .refused(Self.chordJ))
        #expect(center.entries["panel"] == nil)
    }

    // MARK: The panel and menu-bar keys over one registry

    @MainActor
    @Test func thePanelKeyReadsItsChordAtRegistration() {
        let center = HotkeyCenter(registrar: Recorder())
        let panel = PanelHotkey(id: PanelHotkey.panelID, title: "Show the panel",
                                defaultChord: PanelHotkey.panelDefault, center: center)
        // A mutable answer the @Sendable source can read.
        final class Stored: @unchecked Sendable { var chord: HotkeyChord? = HotkeyCenterTests.chordD }
        let stored = Stored()
        panel.chordSource = { stored.chord }
        panel.setEnabled(true)
        #expect(center.entries[PanelHotkey.panelID]?.chord == Self.chordD)
        // Cleared on Settings › Shortcuts: on, but holding no key.
        stored.chord = nil
        panel.setEnabled(true)
        #expect(center.status(of: PanelHotkey.panelID) == .inactive)
        #expect(!panel.registrationFailed)
    }

    @MainActor
    @Test func theCompatibilityInitMapsTheOldSignaturesToRegistryIDs() {
        let panel = PanelHotkey()
        let shelf = PanelHotkey(signature: OSType(0x6A726273), keyCode: UInt32(kVK_ANSI_D))
        #expect(panel.id == PanelHotkey.panelID)
        #expect(panel.defaultChord == PanelHotkey.panelDefault)
        #expect(shelf.id == PanelHotkey.shelfID)
        #expect(shelf.defaultChord == PanelHotkey.shelfDefault)
    }

    @MainActor
    @Test func aMenuBarKeyOnThePanelsChordNamesThePanel() {
        let center = HotkeyCenter(registrar: Recorder())
        center.register(PanelHotkey.panelID, title: "Show the panel", chord: Self.chordJ) {}
        let hotkeys = MenuBarHotkeys(bindings: [
            MenuBarHotkeyBinding(action: .commandBar, keyCode: Self.chordJ.keyCode,
                                 modifiers: Self.chordJ.modifiers, enabled: true),
        ])
        hotkeys.center = center
        hotkeys.start()
        #expect(hotkeys.failedActions == [.commandBar])
        #expect(hotkeys.conflictOwners[.commandBar] == "Show the panel")
        hotkeys.stop()
        #expect(center.status(of: MenuBarHotkeys.registryID(for: .commandBar)) == .inactive)
        #expect(center.status(of: PanelHotkey.panelID) == .active(Self.chordJ))
    }

    // MARK: The recorder's grammar

    @Test func escCancelsAndDeleteClearsOnlyWhenBare() {
        #expect(ShortcutRecorderLogic.step(keyCode: UInt16(kVK_Escape), flags: []) == .cancel)
        #expect(ShortcutRecorderLogic.step(keyCode: UInt16(kVK_Delete), flags: []) == .clear)
        #expect(ShortcutRecorderLogic.step(keyCode: UInt16(kVK_ForwardDelete), flags: [.capsLock]) == .clear)
        // With modifiers they are chords like any other.
        let chord = HotkeyChord(keyCode: UInt32(kVK_Delete), modifiers: Self.controlOption)
        #expect(ShortcutRecorderLogic.step(keyCode: UInt16(kVK_Delete), flags: [.control, .option]) == .record(chord))
    }

    @Test func aChordIsRecordedWithoutTheIncidentalFlags() {
        let step = ShortcutRecorderLogic.step(keyCode: UInt16(kVK_ANSI_J),
                                              flags: [.control, .option, .capsLock, .function, .numericPad])
        #expect(step == .record(Self.chordJ))
    }

    @Test func anInvalidChordKeepsListeningAndSaysWhy() {
        let bare = HotkeyChord(keyCode: UInt32(kVK_ANSI_K), modifiers: 0)
        #expect(ShortcutRecorderLogic.step(keyCode: UInt16(kVK_ANSI_K), flags: []) == .invalid(bare, .needsModifier))
    }

    @Test func heldModifiersDrawInMenuOrder() {
        #expect(ShortcutRecorderLogic.heldGlyphs([.command, .control, .shift]) == "⌃⇧⌘")
        #expect(ShortcutRecorderLogic.heldGlyphs([.capsLock]) == "")
    }
}
