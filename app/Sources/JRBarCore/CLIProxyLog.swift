import Foundation

/// One parsed CLIProxyAPI per-request log (`~/.cli-proxy-api/logs/*.log`).
/// Every field is whatever the log itself declared — a missing section
/// leaves the field nil rather than fabricating a value.
public struct CLIProxyRequest: Sendable, Equatable {
    public let timestamp: Date?
    public let method: String?
    public let path: String?         // URL line, query stripped
    public let client: String?       // from User-Agent, e.g. "claude-cli/2.1.222"
    public let sessionID: String?    // X-Claude-Code-Session-Id, X-Session-Id, or body session_id/chat_id
    public let model: String?        // request body JSON "model"
    public let status: Int?          // RESPONSE Status
    public let upstreamURL: String?  // first API REQUEST's Upstream URL (host+path only)
    public let attemptCount: Int
    public let errorSummary: String? // status>=400 → "HTTP <status>" + bounded response error text

    public init(timestamp: Date? = nil, method: String? = nil,
                path: String? = nil, client: String? = nil,
                sessionID: String? = nil, model: String? = nil,
                status: Int? = nil, upstreamURL: String? = nil,
                attemptCount: Int = 0, errorSummary: String? = nil) {
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.client = client
        self.sessionID = sessionID
        self.model = model
        self.status = status
        self.upstreamURL = upstreamURL
        self.attemptCount = attemptCount
        self.errorSummary = errorSummary
    }
}

/// Reads CLIProxyAPI's section-marked request logs:
///
///     === REQUEST INFO ===        Version / URL / Method / Timestamp
///     === HEADERS ===             downstream request headers
///     === REQUEST BODY ===        downstream JSON body
///     === API REQUEST N ===       upstream attempt: Upstream URL,
///                                 HTTP Method, Auth, Headers:, Body:
///     === API RESPONSE ===        upstream attempt result
///     === RESPONSE ===            Status + downstream response headers/body
///
/// Sections are found by a line scan — never a whole-file regex — so a
/// multi-megabyte body or a non-UTF8 tail costs one linear pass.
public enum CLIProxyLogParser {
    static let requestInfoMarker = "=== REQUEST INFO ==="

    public static func looksLikeCLIProxyLog(_ data: Data) -> Bool {
        data.range(of: Data(requestInfoMarker.utf8)) != nil
    }

    /// One physical line: byte range (newline excluded), whether it was
    /// newline-terminated, and a lossy decode for inspection. Kept lines
    /// are re-emitted from their original bytes — non-UTF8 tails survive.
    struct Line {
        let range: Range<Int>
        let terminated: Bool
        let text: String
    }

    static func lines(in data: Data) -> [Line] {
        var lines: [Line] = []
        var start = 0
        for index in 0..<data.count where data[index] == 0x0A {
            lines.append(Line(range: start..<index, terminated: true,
                              text: String(decoding: data[start..<index], as: UTF8.self)))
            start = index + 1
        }
        if start < data.count {
            lines.append(Line(range: start..<data.count, terminated: false,
                              text: String(decoding: data[start..<data.count], as: UTF8.self)))
        }
        return lines
    }

    /// `=== NAME ===` → `NAME`, or nil for content lines.
    static func sectionName(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("=== "), trimmedLine.hasSuffix(" ==="),
              trimmedLine.count > 8 else { return nil }
        let name = trimmedLine.dropFirst(4).dropLast(4)
        return name.isEmpty ? nil : String(name)
    }

    /// A marker line only counts as a real section boundary when its name
    /// is one the logger writes. Bodies are upstream-controlled text — a
    /// pasted `=== NOTES ===` inside one must not end a redacted region
    /// and reopen the verbatim path.
    static func knownSectionName(_ trimmedLine: String) -> String? {
        guard let name = sectionName(trimmedLine) else { return nil }
        let upper = name.uppercased()
        if ["REQUEST INFO", "HEADERS", "REQUEST BODY", "RESPONSE"]
            .contains(upper) { return name }
        if upper.hasPrefix("API REQUEST") || upper.hasPrefix("API RESPONSE") {
            return name
        }
        return nil
    }

