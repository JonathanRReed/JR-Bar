import AppKit
import JRBarCore
import SwiftUI

/// The rivals note, for any utility card: one line per running rival
/// that says what the overlap costs, then the ways out — Hand over where
/// the rival can take the surface, and Quit on the person's click. The
/// menu bar's card has worn this since the Bartender days; now every
/// surface does (`UtilityRivals`).
///
/// The note shows only while JR-Bar's own surface is the one live
/// (`active`): a rival already picked under "Render with" is the choice,
/// not a clash. Only a surface that clashes asks with buttons. The shake
/// already steps aside on its own — its switch sits right above the
/// note — and keep-awake is information only, so those two notes have
/// none.
struct RivalGuardView: View {
    let role: UtilityRivals.Role
    /// Whether JR-Bar's own surface for this role is live right now.
    var active = true
    /// Hands the surface to the rival; nil offers no Hand over.
    var handOver: ((UtilityRivals.Rival) -> Void)?
    /// A fixed list for proofs and tests; nil reads the workspace.
    var rivals: [UtilityRivals.Rival]?
    var quit: (UtilityRivals.Rival) -> Void = { UtilityRivals.quit($0) }

    var body: some View {
        // Read the watch so a launch or a quit redraws the note.
        _ = UtilityRivalsWatch.shared.version
        let running = active ? (rivals ?? UtilityRivals.running(for: role)) : []
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(running) { rival in
                row(rival)
            }
        }
    }

    private func row(_ rival: UtilityRivals.Rival) -> some View {
        HStack(spacing: SettingsMetrics.s) {
            CardNote(UtilityRivals.note(for: rival, role: role),
                     symbol: symbol, tint: tint)
            Spacer(minLength: SettingsMetrics.s)
            if role.policy == .ask {
                if let handOver, rival.handoff(for: role) != nil {
                    Button("Hand over") { handOver(rival) }
                        .controlSize(.small)
                        .help("Let \(rival.name) have it; JR-Bar's own parks while the pick stands")
                }
                Button("Quit \(rival.name)") { quit(rival) }
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch role.policy {
        case .ask: return "exclamationmark.triangle.fill"
        case .stepAside: return "hand.raised.fill"
        case .informOnly: return "info.circle"
        }
    }

    private var tint: Color {
        switch role.policy {
        case .ask: return .orange
        case .stepAside: return .secondary
        case .informOnly: return .secondary
        }
    }
}

extension DockUtility {
    /// Hand over from the rivals note: the Dock previews go to the
    /// rival's pick, and ours park — the same write "Render with" makes.
    func handOver(to rival: UtilityRivals.Rival) {
        guard case .dock(let provider)? = rival.handoff(for: .dockPreviews) else { return }
        providerBinding.wrappedValue = provider
    }
}

extension NotchToy {
    /// Hand over from the rivals note: the notch goes to Alcove or
    /// Boring Notch exactly as the "Render with" picker gives it.
    func handOver(to rival: UtilityRivals.Rival) {
        guard case .notch(let provider)? = rival.handoff(for: .notch) else { return }
        setProvider(provider)
    }
}
