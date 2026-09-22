import JRBarCore
import SwiftUI

// MARK: - Shortcuts

/// Every global shortcut JR-Bar holds, on one page, each with a real
/// recorder: the panel and shelf summons, the Menu Bar utility's keys,
/// and the app actions any key can be bound to. The rows read the one
/// `HotkeyCenter`, so a key another app owns or another row already
/// holds is named where it happened — Raycast's Shortcuts tab, for the
/// things JR-Bar does.
struct ShortcutsPage: View {
    @Bindable var store: SettingsStore
    var center: HotkeyCenter = .shared

    var body: some View {
        SettingGroup("JR-Bar", note: "These work in every app. Click a shortcut, then press the new keys — Esc cancels, Delete clears it.") {
            ShortcutRow(title: "Show the panel", id: PanelHotkey.panelID,
                        chord: store.panelHotkeyChord, isOn: $store.panelHotkeyEnabled,
                        center: center,
                        onChange: { store.setShortcut($0, for: PanelHotkey.panelID) },
                        onTakeOver: { store.setShortcut(nil, for: $0) })
            ShortcutRow(title: "Open the shelf", subtitle: "Folds it again on a second press.",
                        id: PanelHotkey.shelfID,
                        chord: store.shelfHotkeyChord, isOn: $store.shelfHotkeyEnabled,
                        center: center,
                        onChange: { store.setShortcut($0, for: PanelHotkey.shelfID) },
                        onTakeOver: { store.setShortcut(nil, for: $0) })
        }

        if let menuBar = store.utilities?.menuBar {
            SettingGroup("Menu bar", note: menuBar.isOn
                         ? "Held while the Menu Bar utility runs."
                         : "The Menu Bar utility is off, so these keys are not held. Turn it on in Utilities.") {
                ForEach(menuBar.resolvedHotkeyBindings(), id: \.action) { binding in
                    ShortcutRow(title: MenuBarHotkeys.title(for: binding.action),
                                id: MenuBarHotkeys.registryID(for: binding.action),
                                chord: HotkeyChord(binding),
                                isOn: Binding(get: { binding.enabled },
                                              set: { menuBar.setHotkeyEnabled($0, for: binding.action) }),
                                center: center,
                                onChange: { menuBar.setHotkeyChord($0, for: binding.action) },
                                onTakeOver: { store.setShortcut(nil, for: $0) })
                }
            }
        }
    }
}
