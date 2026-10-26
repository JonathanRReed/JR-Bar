import JRBarCore
import JRBarUI
import SwiftUI

struct StudioCuesPage: View {
    @Bindable var store: EffectStudioStore
    var body: some View { LightMomentsView(store: store) }
}

struct StudioCueControls: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        SettingsGroup {
            SettingsRow("Celebrate completions") {
                Toggle("Celebrate completions", isOn: settings.bool("colors.done_celebration_enabled", default: true))
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Tint by tool") {
                Toggle("Tint by tool", isOn: settings.bool("colors.tint_by_tool"))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
        SettingSlider(settings, "Automatic speed", path: "colors.cycle_speed_seconds", in: 0.5...8,
                      step: 0.1, default: 2.2, format: SettingsStore.seconds)
        SettingToggle(settings, "Rainstick at night", path: "rainstick_night_enabled")
        MilestoneStepsField(store: settings)
    }
}

struct StudioStateColours: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
                SettingsGroup {
                    ForEach(SettingsKey.modes, id: \.self) { mode in
                        ModeSwatch(store: settings, mode: mode)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(JRBarTokens.Space.md)
                    }
                }
                ColorVisionNote(store: settings, colors: StudioPalette.states(settings), others: StudioPalette.providers(settings))
                SettingGroup("Pulse range") {
                    ForEach(SettingsKey.fadeModes, id: \.self) { FadeRow(store: settings, mode: $0) }
                }
                SettingGroup("Dimming") {
                    SettingSlider(settings, "Maximum brightness", path: "global_brightness_scale", in: 0.05...1,
                                  default: 1, format: SettingsStore.percent)
                    SettingToggle(settings, "Dim when idle", path: "idle_dim_enabled", default: true)
                    SettingSlider(settings, "After", path: "idle_dim_after_minutes", in: 1...180, step: 1,
                                  default: 10, format: SettingsStore.minutes)
                    SettingSlider(settings, "Idle brightness", path: "idle_dim_fraction", in: 0.05...1,
                                  default: 0.3, format: SettingsStore.percent)
                    SettingToggle(settings, "Dim on display sleep", path: "sleep_dim_enabled", default: true)
                    SettingSlider(settings, "Sleep brightness", path: "sleep_dim_fraction", in: 0.05...1,
                                  default: 0.2, format: SettingsStore.percent)
                    SettingToggle(settings, "Turn off when idle", path: "idle_auto_off_enabled")
                    SettingSlider(settings, "Off after", path: "idle_auto_off_after_minutes", in: 5...1440, step: 5,
                                  default: 60, format: SettingsStore.minutes)
                }
                AutoDimSection(store: settings)
            }.padding(JRBarTokens.Space.lg)
        }
    }
}

struct StudioScenesPage: View {
    @Bindable var store: EffectStudioStore
    var body: some View {
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
                sceneControls
                missingPack
                scenePacks
                importButton
            }.padding(JRBarTokens.Space.lg)
        }
    }
    private var importButton: some View {
        let action: () -> Void = store.importScenePack
        return Button("Import scene pack…", action: action)
    }

    private var scenePacks: some View {
        let packs: [ScenePackSummary] = store.scenePacks
        return ForEach(packs) { pack in ScenePackRow(pack: pack, store: store) }
    }

    private var sceneControls: some View {
        SettingsGroup {
            SettingsRow("Saved scene") { scenePicker }
            if store.activeSceneIsAutomatic {
                let name = EffectScene(rawValue: store.activeScene)?.label ?? store.activeScene
                SettingsRow("Playing now: \(name)") {
                    Button("Keep") { _ = store.setActiveScene(store.activeScene) }
                        .disabled(store.sceneChanging)
                }
            }
        }
    }

    @ViewBuilder private var missingPack: some View {
        if let activeID = store.activeScenePackID,
           !store.scenePacks.contains(where: { $0.id == activeID }) {
            SettingsGroup {
                SettingsRow("Pack unavailable: \(activeID)") {
                    Button("Use built-in scenes") { _ = store.setActiveScenePack(nil) }
                        .disabled(store.scenePackChanging)
                }
            }
        }
    }

    private var scenePicker: some View {
        Picker("Saved scene", selection: Binding(get: { store.selectedScene }, set: { _ = store.setActiveScene($0) })) {
            ForEach(EffectScene.allCases) { Text($0.label).tag($0.rawValue) }
        }.labelsHidden().disabled(store.sceneChanging)
    }
}

