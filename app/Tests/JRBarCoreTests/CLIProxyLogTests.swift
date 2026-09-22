import Foundation
import Testing
@testable import JRBarCore

/// CLIProxyAPI per-request log ingestion: the section parser, the
/// consent redactor, the probe/redact dispatch, source discovery, and
/// end-to-end capture. Fixtures are synthetic — built to the documented
/// `=== SECTION ===` format, never copied from real logs.
@Suite("CLIProxyAPI logs")
struct CLIProxyLogTests {

    /// A two-attempt error log in the real on-disk shape.
    static func fixture(
        session: String = "11111111-2222-3333-4444-555555555555",
        status: Int = 503
    ) -> String {
        """
        === REQUEST INFO ===
        Version: 7.2.75
        URL: /v1/messages?beta=true
        Method: POST
        Downstream Transport: http
        Upstream Transport: http
        Timestamp: 2026-08-05T19:42:58.421415-05:00

        === HEADERS ===
        User-Agent: claude-cli/2.1.222 (external, cli)
        X-Claude-Code-Session-Id: \(session)
        X-Api-Key: sk-fixture-secret-key-0000000000

        === REQUEST BODY ===
        {"model":"fixture-model-1","session_id":"body-session","messages":[{"role":"user","content":"synthetic prompt body"}]}

        === API REQUEST 1 ===
        Timestamp: 2026-08-05T19:42:58.501474-05:00
        Upstream URL: https://chatgpt.example.com/backend-api/codex/responses?trace=1
        HTTP Method: POST
        Auth: provider=codex, auth_id=fake-auth-file.json, type=oauth

        Headers:
        Authorization: Bearer fixture-secret-token-abcdef
        Session_id: upstream-session-id
        User-Agent: claude-cli/2.1.222 (external, cli)

        Body:
        {"model":"fixture-model-1","input":[]}

        === API RESPONSE ===
        Timestamp: 2026-08-05T19:42:59.166778-05:00
        {"type":"error","error":{"type":"api_error","message":"synthetic upstream failure"}}

        === API REQUEST 2 ===
        Timestamp: 2026-08-05T19:43:00.000000-05:00
        Upstream URL: https://other.example.com/v1/responses

        === RESPONSE ===
        Status: \(status)
        Content-Type: application/json

        {"type":"error","error":{"type":"api_error","message":"synthetic upstream failure"}}
        """
    }

    // MARK: Parser

    @Test("the parser reads request info, headers, body JSON, attempts, and the response")
    func parsesFullLog() throws {
        let data = Data(Self.fixture().utf8)
        #expect(CLIProxyLogParser.looksLikeCLIProxyLog(data))
        let request = try #require(CLIProxyLogParser.parse(data))
        #expect(request.method == "POST")
        #expect(request.path == "/v1/messages")               // query stripped
        #expect(request.client == "claude-cli/2.1.222")        // up to first space
        // The downstream session header wins over the body's session_id.
        #expect(request.sessionID == "11111111-2222-3333-4444-555555555555")
        #expect(request.model == "fixture-model-1")
        #expect(request.status == 503)
        // First attempt only, host+path with the query stripped.
        #expect(request.upstreamURL == "chatgpt.example.com/backend-api/codex/responses")
        #expect(request.attemptCount == 2)
        #expect(request.errorSummary == "HTTP 503: synthetic upstream failure")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = formatter.date(from: "2026-08-05T19:42:58.421415-05:00")
        #expect(request.timestamp != nil)
        if let stamp = request.timestamp, let expected {
            #expect(abs(stamp.timeIntervalSince1970 - expected.timeIntervalSince1970) < 0.001)
        }
    }

    @Test("missing sections leave nils; a non-log parses to nil")
    func missingSections() throws {
        let minimal = Data("""
        === REQUEST INFO ===
        Method: HEAD

        """.utf8)
        let request = try #require(CLIProxyLogParser.parse(minimal))
        #expect(request.method == "HEAD")
        #expect(request.status == nil && request.model == nil && request.sessionID == nil)
        #expect(request.attemptCount == 0 && request.errorSummary == nil)
        #expect(request.path == nil && request.upstreamURL == nil)

        #expect(CLIProxyLogParser.looksLikeCLIProxyLog(Data("plain text".utf8)) == false)
        #expect(CLIProxyLogParser.parse(Data(#"{"type":"user"}"#.utf8)) == nil)
    }

