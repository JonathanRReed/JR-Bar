import AppKit
import EventKit
import JRBarCore
import SwiftUI
import UserNotifications

// MARK: - Lighting

struct LightingPage: View {
    @Bindable var store: SettingsStore

    static let blendModes: [(value: String, label: String, detail: String)] = [
        // Smooth first: it is the default, and on the Screen Bar's blended
        // surface per-agent blocks average into mud.
        ("color_blend", "Smooth", "One seamless light. Everyone's colours blend across the strip."),
        ("round_robin", "Everyone", "Every agent is lit at once, each in its own colour."),
        ("spatial_split", "Split", "Each agent gets its own section, sized by how much it needs you."),
        ("relay", "Spotlight", "One agent flares bright at a time; the rest stay dim."),
        ("cycle", "One at a Time", "The whole strip shows one agent, then the next."),
        ("classic", "Status Only", "One colour for whatever needs you most. Agents are not shown."),
    ]

    static let scenes: [(value: String, label: String)] = [
        ("calm", "Calm"), ("focus", "Focus"), ("night", "Night"), ("demo", "Demo"), ("travel", "Travel"), ("dnd", "Do Not Disturb"),
    ]

    private let swatchColumns = [GridItem(.adaptive(minimum: 160), alignment: .leading)]

    var body: some View {
        SettingGroup("Provider colours") {
            LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 8) {
                ForEach(SettingsKey.providers, id: \.self) { provider in
                    ProviderSwatch(store: store, provider: provider)
                }
            }
            .padding(.vertical, 2)
            ColorVisionNote(store: store, colors: providerColorsInUse)
        }

        SettingGroup("Blend") {
            Provided(store, "colors.blend_mode") {
                Picker(selection: store.string("colors.blend_mode", default: "color_blend")) {
                    ForEach(Self.blendModes, id: \.value) { Text($0.label).tag($0.value) }
                } label: {
                    SettingLabel(title: "Blend mode", subtitle: blendDetail)
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            SettingRow("With three agents", subtitle: "Two working and one asking — how a busy desk reads in this mode.") {
                VStack(alignment: .trailing, spacing: 6) {
                    LEDStripPreview(program: fleetProgram, style: .dots, dotSize: 9, spacing: 6)
                        .frame(width: 168)
                    LEDStripPreview(program: fleetProgram, style: .band, dotSize: 5, showsBackground: false)
                        .frame(width: 150)
                }
                .accessibilityLabel("Three agents under the chosen blend")
            }
            SettingSlider(store, "Cycle speed", subtitle: "One breath, in seconds.", path: "colors.cycle_speed_seconds", in: 0.5...8, step: 0.1, default: 2.2, format: SettingsStore.seconds)
            SettingToggle(store, "Celebrate completions", subtitle: "A flourish when a session settles into Done.",
                          path: "colors.done_celebration_enabled", default: true)
            SettingRow("Celebration preview", subtitle: "The ripple, bloom and hold the strip plays.") {
                LEDStripPreview(program: LightingPreviewPrograms.celebration(colorHex: celebrationColor), style: .dots, dotSize: 9, spacing: 6)
                    .frame(width: 168)
                    .opacity((store.document.bool("colors.done_celebration_enabled") ?? true) ? 1 : 0.35)
                    .accessibilityLabel("Done celebration preview")
            }
        }

        SettingGroup("State colours", note: "What each state looks like, whoever is running. Ask and Error are deliberately separate — set them to the same colour and the lights still pull them apart.") {
            LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 8) {
                ForEach(SettingsKey.modes, id: \.self) { mode in
                    ModeSwatch(store: store, mode: mode)
                }
            }
            .padding(.vertical, 2)
            ColorVisionNote(store: store, colors: stateColors)
        }

        SettingGroup("Pulse range") {
            DisclosureRow("Fine-tune pulsing", subtitle: "Floor and ceiling of each pulsing mode's brightness.") {
                ForEach(SettingsKey.fadeModes, id: \.self) { mode in
                    FadeRow(store: store, mode: mode)
                }
            }
        }

        SettingGroup("Dimming") {
            SettingToggle(store, "Dim when idle", path: "idle_dim_enabled", default: true)
            SettingSlider(store, "After", path: "idle_dim_after_minutes", in: 1...180, step: 1, default: 10, format: SettingsStore.minutes)
                .disabled(!(store.document.bool("idle_dim_enabled") ?? true))
            SettingSlider(store, "Idle brightness", path: "idle_dim_fraction", in: 0.05...1, default: 0.3, format: SettingsStore.percent)
                .disabled(!(store.document.bool("idle_dim_enabled") ?? true))
            SettingToggle(store, "Dim on display sleep", path: "sleep_dim_enabled", default: true)
            SettingSlider(store, "Sleep brightness", path: "sleep_dim_fraction", in: 0.05...1, default: 0.2, format: SettingsStore.percent)
                .disabled(!(store.document.bool("sleep_dim_enabled") ?? true))
            SettingToggle(store, "Turn off when idle", subtitle: "After a long idle the lights switch off entirely.", path: "idle_auto_off_enabled")
            SettingSlider(store, "Off after", path: "idle_auto_off_after_minutes", in: 5...1440, step: 5, default: 60, format: SettingsStore.minutes)
                .disabled(!(store.document.bool("idle_auto_off_enabled") ?? false))
        }

        AutoDimSection(store: store)

        SettingGroup("Scene") {
            SettingPicker(store, "Active scene", subtitle: "Which scene's effect assignments are in force.",
                          path: "active_scene", options: Self.scenes, default: "calm")
            ScenePackPicker(store: store)
            SettingRow("Effect Studio", subtitle: "Tune effects live and assign looks to states, scenes, providers and devices.") {
                Button("Effect Studio…") { store.onOpenEffects?() }
            }
        }

        SettingGroup("Ambient cues", note: "Both are opt-in and carry no state you have to read; they yield to real signals and stay dark during Do Not Disturb and low power. Effect Studio › Moments lists every cue the lights can play.") {
            SettingToggle(store, "Rainstick idle", subtitle: "A dim pixel drifts along the strip every thirty seconds while nothing else needs it.",
                          path: "rainstick_idle_enabled")
            SettingToggle(store, "Also at night", subtitle: "The Night scene withholds the drip unless you allow it here.",
                          path: "rainstick_night_enabled")
                .disabled(!(store.document.bool("rainstick_idle_enabled") ?? false))
            SettingRow("Rainstick preview", subtitle: "Shown twenty-five times faster and brighter than the strip plays it.") {
                LEDStripPreview(program: LightingPreviewPrograms.rainstick(), style: .dots, dotSize: 9, spacing: 6)
                    .frame(width: 168)
                    .opacity((store.document.bool("rainstick_idle_enabled") ?? false) ? 1 : 0.35)
                    .accessibilityLabel("Rainstick idle preview")
            }
            SettingToggle(store, "Completion milestones", subtitle: "A short celebration when finished sessions cross a milestone.",
                          path: "milestone_odometer_enabled")
            MilestoneStepsField(store: store)
                .disabled(!(store.document.bool("milestone_odometer_enabled") ?? false))
        }
    }

