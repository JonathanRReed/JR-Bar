import JRBarCore
import SwiftUI

/// A device card's "Strip direction" row: which way round the strip is
/// mounted, and a sweep that starts from LED 0 so you can match it to the
/// strip on your desk. Reversed mirrors every agent light the monitor
/// draws for this device, and Effect Studio's Play on strip, so a comet
/// that ran left to right still does after the strip is turned round
/// (`devices.N.led_direction`). Only the Pro and the Dot have one (the
/// Screen Bar is drawn on screen, the right way round already). A linked
/// Dot follows the Pro in desk order whichever way the Pro is set, and
/// while its role drives it the row is dimmed and says why -- except
/// Extend with the Continue look, which enters the Dot at its LED nearest
/// the strip and so still reads the Dot's own direction.
struct LEDDirectionRow: View {
    @Bindable var store: SettingsStore
    let device: SettingsStore.DeviceEntry

    static let choices: [(value: String, label: String)] = [
        ("forward", "LED 0 left"), ("reversed", "LED 0 right"),
    ]

    private var path: String { "\(device.prefix).led_direction" }
    private var reversed: Bool { store.values.string(SettingsPath(path)) == "reversed" }
    private var ledCount: Int { device.kind == "dot" ? 2 : 8 }
    /// Linked, the Dot plays the Pro's light; only Continue still reads
    /// which way round the Dot is mounted (`DotLinkReading.directionActs`).
    private var linkedDot: Bool { device.kind == "dot" && DotLinkReading.followsPro(store) }
    private var followsPro: Bool { linkedDot && !DotLinkReading.directionActs(store) }
    private var subtitle: String {
        if followsPro { return DotLinkReading.note(store) }
        if linkedDot { return DotLinkReading.continueDirectionNote }
        return Self.subtitle(reversed: reversed)
    }

    /// The devices whose own strip the monitor draws for.
    static func applies(to kind: String) -> Bool { kind == "pro" || kind == "dot" }

    var body: some View {
        if Self.applies(to: device.kind) {
            Provided(store, path) {
                SettingRow("Strip direction", subtitle: subtitle) {
                    HStack(spacing: 10) {
                        LEDStripPreview(program: Self.sweep(reversed: reversed, ledCount: ledCount),
                                        ledCount: ledCount, style: .dots, dotSize: 6, spacing: 4)
                            .frame(width: ledCount == 2 ? 44 : 96)
                            .opacity(followsPro ? 0.4 : 1)
                            .accessibilityLabel(reversed ? "A sweep starting at the right" : "A sweep starting at the left")
                        Picker("Strip direction", selection: store.string(path, default: "forward")) {
                            ForEach(Self.choices, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    .disabled(followsPro)
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
