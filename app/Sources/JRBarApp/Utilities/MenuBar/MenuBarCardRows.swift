import AppKit
import JRBarCore
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarRuleAppPicker: View {
    @Binding var selection: String
    @ViewState private var enteringIdentifier = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.s) {
            Menu {
                ForEach(RunningApps.shared.apps.filter { $0.policy == .regular && $0.bundleID != nil }, id: \.pid) { app in
                    if let id = app.bundleID {
                        Button(app.name ?? AppDisplayNames.shared.name(of: id)) { selection = id }
                    }
                }
                Divider()
                Button("Choose an app…") { chooseApp() }
                Button("Enter an app identifier…") { enteringIdentifier.toggle() }
            } label: {
                Text(selection.isEmpty ? "Choose an app" : AppDisplayNames.shared.name(of: selection))
            }
            .fixedSize()
            .help("Choose the app this rule watches.")
            if enteringIdentifier {
                TextField("App identifier", text: $selection)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .accessibilityLabel("Application identifier")
                    .help("For an app that is not installed, enter its identifier.")
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        WindowPresenter.automatic.perform {
            panel.begin { response in
                guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
                selection = id
            }
        }
    }
}

/// "Item Bar opens at": under the icon's ‹, or under the pointer.
struct MenuBarItemBarAnchorRow: View {
    let utility: MenuBarUtility

    var body: some View {
        LabeledContent {
            Picker(selection: utility.bind(\.curation.itemBarAt)) {
                Text("The icon").tag(MenuBarItemBarAnchor.icon)
                Text("The pointer").tag(MenuBarItemBarAnchor.pointer)
            } label: { EmptyView() }
                .labelsHidden().pickerStyle(.segmented)
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
