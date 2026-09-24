import AppKit
import JRBarCore
import Observation

/// The History window's state: the daemon's rows, the filter, the away
/// summary, and the undo window for the last clear — plus the two views
/// of the past that used to live elsewhere: a row's own session timeline
/// (the shared timeline view, opened in place) and the daemon's event
/// journal (what the Event Replay window showed on its own).
@MainActor
@Observable
final class HistoryStore {
    let core: CoreModel

    /// Activity is the ledger of what happened to sessions; Events is the
    /// daemon's live event journal for this run — Event Replay, folded in.
    enum Mode: String, CaseIterable, Identifiable {
        case activity = "Activity"
        case events = "Events"
        var id: String { rawValue }
    }

    /// The daemon's settings document, for provider colour overrides.
    var document: SettingsDocument? { core.settings.map { SettingsDocument($0.document) } }
    var rows: [CoreHistoryRow] = []
    var filter = HistoryFilter() {
        didSet { if filter.text != oldValue.text { searchTranscripts() } }
    }
    var loading = false
    var error: String?
    var loadedAt: Date?
    var now = Date()
    var selectedID: String?
    var onClose: (@MainActor () -> Void)?
    /// Reveals a session in the Overview (its inspector, timeline and
    /// usage); an event row's click-through.
    var onRevealSession: (@MainActor (String) -> Void)?

    var mode: Mode = .activity {
        didSet { syncReplay() }
    }
    /// The journal reader — the same store Event Replay used, so its
    /// coverage (`retained`/`dropped`) and live throttle come along.
    let replay: ReplayStore
    var eventFilter = EventLogFilter()
    private var windowOpen = false

    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var refreshWork: DispatchWorkItem?
    @ObservationIgnored private var lastEventID: String?
    /// Without an event, rows are refreshed this often (the daemon may
    /// record things that never raise an event).
    static let refreshInterval: TimeInterval = 30

    init(core: CoreModel) {
        self.core = core
        self.replay = ReplayStore(core: core)
    }

    /// The journal reloads on live frames only while someone is looking
    /// at it.
    private func syncReplay() {
        let watching = windowOpen && mode == .events
        replay.isOpen = watching
        if watching { Task { await replay.load() } }
    }

    // MARK: Events (the journal)

    /// The journal, filtered, newest first.
    var events: [CoreEvent] { eventFilter.apply(replay.events) }

    /// Categories present in the journal, in the chips' order.
    var eventCategories: [EventLogCategory] {
        let present = Set(replay.events.filter { !EventLogFilter.hiddenKinds.contains($0.kind) }.map { EventLogCategory.of($0.kind) })
        return EventLogCategory.allCases.filter(present.contains)
    }

    func eventCount(_ category: EventLogCategory) -> Int {
        replay.events.filter { !EventLogFilter.hiddenKinds.contains($0.kind) && EventLogCategory.of($0.kind) == category }.count
    }

    func toggleEventCategory(_ category: EventLogCategory) {
        if eventFilter.categories.contains(category) { eventFilter.categories.remove(category) } else { eventFilter.categories.insert(category) }
    }

    /// An event about a local session opens that session in the Overview.
    func canReveal(_ event: CoreEvent) -> Bool {
        guard let session = event.session, !session.isEmpty else { return false }
        return onRevealSession != nil
    }

    func reveal(_ event: CoreEvent) {
        guard let session = event.session, !session.isEmpty else { return }
        onRevealSession?(session)
    }

    // MARK: Row timelines

    /// The row whose session timeline is open under it, if any.
    var expandedID: String?
    /// The shared timeline view's chip/disclosure state for the open row.
    let expandedViewState = ReconstructedTimelineViewState()
    private(set) var expandedTimelines: [String: SessionReconstruction] = [:]
    private(set) var expandedLoading: Set<String> = []

    func canExpand(_ row: CoreHistoryRow) -> Bool { HistoryTimelineRequest.canExpand(row) }

    func toggleExpanded(_ row: CoreHistoryRow) {
        guard canExpand(row) else { return }
        if expandedID == row.id {
            expandedID = nil
            return
        }
        expandedID = row.id
        selectedID = row.id
        expandedViewState.kind = .all
        loadTimeline(for: row)
    }

