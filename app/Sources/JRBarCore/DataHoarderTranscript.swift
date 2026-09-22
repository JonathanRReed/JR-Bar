import Foundation

/// What the capture engine learned from a file's newest lines: provider
/// identity plus whatever the transcript itself declares. Fields merge
/// monotonically — later segments enrich, never erase.
public struct TranscriptMetadata: Sendable, Equatable {
    /// "claude" / "codex" / "other".
    public var provider: String?
    public var sessionID: String?
    /// The session's working directory as the transcript records it.
    public var project: String?
    public var model: String?
    /// First user prompt — only populated when full-content consent is on.
    public var title: String?
    public var startedAt: Date?
    public var lastActivityAt: Date?

    public init(provider: String? = nil, sessionID: String? = nil,
                project: String? = nil, model: String? = nil, title: String? = nil,
                startedAt: Date? = nil, lastActivityAt: Date? = nil) {
        self.provider = provider
        self.sessionID = sessionID
        self.project = project
        self.model = model
        self.title = title
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
    }
}

/// Reads Claude Code and Codex JSONL shapes from freshly captured lines.
///
/// Claude rows look like `{"type":"assistant","sessionId":…,"cwd":…,
/// "timestamp":…,"message":{"model":…,"content":[…]}}`; Codex rows look like
/// `{"timestamp":…,"type":"session_meta","payload":{"id":…,"cwd":…}}` with
/// `turn_context` carrying the model and `response_item` the messages.
/// Anything else reports provider "other" and yields no metadata — the
/// archive keeps the bytes, it just can't describe them.
public enum TranscriptProbe {
    private static let titleLimit = 160

