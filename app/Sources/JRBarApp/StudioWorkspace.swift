import JRBarCore
import JRBarUI
import SwiftUI

struct StudioWorkspace: View {
    @Bindable var store: EffectStudioStore
    private var lights: EffectStudioLights { store.lightsStudio }
    @Environment(\.renderSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                StudioStage(store: store)
                Divider()
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if lights.inspector {
                Divider()
                StudioPlanInspector(lights: lights) { store.mode = .devices; lights.inspector = false }
                    .frame(width: 240)
            }
        }
        .jrbarType(.body)
        .task(id: lights.previewKey) {
            guard !snapshot else { return }
            await lights.refreshPlan()
            await lights.refreshPreviews()
            await lights.refreshSupportingPreviews()
        }
        .task(id: store.core.lights?.surfaces) {
            if !snapshot { await lights.refreshPlan() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            Text("Studio").jrbarType(.heading).padding(JRBarTokens.Space.md)
            ForEach(EffectStudioStore.Mode.allCases) { mode in
                Button { store.mode = mode } label: {
                    Label(mode.label, systemImage: mode.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(JRBarTokens.Space.sm)
                        .background(store.mode == mode ? JRBarTokens.Ink.accentSoft : .clear,
                                    in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(store.mode == mode ? .isSelected : [])
            }
            Spacer()
        }
        .padding(JRBarTokens.Space.sm)
        .frame(width: 168)
        .background(.bar)
    }

    @ViewBuilder private var page: some View {
        switch store.mode {
        case .mix: StudioMixPage(store: store)
        case .providers: StudioProvidersPage(store: store)
        case .moments: StudioCuesPage(store: store)
        case .colours: StudioStateColours(settings: lights.settings)
        case .profiles:
            SnapshotScrollView {
                CalibrationProfilesSection(store: lights.settings)
                    .environment(\.settingGroupsInline, true)
                    .padding(JRBarTokens.Space.lg)
            }
        case .assignments: EffectAssignmentsPane(store: store)
        case .scenes: StudioScenesPage(store: store)
        case .devices: StudioDevicesPage(store: store)
        case .effects: storeView.effectsRoom
        case .program: LEDSStudioView(store: store, model: store.ledsStudio)
        }
    }

    private var storeView: EffectStudioView { EffectStudioView(store: store) }
}

struct StudioStage: View {
    @Bindable var store: EffectStudioStore
    private var lights: EffectStudioLights { store.lightsStudio }
    private var program: String { lights.program ?? "off" }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.md) {
            HStack {
                Text(store.mode.label).jrbarType(.heading)
                Spacer()
                Button { lights.inspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .labelStyle(.iconOnly)
                .help("Show light plan inspector")
                .accessibilityValue(lights.inspector ? "Shown" : "Hidden")
            }
            HStack(spacing: JRBarTokens.Space.xxl) {
                GeometryReader { geometry in
                    let width = max(0, geometry.size.width - JRBarTokens.Space.xxxl)
                    let metrics = LEDStripPreview.dotMetrics(ledCount: 8, width: width, dotSize: 24, spacing: 16, padded: true)
                    VStack(spacing: JRBarTokens.Space.md) {
                        LEDStripPreview(program: program, ledCount: 8, style: .dots,
                                        dotSize: metrics.dotSize, spacing: metrics.spacing, paused: !store.isLive,
                                        showsBackground: true)
                            .accessibilityLabel("Eight LED strip preview")
                        LEDStripPreview(program: lights.screenProgram ?? program, ledCount: 8, style: .band,
                                        dotSize: 8, paused: !store.isLive, showsBackground: false)
                            .frame(maxWidth: 340)
                            .accessibilityLabel("Screen Bar preview")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 112)
                .padding(JRBarTokens.Space.lg)
                .background(JRBarTokens.Ink.secondaryFill,
                            in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
                VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                    Text("Preview as if").jrbarType(.section)
                    Picker("Preview as if", selection: Binding(get: { lights.scenario }, set: { lights.scenario = $0 })) {
                        ForEach(EffectStudioLights.Scenario.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Toggle("Play on devices", isOn: Binding(get: { lights.playOnDevices }, set: { lights.playOnDevices = $0 }))
                        .toggleStyle(.checkbox)
                    Button("Play preview", systemImage: "play.fill") { play() }
                        .disabled(lights.scenario == .live || lights.program == nil || lights.failure != nil || !store.isLive || lights.refreshing || lights.playing)
                        .help(lights.scenario == .live ? "Live activity is already playing" : "Play this situation for 5 seconds")
                }
                .frame(width: 266)
            }
            StudioWhatPlays(lights: lights)
        }
        .padding(JRBarTokens.Space.lg)
    }

    private func play() {
        let hardware = lights.playOnDevices && store.hasHardware
        if hardware, !store.hardwareConsent {
            store.pendingHardwarePlay = { _ = lights.playPreview() }
            store.askingConsent = true
        } else { _ = lights.playPreview() }
    }
}

struct StudioWhatPlays: View {
    @Bindable var lights: EffectStudioLights

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("What plays").jrbarType(.headline)
                if !lights.core.isLive { Text("Last preview · disconnected").foregroundStyle(JRBarTokens.Ink.attention) }
                if lights.core.isLive, (lights.scenario == .live ? lights.planFailure : lights.failure) != nil {
                    Text("Last preview").foregroundStyle(JRBarTokens.Ink.attention)
                }
                Spacer()
                if lights.refreshing { Text("Updating").foregroundStyle(.secondary) }
            }
            if let failure = lights.playFailure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(JRBarTokens.Ink.attention)
            }
            ForEach(lights.auditions.keys.sorted(), id: \.self) { name in
                if let audition = lights.auditions[name] {
                    Text("Last preview on \(name): \(audition.reason)").jrbarType(.caption)
                    warnings(audition.playbackWarnings)
                }
            }
            if let failure = lights.scenario == .live ? lights.planFailure : lights.failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(JRBarTokens.Ink.attention)
            }
            if lights.scenario == .live {
                if let plan = lights.plan {
                    ForEach(plan.devices) { device in
                        Text("\(lights.deviceName(device.device)): \(device.reason)")
                        if let cue = device.cueReason { Text(cue).foregroundStyle(.secondary) }
                        warnings(device.playbackWarnings)
                    }
                    if plan.devices.isEmpty { Text("No light devices are configured.").foregroundStyle(.secondary) }
                } else { Text("Waiting for the daemon's light plan.").foregroundStyle(.secondary) }
            } else if let preview = lights.selectedPreview {
                Text(preview.reason)
                Text(preview.label).jrbarType(.caption).foregroundStyle(.secondary)
                warnings(preview.playbackWarnings)
            } else { Text("Waiting for the daemon's preview.").foregroundStyle(.secondary) }
            if lights.scenario != .live {
                ForEach(lights.plan?.devices.filter { !$0.warnings.isEmpty } ?? []) { device in
                    Text("Live \(lights.deviceName(device.device)): \(device.reason)").jrbarType(.caption)
                    warnings(device.playbackWarnings)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(JRBarTokens.Space.md)
        .background(JRBarTokens.Ink.fill, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func warnings(_ rows: [String]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, text in
            Label(text, systemImage: "exclamationmark.triangle")
                .jrbarType(.caption).foregroundStyle(JRBarTokens.Ink.attention)
        }
    }
}

private struct StudioPlanInspector: View {
    @Bindable var lights: EffectStudioLights
    let openDevices: () -> Void
    var body: some View {
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.md) {
                Text("Devices").jrbarType(.headline)
                if let failure = lights.planFailure { Text(failure).foregroundStyle(JRBarTokens.Ink.attention) }
                ForEach(lights.plan?.devices ?? []) { device in
                    Text(lights.deviceName(device.device)).jrbarType(.headline)
                    Text("\(device.ledCount) LEDs")
                    if let mix = lights.plan?.mixes.first(where: { $0.id == device.requestedMix }) {
                        Text("Mix: \(mix.name)").foregroundStyle(.secondary)
                    }
                    Divider()
                }
                Button("Edit devices", action: openDevices)
            }.padding(JRBarTokens.Space.lg)
        }
    }
}