    @Test("a session id from the body alone is found; non-UTF8 tails don't crash")
    func bodySessionAndNonUTF8() throws {
        let text = """
        === REQUEST INFO ===
        Method: POST
        URL: /v1/responses

        === REQUEST BODY ===
        {"model":"m-9","chat_id":"chat-7"}
        """
        var data = Data(text.utf8)
        // Non-UTF8 tail on its own trailing line — the body JSON stays clean.
        data.append(0x0A)
        data.append(contentsOf: [0xFF, 0xFE, 0x80])
        let request = try #require(CLIProxyLogParser.parse(data))
        #expect(request.sessionID == "chat-7" && request.model == "m-9")
    }

    // MARK: Redactor

    @Test("redaction keeps the skeleton, masks credential values, and drops bodies")
    func redaction() throws {
        let secrets = [
            "sk-fixture-secret-key-0000000000",
            "fixture-secret-token-abcdef",
            "fake-auth-file.json",
            "synthetic prompt body",
            "synthetic upstream failure",
            "fixture-model-1",
        ]
        let redacted = CLIProxyRedactor.redact(Data(Self.fixture().utf8))
        let text = String(decoding: redacted, as: UTF8.self)
        for secret in secrets {
            #expect(!text.contains(secret), "leaked: \(secret)")
        }
        // Skeleton and header names survive.
        #expect(text.contains("=== REQUEST INFO ==="))
        #expect(text.contains("=== HEADERS ==="))
        #expect(text.contains("=== API REQUEST 1 ==="))
        #expect(text.contains("=== RESPONSE ==="))
        #expect(text.contains("User-Agent: claude-cli/2.1.222 (external, cli)"))
        #expect(text.contains("X-Api-Key: [masked]"))
        #expect(text.contains("Authorization: [masked]"))
        #expect(text.contains("Auth: [masked]"))
        // The session id is metadata (kept like transcript sessionId).
        #expect(text.contains("X-Claude-Code-Session-Id: 11111111-2222-3333-4444-555555555555"))
        #expect(text.contains("Status: 503"))
        #expect(text.contains("URL: /v1/messages"))           // query stripped
        #expect(text.contains("[redacted "))
        // The redacted copy still parses as a log.
        #expect(CLIProxyLogParser.looksLikeCLIProxyLog(redacted))
        let parsed = try #require(CLIProxyLogParser.parse(redacted))
        #expect(parsed.status == 503 && parsed.method == "POST")
    }

    @Test("a marker-shaped line inside a body cannot end its own redaction")
    func markerSpoofInsideBody() throws {
        // Bodies are upstream-controlled text: a pasted === NOTES === must
        // stay inside the redacted region, not reopen the verbatim path.
        let text = """
        === REQUEST INFO ===
        Method: POST
        URL: /v1/messages

        === REQUEST BODY ===
        {"prompt":"secret"}
        === NOTES ===
        Prompt: sk-body-leak
        key: value
        === RESPONSE ===
        Status: 200
        """
        let redacted = CLIProxyRedactor.redact(Data(text.utf8))
        let out = String(decoding: redacted, as: UTF8.self)
        #expect(!out.contains("sk-body-leak"))
        #expect(!out.contains("=== NOTES ==="))
        #expect(!out.contains("Prompt:"))
        // A known marker still ends the region — the skeleton survives.
        #expect(out.contains("=== RESPONSE ==="))
        #expect(out.contains("Status: 200"))
    }

