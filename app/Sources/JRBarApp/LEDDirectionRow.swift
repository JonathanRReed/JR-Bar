import JRBarCore
import SwiftUI

/// A device card's "Strip direction" row: which way round the strip is
/// mounted, and a sweep that starts from LED 0 so you can match it to the
/// strip on your desk. Reversed mirrors every agent light the monitor
/// draws for this device (`devices.N.led_direction`), so a comet that ran
/// left to right still does after the strip is turned round.
struct LEDDirectionRow: View {
    @Bindable var store: SettingsStore
    let device: SettingsStore.DeviceEntry

    static let choices: [(value: String, label: String)] = [
        ("forward", "LED 0 left"), ("reversed", "LED 0 right"),
    ]

    private var path: String { "\(device.prefix).led_direction" }
    private var reversed: Bool { store.document.string(SettingsPath(path)) == "reversed" }
    private var ledCount: Int { device.kind == "dot" ? 2 : 8 }

    var body: some View {
        Provided(store, path) {
            SettingRow("Strip direction", subtitle: Self.subtitle(reversed: reversed)) {
                HStack(spacing: 10) {
                    LEDStripPreview(program: Self.sweep(reversed: reversed, ledCount: ledCount),
                                    ledCount: ledCount, style: .dots, dotSize: 6, spacing: 4)
                        .frame(width: ledCount == 2 ? 44 : 96)
                        .accessibilityLabel(reversed ? "A sweep starting at the right" : "A sweep starting at the left")
                    Picker("Strip direction", selection: store.string(path, default: "forward")) {
                        ForEach(Self.choices, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
    }

    static func subtitle(reversed: Bool) -> String {
        reversed
            ? "Mounted the other way round: every light is mirrored, so motion still runs left to right."
            : "The sweep starts where LED 0 is. Turn the strip round? Pick LED 0 right."
    }

    /// A comet leaving LED 0: the monitor's own shape (a head-and-tail
    /// profile rolled round the strip), turned for a strip whose LED 0 is
    /// on the right.
    static func sweep(reversed: Bool, ledCount: Int) -> String {
        let tail: [Double] = ledCount <= 2 ? [1.0, 0.16] : [1.0, 0.38, 0.14, 0.05, 0.01, 0, 0, 0]
        var shades = tail.prefix(max(2, ledCount)).map { LightingPreviewPrograms.scaled("#00E5FF", $0) }
        if reversed { shades.reverse() }
        let roll = reversed ? "roll-left" : "roll-right"
        return "\(shades.joined(separator: " ")) 120ms cosine\n\(roll) 1600ms linear\nrepeat"
    }
}