    /// The lit states' colours for the vision check — idle is the dark
    /// resting whisper, never read against the others.
    private var stateColors: [ColorVisionNote.Entry] {
        SettingsKey.modes.filter { $0 != "idle" }.map { mode in
            let path = "colors.mode_colors.\(mode)"
            return ColorVisionNote.Entry(
                id: mode, name: ModeSwatch.labels[mode]?.name ?? mode.capitalized, path: path,
                hex: store.document.string(SettingsPath(path)) ?? ModeSwatch.defaults[mode] ?? "#8E8E93")
        }
    }

    /// The providers worth comparing: the ones this Mac actually runs —
    /// a live session or an installed hook. Twelve hues all against each
    /// other would flag pairs nobody will ever see side by side.
    private var providerColorsInUse: [ColorVisionNote.Entry] {
        let running = Set(store.core.sessions.map(\.provider))
        return SettingsKey.providers
            .filter { running.contains($0) || (store.hookStatus($0).map { $0 != "missing" } ?? false) }
            .map { provider in
                let style = ProviderStyle.style(for: provider)
                let path = "colors.agent_colors.\(provider)"
                return ColorVisionNote.Entry(id: provider, name: style.name, path: path,
                                             hex: store.document.string(SettingsPath(path)) ?? style.accentHex)
            }
    }

    /// The fleet preview: Claude and Codex working in their colours,
    /// a third agent asking in the ask colour, under the chosen blend.
    private var fleetProgram: String {
        func accent(_ provider: String) -> String {
            store.document.agentColorHex(provider) ?? ProviderStyle.style(for: provider).accentHex
        }
        return LightingPreviewPrograms.fleet(
            blendMode: store.document.string("colors.blend_mode") ?? "color_blend",
            working: (accent("claude"), accent("codex")),
            askHex: store.document.string("colors.mode_colors.ask") ?? ModeSwatch.defaults["ask"] ?? "#FF3A00",
            cycleSeconds: store.document.double("colors.cycle_speed_seconds") ?? 2.2)
    }

