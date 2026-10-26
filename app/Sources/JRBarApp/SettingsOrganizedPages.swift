import JRBarCore
import JRBarUI
import SwiftUI

struct SettingsBackRow: View {
    let store: SettingsStore
    var body: some View {
        Button {
            store.subpage = nil
            store.selectedProvider = nil
            store.searchHit = nil
            store.highlightedCard = nil
        } label: {
            Label(store.page.title, systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .foregroundStyle(JRBarTokens.Ink.accent)
    }
}

struct SettingsStudioLink: View {
    let store: SettingsStore
    var body: some View {
        SettingsGroup {
            SettingsNavigationRow("Open Studio") { store.onOpenEffects?() }
        }
    }
}

struct SettingsUsageOptions: View {
    let store: SettingsStore
    var body: some View {
        SettingGroup("Usage") {
            SettingsNavigationRow("Usage Center") { store.onOpenUsageCenter?() }
            SettingToggle(store, "Token history", path: "token_history_enabled", default: true)
            SettingPicker(store, "Lead with", path: "usage_display_mode", options: [
                ("tokens", "Tokens"), ("cost", "Cost"),
            ], default: "tokens", segmented: true)
            SettingIntPicker(store, "Graph range", path: "usage_graph_days", options: [
                (7, "7 days"), (30, "30 days"), (90, "90 days"), (365, "A year"),
            ], default: 7)
        }
        SettingGroup("Asks") {
            SettingToggle(store, "Sub-agent asks", subtitle: SubagentAsksCopy.subtitle, path: "subagent_asks_alert")
            SettingsRow("Try an ask") {
                Button("Show a Demo Ask") { DemoAskStore.shared.tryIt() }
            }
        }
        SettingGroup("Quota alerts") {
            SettingToggle(store, "Alert at thresholds", path: "quota_alerts_enabled", default: true)
            Provided(store, "quota_alert_thresholds") { ThresholdRow(store: store) }
        }
    }
}

struct SettingsPrivacyPage: View {
    let store: SettingsStore
    var body: some View {
        SettingGroup("Transcripts") {
            Provided(store, "transcript_monitoring.claude", "transcript_monitoring.codex",
                     "transcript_monitoring.gemini", "transcript_monitoring.pi") {
                MultiSelectMenu(store, "Watch transcripts", keyPrefix: "transcript_monitoring",
                                options: SettingsKey.transcriptProviders.map { ($0, ProviderStyle.style(for: $0).name) },
                                providerTiles: true)
            }
        }
        SettingGroup("Presence") {
            SettingToggle(store, "Mic and camera presence", path: "presence_enabled", default: true)
        }
        SettingGroup("History") {
            SettingToggle(store, "Keep history", path: "capacity_history_enabled")
            SettingIntPicker(store, "Keep for", path: "capacity_history_retention_days", options: [
                (1, "1 day"), (7, "7 days"), (30, "30 days"), (90, "90 days"),
            ], default: 7).disabled(!(store.values.bool("capacity_history_enabled") ?? false))
        }
        SettingGroup("Network requests") {
            SettingToggle(store, "Provider status pages", subtitle: ProviderStatusPagesCopy.subtitle,
                          path: "provider_status_feeds_enabled")
            SettingToggle(store, "Check for agent updates", subtitle: ProviderUpdateChecksCopy.subtitle,
                          path: "provider_update_checks_enabled")
        }
        .onChange(of: store.values.bool("provider_update_checks_enabled") ?? false) { _, on in
            if on { store.core.checkProviderUpdates() }
        }
        SettingsGroup {
            SettingsNavigationRow("Provider usage") { store.page = .agents }
            SettingsNavigationRow("Remote") { store.page = .remote }
        }
    }
}

struct DeviceHardwareSettings: View {
    let store: SettingsStore
    let device: SettingsStore.DeviceEntry
    private var linkedBrightness: Bool {
        device.kind == "dot" && (store.values.bool("devices_linked") ?? true)
            && DotRole.parse(store.values.string("dot_role")) != .status
            && (store.values.bool("linked_follow_brightness") ?? true)
    }
    var body: some View {
        if device.kind != "screen_bar" {
            SettingToggle(store, "Use this device", path: "\(device.prefix).enabled", default: true)
        }
        SettingSlider(store, "Brightness", subtitle: linkedBrightness ? "Follows the strip's brightness." : nil,
                      path: "\(device.prefix).brightness", in: 0...255,
                      step: 1, default: 255) { "\(Int(($0 / 255 * 100).rounded()))%" }
            .disabled(linkedBrightness || (store.values.bool(SettingsPath("\(device.prefix).auto_brightness_enabled")) ?? false))
        SettingToggle(store, "Auto-brightness", path: "\(device.prefix).auto_brightness_enabled")
            .disabled(linkedBrightness)
        DeviceCalibrationRow(store: store, deviceID: device.id, prefix: device.prefix)
    }
}

struct SettingsFeatureDetail: View {
    let toy: any Toy
    var body: some View {
        SettingsGroup {
            SettingsRow(toy.switchLabel) {
                Toggle(toy.switchLabel, isOn: Binding(get: { toy.isOn }, set: { toy.isOn = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
        .id(SettingsStore.cardAnchor(toy.id))
        toy.controls
            .cardBodyStyle()
            .padding(JRBarTokens.Space.md)
    }
}

struct ClaudePlanLimitsRow: View {
    let store: SettingsStore
    var body: some View {
        Provided(store, "claude_plan_limits_enabled") {
            SettingsRow("Read plan limits", subtitle: "Reads official quota windows from Anthropic after you turn it on.") {
                Toggle("Read plan limits", isOn: Binding(
                    get: { store.values.bool("claude_plan_limits_enabled") ?? false },
                    set: { store.setClaudePlanLimits($0) }
                )).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}


/// Output choices stay in Studio; device calibration stays in Devices.
struct DeviceLightingOverrides: View {
    let store: SettingsStore

    var body: some View {
        SettingGroup("Pro & Dot") {
            SettingToggle(store, "Dot follows strip", path: "devices_linked", default: true)
            SettingSlider(store, "Dot brightness", path: "linked_dot_scale", in: 0.05...1,
                          step: 0.05, default: 0.3, format: SettingsStore.percent)
                .disabled(!(store.values.bool("devices_linked") ?? true))
            LinkedBrightnessToggle(store: store)
            DotRoleControls(store: store, inDeviceCard: false)
            LinkedSyncControls(store: store)
        }
        ForEach(store.deviceEntries) { device in
            SettingGroup(device.name) {
                DeviceLightSettings(store: store, device: device)
                if device.kind == "dot" { DotTravelStyleRow(store: store, device: device) }
            }
        }
        ScreenBarMotionSettings(store: store)
    }
}

struct ScreenBarMotionSettings: View {
    let store: SettingsStore
    @AppStorage(ScreenBarController.stillOnCameraDefaultsKey) private var stillOnCamera = true

    var body: some View {
        SettingGroup("Screen Bar motion") {
            SettingToggle(store, "Mirror hardware strip", path: "link_screen_bar_to_hardware", default: true)
            SettingSlider(store, "Phase nudge", path: "screen_bar_phase_offset_ms", in: -500...500,
                          step: 10, default: 0) { "\(Int($0)) ms" }
                .disabled(!(store.values.bool("link_screen_bar_to_hardware") ?? true))
            SettingSlider(store, "Minimum glow", path: "screen_bar_min_glow", in: 0...1,
                          default: 0.25, format: SettingsStore.percent)
            SettingsRow("Hold still on camera", subtitle: ScreenBarCameraHold.subtitle(
                cameraReadable: ScreenBarLiveStatus.shared.cameraReadable)) {
                Toggle("Hold still on camera", isOn: $stillOnCamera).labelsHidden().toggleStyle(.switch)
                    .disabled(!ScreenBarLiveStatus.shared.cameraReadable)
            }
        }
    }
}
