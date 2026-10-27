import Foundation

/// A session's story as one readable Markdown file — the header facts,
/// what happened, the honest gaps, and every timeline row — so a run can go
/// into a PR description or a postmortem. The Overview's "Export this run"
/// writes it, from the same `SessionReconstruction` the timeline view draws.
///
/// It is a rendering, not a raw copy: every row's text is already bounded
/// by the reconstruction, long token-shaped runs are masked again here,
/// and the home folder reads as `~`. Model output and tool results are
/// fenced so nothing in them can pass for the document's own structure.
public enum SessionMarkdown {
    /// One header line: "**Label:** value".
    public struct Fact: Sendable, Equatable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public static func render(title: String, facts: [Fact], reconstruction: SessionReconstruction,
                              notes: [String] = [], home: String? = NSHomeDirectory(),
                              generatedAt: Date = Date(), timeZone: TimeZone = .current) -> String {
        let clean = { (text: String) in mask(collapseHome(text, home: home)) }
        var out: [String] = ["# \(inline(clean(title)))", ""]
        for fact in facts where !fact.value.isEmpty {
            out.append("- **\(inline(clean(fact.label))):** \(inline(clean(fact.value)))")
        }
        if !facts.isEmpty { out.append("") }
        let stamp = formatter("yyyy-MM-dd HH:mm", timeZone).string(from: generatedAt)
        out.append("> Exported by JR-Bar on \(stamp). Row text is bounded, long token-shaped runs read as [redacted] and the home folder as ~.")
        for note in notes { out.append("> \(inline(clean(note)))") }
        out.append("")

        out.append("## What happened")
        out.append("")
        out.append(reconstruction.story.failed ? quoted(clean(reconstruction.story.sentence)) : "No failures in these rows.")
        out.append("")

        let gaps = reconstruction.gaps.map(ReconstructionGap.text)
        if !gaps.isEmpty {
            out.append("## Gaps")
            out.append("")
            out.append(contentsOf: gaps.map { "- \(inline(clean($0)))" })
            out.append("")
        }

        out.append("## Timeline")
        out.append("")
        let clock = formatter("HH:mm:ss", timeZone)
        let items = reconstruction.items
        if items.isEmpty { out.append("No rows could be rebuilt."); out.append("") }
        for item in items {
            let time = item.at.map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "—"
            out.append(contentsOf: rows(item, time: time, clean: clean))
        }
        return out.joined(separator: "\n")
    }

    private static func rows(_ item: ReconstructedItem, time: String, clean: (String) -> String) -> [String] {
        let sidechain = item.sidechain ? " · subagent" : ""
        let body = item.text.map(clean)
        switch item.kind {
        case .message:
            let who: String
            switch item.role {
            case "user": who = "You"
            case "assistant": who = "Assistant"
            default: who = inline(clean(item.role ?? "Message"))
            }
            let model = item.model.map { " (\(inline(clean($0))))" } ?? ""
            var out = ["### \(time) · \(who)\(model)\(sidechain)", ""]
            if item.redacted {
                out.append("_redacted_")
            } else if let body {
                // What you typed reads as prose; model output is fenced —
                // it is content, never the document's own structure.
                out.append(item.untrusted ? fenced(body) : quoted(body))
            }
            out.append("")
            return out
        case .toolUse:
            let name = singleLine(clean(item.name ?? "tool")).replacingOccurrences(of: "`", with: "'")
            var out = ["- \(time) · tool `\(name)`\(item.isError ? " · failed" : "")\(sidechain)"]
            if item.redacted {
                out.append("  _input redacted_")
            } else if let body {
                out.append(indented(fenced(body)))
            }
            out.append("")
            return out
        case .toolResult:
            var out = ["- \(time) · result\(item.isError ? " · **failed**" : "")\(sidechain)"]
            if item.redacted {
                out.append("  _output redacted_")
            } else if let body {
                out.append(indented(fenced(body)))
            }
            out.append("")
            return out
        case .turnEnd:
            return ["- \(time) · turn end\(item.name.map { " · \(inline(clean($0)))" } ?? "")\(item.isError ? " · **failed**" : "")", ""]
        }
    }

