import JRBarCore
import SwiftUI

/// The Try it ask in the panel (`DemoAsk`): one card above the real asks,
/// in a violet wash instead of the asks' amber and marked "Demo", so it
/// cannot be taken for a real one. It is not one of `rows`: the header's
/// count, the Screen Bar's focus and the menu bar icon never see it.
extension PanelStore {
    /// The demo while it is up, as a card row.
    var demoRow: SessionRow? {
        guard let ask = DemoAskStore.shared.current(at: now) else { return nil }
        return SessionRow(orphanAsk: ask)
    }

    /// How many ask cards the list draws: the daemon's, and the demo.
    var askCardCount: Int { visibleAskRows.count + (demoRow == nil ? 0 : 1) }

    /// How many of them the person has opened.
    var expandedAskCount: Int {
        let real = visibleAskRows.filter { AskExpansion.shared.isShowing($0.ask) }.count
        return real + (AskExpansion.shared.isShowing(demoRow?.ask) ? 1 : 0)
    }

    /// "Put away" on the demo card.
    func dismissDemo() {
        DemoAskStore.shared.dismiss()
        show(toast: DemoAsk.dismissedLine)
    }
}

/// What marks a card as the demo: the word, and one tint nothing else in
/// the panel wears.
enum DemoAskLook {
    static let tint = Color(nsColor: .systemPurple)
}

/// The "Try it" row, the same words wherever it is offered: Setup's Done
/// step and Settings › Agents & Usage.
struct DemoAskTryRow: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DemoAskLook.tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DemoAskLook.tint.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("See an ask before one arrives").font(.system(size: 13, weight: .medium))
                Text("A demo ask with Approve and Deny that answer nothing. \(DemoAsk.whereLine)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Try it", action: action)
                .help("Show a demo ask. It is not from an agent, nothing is sent anywhere, and it is not recorded.")
        }
    }
}

/// The "Demo" capsule where a real ask says "Permission".
struct DemoAskBadge: View {
    var body: some View {
        Text(DemoAsk.badge)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(DemoAskLook.tint)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(DemoAskLook.tint.opacity(0.16)))
            .overlay(Capsule().strokeBorder(DemoAskLook.tint.opacity(0.4), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2])))
            .accessibilityLabel("Demo")
    }
}
