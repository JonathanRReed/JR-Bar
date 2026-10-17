import Foundation

/// What a row says when an ask cannot be answered from JR-Bar.
///
/// The daemon decides that (`answerable: false`): a view-only agent such as
/// Gemini, Devin or Grok declares no way to take a decision, and Claude or
/// Codex in a terminal that cannot prove its focused tab is not offered one
/// either. In every such case the row says so in plain words, names the app
/// the person answers in, and offers to open it. It never draws Approve,
/// Deny or Always Allow for what no daemon could deliver.
public enum AskAnswerHost {
    /// The app the session runs in, as the person knows it ("Ghostty",
    /// "VS Code"): the terminal the daemon found, else an app or IDE the
    /// hook named by bundle id. Nil when the daemon does not know, and the
    /// row then says "its own window" rather than invent an app.
    public static func app(of session: CoreSession) -> String? {
        if let terminal = clean(session.terminal?.app) { return terminal }
        guard let origin = session.origin, origin.bundleId != nil else { return nil }
        return clean(origin.label)
    }

    /// "Answer this in Ghostty", or "Answer this in its own window".
    public static func line(host: String?) -> String {
        "Answer this in \(clean(host) ?? "its own window")"
    }

    /// The button beside the line: "Open Ghostty", or "Open session" when the
    /// daemon named no app (the daemon then says plainly if it cannot find
    /// the window, and nothing new is started).
    public static func buttonTitle(host: String?) -> String {
        clean(host).map { "Open \($0)" } ?? "Open session"
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
