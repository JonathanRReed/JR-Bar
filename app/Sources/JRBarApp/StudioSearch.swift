import JRBarCore
import SwiftUI

extension EffectStudioStore {
    /// Search selects the page and the rendered control without changing a setting.
    func reveal(_ entry: SettingsSearchEntry) {
        let settings = lightsStudio.settings
        let target: (Mode, String)
        switch entry.group {
        case "Calibration profiles": target = (.profiles, "calibration_profiles")
        case "Provider colours", "Provider colours and animations":
            target = (.providers, "colors.agent_colors.claude")
        case "State colours": target = (.colours, "colors.mode_colors.idle")
        case "Pulse range": target = (.colours, "colors.fade_floor.idle")
        case "Dimming":
            let paths = ["Dim when idle": "idle_dim_enabled", "After": "idle_dim_after_minutes",
                         "Idle brightness": "idle_dim_fraction", "Dim on display sleep": "sleep_dim_enabled",
                         "Sleep brightness": "sleep_dim_fraction", "Turn off when idle": "idle_auto_off_enabled",
                         "Off after": "idle_auto_off_after_minutes"]
            target = (.colours, paths[entry.title] ?? "idle_dim_enabled")
        case "Auto-dim":
            let paths = ["Between": "auto_dim.schedule.start_minutes", "Dim to": "auto_dim.schedule.fraction",
                         "Never below": settings.values.string("auto_dim.mode") == "ambient"
                            ? "auto_dim.ambient.min_fraction" : "auto_dim.display.min_fraction",
                         "Dark below": "auto_dim.ambient.lux_floor", "Bright above": "auto_dim.ambient.lux_ceiling",
                         "Marks from room": "studio.roomMarks", "Learned from you": "auto_dim.ambient.min_fraction",
                         "Right now": "auto_dim.mode"]
            target = (.colours, paths[entry.title] ?? "auto_dim.mode")
        case "Scene": target = (.scenes, "active_scene")
        default:
            switch entry.title {
            case "Blend mode": target = (.mix, "colors.blend_mode")
            case "Cycle speed": target = (.moments, "colors.cycle_speed_seconds")
            case "Celebrate completions": target = (.moments, "colors.done_celebration_enabled")
            case "Celebration preview", "Finish": target = (.moments, "colors.done_celebration_style")
            case "Tint by tool": target = (.moments, "colors.tint_by_tool")
            case "Scene pack": target = (.scenes, "studio.scenePacks")
            case "Also at night": target = (.moments, "rainstick_night_enabled")
            case "Milestones": target = (.moments, "milestone_odometer_steps")
            case "Rainstick idle": target = (.moments, "rainstick_idle_enabled")
            case "Completion milestones": target = (.moments, "milestone_odometer_enabled")
            case "Look": target = (.devices, "dot_extend_style")
            case "Mirror hardware strip": target = (.devices, "link_screen_bar_to_hardware")
            case "Phase nudge": target = (.devices, "screen_bar_phase_offset_ms")
            case "Minimum glow": target = (.devices, "screen_bar_min_glow")
            case "Hold still on camera": target = (.devices, ScreenBarController.stillOnCameraDefaultsKey)
            case "Role": target = (.devices, "dot_role")
            case "Also glow for finished runs": target = (.devices, "dot_role_include_completions")
            default:
                let device = settings.deviceEntries.first { entry.group != "Screen Bar" || $0.kind == "screen_bar" }
                let paths = ["Display": "led_display", "Pin to": "provider_pin", "Asks only": "signal_policy", "Blend": "blend_mode"]
                target = (.devices, "\(device?.prefix ?? "devices.0").\(paths[entry.title] ?? "led_display")")
            }
        }
        mode = target.0
        searchPath = target.1
        searchRequest += 1
    }
}

struct StudioSearchPage<Content: View>: View {
    @Bindable var store: EffectStudioStore
    @ViewState private var paths: Set<String> = []
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .environment(\.studioSearchPath, store.searchPath)
                .onPreferenceChange(SettingsControlPaths.self) { paths = $0 }
                .onChange(of: store.lightsStudio.settings.values.string("auto_dim.mode")) { _, _ in
                    store.searchPath = nil
                }
                .task(id: "\(store.searchRequest)/\(store.searchPath.map(paths.contains) ?? false)") {
                    guard let path = store.searchPath, paths.contains(path) else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(path, anchor: .center)
                }
        }
    }
}

private struct StudioSearchPathKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var studioSearchPath: String? {
        get { self[StudioSearchPathKey.self] }
        set { self[StudioSearchPathKey.self] = newValue }
    }
}
