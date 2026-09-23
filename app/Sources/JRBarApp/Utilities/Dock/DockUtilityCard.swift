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
    /// Installed apps the exclusion menu can name when they aren't
    /// running — scanned off the main thread when the card appears.
    @ViewState private var installed: [DockInstalledApps.App] = []

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
                             subtitle: "Apple's Dock stays. Rest the pointer on an icon and that app's windows appear beside the Dock: click a card to raise the window (⌥-click keeps the preview up), hover it for × (close), – (minimize) and full screen; New, Hide and Quit sit in the header. Apps with no windows open nothing. Off keeps the switcher below on its own.")
            }
            Picker(selection: previewTrigger) {
                Text("Hover").tag(DockPreviewTrigger.hover)
                Text("Hover with ⌥ held").tag(DockPreviewTrigger.optionHover)
                Text("Middle-click").tag(DockPreviewTrigger.middleClick)
            } label: {
                SettingLabel(title: "Open previews on",
                             subtitle: "A rest on the icon, a rest while holding Option, or a middle click — for anyone who finds hover panels noisy while aiming at the Dock.")
            }
            .pickerStyle(.menu)
            .fixedSize()
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
            .disabled(utility.enhance.preferences.previewTrigger == .middleClick)
            Toggle(isOn: scrollGestures) {
                SettingLabel(title: "Scroll on an icon",
                             subtitle: "Scroll up on a Dock icon to open its preview at once; scroll down to hide the app.")
            }
            Toggle(isOn: clickToMinimize) {
                SettingLabel(title: "Click the front app's icon to minimize",
                             subtitle: "Clicking the Dock icon of the app you're in minimizes its windows, like a Windows taskbar; click again and the Dock brings one back.")
            }
            Toggle(isOn: thumbnails) {
                SettingLabel(title: "Window thumbnails",
                             subtitle: "A capture of each window, kept for half a minute (needs Screen Recording — each fresh capture flashes macOS's recording dot); off shows icon + title cards.")
            }
            Toggle(isOn: liveCard) {
                SettingLabel(title: "Live card under the pointer",
                             subtitle: "The card you point at plays live instead of showing a still — macOS's recording dot stays on while it does.")
            }
            .disabled(!utility.enhance.preferences.showThumbnails)
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
                             subtitle: utility.enhance.autohideHold.available
                                ? "While a preview is up an auto-hiding Dock stays out so the pointer can step onto the cards; it hides again when the panel closes."
                                : "Not available on this macOS — an auto-hiding Dock slides away when the pointer steps onto the cards.")
            }
            .disabled(!utility.enhance.autohideHold.available)
            if let note = utility.recoveredHoldNote {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        utility.dismissRecoveredHoldNote()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            Toggle(isOn: frontAppChord) {
                SettingLabel(title: "⌥` previews the front app",
                             subtitle: "Option-backtick opens the front app's windows on its Dock tile with the next one picked — arrows walk, Return raises, W, M and F act. Takes the accent key ⌥` types on US layouts.")
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
            let learned = utility.settings().enhance.learnedPicks.count
            if learned > 0 {
                HStack(spacing: 8) {
                    Text(learned == 1 ? "Type-ahead remembers 1 pick — a short query lands where it did last time."
                                      : "Type-ahead remembers \(learned) picks — a short query lands where it did last time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Forget") { utility.update { $0.enhance.learnedPicks = [] } }
                        .controlSize(.small)
                }
            }
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
                // Apps that aren't running right now — an exclusion
                // shouldn't have to wait for the app to be open.
                let others = DockInstalledApps.notListed(installed, excluded: exclusions.wrappedValue,
                                                         running: filterableApps.compactMap(\.bundleIdentifier))
                if !others.isEmpty {
                    Divider()
                    Menu("Other Apps") {
                        ForEach(others, id: \.bundleID) { app in
                            Button(app.name) { exclusions.wrappedValue.append(app.bundleID) }
                        }
                    }
                }
            } label: {
                Label("Exclude an app…", systemImage: "plus.circle")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(filterableApps.isEmpty && installed.isEmpty)
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
        .task { installed = await DockInstalledApps.load() }
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
    private var previewTrigger: Binding<DockPreviewTrigger> {
        Binding(get: { utility.enhance.preferences.previewTrigger },
                set: { utility.enhance.preferences.previewTrigger = $0 })
    }
    private var scrollGestures: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.scrollGestures },
                set: { utility.enhance.preferences.scrollGestures = $0 })
    }
    private var frontAppChord: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.frontAppChord },
                set: { utility.enhance.preferences.frontAppChord = $0 })
    }
    private var liveCard: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.liveCard },
                set: { utility.enhance.preferences.liveCard = $0 })
    }
    private var clickToMinimize: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.clickToMinimize },
                set: { utility.enhance.preferences.clickToMinimize = $0 })
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
    /// installed app's, else the bundle id so an uninstalled filter is
    /// still recognisable.
    private func appName(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? installed.first(where: { $0.bundleID == bundleID })?.name
            ?? bundleID
    }
}

/// The apps installed where macOS keeps them — the exclusion menu's
/// "Other Apps", so a filter never waits for the app to be running.
enum DockInstalledApps {
    struct App: Equatable, Sendable {
        let name: String
        let bundleID: String
    }

    static let directories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// Every `.app` directly inside `directories`, by display name, one
    /// row per bundle id. Reads each bundle's Info.plist — off the main
    /// thread (`load`).
    static func scan(_ directories: [URL]) -> [App] {
        var seen = Set<String>()
        var apps: [App] = []
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasSuffix(".app") {
                let url = directory.appendingPathComponent(name)
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      seen.insert(id).inserted else { continue }
                let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? String(name.dropLast(4))
                apps.append(App(name: display, bundleID: id))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func load() async -> [App] {
        await Task.detached(priority: .utility) { scan(directories) }.value
    }

    /// The installed apps the menu's running half and the list don't
    /// already carry — and never JR-Bar's own family.
    static func notListed(_ installed: [App], excluded: [String], running: [String]) -> [App] {
        let skip = Set(excluded).union(running)
        return installed.filter { !skip.contains($0.bundleID) && !MenuBarUtility.isOwnFamily($0.bundleID) }
    }
}
