import JRBarUI
import JRBarCore
import JRBarLEDS
import SwiftUI

// MARK: - General

struct GeneralPage: View {
    @Bindable var store: SettingsStore

    var body: some View {
        SettingGroup("Startup") {
            Toggle(isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })) {
                SettingLabel(title: "Launch at login", subtitle: store.launchAtLoginError ?? "Starts JR-Bar when you log in.")
            }
            .settingRowStyle()
            SettingRow("Setup", subtitle: "The first-run walkthrough — agents, permissions, menu bar.") {
                Button("Run Setup Again…") { SetupWindowController.show() }
            }
        }

        SettingGroup("Menu bar") {
            MenuBarStylePicker(store: store)
            Toggle(isOn: $store.panelHotkeyEnabled) {
                SettingLabel(title: "Panel hotkey",
                             subtitle: store.panelHotkeyRegistrationFailed
                                ? "\(store.panelHotkeyLabel) is taken — rebind it on Shortcuts."
                                : "Press \(store.panelHotkeyLabel) in any app to show or hide the panel.")
            }
            .settingRowStyle()
            Toggle(isOn: $store.shelfHotkeyEnabled) {
                SettingLabel(title: "Shelf hotkey",
                             subtitle: store.shelfHotkeyRegistrationFailed
                                ? "\(store.shelfHotkeyLabel) is taken — rebind it on Shortcuts."
                                : "Press \(store.shelfHotkeyLabel) in any app to open or fold the notch's shelf.")
            }
            .settingRowStyle()
        }

        SettingGroup("Brightness") {
            SettingSlider(store, "Maximum brightness", subtitle: "Caps every light JR-Bar drives.",
                          path: "global_brightness_scale", in: 0.05...1.0, default: 1.0, format: SettingsStore.percent)
        }

        SettingGroup("Software Update", note: "Updates are checked by the app, not the monitor. The channel is remembered on this Mac.") {
            SettingRow("Version", subtitle: softwareUpdateSubtitle) {
                Button("Check for Updates…") { store.checkForUpdates() }
                    .disabled(!store.updaterAvailable)
                    .help(store.updaterHint ?? "Look for a newer JR-Bar now")
            }
            Toggle(isOn: Binding(get: { store.automaticUpdateChecks }, set: { store.setAutomaticUpdateChecks($0) })) {
                SettingLabel(title: "Automatically check for updates",
                             subtitle: store.updaterHint ?? "Checks in the background and asks before installing.")
            }
            .disabled(!store.updaterAvailable)
            .settingRowStyle()
            DisclosureRow("Advanced") {
                Picker(selection: $store.updateChannel) {
                    Text("Stable").tag("stable")
                    Text("Beta").tag("beta")
                } label: {
                    SettingLabel(title: "Update channel", subtitle: "Stable or beta builds.")
                }
                .pickerStyle(.menu)
            }
        }
        .onAppear { store.refreshUpdater() }
    }

    private var softwareUpdateSubtitle: String {
        let version = AppVersion.describe()
        guard store.updaterAvailable else { return "JR-Bar \(version)" }
        guard let checked = store.lastUpdateCheck else { return "JR-Bar \(version) · never checked" }
        return "JR-Bar \(version) · last checked \(checked.formatted(.relative(presentation: .named)))"
    }
}

/// `menu_bar_icon_style` as five rows, each drawing the style it names on
/// a strip of menu bar, from the live providers when the daemon has any
/// (so the preview is the reader's own menu bar) and from a sample
/// otherwise.
struct MenuBarStylePicker: View {
    @Bindable var store: SettingsStore

    private var current: StatusIconStyle { StatusIconStyle(setting: store.menuBarIconStyle) }

    /// The meters as the menu bar would draw them now: the providers shown
    /// in the panel, in that order; a sample while the core is away.
    private var meters: [StatusMeter] {
        let preferred = store.document.strings("usage_graph_providers") ?? []
        let shown = AppDelegate.meteredProviders(preferred: preferred, usage: store.core.isLive ? store.core.usage : [])
        guard !shown.isEmpty else { return StatusItemController.sampleMeters }
        let now = Date().timeIntervalSince1970
        return shown.prefix(StatusIconRenderer.maxMeters).map { provider in
            StatusItemController.previewMeter(for: provider, document: store.document, now: now)
        }
    }

    private var overflow: Int {
        let preferred = store.document.strings("usage_graph_providers") ?? []
        let shown = AppDelegate.meteredProviders(preferred: preferred, usage: store.core.isLive ? store.core.usage : [])
        return max(0, shown.count - StatusIconRenderer.maxMeters)
    }

    /// The session dots as the menu bar would draw them now: the live
    /// sessions in the panel's order, or a sample while the core is away.
    private var sessions: [SessionDot] {
        let live = store.core.isLive ? store.core.sessions : []
        guard !live.isEmpty else { return StatusItemController.sampleSessionDots }
        return live.sorted { Self.rank($0) < Self.rank($1) }.map { session in
            let activity = SessionActivity.reduce(session)
            let state: StatusDotState = session.ask != nil || activity == .waiting ? .ask
                : activity == .failed ? .error
                : activity == .working ? .working
                : activity == .done ? .done : .idle
            return SessionDot(id: session.id, state: state,
                              accentHex: activity == .working ? ProviderStyle.style(for: session.provider, document: store.document).accentHex : nil)
        }
    }

