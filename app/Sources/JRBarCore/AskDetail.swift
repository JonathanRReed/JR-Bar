import Foundation

/// The words and the arithmetic behind an expanded ask: what the chevron
/// is called, what the body shows, and the one place a plan approval is
/// sent to the session. Every surface that draws an ask reads these, so
/// the panel, the notch card and the Overview say the same thing.
///
/// Nothing here answers an ask. Expanding is reading; the decision stays
/// a person's click, and for a plan it stays in the terminal.
public enum AskDetailCopy {
    /// What the chevron reveals, in the word a person would use.
    public static func noun(_ detail: CoreAskDetail) -> String {
        if detail.plan != nil { return "plan" }
        if detail.command != nil { return "full command" }
        return "edit summary"
    }

    /// "Show full command", "Hide plan": the chevron's tooltip and spoken label.
    public static func toggleTitle(_ detail: CoreAskDetail, expanded: Bool) -> String {
        "\(expanded ? "Hide" : "Show") \(noun(detail))"
    }

    /// The chevron's spoken hint, for the state it is in.
    public static func toggleHint(expanded: Bool) -> String {
        expanded ? "Collapses the details. Nothing is answered." : "Expands the details. Nothing is answered."
    }

    /// The text the body shows in its monospaced well: a plan, else the
    /// whole command; nil for an edit that is only a summary.
    public static func body(_ detail: CoreAskDetail) -> String? {
        detail.plan ?? detail.command
    }

    /// Said under a body the daemon had to cut.
    public static func footnote(_ detail: CoreAskDetail) -> String? {
        guard detail.truncated, body(detail) != nil else { return nil }
        return "Showing the first 2,000 characters"
    }

    /// The paths an edit names, one per line, for the body of an edit
    /// summary. Empty when the daemon named none.
    public static func pathLines(_ edit: CoreAskEdit) -> [String] {
        let shown = edit.paths
        guard edit.files > shown.count, !shown.isEmpty else { return shown }
        return shown + ["+\(edit.files - shown.count) more"]
    }

    /// The plan's one action: the decision is made in the terminal.
    public static let sessionActionTitle = "Answer in the session"
    public static let sessionActionHelp = "Open the session. A plan is approved or changed there, not here."
    public static let planNote = "Decided in the session."

    /// What VoiceOver reads for an expanded body, so the monospaced well
    /// is not skipped: "Full command: …", "Plan: …".
    public static func bodyLabel(_ detail: CoreAskDetail) -> String {
        if let plan = detail.plan { return "Plan: \(plan)" }
        if let command = detail.command { return "Full command: \(command)" }
        if let edit = detail.edit { return edit.summary }
        return "Details"
    }
}
