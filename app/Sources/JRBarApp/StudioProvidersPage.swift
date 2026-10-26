import JRBarCore
import JRBarUI
import SwiftUI

struct StudioProvidersPage: View {
    @Bindable var store: EffectStudioStore
    var body: some View {
        SnapshotScrollView {
            VStack(spacing: JRBarTokens.Space.md) {
                if let failure = store.lightsStudio.supportingFailure { StatusBanner(failure, kind: .attention) }
                ForEach(store.providerTargets.filter { $0.id != "t3code" }, id: \.id) { provider in
                    StudioProviderRow(store: store, provider: provider.id)
                }
                ColorVisionNote(store: store.lightsStudio.settings, colors: StudioPalette.providers(store.lightsStudio.settings))
            }.padding(JRBarTokens.Space.lg)
        }
    }
}

private struct StudioProviderRow: View {
    @Bindable var store: EffectStudioStore
    let provider: String
    private var settings: SettingsStore { store.lightsStudio.settings }
    private var motion: String {
        store.pendingProviderMotion(provider) ?? settings.values.string(SettingsPath("colors.provider_animation.\(provider)")) ?? "auto"
    }
    private var effects: [EffectDefinition] {
        (store.catalog?.effects ?? []).filter { $0.catalog == "provider_animation" && $0.id != "auto" }
            .sorted(by: EffectStudioStore.libraryOrder)
    }
    private var effect: EffectDefinition? { effects.first { $0.id == motion } }
    private var parameters: [String: JSONValue] {
        if let pending = store.pendingProviderParameters(provider) { return effect?.normalizedParameters(pending) ?? pending }
        let row = store.assignments?.assignments.first { $0.scope == .provider && $0.targetID == provider && $0.effectID == motion }
        let table = settings.values.object("colors.provider_animation_parameters")
        let playback = table.map { $0[provider]?.objectValue ?? [:] }
        guard let effect else { return playback ?? row?.parameters ?? [:] }
        return EffectStudioStore.providerParameters(effect, assignment: row?.parameters ?? [:], playback: playback)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            HStack(spacing: JRBarTokens.Space.md) {
                ProviderLogoTile(provider: provider, size: 28, accent: settings.providerStyle(provider).accent)
                Text(ProviderPalette.displayName(for: provider)).jrbarType(.headline)
                Spacer()
                if let program = store.lightsStudio.providerPrograms[provider] {
                    LEDStripPreview(program: program, ledCount: 8, style: .band, dotSize: 6,
                                    paused: !store.isLive, showsBackground: true).frame(width: 120)
                } else { Text("Preview unavailable").jrbarType(.caption).foregroundStyle(.secondary) }
                ColorPicker("\(ProviderPalette.displayName(for: provider)) colour",
                            selection: settings.color("colors.agent_colors.\(provider)", default: settings.providerStyle(provider).accentHex),
                            supportsOpacity: false).labelsHidden()
                Picker("Animation", selection: Binding(get: { motion }, set: { id in
                    let chosen = id == "auto" ? store.catalog?.effect("auto") : effects.first { $0.id == id }
                    _ = store.saveProvider(provider, effect: chosen)
                })) {
                    Text("Automatic").tag("auto")
                    ForEach(effects) { Text($0.label).tag($0.id) }
                    if motion != "auto", effect == nil { Text("Unavailable: \(motion)").tag(motion) }
                }
                .frame(width: 180)
            }
            if let effect {
                ForEach(effect.parameters.filter { $0.name != "color" && $0.name != "repeat" && $0.name != "pass_mode" }) { parameter in
                    EffectParameterRow(parameter: parameter, value: parameters[parameter.name] ?? parameter.defaultValue,
                                       effectID: effect.id) { value in
                        var values = parameters
                        values[parameter.name] = parameter.normalize(value)
                        _ = store.saveProvider(provider, effect: effect, parameters: values)
                    }
                }
            }
        }
        .padding(JRBarTokens.Space.md)
        .background(JRBarTokens.Ink.content, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
        .disabled(!store.isLive)
    }
}
