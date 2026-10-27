import Foundation

/// How a session is named on screen. Today's daemon sends human labels
/// (`jr-bar-67`, `Codex 01a08b62`) with a `short_id`; older ones sent the
/// provider name plus a UUID. Either way the panel shows a single short
/// label with no UUID in it and no provider name at the front, so a caller
/// can write "Claude jr-bar-67" without ever producing "Claude Claude …".
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

    /// The shared title without a provider prefix or an opaque session id.
    /// Ids belong in help and accessibility, never in a title fallback.
    public static func display(label: String?, shortId: String?, id: String, provider: String) -> String {
        let providerWords = Set([provider, providerName(provider)].map { $0.lowercased() }.filter { !$0.isEmpty })
        var text = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // "Claude fca1eb06-…" → "fca1eb06-…"; "Codex 01a08b62" → "01a08b62".
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let first = words.first, providerWords.contains(first.lowercased()) {
            text = words.dropFirst().joined(separator: " ")
        }
        text = humanTitle(text)
        if text.isEmpty || providerWords.contains(text.lowercased()) { return "Session" }
        return text
    }

    /// Context comes only from the daemon's proven groups, as in the panel.
    public static func contextual(_ session: CoreSession, sessions: [CoreSession], groups: [CoreAgentGroup]) -> String {
        guard let group = groups.first(where: { $0.id == session.groupId && $0.members.contains(session.id) }),
              group.rootWorkKey != session.id,
              let head = sessions.first(where: { $0.id == group.rootWorkKey && $0.groupId == group.id }) else { return session.displayLabel }
        let title = session.displayLabel
        let fallback = "\(head.displayLabel) worker "
        if title.hasPrefix(fallback), Int(title.dropFirst(fallback.count)) != nil { return title }
        return "\(title) · under \(head.displayLabel)"
    }

    /// A notice uses the current session title, then its saved event title.
    public static func eventTitle(_ event: CoreEvent, session: CoreSession?) -> String? {
        if let session { return session.displayLabel }
        guard let label = event.label, !label.isEmpty else { return nil }
        let title = event.session == nil ? humanTitle(label)
            : display(label: label, shortId: nil, id: event.session ?? "", provider: event.provider ?? "")
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