    /// Fold one pass of complete lines into `metadata`. `includeTitle`
    /// follows the full-content consent — a prompt fragment is content, so
    /// redacted captures never write it even to the catalog.
    public static func ingest(lines: [String], into metadata: inout TranscriptMetadata,
                              includeTitle: Bool) {
        // CLIProxyAPI request logs are section-marked text, not JSONL —
        // one probe of the whole batch classifies the file.
        if absorbCLIProxy(lines: lines, into: &metadata) { return }
        var sawKnown = false
        var sawUnknown = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
                  let row = object as? [String: Any] else {
                if !trimmed.isEmpty { sawUnknown = true }
                continue
            }
            if isClaude(row) {
                sawKnown = true
                metadata.provider = "claude"
                absorbClaude(row, into: &metadata, includeTitle: includeTitle)
            } else if isCodex(row) {
                sawKnown = true
                if metadata.provider == nil { metadata.provider = "codex" }
                absorbCodex(row, into: &metadata, includeTitle: includeTitle)
            } else {
                sawUnknown = true
            }
        }
        if metadata.provider == nil, !sawKnown, sawUnknown {
            metadata.provider = "other"
        }
    }

    // MARK: CLIProxyAPI

    /// A CLIProxyAPI request log yields request-line metadata: provider
    /// `cliproxy`, the session id it carried, the client as `project`, and
    /// a `"POST /v1/messages → 500"`-style title built from method, path
    /// and status — request metadata the redacted copy keeps verbatim, so
    /// it is safe regardless of the content consent.
    private static func absorbCLIProxy(lines: [String],
                                       into metadata: inout TranscriptMetadata) -> Bool {
        // The marker may open the file or resume a multi-request log mid-
        // delta — parse from wherever it stands. A delta with no marker at
        // all stays unrecognised ("other", which never displaces a named
        // provider at the catalog merge).
        guard let markerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == CLIProxyLogParser.requestInfoMarker
        }) else { return false }
        let data = Data(lines[markerIndex...].joined(separator: "\n").utf8)
        guard let request = CLIProxyLogParser.parse(data) else { return false }
        metadata.provider = "cliproxy"
        if let session = request.sessionID, !session.isEmpty {
            metadata.sessionID = session
        }
        if let model = request.model, !model.isEmpty {
            metadata.model = model
        }
        if let client = request.client, !client.isEmpty {
            metadata.project = client
        }
        if metadata.title == nil {
            let status = request.status.map(String.init) ?? "…"
            metadata.title = "\(request.method ?? "?") \(request.path ?? "?") → \(status)"
        }
        if let stamp = request.timestamp {
            metadata.startedAt = stamp
            metadata.lastActivityAt = stamp
        }
        return true
    }

    // MARK: Claude

    private static func isClaude(_ row: [String: Any]) -> Bool {
        if row["sessionId"] is String { return true }
        guard row["message"] is [String: Any], let type = row["type"] as? String else { return false }
        return ["user", "assistant", "summary", "system", "file-history-snapshot"].contains(type)
    }

    private static func absorbClaude(_ row: [String: Any], into metadata: inout TranscriptMetadata,
                                     includeTitle: Bool) {
        if let session = row["sessionId"] as? String, !session.isEmpty {
            metadata.sessionID = session
        }
        if let cwd = row["cwd"] as? String, !cwd.isEmpty {
            metadata.project = cwd
        }
        absorbTimestamp(row["timestamp"], into: &metadata)
        if let message = row["message"] as? [String: Any],
           let model = message["model"] as? String, !model.isEmpty {
            metadata.model = model
        }
        if includeTitle, metadata.title == nil, row["type"] as? String == "user",
           let message = row["message"] as? [String: Any],
           (message["role"] as? String) == "user" {
            metadata.title = firstText(in: message["content"])
        }
    }

    /// Claude content is a plain string or an array of typed blocks;
    /// the title is the first text block's body.
    private static func firstText(in content: Any?) -> String? {
        if let text = content as? String { return trimmedTitle(text) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String { return trimmedTitle(text) }
        }
        return nil
    }

    // MARK: Codex

    private static func isCodex(_ row: [String: Any]) -> Bool {
        row["payload"] is [String: Any] && row["type"] is String
    }

    private static func absorbCodex(_ row: [String: Any], into metadata: inout TranscriptMetadata,
                                    includeTitle: Bool) {
        guard let payload = row["payload"] as? [String: Any] else { return }
        absorbTimestamp(row["timestamp"], into: &metadata)
        switch row["type"] as? String {
        case "session_meta":
            if let id = payload["id"] as? String, !id.isEmpty {
                metadata.sessionID = id
            }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                metadata.project = cwd
            }
            absorbTimestamp(payload["timestamp"], into: &metadata)
        case "turn_context":
            if let model = payload["model"] as? String, !model.isEmpty {
                metadata.model = model
            }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                metadata.project = cwd
            }
        case "response_item":
            guard includeTitle, metadata.title == nil,
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "input_text" {
                if let text = block["text"] as? String {
                    metadata.title = trimmedTitle(text)
                    return
                }
            }
        default:
            break
        }
    }

    // MARK: Shared

    // Read-only after init; Foundation's date formatters are thread-safe on
    // modern OSes but don't declare Sendable.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }

    private static func absorbTimestamp(_ raw: Any?, into metadata: inout TranscriptMetadata) {
        guard let stamp = timestamp(raw) else { return }
        if metadata.startedAt == nil || stamp < metadata.startedAt! {
            metadata.startedAt = stamp
        }
        if metadata.lastActivityAt == nil || stamp > metadata.lastActivityAt! {
            metadata.lastActivityAt = stamp
        }
    }

    private static func trimmedTitle(_ text: String) -> String? {
        let collapsed = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(titleLimit))
    }
}

/// The consent gate's write path: with `fullContentCapture` off, stored
/// segments keep the transcript's structure — types, roles, timestamps,
/// tool names, ids, token counts, error fields — while every free-text
/// value under a content-bearing key becomes `"[redacted N chars]"`.
/// A line that is not a JSON object stores `"[unparsed N bytes]"` so a
/// redacted segment never fabricates structure it could not read.
public enum TranscriptRedactor {
    /// Keys whose *string* values carry prompts, responses, or tool payloads.
    /// Membership only matters for documentation now — the verbatim rule is
    /// ``safeKeys``, and no sensitive key is on it. The set still marks
    /// subtrees that are content by *name* when callers reason about shape.
    static let sensitiveKeys: Set<String> = [
        "content", "text", "message", "thinking", "prompt", "summary",
        "input", "output", "result", "command", "arguments", "instructions",
        "query", "last_assistant_message",
        // Tool results and edit payloads: Bash stdout/stderr, Edit/Write
        // originals and patches — these carry file contents and command
        // output verbatim in Claude transcripts.
        "stdout", "stderr", "originalFile", "oldString", "newString",
        "structuredPatch", "patch", "diff", "fileText", "data", "response",
        "body", "payload", "toolUseResult", "file_content", "contents",
    ]