    /// The newest page of the row's transcript, through the same
    /// `session_timeline` the Overview reads; an ended session that aged
    /// out of the roster still resolves by provider and uuid.
    func loadTimeline(for row: CoreHistoryRow, force: Bool = false) {
        guard let session = row.session, core.isLive, !expandedLoading.contains(row.id) else { return }
        if !force, expandedTimelines[row.id] != nil { return }
        expandedLoading.insert(row.id)
        let running = isLiveSession(session)
        Task { [weak self] in
            guard let self else { return }
            defer { self.expandedLoading.remove(row.id) }
            do {
                let page = try await self.core.sessionTimeline(
                    id: session, limit: 150, provider: HistoryTimelineRequest.provider(of: row),
                    session: HistoryTimelineRequest.sessionUUID(from: session))
                self.expandedTimelines[row.id] = SessionReconstructor.reconstruction(
                    from: page.events, gaps: page.gaps, running: running)
            } catch {
                self.expandedTimelines[row.id] = SessionReconstructor.reconstruction(
                    from: [], gaps: [(error as? CoreReplyError)?.message ?? error.localizedDescription], running: running)
            }
        }
    }

    /// → / Space open the selected row's timeline, ← closes it.
    func expandSelected(_ open: Bool) {
        guard let row = displayed.first(where: { $0.id == selectedID }) else { return }
        if open, expandedID != row.id { toggleExpanded(row) }
        if !open, expandedID == row.id { expandedID = nil }
    }

    func timeline(for row: CoreHistoryRow) -> SessionReconstruction? { expandedTimelines[row.id] }
    func isLoadingTimeline(_ row: CoreHistoryRow) -> Bool { expandedLoading.contains(row.id) }

    // MARK: Transcript search

    /// The Data Hoarder's full-text index: session uuid → the best
    /// snippet for a query. Set by the app delegate while the archive is
    /// on; nil searches the rows' own words only.
    var archiveSearch: ((String) async -> [String: String])?
    /// Whether the archive is on to be searched — the field's placeholder
    /// only promises transcripts when it is.
    var archiveSearchAvailable: (() -> Bool)?
    var canSearchTranscripts: Bool { archiveSearch != nil && (archiveSearchAvailable?() ?? false) }
    /// Sessions whose archived transcript said the text, for the query
    /// they answered — so "which run touched the auth middleware?" finds
    /// the run even though no row's label says so.
    private(set) var transcriptHits: (query: String, snippets: [String: String]) = ("", [:])
    @ObservationIgnored private(set) var transcriptSearch: Task<Void, Never>?
    /// Shorter queries match too much of a transcript to mean anything.
    static let transcriptQueryMinimum = 3

    private var trimmedQuery: String { filter.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Debounced so typing does not run a query per key; a stale answer
    /// (the text moved on) is dropped.
    func searchTranscripts(debounce: Duration = .milliseconds(300)) {
        transcriptSearch?.cancel()
        let query = trimmedQuery
        guard query.count >= Self.transcriptQueryMinimum, let archiveSearch else {
            transcriptHits = ("", [:])
            return
        }
        transcriptSearch = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            let snippets = await archiveSearch(query)
            guard !Task.isCancelled, let self, self.trimmedQuery == query else { return }
            self.transcriptHits = (query, snippets)
        }
    }

    // MARK: The Data Hoarder offer

    /// Whether the Data Hoarder already keeps agent transcripts. Set by
    /// the app delegate; unset reads as yes, so nothing is offered.
    var hoarderKeepsTranscripts: (() -> Bool)?
    /// The consent sheet's Turn On: the chosen sources and the backfill
    /// window, handed to the utility — set by the app delegate.
    @ObservationIgnored var keepTranscripts: (@MainActor (_ sourceIDs: [String], _ days: Int) -> Void)?
    /// Whether Data Hoarder's full-content switch is on — the sheet's
    /// consent text says verbatim, not redacted, when it is.
    @ObservationIgnored var hoarderFullContent: () -> Bool = { false }
    /// When each agent source was last kept — the sheet's estimate for a
    /// source kept before counts what changed since, not the window.
    @ObservationIgnored var hoarderResumePoints: @MainActor ([String]) async -> [String: Date] = { _ in [:] }
    /// The folders the sheet looks in; tests point it at fixtures.
    @ObservationIgnored var offerSources: () -> [ArchiveSource] = { DataHoarderModel.agentSources() }
    /// The open consent sheet, if any.
    var hoarderOffer: DataHoarderOffer?

    /// The empty search's one-line offer: a real query found nothing, and
    /// no transcript copy exists for it to have searched.
    var offersHoarder: Bool {
        trimmedQuery.count >= Self.transcriptQueryMinimum && keepTranscripts != nil
            && !(hoarderKeepsTranscripts?() ?? true)
    }

    /// The offer's click opens the sheet. Only file names, sizes and dates
    /// are read for its estimate; contents wait for its Turn On.
    func offerHoarder() {
        guard offersHoarder, let keep = keepTranscripts else { return }
        hoarderOffer = DataHoarderOffer(sources: offerSources(), fullContent: hoarderFullContent(),
                                        resumePoints: hoarderResumePoints) { [weak self] sourceIDs, days in
            let resuming = self?.hoarderOffer?.resumesEveryChosenSource ?? false
            keep(sourceIDs, days)
            self?.hoarderTurnedOn(days: days, resuming: resuming)
        }
    }

