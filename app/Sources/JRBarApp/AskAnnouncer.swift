import AppKit
import JRBarCore

/// Tells VoiceOver, once, when an agent starts waiting for the person.
///
/// A new ask used to appear as a card and a sound, and nothing a screen
/// reader could hear: the only announcement in the app was a toast. This
/// posts one spoken line for each ask the first time it is seen, however many
/// times the daemon sends the same state afterwards, and never for an ask that
/// is answered, stale or already announced. It only says that an agent needs
/// the person; answering stays a click or a key, as everywhere else.
@MainActor
final class AskAnnouncer {
    /// How the line is spoken: a VoiceOver announcement by default, a list in tests.
    var post: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    private var seen: Set<String> = []
    private var order: [String] = []
    private static let memory = 256

    /// Looks at the asks the daemon lists now and speaks for the new ones.
    func note(_ asks: [CoreAsk]) {
        var fresh: [CoreAsk] = []
        for ask in asks where !seen.contains(ask.id) {
            remember(ask.id)
            // An ask the person already answered, or that has gone stale, is
            // not news.
            guard !ask.isStale, !ask.isDecided else { continue }
            fresh.append(ask)
        }
        guard let first = fresh.first else { return }
        if fresh.count == 1 {
            post(Self.line(for: first))
        } else {
            post("\(fresh.count) agents need you")
        }
    }

    /// "Claude needs you: Run npm test", the whole announcement for one ask.
    nonisolated static func line(for ask: CoreAsk) -> String {
        let provider = ask.session.flatMap { $0.split(separator: ":").first }
            .map { SessionLabel.providerName(String($0)) } ?? "An agent"
        let summary = (ask.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return "\(provider) needs you" }
        let clipped = summary.count > 120 ? String(summary.prefix(120)) + "…" : summary
        return "\(provider) needs you: \(clipped)"
    }

    private func remember(_ id: String) {
        seen.insert(id)
        order.append(id)
        if order.count > Self.memory {
            let dropped = order.removeFirst()
            seen.remove(dropped)
        }
    }
}