struct StudioDevicesPage: View {
    @Bindable var store: EffectStudioStore
    private var settings: SettingsStore { store.lightsStudio.settings }
    var body: some View {
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
                ForEach(settings.deviceEntries) { device in
                    StudioDeviceRows(settings: settings, device: device, mixes: store.lightsStudio.plan?.mixes ?? [])
                }
                // Device assignments appear here once, without repeating provider assignments.
                ForEach(store.devicePlayback) { assignment in
                    HStack {
                        Text("\(store.targetTitle(for: assignment)): \(store.catalog?.effect(assignment.effectID)?.label ?? assignment.effectID)")
                        Spacer()
                        Button("Remove") { _ = store.remove(assignment) }.disabled(store.isRemoving(assignment))
                    }
                    .padding(JRBarTokens.Space.md)
                }
                if settings.deviceEntries.isEmpty { Text("No devices configured").foregroundStyle(.secondary) }
            }.padding(JRBarTokens.Space.lg)
        }
    }
}

private struct StudioDeviceRows: View {
    @Bindable var settings: SettingsStore
    let device: SettingsStore.DeviceEntry
    let mixes: [StudioMix]
    private var mirrorsHardware: Bool {
        device.kind == "screen_bar" && (settings.values.bool("link_screen_bar_to_hardware") ?? true)
    }
    private var linked: Bool {
        device.kind == "dot" && (settings.values.bool("devices_linked") ?? true)
            && DotRole.parse(settings.values.string("dot_role")) != .status
    }
    var body: some View {
        SettingsGroup {
            SettingsRow("\(device.name): Display") {
                Picker("\(device.name) display", selection: settings.string("\(device.prefix).led_display", default: "agent")) {
                    ForEach(DevicesPage.displayModes, id: \.value) { Text($0.label).tag($0.value) }
                }.labelsHidden().disabled(linked)
            }
            SettingsRow("\(device.name): Mix") {
                Picker("\(device.name) mix", selection: settings.optionalString("\(device.prefix).blend_mode")) {
                    Text("Global Mix").tag("")
                    ForEach(mixes) { Text($0.name).tag($0.id) }
                }.labelsHidden().disabled(linked || mirrorsHardware)
            }
            SettingsRow("\(device.name): Asks only") {
                Toggle("\(device.name) asks only", isOn: Binding(
                    get: { settings.values.string(SettingsPath("\(device.prefix).signal_policy")) == "asks_only" },
                    set: { settings.set("\(device.prefix).signal_policy", $0 ? .string("asks_only") : .null) }
                )).labelsHidden().toggleStyle(.switch).disabled(linked)
            }
            SettingsRow("\(device.name): Provider") {
                Picker("\(device.name) provider", selection: settings.optionalString("\(device.prefix).provider_pin")) {
                    Text("All providers").tag("")
                    ForEach(SettingsKey.providers.filter { $0 != "t3code" }, id: \.self) {
                        Text(ProviderPalette.displayName(for: $0)).tag($0)
                    }
                }.labelsHidden().disabled(linked)
            }
            if device.kind == "dot", device.id == settings.deviceEntries.first(where: { $0.kind == "dot" })?.id {
                SettingsRow("\(device.name): Role") {
                    Picker("Dot role", selection: settings.string("dot_role", default: DotRole.extend.rawValue)) {
                        ForEach(DotRole.allCases) { Text($0.label).tag($0.rawValue) }
                    }.labelsHidden().disabled(!(settings.values.bool("devices_linked") ?? true))
                }
                SettingsRow("\(device.name): Finished runs") {
                    Toggle("Also show finished runs", isOn: settings.bool("dot_role_include_completions"))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!DotRole.parse(settings.values.string("dot_role")).usesCompletions)
                }
            }
            if linked { Text("\(device.name) follows the strip.")
                .jrbarType(.caption).foregroundStyle(.secondary).padding(JRBarTokens.Space.md) }
        }
    }
}

/// The existing palette check uses the same configured colours as the controls.
@MainActor
enum StudioPalette {
    static func providers(_ settings: SettingsStore) -> [ColorVisionNote.Entry] {
        SettingsKey.providers.filter { provider in
            provider != "t3code" && (settings.runningProviders.contains(provider)
                || (settings.hookStatus(provider).map { $0 != "missing" } ?? false))
        }.map { provider in
            let style = settings.providerStyle(provider)
            let path = "colors.agent_colors.\(provider)"
            return ColorVisionNote.Entry(id: provider, name: style.name, path: path,
                                         hex: settings.values.string(SettingsPath(path)) ?? style.accentHex)
        }
    }

    static func states(_ settings: SettingsStore) -> [ColorVisionNote.Entry] {
        SettingsKey.modes.filter { $0 != "idle" }.map { mode in
            let path = "colors.mode_colors.\(mode)"
            return ColorVisionNote.Entry(id: mode, name: ModeSwatch.labels[mode]?.name ?? mode.capitalized,
                                         path: path, hex: settings.values.string(SettingsPath(path)) ?? ModeSwatch.defaults[mode] ?? "#8E8E93")
        }
    }
}