    /// Turn On landed: the search reruns against what is indexed so far,
    /// and the notice says the copy is still filling — or, when every
    /// chosen folder was kept before, that it picks up where it stopped.
    func hoarderTurnedOn(days: Int, resuming: Bool = false) {
        hoarderOffer = nil
        say(resuming
                ? "Data Hoarder picks up where it stopped — search reaches it as it indexes"
                : "Data Hoarder is reading the last \(days) days — search reaches it as it indexes",
            isError: false)
        searchTranscripts(debounce: .seconds(2))
    }

    /// The session uuids the current text found in transcripts.
    private var liveTranscriptHits: Set<String> {
        transcriptHits.query == trimmedQuery && !trimmedQuery.isEmpty ? Set(transcriptHits.snippets.keys) : []
    }

    /// The snippet for a row the text found only in its transcript.
    func transcriptSnippet(for row: CoreHistoryRow) -> String? {
        guard !filter.matchesOwnWords(row), transcriptHits.query == trimmedQuery,
              let uuid = HistoryTimelineRequest.sessionUUID(from: row.session) else { return nil }
        return transcriptHits.snippets[uuid]
    }

    // MARK: Derived

    var filtered: [CoreHistoryRow] { filter.apply(rows, transcriptHits: liveTranscriptHits) }
    var days: [HistoryDay] { HistoryGrouping.days(filtered, now: now) }
    var away: AwaySummary? { AwaySummary.make(from: rows) }
    var providers: [String] {
        var seen: [String] = []
        for row in rows { if let provider = row.provider, !seen.contains(provider) { seen.append(provider) } }
        return seen
    }
    var kinds: [String] { CoreHistoryRow.kinds.filter { kind in rows.contains { $0.kind == kind } } }
    var canUndo: Bool { _ = now; return core.canUndoClear }
    var undoRemaining: String? {
        guard let last = core.lastClear, core.canUndoClear else { return nil }
        let left = Int(EventPolicy.undoWindow - now.timeIntervalSince(last.at))
        return left >= 60 ? "\(left / 60) min" : "\(max(0, left)) s"
    }
    var completedCount: Int { core.sessions.filter { SessionActivity.reduce($0) == .done }.count }
    var isLive: Bool { core.isLive }

    // MARK: Lifecycle

    func windowDidOpen() {
        now = Date()
        windowOpen = true
        syncReplay()
        lastEventID = core.lastEvent?.id
        clock?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.now = Date()
                // New rows follow events (a completion, an ask); refetch
                // on each one, and every 30 s regardless.
                guard self.core.isLive else { return }
                let eventID = self.core.lastEvent?.id
                let stale = self.loadedAt.map { self.now.timeIntervalSince($0) > Self.refreshInterval } ?? true
                if eventID != self.lastEventID || stale {
                    self.lastEventID = eventID
                    self.reload()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        reload()
        // Opening the window is itself a look: advance the daemon's
        // `last_seen` watermark so `unseen` means "since you last looked".
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.core.markHistorySeen()
        }
    }

