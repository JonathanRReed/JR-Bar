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

/// The Dock card's disclosure body, in the Menu Bar card's shape: what
/// needs you first (a missing permission, a recovered hold), the rows
/// most people set, then the rest of the previews and the exclusion
/// list behind disclosures, and the switcher last. The knobs persist
/// through `DockSettings.enhance` — the facade's `write` lands in
/// `app-state.json` via `DockUtility.update`.
struct DockUtilityControls: View {
    let utility: DockUtility
    /// Installed apps the exclusion menu can name when they aren't
    /// running — scanned off the main thread when the card appears.
    @ViewState private var installed: [DockInstalledApps.App] = []
    @ViewState private var showPreviewOptions = false
    @ViewState private var showExclusions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            notices

            LabeledContent {
                Picker(selection: utility.providerBinding) {
                    Text("JR-Bar").tag(DockProvider.jrbar)
                    Text("DockDoor").tag(DockProvider.dockDoor)
                    Text("ActiveDock").tag(DockProvider.activeDock)
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            } label: {
                SettingLabel(title: "Render with",
                             subtitle: "Hand the previews to DockDoor (free) or ActiveDock (paid); ours park while the pick stands. The switcher has its own pick below.")
            }
            if let note = utility.providerNote {
                providerNote(note, symbol: "arrow.triangle.2.circlepath",
                             open: utility.externalURL == nil ? nil : { utility.openExternal() })
            }

            CardSectionHeader("Previews")
            Toggle(isOn: hoverPreviews) {
                SettingLabel(title: "Hover previews",
                             subtitle: "Apple's Dock stays. Rest on an icon and its windows appear beside the Dock — click a card to raise it, ⌥-click to keep the preview up.")
            }
            LabeledContent {
                Picker(selection: previewTrigger) {
                    Text("Hover").tag(DockPreviewTrigger.hover)
                    Text("Hover with ⌥ held").tag(DockPreviewTrigger.optionHover)
                    Text("Middle-click").tag(DockPreviewTrigger.middleClick)
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            } label: {
                SettingLabel(title: "Open previews on",
                             subtitle: "A rest on the icon, a rest with Option held, or a middle click — for anyone who finds hover panels noisy.")
            }
            .disabled(!ownPreviews)
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

            CardSectionHeader("Appearance")
            appearance
            Toggle(isOn: thumbnails) {
                SettingLabel(title: "Window thumbnails",
                             subtitle: "A capture of each window, kept for half a minute. Needs Screen Recording, and a fresh capture flashes macOS's recording dot; off shows icon and title cards.")
            }

            CardSectionHeader("More")
            DisclosureGroup(isExpanded: $showPreviewOptions) {
                previewOptions
            } label: {
                SettingLabel(title: "More preview options",
                             subtitle: "Fine spacing, card size and captures, which windows list, the icon gestures, ⌥` and the auto-hiding Dock.")
            }

            DisclosureGroup(isExpanded: $showExclusions) {
                exclusionList
            } label: {
                SettingLabel(title: "Never preview",
                             subtitle: Self.exclusionSummary(exclusions.wrappedValue.map(appName(for:))))
            }

            CardSectionHeader("Switching")
            LabeledContent {
                Picker(selection: utility.switcherProviderBinding) {
                    ForEach(DockSwitcherProvider.allCases, id: \.self) { provider in
                        Text(DockUtility.displayName(provider)).tag(provider)
                    }
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            } label: {
                SettingLabel(title: "Switcher",
                             subtitle: "Who answers ⌥⇥ and ⌘⇥ — so DockDoor can draw the previews while JR-Bar keeps the switcher.")
            }
            if let note = utility.switcherNote {
                providerNote(note, symbol: "exclamationmark.arrow.triangle.2.circlepath",
                             open: utility.switcherExternalURL == nil ? nil : { utility.openSwitcherExternal() })
            }
            Toggle(isOn: switcher) {
                SettingLabel(title: "⌥⇥ window switcher",
                             subtitle: "Option-Tab raises every app's windows in recency order, a window whose agent waits on you first. Type to search windows and their sessions — ! for waiting agents, ` for one app.")
            }
            .disabled(!ownSwitcher)
            Toggle(isOn: appSwitcher) {
                SettingLabel(title: "⌘⇥ app switcher",
                             subtitle: "Replaces Command-Tab with a centred app strip. Off leaves the system's chord alone.")
            }
            .disabled(!ownSwitcher)
            Toggle(isOn: switcherThisDisplay) {
                SettingLabel(title: "⌥⇥ lists this display only",
                             subtitle: "The strip shows the windows on the pointer's screen; minimized ones always list.")
            }
            .disabled(!ownSwitcher)
            let learned = utility.settings().enhance.learnedPicks.count
            if learned > 0 {
                HStack(spacing: SettingsMetrics.s) {
                    CardNote(learned == 1 ? "Type-ahead remembers 1 pick — a short query lands where it did last time."
                                          : "Type-ahead remembers \(learned) picks — a short query lands where it did last time.",
                             symbol: "sparkle.magnifyingglass")
                    Spacer(minLength: SettingsMetrics.s)
                    Button("Forget") { utility.update { $0.enhance.learnedPicks = [] } }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { utility.enhance.refreshPermissions(force: true) }
        .task { installed = await DockInstalledApps.load() }
    }

    /// What needs you before any knob does: the permission the card's
    /// status chip names, and a Dock hold an unclean quit left behind.
    @ViewBuilder
    private var notices: some View {
        if utility.isOn && !utility.enhance.accessibilityTrusted {
            permissionNote("Hover previews need Accessibility so JR-Bar can see which Dock icon the pointer rests on.") {
                utility.openAccessibilitySettings()
            }
        } else if utility.isOn && utility.enhance.preferences.showThumbnails
                    && !utility.enhance.screenCaptureGranted {
            permissionNote("Thumbnails need Screen Recording — window titles, raising, closing and minimizing work without it.") {
                utility.openScreenCaptureSettings()
            }
        }
        if let note = utility.recoveredHoldNote {
            HStack(spacing: SettingsMetrics.s) {
                CardNote(note, symbol: "arrow.uturn.backward.circle")
                Spacer(minLength: SettingsMetrics.s)
                Button {
                    utility.dismissRecoveredHoldNote()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.bottom, SettingsMetrics.xs)
        }
    }

    /// How much air the preview keeps and where it sits: a live sample
    /// over drawn stills (no capture), the spacing stops, the distance
    /// from the Dock and the name-label cover.
    @ViewBuilder
    private var appearance: some View {
        let prefs = utility.enhance.preferences
        DockPreviewSample(spacing: prefs.previewSpacing, dockGap: prefs.dockGap,
                          coversLabel: prefs.coverDockLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, SettingsMetrics.s)
        LabeledContent {
            HStack(spacing: 8) {
                if spacingStop.wrappedValue == nil {
                    Text("Custom")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .help("Set with Fine spacing, under More preview options")
                }
                Picker(selection: spacingStop) {
                    ForEach(DockPreviewSpacing.allCases, id: \.self) { stop in
                        Text(stop.title).tag(Optional(stop))
                    }
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
            }
        } label: {
            SettingLabel(title: "Spacing",
                         subtitle: "The air around the cards inside the preview. Standard is the roomier look it had before.")
        }
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: dockGap, in: DockEnhancePreferences.dockGapRange)
                    .frame(width: 140)
                ValueText(text: "\(Int(prefs.dockGap.rounded())) pt")
            }
        } label: {
            SettingLabel(title: "Distance from the Dock",
                         subtitle: "The gap between the icon and the preview's glass.")
        }
        Toggle(isOn: coverDockLabel) {
            SettingLabel(title: "Cover the Dock's name label",
                         subtitle: "The preview sits over the name the Dock shows above the icon; its header names the app. Off, it floats above the name.")
        }
    }

    /// The rows past the everyday ones: what a card looks like and
    /// captures, which windows list, and the icon and keyboard gestures.
    private var previewOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: fineSpacing, in: DockEnhancePreferences.spacingRange, step: 0.05)
                        .frame(width: 140)
                    ValueText(text: Self.percent(utility.enhance.preferences.previewSpacing))
                }
            } label: {
                SettingLabel(title: "Fine spacing",
                             subtitle: "The spacing between the stops: 60 % is Tight, 100 % Standard, 140 % Roomy. The ⌥⇥ switcher follows it too.")
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
            Toggle(isOn: previewThisDisplay) {
                SettingLabel(title: "Only windows on this display",
                             subtitle: "A preview lists the windows on the Dock's own screen; minimized ones always list.")
            }
            // The icon gestures ride JR-Bar's own watcher — with the
            // previews off or handed to a counterpart they'd do nothing,
            // so they say so by standing down.
            Toggle(isOn: scrollGestures) {
                SettingLabel(title: "Scroll on an icon",
                             subtitle: "Scroll up on a Dock icon to open its preview at once; scroll down to hide the app.")
            }
            .disabled(!ownPreviews)
            Toggle(isOn: clickToMinimize) {
                SettingLabel(title: "Click the front app's icon to minimize",
                             subtitle: "Clicking the Dock icon of the app you're in minimizes its windows, like a Windows taskbar; click again and the Dock brings one back.")
            }
            .disabled(!ownPreviews)
            Toggle(isOn: frontAppChord) {
                SettingLabel(title: "⌥` previews the front app",
                             subtitle: "Option-backtick opens the front app's windows on its Dock tile with the next one picked — arrows walk, Return raises, W, M and F act. Takes the accent key ⌥` types on US layouts.")
            }
            .disabled(!ownPreviews)
            Toggle(isOn: holdOpen) {
                SettingLabel(title: "Hold the Dock out",
                             subtitle: utility.enhance.autohideHold.available
                                ? "While a preview is up an auto-hiding Dock stays out so the pointer can step onto the cards; it hides again when the panel closes."
                                : "Not available on this macOS — an auto-hiding Dock slides away when the pointer steps onto the cards.")
            }
            .disabled(!utility.enhance.autohideHold.available)
        }
    }

    /// The apps that never open a preview, each with its way back, and
    /// the menu that adds one — running apps first, installed ones under.
    private var exclusionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(exclusions.wrappedValue, id: \.self) { bundleID in
                HStack(spacing: 6) {
                    Text(appName(for: bundleID))
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
        }
    }

    /// The exclusion group's line: what the list is for while it is
    /// empty, the names it holds once it isn't.
    static func exclusionSummary(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Apps on this list can rest in the Dock all they like — no preview opens."
        case 1: return "\(names[0]) never opens a preview."
        case 2: return "\(names[0]) and \(names[1]) never open a preview."
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more never open a preview."
        }
    }

    /// A counterpart's line under its picker, with Open when there's an
    /// app to open.
    private func providerNote(_ note: String, symbol: String, open: (() -> Void)?) -> some View {
        HStack(spacing: SettingsMetrics.s) {
            CardNote(note, symbol: symbol)
            if let open {
                Spacer(minLength: SettingsMetrics.s)
                Button("Open", action: open)
                    .controlSize(.small)
            }
        }
    }

    private func permissionNote(_ text: String, open: @escaping () -> Void) -> some View {
        HStack(spacing: SettingsMetrics.s) {
            CardNote(text, symbol: "exclamationmark.triangle.fill", tint: .orange)
            Spacer(minLength: SettingsMetrics.s)
            Button("Open Settings", action: open)
                .controlSize(.small)
        }
        .padding(.bottom, SettingsMetrics.xs)
    }

    /// Whether JR-Bar answers ⌥⇥ and ⌘⇥ — the switcher rows only act then.
    private var ownSwitcher: Bool { utility.settings().switcherProvider == .jrbar }

    /// Whether JR-Bar's own hover watcher is the one running — the
    /// trigger, the icon gestures and ⌥` all ride it.
    private var ownPreviews: Bool { DockUtility.ownsPreviews(utility.settings()) }

    /// "60%" — the fine spacing's readout.
    static func percent(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    /// The stop the spacing sits on; nil between stops (Custom). Picking
    /// a stop stores its scale.
    private var spacingStop: Binding<DockPreviewSpacing?> {
        Binding(get: { DockPreviewSpacing.stop(for: utility.enhance.preferences.previewSpacing) },
                set: { stop in
                    guard let stop else { return }
                    utility.enhance.preferences.previewSpacing = stop.scale
                })
    }
    /// The fine slider lands on its 0.05 steps exactly, so 0.6 reads as
    /// Tight rather than a hair off it.
    private var fineSpacing: Binding<Double> {
        Binding(get: { utility.enhance.preferences.previewSpacing },
                set: { utility.enhance.preferences.previewSpacing = ($0 * 20).rounded() / 20 })
    }
    private var dockGap: Binding<Double> {
        Binding(get: { utility.enhance.preferences.dockGap },
                set: { utility.enhance.preferences.dockGap = $0.rounded() })
    }
    private var coverDockLabel: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.coverDockLabel },
                set: { utility.enhance.preferences.coverDockLabel = $0 })
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
