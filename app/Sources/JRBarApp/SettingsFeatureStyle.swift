import JRBarCore
import JRBarUI
import SwiftUI

struct SettingsFeatureHeadingValue: Equatable {
    let title: String
    let purpose: String
    let status: String
}

struct SettingsFeatureHeadings: PreferenceKey {
    static let defaultValue: [SettingsFeatureHeadingValue] = []
    static func reduce(value: inout [SettingsFeatureHeadingValue], nextValue: () -> [SettingsFeatureHeadingValue]) {
        value.append(contentsOf: nextValue())
    }
}

struct SettingsFeatureHeading<Control: View>: View {
    let title: String
    let symbol: String
    let purpose: String
    let status: String
    var tint: Color = JRBarTokens.Ink.accent
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: JRBarTokens.Space.md) {
            SettingsIconTile(symbol: symbol, tint: tint, size: SettingsMetrics.headerTile)
            VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
                Text(title).jrbarType(.title3).fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                Text(purpose).jrbarType(.callout).foregroundStyle(.secondary)
                Text(status).jrbarType(.callout).foregroundStyle(.secondary)
                    .accessibilityLabel("\(title): \(status)")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, JRBarTokens.Space.xs)
        .preference(
            key: SettingsFeatureHeadings.self,
            value: [SettingsFeatureHeadingValue(title: title, purpose: purpose, status: status)])
    }
}

extension SettingsFeatureHeading where Control == EmptyView {
    init(title: String, symbol: String, purpose: String, status: String, tint: Color = JRBarTokens.Ink.accent) {
        self.init(title: title, symbol: symbol, purpose: purpose, status: status, tint: tint) { EmptyView() }
    }
}

/// Search opens the same disclosure the person can open by hand.
enum SettingsFeatureOptions {
    static func fold(_ id: String) -> String { "feature:\(id):more" }
    static func agentProvider(_ id: String) -> String { "feature:agents:provider:\(id)" }

    static let titles: [String: Set<String>] = [
        "dock": [
            "Render with", "Fine switcher spacing", "Live card under the pointer",
            "Cards take each window's shape", "Capture every window", "List past N windows",
            "Only windows on this display", "Scroll on an icon", "Click the front app's icon to minimize",
            "⌥` previews the front app", "Hold the Dock out", "Distance from the Dock",
            "Cover the Dock's name label", "Switcher spacing", "⌥⇥ lists this display only",
            "Window order", "Apps with no windows", "Card faces", "Remembered picks",
        ],
        "keepAwake": ["Durations", "Custom duration", "Other apps holding this Mac awake"],
        "fold": [
            "Release when parked", "Jitter", "Perspective", "Shade", "Blur", "Frost",
            "Goes dark over", "Hold picture in place", "Click on return", "Hinge voice",
            "Simulate a fold", "Render with", "Wallpaper without Screen Recording",
        ],
        "notch-buddy": ["Mini", "Wear the Screen Bar's colour", "Caption on hover", "Take walks", "Time between walks"],
    ]

    static func contains(_ entry: SettingsSearchEntry) -> Bool {
        guard let id = entry.card else { return entry.group == "Seasonal touches" && entry.title != "Seasonal touches" }
        if id == "menuBar" {
            return ![
                "Menu Bar", "Hover the blank stretch", "Click the blank stretch", "Scroll over the bar",
                "Click and scroll delay", "Show after hovering", "Hide after leaving", "Tuck away",
                "Reveal style", "Hide shown items while revealing", "Hidden items as tiles", "Item Bar opens at",
            ].contains(entry.title)
        }
        if id == "notch" {
            return !["Notch", "Render with", "Show the island", "Card on hover", "Open after", "Display", "Shelf", "Shelf hotkey"].contains(
                entry.title)
        }
        return titles[id]?.contains(entry.title) == true
    }
}

struct SettingsFeatureMoreOptions<Content: View>: View {
    let id: String
    let subtitle: String
    var initiallyExpanded = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        SettingsGroup {
            DisclosureRow(
                "More options", subtitle: subtitle, fold: SettingsFeatureOptions.fold(id),
                initiallyExpanded: initiallyExpanded
            ) {
                VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) { content() }
                    .padding(.top, JRBarTokens.Space.md)
            }
        }
    }
}

struct SettingsMoreOptionsLabel: View {
    let subtitle: String
    var body: some View { SettingLabel(title: "More options", subtitle: subtitle) }
}
