import JRBarCore
import SwiftUI

/// The pieces every ask row shares, whatever surface draws it: the
/// destructive mark, the preview line, the hold's ring, and the menu a
/// held question's options live in when they do not fit as buttons. Each surface keeps
/// its own buttons and its own type; these only say the same thing the
/// same way.

/// The daemon's `risk: "destructive"` — a mark, never a block: the
/// command is the kind that loses work if it runs by mistake.
struct AskRiskMark: View {
    var size: CGFloat = 10

    static let help = "Destructive — this command can lose work if it runs by mistake"

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.red)
            .help(Self.help)
            .accessibilityLabel("Destructive")
    }
}

/// The decide lane's hold, drawn: a ring that drains as the window the
/// hook holds the ask for runs out (`AskHold`). A second's step glides;
/// under Reduce Motion it steps in ninths and never animates. The
/// seconds live in the tooltip, not on the ring.
struct AskHoldRing: View {
    /// What is left of the hold, 1 → 0.
    let fraction: Double
    let reduced: Bool
    var size: CGFloat = 12

    var body: some View {
        let shown = reduced ? AskHold.stepped(fraction) : fraction
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(reduced ? nil : .linear(duration: 1), value: shown)
    }
}

/// What the agent wants to run, one line: the command, the file, the
/// URL. Monospaced, cut in the middle so both ends of a path survive.
struct AskPreviewLine: View {
    let text: String
    var size: CGFloat = 11
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
            .accessibilityLabel("Runs \(text)")
    }
}

extension CoreAsk {
    /// The preview worth a line: non-empty and not the summary again.
    var previewLine: String? {
        guard let preview = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty,
              preview != summary?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return preview
    }
}

/// The items of a held question's menu. One single-pick question is a
/// list whose click is the answer; anything more lists every question
/// with its options as checkmarks — a click only picks — and Send
/// Answers once each question has one.
struct AskChoiceMenuItems: View {
    let choices: [CoreAskChoice]
    let picks: AskChoicePicks
    /// A click on an option: `AskChoicePicks.oneClick` says whether it
    /// is the whole answer or one pick among several.
    let pick: (String, CoreAskChoice) -> Void
    let send: () -> Void

    var body: some View {
        if choices.count == 1, let choice = choices.first, !choice.multi {
            Section(choice.header ?? choice.question) {
                ForEach(choice.options, id: \.self) { label in
                    Button(label) { pick(label, choice) }
                }
            }
        } else {
            ForEach(choices, id: \.question) { choice in
                Section(choice.header.map { "\($0) — \(choice.question)" } ?? choice.question) {
                    ForEach(choice.options, id: \.self) { label in
                        Toggle(label, isOn: Binding(
                            get: { picks.isPicked(label, in: choice) },
                            set: { _ in pick(label, choice) }))
                    }
                }
            }
            Divider()
            Button("Send Answers") { send() }
                .disabled(!picks.isComplete(choices))
        }
    }
}

extension AskAnswerDesk {
    /// A click on an option from any surface's menu or button: the whole
    /// answer when it is one (`oneClick`), else one more pick.
    func pick(_ label: String, in choice: CoreAskChoice, of ask: CoreAsk) {
        let choices = ask.decision?.choices ?? []
        if let verdict = AskChoicePicks.oneClick(label, choices: choices) {
            Task { await self.answer(ask, verdict) }
        } else {
            toggle(label, in: choice, of: ask)
        }
    }
}
