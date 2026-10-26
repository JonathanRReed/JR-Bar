import JRBarUI
import SwiftUI

struct UtilitiesPage: View {
    let store: SettingsStore
    var body: some View {
        SettingGroup("Utilities") {
            if let utilities = store.utilities {
                SettingsFeatureRow(store: store, toy: utilities.menuBar)
                SettingsFeatureRow(store: store, toy: utilities.dock)
                SettingsFeatureRow(store: store, toy: KeepAwakeUtility.shared)
                SettingsFeatureRow(store: store, toy: utilities.agents)
            }
        }
    }
}

struct SettingsFeatureRow: View {
    let store: SettingsStore
    let toy: any Toy
    var body: some View {
        let title = toy.id == "keepAwake" ? "Keep Awake manually" : toy.name
        SettingsRow(title) {
            Toggle(title, isOn: Binding(get: { toy.isOn }, set: { toy.isOn = $0 }))
                .labelsHidden().toggleStyle(.switch)
            Button { store.subpage = toy.id; store.expandedCards.insert(toy.id) } label: {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(toy.name) settings")
        }
    }
}
