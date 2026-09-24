import JRBarCore
import SwiftUI

/// The Aquarium card's swimming rows (docs/TOYS.md §Aquarium, Swimming):
/// how busy the fish are, how big they draw and how fast they swim.
/// The card's Fine-tune section mounts it with a binding to the tank's
/// settings; every row writes straight through.
struct AquariumSwimRows: View {
    @Binding var settings: AquariumSettings

    init(settings: Binding<AquariumSettings>) {
        _settings = settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Picker("", selection: $settings.swimPace) {
                    ForEach(SwimPace.allCases, id: \.self) { pace in
                        Text(pace.displayName).tag(pace)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            } label: {
                SettingLabel(title: "Swim pace", subtitle: "How often fish wander and turn.")
            }
            LabeledContent {
                slider(value: fishScale, in: AquariumSettings.fishScaleRange)
            } label: {
                SettingLabel(title: "Fish size", subtitle: "Every fish, and what you can tap with it.")
            }
            LabeledContent {
                slider(value: swimSpeed, in: AquariumSettings.swimSpeedRange)
            } label: {
                SettingLabel(title: "Swimming speed",
                             subtitle: "Faster fish turn faster too, so their paths keep their shape.")
            }
        }
    }

    private var fishScale: Binding<Double> {
        Binding(get: { AquariumSettings.clamped(settings.fishScale, to: AquariumSettings.fishScaleRange) },
                set: { settings.fishScale = AquariumSettings.clamped($0, to: AquariumSettings.fishScaleRange) })
    }

    private var swimSpeed: Binding<Double> {
        Binding(get: { AquariumSettings.clamped(settings.swimSpeed, to: AquariumSettings.swimSpeedRange) },
                set: { settings.swimSpeed = AquariumSettings.clamped($0, to: AquariumSettings.swimSpeedRange) })
    }

    private func slider(value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: 0.05)
                .frame(width: 150)
            ValueText(text: String(format: "%.2f×", value.wrappedValue))
        }
    }
}