    func windowDidClose() {
        windowOpen = false
        syncReplay()
        clock?.invalidate()
        clock = nil
        // The window was open and read: advance the daemon's `last_seen`
        // watermark so `unseen` means "since you last looked", not "since
        // the app last disconnected" (the app stays connected).
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.core.markHistorySeen()
        }
    }

    func reload() {
        guard core.isLive else {
            error = "History needs the monitor. Rows appear when it connects."
            return
        }
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.loading = false }
            do {
                let rows = try await self.core.listHistory()
                self.rows = rows
                self.error = nil
                self.loadedAt = Date()
            } catch {
                self.error = "Could not load history: \(error)"
            }
        }
    }

    // MARK: Actions

    /// The session the row names is still a live row in the daemon's
    /// state (not finished, ended or failed) — a "started" history row for
    /// it must not read as a completed run.
    func isLiveSession(_ id: String?) -> Bool {
        guard let id else { return false }
        return core.sessions.contains { session in
            session.id == id && ![SessionActivity.done, .ended, .failed].contains(SessionActivity.reduce(session))
        }
    }

    func open(_ row: CoreHistoryRow) {
        selectedID = row.id
        // Only a session still live in the daemon's state can be opened;
        // an ended row keeps its history but has nothing to show — Resume
        // is its verb.
        guard isLiveSession(row.session), let session = row.session else { return }
        Task { [weak self] in await self?.open(session: session) }
    }

    /// One live session, through `SessionOpener` — the daemon, then the
    /// Dock's window locator — with its refusal, if any, as the notice.
    func open(session: String) async {
        if let refusal = await opener(session) { say(refusal, isError: true) }
    }

    /// Opening a session: `SessionOpener` in production; tests stage it.
    @ObservationIgnored var opener: @MainActor (_ session: String) async -> String? = { await SessionOpener.open($0) }

    // MARK: Resume

    /// The last Open or Resume's outcome, in the daemon's words — a
    /// receipt or a refusal — for a few seconds under the filter bar.
    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }
    private(set) var notice: Notice?
    @ObservationIgnored private var noticeToken: UUID?
    static let noticeLife: TimeInterval = 5

    /// The agents whose CLIs `resume_session` can pick back up.
    static let resumableProviders: Set<String> = ["claude", "codex", "devin", "grok", "cursor", "hermes"]

    /// The provider a row belongs to: its own, else its agent id's first
    /// part (`claude:session:…`).
    nonisolated static func provider(of row: CoreHistoryRow) -> String? {
        row.provider ?? row.session?.split(separator: ":").first.map(String.init)
    }

    /// Resume is offered on a row whose session is no longer running —
    /// a live one opens instead — of an agent whose CLI can resume, on
    /// this Mac. The daemon has the last word (a worker, a directory that
    /// is gone), and its refusal is the notice.
    func canResume(_ row: CoreHistoryRow) -> Bool {
        guard let session = row.session, !session.isEmpty, !CoreSession.isRemoteID(session),
              let provider = Self.provider(of: row) else { return false }
        return Self.resumableProviders.contains(provider) && !isLiveSession(session)
    }

    /// `resume_session {session}` — explicit only: the ended session
    /// picks back up in the terminal it ran in (a new tab or window at
    /// its folder, the resume typed into your own shell); one still
    /// running is raised instead, never started twice.
    func resume(_ row: CoreHistoryRow) {
        selectedID = row.id
        guard canResume(row), let session = row.session else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.send("resume_session", args: ["session": .string(session)])
                if reply.ok {
                    self.say(Self.resumedText(reply.result, title: row.displayTitle), isError: false)
                } else {
                    self.say(reply.error?.message ?? "Could not resume \(row.displayTitle)", isError: true)
                }
            } catch {
                self.say("The monitor is not answering", isError: true)
            }
        }
    }

    /// "Resumed fix-ci in a new Ghostty tab", or, for a session that
    /// turned out to be running, "Raised fix-ci in Terminal".
    nonisolated static func resumedText(_ result: JSONValue?, title: String) -> String {
        let app = result?["app"]?.stringValue
        switch result?["raised"]?.stringValue {
        case "new_tab": return "Resumed \(title) in a new \(app ?? "terminal") tab"
        case "new_window": return "Resumed \(title) in a new \(app ?? "terminal") window"
        case .some: return "\(title) was still running — raised it\(app.map { " in \($0)" } ?? "")"
        case nil: return "Resumed \(title)"
        }
    }

    private func say(_ text: String, isError: Bool) {
        notice = Notice(text: text, isError: isError)
        // A Resume run from the palette: its HUD says this line.
        PaletteVerbScope.ticket?.hear(text)
        let token = UUID()
        noticeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeLife) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeToken == token else { return }
                self.notice = nil
            }
        }
    }

    // MARK: Keyboard

    /// The rows in the order the window shows them (days, newest first).
    var displayed: [CoreHistoryRow] { days.flatMap(\.rows) }

    /// ↑/↓ move the selection through the displayed rows.
    func moveSelection(by delta: Int) {
        let rows = displayed
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : rows.count)
        let next = min(rows.count - 1, max(0, current + delta))
        selectedID = rows[next].id
    }

    /// Return opens the selected row; rows with no live session (the run
    /// is gone from the daemon) have nothing to open.
    func openSelected() {
        guard let row = displayed.first(where: { $0.id == selectedID }) else { return }
        open(row)
    }

    func clearCompleted() {
        core.clearCompleted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func undo() {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let reply = try await self.core.undoClear(), !reply.ok {
                    self.error = "Undo refused: \(reply.error?.message ?? reply.error?.code ?? "unknown")"
                }
                self.reload()
            } catch {
                self.error = "Undo failed: \(error)"
            }
        }
    }

    func toggleProvider(_ provider: String) {
        if filter.providers.contains(provider) { filter.providers.remove(provider) } else { filter.providers.insert(provider) }
    }

    func toggleKind(_ kind: String) {
        if filter.kinds.contains(kind) { filter.kinds.remove(kind) } else { filter.kinds.insert(kind) }
    }

    func clearFilter() { filter = HistoryFilter() }

    // MARK: Formatting

    /// The time of day in the reader's own 12- or 24-hour clock.
    static func clock(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
    }

    /// `m:ss` under an hour, `h:mm:ss` after; monospaced in the column.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        if total < 3600 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
