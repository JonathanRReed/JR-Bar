import Foundation

public struct ArchiveSource: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let root: URL
    public let extensions: Set<String>

    public init(id: String, name: String, root: URL, extensions: Set<String>) {
        self.id = id
        self.name = name
        self.root = root
        self.extensions = extensions
    }

    /// Source id for CLIProxyAPI's per-request logs
    /// (`~/.cli-proxy-api/logs`, `JRBAR_CLIPROXY_LOGS` override). Capture is
    /// off by default like every source — the id exists so settings and
    /// the capture list can name it.
    public static let cliProxyAPILogs = "cli-proxy-api-logs"

    public static func defaults(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ArchiveSource] {
        let codexHome = environment["CODEX_HOME"]
            .flatMap { overrideURL($0, home: home) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        let claudeHome = environment["CLAUDE_CONFIG_DIR"]
            .flatMap { overrideURL($0, home: home) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        let cliProxyLogs = environment["JRBAR_CLIPROXY_LOGS"]
            .flatMap { overrideURL($0, home: home) }
            ?? home.appendingPathComponent(".cli-proxy-api/logs", isDirectory: true)
        return [
            ArchiveSource(id: "codex-sessions", name: "Codex sessions",
                          root: codexHome.appendingPathComponent("sessions", isDirectory: true),
                          extensions: ["jsonl"]),
            ArchiveSource(id: "codex-archived-sessions", name: "Codex archived sessions",
                          root: codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
                          extensions: ["jsonl"]),
            ArchiveSource(id: "claude-projects", name: "Claude Code projects",
                          root: claudeHome.appendingPathComponent("projects", isDirectory: true),
                          extensions: ["jsonl"]),
            // The other agents on this Mac keep JSONL sessions too; they
            // archive and search like any file, filed as "other" until a
            // transcript reader exists for them.
            ArchiveSource(id: "pi-sessions", name: "pi sessions",
                          root: home.appendingPathComponent(".pi/agent/sessions", isDirectory: true),
                          extensions: ["jsonl"]),
            ArchiveSource(id: "gemini-chats", name: "Gemini CLI chats",
                          root: home.appendingPathComponent(".gemini/tmp", isDirectory: true),
                          extensions: ["jsonl"]),
            ArchiveSource(id: "grok-sessions", name: "Grok sessions",
                          root: home.appendingPathComponent(".grok/sessions", isDirectory: true),
                          extensions: ["jsonl"]),
            ArchiveSource(id: ArchiveSource.cliProxyAPILogs, name: "CLIProxyAPI logs",
                          root: cliProxyLogs, extensions: ["log"]),
        ]
    }

    private static func overrideURL(_ path: String, home: URL) -> URL? {
        guard !path.isEmpty else { return nil }
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

public struct ArchiveSourceFile: Sendable, Identifiable {
    public let url: URL
    public let byteCount: Int64
    public let modifiedAt: Date?
    public var id: URL { url }

    public init(url: URL, byteCount: Int64, modifiedAt: Date?) {
        self.url = url
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct ArchiveSourceInventory: Sendable, Identifiable {
    public let source: ArchiveSource
    public let files: [ArchiveSourceFile]
    public let warnings: [String]
    public var id: String { source.id }
    public var totalBytes: Int64 {
        files.reduce(into: 0) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.byteCount)
            total = overflow ? Int64.max : sum
        }
    }
    public var earliestModifiedAt: Date? { files.compactMap(\.modifiedAt).min() }
    public var latestModifiedAt: Date? { files.compactMap(\.modifiedAt).max() }

    public init(source: ArchiveSource, files: [ArchiveSourceFile], warnings: [String]) {
        self.source = source
        self.files = files
        self.warnings = warnings
    }
}

/// Discovers transcript metadata without opening file contents.
/// `maximumVisitedEntries` bounds filesystem work and `maximumFiles` bounds
/// retained metadata per source. An inventory warning marks either truncation.
public actor DataHoarderSourceScanner {
    private let maximumVisitedEntries: Int
    private let maximumFiles: Int
    private let fileManager: FileManager

    public init(maximumVisitedEntries: Int = 100_000, maximumFiles: Int = 20_000) {
        self.maximumVisitedEntries = max(1, maximumVisitedEntries)
        self.maximumFiles = max(1, maximumFiles)
        fileManager = .default
    }

    public func scan(_ sources: [ArchiveSource]) throws -> [ArchiveSourceInventory] {
        try sources.map { try scan($0) }
    }

    private func scan(_ source: ArchiveSource) throws -> ArchiveSourceInventory {
        try Task.checkCancellation()
        let rootValues: URLResourceValues
        do {
            rootValues = try source.root.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey,
            ])
        } catch {
            let message = fileManager.fileExists(atPath: source.root.path)
                ? "Could not read source: \(source.root.path)"
                : "Source folder is missing: \(source.root.path)"
            return ArchiveSourceInventory(source: source, files: [], warnings: [message])
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              rootValues.isHidden != true, rootValues.isPackage != true else {
            return ArchiveSourceInventory(
                source: source, files: [],
                warnings: ["Source is not a readable folder: \(source.root.path)"])
        }

        var files: [ArchiveSourceFile] = []
        var warnings: [String] = []
        var visited = 0
        var reachedVisitLimit = false
        var reachedFileLimit = false
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
            .isPackageKey, .fileSizeKey, .contentModificationDateKey,
        ]

        let enumerator = fileManager.enumerator(
            at: source.root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                warnings.append("Could not read folder: \(url.path)")
                return true
            })
        guard let enumerator else {
            return ArchiveSourceInventory(
                source: source, files: [],
                warnings: ["Could not read source: \(source.root.path)"])
        }
        while let child = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if visited >= maximumVisitedEntries {
                reachedVisitLimit = true
                break
            }
            visited += 1
            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: keys)
            } catch {
                warnings.append("Could not read metadata: \(child.path)")
                enumerator.skipDescendants()
                continue
            }
            if values.isHidden == true || values.isSymbolicLink == true || values.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  source.extensions.contains(child.pathExtension) else { continue }
            if files.count >= maximumFiles {
                reachedFileLimit = true
                break
            }
            files.append(ArchiveSourceFile(
                url: child,
                byteCount: Int64(max(0, values.fileSize ?? 0)),
                modifiedAt: values.contentModificationDate))
        }
        if reachedVisitLimit {
            warnings.append("Partial results: stopped after \(maximumVisitedEntries) filesystem entries.")
        }
        if reachedFileLimit {
            warnings.append("Partial results: stopped after \(maximumFiles) matching files.")
        }
        files.sort {
            switch ($0.modifiedAt, $1.modifiedAt) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.url.path < $1.url.path
            }
        }
        return ArchiveSourceInventory(source: source, files: files, warnings: warnings)
    }
}
