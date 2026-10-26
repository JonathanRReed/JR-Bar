import Carbon
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Studio shortcut", .serialized)
@MainActor
struct StudioShortcutTests {
    @Test func studioShortcutPersistsOffAndRebindWithoutChangingThePanel() {
        let suite = ScratchDefaults.suiteName("studio-shortcut")
        let defaults = ScratchDefaults.open(suite)
        defer { ScratchDefaults.remove(suite) }
        let panelChord = HotkeyChord(keyCode: 38, modifiers: UInt32(controlKey | optionKey))
        HotkeyChordDefaults.set(panelChord, for: PanelHotkey.panelID, defaults: defaults)
        let store = SettingsStore(core: CoreModel(), shortcutDefaults: defaults)
        #expect(store.studioHotkeyEnabled)
        var changes: [Bool] = []
        store.onStudioHotkeyChange = { changes.append($0) }
        store.studioHotkeyEnabled = false
        #expect(!SettingsStore(core: CoreModel(), shortcutDefaults: defaults).studioHotkeyEnabled)
        let rebound = HotkeyChord(keyCode: 37, modifiers: UInt32(controlKey | optionKey))
        store.setShortcut(rebound, for: PanelHotkey.studioID)
        #expect(changes == [false, true])
        let reopened = SettingsStore(core: CoreModel(), shortcutDefaults: defaults)
        #expect(reopened.studioHotkeyChord == rebound)
        #expect(reopened.studioHotkeyEnabled)
        #expect(reopened.panelHotkeyChord == panelChord)
        store.setShortcut(nil, for: PanelHotkey.studioID)
        #expect(SettingsStore(core: CoreModel(), shortcutDefaults: defaults).studioHotkeyChord == nil)
    }

}