    // MARK: Text hygiene

    /// Python `_SECRET_RUN`, the reconstruction's own mask, applied again
    /// so a timeline built elsewhere is held to the same rule.
    private static let secretRun = try! NSRegularExpression(pattern: "[A-Za-z0-9_\\-+/=.]{24,}")

    static func mask(_ text: String) -> String {
        secretRun.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: "[redacted]")
    }

    static func collapseHome(_ text: String, home: String?) -> String {
        guard let home, home.count > 1 else { return text }
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return text.replacingOccurrences(of: trimmed, with: "~")
    }

    /// One line, no Markdown structure characters left to misread.
    static func inline(_ text: String) -> String {
        var escaped = singleLine(text).replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["*", "_", "`", "[", "]", "<", ">", "#", "!", "|"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
        }
        return escaped
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// A fence one backtick longer than any run inside, so content can
    /// never close it early.
    static func fenced(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)text\n\(text)\n\(fence)"
    }

    static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    private static func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }

    private static func formatter(_ format: String, _ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }
}

/// A reconstruction's named gaps in plain words — one wording for the
/// timeline view and the Markdown export. Unknown gaps pass through:
/// honesty beats a swallowed label.
public enum ReconstructionGap {
    public static func text(_ gap: String) -> String {
        if gap.hasPrefix("malformed_lines:") {
            let count = gap.dropFirst("malformed_lines:".count)
            return "\(count) malformed \(count == "1" ? "line" : "lines")"
        }
        if gap.hasPrefix("item_cap:") {
            return "item cap reached (\(gap.dropFirst("item_cap:".count))) — later rows omitted"
        }
        if gap.hasPrefix("transcript_too_large:") {
            return "transcript too large to rebuild (\(gap.dropFirst("transcript_too_large:".count)) bytes)"
        }
        if gap.hasPrefix("timeline_item_cap:") {
            return "transcript exceeds the item cap — earliest rows omitted"
        }
        switch gap {
        case "unsupported_provider":
            return "this provider's transcript format is not read yet"
        case "transcript_not_found":
            return "no transcript found for this session"
        case "transcript_unreadable":
            return "the transcript file could not be read"
        default:
            return gap.hasPrefix("gap:") ? "capture gap: \(gap.dropFirst(4))" : gap
        }
    }
}

extension FailureStory {
    /// Only what the story actually knows — intent, the last error,
    /// mid-turn death, the failed tools — as one sentence; nils drop out.
    public var sentence: String {
        var parts: [String] = []
        if let intent = lastUserIntent, !intent.isEmpty {
            parts.append("Last asked: \(intent)")
        }
        if let summary = lastErrorSummary, !summary.isEmpty {
            parts.append("Then \(summary)")
        } else if errorCount > 0 {
            parts.append("\(errorCount) \(errorCount == 1 ? "error" : "errors") in these rows")
        }
        if let seconds = failingTurnSeconds, seconds >= 1 {
            parts.append("It failed \(Self.duration(seconds)) into the turn")
        }
        if diedMidTurn {
            parts.append("The session ended mid-turn")
        }
        if !failedToolNames.isEmpty {
            parts.append("Failed tools: \(failedToolNames.joined(separator: ", "))")
        }
        guard !parts.isEmpty else { return "These rows show a failure." }
        // A quoted intent or error often ends its own sentence; add a
        // full stop only where one is missing, never a second.
        return parts.map { part in
            part.last.map { ".!?…".contains($0) } == true ? part : part + "."
        }.joined(separator: " ")
    }

    /// "42 s", "3 min 12 s", "1 h 4 min".
    static func duration(_ seconds: Double) -> String {
        UsageTime.duration(seconds)
    }
}