    /// Keys that stay verbatim even inside a redacted subtree — the shape
    /// markers reconstruction and search rely on. Everything else under a
    /// sensitive key is content, whatever name it wears.
    static let structuralKeys: Set<String> = [
        "type", "role", "name", "id", "tool_use_id", "toolUseId", "model",
        "stop_reason", "finish_reason", "status", "is_error", "isError",
        "uuid", "parentUuid", "sessionId", "timestamp",
    ]

    /// Keys whose strings are metadata, not content — the verbatim
    /// allowlist. A string under any *other* key redacts at any depth:
    /// the consent contract is "structure survives, content does not",
    /// and a key the format list has never seen cannot be trusted to
    /// carry metadata. Nested values under a non-safe key redact the
    /// same way — `{"custom": {"notes": "…"}}` keeps no text.
    static let safeKeys: Set<String> = structuralKeys.union([
        "cwd", "version", "gitBranch", "requestId", "userType",
        "entrypoint", "slug", "messageType", "permissionMode",
        "toolName", "level", "provider", "project", "subtype",
        "operation", "session_id", "chat_id", "model_id",
        "created_at", "updated_at", "duration_ms",
    ])

    /// Redact every line in `data` (assumed already cut on line boundaries).
    /// CLIProxyAPI logs are section-marked text, not JSONL — they take the
    /// section-aware redactor that keeps the skeleton and drops the bodies.
    public static func redact(_ data: Data) -> Data {
        if CLIProxyLogParser.looksLikeCLIProxyLog(data) {
            return CLIProxyRedactor.redact(data)
        }
        var output = Data()
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            output.append(contentsOf: redactSlice(data[start..<index]))
            output.append(0x0A)
            start = index + 1
        }
        if start < data.endIndex {
            output.append(contentsOf: redactSlice(data[start...]))
        }
        return output
    }

    public static func redactLine(_ line: String) -> String {
        String(decoding: redactSlice(Data(line.utf8)), as: UTF8.self)
    }

    private static func redactSlice(_ slice: Data.SubSequence) -> Data {
        let line = String(decoding: slice, as: UTF8.self)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Data(line.utf8) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            return unparsed(slice)
        }
        if let row = object as? [String: Any] {
            return serialize(redactValue(row) as? [String: Any] ?? row)
        }
        // A bare JSON string line is itself content.
        if let text = object as? String {
            return serialize("[redacted \(text.count) chars]")
        }
        // A bare JSON array is content too — `[{"text": "…"}]` stores no
        // key the allowlist could check, so the elements ride the
        // sensitive path. Numbers and booleans cannot carry text.
        if object is [Any] {
            return serialize(redactValue(object, insideSensitive: true))
        }
        return serialize(object)
    }

    private static func unparsed(_ slice: Data.SubSequence) -> Data {
        serialize("[unparsed \(slice.count) bytes]")
    }

    private static func serialize(_ object: Any) -> Data {
        // .fragmentsAllowed lets the marker strings and bare JSON scalars
        // serialize — without it Foundation raises an uncatchable exception.
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else {
            return Data("\"[unparsed]\"".utf8)
        }
        return data
    }

    /// `insideSensitive` is set while descending under a sensitive key, so
    /// a bare string element — `"content": ["…"]` — or a string under an
    /// unknown nested key — `"input": {"payload": "…"}` — is still treated
    /// as content. Structural fields (`type`, `role`, `name`) survive at
    /// any depth so the redacted segment keeps its shape.
    private static func redactValue(_ value: Any, insideSensitive: Bool = false) -> Any {
        switch value {
        case let text as String:
            return insideSensitive ? "[redacted \(text.count) chars]" : text
        case let row as [String: Any]:
            var copy = row
            for (key, element) in row {
                // A string stays verbatim only under a known-metadata key —
                // whether the row is top-level, under a sensitive parent,
                // or under a key no format list recognizes.
                if let text = element as? String {
                    copy[key] = safeKeys.contains(key)
                        ? text : "[redacted \(text.count) chars]"
                } else {
                    copy[key] = redactValue(
                        element,
                        insideSensitive: insideSensitive || !safeKeys.contains(key))
                }
            }
            return copy
        case let list as [Any]:
            return list.map { redactValue($0, insideSensitive: insideSensitive) }
        default:
            return value
        }
    }
}
