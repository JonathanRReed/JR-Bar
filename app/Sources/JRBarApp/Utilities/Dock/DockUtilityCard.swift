import AppKit
import JRBarCore
import SwiftUI

/// `DockUtility` as a card on the Utilities page — the same `Toy`
/// shape `MenuBarUtility` already wears (docs/UTILITIES.md).
extension DockUtility: Toy {
    var id: String { "dock" }
    var name: String { "Dock" }
    var blurb: String {
        "Rest on a Dock icon to see that app's windows — click one to raise it, close or minimize from the card."
    }
    var symbol: String { "dock.rectangle" }

    var isOn: Bool {
        get { settings().enabled }
        set { update { $0.enabled = newValue } }
    }

    var status: ToyStatus {
        guard isOn else { return .off }
        if !enhance.accessibilityTrusted {
            return .needsPermission("Needs Accessibility")
        }
        return enhance.running || switcher.running ? .on : .paused("Parked")
    }

    var controls: AnyView { AnyView(DockUtilityControls(utility: self)) }
}

/// The Dock card's disclosure body: the hover delay, what the cards
/// carry, and the two permission gates the feature lives behind. The
/// knobs persist through `DockSettings.enhance` — the facade's `write`
/// lands in `app-state.json` via `DockUtility.update`.
struct DockUtilityControls: View {
    let utility: DockUtility

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: utility.providerBinding) {
                Text("JR-Bar").tag(DockProvider.jrbar)
                Text("DockDoor").tag(DockProvider.dockDoor)
                Text("ActiveDock").tag(DockProvider.activeDock)
            } label: {
                SettingLabel(title: "Render with",
                             subtitle: "Hand the previews to an installed counterpart — DockDoor (free) or ActiveDock (paid). Our previews park while the pick stands; the switcher is its own pick below.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            if let note = utility.providerNote {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if utility.externalURL != nil {
                        Spacer()
                        Button("Open") { utility.openExternal() }
                            .controlSize(.small)
                    }
                }
            }

            Toggle(isOn: hoverPreviews) {
                SettingLabel(title: "Hover previews",
                             subtitle: "Apple's Dock stays. Rest the pointer on an icon and that app's windows appear beside the Dock: click a card to raise the window, hover it for × (close), – (minimize) and full screen; New, Hide and Quit sit in the header. Apps with no windows open nothing. Off keeps the switcher below on its own.")
            }
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: previewDelay, in: DockEnhancePreferences.delayRange)
                        .frame(width: 140)
                    ValueText(text: SettingsStore.seconds(utility.enhance.preferences.previewDelay))
                }
            } label: {
                SettingLabel(title: "Show after",
                             subtitle: "How long the pointer rests before the preview opens.")
            }
            Toggle(isOn: thumbnails) {
                SettingLabel(title: "Window thumbnails",
                             subtitle: "A capture of each window, kept for half a minute (needs Screen Recording — each fresh capture flashes macOS's recording dot); off shows icon + title cards.")
            }
            Toggle(isOn: largePreviews) {
                SettingLabel(title: "Large cards",
                             subtitle: "Bigger thumbnails for reading the window, not just the title.")
            }
            Toggle(isOn: offscreen) {
                SettingLabel(title: "Capture every window",
                             subtitle: "Thumbnails for windows on other Spaces and minimized ones too; the cards list them either way.")
            }
            Toggle(isOn: holdOpen) {
                SettingLabel(title: "Hold the Dock out",
                             subtitle: "While a preview is up an auto-hiding Dock stays out so the pointer can step onto the cards; it hides again when the panel closes.")
            }
            Toggle(isOn: previewThisDisplay) {
                SettingLabel(title: "Only windows on this display",
                             subtitle: "A preview lists the windows on the Dock's own screen; minimized ones always list.")
            }
            Divider()
                .padding(.vertical, 4)
            Picker(selection: utility.switcherProviderBinding) {
                ForEach(DockSwitcherProvider.allCases, id: \.self) { provider in
                    Text(DockUtility.displayName(provider)).tag(provider)
                }
            } label: {
                SettingLabel(title: "Switcher",
                             subtitle: "Who answers ⌥⇥ and ⌘⇥ — its own pick, so DockDoor can draw the previews while JR-Bar keeps the switcher.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            if let note = utility.switcherNote {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if utility.switcherExternalURL != nil {
                        Spacer()
                        Button("Open") { utility.openSwitcherExternal() }
                            .controlSize(.small)
                    }
                }
            }
            Toggle(isOn: switcher) {
                SettingLabel(title: "⌥⇥ window switcher",
                             subtitle: "Option-Tab raises every app's windows in recency order — a window whose agent waits on you comes first. Tab walks, releasing Option commits, esc cancels; type to search windows and the sessions in them (! for waiting agents), ` narrows to one app.")
            }
            .disabled(utility.settings().switcherProvider != .jrbar)
            Toggle(isOn: switcherThisDisplay) {
                SettingLabel(title: "⌥⇥ lists this display only",
                             subtitle: "The strip shows the windows on the pointer's screen; minimized ones always list.")
            }
            .disabled(utility.settings().switcherProvider != .jrbar)
            Toggle(isOn: appSwitcher) {
                SettingLabel(title: "⌘⇥ app switcher",
                             subtitle: "Replaces the system's Command-Tab with a centred app strip — Tab walks, releasing Command commits. Off leaves the OS chord alone.")
            }
            .disabled(utility.settings().switcherProvider != .jrbar)
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: compactLimit, in: 0...12, step: 1)
                        .frame(width: 140)
                    ValueText(text: utility.enhance.preferences.compactListLimit == 0
                              ? "Never" : "past \(utility.enhance.preferences.compactListLimit)")
                }
            } label: {
                SettingLabel(title: "List past N windows",
                             subtitle: "An app with more windows than this gets a compact title list instead of thumbnails — and no captures at all.")
            }
            Divider()
                .padding(.vertical, 4)
            SettingLabel(title: "Never preview",
                         subtitle: "Apps on this list can rest in the Dock all they like — no preview opens.")
            ForEach(exclusions.wrappedValue, id: \.self) { bundleID in
                HStack(spacing: 6) {
                    Text(appName(for: bundleID))
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        exclusions.wrappedValue.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Preview \(appName(for: bundleID)) again")
                }
            }
            Menu {
                ForEach(filterableApps, id: \.bundleIdentifier) { app in
                    Button(app.localizedName ?? "App") {
                        exclusions.wrappedValue.append(app.bundleIdentifier!)
                    }
                }
            } label: {
                Label("Exclude an app…", systemImage: "plus.circle")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(filterableApps.isEmpty)
            if utility.isOn && !utility.enhance.accessibilityTrusted {
                HStack(spacing: 8) {
                    Text("Hover previews need Accessibility so JR-Bar can see which Dock icon the pointer rests on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Settings") { utility.openAccessibilitySettings() }
                        .controlSize(.small)
                }
            } else if utility.isOn && utility.enhance.preferences.showThumbnails
                        && !utility.enhance.screenCaptureGranted {
                HStack(spacing: 8) {
                    Text("Thumbnails need Screen Recording — window titles, raising, closing and minimizing work without it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Settings") { utility.openScreenCaptureSettings() }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { utility.enhance.refreshPermissions(force: true) }
    }

    // Nested settings structs get their own bindings — `bind` only
    // reaches top-level key paths cleanly through the write path.
    private var previewDelay: Binding<Double> {
        Binding(get: { utility.enhance.preferences.previewDelay },
                set: { utility.enhance.preferences.previewDelay = $0 })
    }
    private var thumbnails: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.showThumbnails },
                set: { utility.enhance.preferences.showThumbnails = $0 })
    }
    private var largePreviews: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.largePreviews },
                set: { utility.enhance.preferences.largePreviews = $0 })
    }
    private var offscreen: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.includeOffscreenWindows },
                set: { utility.enhance.preferences.includeOffscreenWindows = $0 })
    }
    private var hoverPreviews: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.hoverPreviews },
                set: { utility.enhance.preferences.hoverPreviews = $0 })
    }
    private var previewThisDisplay: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.previewThisDisplay },
                set: { utility.enhance.preferences.previewThisDisplay = $0 })
    }
    private var switcherThisDisplay: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.switcherThisDisplay },
                set: { utility.enhance.preferences.switcherThisDisplay = $0 })
    }
    private var holdOpen: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.holdDockOpen },
                set: { utility.enhance.preferences.holdDockOpen = $0 })
    }
    private var switcher: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.windowSwitcher },
                set: { utility.enhance.preferences.windowSwitcher = $0 })
    }

    private var appSwitcher: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.appSwitcher },
                set: { utility.enhance.preferences.appSwitcher = $0 })
    }
    private var compactLimit: Binding<Double> {
        Binding(get: { Double(utility.enhance.preferences.compactListLimit) },
                set: { utility.enhance.preferences.compactListLimit = Int($0.rounded()) })
    }
    private var exclusions: Binding<[String]> {
        Binding(get: { utility.enhance.preferences.excludedBundleIDs },
                set: { utility.enhance.preferences.excludedBundleIDs = $0 })
    }

    /// Running regular apps not already excluded — the add menu's pool.
    private var filterableApps: [NSRunningApplication] {
        let excluded = Set(exclusions.wrappedValue)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && !excluded.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// What an excluded row reads: the running app's name, else the
    /// bundle id so an uninstalled filter is still recognisable.
    private func appName(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName ?? bundleID
    }
}
