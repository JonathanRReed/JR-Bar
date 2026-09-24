import AppKit
import JRBarCore

/// Who a record belongs to, as the archive's search and detail need it:
/// the provider picker built from the sources that capture (pi, Gemini
/// and Grok were only findable under "Other"), the command that picks a
/// session back up in a terminal, and the hand-off to Agent Sessions when
/// it is installed — the rival kept an option.
enum DataHoarderProviders {
    /// The providers the picker offers, in the sources' own order:
    /// Claude and Codex always (the probe names them in any imported
    /// file), each capturing source's agent, CLIProxyAPI when its logs
    /// are kept, and "other" last.
    static func choices(enabledSources: [String]) -> [String] {
        var providers = ["claude", "codex"]
        for source in ArchiveSource.defaults() where enabledSources.contains(source.id) {
            let provider = source.id == ArchiveSource.cliProxyAPILogs
                ? "cliproxy" : DataHoarderOffer.provider(of: source.id)
            if !providers.contains(provider) { providers.append(provider) }
        }
        return providers + ["other"]
    }

    /// A provider's name in the picker.
    static func title(_ provider: String) -> String {
        switch provider {
        case "other": return "Other"
        case "cliproxy": return "CLIProxyAPI"
        default: return ProviderStyle.style(for: provider).name
        }
    }

    // MARK: Resume

    /// The CLIs that pick an ended session back up by id — the daemon's
    /// own table (`session_actions.SESSION_TERMINAL_OPENERS`).
    static let resumeCommands: [String: [String]] = [
        "codex": ["codex", "resume"],
        "claude": ["claude", "--resume"],
        "devin": ["devin", "--resume"],
        "grok": ["grok", "--resume"],
        "cursor": ["cursor-agent", "--resume"],
        "hermes": ["hermes", "--resume"],
    ]

    /// The shell line that resumes a record's session: in its folder
    /// when the record names one ("cd '/Users/jr/JR-Bar' && claude
    /// --resume 5f1c…"), nil for a provider whose CLI cannot resume or a
    /// record with no session id.
    static func resumeCommand(provider: String?, sessionID: String?, project: String?) -> String? {
        guard let provider, let command = resumeCommands[provider],
              let sessionID, isSafeID(sessionID) else { return nil }
        let line = (command + [sessionID]).joined(separator: " ")
        guard let project, project.hasPrefix("/") else { return line }
        return "cd \(shellQuoted(project)) && \(line)"
    }

    /// The agent id the daemon's `resume_session` takes.
    static func agentID(provider: String, sessionID: String) -> String {
        "\(provider):session:\(sessionID)"
    }

    /// A session id is letters, digits, dashes and underscores — anything
    /// else is not pasted into a shell line.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Agent Sessions

    /// Agent Sessions (jazzyalex/agent-sessions): local search and resume
    /// across sixteen agents. Offered as a hand-off only when installed.
    static let agentSessions = ExternalAppProbe(
        bundleIDs: ["com.triada.AgentSessions", "com.jazzyalex.AgentSessions"],
        appNames: ["Agent Sessions.app", "AgentSessions.app"])
}

extension DataHoarderModel {
    /// The resume line for a record, when its CLI can resume.
    func resumeCommand(for record: ArchiveRecord) -> String? {
        DataHoarderProviders.resumeCommand(provider: record.provider, sessionID: record.sessionID,
                                           project: record.project)
    }

    /// Copy Resume Command: the line on the pasteboard, to paste into
    /// any terminal. Nothing is typed anywhere.
    func copyResumeCommand(_ record: ArchiveRecord, to board: NSPasteboard = .general) {
        guard let line = resumeCommand(for: record) else { return }
        board.clearContents()
        board.setString(line, forType: .string)
        message = "Copied: \(line)"
    }

    /// Resume: the daemon's `resume_session` picks the session back up
    /// in the terminal it ran in (or raises it, still running). Its
    /// refusal is the line under the header.
    func resume(_ record: ArchiveRecord) {
        guard let provider = record.provider, let session = record.sessionID,
              resumeCommand(for: record) != nil else { return }
        guard let send = Self.resumeSender else {
            message = "The monitor is not answering — Copy Resume Command instead."
            return
        }
        let id = DataHoarderProviders.agentID(provider: provider, sessionID: session)
        let title = record.title ?? record.name
        Task { [weak self] in
            do {
                let reply = try await send(id)
                self?.message = reply.ok
                    ? HistoryStore.resumedText(reply.result, title: title)
                    : reply.error?.message ?? "Could not resume \(title)"
            } catch {
                self?.message = "The monitor is not answering — Copy Resume Command instead."
            }
        }
    }

    /// Open in Agent Sessions — its own window, for its own search.
    func openInAgentSessions() {
        DataHoarderProviders.agentSessions.open()
    }

    /// The daemon's `resume_session`, published by the app delegate; nil
    /// in tests and before the core is up.
    @MainActor static var resumeSender: ((String) async throws -> CoreReply)?

    /// Records captured before their source's provider was stamped read
    /// as "other"; the folder they came from says whose they are, so the
    /// picker's pi, Gemini and Grok find them too. One pass, cheap: a
    /// catalog read and one update per record it fixes.
    func relabelSourceRecords(sources: [ArchiveSource] = ArchiveSource.defaults()) async {
        guard enabled else { return }
        let named = sources.compactMap { source in
            ArchiveSource.namedProvider(of: source.id).map { (root: source.root.standardizedFileURL.path, provider: $0) }
        }
        guard !named.isEmpty,
              let records = try? await archive.records(query: "", inTrash: false) else { return }
        var fixed = 0
        for record in records where record.provider == nil || record.provider == "other" {
            let path = URL(fileURLWithPath: record.sourcePath).standardizedFileURL.path
            guard let match = named.first(where: { path.hasPrefix($0.root + "/") }) else { continue }
            if (try? await archive.updateRecordMetadata(id: record.id, provider: match.provider)) != nil {
                fixed += 1
            }
        }
        if fixed > 0 { await reload() }
    }
}
