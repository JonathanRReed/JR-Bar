import SwiftUI

/// Control identities travel with the rendered view, including conditional rows.
/// A page title or a control left in an unreachable view cannot satisfy a home test.
struct SettingsControlPaths: PreferenceKey {
    static let defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

extension View {
    func settingControl(_ paths: String...) -> some View { settingControl(paths) }

    func settingControl(_ paths: [String]) -> some View {
        transformPreference(SettingsControlPaths.self) { $0.formUnion(paths) }
            .accessibilityIdentifier("settings:" + paths.joined(separator: ","))
    }
}
