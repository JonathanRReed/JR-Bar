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
        HStack(spacing: JRBarTokens.Space.md) {
            Button { store.openFeature(toy.id) } label: {
                HStack(spacing: JRBarTokens.Space.md) {
                    SidebarIcon(symbol: toy.symbol, tint: ToyCard.tint(for: toy.id, page: .blue))
                    Text(toy.id == "keepAwake" ? "Keep Awake manually" : toy.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle(toy.switchLabel, isOn: Binding(get: { toy.isOn }, set: { toy.isOn = $0 }))
                .labelsHidden().toggleStyle(.switch)
        }
        .padding(JRBarTokens.Space.md)
    }
}

extension SettingsStore {
    func openFeature(_ id: String) {
        subpage = id
        expandedCards.insert(id)
    }
}
