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
    /// are kept, then any agent the archive already holds records of —
    /// a pi file brought in by Find History while pi's capture is off
    /// still gets its name — and the pick in force, so a saved filter
    /// whose source was switched off keeps its row. "other" is last.
    static func choices(enabledSources: [String], archived: [String?] = [],
                        selected: String? = nil) -> [String] {
        var providers = ["claude", "codex"]
        for source in ArchiveSource.defaults() where enabledSources.contains(source.id) {
            let provider = source.id == ArchiveSource.cliProxyAPILogs
                ? "cliproxy" : DataHoarderOffer.provider(of: source.id)
            if !providers.contains(provider) { providers.append(provider) }
        }
        let held = Set((archived + [selected]).compactMap { $0 }.filter { !$0.isEmpty && $0 != "other" })
        let more = held.subtracting(providers).sorted { title($0) < title($1) }
        return providers + more + ["other"]
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

    /// The line under the header when the daemon refuses a Resume. It
    /// knows only the sessions its own process registry saw start, so an
    /// older archive record often has no place to resume in; the copied
    /// command still works in any terminal, so the refusal says so.
    static func resumeRefusal(_ error: CoreReplyError?, title: String) -> String {
        guard let error else { return "Could not resume \(title)" }
        let said = error.message ?? "Could not resume \(title)"
        guard error.code == "not_found" else { return said }
        let sentence = said.hasSuffix(".") ? String(said.dropLast()) : said
        return sentence + " — Copy Resume Command instead."
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

    // MARK: CLIProxyAPI's request log

    /// Where CLIProxyAPI keeps its config: its own folder, else Homebrew's.
    static let cliProxyConfigPaths = [
        "~/.cli-proxy-api/config.yaml",
        "/opt/homebrew/etc/cliproxyapi.conf",
        "/usr/local/etc/cliproxyapi.conf",
    ]

    /// The first CLIProxyAPI config that exists, as text. It is read on
    /// this Mac only to see whether `request-log` is on, and is never shown
    /// or sent anywhere. nil when there is none.
    static func cliProxyConfig(paths: [String] = cliProxyConfigPaths) -> String? {
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return nil
    }

    /// The note under the CLIProxyAPI source while its proxy writes only
    /// error logs, so the archive holds a few failures and none of the
    /// ordinary requests. The sentence and the rule belong to the daemon
    /// lane: at integration this returns
    /// `CLIProxyLogParser.requestLogNote(config: config)` (X18). Until
    /// then there is no note.
    static func requestLogNote(config: String?) -> String? {
        nil
    }

    // MARK: Agent Sessions

    /// Agent Sessions (jazzyalex/agent-sessions): local search and resume
    /// across sixteen agents. Offered as a hand-off only when installed.
    static let agentSessions = ExternalAppProbe(
        bundleIDs: ["com.triada.AgentSessions", "com.jazzyalex.AgentSessions"],
        appNames: ["Agent Sessions.app", "AgentSessions.app"])
}

extension DataHoarderModel {
    /// The provider picker's rows: the capturing sources' agents, the
    /// agents already in the archive, and the pick in force.
    var providerChoices: [String] {
        DataHoarderProviders.choices(enabledSources: captureSettings.enabledSources,
                                     archived: records.map(\.provider), selected: searchFilter.provider)
    }

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
                    : DataHoarderProviders.resumeRefusal(reply.error, title: title)
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

    /// Where the one-time relabel below is marked done.
    static let relabelDoneKey = "jrbar.dataHoarder.sourceProvidersRelabeled"

    /// Records captured before their source's provider was stamped read
    /// as "other"; the folder they came from says whose they are, so the
    /// picker's pi, Gemini and Grok find them too. Once per Mac: capture
    /// and import stamp the provider as each record lands now, so after
    /// one pass over the catalog there is nothing left to fix, and the
    /// archive's opening never reads the whole catalog for it again.
    func relabelSourceRecords(sources: [ArchiveSource] = ArchiveSource.defaults(),
                              defaults: UserDefaults = .standard) async {
        guard enabled, !defaults.bool(forKey: Self.relabelDoneKey) else { return }
        guard let records = try? await archive.records(query: "", inTrash: false) else { return }
        var fixed = 0
        for record in records {
            if await stampSourceProvider(record, sources: sources) { fixed += 1 }
        }
        defaults.set(true, forKey: Self.relabelDoneKey)
        if fixed > 0 { await reload() }
    }

    /// A record the probe could only call "other" (or nothing) takes the
    /// provider of the named source whose folder it came from, the way
    /// capture stamps it. True when the record was changed.
    @discardableResult
    func stampSourceProvider(_ record: ArchiveRecord,
                             sources: [ArchiveSource] = ArchiveSource.defaults()) async -> Bool {
        guard record.provider == nil || record.provider == "other",
              let provider = DataHoarderProviders.sourceProvider(forPath: record.sourcePath, sources: sources)
        else { return false }
        return (try? await archive.updateRecordMetadata(id: record.id, provider: provider)) != nil
    }
}

extension DataHoarderProviders {
    /// The named agent whose source folder holds `path` (pi, Gemini, Grok),
    /// nil for Claude and Codex, whose content names them, and for any
    /// folder the person added.
    static func sourceProvider(forPath path: String, sources: [ArchiveSource]) -> String? {
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        for source in sources {
            guard let provider = ArchiveSource.namedProvider(of: source.id) else { continue }
            if file.hasPrefix(source.root.standardizedFileURL.path + "/") { return provider }
        }
        return nil
    }
}
