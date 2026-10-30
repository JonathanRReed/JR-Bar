import JRBarUI
import AppKit
import JRBarCore
import SwiftUI

/// `DockUtility` as a card on the Utilities page — the same `Toy`
/// shape `MenuBarUtility` already wears (docs/UTILITIES.md).
extension DockUtility: Toy {
    var id: String { "dock" }
    var name: String { "Dock" }
    var blurb: String {
        "Previews and widgets when you hover the Dock"
    }
    var symbol: String { "dock.rectangle" }

    var isOn: Bool {
        get { settings().enabled }
        set { update { $0.enabled = newValue } }
    }

    var status: ToyStatus {
        guard isOn else { return .off }
        if let status = providerStatus { return status }
        if !enhance.accessibilityTrusted {
            return .needsPermission("Needs Accessibility")
        }
        if enhance.running || switcher.running { return .on }
        let current = settings()
        return Self.idleChip(previewsOn: current.enhance.hoverPreviews, switcherOn: current.switcherWanted)
    }

    /// The chip while JR-Bar has the Dock and neither half runs: that both
    /// halves are switched off, or that they are still starting, never
    /// "Parked". A counterpart's chip is `providerStatus`.
    nonisolated static func idleChip(previewsOn: Bool, switcherOn: Bool) -> ToyStatus {
        if !previewsOn && !switcherOn { return .note("Previews and switcher are off") }
        return .paused("Starting")
    }

    /// What the Dock costs right now, measured where the work happens.
    func cost(at now: TimeInterval) -> String? {
        guard isOn else { return UtilityCost.off }
        return Self.costLine(watching: enhance.running, switcher: switcher.running,
                             previews: UtilityCost.dockPreviews.count(at: now),
                             captures: UtilityCost.dockCaptures.count(at: now))
    }

    nonisolated static func costLine(watching: Bool, switcher: Bool, previews: Int, captures: Int) -> String {
        var parts: [String] = []
        if watching {
            parts.append("Watching the Dock through Accessibility")
            parts.append("\(UtilityCost.count(previews, "preview")), \(UtilityCost.count(captures, "capture")) in the last minute")
        }
        if switcher { parts.append("one key tap for the switcher chords") }
        if parts.isEmpty { return "Nothing running · the Dock is someone else's or switched off" }
        return parts.joined(separator: " · ")
    }

    var controls: AnyView { AnyView(DockUtilityControls(utility: self)) }

    var settingsStatus: String {
        Self.settingsStatus(settings: settings(), status: status)
    }

    nonisolated static func settingsStatus(settings current: DockSettings, status state: ToyStatus) -> String {
        let text: String
        if state == .on {
            text = current.previewsWanted ? "Previews on" : "Previews off"
        } else {
            text = state.text
        }
        return "\(text) · \(current.enhance.previewSize.title) widgets"
    }
}

