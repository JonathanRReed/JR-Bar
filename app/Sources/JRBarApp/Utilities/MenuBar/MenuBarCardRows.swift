import AppKit
import JRBarCore
import SwiftUI

/// "Item Bar opens at": under the icon's ‹, or under the pointer.
struct MenuBarItemBarAnchorRow: View {
    let utility: MenuBarUtility

    var body: some View {
        LabeledContent {
            Picker(selection: utility.bind(\.curation.itemBarAt)) {
                Text("The icon").tag(MenuBarItemBarAnchor.icon)
                Text("The pointer").tag(MenuBarItemBarAnchor.pointer)
            } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
        } label: {
            SettingLabel(title: "Item Bar opens at",
                         subtitle: "Under the icon, or wherever the pointer is.")
        }
    }
}

/// "Relaunch menu bar apps": items take a new spacing only as their
/// apps relaunch. A confirm lists every app it will quit and reopen;
/// nothing runs on its own, and Apple's agents are never touched.
struct MenuBarSpacingRelaunchRow: View {
    let utility: MenuBarUtility
    @ViewState private var confirming = false

    var body: some View {
        let apps = utility.spacingRelaunchApps
        let names = apps.map(\.name).joined(separator: ", ")
        LabeledContent {
            Button(utility.relaunchingApps.isEmpty ? "Relaunch…" : "Relaunching…") { confirming = true }
                .controlSize(.small)
                .fixedSize()
                .disabled(apps.isEmpty || !utility.relaunchingApps.isEmpty || utility.spacingError != nil)
        } label: {
            SettingLabel(title: "Relaunch menu bar apps",
                         subtitle: "Items take a new spacing as their apps relaunch. This quits and reopens the apps with items on your bar, never Apple's own.")
        }
        .confirmationDialog("Relaunch \(apps.count) menu bar apps?", isPresented: WindowPresenter.presentation($confirming)) {
            Button("Relaunch") { utility.relaunchForSpacing(apps.map(\.bundleID)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("JR-Bar asks each to quit and opens it again in the background: \(names).")
        }
    }
}

struct MenuBarSpacingFailureRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.s) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SettingsMetrics.s)
            Button("Retry", action: retry)
                .controlSize(.small)
                .accessibilityLabel("Retry saving menu bar spacing")
        }
    }
}
