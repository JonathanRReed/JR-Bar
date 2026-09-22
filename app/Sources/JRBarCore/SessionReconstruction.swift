import Foundation

/// One rebuilt timeline row — the archived-session twin of the live
/// `session_timeline` items the Python side projects from Claude Code and
/// Codex transcripts. `at` is the row's own stamp (epoch seconds);
/// `untrusted` marks content that must never render as a command or an
/// approval (T44); `redacted` marks a text payload withheld by the
/// metadata-only consent mode.
public struct ReconstructedItem: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case message
        case toolUse
        case toolResult
        case turnEnd
    }

    public let seq: Int
    public let at: Double?            // epoch seconds
    public let kind: Kind
    public let uuid: String?
    public let parentUUID: String?
    public let role: String?          // "user"/"assistant"
    public let name: String?          // tool name, or turn-end reason
    public let toolUseID: String?
    public let isError: Bool
    public let sidechain: Bool
    public let untrusted: Bool
    public let redacted: Bool         // text was redacted/missing due to consent mode
    public let text: String?
    public let model: String?

    public init(seq: Int, at: Double? = nil, kind: Kind,
                uuid: String? = nil, parentUUID: String? = nil,
                role: String? = nil, name: String? = nil,
                toolUseID: String? = nil, isError: Bool = false,
                sidechain: Bool = false, untrusted: Bool = false,
                redacted: Bool = false, text: String? = nil,
                model: String? = nil) {
        self.seq = seq
        self.at = at
        self.kind = kind
        self.uuid = uuid
        self.parentUUID = parentUUID
        self.role = role
        self.name = name
        self.toolUseID = toolUseID
        self.isError = isError
        self.sidechain = sidechain
        self.untrusted = untrusted
        self.redacted = redacted
        self.text = text
        self.model = model
    }

    /// The post-sort renumbering writes a fresh item — fields stay `let`.
    func renumbered(_ seq: Int) -> ReconstructedItem {
        ReconstructedItem(seq: seq, at: at, kind: kind, uuid: uuid,
                          parentUUID: parentUUID, role: role, name: name,
                          toolUseID: toolUseID, isError: isError,
                          sidechain: sidechain, untrusted: untrusted,
                          redacted: redacted, text: text, model: model)
    }
}

/// What went wrong in the session, derived from the reconstructed items.
/// Nothing here is guessed: a clean ending reports `failed == false`, a
/// transcript that stops mid-work reports `diedMidTurn`, and error counts
/// only ever count `isError` items.
public struct FailureStory: Sendable, Equatable {
    public let failed: Bool
    public let errorCount: Int
    public let lastErrorSummary: String?
    public let diedMidTurn: Bool      // last activity has no closing turn_end
    public let lastUserIntent: String?// bounded last user message
    public let failedToolNames: [String]

    public init(failed: Bool, errorCount: Int, lastErrorSummary: String?,
                diedMidTurn: Bool, lastUserIntent: String?,
                failedToolNames: [String]) {
        self.failed = failed
        self.errorCount = errorCount
        self.lastErrorSummary = lastErrorSummary
        self.diedMidTurn = diedMidTurn
        self.lastUserIntent = lastUserIntent
        self.failedToolNames = failedToolNames
    }
}

/// The reconstruction result: ordered items, the failure story, and the
/// honest gaps — named, never hidden (`malformed_lines:3`,
/// `item_cap:5000`, `unsupported_provider`, `transcript_too_large:N`).
public struct SessionReconstruction: Sendable, Equatable {
    public let items: [ReconstructedItem]
    public let story: FailureStory
    public let gaps: [String]
    public let totalLines: Int
    public let redactedLines: Int

    public init(items: [ReconstructedItem], story: FailureStory,
                gaps: [String], totalLines: Int, redactedLines: Int) {
        self.items = items
        self.story = story
        self.gaps = gaps
        self.totalLines = totalLines
        self.redactedLines = redactedLines
    }
}

/// Rebuilds a timeline from archived transcript segments — the same
/// row→item projection as `src/jrbar/session_timeline.py`
/// (`claude_row_items` / `codex_row_items`), applied to stored segment
/// payloads instead of the original file.
///
/// Rows the consent redactor rewrote still parse: structure survives, and
/// `"[redacted N chars]"` / `"[unparsed N bytes]"` sentinels become
/// `redacted` items rather than phantom content. Malformed lines are
/// counted as a named gap, never thrown.
public enum SessionReconstructor {
    /// ~4000 chars per the worker contract — the Python TIMELINE_TEXT_MAX
    /// analogue (the Python value is 600; the contract asked for ~4000).
    private static let textLimit = 4_000
    private static let maxItems = 5_000
    /// Mirrors TIMELINE_MAX_BYTES: beyond this the record is reported as a
    /// named gap instead of being silently sampled.
    private static let maxBytes = 64 * 1024 * 1024
    private static let intentLimit = 200

