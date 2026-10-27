import Foundation

/// Shared access to daemon session names and compatibility for saved labels.
public enum SessionLabel {
    static let uuidPattern = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    static let hexRunPattern = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{16,}$")
    static let sessionIDPattern = try! NSRegularExpression(pattern: "\\b(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{8,})\\b")

    /// Old events and saved history can still carry generated id labels.
    public static func humanTitle(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return sessionIDPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .replacingOccurrences(of: "()", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A UUID, or a bare hex run of 16+ characters (a sub-agent id).
    public static func looksLikeUUID(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = uuidPattern.firstMatch(in: trimmed, range: range), match.range == range { return true }
        return hexRunPattern.firstMatch(in: trimmed, range: range) != nil
    }

    /// Every UUID inside `text` shortened to its first eight characters.
    public static func shorteningUUIDs(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in uuidPattern.matches(in: text, range: range).reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: result[swiftRange].prefix(8))
        }
        return result
    }

    /// Compatibility for saved labels. Current labels come from the daemon.
    public static func display(label: String?, shortId: String?, id: String, provider: String,
                               cwd: String? = nil, project: String? = nil, detail: String? = nil) -> String {
        for candidate in [label, detail] {
            guard let candidate, let title = title(candidate, provider: provider) else { continue }
            let nativeID = id.split(separator: ":", maxSplits: 2).last.map(String.init) ?? id
            let generated = candidate.lowercased().hasPrefix(providerName(provider).lowercased() + " ")
            if title != AgentProject.name(of: cwd), title != id, !generated || title != nativeID { return title }
        }
        return "\(providerName(provider)) session in \(project ?? AgentProject.name(of: cwd) ?? "Unknown project")"
    }

    private static func title(_ value: String, provider: String) -> String? {
        var text = humanTitle(value)
        let prefix = providerName(provider) + " "
        if text.lowercased().hasPrefix(prefix.lowercased()), !text.lowercased().hasPrefix(prefix.lowercased() + "session in ") {
            text = String(text.dropFirst(prefix.count))
        }
        if text.range(of: #"^[0-9a-fA-F]{4,}$"#, options: .regularExpression) != nil,
           text.rangeOfCharacter(from: .decimalDigits) != nil { return nil }
        guard !text.isEmpty, !text.hasPrefix("t3-"), !text.hasPrefix("/"), !text.hasPrefix("~/"), !text.contains("/t3-"),
              !["session", "worker", "agent", provider.lowercased(), providerName(provider).lowercased(),
                providerName(provider).lowercased() + " session", providerName(provider).lowercased() + " agent"].contains(text.lowercased())
        else { return nil }
        return text
    }

    /// Group context is already part of the daemon's canonical title.
    public static func contextual(_ session: CoreSession, sessions: [CoreSession], groups: [CoreAgentGroup]) -> String {
        session.displayLabel
    }

    /// A notice uses the current session title, then its saved event title.
    public static func eventTitle(_ event: CoreEvent, session: CoreSession?) -> String? {
        if let session { return session.displayLabel }
        if let id = event.session {
            return display(label: event.label, shortId: nil, id: id, provider: event.provider ?? "")
        }
        guard let label = event.label, !label.isEmpty else { return nil }
        let title = humanTitle(label)
        return title.isEmpty ? nil : title
    }

    /// `claude` → `Claude`, `opencode` → `OpenCode`, an unknown id capitalised.
    public static func providerName(_ id: String) -> String {
        switch ProviderID.canonical(id) {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "opencode": return "OpenCode"
        case "openclaw": return "OpenClaw"
        case "antigravity": return "Antigravity"
        case "cursor": return "Cursor"
        case "devin": return "Devin"
        case "factory": return "Factory"
        case "kimi": return "Kimi Code"
        case "kilo": return "Kilo"
        case "openai-api": return "OpenAI API"
        case "t3code": return "T3 Code"
        case "jrbar": return "JR-Bar"
        case "grok": return "Grok"
        case "hermes": return "Hermes"
        case "kiro": return "Kiro"
        case "pi": return "Pi"
        case "": return "Agent"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

extension CoreSession {
    /// A session mirrored from a peer Mac (`remote:<machine>:<source id>`).
    /// It describes work happening somewhere else: nothing in this process
    /// can raise its window or type an answer into it, so no surface may
    /// offer a local action for it.
    public var isRemote: Bool { Self.isRemoteID(id) }

    /// Whether a session id names a remote-peer row.
    public static func isRemoteID(_ id: String) -> Bool { id.hasPrefix("remote:") }

    /// The machine a remote id runs on (`remote:studio-mac:…` →
    /// "studio-mac"), for the row's "on studio-mac" line; nil when the id
    /// carries no machine segment.
    public static func remoteMachine(inID id: String) -> String? {
        guard isRemoteID(id) else { return nil }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// The machine a remote row runs on, for the "on studio-mac" line.
    public var remoteMachine: String? { Self.remoteMachine(inID: id) }
}
