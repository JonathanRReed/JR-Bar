import JRBarUI
import JRBarCore
import SwiftUI

// MARK: - General

struct GeneralPage: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })) {
                SettingLabel(title: "Launch at login", subtitle: store.launchAtLoginError ?? "Registers JR-Bar with the system so it starts with your Mac.")
            }
            MenuBarStylePicker(store: store)
            SettingToggle(store, "Show tips", subtitle: "Occasional hints in the panel about what the light means.", path: "tips_enabled", default: true)
        }

        Section("Screen Bar") {
            SettingToggle(store, "Show the Screen Bar", subtitle: "The light band under the notch.", path: "virtual_status_device_enabled", default: true)
            SettingToggle(store, "Follow Alcove", subtitle: "Match Alcove's capsule width so an expanded live activity never outgrows the band.", path: "screen_bar_follow_alcove", default: true)
            SettingToggle(store, "Show in full screen", subtitle: "Keep the band over full-screen apps and videos.", path: "screen_bar_show_in_full_screen")
            SettingToggle(store, "Link to the hardware strip", subtitle: "The Screen Bar plays the same animation the SidePulse is running, phase-locked.", path: "link_screen_bar_to_hardware", default: true)
        }

        Section("Brightness") {
            SettingSlider(store, "Global brightness", subtitle: "One dial over every surface; composes with each device's own brightness.",
                          path: "global_brightness_scale", in: 0.05...1.0, default: 1.0, format: SettingsStore.percent)
        }

        Section {
            LabeledContent {
                Button("Check for Updates…") { store.checkForUpdates() }
                    .disabled(!store.updaterAvailable)
                    .help(store.updaterHint ?? "Look for a newer JR-Bar now")
            } label: {
                SettingLabel(title: "Software Update", subtitle: softwareUpdateSubtitle)
            }
            Toggle(isOn: Binding(get: { store.automaticUpdateChecks }, set: { store.setAutomaticUpdateChecks($0) })) {
                SettingLabel(title: "Automatically check for updates",
                             subtitle: store.updaterHint ?? "Sparkle looks for a newer JR-Bar in the background and asks before installing.")
            }
            .disabled(!store.updaterAvailable)
            Picker("Update channel", selection: $store.updateChannel) {
                Text("Stable").tag("stable")
                Text("Beta").tag("beta")
            }
            .pickerStyle(.menu)
            .fixedSize()
        } footer: {
            SectionNote("Updates are checked by the app, not the core. The channel is remembered on this Mac.")
        }
        .onAppear { store.refreshUpdater() }
    }

    private var softwareUpdateSubtitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
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
        return shown.prefix(StatusIconRenderer.maxMeters).map { provider in
            StatusItemController.meter(for: provider.id,
                                       fraction: UsageCenterStore.primaryWindow(of: provider).flatMap { $0.usedPct }.map { $0 / 100 },
                                       approximate: provider.isDerived)
        }
    }

    private var overflow: Int {
        let preferred = store.document.strings("usage_graph_providers") ?? []
        let shown = AppDelegate.meteredProviders(preferred: preferred, usage: store.core.isLive ? store.core.usage : [])
        return max(0, shown.count - StatusIconRenderer.maxMeters)
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                SettingLabel(title: "Menu bar icon", subtitle: "What the status item shows at a glance.")
                VStack(spacing: 0) {
                    ForEach(Array(StatusIconStyle.allCases.enumerated()), id: \.element) { index, style in
                        if index > 0 { Divider().opacity(0.5) }
                        MenuBarStyleRow(style: style,
                                        selected: current == style,
                                        meters: meters,
                                        overflow: overflow,
                                        label: labelText) {
                            store.menuBarIconStyle = style.rawValue
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
        }
    }

    private var labelText: String? {
        guard store.core.isLive, let aggregate = store.core.state?.aggregate else {
            return StatusIconRenderer.label(active: 2, needsYou: 1, ready: 0)
        }
        return StatusIconRenderer.label(active: aggregate.active, needsYou: aggregate.needsYou, ready: aggregate.ready)
            ?? "quiet"
    }
}

/// One row of the picker: a radio mark, the preview on its own dark strip,
/// and the style's name and sentence.
struct MenuBarStyleRow: View {
    let style: StatusIconStyle
    let selected: Bool
    let meters: [StatusMeter]
    let overflow: Int
    let label: String?
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.6))
                MenuBarPreview(style: style, meters: meters, overflow: overflow, label: label)
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

