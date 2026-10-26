import JRBarCore
import JRBarUI
import SwiftUI

struct StudioMixPage: View {
    @Bindable var store: EffectStudioStore
    private var lights: EffectStudioLights { store.lightsStudio }
    private let groups: [(String, [String])] = [
        ("Share the strip", ["spatial_split", "cycle", "round_robin"]),
        ("Mix animations", ["alternate", "relay", "weave", "tide"]),
        ("Calm", ["color_blend", "classic"]),
    ]

    var body: some View {
        GeometryReader { geometry in
            SnapshotScrollView {
                VStack(alignment: .leading, spacing: JRBarTokens.Space.xl) {
                    if lights.mix == "cycle", !store.spotlightExplained {
                        StatusBanner("Spotlight is now One at a Time", detail: "Each provider gets the whole strip for 4 seconds.") {
                            Button("Dismiss") { store.spotlightExplained = true }
                        }
                    }
                    ForEach(groups, id: \.0) { title, ids in
                        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                            Text(title).jrbarType(.section)
                            cards(ids, columns: ids.count == 4 && geometry.size.width < 640 ? 2 : ids.count)
                        }
                    }
                    if lights.plan == nil { Text(lights.planFailure ?? "Waiting for the mix catalog.").foregroundStyle(.secondary) }
                    if let selected = lights.plan?.mixes.first(where: { $0.id == lights.mix }),
                       !selected.parameters.isEmpty || selected.id == "spatial_split" || selected.id == "cycle" {
                        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                            if selected.id == "spatial_split" {
                                Text("The extra LED goes to the agent that needs you most, then the one that started first.")
                            } else if selected.id == "cycle" {
                                Text("Each provider holds the strip for 4 seconds.")
                            }
                            ForEach(selected.parameters, id: \.key) { parameter in
                                let path = "colors.mix_parameters.\(selected.id).\(parameter.key)"
                                EffectParameterRow(parameter: parameter.control,
                                                   value: lights.settings.values.value(at: SettingsPath(path)) ?? .number(parameter.default)) {
                                    lights.settings.set(path, $0, throttled: true)
                                }
                            }
                        }
                        .padding(JRBarTokens.Space.md)
                        .background(JRBarTokens.Ink.fill, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
                    }
                }
                .padding(JRBarTokens.Space.lg)
            }
        }
        .disabled(!store.isLive)
        .settingControl(lights.plan?.mixes.isEmpty == false ? ["colors.blend_mode"] : [])
    }
    private func cards(_ ids: [String], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 140)), count: columns), spacing: JRBarTokens.Space.sm) {
            ForEach(ids, id: \.self) { id in
                if let mix = lights.plan?.mixes.first(where: { $0.id == id }) {
                    StudioMixCard(mix: mix, preview: lights.preview(id), selected: lights.mix == id,
                                  connected: store.isLive) {
                        lights.settings.set("colors.blend_mode", .string(id))
                    }
                }
            }
        }
        .frame(minWidth: CGFloat(columns) * 140 + CGFloat(columns - 1) * JRBarTokens.Space.sm)
    }

}

private struct StudioMixCard: View {
    let mix: StudioMix
    let preview: StudioFleetPreview?
    let selected: Bool
    let connected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                HStack {
                    Text(mix.name).jrbarType(.headline)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
                LEDStripPreview(program: preview?.program ?? "off", ledCount: 8, style: .dots,
                                dotSize: 6, spacing: 5, paused: !connected)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(mix.name) daemon preview")
                if mix.id == "classic" || mix.id == "color_blend" {
                    Text("Holds still. Asks still blink.").jrbarType(.caption).foregroundStyle(.secondary)
                }
                if let warning = preview?.playbackWarnings.first {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .jrbarType(.caption).foregroundStyle(JRBarTokens.Ink.attention).lineLimit(2)
                        .help(preview?.playbackWarnings.joined(separator: " ") ?? warning)
                } else if preview == nil {
                    Text("Preview unavailable").jrbarType(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .padding(JRBarTokens.Space.md)
            .background(selected ? JRBarTokens.Ink.accentSoft : JRBarTokens.Ink.content,
                        in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
            .overlay(RoundedRectangle(cornerRadius: JRBarTokens.Radius.group)
                .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(JRBarTokens.Ink.separator), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
