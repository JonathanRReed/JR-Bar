import SwiftUI

/// Control identities travel with the rendered view, including conditional rows.
/// A page title or a control left in an unreachable view cannot satisfy a home test.
struct SettingsControlPaths: PreferenceKey {
    static let defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

/// Records every binding for the Settings audit.
struct SettingsControlOccurrences: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func settingControl(_ paths: String...) -> some View { settingControl(paths) }

    func settingControl(_ paths: [String]) -> some View {
        transformPreference(SettingsControlPaths.self) { $0.formUnion(paths) }
            .transformPreference(SettingsControlOccurrences.self) { $0.append(contentsOf: paths) }
            .accessibilityIdentifier("settings:" + paths.joined(separator: ","))
            .modifier(SettingsControlAnchor(paths: paths))
    }
}

private struct SettingsControlAnchor: ViewModifier {
    let paths: [String]
    @Environment(\.studioSearchPath) private var target

    @ViewBuilder func body(content: Content) -> some View {
        if let first = paths.first {
            content.id(first)
                .background(target.map(paths.contains) == true ? Color.accentColor.opacity(0.12) : .clear)
        } else { content }
    }
}