    /// `Name: value` where `Name` is a word of letters, digits, dashes,
    /// underscores and inner spaces — CLIProxy writes `Upstream URL:`,
    /// `HTTP Method:` and `Downstream Transport:` beside HTTP headers.
    /// Body lines starting with `{`, quotes or punctuation fail the name
    /// test on purpose; a header-shaped *body* line can only be excluded
    /// by position (blank line / `Body:` marker), which the callers enforce.
    static func headerPair(_ text: String) -> (name: String, value: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = text[text.startIndex..<colon]
        guard let first = name.first,
              first.isASCII && (first.isLetter || first.isNumber),
              name.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-"
                                 || $0 == "_" || $0 == " ")
              }) else { return nil }
        let value = text[text.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        return (String(name).trimmingCharacters(in: .whitespaces), value)
    }

    /// Sections in order; preamble lines (before the first marker) carry
    /// a nil name.
    static func sections(in data: Data) -> [(name: String?, lines: [Line])] {
        var result: [(name: String?, lines: [Line])] = []
        var name: String? = nil
        var lines: [Line] = []
        for line in Self.lines(in: data) {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if let marker = sectionName(trimmed) {
                result.append((name, lines))
                name = marker
                lines = []
            } else {
                lines.append(line)
            }
        }
        result.append((name, lines))
        return result
    }

    /// Lowercased `name:` → `value` for a section's `Key: value` lines;
    /// first occurrence wins.
    static func keyValues(_ lines: [Line]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            guard let pair = headerPair(line.text),
                  result[pair.name.lowercased()] == nil else { continue }
            result[pair.name.lowercased()] = pair.value
        }
        return result
    }

    /// Host+path only: scheme, credentials, query and fragment stripped.
    static func sanitizeURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let scheme = value.range(of: "://") {
            value = String(value[scheme.upperBound...])
        }
        if let at = value.firstIndex(of: "@") {
            let slash = value.firstIndex(of: "/") ?? value.endIndex
            if at < slash { value = String(value[value.index(after: at)...]) }
        }
        if let cut = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[value.startIndex..<cut])
        }
        return value
    }

    static func jsonObject(_ lines: [Line]) -> [String: Any]? {
        var text = lines.map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"),
              let close = text.lastIndex(of: "}") else { return nil }
        // A damaged or non-UTF8 tail after the closing brace must not
        // invalidate an otherwise readable body.
        text = String(text[...close])
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any] else { return nil }
        return object
    }

    public static func parse(_ data: Data) -> CLIProxyRequest? {
        guard looksLikeCLIProxyLog(data) else { return nil }
        var info: [String: String] = [:]
        var headers: [String: String] = [:]
        var upstreamHeaders: [String: String] = [:]
        var upstreamURL: String?
        var requestBody: [String: Any]?
        var upstreamBody: [String: Any]?
        var status: Int?
        var responseBody: [String] = []
        var attempts = 0

        for section in sections(in: data) {
            guard let name = section.name else { continue }
            let upper = name.uppercased()
            if upper == "REQUEST INFO" {
                if info.isEmpty { info = keyValues(section.lines) }
            } else if upper == "HEADERS" {
                if headers.isEmpty { headers = keyValues(section.lines) }
            } else if upper.hasPrefix("REQUEST BODY") {
                if requestBody == nil { requestBody = jsonObject(section.lines) }
            } else if upper.hasPrefix("API REQUEST") {
                attempts += 1
                if upstreamURL == nil {
                    parseAttempt(section.lines,
                                 upstreamURL: &upstreamURL,
                                 headers: &upstreamHeaders,
                                 body: &upstreamBody)
                }
            } else if upper == "RESPONSE" {
                parseResponse(section.lines, status: &status, body: &responseBody)
            }
        }

        var sessionID = headers["x-claude-code-session-id"]
            ?? headers["x-session-id"]
            ?? upstreamHeaders["session_id"] ?? upstreamHeaders["session-id"]
            ?? upstreamHeaders["x-session-id"]
            ?? upstreamHeaders["chat_id"] ?? upstreamHeaders["chat-id"]
        if sessionID == nil {
            sessionID = requestBody?["session_id"] as? String
                ?? requestBody?["chat_id"] as? String
                ?? upstreamBody?["session_id"] as? String
                ?? upstreamBody?["chat_id"] as? String
        }
        let model = requestBody?["model"] as? String
            ?? upstreamBody?["model"] as? String
        let client = headers["user-agent"].flatMap { agent -> String? in
            let prefix = agent.prefix { $0 != " " && $0 != "(" }
                .trimmingCharacters(in: .whitespaces)
            return prefix.isEmpty ? nil : prefix
        }
        var errorSummary: String? = nil
        if let status, status >= 400 {
            errorSummary = "HTTP \(status)"
                + (responseErrorSummary(responseBody).map { ": \($0)" } ?? "")
        }
        return CLIProxyRequest(
            timestamp: info["timestamp"].flatMap(TranscriptProbe.timestamp),
            method: info["method"],
            path: info["url"].map(sanitizeURL),
            client: client,
            sessionID: sessionID,
            model: model,
            status: status,
            upstreamURL: upstreamURL,
            attemptCount: attempts,
            errorSummary: errorSummary)
    }

    /// An `=== API REQUEST N ===` attempt: info lines, then a `Headers:`
    /// block, then `Body:` content. Later attempts are counted, not parsed.
    private static func parseAttempt(
        _ lines: [Line], upstreamURL: inout String?,
        headers: inout [String: String], body: inout [String: Any]?
    ) {
        var pre: [String: String] = [:]
        var inHeaders = false
        var inBody = false
        var bodyLines: [Line] = []
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if inBody { bodyLines.append(line); continue }
            if trimmed == "Headers:" { inHeaders = true; continue }
            if trimmed == "Body:" { inBody = true; continue }
            guard let pair = headerPair(line.text) else { continue }
            let key = pair.name.lowercased()
            if inHeaders {
                if headers[key] == nil { headers[key] = pair.value }
            } else if pre[key] == nil {
                pre[key] = pair.value
            }
        }
        upstreamURL = pre["upstream url"].map(sanitizeURL)
        body = jsonObject(bodyLines)
    }

    /// `=== RESPONSE ===`: `Status:` plus headers until the first blank
    /// or non-header line — everything after is the response body.
    private static func parseResponse(
        _ lines: [Line], status: inout Int?, body: inout [String]
    ) {
        var inBody = false
        for line in lines {
            if inBody { body.append(line.text); continue }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { inBody = true; continue }
            if let pair = headerPair(line.text) {
                if pair.name.lowercased() == "status", status == nil {
                    status = Int(pair.value)
                }
            } else {
                inBody = true
                body.append(line.text)
            }
        }
    }

    /// The bounded error text for an `HTTP <status>` summary — the
    /// response body's `error.message`/`error`/`message` when it is JSON,
    /// the flattened body text otherwise. ≤200 chars, one line.
    private static func responseErrorSummary(_ bodyLines: [String]) -> String? {
        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var detail: String? = nil
        if body.hasPrefix("{"),
           let object = try? JSONSerialization.jsonObject(with: Data(body.utf8))
                as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                detail = error["message"] as? String ?? error["type"] as? String
            } else {
                detail = object["error"] as? String ?? object["message"] as? String
            }
        }
        if detail == nil, !body.isEmpty { detail = body }
        guard let detail else { return nil }
        let flattened = detail.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }
        return String(flattened.prefix(200))
    }
}

