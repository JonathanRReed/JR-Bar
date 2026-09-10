import AppKit
import JRBarCore
import SwiftUI

// MARK: - Lighting

struct LightingPage: View {
    @Bindable var store: SettingsStore

    static let blendModes: [(value: String, label: String, detail: String)] = [
        ("round_robin", "Everyone", "Every agent is lit at once, each in its own colour."),
        ("relay", "Spotlight", "One agent flares bright at a time; the rest stay dim."),
        ("spatial_split", "Split", "Each agent gets its own section, sized by how much it needs you."),
        ("color_blend", "Smooth", "One seamless light. Everyone's colours blend across the strip."),
        ("cycle", "One at a Time", "The whole strip shows one agent, then the next."),
        ("classic", "Status Only", "One colour for whatever needs you most. Agents are not shown."),
    ]

    static let scenes: [(value: String, label: String)] = [
        ("calm", "Calm"), ("focus", "Focus"), ("night", "Night"), ("demo", "Demo"), ("travel", "Travel"), ("dnd", "Do Not Disturb"),
    ]

    private let swatchColumns = [GridItem(.adaptive(minimum: 160), alignment: .leading)]

    var body: some View {
        Section {
            LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 8) {
                ForEach(SettingsKey.providers, id: \.self) { provider in
                    ProviderSwatch(store: store, provider: provider)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Provider colours")
        }

        Section {
            Provided(store, "colors.blend_mode") {
                Picker(selection: store.string("colors.blend_mode", default: "round_robin")) {
                    ForEach(Self.blendModes, id: \.value) { Text($0.label).tag($0.value) }
                } label: {
                    SettingLabel(title: "Blend mode", subtitle: blendDetail)
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            SettingSlider(store, "Cycle speed", subtitle: "One breath, in seconds.", path: "colors.cycle_speed_seconds", in: 0.5...8, step: 0.1, default: 2.2, format: SettingsStore.seconds)
            SettingToggle(store, "Celebrate completions", subtitle: "A twinkle-then-bloom flourish when a session settles into Done.",
                          path: "colors.done_celebration_enabled", default: true)
            LabeledContent {
                LEDStripPreview(program: LightingPreviewPrograms.celebration(colorHex: celebrationColor), style: .dots, dotSize: 9, spacing: 6)
                    .frame(width: 168)
                    .opacity((store.document.bool("colors.done_celebration_enabled") ?? true) ? 1 : 0.35)
                    .accessibilityLabel("Done celebration preview")
            } label: {
                SettingLabel(title: "Celebration preview", subtitle: "The ripple, bloom and hold the strip plays; the Screen Bar blends the same frames.")
            }
        } header: {
            Text("Blend")
        }

        Section {
            ForEach(SettingsKey.fadeModes, id: \.self) { mode in
                FadeRow(store: store, mode: mode)
            }
        } header: {
            Text("Pulse range")
        } footer: {
            SectionNote("Floor and ceiling of each pulsing mode's brightness, as fractions of the device brightness.")
        }

        Section("Dimming") {
            SettingToggle(store, "Dim when idle", path: "idle_dim_enabled", default: true)
            SettingSlider(store, "After", path: "idle_dim_after_minutes", in: 1...180, step: 1, default: 10, format: SettingsStore.minutes)
                .disabled(!(store.document.bool("idle_dim_enabled") ?? true))
            SettingSlider(store, "Idle brightness", path: "idle_dim_fraction", in: 0.05...1, default: 0.3, format: SettingsStore.percent)
                .disabled(!(store.document.bool("idle_dim_enabled") ?? true))
            SettingToggle(store, "Dim when the display sleeps", path: "sleep_dim_enabled", default: true)
            SettingSlider(store, "Sleep brightness", path: "sleep_dim_fraction", in: 0.05...1, default: 0.2, format: SettingsStore.percent)
                .disabled(!(store.document.bool("sleep_dim_enabled") ?? true))
            SettingToggle(store, "Turn off after a long idle", path: "idle_auto_off_enabled")
            SettingSlider(store, "Off after", path: "idle_auto_off_after_minutes", in: 5...1440, step: 5, default: 60, format: SettingsStore.minutes)
                .disabled(!(store.document.bool("idle_auto_off_enabled") ?? false))
        }

        Section {
            SettingPicker(store, "Active scene", subtitle: "A presentation policy: brightness, motion and notification admission as one choice.",
                          path: "active_scene", options: Self.scenes, default: "calm")
            LabeledContent {
                Button("Effects…") { store.onOpenEffects?() }
            } label: {
                SettingLabel(title: "Effect Studio", subtitle: "Browse the registry and packs, tune parameters with a live preview, and assign looks to states, scenes, providers and devices.")
            }
        } header: {
            Text("Scene")
        }
    }

    private var blendDetail: String {
        let mode = store.document.string("colors.blend_mode") ?? "round_robin"
        return Self.blendModes.first { $0.value == mode }?.detail ?? ""
    }

    /// The colour the celebration plays in: the document's done colour when
    /// it has one, else the firmware reference green.
    private var celebrationColor: String {
        for path in ["colors.done_celebration_color", "colors.mode_colors.done", "colors.status_colors.done", "colors.status_colors.completed"] {
            if let hex = store.document.string(SettingsPath(path)), NSColor(hex: hex) != nil { return hex }
        }
        return "#00FF66"
    }
}

/// A provider's colour well beside a tiny live preview of its working
/// animation under the current blend mode and cycle speed.
struct ProviderSwatch: View {
    @Bindable var store: SettingsStore
    let provider: String

    var body: some View {
        let style = ProviderStyle.style(for: provider)
        let path = "colors.agent_colors.\(provider)"
        let hex = store.document.string(SettingsPath(path)) ?? style.accentHex
        let blend = store.document.string("colors.blend_mode") ?? "round_robin"
        let cycle = store.document.double(SettingsPath("colors.cycle_speed_seconds")) ?? 2.2
        HStack(spacing: 8) {
            ColorPicker("", selection: store.color(path, default: style.accentHex), supportsOpacity: false)
                .labelsHidden()
                .disabled(!store.isProvided(path))
            VStack(alignment: .leading, spacing: 3) {
                Text(style.name)
                HStack(spacing: 6) {
                    LEDStripPreview(program: LightingPreviewPrograms.working(colorHex: hex, blendMode: blend, cycleSeconds: cycle),
                                    style: .band, dotSize: 6, showsBackground: true, cornerRadius: 6,
                                    phase: Double(SettingsKey.providers.firstIndex(of: provider) ?? 0) * cycle * 0.23)
                        .frame(width: 66)
                        .accessibilityLabel("\(style.name) working animation preview")
                    Text(store.document.string(SettingsPath(path)) ?? (store.hasDocument ? "not provided" : style.accentHex))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .help("How \(style.name) looks while working: \(LightingPage.blendModes.first { $0.value == blend }?.label ?? blend), one cycle every \(SettingsStore.seconds(cycle))")
    }
}

struct FadeRow: View {
    @Bindable var store: SettingsStore
    let mode: String

    var body: some View {
        let floorPath = "colors.fade_floor.\(mode)"
        let ceilingPath = "colors.fade_ceiling.\(mode)"
        Provided(store, floorPath, ceilingPath) {
            LabeledContent(mode.capitalized) {
                HStack(spacing: 10) {
                    Text("Floor").font(.callout).foregroundStyle(.secondary)
                    Slider(value: store.double(floorPath, default: 0.01), in: 0...1).frame(width: 90)
                    ValueText(text: SettingsStore.percent(store.document.double(SettingsPath(floorPath)) ?? 0.01), width: 40)
                    Text("Ceiling").font(.callout).foregroundStyle(.secondary).padding(.leading, 6)
                    Slider(value: store.double(ceilingPath, default: 0.5), in: 0...1).frame(width: 90)
                    ValueText(text: SettingsStore.percent(store.document.double(SettingsPath(ceilingPath)) ?? 0.5), width: 40)
                }
            }
        }
    }
}

// MARK: - Notifications & Focus

struct NotificationsPage: View {
    @Bindable var store: SettingsStore

    static let focusModes: [(value: String, label: String)] = [
        ("mute", "Mute"), ("dim", "Dim"), ("pause", "Pause"), ("asks_only", "Asks only"), ("dark", "Dark"),
    ]

    /// The Focus modes every Mac has, by their system identifiers.
    static let knownFocuses: [(id: String, name: String)] = [
        ("com.apple.donotdisturb.mode.default", "Do Not Disturb"),
        ("com.apple.focus.work", "Work"),
        ("com.apple.focus.personal-time", "Personal"),
        ("com.apple.sleep.sleep-mode", "Sleep"),
    ]

    var body: some View {
        Section("Completion") {
            SettingToggle(store, "Notification banner", subtitle: "A macOS notification when a main session finishes. Needs the system notification permission.",
                          path: "completion_notification_enabled")
            SettingToggle(store, "Completion sweep", subtitle: "Sweep the bar in the finishing agent's colour the moment any session completes.",
                          path: "completion_sweep_enabled", default: true)
        }

        Section {
            SettingPicker(store, "Loudest stage", subtitle: "How far an ignored ask may escalate.", path: "escalation_tier", options: [
                ("light", "Light only"), ("menu_bar", "Menu bar"), ("chime", "Chime"), ("takeover", "Take over"),
            ], default: "menu_bar")
            SettingNumberField(store, "Ramp after", path: "escalation_ramp_seconds", in: 5...3600, default: 30, unit: "s")
            SettingNumberField(store, "Menu bar after", path: "escalation_menu_bar_seconds", in: 5...7200, default: 120, unit: "s")
            SettingNumberField(store, "Final stage after", path: "escalation_final_seconds", in: 5...14400, default: 300, unit: "s")
            SettingStepper(store, "Alert burst", subtitle: "Repetitions a courtesy signal gets before it settles; critical signals ignore this.",
                           path: "alert_burst", in: 1...10, default: 3, unit: "×")
        } header: {
            Text("Escalation")
        }

        Section {
            SettingToggle(store, "Quiet schedule", path: "dnd_schedule_enabled")
            Provided(store, "dnd_schedule_start_minutes", "dnd_schedule_end_minutes") {
                LabeledContent("From") {
                    HStack(spacing: 8) {
                        DatePicker("", selection: store.minutesOfDay("dnd_schedule_start_minutes", default: 1320), displayedComponents: .hourAndMinute).labelsHidden()
                        Text("to").foregroundStyle(.secondary)
                        DatePicker("", selection: store.minutesOfDay("dnd_schedule_end_minutes", default: 420), displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
            }
            .disabled(!(store.document.bool("dnd_schedule_enabled") ?? false))
            SettingPicker(store, "While quiet", path: "dnd_schedule_mode", options: Self.focusModes, default: "dark")
                .disabled(!(store.document.bool("dnd_schedule_enabled") ?? false))
            SettingSlider(store, "Dim to", path: "dnd_dim_fraction", in: 0...1, default: 0.15, format: SettingsStore.percent)
                .disabled(!(store.document.bool("dnd_schedule_enabled") ?? false) || store.document.string("dnd_schedule_mode") != "dim")
        } header: {
            Text("Quiet hours")
        }

        Section {
            SettingToggle(store, "React to Focus modes", subtitle: "Reads the active Focus, which needs Full Disk Access for this app.", path: "focus_sync_enabled")
            SettingPicker(store, "In Do Not Disturb", path: "dnd_focus_mode", options: Self.focusModes, default: "pause")
                .disabled(!(store.document.bool("focus_sync_enabled") ?? false))
            ForEach(Self.knownFocuses, id: \.id) { focus in
                FocusRuleRow(store: store, focusID: focus.id, name: focus.name)
                    .disabled(!(store.document.bool("focus_sync_enabled") ?? false))
            }
        } header: {
            Text("Focus")
        } footer: {
            SectionNote("A Focus without a rule uses the idle brightness from Lighting.")
        }

        Section {
            SettingToggle(store, "Keep the Mac awake while agents run", subtitle: "Prevents system sleep, not display sleep.", path: "agent_keep_awake_enabled", default: true)
            SettingToggle(store, "Keep the display awake too", path: "keep_display_awake")
            SettingPicker(store, "With the lid closed", subtitle: closedLidNote, path: "closed_lid_awake_policy", options: [
                ("never", "Let it sleep"), ("agents", "Stay awake while agents run"), ("always", "Always stay awake"),
            ], default: "never")
            SettingToggle(store, "Keep awake on battery", subtitle: "Off releases the hold whenever the Mac is unplugged.", path: "keep_awake_on_battery", default: true)
        } header: {
            Text("Power")
        }

        Section {
            SettingToggle(store, "Low battery alert", subtitle: "Every surface switches to the slow red breathe until power returns.",
                          path: "battery_monitoring.low_battery_alert_enabled", default: true)
            SettingSlider(store, "Below", path: "battery_monitoring.low_battery_threshold_percent", in: 1...50, step: 1, default: 5) { "\(Int($0)) %" }
                .disabled(!(store.document.bool("battery_monitoring.low_battery_alert_enabled") ?? true))
        } header: {
            Text("Battery")
        }
    }

    private var closedLidNote: String {
        let lid = store.core.state?.power?.closedLid
        switch lid?.helperInstalled {
        case true?: return "The sleep helper is installed; closed-lid holds are honoured." + (lid?.holding == true ? " Holding now." : "")
        case false?: return "Needs the privileged sleep helper, which is not installed. The core will offer to install it."
        default: return "Needs the privileged sleep helper; the core reports whether it is installed."
        }
    }
}

struct FocusRuleRow: View {
    @Bindable var store: SettingsStore
    let focusID: String
    let name: String

    private var rule: Double? { store.document.double(SettingsPath("focus_dim_rules.\(focusID)")) }

    var body: some View {
        Provided(store, "focus_dim_rules") {
            row
        }
    }

    private var row: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Toggle("Rule", isOn: Binding(
                    get: { rule != nil },
                    set: { on in store.set("focus_dim_rules.\(focusID)", on ? .number(0.3) : .null) }
                ))
                .toggleStyle(.checkbox)
                Slider(value: Binding(get: { rule ?? 0.3 }, set: { store.set("focus_dim_rules.\(focusID)", .number($0), throttled: true) }), in: 0...1)
                    .frame(width: 130)
                    .disabled(rule == nil)
                ValueText(text: rule.map(SettingsStore.percent) ?? "idle dim")
            }
        } label: {
            SettingLabel(title: name, subtitle: focusID)
        }
    }
}

// MARK: - Remote

struct RemotePage: View {
    @Bindable var store: SettingsStore

    static let webhookEvents: [(value: String, label: String)] = [
        ("completion", "Completion"), ("ask_opened", "Ask opened"), ("failed", "Failure"), ("quota_crossed", "Quota crossed"),
    ]

    var body: some View {
        Section {
            SettingToggle(store, "Remote peers", subtitle: "Discover other Macs running JR-Bar and show their agents here.", path: "remote_peers.enabled")
            SettingToggle(store, "Publish this Mac", subtitle: "Let peers read this desk's sessions.", path: "remote_peers.publish_enabled")
                .disabled(!(store.document.bool("remote_peers.enabled") ?? false))
            SettingToggle(store, "Mute remote interrupts", subtitle: "A peer's asks may not take a light here until you unmute that machine by name.",
                          path: "remote_peers.remote_interrupts_muted", default: true)
                .disabled(!(store.document.bool("remote_peers.enabled") ?? false))
            MachineList(store: store, path: "remote_peers.unmuted_machines", title: "Unmuted machines")
                .disabled(!(store.document.bool("remote_peers.enabled") ?? false))
        } header: {
            Text("Peers")
        }

        Section {
            SettingToggle(store, "Cloud ingest", subtitle: "Opens a loopback port so off-machine agents can post their own lifecycle.", path: "cloud_ingest_enabled")
            Provided(store, "cloud_ingest_token_path") {
                LabeledContent("Token") {
                    HStack(spacing: 8) {
                        Text(store.document.string("cloud_ingest_token_path") ?? "")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 300, alignment: .trailing)
                        Button("Reveal") {
                            let path = (store.document.string("cloud_ingest_token_path") ?? "") as NSString
                            let url = URL(fileURLWithPath: path.expandingTildeInPath)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Cloud")
        }

        Section {
            SettingTextField(store, "Webhook URL", subtitle: "POSTs stage-3 escalations whenever set.", path: "escalation_webhook_url", prompt: "https://", monospaced: true)
            Provided(store, "webhook_events") {
                LabeledContent("Also send") {
                    HStack(spacing: 14) {
                        ForEach(Self.webhookEvents, id: \.value) { event in
                            Toggle(event.label, isOn: store.listMember("webhook_events", event.value))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .disabled((store.document.string("escalation_webhook_url") ?? "").isEmpty)
        } header: {
            Text("Webhook")
        }
    }
}

/// A string list with add and remove, for machine names.
struct MachineList: View {
    @Bindable var store: SettingsStore
    let path: String
    let title: String
    @ViewState private var draft = ""

    var body: some View {
        Provided(store, path) {
            LabeledContent(title) {
                VStack(alignment: .leading, spacing: 6) {
                    let machines = store.document.strings(SettingsPath(path)) ?? []
                    if machines.isEmpty {
                        Text("None").foregroundStyle(.tertiary)
                    }
                    ForEach(machines, id: \.self) { machine in
                        HStack(spacing: 6) {
                            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                            Text(machine)
                            Button {
                                store.stringList(path).wrappedValue.removeAll { $0 == machine }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 6) {
                        TextField("", text: $draft, prompt: Text("Machine name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit(add)
                        Button("Add", action: add).controlSize(.small).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var list = store.stringList(path).wrappedValue
        if !list.contains(name) { list.append(name) }
        store.stringList(path).wrappedValue = list
        draft = ""
    }
}

// MARK: - Advanced

struct AdvancedPage: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Section("Diagnostics") {
            LabeledContent("Connection", value: connectionWord)
            LabeledContent("Core version", value: store.core.hello?.coreVersion ?? "—")
            LabeledContent("Socket") {
                Text(store.core.socketPath).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            LabeledContent("Capabilities") {
                Text(store.core.hello?.capabilities.joined(separator: ", ") ?? "—")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 380, alignment: .trailing)
            }
            LabeledContent("Generations", value: "state \(store.core.state?.generation ?? 0) · settings \(store.generation)")
            HStack(spacing: 8) {
                Button("Reveal State Folder") { store.revealStateFolder() }
                Button(store.doctorRunning ? "Running…" : "Run Doctor") { store.runDoctor() }
                    .disabled(!store.core.isLive || store.doctorRunning)
            }
        }

        Section {
            LogTail(entries: store.core.logTail)
        } header: {
            HStack {
                Text("Core log")
                Spacer()
                Text("\(store.core.logTail.count) lines").font(.callout).foregroundStyle(.tertiary)
            }
        }

        Section {
            ForEach(SettingsStore.Page.allCases.filter { $0 != .advanced }) { page in
                LabeledContent(page.title) {
                    Button("Reset…") { store.resetTarget = page }
                        .controlSize(.small)
                        .disabled(!store.core.isLive)
                }
            }
        } header: {
            Text("Reset to defaults")
        } footer: {
            SectionNote("Each button puts that page's settings back to the core's defaults. Devices keep their identities.")
        }
    }

    private var connectionWord: String {
        switch store.core.connection {
        case .connected where store.core.state != nil: return "Connected"
        case .connected: return "Connected, waiting for state"
        case .connecting(let attempt): return attempt <= 1 ? "Connecting…" : "Reconnecting (try \(attempt))"
        case .disconnected(let reason): return "Disconnected · \(reason)"
        case .idle: return "Idle"
        }
    }
}

struct LogTail: View {
    let entries: [CoreLog]

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if entries.isEmpty {
                        Text("No log lines yet.").foregroundStyle(.tertiary).padding(6)
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.at.map { Self.clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "--:--:--")
                                .foregroundStyle(.tertiary)
                            Text((entry.level ?? "info").uppercased())
                                .foregroundStyle(entry.level == "error" ? Color.red : (entry.level == "warn" || entry.level == "warning" ? .orange : .secondary))
                                .frame(width: 44, alignment: .leading)
                            Text(entry.message ?? "")
                                .textSelection(.enabled)
                        }
                        .id(index)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.quaternary))
            .onChange(of: entries.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

/// The `doctor` reply, as a checklist plus the remaining key/value pairs.
struct DoctorSheet: View {
    let report: JSONValue
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(.secondary)
                Text("Doctor").font(.title3.weight(.semibold))
                Spacer()
                if report["ok"]?.boolValue == true {
                    Label("All good", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if let checks = report["checks"]?.arrayValue, !checks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: check["ok"]?.boolValue == true ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(check["ok"]?.boolValue == true ? Color.green : .red)
                            Text(check["name"]?.stringValue ?? "check")
                            Spacer()
                            Text(check["detail"]?.stringValue ?? "").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            ScrollView {
                Text(Self.render(report))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    static func render(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "\(value)" }
        return text
    }
}

// MARK: - Calibration

/// RGB gains and resting glow for one device, previewed live on the strip
/// through `preview_program`, applied through `apply_calibration`.
struct CalibrationSheet: View {
    @Bindable var store: SettingsStore
    let deviceID: String
    let dismiss: () -> Void

    @ViewState private var red = 1.0
    @ViewState private var green = 1.0
    @ViewState private var blue = 1.0
    @ViewState private var glow = 0.0
    @ViewState private var loaded = false
    @ViewState private var previewWork: DispatchWorkItem?

    private var device: SettingsStore.DeviceEntry? { store.deviceEntries.first { $0.id == deviceID } }
    private var surface: String { device?.kind == "dot" ? "dot" : "hardware" }
    private var ledCount: Int { device?.kind == "dot" ? 2 : 8 }

    /// The preview: white through the gains, on a bed of the resting glow.
    private var previewHex: String {
        String(format: "#%02X%02X%02X", Int((255 * red).rounded()), Int((255 * green).rounded()), Int((255 * blue).rounded()))
    }

    private var glowHex: String {
        let level = Int((255 * glow).rounded())
        return String(format: "#%02X%02X%02X", Int(Double(level) * red), Int(Double(level) * green), Int(Double(level) * blue))
    }

    private var previewProgram: String {
        "\(glowHex) 0ms\n" + (0..<ledCount).map { "\($0):\(previewHex) 300ms ease \($0 * 40)ms" }.joined(separator: "; ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calibrate \(device?.name ?? deviceID)").font(.title3.weight(.semibold))
                    Text("Correct this strip's own LED dies so white reads white. The preview shows on the device for three seconds after each change.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            CalibrationPreview(ledCount: ledCount, red: red, green: green, blue: blue, glow: glow)
                .frame(height: 44)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                gainRow("Red", value: $red, tint: .red)
                gainRow("Green", value: $green, tint: .green)
                gainRow("Blue", value: $blue, tint: .blue)
                GridRow {
                    Text("Resting glow")
                    Slider(value: $glow, in: 0...0.3)
                    Text(SettingsStore.percent(glow)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
            HStack {
                Button("Reset") { red = 1; green = 1; blue = 1; glow = 0; schedulePreview() }
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    store.core.applyCalibration(device: deviceID, profile: [
                        "red_gain": .number(red), "green_gain": .number(green), "blue_gain": .number(blue), "resting_glow": .number(glow),
                    ])
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: load)
        .onChange(of: red) { _, _ in schedulePreview() }
        .onChange(of: green) { _, _ in schedulePreview() }
        .onChange(of: blue) { _, _ in schedulePreview() }
        .onChange(of: glow) { _, _ in schedulePreview() }
    }

    private func gainRow(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title)
            }
            Slider(value: value, in: 0.2...1.0)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
    }

    private func load() {
        guard !loaded, let device else { return }
        loaded = true
        let doc = store.document
        red = doc.double(SettingsPath("\(device.prefix).red_gain")) ?? 1
        green = doc.double(SettingsPath("\(device.prefix).green_gain")) ?? 1
        blue = doc.double(SettingsPath("\(device.prefix).blue_gain")) ?? 1
        glow = doc.double(SettingsPath("\(device.prefix).resting_glow")) ?? 0
    }

    private func schedulePreview() {
        guard loaded else { return }
        previewWork?.cancel()
        let program = previewProgram
        let surface = surface
        let work = DispatchWorkItem { [store] in
            MainActor.assumeIsolated { store.core.previewProgram(surface: surface, program: program, seconds: 3) }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

/// The calibration's result on a row of LEDs, so the sheet shows what the strip will.
struct CalibrationPreview: View {
    let ledCount: Int
    let red: Double
    let green: Double
    let blue: Double
    let glow: Double

    var body: some View {
        HStack(spacing: ledCount > 4 ? 10 : 18) {
            ForEach(0..<ledCount, id: \.self) { index in
                let lit = index % 2 == 0
                let level = lit ? 1.0 : glow
                Circle()
                    .fill(Color(red: red * level, green: green * level, blue: blue * level))
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: Color(red: red, green: green, blue: blue).opacity(lit ? 0.6 : 0), radius: 6)
                    .frame(width: 16, height: 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
