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
    var rows: [CoreHistoryRow] = [] {
        didSet { pruneTimelines(to: Set(rows.map(\.id))) }
    }
    var filter = HistoryFilter()
    var loading = false
    var error: String?
    var loadedAt: Date?
    var now = Date()
    var selectedID: String?
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
    @ObservationIgnored private var lastEventSequence = 0
    @ObservationIgnored private var loadToken: UUID?
    @ObservationIgnored private var readDuringVisit = false
    private let schedulingEnabled: Bool
    @ObservationIgnored var readHistory: @MainActor () async throws -> [CoreHistoryRow]
    @ObservationIgnored var markSeen: @MainActor () async throws -> Void
    @ObservationIgnored var readTimeline: @MainActor (CoreHistoryRow) async throws -> CoreTimelinePage
    @ObservationIgnored private var activeTimelineReads: Set<String> = []
    /// Without an event, rows are refreshed this often (the daemon may
    /// record things that never raise an event).
    static let refreshInterval: TimeInterval = 30

    init(core: CoreModel, schedulingEnabled: Bool = true) {
        self.core = core
        self.schedulingEnabled = schedulingEnabled
        self.replay = ReplayStore(core: core)
        self.readHistory = { try await core.listHistory() }
        self.markSeen = { _ = try await core.markHistorySeen() }
        self.readTimeline = { row in
            guard let session = row.session else { throw CoreReplyError(code: "invalid_args") }
            return try await core.sessionTimeline(
                id: session, limit: 150, provider: HistoryTimelineRequest.provider(of: row),
                session: HistoryTimelineRequest.sessionUUID(from: session))
        }
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
    static let timelineCacheLimit = 32
    @ObservationIgnored private var timelineRecency: [String] = []
    @ObservationIgnored private var timelineTokens: [String: UUID] = [:]
    /// Rows whose last timeline read failed: the gap line stands in for the
    /// timeline, and opening the row again asks again.
    private(set) var failedTimelines: Set<String> = []

    func canExpand(_ row: CoreHistoryRow) -> Bool { HistoryTimelineRequest.canExpand(row) }

    func toggleExpanded(_ row: CoreHistoryRow) {
        guard canExpand(row) else { return }
        if expandedID == row.id {
            expandedID = nil
            return
        }
        // A row that opens onto nothing says why; it never opens blank.
        guard core.isLive else {
            say("A run's timeline needs the monitor. Try again when it connects.", isError: true)
            return
        }
        expandedID = row.id
        selectedID = row.id
        expandedViewState.kind = .all
        loadTimeline(for: row)
    }

    @discardableResult
    func loadMissingExpandedTimeline(for row: CoreHistoryRow) -> Task<Void, Never>? {
        guard expandedID == row.id, expandedTimelines[row.id] == nil else { return nil }
        return loadTimeline(for: row)
    }

    /// The newest page of the row's transcript, through the same
    /// `session_timeline` the Overview reads; an ended session that aged
    /// out of the roster still resolves by provider and uuid.
    @discardableResult
    func loadTimeline(for row: CoreHistoryRow, force: Bool = false) -> Task<Void, Never>? {
        guard let session = row.session, core.isLive, !expandedLoading.contains(row.id) else { return nil }
        let running = isLiveSession(session)
        touchTimeline(row.id)
        guard Self.shouldLoadTimeline(cached: expandedTimelines[row.id] != nil, failed: failedTimelines.contains(row.id),
                                      running: running, force: force || activeTimelineReads.contains(row.id)) else { return nil }
        expandedLoading.insert(row.id)
        let token = UUID()
        timelineTokens[row.id] = token
        let read = readTimeline
        return Task { [weak self] in
            guard let self, self.timelineTokens[row.id] == token else { return }
            defer {
                if self.timelineTokens[row.id] == token {
                    self.expandedLoading.remove(row.id)
                    self.timelineTokens.removeValue(forKey: row.id)
                }
            }
            do {
                let page = try await read(row)
                guard self.timelineTokens[row.id] == token else { return }
                if running { self.activeTimelineReads.insert(row.id) }
                else { self.activeTimelineReads.remove(row.id) }
                self.expandedTimelines[row.id] = SessionReconstructor.reconstruction(
                    from: page.events, gaps: page.gaps, running: running)
                self.failedTimelines.remove(row.id)
            } catch {
                guard self.timelineTokens[row.id] == token else { return }
                self.expandedTimelines[row.id] = SessionReconstructor.reconstruction(
                    from: [], gaps: [UsageCenterStore.describe(error)], running: running)
                self.failedTimelines.insert(row.id)
            }
            self.touchTimeline(row.id)
            self.trimTimelines()
        }
    }

    private func touchTimeline(_ id: String) {
        timelineRecency.removeAll { $0 == id }
        if expandedTimelines[id] != nil { timelineRecency.append(id) }
    }

    private func evictTimeline(_ id: String) {
        expandedTimelines.removeValue(forKey: id)
        failedTimelines.remove(id)
        activeTimelineReads.remove(id)
        expandedLoading.remove(id)
        timelineTokens.removeValue(forKey: id)
        timelineRecency.removeAll { $0 == id }
    }

    private func trimTimelines() {
        while expandedTimelines.count > Self.timelineCacheLimit {
            guard let oldest = timelineRecency.first else { break }
            evictTimeline(oldest)
        }
    }

    private func pruneTimelines(to live: Set<String>) {
        let retained = Set(expandedTimelines.keys).union(timelineTokens.keys)
        for id in retained.subtracting(live) { evictTimeline(id) }
        if let expandedID, !live.contains(expandedID) { self.expandedID = nil }
    }

    /// Whether opening a row reads its timeline again. A read that landed
    /// is kept for a finished run; one that failed is asked for again, and
    /// a run still going is too. A page read while active also needs one
    /// final read after completion before it can be kept.
    nonisolated static func shouldLoadTimeline(cached: Bool, failed: Bool, running: Bool, force: Bool) -> Bool {
        force || !cached || failed || running
    }

    /// → / Space open the selected row's timeline, ← closes it.
    func expandSelected(_ open: Bool) {
        guard let row = displayed.first(where: { $0.id == selectedID }) else { return }
        if open, expandedID != row.id { toggleExpanded(row) }
        if !open, expandedID == row.id { expandedID = nil }
    }

    func timeline(for row: CoreHistoryRow) -> SessionReconstruction? { expandedTimelines[row.id] }
    func isLoadingTimeline(_ row: CoreHistoryRow) -> Bool { expandedLoading.contains(row.id) }

    private var trimmedQuery: String { filter.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Derived

    var filtered: [CoreHistoryRow] { filter.apply(rows) }
    var days: [HistoryDay] { HistoryGrouping.days(filtered, now: now) }
    /// "While you were away" is what was unseen when the window opened, and
    /// it stays that for as long as the window is open: opening moved the
    /// daemon's `last_seen` mark, so a later refresh reports the same rows
    /// as seen. Rows that arrive while the window is open are not away.
    var away: AwaySummary? {
        let baseline = awayIDs.map { ids in rows.filter { ids.contains($0.id) } } ?? rows
        return AwaySummary.make(from: baseline.map { row in
            var row = row
            row.unseen = isUnseen(row)
            return row
        })
    }

    /// The ids unseen at the window's first read after it opened; nil until
    /// that read lands, when the daemon's own flag stands.
    private(set) var awayIDs: Set<String>?
    @ObservationIgnored private var awaitingAwayBaseline = false

    func isUnseen(_ row: CoreHistoryRow) -> Bool { awayIDs?.contains(row.id) ?? row.unseen }

    /// A read of the rows landed. The first one after the window opened
    /// fixes what counts as away.
    func adopt(rows: [CoreHistoryRow]) {
        self.rows = rows
        if awaitingAwayBaseline {
            awaitingAwayBaseline = false
            awayIDs = Set(rows.filter(\.unseen).map(\.id))
        }
    }
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
        return UsageTime.duration(Double(left))
    }
    var completedCount: Int { core.sessions.filter { SessionActivity.reduce($0).isClearable || $0.stale }.count }
    var isLive: Bool { core.isLive }

    // MARK: Lifecycle

    @discardableResult
    func windowDidOpen() -> Task<Void, Never>? {
        now = Date()
        // Showing the window again while it is open is not a new visit.
        if !windowOpen {
            loadToken = nil
            loading = false
            readDuringVisit = false
            awayIDs = nil
            awaitingAwayBaseline = true
        }
        windowOpen = true
        syncReplay()
        lastEventSequence = core.eventSequence
        clock?.invalidate()
        clock = nil
        if schedulingEnabled {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = self?.refreshOnClockTick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        }
        return reload()
    }

    /// A queued tick may reach the main actor after the window closed.
    @discardableResult
    func refreshOnClockTick() -> Task<Void, Never>? {
        guard windowOpen else { return nil }
        now = Date()
        guard core.isLive else { return nil }
        let sequence = core.eventSequence
        let stale = loadedAt.map { now.timeIntervalSince($0) > Self.refreshInterval } ?? true
        guard sequence != lastEventSequence || stale else { return nil }
        lastEventSequence = sequence
        return reload()
    }

    func windowDidClose() {
        windowOpen = false
        expandedID = nil
        pruneTimelines(to: [])
        syncReplay()
        clock?.invalidate()
        clock = nil
        loadToken = nil
        loading = false
        // A failed read never acknowledges rows the person could not see.
        if readDuringVisit {
            Task { [weak self] in
                try? await self?.markSeen()
            }
        }
    }

    /// What every load failure starts with; the empty state, whose title
    /// already says it, shows the reason alone.
    static let loadFailurePrefix = "Could not load history: "

    @discardableResult
    func reload() -> Task<Void, Never>? {
        guard core.isLive else {
            error = "History needs the monitor. Rows appear when it connects."
            return nil
        }
        guard !loading else { return nil }
        loading = true
        let token = UUID()
        loadToken = token
        return Task { [weak self] in
            guard let self, self.loadToken == token else { return }
            defer {
                if self.loadToken == token { self.loading = false }
            }
            do {
                let rows = try await self.readHistory()
                guard self.loadToken == token else { return }
                let firstRead = self.awaitingAwayBaseline && self.windowOpen
                self.adopt(rows: rows)
                self.error = nil
                self.loadedAt = Date()
                if self.windowOpen {
                    self.readDuringVisit = true
                    if firstRead { try? await self.markSeen() }
                }
            } catch {
                guard self.loadToken == token else { return }
                self.error = Self.loadFailurePrefix + UsageCenterStore.describe(error)
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

    /// The last action's receipt or refusal, shown under the filter bar.
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
                self.say(MonitorWords.sentence, isError: true)
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

    /// A palette hit: the Activity tab (the Events tab has no filter to
    /// see), the query as the filter, and the row selected. A row folded
    /// under a newer one of its session selects the row that stands for it.
    func focus(on row: CoreHistoryRow?, query: String) {
        mode = .activity
        filter = HistoryFilter(text: query)
        guard let row else { return }
        for day in days {
            if day.rows.contains(where: { $0.id == row.id }) { selectedID = row.id; return }
            if let head = day.folded.first(where: { $0.value.contains { $0.id == row.id } }) { selectedID = head.key; return }
        }
        selectedID = row.id
    }

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

    enum HistoryAction: Equatable { case clear, undo }
    private(set) var pendingAction: HistoryAction?

    @discardableResult
    func clearCompleted() -> Task<Void, Never>? { performHistoryAction(.clear) }

    @discardableResult
    func undo() -> Task<Void, Never>? { performHistoryAction(.undo) }

    private func performHistoryAction(_ action: HistoryAction) -> Task<Void, Never>? {
        guard pendingAction == nil else { return nil }
        pendingAction = action
        return Task { [weak self] in
            guard let self else { return }
            defer { self.pendingAction = nil }
            let verb = action == .clear ? "Clear" : "Undo"
            do {
                let reply: CoreReply
                if action == .clear {
                    reply = try await self.core.clearCompletedNow()
                } else {
                    guard let undone = try await self.core.undoClear() else {
                        self.say("Nothing to undo. The undo window has passed.", isError: true)
                        return
                    }
                    reply = undone
                }
                guard reply.ok else {
                    self.say("\(verb) failed: \(reply.error?.message ?? reply.error?.code ?? "refused")", isError: true)
                    return
                }
                let countKey = action == .clear ? "cleared" : "restored"
                let count = reply.result?[countKey]?.arrayValue?.count ?? 0
                let quantity = "\(count) \(count == 1 ? "session" : "sessions")"
                if action == .clear {
                    let undo = reply.result?["batch"]?.stringValue == nil ? "" : " Undo is available for 5 minutes."
                    self.say(count > 0 ? "Cleared \(quantity).\(undo)" : "Nothing to clear.", isError: false)
                } else {
                    self.say("Restored \(quantity).", isError: false)
                }
                self.loadToken = nil
                self.loading = false
                if let refresh = self.reload() { await refresh.value }
            } catch {
                self.say("\(verb) failed: \(MonitorWords.sentence)", isError: true)
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
        UsageTime.clock(date.timeIntervalSince1970, locale: locale)
    }

    /// `m:ss` under an hour, `h:mm:ss` after; monospaced in the column.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let total = Int(saturating: seconds.rounded())
        if total < 3600 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