/// The consent-gated copy of a CLIProxyAPI log: the section skeleton and
/// every header name survive, credential values are masked, and bodies —
/// the only places prompts and responses live — become
/// `[redacted N bytes]` markers. Kept lines are re-emitted from their
/// original bytes so nothing is silently rewritten.
public enum CLIProxyRedactor {
    /// Header-ish names whose values are credentials (lowercased compare).
    private static func isSensitiveName(_ lowercased: String) -> Bool {
        switch lowercased {
        case "authorization", "proxy-authorization", "cookie", "set-cookie",
             "x-api-key", "api-key", "apikey", "auth", "x-goog-api-key",
             "x-auth-token", "access-token", "refresh-token", "private-token":
            return true
        default:
            return lowercased.contains("api-key") || lowercased.contains("apikey")
                || lowercased.contains("token") || lowercased.contains("secret")
                || lowercased.contains("credential")
        }
    }

    public static func redact(_ data: Data) -> Data {
        guard CLIProxyLogParser.looksLikeCLIProxyLog(data) else { return data }
        let lines = CLIProxyLogParser.lines(in: data)
        // Marker positions delimit sections; redacted regions run to the
        // next marker (or EOF) so their byte counts stay honest.
        var out = Data()
        out.reserveCapacity(min(data.count, 256 * 1024))
        var section = ""
        var index = 0
        var redactFrom: Int? = nil
        func emit(_ line: CLIProxyLogParser.Line) {
            out.append(contentsOf: data[line.range])
            if line.terminated { out.append(0x0A) }
        }
        func emitMarker(byteCount: Int) {
            out.append(contentsOf: Data("[redacted \(byteCount) bytes]".utf8))
            out.append(0x0A)
        }
        // A body region runs to the next section marker (or EOF): record
        // where it starts, then skip every line the marker will replace.
        func redactRestOfSection(from start: Int) {
            redactFrom = start
            index += 1
            while index < lines.count,
                  CLIProxyLogParser.knownSectionName(
                    lines[index].text.trimmingCharacters(in: .whitespaces)) == nil {
                index += 1
            }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if let marker = CLIProxyLogParser.knownSectionName(trimmed) {
                if let redactFrom {
                    emitMarker(byteCount: line.range.lowerBound - redactFrom)
                }
                redactFrom = nil
                section = marker.uppercased()
                emit(line)
                index += 1
                continue
            }
            let upper = section
            if upper.hasPrefix("REQUEST BODY") {
                // Whole section is a body — one marker covers it.
                redactRestOfSection(from: line.range.lowerBound)
                continue
            }
            if trimmed.isEmpty {
                emit(line)
                index += 1
                // In response sections a blank line ends the headers — a
                // header-shaped body line still cannot leak past it.
                if upper == "RESPONSE" || upper.hasPrefix("API RESPONSE") {
                    redactFrom = index < lines.count
                        ? lines[index].range.lowerBound : data.count
                    while index < lines.count,
                          CLIProxyLogParser.knownSectionName(
                            lines[index].text.trimmingCharacters(in: .whitespaces)) == nil {
                        index += 1
                    }
                }
                continue
            }
            if upper.hasPrefix("API RESPONSE") {
                // Upstream attempt results keep only their own metadata —
                // everything else is response content.
                if let pair = CLIProxyLogParser.headerPair(line.text),
                   ["timestamp", "status"].contains(pair.name.lowercased()) {
                    emit(line)
                    index += 1
                } else {
                    redactRestOfSection(from: line.range.lowerBound)
                }
                continue
            }
            if upper.hasPrefix("API REQUEST"), trimmed == "Body:" {
                emit(line)
                index += 1
                redactFrom = index < lines.count
                    ? lines[index].range.lowerBound : data.count
                while index < lines.count,
                      CLIProxyLogParser.knownSectionName(
                        lines[index].text.trimmingCharacters(in: .whitespaces)) == nil {
                    index += 1
                }
                continue
            }
            guard let pair = CLIProxyLogParser.headerPair(line.text) else {
                // First non-header line — the body starts here.
                redactRestOfSection(from: line.range.lowerBound)
                continue
            }
            let lowerName = pair.name.lowercased()
            // SSE field names are never HTTP headers — a `data:`/`event:`
            // line in any section means the body has started, whether or
            // not a blank line announced it.
            if ["data", "event", "retry"].contains(lowerName) {
                redactRestOfSection(from: line.range.lowerBound)
                continue
            }
            if upper == "RESPONSE" {
                // The downstream response section keeps only transport
                // metadata; a header-shaped body line (SSE or otherwise)
                // cannot leak past the allowlist.
                if ["status", "content-type", "content-length", "date",
                    "x-request-id", "retry-after", "cf-ray", "server"].contains(lowerName) {
                    emit(line)
                    index += 1
                } else {
                    redactRestOfSection(from: line.range.lowerBound)
                }
                continue
            }
            if isSensitiveName(lowerName) {
                out.append(contentsOf: Data("\(pair.name): [masked]".utf8))
                if line.terminated { out.append(0x0A) }
            } else if lowerName == "url" || lowerName == "upstream url" {
                out.append(contentsOf: Data(
                    "\(pair.name): \(CLIProxyLogParser.sanitizeURL(pair.value))".utf8))
                if line.terminated { out.append(0x0A) }
            } else {
                emit(line)
            }
            index += 1
        }
        if let redactFrom {
            emitMarker(byteCount: data.count - redactFrom)
        }
        return out
    }
}