    /// Asks lead, then failures, work and done — the panel's order.
    private static func rank(_ session: CoreSession) -> Int {
        if session.ask != nil { return 0 }
        switch SessionActivity.reduce(session) {
        case .waiting: return 1
        case .failed: return 2
        case .working: return 3
        case .done: return 4
        case .ended: return 5
        case .idle: return 6
        }
    }

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: SettingsMetrics.s),
                                       count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.s + 2) {
            SettingLabel(title: "Menu bar icon", subtitle: "What the status item shows.")
            LazyVGrid(columns: Self.columns, spacing: SettingsMetrics.s) {
                ForEach(StatusIconStyle.allCases, id: \.self) { style in
                    MenuBarStyleTile(style: style,
                                     selected: current == style,
                                     meters: meters,
                                     overflow: overflow,
                                     sessions: sessions,
                                     label: labelText) {
                        store.menuBarIconStyle = style.rawValue
                    }
                }
            }
            // The chosen style's own sentence, under the gallery.
            Label {
                Text(current.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var labelText: String? {
        guard store.core.isLive, let aggregate = store.core.state?.aggregate else {
            return StatusIconRenderer.label(active: 2, needsYou: 1, ready: 0)
        }
        return StatusIconRenderer.label(active: aggregate.active, needsYou: aggregate.needsYou, ready: aggregate.ready)
            ?? "quiet"
    }
}

/// One row of Setup's icon picker: a radio mark, the preview on its own
/// strip, and the style's name and sentence. Settings shows the same
/// styles as a gallery of `MenuBarStyleTile`s.
struct MenuBarStyleRow: View {
    let style: StatusIconStyle
    let selected: Bool
    let meters: [StatusMeter]
    let overflow: Int
    let sessions: [SessionDot]
    let label: String?
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.6))
                MenuBarPreview(style: style, meters: meters, overflow: overflow, sessions: sessions, label: label)
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.title).foregroundStyle(.primary)
                    Text(style.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.10))
                                 : AnyShapeStyle(Color.primary.opacity(hovering ? 0.04 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(style.title). \(style.subtitle)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One style in the General page's gallery: the status item drawn on
/// its strip of menu bar, the style's name under it, and the accent
/// ring on the one in use. The chosen style's sentence sits under the
/// grid, so nine tiles fit where nine rows of prose used to.
struct MenuBarStyleTile: View {
    let style: StatusIconStyle
    let selected: Bool
    let meters: [StatusMeter]
    let overflow: Int
    let sessions: [SessionDot]
    let label: String?
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
        Button(action: action) {
            VStack(spacing: 7) {
                MenuBarPreview(style: style, meters: meters, overflow: overflow, sessions: sessions,
                               label: label, width: nil)
                HStack(spacing: 4) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(style.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .padding(SettingsMetrics.s)
            .frame(maxWidth: .infinity)
            .background(shape.fill(selected ? Color.accentColor.opacity(0.1)
                                            : Color.primary.opacity(hovering ? 0.06 : 0.03)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                        lineWidth: selected ? 1.5 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(style.subtitle)
        .accessibilityLabel("\(style.title). \(style.subtitle)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The status item as it would look, drawn by the same renderer the menu
/// bar uses, on a strip that reads as a menu bar in either appearance.
struct MenuBarPreview: View {
    let style: StatusIconStyle
    let meters: [StatusMeter]
    let overflow: Int
    let sessions: [SessionDot]
    let label: String?
    /// The strip's width; nil fills the space it is given (the gallery).
    var width: CGFloat? = MenuBarPreview.width
    @Environment(\.colorScheme) private var scheme

    /// Wide enough for the roomiest preview (the label style's "1 ask · 2
    /// working", which is as long as `StatusIconRenderer.label` gets), so
    /// every row's text starts at the same x and none of them truncates.
    static let width: CGFloat = 152

    /// The ring reads the leading meter the way the bar's own does: a
    /// stale or unread lead draws no ring rather than a made-up figure.
    private var ringFraction: Double? {
        guard let lead = meters.first else { return 0.42 }
        return lead.stale ? nil : lead.fraction
    }

    private var spec: StatusIconSpec {
        StatusIconSpec(style: style,
                       ringFraction: ringFraction,
                       tintHex: "#00E5FF",
                       meters: style.isMeters || style == .compactPercent ? meters : [],
                       overflow: style.isMeters ? overflow : 0,
                       dot: style.isMeters ? .working : .idle,
                       sessions: style == .agents || style == .orbit ? sessions : [],
                       phase: 0.5)
    }

    var body: some View {
        let image = StatusIconRenderer.shared.image(for: spec)
        let size = StatusIconRenderer.size(for: spec)
        HStack(spacing: 5) {
            if style == .hidden {
                // Nothing stands in the bar; a struck eye says so instead
                // of an empty strip that reads as a preview still loading.
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            } else {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .foregroundStyle(image.isTemplate && !style.isMeters && style != .agents ? Color(nsColor: NSColor(hex: "#00E5FF") ?? .labelColor) : .primary)
                    .frame(width: size.width, height: size.height)
            }
            if style == .glyphLabel, let label {
                Text(label).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            }
        }
        .padding(.horizontal, 7)
        // One width for every chip, so the names beside them line up.
        .frame(width: width, height: 26)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Agents

struct AgentsPage: View {
    @Bindable var store: SettingsStore
    /// `hooks_doctor`'s per-provider report — read when the page shows
    /// and again whenever an install or removal settles.
    @ViewState private var doctor = HooksDoctorModel()
    /// `t3code_integration` — the T3 Code row shows once it says the
    /// database is on this Mac.
    @ViewState private var t3 = T3CodeModel()

    static let openChoices: [(value: String, label: String)] = [
        ("", "Automatic"), ("app", "Its app"), ("terminal", "Terminal"), ("vscode", "VS Code"),
    ]

    /// The providers split by whether the daemon found the agent's CLI on
    /// this Mac: the rows that can take an install, then the ones that
    /// cannot. A daemon that does not say keeps the row in the first list.
    nonisolated static func partition(_ providers: [String],
                                      detected: (String) -> Bool?) -> (found: [String], missing: [String]) {
        (providers.filter { detected($0) != false }, providers.filter { detected($0) == false })
    }

    var body: some View {
        let split = Self.partition(SettingsKey.providers) { store.hookDetected($0) }
        SettingGroup("Providers", note: "Hooks let each agent report its sessions. Each row's … menu reinstalls or removes them and picks what a click on a session opens.") {
            ForEach(split.found, id: \.self) { provider in
                AgentRow(store: store, provider: provider, doctor: doctor.entry(for: provider))
            }
            // Not a hook: T3 Code is read from its own database, by opt-in.
            T3CodeRow(model: t3, core: store.core)
            if !split.missing.isEmpty {
                // No CLI to hook into: out of the way, but Remove stays a
                // click away for hooks an old install left behind.
                DisclosureGroup("CLI not found (\(split.missing.count))") {
                    ForEach(split.missing, id: \.self) { provider in
                        AgentRow(store: store, provider: provider, doctor: doctor.entry(for: provider))
                    }
                }
                .help("No CLI for these agents in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin")
            }
        }
        .task {
            doctor.refresh(core: store.core)
            t3.refresh(core: store.core)
        }
        .onChange(of: store.hookBusy) { before, after in
            // An install, repair or removal just finished: read again.
            if after.count < before.count { doctor.refresh(core: store.core) }
        }
        .onChange(of: store.core.isLive) { _, live in
            guard live else { return }
            doctor.refresh(core: store.core)
            t3.refresh(core: store.core)
        }

        SettingGroup("Transcripts", note: "Reads each agent's local transcript files for token and cost figures.") {
            Provided(store, "transcript_monitoring.claude", "transcript_monitoring.codex",
                     "transcript_monitoring.gemini", "transcript_monitoring.pi") {
                MultiSelectMenu(store, "Watch transcripts",
                                subtitle: "Agents whose transcripts are read.",
                                keyPrefix: "transcript_monitoring",
                                options: SettingsKey.transcriptProviders.map { ($0, ProviderStyle.style(for: $0).name) },
                                providerTiles: true)
            }
        }

        SettingGroup("Asks") {
            SettingToggle(store, "Sub-agent asks", subtitle: "Sub-agents cannot be answered, so only main sessions alert by default.",
                          path: "subagent_asks_alert")
        }
    }
}

struct AgentRow: View {
    @Bindable var store: SettingsStore
    let provider: String
    /// What `hooks_doctor` found for this provider, when it has said.
    var doctor: HooksDoctorEntry? = nil

    private var style: ProviderStyle { ProviderStyle.style(for: provider, document: store.document) }
    private var status: String? { store.hookStatus(provider) }

    private var statusWord: String {
        switch status {
        case "ok": return "Live"
        case "missing": return "Not installed"
        case "stale": return "Quiet"
        case nil: return store.core.isLive ? "Unknown" : "Monitor offline"
        case let other?: return other.capitalized
        }
    }

    private var statusColor: Color {
        switch status {
        case "ok": return .green
        case "stale": return .orange
        case "missing": return Color(nsColor: .tertiaryLabelColor)
        default: return Color(nsColor: .quaternaryLabelColor)
        }
    }

    private var busy: Bool { store.hookBusy.contains(provider) }
    private var cliMissing: Bool { store.hookDetected(provider) == false }
    private var canInstall: Bool { store.core.isLive && !cliMissing && !busy }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderTile(style: style, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(style.name)
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusWord)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if busy {
                DelayedWait(size: 12)
            } else if status == "missing", !cliMissing {
                // Not hooked yet: the one thing to do, in reach.
                Button("Install") { store.installHooks(provider) }
                    .controlSize(.small)
                    .disabled(!canInstall)
            }
            actions
        }
        .padding(.vertical, 1)
    }

    /// The full-width line under the name — the last click's answer, the
    /// hook doctor's repair with its button, or its plain report — wrapping
    /// to two lines rather than cutting the doctor off mid-word.
    @ViewBuilder
    private var statusLine: some View {
        if let note = store.hookNotes[provider] {
            // The reply's own words, where the click happened.
            Text(note.text)
                .font(.caption)
                .foregroundStyle(note.isError ? Color.red : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        } else if let doctor, let reason = HooksDoctor.repairReason(doctor) {
            // Something to fix, and the fix beside it.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Repair") { store.installHooks(provider) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(!canInstall)
                    .help("Reinstall \(style.name)'s hooks the way JR-Bar writes them today")
            }
        } else if let doctor, let line = HooksDoctor.line(doctor) {
            Text(line)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("From the monitor's hook doctor")
        }
    }

    /// Reinstall, Remove and what a click opens, behind one … so the row
    /// fits the window.
    private var actions: some View {
        Menu {
            Button(status == "ok" ? "Reinstall Hooks" : "Install Hooks") { store.installHooks(provider) }
                .disabled(!canInstall)
            Button("Remove Hooks") { store.uninstallHooks(provider) }
                .disabled(!store.core.isLive || status == "missing" || busy)
            Divider()
            Picker("Clicks Open", selection: store.optionalString("session_open_preferences.\(provider)")) {
                ForEach(AgentsPage.openChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .disabled(!store.isProvided("session_open_preferences"))
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(cliMissing
              ? "No \(style.name) CLI found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin"
              : "Hooks, and what a click on one of \(style.name)'s sessions opens")
        .accessibilityLabel("\(style.name) options")
    }
}

// MARK: - Usage

struct UsagePage: View {
    @Bindable var store: SettingsStore

    var body: some View {
        SettingGroup("Menu bar meters", note: "The panel and Usage Center always show every provider with usage.") {
            Provided(store, "usage_graph_providers") {
                MultiSelectMenu(store, "Show meters for",
                                subtitle: "Providers that get a meter in Meters-style menu-bar icons.",
                                path: "usage_graph_providers",
                                options: SettingsKey.providers.map { ($0, ProviderStyle.style(for: $0).name) },
                                providerTiles: true)
            }
        }

        SettingGroup("Display", note: "The graphs live in the Usage Center (⌘U); this range is what it opens on. The panel's sparklines cover a week, or a month when the range is longer.") {
            SettingPicker(store, "Lead with", path: "usage_display_mode", options: [
                ("tokens", "Tokens"), ("cost", "Cost"),
            ], default: "tokens", segmented: true)
            SettingIntPicker(store, "Graph range", path: "usage_graph_days", options: [
                (7, "7 days"), (30, "30 days"), (90, "90 days"), (365, "A year"),
            ], default: 7)
            SettingRow("Graphs", subtitle: "Per-provider history, cost and pace, for the range above.") {
                Button("Usage Center…") { store.onOpenUsageCenter?() }
                    .help("The graphs live in the Usage Center (⌘U)")
            }
        }

        SettingGroup("Claude") {
            Provided(store, "claude_plan_limits_enabled") {
                Toggle(isOn: Binding(
                    get: { store.document.bool("claude_plan_limits_enabled") ?? false },
                    // Consent-stamped write: the consent version lands
                    // first so a consent-aware core keeps the enable.
                    set: { on in store.setClaudePlanLimits(on) }
                )) {
                    SettingLabel(title: "Read plan limits",
                                 subtitle: "Reads your subscription's official 5-hour and 7-day windows from Anthropic. Off until you opt in.")
                }
                .settingRowStyle()
            }
        }

        SettingGroup("Quota alerts") {
            SettingToggle(store, "Alert at thresholds", subtitle: "A nudge, then a warning, as a usage window fills.",
                          path: "quota_alerts_enabled")
            Provided(store, "quota_alert_thresholds") {
                ThresholdRow(store: store)
            }
        }

        SettingGroup("History") {
            SettingToggle(store, "Keep history", subtitle: "Stores usage samples locally so graphs can look back.", path: "capacity_history_enabled")
            SettingIntPicker(store, "Keep for", path: "capacity_history_retention_days", options: [
                (1, "1 day"), (7, "7 days"), (30, "30 days"), (90, "90 days"),
            ], default: 7)
                .disabled(!(store.document.bool("capacity_history_enabled") ?? false))
        }
    }
}

/// `quota_alert_thresholds`: a nudge and a warning, as two steppers.
struct ThresholdRow: View {
    @Bindable var store: SettingsStore

    private var thresholds: [Double] {
        let values = store.document.array("quota_alert_thresholds")?.compactMap(\.doubleValue) ?? []
        return values.count >= 2 ? Array(values.prefix(2)) : [90, 95]
    }

    private func binding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { Int(thresholds[index].rounded()) },
            set: { value in
                var values = thresholds
                values[index] = Double(value)
                store.set("quota_alert_thresholds", .array(values.sorted().map(JSONValue.number)))
            }
        )
    }

    var body: some View {
        LabeledContent("Thresholds") {
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    ValueText(text: "Nudge at \(binding(0).wrappedValue)%", width: 100)
                    Stepper("", value: binding(0), in: 50...99).labelsHidden()
                }
                HStack(spacing: 4) {
                    ValueText(text: "Warn at \(binding(1).wrappedValue)%", width: 92)
                    Stepper("", value: binding(1), in: 50...100).labelsHidden()
                }
            }
        }
        .disabled(!(store.document.bool("quota_alerts_enabled") ?? false))
    }
}

// MARK: - Devices & Screen Bar

struct DevicesPage: View {
    @Bindable var store: SettingsStore

    static let displayModes: [(value: String, label: String)] = [
        ("agent", "Agent status"), ("battery", "Battery"), ("studio", "Studio program"), ("quota_runway", "Quota runway"),
    ]

    var body: some View {
        let devices = store.deviceEntries
        if devices.isEmpty {
            SettingGroup("Devices") {
                if store.hasDocument {
                    Text("No SidePulse hardware yet — plug in a Pro or Dot and it shows up here.").foregroundStyle(.secondary)
                } else {
                    Text("Devices appear once the monitor is connected.").foregroundStyle(.secondary)
                }
            }
        }
        ForEach(devices) { device in
            DeviceCard(store: store, device: device)
        }

        CalibrationProfilesSection(store: store)

        SettingGroup("Pro & Dot", note: "The role is what the Dot is for; the link is whether the monitor drives it at all.") {
            SettingToggle(store, "Dot follows strip", subtitle: "The Dot mirrors the Pro instead of rendering its own; which cue is the role below.",
                          path: "devices_linked", default: true)
            SettingSlider(store, "Dot brightness", subtitle: "Two nearby LEDs read much brighter than eight across a desk. The alert beacon is never dimmed.",
                          path: "linked_dot_scale", in: 0.05...1.0, step: 0.05, default: 0.3) { "\(Int(($0 * 100).rounded()))%" }
                .disabled(!(store.document.bool("devices_linked") ?? true))
            DotRoleControls(store: store, inDeviceCard: false)
        }

        CreatorMicroCard(store: store)

        StreamDeckCard(store: store)

        SettingGroup(note: "The gap is the span treated as the notch, between the two risers; the wing is each stroke's reach beyond it. Automatic measures the notch and Alcove; manual values are points and always win.") {
            ScreenBarCard(store: store)
        } header: {
            let bar = store.stateDevice("screen-bar")
            SettingsGroupHeader(title: "Screen Bar", symbol: "rectangle.topthird.inset.filled",
                                tint: Color(nsColor: .systemTeal),
                                pill: bar.map { $0.enabled == true ? "Shown" : "Hidden" },
                                pillTint: bar?.enabled == true ? .green : .secondary)
        }
    }
}

struct DeviceCard: View {
    @Bindable var store: SettingsStore
    let device: SettingsStore.DeviceEntry

    private var state: CoreDevice? { store.stateDevice(device.id) }
    private var pinOptions: [(value: String, label: String)] {
        [("", "All agents")] + SettingsKey.providers.map { ($0, ProviderStyle.style(for: $0).name) }
    }

    var body: some View {
        SettingGroup {
            if state?.isPresent == true {
                // The age ticks between core pushes; a coarse clock is
                // enough for "written 40 s ago".
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    SettingRow("Right now", subtitle: DeviceHealthLine.describe(
                        device: state, surface: surface, now: context.date)) { EmptyView() }
                }
            }
            SettingPicker(store, "Display", path: "\(device.prefix).led_display", options: DevicesPage.displayModes, default: "agent")
            SettingSlider(store, "Brightness", path: "\(device.prefix).brightness", in: 0...255, step: 1, default: 255) { "\(Int(($0 / 255 * 100).rounded()))%" }
            SettingToggle(store, "Auto-brightness", subtitle: "Follows the display's brightness: dim in a dark room, bright in daylight.",
                          path: "\(device.prefix).auto_brightness_enabled")
            Provided(store, "\(device.prefix).provider_pin") {
                Picker(selection: store.optionalString("\(device.prefix).provider_pin")) {
                    ForEach(pinOptions, id: \.value) { Text($0.label).tag($0.value) }
                } label: {
                    SettingLabel(title: "Pin to", subtitle: "Shows only that provider's sessions; rests dark otherwise.")
                }
                .pickerStyle(.menu)
            }
            Provided(store, "\(device.prefix).signal_policy") {
                Toggle(isOn: Binding(
                    get: { store.document.string(SettingsPath("\(device.prefix).signal_policy")) == "asks_only" },
                    set: { store.set("\(device.prefix).signal_policy", $0 ? .string("asks_only") : .null) }
                )) {
                    SettingLabel(title: "Asks only", subtitle: "Mutes courtesy signals; agent status, asks and low battery still show.")
                }
                .settingRowStyle()
            }
            Provided(store, "\(device.prefix).blend_mode") {
                Picker(selection: store.optionalString("\(device.prefix).blend_mode")) {
                    Text("Same as Lighting").tag("")
                    Divider()
                    ForEach(LightingPage.blendModes, id: \.value) { Text($0.label).tag($0.value) }
                } label: {
                    SettingLabel(title: "Blend", subtitle: blendSubtitle)
                }
                .pickerStyle(.menu)
            }
            SettingRow("Colour calibration", subtitle: calibrationSummary) {
                Button("Calibrate…") { store.calibrating = device.id }
                    .disabled(!store.core.isLive)
            }
            if device.kind == "dot" {
                DotRoleControls(store: store, inDeviceCard: true)
            }
        } header: {
            SettingsGroupHeader(title: device.name,
                                symbol: device.kind == "dot" ? "circle.grid.2x1.fill" : "light.beacon.max.fill",
                                tint: SettingsStore.Page.devices.tint,
                                pill: state.map { $0.isPresent ? "Connected" : ($0.error ?? "Not connected") },
                                pillTint: state?.isPresent == true ? .green : .orange,
                                trailing: device.kind == "dot" ? "2 LEDs" : "8 LEDs")
        }
    }

    private var calibrationSummary: String {
        SettingsStore.calibrationSummary(document: store.document, prefix: device.prefix)
    }

    /// The program this device was last sent, from the `lights` push.
    private var surface: CoreLightSurface? {
        guard let state else { return nil }
        return DeviceHealthLine.surface(for: state, lights: store.core.lights, devices: store.core.devices)
    }

    /// The per-device blend's note: what it does, and the case for it —
    /// on eight discrete LEDs per-agent blocks read cleanly even while
    /// the Screen Bar keeps Smooth, where they would turn to mud.
    private var blendSubtitle: String {
        let mode = store.document.string(SettingsPath("\(device.prefix).blend_mode"))
        guard let mode, let entry = LightingPage.blendModes.first(where: { $0.value == mode }) else {
            let global = store.document.string("colors.blend_mode") ?? "color_blend"
            let label = LightingPage.blendModes.first { $0.value == global }?.label ?? global
            return "Follows Settings › Lighting (\(label)). A strip can take its own — Everyone reads cleanly on eight LEDs while the band stays Smooth."
        }
        return entry.detail
    }
}

extension SettingsStore {
    /// The one-line "Colour calibration" summary: gains and glow always,
    /// brightness when it is not the full drive -- the sheet edits all
    /// three, so a dimmed-by-calibration device is not "Uncalibrated".
    static func calibrationSummary(document: SettingsDocument, prefix: String) -> String {
        let r = document.double(SettingsPath("\(prefix).red_gain")) ?? 1
        let g = document.double(SettingsPath("\(prefix).green_gain")) ?? 1
        let b = document.double(SettingsPath("\(prefix).blue_gain")) ?? 1
        let glow = document.double(SettingsPath("\(prefix).resting_glow")) ?? 0
        let brightness = document.double(SettingsPath("\(prefix).brightness")) ?? 255
        if r == 1, g == 1, b == 1, glow == 0, brightness >= 255 { return "Uncalibrated" }
        var summary = String(format: "R %.2f · G %.2f · B %.2f · glow %d%%", r, g, b, Int((glow * 100).rounded()))
        if brightness < 255 {
            summary += String(format: " · %d%%", Int((brightness / 255 * 100).rounded()))
        }
        return summary
    }
}

/// A device card's "Right now" line — blink(1)'s device status, for a
/// light that says "Connected" and nothing else: why it is lit, whether
/// the last write failed, how long ago the monitor last wrote it (the
/// firmware restarts on every write, and a keepalive rewrites it), the
/// program's size against the firmware's 512-byte / 20-line budget, the
/// firmware's own verdict when it would refuse the text, and the drive
/// the device is actually at. nil while the device is away — the header
/// already says so.
enum DeviceHealthLine {
    /// The `lights` surface a device plays: the Dot's own; a strip's own
    /// `hardware:<id>` when it is not the first; the first connected
    /// strip's `hardware`.
    static func surface(for device: CoreDevice, lights: CoreLights?, devices: [CoreDevice]) -> CoreLightSurface? {
        guard let lights else { return nil }
        if device.kind == "dot" { return lights.dot }
        if let own = lights.surfaces["hardware:\(device.id)"] { return own }
        let first = devices.first { $0.kind == "pro" && $0.isPresent }
        return first?.id == device.id ? lights.hardware : nil
    }

    static func describe(device: CoreDevice?, surface: CoreLightSurface?, now: Date) -> String? {
        guard let device, device.isPresent else { return nil }
        var parts: [String] = []
        if let why = surface?.why, !why.isEmpty {
            let words = why.replacingOccurrences(of: "_", with: " ")
            parts.append(words.prefix(1).uppercased() + words.dropFirst())
        }
        if let cue = surface?.cue?.name, !cue.isEmpty { parts.append("playing \(cue)") }
        if let error = device.error, !error.isEmpty {
            parts.append("the last write failed (\(error.replacingOccurrences(of: "_", with: " ")))")
        }
        if let written = device.lastWrite {
            parts.append("written \(age(now.timeIntervalSince1970 - written)) ago")
        } else {
            parts.append("not written since the monitor started")
        }
        if let program = surface?.program, !program.isEmpty {
            let analysis = LEDSStudioAnalysis(program)
            parts.append("\(analysis.lines) line\(analysis.lines == 1 ? "" : "s"), \(analysis.bytes) of \(LEDSLimits.maxProgramBytes) bytes")
            let verdict = device.kind == "dot" ? analysis.dot : analysis.strip
            if let error = verdict.error { parts.append(error.description) }
        }
        if let drive = surface?.brightness {
            parts.append("driven at \(Int((min(1, max(0, drive)) * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    /// "4 s", "12 min", "3 h" — a clock step behind is harmless.
    static func age(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return "\(Int(seconds / 3600)) h"
    }
}

/// The Creator Micro 2: the three switches of `deck-controls.json`, what
/// the core says about the pad, and the door to the Control Center, where
/// everything else about it is done.
struct CreatorMicroCard: View {
    @Bindable var store: SettingsStore

    private var deck: DeckState? { store.deck }
    private var device: DeckDevice? { deck?.device }
    private var settings: DeckSettings { deck?.settings ?? DeckSettings() }
    private var live: Bool { store.core.isLive && deck != nil }

    private var statusColor: Color {
        guard let device, device.connected else { return .secondary }
        if device.hasConflict { return .red }
        return device.approved ? .green : .orange
    }

    private var statusText: String {
        guard store.core.isLive else { return "Monitor not connected" }
        guard deck != nil else { return "Not in this version" }
        guard let device, device.connected else { return "Not connected" }
        var parts: [String] = []
        if device.hasConflict { parts.append(DeckDevice.conflictText) }
        else if !device.approved { parts.append("Connected, needs approval") }
        else { parts.append("Connected") }
        if let transport = device.transport { parts.append(transport.label) }
        if let serial = device.serial { parts.append(serial) }
        return parts.joined(separator: " · ")
    }

    /// A layer's owner picker: reads the daemon-published settings, and a
    /// change rewrites the whole `layer_owners` list (the daemon replaces
    /// it, it does not merge). "jrbar" rows are dropped — unassigned means
    /// ours; the daemon keeps layer 1 ours no matter what is sent.
    private func layerOwnerBinding(_ layer: Int) -> Binding<String> {
        Binding(
            get: { settings.owner(forLayer: layer) },
            set: { owner in
                var owners = (settings.layerOwners ?? []).filter { $0.layer != layer }
                if owner != "jrbar" { owners.append(DeckLayerOwner(layer: layer, owner: owner)) }
                owners.sort { $0.layer < $1.layer }
                let core = store.core
                Task { @MainActor in
                    _ = try? await core.deckSetSettings(
                        layerOwners: owners.map { (layer: $0.layer, owner: $0.owner) })
                }
            })
    }

    private func set(enabled: Bool? = nil, sessionMode: Bool? = nil, analogEnabled: Bool? = nil) {
        let core = store.core
        if enabled == true {
            // The toggle used to write deck-controls.json and stop there —
            // the HID service only runs once the pad is approved, so
            // enabling probes and approves in one step. Zero pads gets the
            // plug-it-in line on the row; several leaves the pick to the
            // Control Center's approve path.
            Task { @MainActor in
                let reply = try? await core.deckApproveDevice()
                guard let reply, reply.ok else {
                    let code = reply?.error?.code ?? ""
                    let text: String
                    switch code {
                    case "no_device":
                        text = "No Creator Micro 2 found. If Codex Micro is open, remove its device connection there first, then plug the pad in"
                    case "ambiguous_device_identity", "device_identity_unavailable":
                        text = "More than one pad found — approve it in the Control Center"
                    default:
                        text = reply?.error?.message ?? "Approval failed"
                    }
                    store.noteDeck(text, isError: true)
                    return
                }
                store.noteDeck("Approved and started", isError: false)
                _ = try? await core.deckSetSettings(enabled: true)
            }
            return
        }
        Task { @MainActor in
            _ = try? await core.deckSetSettings(enabled: enabled, sessionMode: sessionMode, analogEnabled: analogEnabled)
            if enabled == false {
                // Off means off: the output service is torn down, not just
                // gated out of writes. The approval survives the switch.
                _ = try? await core.deckDisable()
            }
        }
    }

    var body: some View {
        SettingGroup(note: "Thirteen session keys per bank, a dial and a joystick with explicit mappings. Pins, banks, the rail, input check and the keymap live in the Control Center; the monitor owns the device.") {
            Toggle(isOn: Binding(get: { settings.enabled }, set: { set(enabled: $0) })) {
                SettingLabel(title: "Enable Creator Micro 2",
                             subtitle: "The monitor drives the approved pad's per-key colours and listens to its inputs.")
            }
            .disabled(!live)
            .settingRowStyle()
            Toggle(isOn: Binding(get: { settings.sessionMode }, set: { set(sessionMode: $0) })) {
                SettingLabel(title: "Session keys",
                             subtitle: "The thirteen keys follow the session board; only the dial, joystick and analog sectors take explicit mappings.")
            }
            .disabled(!live || !settings.enabled)
            .settingRowStyle()
            Toggle(isOn: Binding(get: { settings.analogEnabled }, set: { set(analogEnabled: $0) })) {
                SettingLabel(title: "Analog joystick sectors",
                             subtitle: "Sectors 1–4 (AG20–AG23) count as inputs and can carry mappings in the Control Center.")
            }
            .disabled(!live || !settings.enabled)
            .settingRowStyle()
            LabeledContent {
                VStack(alignment: .trailing, spacing: 3) {
                    StatusPill(statusText, tint: statusColor)
                    // The toggle's own answer, where the click happened.
                    if let note = store.deckNote {
                        Text(note.text)
                            .font(.caption)
                            .foregroundStyle(note.isError ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .transition(.opacity)
                    }
                }
            } label: {
                Text("Status")
            }
            if let deck {
                DisclosureRow("Details") {
                    LabeledContent("Keymap") {
                        Text(deck.keymap.label).foregroundStyle(deck.keymap.needsRecovery ? .orange : .secondary)
                    }
                    LabeledContent("Compact rail") {
                        Text(deck.rail.edge.label).foregroundStyle(.secondary)
                    }
                    LabeledContent("Sessions") {
                        Text("\(deck.keySlots.filter { !$0.isEmpty }.count) of 13 on this bank · \(deck.banks.title)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Board scope") {
                        Text(deck.scope == "automatic" ? "Automatic — all providers"
                             : ProviderStyle.style(for: deck.scope).name)
                            .foregroundStyle(.secondary)
                    }
                    if let receipt = deck.device?.receipt {
                        LabeledContent("Last receipt") {
                            Text(receipt.text).foregroundStyle(receipt.isProblem ? .orange : .secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                if !deck.keymap.layers.isEmpty {
                    DisclosureRow("Layers", subtitle: "Who each hardware layer belongs to. Layer 1 is always JR-Bar's; a layer handed to Codex, Claude or other apps is left to that writer instead of fought over.") {
                        ForEach(deck.keymap.layers.sorted(by: { $0.layer < $1.layer })) { layer in
                            if layer.layer == 0 {
                                LabeledContent("Layer 1") {
                                    Text("JR-Bar — the auto layer")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Picker("Layer \(layer.layer + 1)", selection: layerOwnerBinding(layer.layer)) {
                                    Text("JR-Bar").tag("jrbar")
                                    ForEach(SettingsKey.providers, id: \.self) { provider in
                                        Text(ProviderStyle.style(for: provider).name).tag(provider)
                                    }
                                    Divider()
                                    Text("Other apps").tag("everything")
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            SettingRow("Control Center", subtitle: "Pins, banks, the rail, input check and the keymap.") {
                Button("Control Center…") { store.onOpenControlCenter?() }
            }
        } header: {
            SettingsGroupHeader(title: "Creator Micro 2", symbol: "keyboard.fill",
                                tint: Color(nsColor: .systemIndigo),
                                pill: device?.approved == false && device?.connected == true
                                    ? "Approve it in the Control Center" : nil,
                                pillTint: .orange)
        }
    }
}

struct ScreenBarCard: View {
    @Bindable var store: SettingsStore
    /// The camera hold is the app's own: the band is drawn here, and the
    /// camera reading is the app's too — the notch island's poll, so the
    /// row follows `ScreenBarCameraHold`.
    @AppStorage(ScreenBarController.stillOnCameraDefaultsKey) private var stillOnCamera = true
    /// The video guard is the app's too: it reads the now-playing app and
    /// the frontmost window, neither of which the daemon sees.
    @AppStorage(ScreenBarController.hideOverVideoDefaultsKey) private var hideOverVideo = true

    var body: some View {
        SettingRow("Right now", subtitle: rightNow) {
            EmptyView()
        }
        SettingToggle(store, "Show Screen Bar", subtitle: "The light band under the notch.", path: "virtual_status_device_enabled", default: true)
        SettingToggle(store, "Follow Alcove", subtitle: "Match Alcove's capsule width so a live activity never outgrows the band.", path: "screen_bar_follow_alcove", default: true)
        Provided(store, "screen_bar_show_in_full_screen") {
            Picker(selection: Binding(
                get: { ScreenBarFullScreen(shows: store.document.bool("screen_bar_show_in_full_screen") ?? true,
                                           hideOverVideo: hideOverVideo) },
                set: { mode in
                    store.set("screen_bar_show_in_full_screen", .bool(mode != .hidden))
                    if mode != .hidden { hideOverVideo = mode == .notOverVideo }
                }
            )) {
                ForEach(ScreenBarFullScreen.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                SettingLabel(title: "In full screen", subtitle: ScreenBarFullScreen(
                    shows: store.document.bool("screen_bar_show_in_full_screen") ?? true,
                    hideOverVideo: hideOverVideo).detail)
            }
            .pickerStyle(.menu)
        }
        ScreenBarHiddenAppsRow(store: store)
        SettingToggle(store, "Notch wings", subtitle: "Status slots beside the notch: sessions on the left, the headline meter on the right.", path: "screen_bar_notch_wings", default: true)
        SettingPicker(store, "Notch shape", subtitle: notchShapeSubtitle,
                      path: "screen_bar_notch_profile",
                      options: NotchProfile.allCases.map { ($0.rawValue, $0.title) },
                      default: NotchProfile.auto.rawValue)
        if NotchProfile(setting: store.document.string("screen_bar_notch_profile")) == .custom {
            SettingSlider(store, "Corner radius", subtitle: "The tray's bottom corners, in points. Every notched MacBook measures about 8.",
                          path: "screen_bar_notch_corner", in: 4...16, step: 0.5,
                          default: Double(NotchProfile.standardCornerRadius)) { SettingsStore.points($0) }
        }
        SettingToggle(store, "Mirror hardware strip", subtitle: "Play the strip's program on its clock; off, the bar renders its own display.", path: "link_screen_bar_to_hardware", default: true)
        Toggle(isOn: $stillOnCamera) {
            SettingLabel(title: "Hold still on camera",
                         subtitle: ScreenBarCameraHold.subtitle(cameraReadable: ScreenBarLiveStatus.shared.cameraReadable))
        }
        .disabled(!ScreenBarLiveStatus.shared.cameraReadable)
        .settingRowStyle()
        DisclosureRow("Advanced", subtitle: "Phase, geometry and the band's dim floor.") {
            SettingSlider(store, "Phase nudge", subtitle: "Shift the bar against the strip if the two are visibly out of step. Positive holds the bar back.",
                          path: "screen_bar_phase_offset_ms", in: -500...500, step: 10, default: 0) { "\(Int($0)) ms" }
                .disabled(!(store.document.bool("link_screen_bar_to_hardware") ?? true))
            NullableSlider(store: store, title: "Gap width", path: "screen_bar_gap_width", range: 120...400, fallback: 180)
            NullableSlider(store: store, title: "Wing length", path: "screen_bar_wing_length", range: 0...80, fallback: 14)
            SettingSlider(store, "Minimum glow", subtitle: "The band's dim floor; zero is pitch black.",
                          path: "screen_bar_min_glow", in: 0...1, default: 0.25, format: SettingsStore.percent)
        }
        SettingRow("Colour calibration", subtitle: screenBarCalibrationSummary) {
            Button("Calibrate…") { store.calibrating = "virtual:status-bar" }
                .disabled(!store.core.isLive)
        }
    }

    /// The "Right now" line: which clock the band is on, whether it
    /// turned a program away, and why it might be still.
    private var rightNow: String {
        let status = ScreenBarLiveStatus.shared
        let core = store.core
        return ScreenBarSourceLine.describe(
            live: core.isLive,
            mirrorSetting: store.document.bool("link_screen_bar_to_hardware") ?? true,
            stripPresent: core.devices.contains { $0.kind == "pro" && $0.isPresent },
            phaseOffsetMs: store.document.double("screen_bar_phase_offset_ms"),
            why: core.lights?.screenBar?.why,
            rejection: status.rejection,
            motionNote: status.motionNote,
            followingAlcove: status.followingAlcove,
            steppedAsideForVideo: status.steppedAsideForVideo,
            cue: core.lights?.screenBar?.cue?.name,
            offlineFeed: status.offlineFeed)
    }

    /// The picker's note: what the machine reports and what the tray's
    /// corners follow. The radius itself is measured — ~8 pt on every
    /// notched MacBook — so the named models agree; the picker is for
    /// the odd panel, not for flavour.
    private var notchShapeSubtitle: String {
        "The tray's bottom corners copy this notch's radius. Detected: \(NotchProfile.machineFamily)."
    }

    private var screenBarCalibrationSummary: String {
        guard let index = store.document.deviceIndex(id: "virtual:status-bar") else {
            return "Uncalibrated"
        }
        return SettingsStore.calibrationSummary(document: store.document, prefix: "devices.\(index)")
    }
}

/// "Hold still on camera" and what it leans on. The band has no camera
/// reading of its own: it borrows the notch's sensor monitor, which now
/// runs for whichever surface needs it — the island's dots, the Screen
/// Bar's ears or the presence report — not only under the island. The
/// row greys out only while nothing is reading, or while the Mic &
/// camera indicators are switched off, so it never reads On for a hold
/// that could not engage.
enum ScreenBarCameraHold {
    /// Whether the camera hold can see a camera: the sensor monitor is
    /// reading, and the indicators it serves are switched on.
    static func readable(monitorReading: Bool, indicatorsOn: Bool) -> Bool {
        monitorReading && indicatorsOn
    }

    static func subtitle(cameraReadable: Bool) -> String {
        cameraReadable
            ? "While a camera is live the band stops moving — nothing pulses beside the lens or in your glasses, and an ask stays a steady amber."
            : "Needs a camera reading: turn on Mic & camera indicators under Utilities › Notch."
    }
}

/// Where the band goes in full screen: the daemon's
/// `screen_bar_show_in_full_screen` plus the app's own video guard, as one
/// choice. A band over a full-screen movie reads as a glitch (the daemon's
/// own default says so); over a full-screen terminal it is the point.
enum ScreenBarFullScreen: CaseIterable, Hashable {
    case hidden, notOverVideo, always

    init(shows: Bool, hideOverVideo: Bool) {
        self = !shows ? .hidden : hideOverVideo ? .notOverVideo : .always
    }

    var title: String {
        switch self {
        case .hidden: return "Hidden"
        case .notOverVideo: return "Shown, not over video"
        case .always: return "Always shown"
        }
    }

    var detail: String {
        switch self {
        case .hidden: return "Full-screen apps have the top of the screen to themselves."
        case .notOverVideo: return "Over full-screen apps, but it steps aside while the app in front is playing a video."
        case .always: return "Over every full-screen app, videos included."
        }
    }
}

/// A number that may be JSON null (automatic): a checkbox and, when manual, a slider.
struct NullableSlider: View {
    @Bindable var store: SettingsStore
    let title: String
    var subtitle: String? = nil
    let path: String
    let range: ClosedRange<Double>
    let fallback: Double

    var body: some View {
        Provided(store, path) {
            LabeledContent {
                HStack(spacing: 10) {
                    Toggle("Automatic", isOn: Binding(
                        get: { store.isNull(path) },
                        set: { auto in store.set(path, auto ? .null : .number(fallback)) }
                    ))
                    .toggleStyle(.checkbox)
                    Slider(value: Binding(get: { store.document.double(SettingsPath(path)) ?? fallback },
                                          set: { store.set(path, .number($0.rounded()), throttled: true) }), in: range)
                        .frame(width: 120)
                        .disabled(store.isNull(path))
                    ValueText(text: store.isNull(path) ? "auto" : SettingsStore.points(store.document.double(SettingsPath(path)) ?? fallback), width: 48)
                }
            } label: {
                SettingLabel(title: title, subtitle: subtitle)
            }
        }
    }
}