    /// The consent redactor's whole-value sentinels.
    private static func isConsentSentinel(_ text: String) -> Bool {
        if text.hasPrefix("[redacted "), text.hasSuffix(" chars]") {
            return text.dropFirst(10).dropLast(7).allSatisfy(\.isNumber)
        }
        if text.hasPrefix("[unparsed "), text.hasSuffix(" bytes]") {
            return text.dropFirst(10).dropLast(7).allSatisfy(\.isNumber)
        }
        return false
    }

    /// Any sentinel value anywhere in a parsed row — the line carried
    /// redaction even though its structure survived.
    private static func containsSentinel(_ value: Any) -> Bool {
        switch value {
        case let text as String:
            return isConsentSentinel(text)
        case let row as [String: Any]:
            return row.values.contains { containsSentinel($0) }
        case let list as [Any]:
            return list.contains { containsSentinel($0) }
        default:
            return false
        }
    }

    /// Python `_string`: trimmed, non-empty, else nil.
    private static func stringValue(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Python truthiness for JSON values — "" / 0 / false / [] / {} are false.
    private static func truthy(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let flag = boolValue(value) { return flag }
        switch value {
        case let number as NSNumber: return number.doubleValue != 0
        case let text as String: return !text.isEmpty
        case let list as [Any]: return !list.isEmpty
        case let row as [String: Any]: return !row.isEmpty
        default: return true
        }
    }

    /// JSON booleans arrive as NSNumber; `as? Bool` cannot tell true from 1.
    private static func boolValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Python `str(value)` for a turn-end reason.
    private static func stringify(_ value: Any) -> String {
        if let flag = boolValue(value) { return flag ? "True" : "False" }
        if let text = value as? String { return text }
        return String(describing: value)
    }

    /// Python `_content_text`: a plain string, or the joined `text` of
    /// text-ish blocks (Claude `text`; Codex `input_text`/`output_text`).
    private static func contentText(_ content: Any?) -> String? {
        if let text = stringValue(content) { return text }
        guard let blocks = content as? [Any] else { return nil }
        var parts: [String] = []
        for block in blocks {
            if let dict = block as? [String: Any],
               ["text", "input_text", "output_text"].contains(dict["type"] as? String),
               let text = stringValue(dict["text"]) {
                parts.append(text)
            } else if let text = block as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Python `_summarize_input`: a tool_use input as bounded text —
    /// shown as context, never run.
    private static func summarizeInput(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(textLimit * 2))
        }
        return String(describing: value)
    }

    /// Python `_SECRET_RUN` — long token-shaped runs mask as `[redacted]`.
    private static let secretRun = try! NSRegularExpression(
        pattern: "[A-Za-z0-9_\\-+/=.]{24,}")

    /// Python `_bound_text`: trimmed, length-bounded, secret-run masked.
    private static func boundText(_ value: Any?) -> String? {
        guard var text = stringValue(value) else { return nil }
        if text.count > textLimit {
            text = String(text.prefix(textLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return secretRun.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: "[redacted]")
    }

    /// The text field plus its consent flag: a whole-value sentinel means
    /// the payload was withheld — `redacted = true`, `text = nil`.
    private static func textAndRedacted(_ raw: Any?) -> (text: String?, redacted: Bool) {
        guard let trimmed = stringValue(raw) else { return (nil, false) }
        if isConsentSentinel(trimmed) { return (nil, true) }
        return (boundText(trimmed), false)
    }

    /// `epochFallback` seeds `fallbackAt` the way the Python timeline seeds
    /// it from file mtime — without it, leading timestamp-less rows sort
    /// last and can falsely read as a mid-turn death.
    public static func reconstruct(segments: [Data], provider: String,
                                   epochFallback: Date? = nil) -> SessionReconstruction {
        var gaps: [String] = []
        var items: [ReconstructedItem] = []
        var totalLines = 0
        var redactedLines = 0
        var malformed = 0
        let supported = provider == "claude" || provider == "codex"
        if !supported { gaps.append("unsupported_provider") }

        var totalBytes = 0
        for segment in segments { totalBytes += segment.count }
        var data = Data()
        data.reserveCapacity(totalBytes)
        for segment in segments { data.append(segment) }
        if totalBytes > maxBytes {
            let lines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
                + (data.last == 0x0A || data.isEmpty ? 0 : 1)
            return SessionReconstruction(
                items: [], story: story(for: []),
                gaps: gaps + ["transcript_too_large:\(totalBytes)"],
                totalLines: lines, redactedLines: 0)
        }

        var fallbackAt: Double? = epochFallback?.timeIntervalSince1970
        var turnID: String? = nil
        var truncated = false

        var start = 0
        var lineRanges: [Range<Int>] = []
        for index in 0..<data.count where data[index] == 0x0A {
            lineRanges.append(start..<index)
            start = index + 1
        }
        if start < data.count { lineRanges.append(start..<data.count) }

        // The cap anchors to the tail: a transcript that outgrows it keeps its
        // newest events — dropping the tail would hide the very failure the
        // timeline exists to surface. `seq` counts every appended item so the
        // pre-sort index stays monotonic after front-trimming.
        var seq = 0
        for range in lineRanges {
            totalLines += 1
            let line = String(decoding: data[range], as: UTF8.self)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(trimmed.utf8), options: [.fragmentsAllowed]) else {
                malformed += 1
                continue
            }
            if let scalar = object as? String {
                // A whole-line sentinel: the redactor could not keep the row.
                if isConsentSentinel(scalar) {
                    redactedLines += 1
                    if scalar.hasPrefix("[unparsed") { malformed += 1 }
                } else {
                    malformed += 1
                }
                continue
            }
            guard let row = object as? [String: Any] else {
                malformed += 1
                continue
            }
            if containsSentinel(row) { redactedLines += 1 }
            let rowItems: [ReconstructedItem]
            switch provider {
            case "claude":
                rowItems = claudeRowItems(row, fallbackAt: &fallbackAt)
            case "codex":
                rowItems = codexRowItems(row, fallbackAt: &fallbackAt, turnID: &turnID)
            default:
                rowItems = []
            }
            for item in rowItems {
                items.append(item.renumbered(seq))
                seq += 1
            }
            // Trim in chunks so a long file stays amortized-linear and the
            // window never holds more than ~2× the cap.
            if items.count > maxItems * 2 {
                items.removeFirst(items.count - maxItems)
                truncated = true
            }
        }
        if items.count > maxItems {
            items.removeFirst(items.count - maxItems)
            truncated = true
        }
        if malformed > 0 { gaps.append("malformed_lines:\(malformed)") }
        if truncated { gaps.append("item_cap:\(maxItems)") }

        // Python: sort by (at is None, at or 0.0, seq), then renumber.
        items.sort { left, right in
            switch (left.at, right.at) {
            case let (leftAt?, rightAt?):
                return leftAt == rightAt ? left.seq < right.seq : leftAt < rightAt
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.seq < right.seq
            }
        }
        items = items.enumerated().map { $0.element.renumbered($0.offset) }
        return SessionReconstruction(
            items: items, story: story(for: items), gaps: gaps,
            totalLines: totalLines, redactedLines: redactedLines)
    }

    /// `parse_datetime(row["timestamp"], fallback)` — a missing or bad stamp
    /// inherits the previous row's; the returned stamp becomes the new floor.
    private static func rowAt(_ row: [String: Any], fallbackAt: inout Double?) -> Double? {
        if let stamp = TranscriptProbe.timestamp(row["timestamp"]) {
            fallbackAt = stamp.timeIntervalSince1970
        }
        return fallbackAt
    }

    // MARK: Claude rows (`claude_row_items`)

    private static func claudeRowItems(
        _ row: [String: Any], fallbackAt: inout Double?
    ) -> [ReconstructedItem] {
        let at = rowAt(row, fallbackAt: &fallbackAt)
        let uuid = stringValue(row["uuid"])
        let parentUUID = stringValue(row["parentUuid"])
        let sidechain = truthy(row["isSidechain"])
        let message = row["message"] as? [String: Any]
        let content = message?["content"]
        var items: [ReconstructedItem] = []
        func append(_ kind: ReconstructedItem.Kind, role: String? = nil,
                    name: String? = nil, toolUseID: String? = nil,
                    isError: Bool = false, untrusted: Bool,
                    redacted: Bool = false, text: String? = nil,
                    model: String? = nil) {
            items.append(ReconstructedItem(
                seq: items.count, at: at, kind: kind, uuid: uuid,
                parentUUID: parentUUID, role: role, name: name,
                toolUseID: toolUseID, isError: isError, sidechain: sidechain,
                untrusted: untrusted, redacted: redacted, text: text, model: model))
        }

        if row["type"] as? String == "user", boolValue(row["isMeta"]) != true {
            if let blocks = content as? [Any] {
                for block in blocks {
                    guard let block = block as? [String: Any] else { continue }
                    if block["type"] as? String == "tool_result" {
                        let field = textAndRedacted(contentText(block["content"]))
                        append(.toolResult,
                               toolUseID: stringValue(block["tool_use_id"]),
                               isError: truthy(block["is_error"]),
                               untrusted: true,
                               redacted: field.redacted, text: field.text)
                    } else if block["type"] as? String == "text",
                              let raw = contentText([block]),
                              !raw.hasPrefix("<task-notification>") {
                        let field = textAndRedacted(raw)
                        append(.message, role: "user", untrusted: false,
                               redacted: field.redacted, text: field.text)
                    }
                }
            } else if let raw = contentText(content),
                      !raw.hasPrefix("<task-notification>") {
                let field = textAndRedacted(raw)
                append(.message, role: "user", untrusted: false,
                       redacted: field.redacted, text: field.text)
            }
            // ``toolUseResult`` rides on the user row; it is the durable
            // result marker when the content blocks were compacted away.
            let result = row["toolUseResult"]
            if let result, !(result is NSNull), items.isEmpty {
                let dict = result as? [String: Any]
                let status = dict?["status"] as? String
                let raw = dict != nil ? contentText(dict?["content"]) : stringValue(result)
                let field = textAndRedacted(raw)
                append(.toolResult,
                       toolUseID: stringValue(row["sourceToolAssistantUUID"]),
                       isError: status == "error" || status == "failed",
                       untrusted: true,
                       redacted: field.redacted, text: field.text)
            }
        } else if row["type"] as? String == "assistant", let message {
            if let blocks = content as? [Any] {
                for block in blocks {
                    guard let block = block as? [String: Any],
                          block["type"] as? String == "tool_use" else { continue }
                    let field = textAndRedacted(summarizeInput(block["input"]))
                    append(.toolUse, role: "assistant",
                           name: stringValue(block["name"]),
                           toolUseID: stringValue(block["id"]),
                           untrusted: false,
                           redacted: field.redacted, text: field.text)
                }
            }
            if let raw = contentText(content) {
                let field = textAndRedacted(raw)
                append(.message, role: "assistant",
                       untrusted: true,  // model output is untrusted content (T44)
                       redacted: field.redacted, text: field.text,
                       model: stringValue(message["model"]))
            }
            if let stop = message["stop_reason"], !(stop is NSNull), truthy(stop) {
                append(.turnEnd, name: stringify(stop), untrusted: false)
            }
        }
        return items
    }

    // MARK: Codex rows (`codex_row_items`)

    private static func codexRowItems(
        _ row: [String: Any], fallbackAt: inout Double?, turnID: inout String?
    ) -> [ReconstructedItem] {
        let at = rowAt(row, fallbackAt: &fallbackAt)
        guard let payload = row["payload"] as? [String: Any] else { return [] }
        let payloadType = payload["type"] as? String
        if row["type"] as? String == "turn_context" || payloadType == "turn_context" {
            turnID = stringValue(payload["turn_id"]) ?? turnID
            return []
        }
        var items: [ReconstructedItem] = []
        func append(_ kind: ReconstructedItem.Kind, role: String? = nil,
                    name: String? = nil, toolUseID: String? = nil,
                    isError: Bool = false, untrusted: Bool,
                    redacted: Bool = false, text: String? = nil) {
            items.append(ReconstructedItem(
                seq: items.count, at: at, kind: kind, role: role, name: name,
                toolUseID: toolUseID, isError: isError,
                untrusted: untrusted, redacted: redacted, text: text))
        }

        switch payloadType {
        case "message":
            let role = stringValue(payload["role"])
            if let raw = contentText(payload["content"]),
               role == "user" || role == "assistant" {
                let field = textAndRedacted(raw)
                append(.message, role: role, name: turnID,
                       untrusted: role == "assistant",
                       redacted: field.redacted, text: field.text)
            }
        case "function_call", "local_shell_call", "custom_tool_call":
            let field = textAndRedacted(summarizeInput(payload["arguments"]))
            append(.toolUse, role: "assistant",
                   name: stringValue(payload["name"]),
                   toolUseID: stringValue(payload["call_id"]) ?? stringValue(payload["id"]),
                   untrusted: false,
                   redacted: field.redacted, text: field.text)
        case "function_call_output":
            let output = payload["output"]
            let outputDict = output as? [String: Any]
            var isError = outputDict.map { truthy($0["is_error"]) } ?? false
            if let outputText = output as? String {
                isError = isError
                    || outputText.prefix(64).lowercased().contains("error")
            }
            let raw = outputDict != nil
                ? contentText(outputDict?["content"]) : stringValue(output)
            let field = textAndRedacted(raw)
            append(.toolResult,
                   toolUseID: stringValue(payload["call_id"]),
                   isError: isError, untrusted: true,
                   redacted: field.redacted, text: field.text)
        case "task_complete":
            let field = textAndRedacted(payload["last_agent_message"])
            append(.turnEnd, name: "task_complete", untrusted: false,
                   redacted: field.redacted, text: field.text)
        case "turn_aborted":
            append(.turnEnd, name: "turn_aborted", isError: true,
                   untrusted: false)
        default:
            break
        }
        return items
    }

    // MARK: Live timelines

    /// The daemon's `session_timeline` items as a reconstruction, so the
    /// Overview inspector, History's expanded rows and the Data Hoarder
    /// archive render one timeline through one view instead of three.
    /// `running` withholds the mid-turn verdict: a session that is still
    /// working ends mid-turn by definition, and calling that a death would
    /// paint every live run as a failure. Unknown kinds are skipped, the
    /// way the transcript projection skips unknown rows.
    public static func reconstruction(from timeline: [CoreTimelineItem], gaps: [String] = [],
                                      running: Bool) -> SessionReconstruction {
        let items: [ReconstructedItem] = timeline.compactMap { item in
            let kind: ReconstructedItem.Kind
            switch item.kind {
            case "message": kind = .message
            case "tool_use": kind = .toolUse
            case "tool_result": kind = .toolResult
            case "turn_end": kind = .turnEnd
            default: return nil
            }
            return ReconstructedItem(
                seq: item.seq, at: item.at, kind: kind, uuid: item.uuid,
                parentUUID: item.parentUuid, role: item.role, name: item.name,
                toolUseID: item.toolUseId, isError: item.isError ?? false,
                sidechain: item.sidechain ?? false, untrusted: item.untrusted ?? false,
                text: item.text, model: item.model)
        }
        return SessionReconstruction(
            items: items, story: story(for: items, running: running), gaps: gaps,
            totalLines: timeline.count, redactedLines: 0)
    }

    // MARK: Failure story

    static func story(for items: [ReconstructedItem], running: Bool = false) -> FailureStory {
        let errorItems = items.filter(\.isError)
        let diedMidTurn = !running && !items.isEmpty && items.last?.kind != .turnEnd
        var lastErrorSummary: String? = nil
        if let last = errorItems.last {
            switch last.kind {
            case .turnEnd:
                lastErrorSummary = last.name == "turn_aborted"
                    ? "turn aborted"
                    : bounded(last.name.map { "turn end: \($0)" } ?? last.text)
            case .toolUse, .toolResult:
                let name = last.name ?? pairedToolName(for: last, in: items)
                lastErrorSummary = name.map { "tool `\($0)` failed" }
                    ?? "tool call failed"
            case .message:
                lastErrorSummary = bounded(last.text) ?? "error"
            }
        }
        let lastUserIntent = items.last {
            $0.kind == .message && $0.role == "user"
        }.flatMap { $0.text }.map { String($0.prefix(intentLimit)) }
        var failedToolNames: [String] = []
        for item in errorItems where item.kind == .toolUse || item.kind == .toolResult {
            if let name = item.name ?? pairedToolName(for: item, in: items),
               !failedToolNames.contains(name) {
                failedToolNames.append(name)
            }
        }
        return FailureStory(
            failed: !errorItems.isEmpty || diedMidTurn,
            errorCount: errorItems.count,
            lastErrorSummary: lastErrorSummary,
            diedMidTurn: diedMidTurn,
            lastUserIntent: lastUserIntent,
            failedToolNames: failedToolNames)
    }

    /// A failed tool_result's name lives on its paired tool_use row.
    private static func pairedToolName(
        for item: ReconstructedItem, in items: [ReconstructedItem]
    ) -> String? {
        guard let id = item.toolUseID else { return nil }
        return items.first { $0.kind == .toolUse && $0.toolUseID == id }?.name
    }

    private static func bounded(_ text: String?) -> String? {
        text.map { String($0.prefix(intentLimit)) }
    }
}
