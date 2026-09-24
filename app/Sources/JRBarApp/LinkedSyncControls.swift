import JRBarCore
import SwiftUI

/// Settings › Devices & Screen Bar › Pro & Dot: how the linked Dot keeps
/// the strip's beat (`jrbar.linked_sync`; `docs/CORE-PROTOCOL.md`,
/// "Keeping the Dot on the strip's beat").
///
/// The Dot's own clock runs about 2.7% slow, so the monitor times every
/// Dot write from the strip's recorded start and the Dot's measured clock,
/// and re-syncs it before it drifts past the tolerance. The page offers the
/// look (mirror or continue), a constant trim for a pair that still reads
/// off by eye, the clock correction itself, and Check sync, a minute of
/// matched flashes to judge by eye.
struct LinkedSyncControls: View {
    @Bindable var store: SettingsStore
    @ViewState private var checkNote: String?
    @ViewState private var checking = false

    static let styles: [(value: String, label: String)] = [("mirror", "Mirror"), ("continue", "Continue")]
    static let sides: [(value: String, label: String)] = [
        ("after_last", "Past LED 7"), ("before_first", "Before LED 0"),
    ]

    private var linked: Bool { store.document.bool("devices_linked") ?? true }
    private var role: DotRole { DotRole.parse(store.document.string("dot_role")) }
    /// Every control here is about the Dot mirroring the strip.
    private var extending: Bool { linked && role == .extend }
    private var style: String { store.document.string("dot_extend_style") ?? "mirror" }
    private var correcting: Bool { store.document.bool("linked_dot_clock_correction") ?? true }

    var body: some View {
        SettingPicker(store, "Look", subtitle: styleSubtitle, path: "dot_extend_style",
                      options: Self.styles, default: "mirror", segmented: true)
            .disabled(!extending)
        if style == "continue" {
            SettingPicker(store, "The Dot sits", subtitle: "Which end of the strip the Dot carries on from.",
                          path: "dot_extend_side", options: Self.sides, default: "after_last")
                .disabled(!extending)
        }
        SettingSlider(store, "Timing trim",
                      subtitle: "Nudges the Dot if the two still read apart; plus runs it ahead.",
                      path: "linked_dot_phase_trim_ms", in: -250...250, step: 5, default: 0) { Self.trimText($0) }
            .disabled(!extending)
        DisclosureRow("Clock", subtitle: "How the monitor keeps the Dot's slower clock on the strip's beat.") {
            SettingToggle(store, "Keep in step",
                          subtitle: "Times the Dot for its own clock and re-syncs it before it drifts. Off, it only starts on the beat.",
                          path: "linked_dot_clock_correction", default: true)
                .disabled(!extending)
            SettingSlider(store, "Sync tolerance",
                          subtitle: "How far the Dot may drift before it is re-synced. Wider means fewer Dot rewrites.",
                          path: "linked_sync_tolerance_ms", in: 20...200, step: 5, default: 40) { "\(Int($0.rounded())) ms" }
                .disabled(!extending || !correcting)
        }
        SettingRow("Check sync", subtitle: checkSubtitle) {
            Button(checking ? "Checking…" : "Check sync") { startCheck() }
                .disabled(!extending || !store.core.isLive || checking)
        }
    }

    private var styleSubtitle: String {
        if style == "continue" {
            return "Light runs off the end of the strip into the Dot. Only moving light continues; anything else mirrors."
        }
        return "The strip's eight LEDs folded into the Dot's two."
    }

    private var checkSubtitle: String {
        if let checkNote { return checkNote }
        return "Both flash white every 2 seconds for a minute. In step, they read as one flash."
    }

    static func trimText(_ value: Double) -> String {
        let whole = Int(value.rounded())
        if whole == 0 { return "0 ms" }
        return whole > 0 ? "+\(whole) ms" : "\(whole) ms"
    }

    private func startCheck() {
        checking = true
        checkNote = nil
        let core = store.core
        Task { @MainActor in
            let reply = try? await core.send("linked_sync_check", args: ["seconds": .number(60)], timeout: 5)
            checking = false
            if reply?.ok == true {
                checkNote = "Watching for a minute: the two flashes should land together."
            } else {
                checkNote = reply?.error?.message ?? "The monitor did not start the check."
            }
        }
    }
}

/// "Match the strip's brightness": whether a linked Dot takes the strip's
/// brightness policy (times Dot brightness) instead of its own
/// auto-brightness, which used to cap it and restart it on every step.
struct LinkedBrightnessToggle: View {
    @Bindable var store: SettingsStore

    var body: some View {
        SettingToggle(store, "Match the strip's brightness",
                      subtitle: "The Dot follows the strip's brightness, dimmed by Dot brightness above, and ignores its own auto-brightness.",
                      path: "linked_follow_brightness", default: true)
            .disabled(!(store.document.bool("devices_linked") ?? true))
    }
}

/// A SidePulse's card: the SD eject guard, as launchd really has it, and
/// the one explicit action that fixes it for the SidePulse plugged in now.
struct EjectGuardRow: View {
    let store: SettingsStore
    @ViewState private var reading: EjectGuardReading?
    @ViewState private var working = false
    @ViewState private var failure: String?

    var body: some View {
        SettingRow("Eject guard", subtitle: failure ?? reading?.words ?? "Asking the monitor…") {
            Button(working ? "Protecting…" : "Protect this SidePulse") { protect() }
                .disabled(!(reading?.canProtect ?? false) || working || !store.core.isLive)
        }
        .task { await load() }
    }

    private func load() async {
        guard store.core.isLive else { return }
        let reply = try? await store.core.send("eject_guard", timeout: 5)
        if let parsed = EjectGuardReading.parse(reply?.result) { reading = parsed }
    }

    private func protect() {
        working = true
        failure = nil
        let core = store.core
        Task { @MainActor in
            let reply = try? await core.send("protect_sidepulse", timeout: 30)
            working = false
            if reply?.ok == true, let parsed = EjectGuardReading.parse(reply?.result) {
                reading = parsed
            } else {
                failure = reply?.error?.message ?? "The guard could not be installed."
            }
        }
    }
}

/// A device card's receipt: another app wrote to the device.
struct DeviceReceiptRow: View {
    let store: SettingsStore
    let deviceID: String
    let deviceName: String

    var body: some View {
        if let line = DeviceReceiptWords.line(store.core.lights?.deviceReceipts[deviceID], deviceName: deviceName) {
            Label(line, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .settingRowStyle()
        }
    }
}

/// The note on a linked Dot's card: its role decides what it shows, so the
/// per-device display controls are switched off rather than left to do
/// nothing.
struct LinkedDotNote: View {
    var body: some View {
        Label("Linked: follows the SidePulse. Display, Pin to, Asks only and Blend are the strip's while the Dot has a role; pick On its own to set them here.",
              systemImage: "link")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .settingRowStyle()
    }
}
