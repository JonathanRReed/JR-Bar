import JRBarCore
import SwiftUI

/// A Dot's "Travel" row: how a travelling motion (a chase, a comet, a
/// scanner) plays on two LEDs. Wipe lights one LED, then the other, then
/// lets go in the same order, so the Dot shows which way the light is
/// going; Crossfade is the older soft swap. Only a Dot shows it
/// (`devices.N.dot_travel_style`), and it only acts while the Dot draws
/// its own display: a Dot linked to the Pro plays the Pro's light, so
/// there the row is dimmed and says why.
struct DotTravelStyleRow: View {
    @Bindable var store: SettingsStore
    let device: SettingsStore.DeviceEntry

    static let choices: [(value: String, label: String)] = [
        ("wipe", "Wipe"), ("crossfade", "Crossfade"),
    ]

    private var path: String { "\(device.prefix).dot_travel_style" }
    private var style: String { store.document.string(SettingsPath(path)) ?? "wipe" }
    private var followsPro: Bool { DotLinkReading.followsPro(store) }

    var body: some View {
        if device.kind == "dot" {
            Provided(store, path) {
                SettingRow("Travel", subtitle: followsPro ? DotLinkReading.note : Self.subtitle(style)) {
                    HStack(spacing: 10) {
                        LEDStripPreview(program: Self.program(style), ledCount: 2, style: .dots, dotSize: 8, spacing: 5)
                            .frame(width: 52)
                            .opacity(followsPro ? 0.4 : 1)
                            .accessibilityLabel("\(style == "crossfade" ? "Crossfade" : "Wipe") preview")
                        Picker("Travel", selection: store.string(path, default: "wipe")) {
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

/// Whether the Dot is drawing its own display or playing the Pro's light.
/// Linked with the Extend, Asks or Call role, the monitor sends the Dot
/// the Pro's program narrowed to two LEDs (or the asks beacon), so the
/// Dot's own Travel and Strip direction have nothing to act on until its
/// role is Status or the two are unlinked. The daemon's `dot_link` word
/// wins over the setting when it has one, as in `DotRoleControls`.
enum DotLinkReading {
    static let note = "Linked: the Dot plays the Pro's light. Set its role to Status, or unlink, to use this."

    @MainActor
    static func followsPro(_ store: SettingsStore) -> Bool {
        let linked = store.document.bool("devices_linked") ?? true
        let off = store.core.lights?.dotLink.map { $0.state == "off" } ?? !linked
        return !off && DotRole.parse(store.document.string("dot_role")) != .status
    }
}
