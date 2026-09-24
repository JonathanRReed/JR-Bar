import JRBarCore
import SwiftUI

/// Settings › Devices › Calibration profiles: the daemon's Day, Night and
/// Travel slots, and the Focus rules that apply one when that Focus
/// starts. A profile is a snapshot of every device's brightness, channel
/// gains and resting glow; applying it restores brightness and gains —
/// exactly what a Focus rule does, so the button and the rule can never
/// disagree about what "Night" means.
struct CalibrationProfilesSection: View {
    @Bindable var store: SettingsStore
    @ViewState private var replacing: String?

    private var saved: [String] { LightProfiles.savedSlots(in: store.document) }

    var body: some View {
        SettingGroup("Calibration profiles", note: "Save the way the strip, the Dot and the Screen Bar look right now, and bring it back later — or let a Focus bring it back when it starts.") {
            Provided(store, "calibration_profiles") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SettingsKey.calibrationProfileSlots, id: \.self) { slot in
                        row(slot)
                        if slot != SettingsKey.calibrationProfileSlots.last { Divider().padding(.vertical, 6) }
                    }
                }
            }
            DisclosureRow("Apply with a Focus", subtitle: "When one of these Focus modes starts, its profile's brightness and gains are applied.") {
                FocusRoster(store: store) { focuses in
                    ForEach(focuses, id: \.id) { focus in
                        FocusProfileRow(store: store, focusID: focus.id, name: focus.name, saved: saved)
                    }
                }
            }
        }
        .confirmationDialog("Replace the \(replacing ?? "") profile?", isPresented: Binding(
            get: { replacing != nil }, set: { if !$0 { replacing = nil } })
        ) {
            Button("Replace with the current look") {
                if let slot = replacing { save(slot) }
                replacing = nil
            }
            Button("Cancel", role: .cancel) { replacing = nil }
        } message: {
            Text("The saved brightness, gains and resting glow for every device are overwritten.")
        }
    }

    private func row(_ slot: String) -> some View {
        let isSaved = saved.contains(slot)
        let applied = isSaved && LightProfiles.isApplied(slot: slot, in: store.document)
        return HStack(spacing: SettingsMetrics.m) {
            SettingsIconTile(symbol: Self.symbol(slot),
                             tint: isSaved ? Self.tint(slot) : Color(nsColor: .systemGray),
                             size: 26)
                .opacity(isSaved ? 1 : 0.55)
            SettingLabel(title: slot, subtitle: subtitle(slot, isSaved: isSaved, applied: applied))
            Spacer(minLength: SettingsMetrics.s)
            if applied {
                StatusPill("In use", tint: .green)
            } else if isSaved {
                Button("Apply") { apply(slot) }
                    .controlSize(.small)
                    .disabled(!store.core.isLive)
                    .help("Restore \(slot)'s brightness and gains on every device it covers")
            }
            Menu {
                Button(isSaved ? "Replace with the current look…" : "Save the current look") {
                    if isSaved { replacing = slot } else { save(slot) }
                }
                if isSaved {
                    Divider()
                    Button("Delete \(slot)", role: .destructive) { delete(slot) }
                }
            } label: {
                Text(isSaved ? "Edit" : "Save")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .disabled(!store.core.isLive)
        }
    }

    private func subtitle(_ slot: String, isSaved: Bool, applied: Bool) -> String {
        guard isSaved else { return "Not saved yet." }
        let count = LightProfiles.deviceCount(slot: slot, in: store.document)
        let devices = "\(count) device\(count == 1 ? "" : "s")"
        return applied ? "\(devices) · in use now" : devices
    }

    static func symbol(_ slot: String) -> String {
        switch slot {
        case "Day": return "sun.max.fill"
        case "Night": return "moon.fill"
        case "Travel": return "airplane"
        default: return "slider.horizontal.3"
        }
    }

    /// Each slot's own hue: a warm day, an indigo night, a sky for travel.
    static func tint(_ slot: String) -> Color {
        switch slot {
        case "Day": return Color(nsColor: .systemOrange)
        case "Night": return Color(nsColor: .systemIndigo)
        case "Travel": return Color(nsColor: .systemTeal)
        default: return Color(nsColor: .systemGray)
        }
    }

    private func save(_ slot: String) {
        store.set("calibration_profiles.\(slot)", LightProfiles.snapshot(of: store.document))
        store.show(status: "Saved the current look as \(slot)")
    }

    private func apply(_ slot: String) {
        let writes = LightProfiles.applyWrites(slot: slot, to: store.document)
        for write in writes { store.set(write.path, write.value) }
        store.show(status: writes.isEmpty ? "\(slot) is already in use" : "Applied \(slot)")
    }

    private func delete(_ slot: String) {
        store.set("calibration_profiles.\(slot)", .null)
        // A rule pointing at a deleted slot would apply nothing; drop it.
        let rules = store.document.object("focus_profile_rules") ?? [:]
        let kept = rules.filter { $0.value.stringValue != slot }
        if kept.count != rules.count { store.set("focus_profile_rules", .object(kept)) }
    }
}

/// One Focus → profile rule. The rules object is written whole: Focus
/// identifiers are dotted, and a per-focus path would nest.
struct FocusProfileRow: View {
    @Bindable var store: SettingsStore
    let focusID: String
    let name: String
    let saved: [String]

    private var rule: String { store.document.object("focus_profile_rules")?[focusID]?.stringValue ?? "" }

    var body: some View {
        Provided(store, "focus_profile_rules") {
            Picker(selection: Binding(
                get: { rule },
                set: { slot in
                    let rules = LightProfiles.rules(store.document.object("focus_profile_rules"),
                                                    setting: focusID, to: slot.isEmpty ? nil : .string(slot))
                    store.set("focus_profile_rules", rules)
                }
            )) {
                Text("No profile").tag("")
                Divider()
                ForEach(SettingsKey.calibrationProfileSlots, id: \.self) { slot in
                    Text(saved.contains(slot) ? slot : "\(slot) (not saved)").tag(slot)
                }
            } label: {
                SettingLabel(title: name)
            }
            .pickerStyle(.menu)
        }
    }
}