/// The status item as it would look, drawn by the same renderer the menu
/// bar uses, on a strip that reads as a menu bar in either appearance.
struct MenuBarPreview: View {
    let style: StatusIconStyle
    let meters: [StatusMeter]
    let overflow: Int
    let label: String?
    @Environment(\.colorScheme) private var scheme

    /// Wide enough for the roomiest preview (the label style's "1 ask · 2
    /// working", which is as long as `StatusIconRenderer.label` gets), so
    /// every row's text starts at the same x and none of them truncates.
    static let width: CGFloat = 152

    private var spec: StatusIconSpec {
        StatusIconSpec(style: style,
                       ringFraction: meters.first?.fraction ?? 0.42,
                       tintHex: "#00E5FF",
                       meters: style.isMeters ? meters : [],
                       overflow: style.isMeters ? overflow : 0,
                       dot: style.isMeters ? .working : .idle,
                       phase: 0.5)
    }

    var body: some View {
        let image = StatusIconRenderer.shared.image(for: spec)
        let size = StatusIconRenderer.size(for: spec)
        HStack(spacing: 5) {
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .foregroundStyle(image.isTemplate && !style.isMeters ? Color(nsColor: NSColor(hex: "#00E5FF") ?? .labelColor) : .primary)
                .frame(width: size.width, height: size.height)
            if style == .glyphLabel, let label {
                Text(label).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            }
        }
        .padding(.horizontal, 7)
        // One width for every chip, so the names beside them line up.
        .frame(width: Self.width, height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Agents

struct AgentsPage: View {
    @Bindable var store: SettingsStore

    static let openChoices: [(value: String, label: String)] = [
        ("", "Automatic"), ("app", "App"), ("terminal", "Terminal"), ("vscode", "VS Code"),
    ]

    var body: some View {
        Section {
            ForEach(SettingsKey.providers, id: \.self) { provider in
                AgentRow(store: store, provider: provider)
            }
        } header: {
            Text("Providers")
        } footer: {
            SectionNote("Hooks let each agent report its sessions to the core. \"Open in\" picks what is raised when you click a session.")
        }

        Section("Transcripts") {
            ForEach(SettingsKey.transcriptProviders, id: \.self) { provider in
                SettingToggle(store, "Watch \(ProviderStyle.style(for: provider).name) transcripts",
                              subtitle: "Reads the local transcript files for token and cost figures.",
                              path: "transcript_monitoring.\(provider)")
            }
        }

        Section("Asks") {
            SettingToggle(store, "Alert for sub-agent asks", subtitle: "Sub-agents cannot be answered directly; by default only main sessions ring the Ask signal.",
                          path: "subagent_asks_alert")
        }
    }
}

struct AgentRow: View {
    @Bindable var store: SettingsStore
    let provider: String

    private var style: ProviderStyle { ProviderStyle.style(for: provider) }
    private var status: String? { store.hookStatus(provider) }

    private var statusWord: String {
        switch status {
        case "ok": return "Installed"
        case "missing": return "Not installed"
        case "stale": return "Needs reinstall"
        case nil: return store.core.isLive ? "Unknown" : "Core offline"
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

    var body: some View {
        HStack(spacing: 10) {
            ProviderTile(style: style, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(style.name)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusWord).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Open in").font(.callout).foregroundStyle(.tertiary)
            Picker("Open in", selection: store.optionalString("session_open_preferences.\(provider)")) {
                ForEach(AgentsPage.openChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 104)
            .disabled(!store.isProvided("session_open_preferences"))
            .help("What a click on one of this provider's sessions raises")
            Button { store.core.installHooks(providers: [provider]) } label: {
                Text(status == "ok" ? "Reinstall" : "Install").frame(width: 58)
            }
            .controlSize(.small)
            .disabled(!store.core.isLive)
            Button { store.core.uninstallHooks(providers: [provider]) } label: {
                Text("Remove").frame(width: 52)
            }
            .controlSize(.small)
            .disabled(!store.core.isLive || status == "missing")
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Usage

struct UsagePage: View {
    @Bindable var store: SettingsStore

    private let columns = [GridItem(.adaptive(minimum: 150), alignment: .leading)]

    var body: some View {
        Section {
            Provided(store, "usage_graph_providers") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(SettingsKey.providers, id: \.self) { provider in
                        let style = ProviderStyle.style(for: provider)
                        Toggle(isOn: store.listMember("usage_graph_providers", provider)) {
                            HStack(spacing: 6) {
                                ProviderTile(style: style, size: 16)
                                Text(style.name)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Show in the panel")
        }

        Section {
            SettingPicker(store, "Lead with", path: "usage_display_mode", options: [
                ("tokens", "Tokens"), ("cost", "Cost"), ("percent", "Percent"),
            ], default: "tokens", segmented: true)
                .fixedSize()
            SettingIntPicker(store, "Graph range", path: "usage_graph_days", options: [
                (1, "Today"), (7, "7 days"), (30, "30 days"), (90, "90 days"), (365, "A year"),
            ], default: 7)
            LabeledContent {
                Button("Open Usage Center") { store.onOpenUsageCenter?() }
                    .help("The graphs live in the Usage Center (⌘U)")
            } label: {
                SettingLabel(title: "Graphs", subtitle: "Per-provider history, cost and pace, for the range above.")
            }
        } header: {
            Text("Display")
        } footer: {
            SectionNote("Graphs live in the Usage Center (⌘U). This range is what it opens on and what the panel's sparklines cover.")
        }

        Section {
            Provided(store, "claude_plan_limits_enabled") {
                Toggle(isOn: Binding(
                    get: { store.document.bool("claude_plan_limits_enabled") ?? false },
                    set: { on in
                        store.set("claude_plan_limits_enabled", .bool(on))
                        store.set("claude_plan_limits_consent_version", .number(on ? 1 : 0))
                    }
                )) {
                    SettingLabel(title: "Read Claude plan limits",
                                 subtitle: "Presents your own Claude subscription credential to api.anthropic.com to read the official 5-hour and 7-day windows. Off until you opt in.")
                }
            }
        } header: {
            Text("Claude")
        }

        Section("Quota alerts") {
            SettingToggle(store, "Alert when a window crosses a threshold", path: "quota_alerts_enabled")
            Provided(store, "quota_alert_thresholds") {
                ThresholdRow(store: store)
            }
        }

        Section {
            SettingToggle(store, "Keep capacity history", subtitle: "Stores usage samples locally so the graph can look back.", path: "capacity_history_enabled")
            SettingIntPicker(store, "Keep for", path: "capacity_history_retention_days", options: [
                (1, "1 day"), (7, "7 days"), (30, "30 days"), (90, "90 days"),
            ], default: 7)
                .disabled(!(store.document.bool("capacity_history_enabled") ?? false))
        } header: {
            Text("History")
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
                    ValueText(text: "Nudge at \(binding(0).wrappedValue) %", width: 100)
                    Stepper("", value: binding(0), in: 50...99).labelsHidden()
                }
                HStack(spacing: 4) {
                    ValueText(text: "Warn at \(binding(1).wrappedValue) %", width: 92)
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
            Section("Devices") {
                if store.hasDocument {
                    Text("No SidePulse devices in the settings document.").foregroundStyle(.secondary)
                } else {
                    Text("Devices appear once the core is connected.").foregroundStyle(.secondary)
                }
            }
        }
        ForEach(devices) { device in
            DeviceCard(store: store, device: device)
        }

        Section {
            SettingToggle(store, "Link Pro and Dot", subtitle: "The Dot follows the strip instead of driving itself. Off, it always renders its own two-LED display, whatever its role says.",
                          path: "devices_linked", default: true)
            SettingSlider(store, "Dot brightness", subtitle: "How bright the linked Dot runs next to the strip: two LEDs an arm's length away read much brighter than eight across a desk.",
                          path: "linked_dot_scale", in: 0.05...1.0, step: 0.05, default: 0.3) { "\(Int(($0 * 100).rounded())) %" }
                .disabled(!(store.document.bool("devices_linked") ?? true))
            DotRoleControls(store: store, inDeviceCard: false)
        } header: {
            Text("Pro + Dot")
        } footer: {
            SectionNote("The role is what the Dot is for; the link is whether the core drives it at all.")
        }

        CreatorMicroCard(store: store)

        Section {
            ScreenBarCard(store: store)
        } header: {
            HStack(spacing: 8) {
                Text("Screen Bar")
                if let bar = store.stateDevice("screen-bar") {
                    Text(bar.enabled == true ? "Shown" : "Hidden").foregroundStyle(.secondary).font(.callout)
                }
            }
        } footer: {
            SectionNote("The gap is the span treated as the notch, between the two risers; the wing is each stroke's reach beyond it. Automatic measures the notch and Alcove; manual values are points and always win.")
        }
    }
}

struct DeviceCard: View {
    @Bindable var store: SettingsStore
    let device: SettingsStore.DeviceEntry

    private var state: CoreDevice? { store.stateDevice(device.id) }
    private var pinOptions: [(value: String, label: String)] {
        [("", "Everyone")] + SettingsKey.providers.map { ($0, ProviderStyle.style(for: $0).name) }
    }

    var body: some View {
        Section {
            SettingPicker(store, "Display", path: "\(device.prefix).led_display", options: DevicesPage.displayModes, default: "agent")
            SettingSlider(store, "Brightness", path: "\(device.prefix).brightness", in: 0...255, step: 1, default: 255) { "\(Int(($0 / 255 * 100).rounded())) %" }
            SettingToggle(store, "Auto-brightness", subtitle: "Follows the display's brightness: dim in a dark room, bright in daylight.",
                          path: "\(device.prefix).auto_brightness_enabled")
            Provided(store, "\(device.prefix).provider_pin") {
                Picker(selection: store.optionalString("\(device.prefix).provider_pin")) {
                    ForEach(pinOptions, id: \.value) { Text($0.label).tag($0.value) }
                } label: {
                    SettingLabel(title: "Pin to", subtitle: "A pinned device shows only that provider's sessions and rests dark otherwise.")
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Provided(store, "\(device.prefix).signal_policy") {
                Toggle(isOn: Binding(
                    get: { store.document.string(SettingsPath("\(device.prefix).signal_policy")) == "asks_only" },
                    set: { store.set("\(device.prefix).signal_policy", $0 ? .string("asks_only") : .null) }
                )) {
                    SettingLabel(title: "Asks only", subtitle: "Mute courtesy signals on this device; agent status, asks and low battery still show.")
                }
            }
            LabeledContent {
                Button("Calibrate…") { store.calibrating = device.id }
                    .disabled(!store.core.isLive)
            } label: {
                SettingLabel(title: "Colour calibration", subtitle: calibrationSummary)
            }
            if device.kind == "dot" {
                DotRoleControls(store: store, inDeviceCard: true)
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: device.kind == "dot" ? "circle.grid.2x1.fill" : "light.beacon.max.fill")
                Text(device.name)
                if let state {
                    Text(state.isPresent ? "Connected" : (state.error ?? "Not connected"))
                        .foregroundStyle(state.isPresent ? Color.secondary : .orange)
                        .font(.callout)
                }
                Spacer()
                Text(device.kind == "dot" ? "2 LEDs" : "8 LEDs").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private var calibrationSummary: String {
        let doc = store.document
        let r = doc.double(SettingsPath("\(device.prefix).red_gain")) ?? 1
        let g = doc.double(SettingsPath("\(device.prefix).green_gain")) ?? 1
        let b = doc.double(SettingsPath("\(device.prefix).blue_gain")) ?? 1
        let glow = doc.double(SettingsPath("\(device.prefix).resting_glow")) ?? 0
        if r == 1, g == 1, b == 1, glow == 0 { return "Uncalibrated" }
        return String(format: "R %.2f · G %.2f · B %.2f · glow %d %%", r, g, b, Int((glow * 100).rounded()))
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
        guard store.core.isLive else { return "Core not connected" }
        guard deck != nil else { return "Not provided by core" }
        guard let device, device.connected else { return "Not connected" }
        var parts: [String] = []
        if device.hasConflict { parts.append(DeckDevice.conflictText) }
        else if !device.approved { parts.append("Connected, needs approval") }
        else { parts.append("Connected") }
        if let transport = device.transport { parts.append(transport.label) }
        if let serial = device.serial { parts.append(serial) }
        return parts.joined(separator: " · ")
    }

    private func set(enabled: Bool? = nil, sessionMode: Bool? = nil, analogEnabled: Bool? = nil) {
        let core = store.core
        Task { _ = try? await core.deckSetSettings(enabled: enabled, sessionMode: sessionMode, analogEnabled: analogEnabled) }
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.enabled }, set: { set(enabled: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Creator Micro 2")
                    Text("The core drives the approved pad's per-key colours and listens to its inputs.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(!live)
            Toggle(isOn: Binding(get: { settings.sessionMode }, set: { set(sessionMode: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session keys")
                    Text("The thirteen keys follow the session board: a key lights with its session's state and reveals it when pressed. Explicit mappings still win.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(!live || !settings.enabled)
            Toggle(isOn: Binding(get: { settings.analogEnabled }, set: { set(analogEnabled: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Analog joystick sectors")
                    Text("Calibrated sectors 1–4 (AG20–AG23) count as inputs and can carry mappings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(!live || !settings.enabled)
            LabeledContent {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).foregroundStyle(.secondary).lineLimit(2)
                }
            } label: {
                Text("Status")
            }
            if let deck {
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
                if let receipt = deck.device?.receipt {
                    LabeledContent("Last receipt") {
                        Text(receipt.text).foregroundStyle(receipt.isProblem ? .orange : .secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            HStack {
                Text("Control Center")
                Spacer()
                Button("Open Control Center…") { store.onOpenControlCenter?() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        } header: {
            HStack(spacing: 8) {
                Text("Creator Micro 2")
                if device?.approved == false, device?.connected == true {
                    Text("Approve it in the Control Center").foregroundStyle(.secondary).font(.callout)
                }
            }
        } footer: {
            SectionNote("Thirteen session keys per bank with solid per-key colour, a dial and a joystick with explicit mappings. Pins, banks, the rail, input check and the keymap live in the Control Center; the core owns the device.")
        }
    }
}

struct ScreenBarCard: View {
    @Bindable var store: SettingsStore

    var body: some View {
        NullableSlider(store: store, title: "Gap width", path: "screen_bar_gap_width", range: 120...400, fallback: 180)
        NullableSlider(store: store, title: "Wing length", path: "screen_bar_wing_length", range: 0...80, fallback: 14)
        SettingPicker(store, "Bracket style", subtitle: "How the Alcove bracket colours itself.", path: "screen_bar_bracket_style", options: [
            ("auto", "Automatic"), ("spatial", "Mirror the LEDs"), ("identity", "One hue"),
        ], default: "auto")
        SettingSlider(store, "Minimum glow", subtitle: "The band's dim floor. Zero is pitch black: only the moving signal shows.",
                      path: "screen_bar_min_glow", in: 0...1, default: 0.25, format: SettingsStore.percent)
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