    private var blendDetail: String {
        let mode = store.document.string("colors.blend_mode") ?? "color_blend"
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

/// Scene packs on the Lighting page: try one on the strip before it
/// takes over, then use it — Hue Sync lets you look at an area before
/// switching to it. The pack's tour (`preview_scene_pack`) plays one step
/// per scene it overrides, in that scene's colour, at its brightness and
/// motion. Installing and removing packs stays in Effect Studio. A core
/// without scene-pack commands keeps the old one-line note.
struct ScenePackPicker: View {
    @Bindable var store: SettingsStore
    @ViewState private var packs: [ScenePackSummary] = []
    @ViewState private var supported = false
    /// The pack on the preview strip: the active one until another is
    /// picked; "" is the built-in scenes.
    @ViewState private var trying: String?
    @ViewState private var preview: EffectPreview?

    private var active: String { store.document.string("active_scene_pack") ?? "" }
    private var shown: String { trying ?? active }

    var body: some View {
        Group {
            if supported, !packs.isEmpty {
                SettingRow("Scene pack", subtitle: subtitle) {
                    HStack(spacing: 10) {
                        if let preview, !shown.isEmpty {
                            LEDStripPreview(program: preview.program, ledCount: preview.ledCount,
                                            style: .band, dotSize: 5, showsBackground: false)
                                .frame(width: 96)
                                .accessibilityLabel("Preview of \(name(shown))")
                        }
                        Picker("Scene pack", selection: Binding(get: { shown }, set: { trying = $0 })) {
                            Text("Built-in scenes").tag("")
                            Divider()
                            ForEach(packs) { Text($0.displayName).tag($0.id) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        if shown != active {
                            Button("Use") {
                                store.set("active_scene_pack", shown.isEmpty ? .null : .string(shown))
                                trying = nil
                            }
                        }
                    }
                }
            } else if !active.isEmpty {
                Text("Scene pack “\(active)” is active — its policies override the built-in scene's. Manage packs in Effect Studio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: store.core.isLive) { await load() }
        .task(id: shown) { await loadPreview() }
    }

    private var subtitle: String {
        guard !shown.isEmpty else { return "The built-in scenes' own policies. Install packs in Effect Studio." }
        let scenes = packs.first { $0.id == shown }?.scenes ?? []
        let overrides = scenes.isEmpty ? "" : " Overrides \(ScenePackPicker.sceneList(scenes))."
        return shown == active
            ? "In use — its policies override the built-in scenes.\(overrides)"
            : "Previewing — nothing changes until you use it.\(overrides)"
    }

    private func name(_ id: String) -> String {
        packs.first { $0.id == id }?.displayName ?? id
    }

    /// "Focus, Night and Calm" from the pack's scene ids.
    static func sceneList(_ scenes: [String]) -> String {
        let names = scenes.map { id in LightingPage.scenes.first { $0.value == id }?.label ?? id.capitalized }
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    private func load() async {
        guard store.core.isLive else { supported = false; return }
        do {
            packs = try await store.core.listScenePacks()
            supported = true
        } catch {
            packs = []
            supported = false
        }
    }

    private func loadPreview() async {
        let id = shown
        guard !id.isEmpty, store.core.isLive else { preview = nil; return }
        preview = try? await store.core.previewScenePack(packID: id, ledCount: 8)
    }
}

/// Pairs of light colours that read as one for some viewer — typical
/// vision or a simulated dichromacy — each with a one-click nudge that
/// moves the second colour apart by lightness, hue kept. Silent when
/// every pair stays apart.
struct ColorVisionNote: View {
    struct Entry: Equatable {
        let id: String
        let name: String
        let path: String
        let hex: String
    }

    @Bindable var store: SettingsStore
    let colors: [Entry]

    private var collisions: [ColorVision.Collision] {
        ColorVision.collisions(colors.map { (id: $0.id, hex: $0.hex) })
    }

    var body: some View {
        let entries = Dictionary(uniqueKeysWithValues: colors.map { ($0.id, $0) })
        ForEach(collisions) { collision in
            if let first = entries[collision.first], let second = entries[collision.second] {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "eye.trianglebadge.exclamationmark").foregroundStyle(.orange)
                    Text("\(first.name) and \(second.name) look alike with \(collision.vision.name).")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let nudged = ColorVision.nudge(second.hex, awayFrom: first.hex) {
                        Button("Nudge \(second.name) apart") { store.set(second.path, .string(nudged)) }
                            .controlSize(.small)
                            .disabled(!store.isProvided(second.path))
                            .help("Sets \(second.name) to \(nudged): the same hue, lighter or darker until every vision tells them apart")
                    }
                }
            }
        }
    }
}

/// The milestone ladder as one comma-separated field. The daemon keeps
/// positive whole counts, sorted, deduplicated, at most sixteen, and
/// falls back to 10, 25, 50, 100 when nothing valid is left — the field
/// shows that same normalisation the moment it commits, so what is typed
/// is never silently different from what fires.
struct MilestoneStepsField: View {
    @Bindable var store: SettingsStore
    @ViewState private var draft = ""
    @FocusState private var focused: Bool

    private var current: [Int] {
        (store.document.array("milestone_odometer_steps") ?? []).compactMap(\.intValue)
    }
    private var currentText: String {
        (current.isEmpty ? SettingsKey.defaultMilestoneSteps : current).map(String.init).joined(separator: ", ")
    }

    var body: some View {
        Provided(store, "milestone_odometer_steps") {
            LabeledContent {
                TextField("", text: Binding(get: { focused ? draft : currentText }, set: { draft = $0 }),
                          prompt: Text("10, 25, 50, 100"))
                    .labelsHidden()
                    .focused($focused)
                    .onChange(of: focused) { _, now in
                        if now { draft = currentText } else { commit() }
                    }
                    .onSubmit { commit() }
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 180)
            } label: {
                SettingLabel(title: "Milestones", subtitle: "Finished-session counts that earn the cue — up to sixteen.")
            }
        }
    }

    private func commit() {
        let steps = SettingsKey.milestoneSteps(parsing: draft)
        guard steps != current else { return }
        store.set("milestone_odometer_steps", .array(steps.map { .number(Double($0)) }))
    }
}

/// Settings › Lighting › Auto-dim: the `auto_dim` document (`mode`, and the
/// rows of whichever mode is chosen) plus the live line from
/// `lights.auto_dim`, what the daemon read and the factor it applied.
struct AutoDimSection: View {
    @Bindable var store: SettingsStore

    private var settings: AutoDimSettings { AutoDimSettings(document: store.document) }
    private var mode: AutoDimSettings.Mode { settings.mode }
    private var provided: Bool { store.hasDocument && AutoDimSettings.isProvided(in: store.document) }

    var body: some View {
        SettingGroup("Auto-dim", note: "Multiplies every light's brightness on top of idle and sleep dimming; the why popover names it when it is in effect.") {
            Provided(store, AutoDimSettings.modePath.description) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Auto-dim", selection: store.string(AutoDimSettings.modePath.description, default: "off")) {
                        ForEach(AutoDimSettings.Mode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Auto-dim mode")
                    Text(mode.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch mode {
            case .off:
                EmptyView()
            case .schedule:
                Provided(store, AutoDimSettings.scheduleStartPath.description, AutoDimSettings.scheduleEndPath.description) {
                    SettingRow("Between", subtitle: "A start after the end wraps midnight.") {
                        HStack(spacing: 8) {
                            DatePicker("", selection: store.minutesOfDay(AutoDimSettings.scheduleStartPath.description, default: AutoDimSettings.defaults.scheduleStartMinutes),
                                       displayedComponents: .hourAndMinute).labelsHidden()
                            Text("to").foregroundStyle(.secondary)
                            DatePicker("", selection: store.minutesOfDay(AutoDimSettings.scheduleEndPath.description, default: AutoDimSettings.defaults.scheduleEndMinutes),
                                       displayedComponents: .hourAndMinute).labelsHidden()
                        }
                    }
                }
                SettingSlider(store, "Dim to", path: AutoDimSettings.scheduleFractionPath.description, in: AutoDimSettings.minFraction...1,
                              default: AutoDimSettings.defaults.scheduleFraction, format: SettingsStore.percent)
            case .display:
                SettingSlider(store, "Never below", subtitle: "The floor under the display's brightness.", path: AutoDimSettings.displayMinFractionPath.description,
                              in: AutoDimSettings.minFraction...1, default: AutoDimSettings.defaults.displayMinFraction, format: SettingsStore.percent)
            case .ambient:
                SettingSlider(store, "Never below", subtitle: "The brightness at the low lux mark.", path: AutoDimSettings.ambientMinFractionPath.description,
                              in: AutoDimSettings.minFraction...1, default: AutoDimSettings.defaults.ambientMinFraction, format: SettingsStore.percent)
                SettingNumberField(store, "Dark below", subtitle: "Full floor at this reading.", path: AutoDimSettings.ambientLuxFloorPath.description,
                                   in: 0...AutoDimSettings.maxLux, default: AutoDimSettings.defaults.ambientLuxFloor, unit: "lux")
                SettingNumberField(store, "Bright above", subtitle: "Full brightness at this reading; must be above the dark mark.", path: AutoDimSettings.ambientLuxCeilingPath.description,
                                   in: 0...AutoDimSettings.maxLux, default: AutoDimSettings.defaults.ambientLuxCeiling, unit: "lux")
                Provided(store, AutoDimSettings.ambientLuxFloorPath.description, AutoDimSettings.ambientLuxCeilingPath.description) {
                    SettingRow("Marks from room", subtitle: "Dark below a quarter of the live lux, bright above 1.6 times it.") {
                        Button("Use current light") { useRoomLight() }
                            .controlSize(.small)
                            .disabled(roomMarks == nil)
                            .help(roomMarks.map { "Writes “Dark below” \(Int($0.floor)) lux and “Bright above” \(Int($0.ceiling)) lux" }
                                  ?? "Needs a live ambient reading; the monitor is not reporting one")
                    }
                }
            }
            if provided, mode != .off {
                AutoDimReadoutRow(result: store.core.lights?.autoDim, settings: settings)
            }
        }
    }

    /// `lights.auto_dim`'s live lux — only while the daemon is really
    /// reading the ambient sensor; on the display fallback `reading` is a
    /// brightness fraction, not lux.
    private var roomLux: Double? {
        guard let result = store.core.lights?.autoDim,
              result.mode == "ambient", result.source == "ambient",
              let lux = result.reading, lux.isFinite, lux > 0 else { return nil }
        return lux
    }

    /// The marks "Use current light" would write: dark a quarter of the
    /// room's lux, bright 1.6 times it, whole lux and a gap the daemon's
    /// ceiling-above-floor check accepts.
    private var roomMarks: (floor: Double, ceiling: Double)? {
        guard let lux = roomLux else { return nil }
        let floor = max(1, (lux * 0.25).rounded())
        let ceiling = min(AutoDimSettings.maxLux, max(floor + 1, (lux * 1.6).rounded()))
        return (floor, ceiling)
    }

    private func useRoomLight() {
        guard let marks = roomMarks else { return }
        store.set(AutoDimSettings.ambientLuxFloorPath.description, .number(marks.floor))
        store.set(AutoDimSettings.ambientLuxCeilingPath.description, .number(marks.ceiling))
    }
}

/// "Ambient: 12 lux → 45 %", "Sensor unavailable, following display: 62 % → 62 %".
struct AutoDimReadoutRow: View {
    let result: CoreAutoDim?
    let settings: AutoDimSettings

    private var line: String { AutoDimReadout.line(result, settings: settings) ?? "Waiting for the monitor's reading" }
    private var unavailable: Bool { result.map { !$0.available } ?? false }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Image(systemName: unavailable ? "exclamationmark.triangle.fill" : symbol)
                    .foregroundStyle(unavailable ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .font(.callout)
                Text(line)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.2), value: line)
        } label: {
            SettingLabel(title: "Right now")
        }
        .accessibilityLabel("Auto-dim right now: \(line)")
    }

    private var symbol: String {
        switch result?.source {
        case "ambient": return "sun.max"
        case "display": return "display"
        case "schedule": return "clock"
        default: return "moon"
        }
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
        let blend = store.document.string("colors.blend_mode") ?? "color_blend"
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

/// One state's colour well beside a live preview of that state's own
/// rhythm -- the light language's five motions, not five flat swatches.
struct ModeSwatch: View {
    @Bindable var store: SettingsStore
    let mode: String

    /// `colors.MODE_ROW_LABELS`, plus the one-liner that says what the
    /// state MEANS -- the Ask/Error pair is only useful if a person knows
    /// which is which.
    static let labels: [String: (name: String, detail: String)] = [
        "idle": ("Idle", "Nothing is running."),
        "working": ("Working", "An agent is busy."),
        "done": ("Done", "A run just finished."),
        "ask": ("Ask", "Waiting on you — a permission prompt or a question."),
        "error": ("Error", "Something broke. Nothing you type answers it."),
    ]

    static let defaults: [String: String] = [
        "idle": "#020204", "working": "#00E5FF", "done": "#00FF66",
        "ask": "#FF3A00", "error": "#B00020",
    ]

    var body: some View {
        let path = "colors.mode_colors.\(mode)"
        let fallback = Self.defaults[mode] ?? "#8E8E93"
        let hex = store.document.string(SettingsPath(path)) ?? fallback
        let label = Self.labels[mode] ?? (name: mode.capitalized, detail: "")
        HStack(spacing: 8) {
            ColorPicker("", selection: store.color(path, default: fallback), supportsOpacity: false)
                .labelsHidden()
                .disabled(!store.isProvided(path))
            VStack(alignment: .leading, spacing: 3) {
                Text(label.name)
                HStack(spacing: 6) {
                    LEDStripPreview(program: LightingPreviewPrograms.state(mode, colorHex: hex),
                                    style: .band, dotSize: 6, showsBackground: true, cornerRadius: 6)
                        .frame(width: 66)
                        .accessibilityLabel("\(label.name) preview")
                    Text(store.document.string(SettingsPath(path)) ?? (store.hasDocument ? "not provided" : fallback))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .help(label.detail)
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
        SettingGroup("Completion") {
            SettingToggle(store, "Notification banner", subtitle: "A macOS banner when a main session finishes; needs the system notification permission.",
                          path: "completion_notification_enabled")
            if store.notificationPermissionDenied {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("macOS has notifications turned off for JR-Bar — banners cannot appear until it is allowed.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
            SettingToggle(store, "Completion sweep", subtitle: "Sweeps the bar in the finishing agent's colour when a session completes.",
                          path: "completion_sweep_enabled", default: true)
        }

        CalendarGlowSection(store: store)

        SettingGroup("Escalation") {
            SettingPicker(store, "Loudest stage", subtitle: "How far an ignored ask may escalate.", path: "escalation_tier", options: [
                ("light", "Light only"), ("menu_bar", "Menu bar"), ("chime", "Chime"), ("takeover", "Take over"),
            ], default: "menu_bar")
            SettingNumberField(store, "Ramp after", path: "escalation_ramp_seconds", in: 5...3600, default: 30, unit: "s")
            SettingNumberField(store, "Menu bar after", path: "escalation_menu_bar_seconds", in: 5...7200, default: 120, unit: "s")
            SettingNumberField(store, "Final stage after", path: "escalation_final_seconds", in: 5...14400, default: 300, unit: "s")
            SettingStepper(store, "Alert burst", subtitle: "Repetitions a courtesy signal gets before it settles; critical signals ignore this.",
                           path: "alert_burst", in: 1...10, default: 3, unit: "×")
            Provided(store, "escalation_tier_by_provider") {
                DisclosureRow("Per provider", subtitle: "Hold one agent's asks lower than the stage above — Claude's may chime while another's never pass the light.") {
                    ForEach(escalationProviders, id: \.self) { provider in
                        EscalationCeilingRow(store: store, provider: provider)
                    }
                }
            }
        }

        SettingGroup("Quiet hours") {
            SettingToggle(store, "Schedule", subtitle: "The lights quiet down between the hours below.", path: "dnd_schedule_enabled")
            Provided(store, "dnd_schedule_start_minutes", "dnd_schedule_end_minutes") {
                SettingRow("From") {
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
        }

        SettingGroup("Focus", note: "A Focus without a rule uses the idle brightness from Lighting.") {
            SettingToggle(store, "React to Focus modes", subtitle: "Reads the active Focus; needs Full Disk Access for this app.", path: "focus_sync_enabled")
            SettingPicker(store, "In Do Not Disturb", path: "dnd_focus_mode", options: Self.focusModes, default: "pause")
                .disabled(!(store.document.bool("focus_sync_enabled") ?? false))
            ForEach(Self.knownFocuses, id: \.id) { focus in
                FocusRuleRow(store: store, focusID: focus.id, name: focus.name)
                    .disabled(!(store.document.bool("focus_sync_enabled") ?? false))
            }
        }

        SettingGroup("Power") {
            SettingToggle(store, "Keep Mac awake", subtitle: "While agents run, the Mac never idles to sleep.", path: "agent_keep_awake_enabled", default: true)
            SettingToggle(store, "Keep display awake", subtitle: "While agents run, the screen stays on too — so it never locks mid-run. Off lets the display sleep while the Mac stays up.", path: "keep_display_awake", default: true)
            SettingPicker(store, "Lid closed", subtitle: closedLidNote, path: "closed_lid_awake_policy", options: [
                ("never", "Let it sleep"), ("agents", "Stay awake while agents run"), ("always", "Always stay awake"),
            ], default: "never")
            SettingToggle(store, "Keep awake on battery", subtitle: "Off releases the hold whenever the Mac is unplugged.", path: "keep_awake_on_battery", default: true)
        }

        SettingGroup("Battery") {
            SettingToggle(store, "Low battery alert", subtitle: "Every surface switches to the slow red breathe until power returns.",
                          path: "battery_monitoring.low_battery_alert_enabled", default: true)
            SettingSlider(store, "Below", path: "battery_monitoring.low_battery_threshold_percent", in: 1...50, step: 1, default: 5) { "\(Int($0)) %" }
                .disabled(!(store.document.bool("battery_monitoring.low_battery_alert_enabled") ?? true))
            SettingToggle(store, "Charging fill when idle", subtitle: "While plugged in and nothing is running, the strip fills to the charge level instead of the idle whisper. Agents always break through.",
                          path: "battery_monitoring.charging_idle_enabled", default: true)
            SettingToggle(store, "Show power changes", subtitle: "Plugging in or unplugging shows the charge on the lights for a few seconds.",
                          path: "battery_monitoring.show_on_power_change", default: true)
        }
        .task { store.refreshNotificationPermission() }
    }

    /// The providers worth a ceiling row: the ones this Mac runs (a live
    /// session or an installed hook) and any that already has one.
    private var escalationProviders: [String] {
        let running = Set(store.core.sessions.map(\.provider))
        let ceilings = store.document.object("escalation_tier_by_provider") ?? [:]
        return SettingsKey.providers.filter {
            running.contains($0) || ceilings[$0] != nil || (store.hookStatus($0).map { $0 != "missing" } ?? false)
        }
    }

    private var closedLidNote: String {
        let lid = store.core.state?.power?.closedLid
        switch lid?.helperInstalled {
        case true?: return "The sleep helper is installed; closed-lid holds are honoured." + (lid?.holding == true ? " Holding now." : "")
        case false?: return "Needs the privileged sleep helper, which is not installed. The monitor will offer to install it."
        default: return "Needs the privileged sleep helper; the monitor reports whether it is installed."
        }
    }
}

/// One provider's escalation ceiling (`escalation_tier_by_provider`):
/// "Same as above" or a lower stage. The object is written whole, like
/// the Focus rules, so clearing a row removes its entry.
struct EscalationCeilingRow: View {
    @Bindable var store: SettingsStore
    let provider: String

    static let stages: [(value: String, label: String)] = [
        ("light", "Light only"), ("menu_bar", "Menu bar"), ("chime", "Chime"), ("takeover", "Take over"),
    ]

    var body: some View {
        let ceilings = store.document.object("escalation_tier_by_provider")
        let current = ceilings?[provider]?.stringValue ?? ""
        Picker(selection: Binding(
            get: { current },
            set: { value in
                store.set("escalation_tier_by_provider",
                          LightProfiles.rules(ceilings, setting: provider, to: value.isEmpty ? nil : .string(value)))
            }
        )) {
            Text("Same as above").tag("")
            Divider()
            ForEach(Self.stages, id: \.value) { Text($0.label).tag($0.value) }
        } label: {
            SettingLabel(title: ProviderStyle.style(for: provider).name, subtitle: note(current))
        }
        .pickerStyle(.menu)
        .fixedSize()
        .settingRowStyle()
    }

    /// A ceiling at or above the global stage changes nothing; say so.
    private func note(_ current: String) -> String? {
        guard !current.isEmpty else { return nil }
        let global = store.document.string("escalation_tier") ?? "menu_bar"
        return EventPolicy.escalationCeiling(current) >= EventPolicy.escalationCeiling(global)
            ? "No lower than the stage above, so it changes nothing." : nil
    }
}

/// Settings › Notifications › Calendar & reminders: the daemon's two
/// EventKit glows — a calm purple breathe before a timed event, and an
/// amber glow when a Reminder comes due. Both read in the monitor; macOS
/// asks for access the first time one is on, and a refused grant says
/// so here instead of glowing never.
struct CalendarGlowSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        SettingGroup("Calendar & reminders", note: "Read on this Mac only; the glow carries no title, just the moment. Why this light names the event while it plays.") {
            SettingToggle(store, "Glow before events", subtitle: "A calm purple breathe before a timed event starts.",
                          path: "calendar_alerts_enabled")
            SettingSlider(store, "Lead time", subtitle: "How long before the start the glow begins.",
                          path: "calendar_lead_minutes", in: 1...60, step: 1, default: 5, format: SettingsStore.minutes)
                .disabled(!(store.document.bool("calendar_alerts_enabled") ?? false))
            if store.document.bool("calendar_alerts_enabled") ?? false {
                EventKitAccessNote(entity: .event)
            }
            SettingToggle(store, "Glow for due reminders", subtitle: "An amber glow when a Reminder with a time comes due.",
                          path: "reminder_alerts_enabled")
            if store.document.bool("reminder_alerts_enabled") ?? false {
                EventKitAccessNote(entity: .reminder)
            }
        }
    }
}

/// A warning under an EventKit glow when macOS has refused the grant —
/// the glow would otherwise just never come. Nothing here asks: the
/// first prompt belongs to the monitor turning the glow on, and a
/// refusal only deep-links to the pane that can undo it.
struct EventKitAccessNote: View {
    let entity: EKEntityType

    private var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: entity) }

    var body: some View {
        if Self.isRefused(status) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(entity == .event
                     ? "macOS has Calendar access turned off for JR-Bar — the glow cannot see your events until it is allowed."
                     : "macOS has Reminders access turned off for JR-Bar — the glow cannot see your reminders until it is allowed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open Settings") {
                    let pane = entity == .event ? "Privacy_Calendars" : "Privacy_Reminders"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    /// Denied and restricted are refusals; write-only calendar access is
    /// one too, since a glow needs to read the event's start.
    static func isRefused(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .denied, .restricted, .writeOnly: return true
        default: return false
        }
    }
}

struct FocusRuleRow: View {
    @Bindable var store: SettingsStore
    let focusID: String
    let name: String

    /// The rule for this Focus, read out of the rules object: the id is
    /// dotted, so it is a key, never a path.
    private var rule: Double? { store.document.object("focus_dim_rules")?[focusID]?.doubleValue }

    /// Writes the rules object whole with this Focus's entry set or
    /// removed. `focus_dim_rules.<id>` would split the dotted id into
    /// nested objects, which the daemon's loader drops — the rule never
    /// stuck.
    private func write(_ value: Double?, throttled: Bool = false) {
        let rules = LightProfiles.rules(store.document.object("focus_dim_rules"), setting: focusID,
                                        to: value.map(JSONValue.number))
        store.set("focus_dim_rules", rules, throttled: throttled)
    }

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
                    set: { on in write(on ? 0.3 : nil) }
                ))
                .toggleStyle(.checkbox)
                Slider(value: Binding(get: { rule ?? 0.3 }, set: { write($0, throttled: true) }), in: 0...1)
                    .frame(width: 130)
                    .disabled(rule == nil)
                ValueText(text: rule.map(SettingsStore.percent) ?? "idle dim")
            }
        } label: {
            SettingLabel(title: name, subtitle: "Dim to this level while the Focus is on.")
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
        SettingGroup("Peers") {
            SettingToggle(store, "Remote peers", subtitle: "Discover other Macs running JR-Bar and show their agents here.", path: "remote_peers.enabled")
            SettingToggle(store, "Publish this Mac", subtitle: "Lets peers read this desk's sessions.", path: "remote_peers.publish_enabled")
                .disabled(!(store.document.bool("remote_peers.enabled") ?? false))
            SettingToggle(store, "Mute remote asks", subtitle: "A peer's asks take no light here until you unmute that machine.",
                          path: "remote_peers.remote_interrupts_muted", default: true)
                .disabled(!(store.document.bool("remote_peers.enabled") ?? false))
            MachineList(store: store, path: "remote_peers.unmuted_machines", title: "Unmuted machines")
                .disabled(!(store.document.bool("remote_peers.enabled") ?? false))
            if store.document.bool("remote_peers.enabled") ?? false, let peers = store.core.state?.peers {
                LabeledContent("Fleet") {
                    if peers.isEmpty {
                        Text("No peers found").foregroundStyle(.secondary)
                    } else {
                        Text(peers.map { peer in
                            peer.reachable ? peer.machine : "\(peer.machine) — \(peer.failure ?? "unreachable")"
                        }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        SettingGroup("Serve", note: "The endpoint listens on loopback only; the token is fetched on demand and never stored by the app.") {
            SettingToggle(store, "Serve status", subtitle: "Opens a loopback endpoint so local tools can read this desk's status.", path: "serve_enabled")
            Provided(store, "serve_enabled") {
                SettingRow("Bearer token") {
                    Button("Copy token") { store.copyServeToken() }
                        .controlSize(.small)
                        .disabled(!(store.document.bool("serve_enabled") ?? false) || !store.core.isLive)
                        .help("Fetches the endpoint's bearer token from the monitor and copies it")
                }
            }
        }

        SettingGroup("Cloud ingest") {
            SettingToggle(store, "Cloud ingest", subtitle: "Opens a loopback port so off-machine agents can post their own lifecycle.", path: "cloud_ingest_enabled")
            Provided(store, "cloud_ingest_token_path") {
                SettingRow("Token file") {
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
        }

        SettingGroup("Webhook") {
            SettingTextField(store, "Webhook URL", subtitle: "POSTs stage-3 escalations whenever set.", path: "escalation_webhook_url", prompt: "https://", monospaced: true)
            Provided(store, "webhook_events") {
                MultiSelectMenu(store, "Also send",
                                subtitle: "Extra events to post alongside escalations.",
                                path: "webhook_events",
                                options: Self.webhookEvents)
            }
            .disabled((store.document.string("escalation_webhook_url") ?? "").isEmpty)
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

/// Settings › Devices & Screen Bar's Stream Deck card: the desk-side half
/// of the loopback status endpoint, next to the other pads. The switch is
/// the same `serve_enabled` Settings › Remote carries; the deck polls
/// `GET /status.json` with the bearer the Copy button fetches.
struct StreamDeckCard: View {
    @Bindable var store: SettingsStore

    /// `serve_token`'s `running` flag, refetched when the switch or the
    /// connection flips; nil until the core answers (older and mock cores
    /// return no flag at all).
    @ViewState private var running: Bool?

    private var enabled: Bool { store.document.bool("serve_enabled") ?? false }

    private var statusText: String {
        guard store.core.isLive else { return "Monitor not connected" }
        guard enabled else { return "Off — the endpoint is not serving" }
        switch running {
        case true: return "Serving on 127.0.0.1:8737"
        case false: return "Enabled, not serving"
        case nil: return "Enabled"
        }
    }

    private var statusColor: Color {
        guard enabled, store.core.isLive else { return .secondary }
        return running == true ? .green : .orange
    }

    var body: some View {
        SettingGroup("Stream Deck", note: "In the Stream Deck software, add an action that requests the URL with header “Authorization: Bearer <token>”. A sideloadable plugin scaffold lives in integrations/streamdeck/.") {
            SettingToggle(store, "Serve status", subtitle: "The loopback endpoint the deck polls; also on Settings › Remote.",
                          path: "serve_enabled")
            SettingRow("Endpoint") {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).foregroundStyle(.secondary)
                }
            }
            SettingRow("Status URL", subtitle: "GET it with the token as the Authorization: Bearer header; the reply carries redacted agent counts.") {
                HStack(spacing: 8) {
                    Text("http://127.0.0.1:8737/status.json")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Copy token") { store.copyServeToken() }
                        .controlSize(.small)
                        .disabled(!enabled || !store.core.isLive)
                        .help("Fetches the endpoint's bearer token from the monitor and copies it")
                }
            }
        }
        .task(id: enabled && store.core.isLive) { await refreshServeState() }
    }

    private func refreshServeState() async {
        guard enabled, store.core.isLive else { running = nil; return }
        let reply = try? await store.core.send("serve_token")
        running = reply?.result?["running"]?.boolValue
        // The core binds the socket on the settings echo; give it a beat
        // before the card calls a just-enabled endpoint "not serving".
        if enabled, running != true {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let again = try? await store.core.send("serve_token")
            running = again?.result?["running"]?.boolValue
        }
    }
}

// MARK: - Advanced

struct AdvancedPage: View {
    @Bindable var store: SettingsStore

    var body: some View {
        SettingGroup("Diagnostics") {
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
            SettingRow("State folder", subtitle: "The monitor's data on this Mac.") {
                Button("Reveal in Finder") { store.revealStateFolder() }
            }
            SettingRow("Doctor", subtitle: "Checks the monitor's health.") {
                Button(store.doctorRunning ? "Running…" : "Run Doctor") { store.runDoctor() }
                    .disabled(!store.core.isLive || store.doctorRunning)
            }
        }

        SettingGroup {
            LogTail(entries: store.core.logTail)
        } header: {
            HStack {
                Text("Core log")
                Spacer()
                Text("\(store.core.logTail.count) lines").font(.callout).foregroundStyle(.tertiary)
            }
        }

        SettingGroup(note: "Each button puts that page's settings back to the monitor's defaults. Devices keep their identities.") {
            // `catalogue == nil` pages (Toys) hold no daemon settings and
            // have nothing to reset.
            DisclosureRow("Reset to defaults", subtitle: "Rarely needed — puts one page's settings back.") {
                ForEach(SettingsStore.Page.allCases.filter { $0 != .advanced && $0.catalogue != nil }) { page in
                    LabeledContent(page.title) {
                        Button("Reset…") { store.resetTarget = page }
                            .controlSize(.small)
                            .disabled(!store.core.isLive)
                    }
                }
            }
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
                            // The daemon's level words run to "UPDATER";
                            // a fixed column that wraps broke it across two
                            // lines as "UPDATE / R".
                            Text((entry.level ?? "info").uppercased())
                                .foregroundStyle(entry.level == "error" ? Color.red : (entry.level == "warn" || entry.level == "warning" ? .orange : .secondary))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(minWidth: 44, alignment: .leading)
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