/// Dock settings use the existing app-state bindings and shared feature groups.
struct DockUtilityControls: View {
    let utility: DockUtility
    /// Installed apps the exclusion menu can name when they aren't
    /// running — scanned off the main thread when the card appears.
    @ViewState private var installed: [DockInstalledApps.App] = []
    @Environment(\.renderSnapshot) private var renderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
            notices
            SettingGroup("Previews") {
                previewControls
                DockPreviewSizePicker(selection: previewSize)
                DockSettingsWidgetSample(size: utility.enhance.preferences.previewSize)
            }
            SettingGroup("App widgets") { nativePreviews }
            SettingGroup("Switchers") { switcherControls }
            SettingGroup("Folders") {
                SettingLabel(title: "Folder pops",
                             subtitle: "Uses Hover previews. Hover a Dock folder to browse its files. Click a subfolder to browse inside, or Command-click to open it in Finder.")
            }
            SettingGroup("Exclusions") {
                SettingLabel(title: "Never preview",
                             subtitle: Self.exclusionSummary(exclusions.wrappedValue.map(appName(for:))))
                exclusionList
                SettingLabel(title: "Never switch to",
                             subtitle: "Hide these apps from both switchers. Their Dock previews stay available.")
                exclusionList(switcherExclusions, restore: "Show in the switcher again")
                    .disabled(!ownSwitcher)
            }
            SettingsFeatureMoreOptions(id: "dock", subtitle: "Providers, gestures, capture limits, display filters and Dock placement.") {
                VStack(alignment: .leading, spacing: 0) {
                    CardSectionHeader("Preview provider")
                    previewProvider
                    CardSectionHeader("Preview behavior")
                    previewOptions
                    CardSectionHeader("Placement")
                    appearance
                    CardSectionHeader("Switcher options")
                    switcherOptions
                }
            }
        }
        .onAppear {
            guard !renderSnapshot else { return }
            utility.enhance.refreshPermissions(force: true)
        }
        .task {
            guard !renderSnapshot else { return }
            installed = await DockInstalledApps.load()
        }
    }

    private var previewProvider: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabeledContent {
                Picker(selection: utility.providerBinding) {
                    Text("JR-Bar").tag(DockProvider.jrbar)
                    ExternalProviderOption(name: "DockDoor", value: DockProvider.dockDoor, installed: ExternalProviders.dockDoor.installed)
                    ExternalProviderOption(name: "ActiveDock", value: DockProvider.activeDock, installed: ExternalProviders.activeDock.installed)
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            } label: {
                SettingLabel(title: "Render with",
                             subtitle: "Preview provider. Choosing DockDoor or ActiveDock pauses JR-Bar previews. The app switcher has a separate provider.")
            }
            if let note = utility.providerNote {
                providerNote(note, symbol: "arrow.triangle.2.circlepath",
                             open: utility.externalURL == nil ? nil : { utility.openExternal() })
            }
            RivalGuardView(role: .dockPreviews, active: utility.isOn && utility.settings().provider == .jrbar,
                           handOver: { utility.handOver(to: $0) })

        }
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: hoverPreviews) {
                SettingLabel(title: "Hover previews",
                             subtitle: "Hover a Dock icon to see its windows or widget. Click a window to bring it forward.")
            }
            .help("Browse folders in place. If a read fails, Retry reads the same folder again without closing the preview.")
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
                             subtitle: "Previews open on hover, Option-hover or middle-click.")
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

            Toggle(isOn: thumbnails) {
                SettingLabel(title: "Window thumbnails",
                             subtitle: "Show window images with Screen Recording access. Captures flash the recording dot. Off shows icons and titles.")
            }

        }
    }

    private var switcherControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabeledContent {
                Picker(selection: utility.switcherProviderBinding) {
                    ForEach(DockSwitcherProvider.allCases, id: \.self) { provider in
                        ExternalProviderOption(name: DockUtility.displayName(provider), value: provider,
                            installed: DockUtility.probe(for: provider)?.installed ?? true)
                    }
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            } label: {
                SettingLabel(title: "Switcher",
                             subtitle: "Choose who handles Option-Tab and Command-Tab, independently of previews.")
            }
            if let note = utility.switcherNote {
                providerNote(note, symbol: "exclamationmark.arrow.triangle.2.circlepath",
                             open: utility.switcherExternalURL == nil ? nil : { utility.openSwitcherExternal() })
            }
            Toggle(isOn: switcher) {
                SettingLabel(title: "⌥⇥ window switcher",
                             subtitle: "Option-Tab switches windows, with waiting agents first. Type to search; ! finds waiting agents and ` filters by app.")
            }
            .disabled(!ownSwitcher)
            Toggle(isOn: appSwitcher) {
                SettingLabel(title: "⌘⇥ app switcher",
                             subtitle: "Command-Tab opens JR-Bar's app strip. Off keeps the system app switcher.")
            }
            .disabled(!ownSwitcher)
        }
    }

    private var switcherOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabeledContent {
                Picker(selection: spacingStop) {
                    ForEach(DockPreviewSpacing.allCases, id: \.self) { stop in
                        Text(stop.title).tag(Optional(stop))
                    }
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
            } label: {
                SettingLabel(title: "Switcher spacing", subtitle: "Set the space between switcher cards.")
            }
            Toggle(isOn: switcherThisDisplay) {
                SettingLabel(title: "⌥⇥ lists this display only",
                             subtitle: "The strip shows the windows on the pointer's screen; minimized ones always list.")
            }
            .disabled(!ownSwitcher)
            LabeledContent {
                Picker(selection: switcherOrder) {
                    Text("Most recent first").tag(DockSwitcherOrder.recent)
                    Text("Grouped by app").tag(DockSwitcherOrder.byApp)
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
            } label: {
                SettingLabel(title: "Window order",
                             subtitle: "The strip's windows by when you last used them, or each app's together.")
            }
            .disabled(!ownSwitcher)
            Toggle(isOn: switcherWindowless) {
                SettingLabel(title: "Apps with no windows",
                             subtitle: "Running apps with no open window get a card at the end of the strip; picking one brings the app forward.")
            }
            .disabled(!ownSwitcher)
            LabeledContent {
                Picker(selection: switcherStyle) {
                    Text("Stills").tag(DockSwitcherStyle.stills)
                    Text("Icons").tag(DockSwitcherStyle.icons)
                } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
            } label: {
                SettingLabel(title: "Card faces",
                             subtitle: "Show window images or app icons. Icons require no screen capture.")
            }
            .disabled(!ownSwitcher)
            let learned = utility.settings().enhance.learnedPicks.count
            LabeledContent {
                Button("Forget") { utility.update { $0.enhance.learnedPicks = [] } }
                    .controlSize(.small).disabled(learned == 0)
            } label: {
                SettingLabel(title: "Remembered picks",
                             subtitle: "Type-ahead remembers \(learned) picks. Forget clears this history.")
            }
        }
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
                .accessibilityLabel("Dismiss")
            }
            .padding(.bottom, SettingsMetrics.xs)
        }
    }

    /// Placement settings keep their existing values and bindings.
    @ViewBuilder
    private var appearance: some View {
        let prefs = utility.enhance.preferences
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
                SettingLabel(title: "Fine switcher spacing", subtitle: "Adjust card spacing between the named stops.")
            }
            Toggle(isOn: liveCard) {
                SettingLabel(title: "Live card under the pointer",
                             subtitle: "Play the hovered window live. Keeps the screen-recording dot on.")
            }
            .disabled(!utility.enhance.preferences.showThumbnails)
            Toggle(isOn: cardsHugWindows) {
                SettingLabel(title: "Cards take each window's shape",
                             subtitle: "Match each card to its window's shape, with no bars beside portrait windows.")
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
                             subtitle: "Above this count, show a title list without captures. Never keeps thumbnail cards.")
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
                             subtitle: "Minimize the active app's windows from its Dock icon. Click again to bring one back.")
            }
            .disabled(!ownPreviews)
            Toggle(isOn: frontAppChord) {
                SettingLabel(title: "⌥` previews the front app",
                             subtitle: "Option-backtick opens the front app's windows. Arrows select; Return opens. Replaces the accent key on US layouts.")
            }
            .disabled(!ownPreviews)
            Toggle(isOn: holdOpen) {
                SettingLabel(title: "Hold the Dock out",
                             subtitle: utility.enhance.autohideHold.available
                                ? "Keep an auto-hiding Dock visible until its preview closes."
                                : "Unavailable on this macOS. The Dock can hide while you move onto a preview.")
            }
            .disabled(!utility.enhance.autohideHold.available)
        }
    }

    /// The apps that never open a preview, each with its way back, and
    /// the menu that adds one — running apps first, installed ones under.
    private var exclusionList: some View {
        exclusionList(exclusions, restore: "Preview again")
    }

    private func exclusionList(_ exclusions: Binding<[String]>, restore: String) -> some View {
        let filterable = filterableApps(excluded: exclusions.wrappedValue)
        return VStack(alignment: .leading, spacing: 6) {
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
                    .help("\(restore): \(appName(for: bundleID))")
                    .accessibilityLabel("\(restore): \(appName(for: bundleID))")
                }
            }
            Menu {
                ForEach(filterable, id: \.bundleID) { app in
                    Button(app.name ?? "App") {
                        exclusions.wrappedValue.append(app.bundleID!)
                    }
                }
                // Apps that aren't running right now — an exclusion
                // shouldn't have to wait for the app to be open.
                let others = DockInstalledApps.notListed(installed, excluded: exclusions.wrappedValue,
                                                         running: filterable.compactMap(\.bundleID))
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
                    .jrbarType(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(filterable.isEmpty && installed.isEmpty)
        }
    }

    /// The exclusion group's line: what the list is for while it is
    /// empty, the names it holds once it isn't.
    static func exclusionSummary(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Add an app here so no preview opens for it."
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
            CardNote(text, symbol: "exclamationmark.triangle.fill", tint: Tone.neutral.color)
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
    private var switcherOrder: Binding<DockSwitcherOrder> {
        Binding(get: { utility.enhance.preferences.switcherOrder },
                set: { utility.enhance.preferences.switcherOrder = $0 })
    }
    private var switcherWindowless: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.switcherShowsWindowless },
                set: { utility.enhance.preferences.switcherShowsWindowless = $0 })
    }
    private var switcherStyle: Binding<DockSwitcherStyle> {
        Binding(get: { utility.enhance.preferences.switcherStyle },
                set: { utility.enhance.preferences.switcherStyle = $0 })
    }
    private var cardsHugWindows: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.cardsHugWindows },
                set: { utility.enhance.preferences.cardsHugWindows = $0 })
    }
    private var coverDockLabel: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.coverDockLabel },
                set: { utility.enhance.preferences.coverDockLabel = $0 })
    }

    // The Enhance preferences are a nested settings struct, so each
    // control binds straight to it.
    private var previewDelay: Binding<Double> {
        Binding(get: { utility.enhance.preferences.previewDelay },
                set: { utility.enhance.preferences.previewDelay = $0 })
    }
    private var thumbnails: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.showThumbnails },
                set: { utility.enhance.preferences.showThumbnails = $0 })
    }
    private var nativePreviews: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            nativePreviewRow("Calendar", bundleID: "com.apple.iCal") {
                SettingLabel(title: "Calendar preview", subtitle: "Show upcoming events or a month grid when you hover Calendar.")
            } control: { Toggle("Calendar preview", isOn: calendarPreview).labelsHidden() }
            if calendarPreview.wrappedValue { DockWidgetPermission(access: .calendar) }
            LabeledContent {
                Picker("Calendar view", selection: calendarView) {
                    ForEach(DockCalendarView.allCases, id: \.self) { view in Text(view.title).tag(view) }
                }.pickerStyle(.segmented).labelsHidden()
            } label: {
                SettingLabel(title: "Calendar view", subtitle: "Choose an event list or a month grid.")
            }
            .disabled(!calendarPreview.wrappedValue)
            nativePreviewRow("Music", bundleID: "com.apple.Music") {
                SettingLabel(title: "Music player", subtitle: "Show the current track and playback controls when you hover Music.")
            } control: { Toggle("Music player", isOn: musicPlayer).labelsHidden() }
            Toggle(isOn: musicFullControls) {
                SettingLabel(title: "Full Music controls", subtitle: "Add shuffle, repeat, volume and Love through Automation. Stays off until you choose it.")
            }
            .disabled(!musicPlayer.wrappedValue)
            if musicFullControls.wrappedValue { DockWidgetPermission(access: .music) }
            nativePreviewRow("Reminders", bundleID: "com.apple.reminders") {
                SettingLabel(title: "Reminders preview", subtitle: "Show due reminders and mark them complete from the Dock.")
            } control: { Toggle("Reminders preview", isOn: Binding(
                get: { utility.enhance.preferences.remindersPreview },
                set: { utility.enhance.preferences.remindersPreview = $0 })).labelsHidden() }
            if utility.enhance.preferences.remindersPreview { DockWidgetPermission(access: .reminders) }
            nativePreviewRow("Shortcuts", bundleID: "com.apple.shortcuts") {
                SettingLabel(title: "Shortcuts preview", subtitle: "List your shortcuts and run one from its preview.")
            } control: { Toggle("Shortcuts preview", isOn: Binding(
                get: { utility.enhance.preferences.shortcutsPreview },
                set: { utility.enhance.preferences.shortcutsPreview = $0 })).labelsHidden() }
            nativePreviewRow("Other media", bundleID: DockEnhanceSettings.otherMediaSizeKey) {
                SettingLabel(title: "Other media previews", subtitle: "Show the playing track for other media apps, with windows when no track is available.")
            } control: { Toggle("Other media previews", isOn: mediaPreview).labelsHidden() }
            let known = Set(["com.apple.iCal", "com.apple.reminders", "com.apple.shortcuts",
                             "com.apple.Music", DockEnhanceSettings.otherMediaSizeKey])
            ForEach(utility.settings().enhance.previewSizeOverrides.keys.sorted().filter { !known.contains($0) }, id: \.self) { bundleID in
                nativePreviewRow(appName(for: bundleID), bundleID: bundleID) {
                    SettingLabel(title: appName(for: bundleID), subtitle: "An individual preview size for this app.")
                } control: { EmptyView() }
            }
        }
    }

    private func nativePreviewRow<Label: View, Control: View>(
        _ name: String, bundleID: String,
        @ViewBuilder label: () -> Label, @ViewBuilder control: () -> Control
    ) -> some View {
        SettingsControlLayout {
            label().frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: JRBarTokens.Space.sm) {
                DockPreviewSizeOverridePicker(name: name, selection: Binding(
                    get: { utility.settings().enhance.previewSizeOverrides[bundleID] },
                    set: { utility.enhance.preferences.setPreviewSize($0, for: bundleID) }))
                control().toggleStyle(.switch)
            }
        }
        .padding(.vertical, SettingsMetrics.rowPadding)
    }

    private var calendarPreview: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.calendarPreview },
                set: { utility.enhance.preferences.calendarPreview = $0 })
    }
    private var calendarView: Binding<DockCalendarView> {
        Binding(get: { utility.enhance.preferences.calendarView },
                set: { utility.enhance.preferences.calendarView = $0 })
    }
    private var musicPlayer: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.musicPlayer },
                set: { utility.enhance.preferences.musicPlayer = $0 })
    }
    private var musicFullControls: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.musicFullControls },
                set: { utility.enhance.preferences.musicFullControls = $0 })
    }
    private var mediaPreview: Binding<Bool> {
        Binding(get: { utility.enhance.preferences.mediaPreview },
                set: { utility.enhance.preferences.mediaPreview = $0 })
    }
    private var previewSize: Binding<DockPreviewSize> {
        Binding(get: { utility.enhance.preferences.previewSize },
                set: { utility.enhance.preferences.previewSize = $0 })
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
    private var switcherExclusions: Binding<[String]> {
        Binding(get: { utility.enhance.preferences.switcherExcludedBundleIDs },
                set: { utility.enhance.preferences.switcherExcludedBundleIDs = $0 })
    }

    /// Running regular apps not already excluded — the add menu's pool.
    /// Read from the `RunningApps` index: the card's body asks for it
    /// three times a render, and asking each app was a LaunchServices
    /// round trip apiece.
    private func filterableApps(excluded bundleIDs: [String]) -> [RunningApp] {
        let excluded = Set(bundleIDs)
        return RunningApps.shared.apps
            .filter { app in
                guard app.policy == .regular, let id = app.bundleID else { return false }
                return !excluded.contains(id)
            }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    /// What an excluded row reads: the running app's name, else the
    /// installed app's, else the bundle id so an uninstalled filter is
    /// still recognisable.
    private func appName(for bundleID: String) -> String {
        RunningApps.shared.apps.first(where: { $0.bundleID == bundleID })?.name
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
        let policy = ExternalFilePolicy(home: NSHomeDirectory())
        for directory in directories where policy.available(directory) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasSuffix(".app") {
                let url = directory.appendingPathComponent(name)
                guard policy.available(url), let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      seen.insert(id).inserted else { continue }
                let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? String(name.dropLast(4))
                apps.append(App(name: display, bundleID: id))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let installedApps = BackgroundLookupCache<Int, [App]>(load: { _ in scan(directories) })

    static func load() async -> [App] {
        await installedApps.resolve(0) ?? []
    }

    /// The installed apps the menu's running half and the list don't
    /// already carry — and never JR-Bar's own family.
    static func notListed(_ installed: [App], excluded: [String], running: [String]) -> [App] {
        let skip = Set(excluded).union(running)
        return installed.filter { !skip.contains($0.bundleID) && !MenuBarUtility.isOwnFamily($0.bundleID) }
    }
}
