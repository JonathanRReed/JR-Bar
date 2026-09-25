import JRBarCore
import SwiftUI

/// A Dot's "Travel" row: how a travelling motion (a chase, a comet, a
/// scanner) plays on two LEDs. Wipe lights one LED, then the other, then
/// lets go in the same order, so the Dot shows which way the light is
/// going; Crossfade is the older soft swap. Only a Dot shows it
/// (`devices.N.dot_travel_style`), and it only acts while the Dot draws
/// its own display: a Dot linked to the Pro plays the Pro's light (or the
/// alert beacon, or the call light), so there the row is dimmed and says
/// which.
struct DotTravelStyleRow: View {
    @Bindable var store: SettingsStore
    let device: SettingsStore.DeviceEntry

    static let choices: [(value: String, label: String)] = [
        ("wipe", "Wipe"), ("crossfade", "Crossfade"),
    ]

    private var path: String { "\(device.prefix).dot_travel_style" }
    private var style: String { store.values.string(SettingsPath(path)) ?? "wipe" }
    private var followsPro: Bool { DotLinkReading.followsPro(store) }

    var body: some View {
        if device.kind == "dot" {
            Provided(store, path) {
                SettingRow("Travel", subtitle: followsPro ? DotLinkReading.note(store) : Self.subtitle(style)) {
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

/// Whether the Dot is drawing its own display or playing what its role
/// gives it. Linked with the Extend role the monitor sends the Dot the
/// Pro's program narrowed to two LEDs; with Asks, the alert beacon; with
/// Call, the call light. Either way the Dot's own Travel and Strip
/// direction have nothing to act on until its role is On its own or the
/// two are unlinked. The daemon's `dot_link` word wins over the setting
/// when it has one, as in `DotRoleControls`.
enum DotLinkReading {
    /// Why the row is dimmed, in terms of what the Dot is doing instead.
    static func note(for role: DotRole) -> String {
        let doing: String
        switch role {
        case .asks: doing = "the Dot is the alert beacon"
        case .call: doing = "the Dot is the call light"
        case .extend, .status: doing = "the Dot plays the Pro's light"
        }
        return "Linked: \(doing). Set its role to On its own, or unlink, to use this."
    }

    @MainActor
    static func note(_ store: SettingsStore) -> String {
        note(for: DotRole.parse(store.values.string("dot_role")))
    }

    @MainActor
    static func followsPro(_ store: SettingsStore) -> Bool {
        let linked = store.values.bool("devices_linked") ?? true
        let off = store.dotLink.map { $0.state == "off" } ?? !linked
        return !off && DotRole.parse(store.values.string("dot_role")) != .status
    }

    /// Whether the Dot's own Strip direction still acts while it follows
    /// the Pro. Extending with the Continue look, the light carries on into
    /// the Dot at its LED nearest the strip, and which way round the Dot is
    /// mounted decides which LED that is (`dot_role.continue_geometry`).
    /// Mirror, Asks and Call never read it.
    @MainActor
    static func directionActs(_ store: SettingsStore) -> Bool {
        DotRole.parse(store.values.string("dot_role")) == .extend
            && (store.values.string("dot_extend_style") ?? "continue") == "continue"
    }

    /// The Strip direction row's note while Continue reads it.
    static let continueDirectionNote =
        "Linked with Continue: the light enters the Dot at the LED nearest the strip, so set which way round it sits."
}
