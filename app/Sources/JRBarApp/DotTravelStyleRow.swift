import JRBarCore
import SwiftUI

/// A Dot's "Travel" row: how a travelling motion (a chase, a comet, a
/// scanner) plays on two LEDs. Wipe lights one LED, then the other, then
/// lets go in the same order, so the Dot shows which way the light is
/// going; Crossfade is the older soft swap. Only a Dot shows it
/// (`devices.N.dot_travel_style`).
struct DotTravelStyleRow: View {
    @Bindable var store: SettingsStore
    let device: SettingsStore.DeviceEntry

    static let choices: [(value: String, label: String)] = [
        ("wipe", "Wipe"), ("crossfade", "Crossfade"),
    ]

    private var path: String { "\(device.prefix).dot_travel_style" }
    private var style: String { store.document.string(SettingsPath(path)) ?? "wipe" }

    var body: some View {
        if device.kind == "dot" {
            Provided(store, path) {
                SettingRow("Travel", subtitle: Self.subtitle(style)) {
                    HStack(spacing: 10) {
                        LEDStripPreview(program: Self.program(style), ledCount: 2, style: .dots, dotSize: 8, spacing: 5)
                            .frame(width: 52)
                            .accessibilityLabel("\(style == "crossfade" ? "Crossfade" : "Wipe") preview")
                        Picker("Travel", selection: store.string(path, default: "wipe")) {
                            ForEach(Self.choices, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
            }
        }
    }

    static func subtitle(_ style: String) -> String {
        style == "crossfade"
            ? "The two LEDs swap softly; the light never goes out."
            : "One LED lights, then the other, then they let go in turn, so you can see which way the light is going."
    }

    /// The monitor's two-LED travel at the default 2.2 s cycle
    /// (`motion_shapes.dot_wipe` and the rolled `DOT_TAIL`).
    static func program(_ style: String) -> String {
        let peak = "#00E5FF"
        if style == "crossfade" {
            let dim = LightingPreviewPrograms.scaled(peak, 0.16)
            return "\(peak) \(dim) 275ms cosine\nroll-right 2200ms linear\nrepeat"
        }
        let rest = LightingPreviewPrograms.scaled(peak, 0.10)
        return ["0:\(peak) 550ms cosine", "1:\(peak) 550ms cosine",
                "0:\(rest) 550ms cosine", "1:\(rest) 550ms cosine", "repeat"].joined(separator: "\n")
    }
}
