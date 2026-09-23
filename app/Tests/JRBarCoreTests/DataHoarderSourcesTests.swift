import Foundation
import Testing
@testable import JRBarCore

@Suite("Data Hoarder source discovery")
struct DataHoarderSourcesTests {
    @Test("default roots honor provider home overrides")
    func defaultRoots() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let sources = ArchiveSource.defaults(
            home: home,
            environment: ["CODEX_HOME": "/tmp/codex-home", "CLAUDE_CONFIG_DIR": "/tmp/claude-home",
                          "JRBAR_CLIPROXY_LOGS": "/tmp/proxy-logs"])

        #expect(sources.map(\.id) == [
            "codex-sessions", "codex-archived-sessions", "claude-projects",
            "pi-sessions", "gemini-chats", "grok-sessions",
            ArchiveSource.cliProxyAPILogs,
        ])
        #expect(sources.map(\.root.path) == [
            "/tmp/codex-home/sessions", "/tmp/codex-home/archived_sessions",
            "/tmp/claude-home/projects",
            "/Users/example/.pi/agent/sessions", "/Users/example/.gemini/tmp", "/Users/example/.grok/sessions",
            "/tmp/proxy-logs",
        ])
        #expect(sources.dropLast().allSatisfy { $0.extensions == ["jsonl"] })
        #expect(sources.last?.extensions == ["log"])

        let fallback = ArchiveSource.defaults(home: home, environment: [:])
        #expect(fallback.map(\.root.path) == [
            "/Users/example/.codex/sessions", "/Users/example/.codex/archived_sessions",
            "/Users/example/.claude/projects",
            "/Users/example/.pi/agent/sessions", "/Users/example/.gemini/tmp", "/Users/example/.grok/sessions",
            "/Users/example/.cli-proxy-api/logs",
        ])

        let tilde = ArchiveSource.defaults(
            home: home,
            environment: ["CODEX_HOME": "~/.alternate-codex", "CLAUDE_CONFIG_DIR": "~/.alternate-claude"])
        #expect(tilde.map(\.root.path) == [
            "/Users/example/.alternate-codex/sessions",
            "/Users/example/.alternate-codex/archived_sessions",
            "/Users/example/.alternate-claude/projects",
            "/Users/example/.pi/agent/sessions", "/Users/example/.gemini/tmp", "/Users/example/.grok/sessions",
            "/Users/example/.cli-proxy-api/logs",
        ])
    }

    @Test("scanner reads metadata for selected extensions and nested folders")
    func metadataAndExtensions() async throws {
        let fixture = try SourceFixture()
        defer { fixture.remove() }
        let nested = try fixture.directory("nested")
        let older = try fixture.file("older.jsonl", in: fixture.root, bytes: Data("old".utf8))
        let newer = try fixture.file("newer.trace", in: nested, bytes: Data("new trace".utf8))
        _ = try fixture.file("ignored.txt", in: nested, bytes: Data("ignore".utf8))
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = Date(timeIntervalSince1970: 2_000)
        try fixture.modified(oldDate, at: older)
        try fixture.modified(newDate, at: newer)
        let source = ArchiveSource(id: "selected", name: "Selected", root: fixture.root,
                                   extensions: ["jsonl", "trace"])

        let inventory = try #require(try await DataHoarderSourceScanner().scan([source]).first)
        #expect(inventory.id == "selected")
        #expect(inventory.files.map(\.url.lastPathComponent) == ["newer.trace", "older.jsonl"])
        #expect(inventory.files.map(\.byteCount) == [9, 3])
        #expect(inventory.totalBytes == 12)
        #expect(inventory.earliestModifiedAt == oldDate)
        #expect(inventory.latestModifiedAt == newDate)
        #expect(inventory.warnings.isEmpty)
    }

    @Test("scanner skips hidden entries, packages, and symlink subtrees")
    func exclusions() async throws {
        let fixture = try SourceFixture()
        defer { fixture.remove() }
        let scanRoot = try fixture.directory("scan")
        _ = try fixture.file("visible.jsonl", in: scanRoot, bytes: Data("ok".utf8))
        _ = try fixture.file(".hidden.jsonl", in: scanRoot, bytes: Data("hidden".utf8))
        let hiddenFolder = scanRoot.appendingPathComponent(".hidden-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: false)
        _ = try fixture.file("inside.jsonl", in: hiddenFolder, bytes: Data("hidden".utf8))
        let package = scanRoot.appendingPathComponent("Trace.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        _ = try fixture.file("package.jsonl", in: package, bytes: Data("package".utf8))
        let outside = try fixture.directory("outside")
        _ = try fixture.file("linked.jsonl", in: outside, bytes: Data("linked".utf8))
        try FileManager.default.createSymbolicLink(
            at: scanRoot.appendingPathComponent("linked-folder"), withDestinationURL: outside)
        let source = ArchiveSource(id: "source", name: "Source", root: scanRoot,
                                   extensions: ["jsonl"])

        let inventory = try #require(try await DataHoarderSourceScanner().scan([source]).first)
        #expect(inventory.files.map(\.url.lastPathComponent) == ["visible.jsonl"])
    }

    @Test("missing and unreadable roots return clear warnings")
    func rootWarnings() async throws {
        let fixture = try SourceFixture()
        defer { fixture.remove() }
        let missing = ArchiveSource(id: "missing", name: "Missing",
                                    root: fixture.root.appendingPathComponent("gone"),
                                    extensions: ["jsonl"])
        let fileRoot = try fixture.file("not-a-folder", in: fixture.root, bytes: Data())
        let unreadable = ArchiveSource(id: "unreadable", name: "Unreadable", root: fileRoot,
                                       extensions: ["jsonl"])

        let inventories = try await DataHoarderSourceScanner().scan([missing, unreadable])
        #expect(inventories[0].files.isEmpty)
        #expect(inventories[0].warnings == ["Source folder is missing: \(missing.root.path)"])
        #expect(inventories[1].files.isEmpty)
        #expect(inventories[1].warnings == ["Source is not a readable folder: \(fileRoot.path)"])
    }

    @Test("scanner lists unreadable regular files without opening them")
    func unreadableFileMetadata() async throws {
        let fixture = try SourceFixture()
        defer { fixture.remove() }
        let file = try fixture.file("private.jsonl", in: fixture.root, bytes: Data("secret".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let source = ArchiveSource(id: "metadata", name: "Metadata", root: fixture.root,
                                   extensions: ["jsonl"])

        let inventory = try #require(try await DataHoarderSourceScanner().scan([source]).first)
        #expect(inventory.files.count == 1)
        #expect(inventory.files[0].url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(inventory.files[0].byteCount == 6)
        #expect(inventory.warnings.isEmpty)
    }

    @Test("visited-entry and file caps produce partial-result warnings")
    func boundedScans() async throws {
        let fixture = try SourceFixture()
        defer { fixture.remove() }
        for index in 0..<6 {
            _ = try fixture.file("\(index).jsonl", in: fixture.root, bytes: Data([UInt8(index)]))
        }
        let source = ArchiveSource(id: "bounded", name: "Bounded", root: fixture.root,
                                   extensions: ["jsonl"])

        let fileLimited = try #require(try await DataHoarderSourceScanner(
            maximumVisitedEntries: 100, maximumFiles: 2).scan([source]).first)
        #expect(fileLimited.files.count == 2)
        #expect(fileLimited.warnings == ["Partial results: stopped after 2 matching files."])

        let visitLimited = try #require(try await DataHoarderSourceScanner(
            maximumVisitedEntries: 3, maximumFiles: 100).scan([source]).first)
        #expect(visitLimited.files.count == 3)
        #expect(visitLimited.warnings == ["Partial results: stopped after 3 filesystem entries."])
    }
}

private struct SourceFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func file(_ name: String, in directory: URL, bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func modified(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