    @Test("TranscriptRedactor dispatches section-marked logs to the cliproxy redactor")
    func transcriptRedactorDispatch() {
        let redacted = TranscriptRedactor.redact(Data(Self.fixture().utf8))
        let text = String(decoding: redacted, as: UTF8.self)
        #expect(text.contains("=== REQUEST INFO ==="))
        #expect(!text.contains("synthetic prompt body"))
        // JSONL content still takes the row redactor.
        let jsonl = TranscriptRedactor.redact(Data(
            #"{"type":"user","message":{"role":"user","content":"secret prompt"}}"#.utf8))
        #expect(String(decoding: jsonl, as: UTF8.self).contains("[redacted 13 chars]"))
    }

    @Test("the probe reads cliproxy request metadata, title included")
    func probeIngest() {
        var metadata = TranscriptMetadata()
        let lines = Self.fixture().split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        TranscriptProbe.ingest(lines: lines, into: &metadata, includeTitle: true)
        #expect(metadata.provider == "cliproxy")
        #expect(metadata.sessionID == "11111111-2222-3333-4444-555555555555")
        #expect(metadata.model == "fixture-model-1")
        #expect(metadata.project == "claude-cli/2.1.222")
        #expect(metadata.title == "POST /v1/messages → 503")
        #expect(metadata.startedAt != nil && metadata.lastActivityAt != nil)
    }

    // MARK: Source discovery

    @Test("the cliproxy source lists *.log metadata-only")
    func sourceDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-cliproxy-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("log".utf8).write(to: root.appendingPathComponent("a.log"))
        try Data("not".utf8).write(to: root.appendingPathComponent("b.txt"))
        try Data("other".utf8).write(to: root.appendingPathComponent("c.jsonl"))
        let source = ArchiveSource(
            id: ArchiveSource.cliProxyAPILogs, name: "CLIProxyAPI logs",
            root: root, extensions: ["log"])
        let inventory = try #require(try await DataHoarderSourceScanner().scan([source]).first)
        #expect(inventory.files.map(\.url.lastPathComponent) == ["a.log"])
        #expect(inventory.warnings.isEmpty)
        // The default root honors JRBAR_CLIPROXY_LOGS.
        let defaults = ArchiveSource.defaults(
            home: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            environment: ["JRBAR_CLIPROXY_LOGS": "~/proxied"])
        let proxy = try #require(defaults.last)
        #expect(proxy.id == ArchiveSource.cliProxyAPILogs)
        #expect(proxy.root.path == "/Users/example/proxied")
    }

    // MARK: Capture

    private struct Fixture {
        let root: URL
        let archive: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("jrbar-cliproxy-\(UUID().uuidString)", isDirectory: true)
            archive = root.appendingPathComponent("archive", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func source(_ name: String, extensions: Set<String>) throws -> ArchiveSource {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return ArchiveSource(id: name, name: name, root: dir, extensions: extensions)
        }

        func file(_ name: String, in directory: String, data: Data) throws -> URL {
            let url = root.appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(name)
            try data.write(to: url)
            return URL(fileURLWithPath: DataHoarderArchive.canonicalPath(url.path))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("a captured log becomes one segment with cliproxy metadata and a status title")
    func captureLog() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source("logs", extensions: ["log"])
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)
        await capture.start(sources: [source], fullContent: true)
        try await Task.sleep(for: .milliseconds(50))
        _ = try fixture.file("error-v1-messages.log", in: "logs", data: Data(Self.fixture().utf8))
        await capture.rescan(source: source)

        let record = try #require(try await archive.records().first)
        #expect(record.provider == "cliproxy")
        #expect(record.title == "POST /v1/messages → 503")
        #expect(record.sessionID == "11111111-2222-3333-4444-555555555555")
        #expect(record.project == "claude-cli/2.1.222")
        #expect(record.model == "fixture-model-1")
        // Immutable .log file: one whole-file segment, no partial-line carry.
        #expect(record.segmentCount == 1)
        #expect(try await archive.preview(id: record.id) == Self.fixture())

        // A second pass adds nothing.
        await capture.rescan(source: source)
        let again = try #require(try await archive.record(id: record.id))
        #expect(again.segmentCount == 1)
        #expect(try await archive.captureFailureCount() == 0)
        await capture.stop()
    }

    @Test("metadata-only consent stores the masked skeleton but still learns request metadata")
    func captureLogRedacted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.source("logs", extensions: ["log"])
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)
        await capture.start(sources: [source], fullContent: false)
        try await Task.sleep(for: .milliseconds(50))
        _ = try fixture.file("error.log", in: "logs", data: Data(Self.fixture().utf8))
        await capture.rescan(source: source)

        let record = try #require(try await archive.records().first)
        // The probe read the original bytes; the stored copy is masked.
        #expect(record.provider == "cliproxy" && record.title == "POST /v1/messages → 503")
        #expect(record.sessionID == "11111111-2222-3333-4444-555555555555")
        let stored = try await archive.preview(id: record.id)
        #expect(!stored.contains("sk-fixture-secret-key-0000000000"))
        #expect(!stored.contains("fixture-secret-token-abcdef"))
        #expect(!stored.contains("synthetic prompt body"))
        #expect(stored.contains("X-Api-Key: [masked]"))
        #expect(stored.contains("=== REQUEST INFO ==="))
        #expect(stored.contains("[redacted "))
        await capture.stop()
    }

