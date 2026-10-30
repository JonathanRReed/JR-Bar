import JRBarCore
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

    /// A failed status ("Couldn't hold the Mac awake") reads red, as it
    /// does on the card; every other status keeps the quiet amber.
    static func chipTint(_ status: ToyStatus) -> Color {
        if case .failed = status { return Tone.failure.color }
        return Tone.neutral.color
    }

    var body: some View {
        HStack(spacing: JRBarTokens.Space.md) {
            Button { store.openFeature(toy.id) } label: {
                HStack(spacing: JRBarTokens.Space.md) {
                    VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                        HStack(spacing: JRBarTokens.Space.sm) {
                            Text(toy.name)
                                .lineLimit(1).layoutPriority(1)
                            if toy.status.showsChip && (store.isLive || toy.status.text != MonitorWords.label) {
                                Text(toy.status.text).foregroundStyle(Self.chipTint(toy.status)).jrbarType(.caption)
                                    .lineLimit(1).help(toy.status.text)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .settingsRowInsets()
    }
}

extension SettingsStore {
    func openFeature(_ id: String) {
        subpage = id
        expandedCards.insert(id)
    }
}
