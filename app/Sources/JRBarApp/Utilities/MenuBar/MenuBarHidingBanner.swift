import JRBarCore
import SwiftUI

/// The top of the Menu Bar card: one line that says whether hiding works,
/// and while it does not, why and what one click does about it. Always
/// carries the way out — "Show everything" while something is hidden, and
/// a plain "Turn off" beside any warning — so a bar that feels wrong is
/// never more than one click from every item showing.
struct MenuBarHidingBanner: View {
    let status: MenuBarHidingStatus
    let onFix: (MenuBarHidingStatus.Fix) -> Void

    var body: some View {
        let tint = Self.tint(status.tone)
        HStack(alignment: .top, spacing: SettingsMetrics.s) {
            Image(systemName: Self.symbol(status.tone))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.headline)
                    .font(.callout.weight(.semibold))
                Text(status.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                    .padding(.top, SettingsMetrics.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(SettingsMetrics.s + 2)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
                .fill(tint.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hiding status: \(status.headline)")
    }

    @ViewBuilder
    private var actions: some View {
        let fix = status.fix
        let escape = status.offersShowEverything
        let canTurnOff = status.tone == .warning
        if fix != nil || escape || canTurnOff {
            HStack(spacing: SettingsMetrics.s) {
                if let fix, let title = status.fixTitle {
                    Button(title) { onFix(fix) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                if escape {
                    Button("Show everything") { onFix(.showEverything) }
                        .controlSize(.small)
                        .help("Every item back on the bar now. Your picks are kept; Hide my picks again puts them back.")
                }
                if canTurnOff {
                    Button("Turn Menu Bar off") { onFix(.turnOff) }
                        .controlSize(.small)
                        .help("Stop hiding altogether. Every item shows exactly as macOS draws it.")
                }
            }
        }
    }

    nonisolated static func symbol(_ tone: MenuBarHidingStatus.Tone) -> String {
        switch tone {
        case .ok: "checkmark.circle.fill"
        case .note: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ tone: MenuBarHidingStatus.Tone) -> Color {
        switch tone {
        case .ok: .green
        case .note: .blue
        case .warning: .orange
        }
    }
}
