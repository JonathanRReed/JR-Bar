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
    var filter = HistoryFilter()
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

    // MARK: Derived

    var filtered: [CoreHistoryRow] { filter.apply(rows) }
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
        // an ended row keeps its history but has nothing to show.
        guard isLiveSession(row.session) else { return }
        core.openSession(row.session!)
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

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `m:ss` under an hour, `h:mm:ss` after; monospaced in the column.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        if total < 3600 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