    @Test("a transcript and a proxy log sharing a session id link through relatedRecords")
    func relatedRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sessions = try fixture.source("sessions", extensions: ["jsonl"])
        let logs = try fixture.source("logs", extensions: ["log"])
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)
        await capture.start(sources: [sessions, logs], fullContent: true)
        try await Task.sleep(for: .milliseconds(50))
        let session = "11111111-2222-3333-4444-555555555555"
        let transcript = #"{"type":"user","sessionId":"\#(session)","timestamp":"2026-09-19T10:00:00Z","message":{"role":"user","content":"hello"}}"# + "\n"
        _ = try fixture.file("session.jsonl", in: "sessions", data: Data(transcript.utf8))
        _ = try fixture.file("error.log", in: "logs", data: Data(Self.fixture(session: session).utf8))
        await capture.rescan(source: sessions)
        await capture.rescan(source: logs)

        let records = try await archive.records()
        #expect(records.count == 2)
        let related = try await archive.relatedRecords(sessionID: session)
        #expect(Set(related.map(\.id)) == Set(records.map(\.id)))
        let transcriptRecord = try #require(records.first { $0.provider == "claude" })
        let proxyRecord = try #require(records.first { $0.provider == "cliproxy" })
        #expect(try await archive.relatedRecords(sessionID: session, excluding: transcriptRecord.id)
            .map(\.id) == [proxyRecord.id])

        // Reconstruction runs on the transcript's stored segments.
        let rebuilt = SessionReconstructor.reconstruct(
            segments: try await archive.segmentData(id: transcriptRecord.id),
            provider: transcriptRecord.provider ?? "other")
        #expect(rebuilt.items.first?.kind == .message)
        #expect(rebuilt.items.first?.text == "hello")
        await capture.stop()
    }

    @Test("scale smoke: 300 transcripts + 50 logs capture incrementally and stay searchable")
    func scaleSmoke() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sessions = try fixture.source("sessions", extensions: ["jsonl"])
        let logs = try fixture.source("logs", extensions: ["log"])
        let archive = DataHoarderArchive(root: fixture.archive)
        let capture = DataHoarderCapture(archive: archive)
        await capture.start(sources: [sessions, logs], fullContent: true)
        try await Task.sleep(for: .milliseconds(50))

        for index in 0..<300 {
            let token = index == 42 ? "uniquetoken42" : "work"
            let line = #"{"type":"user","sessionId":"sess-\#(index)","timestamp":"2026-09-19T10:00:00Z","message":{"role":"user","content":"\#(token) payload"}}"# + "\n"
            _ = try fixture.file("s\(index).jsonl", in: "sessions", data: Data(line.utf8))
        }
        for index in 0..<50 {
            _ = try fixture.file("e\(index).log", in: "logs",
                                 data: Data(Self.fixture(session: "sess-\(index)").utf8))
        }
        await capture.rescan(source: sessions)
        await capture.rescan(source: logs)

        let records = try await archive.records()
        #expect(records.count == 350)
        #expect(records.allSatisfy { $0.segmentCount == 1 })
        #expect(try await archive.captureFailureCount() == 0)

        // Incremental: a second pass stores zero new segments.
        await capture.rescan(source: sessions)
        await capture.rescan(source: logs)
        let after = try await archive.records()
        #expect(after.allSatisfy { $0.segmentCount == 1 })

        // FTS finds the one transcript carrying the unique token.
        let hits = try await archive.search(query: "uniquetoken42")
        #expect(hits.count == 1)
        #expect(hits.first?.record.sessionID == "sess-42")
        await capture.stop()
    }
}
