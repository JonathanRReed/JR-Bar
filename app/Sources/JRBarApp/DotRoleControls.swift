import JRBarCore
import SwiftUI

/// Settings › Devices & Screen Bar: what the linked Dot is for
/// (`dot_role`, `dot_role_include_completions`; `docs/CORE-PROTOCOL.md`,
/// "The Dot's role"). The picker and the toggle live in the Dot's own card
/// when the document has a Dot; the Pro + Dot section then shows only the
/// live reading, so the same global key is never two controls on one page.
struct DotRoleControls: View {
    @Bindable var store: SettingsStore
    /// True inside the Dot's device card, false in the Pro + Dot section.
    let inDeviceCard: Bool

    private var hasDotCard: Bool { store.deviceEntries.contains { $0.kind == "dot" } }
    /// The full control belongs wherever the reader is looking at the Dot:
    /// its card, or — with no Dot in the document — the Pro + Dot section.
    private var carriesControls: Bool { inDeviceCard || !hasDotCard }

    private var chosen: DotRole { DotRole.parse(store.document.string("dot_role")) }
    private var includeCompletions: Bool { store.document.bool("dot_role_include_completions") ?? false }
    /// With `devices_linked` off the daemon plans nothing for the Dot, so
    /// no role is in effect whatever the key says.
    private var linked: Bool { store.document.bool("devices_linked") ?? true }
    private var readout: DotRoleReadout {
        DotRoleReadout.make(chosen: chosen, includeCompletions: includeCompletions, linked: linked,
                            dot: store.core.lights?.dot)
    }

    var body: some View {
        if carriesControls {
            Provided(store, "dot_role") {
                Picker(selection: store.string("dot_role", default: DotRole.extend.rawValue)) {
                    ForEach(DotRole.allCases) { role in
                        Text(role.label).tag(role.rawValue)
                    }
                } label: {
                    SettingLabel(title: "Role",
                                 subtitle: linked ? chosen.explanation
                                     : "Link Pro and Dot below to give the Dot a role; unlinked it always renders its own display.")
                }
                .pickerStyle(.segmented)
                .disabled(!linked)
            }
            Provided(store, "dot_role_include_completions") {
                Toggle(isOn: store.bool("dot_role_include_completions")) {
                    SettingLabel(title: "Also glow for finished runs",
                                 subtitle: "The beacon adds a slow green breath for a completion nobody has looked at yet. Blocked still outranks waiting, which outranks finished.")
                }
                .disabled(!linked || !chosen.usesCompletions)
            }
            DotRoleReadoutRow(readout: readout, program: store.core.lights?.dot?.program, compact: false)
        } else {
            DotRoleReadoutRow(readout: readout, program: store.core.lights?.dot?.program, compact: true)
        }
    }
}

/// The live line: the role the daemon echoes, what it is doing, and a
/// two-LED preview of the Dot's actual program.
struct DotRoleReadoutRow: View {
    let readout: DotRoleReadout
    let program: String?
    let compact: Bool

    private var roleWord: String {
        if let active = readout.active { return active.label }
        if readout.rendersItself { return DotRole.status.label }
        return "—"
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(roleWord)
                        .foregroundStyle(readout.settling ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    Text(readout.headline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let program, !program.isEmpty {
                    LEDStripPreview(program: program, ledCount: 2, dotSize: 11, spacing: 6, cornerRadius: 7)
                        .frame(width: 56)
                        .accessibilityLabel("What the Dot is playing")
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 56, height: 26)
                }
            }
        } label: {
            SettingLabel(title: compact ? "Dot role now" : "Right now",
                         subtitle: subtitle)
        }
    }

    /// The compact row is a cross-reference, not a second copy of the
    /// reading: it names where the role is set and leaves the explanation
    /// to the card that carries the picker.
    private var subtitle: String? { compact ? "Set in the Dot's card above." : readout.detail }
}
