import AppKit
import JRBarCore
import Observation

/// The Overview window's state: the daemon's full roster (the records the
/// panel's aging filter would hide included), the selected cut, search,
/// sorting, saved views, and the summary strip's counts.
///
/// Counts come from the daemon's `list_roster` document — the same
/// projection the list shows — never from a second source the table and
/// the strip could disagree over (S7.1).
@MainActor
@Observable
final class OverviewStore {
    let core: CoreModel

    var roster: [CoreRosterEntry] = []
    var counts = CoreRosterCounts()
    var coverageNote: String?
    var loading = false
    var error: String?
    var loadedAt: Date?
    var now = Date()
    var selectedID: String?
    /// The table's full multi-selection; `selectedID` is the primary
    /// (first in row order) the inspector follows. Two selected rows
    /// enable Compare (S7.4).
    var selectedIDs: Set<String> = []

    /// The active cut: a preset or a saved view's definition.
    var filter = OverviewFilter(preset: .needsMe)
    /// Free text over title, project, tool and event names (S7.1).
    var search = ""
    var sortOrder = [KeyPathComparator(\CoreRosterEntry.attentionSortKey)]
    var savedFilters: [SavedOverviewFilter] = OverviewSavedFilters.load()
    /// The selected saved view's name while it is applied; an edit to the
    /// live filter clears the highlight without deleting the definition.
    var activeSavedFilter: String?

    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var lastEventID: String?
    /// The roster is a query surface: the daemon may retain things no
    /// event names, so absent events this is the cadence.
    static let refreshInterval: TimeInterval = 15

    init(core: CoreModel) {
        self.core = core
    }

    // MARK: Derived

    /// The rows the active cut keeps, after search and sorting. The sort
    /// applies to the whole filtered set so a column click never lies
    /// about the order the daemon sent.
    var rows: [CoreRosterEntry] {
        var out = roster.filter { row in
            filter.matches(row) && (search.isEmpty || OverviewStore.matchesSearch(row, search))
        }
        out.sort(using: sortOrder)
        return out
    }

    /// Distinct project labels present in the roster, for the sidebar's
    /// "This project" section. Sorted; same-named roots differ by their
    /// parent component.
    var projects: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in roster {
            guard let name = OverviewFilter.projectName(of: entry.session.cwd), !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
        }
        return out.sorted()
    }

    /// The summary strip's counts — computed over the SAME filtered rows
    /// the table shows (S7.1: the strip and the list never disagree).
    var stripCounts: (live: Int, attention: Int, unreviewed: Int, hidden: Int) {
        var live = 0, attention = 0, unreviewed = 0, hidden = 0
        for entry in rows {
            // The daemon's own outcome axis decides finished-vs-live — one
            // vocabulary, no second lifecycle table to drift out of sync.
            if !(["succeeded", "failed", "unreported"].contains(entry.axes?.outcome ?? "")) { live += 1 }
            if entry.pinned || entry.session.ask != nil { attention += 1 }
            if entry.axes?.review == "unreviewed" { unreviewed += 1 }
            if entry.visibility == "hidden" { hidden += 1 }
        }
        return (live, attention, unreviewed, hidden)
    }

    var isLive: Bool { core.isLive }

    var selected: CoreRosterEntry? { rows.first { $0.id == selectedID } }

    // MARK: Lifecycle

    func windowDidOpen() {
        now = Date()
        lastEventID = core.lastEvent?.id
        clock?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        Task { await load() }
    }

    func windowDidClose() {
        clock?.invalidate()
        clock = nil
    }

    private func tick() {
        now = Date()
        guard core.isLive else { return }
        // The roster is a query surface: rows move with each collector
        // snapshot, not just named events — reload on events and every
        // `refreshInterval` regardless.
        let eventID = core.lastEvent?.id
        let stale = loadedAt.map { now.timeIntervalSince($0) > Self.refreshInterval } ?? true
        if eventID != lastEventID || stale {
            lastEventID = eventID
            Task { await load() }
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            // The Overview is the everything-workspace: ask for the
            // daemon's ROSTER_MAX_LIMIT so a long-retained set is not
            // truncated at the interactive default of 500.
            let document = try await core.listRoster(scope: "all", limit: 2000)
            roster = document.sessions
            counts = document.counts
            coverageNote = document.coverage?["note"]?.stringValue
            loadedAt = Date()
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Actions

    /// Keyboard navigation for the table: the selection moves within the
    /// visible (filtered, sorted) rows, never off it.
    func moveSelection(by delta: Int) {
        let list = rows
        guard !list.isEmpty else { selectedID = nil; selectedIDs = []; return }
        let index = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : list.count)
        let next = max(0, min(list.count - 1, index + delta))
        selectedID = list[next].id
        selectedIDs = [list[next].id]
    }

    /// The table reports its selection set; `selectedID` follows the
    /// first selected row in table order so the inspector stays stable.
    func selectionChanged(to ids: Set<String>) {
        selectedIDs = ids
        selectedID = rows.first { ids.contains($0.id) }?.id
    }

    // MARK: Compare

    /// The `compare_sessions` document for the two-row selection, shown
    /// in a sheet; nil hides it. `comparing` marks the fetch in flight.
    var comparison: CoreRunComparison?
    var comparing = false

    var canCompare: Bool { selectedIDs.count == 2 }

    func compareSelected() {
        guard canCompare else { return }
        let pair = rows.filter { selectedIDs.contains($0.id) }.map(\.id)
        guard pair.count == 2 else { return }
        comparing = true
        Task {
            defer { comparing = false }
            do {
                comparison = try await core.compareRuns(pair[0], pair[1])
            } catch {
                self.error = Self.describe(error)
            }
        }
    }

    /// Open the selected session's terminal — the same `open_session`
    /// the panel's row runs, so a remote row is refused there, not here.
    func openSelected() {
        guard let id = selectedID else { return }
        core.openSession(id)
    }

    func apply(_ saved: SavedOverviewFilter) {
        filter = saved.filter
        activeSavedFilter = saved.name
        search = ""
    }

    func saveCurrentFilter(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedFilters.removeAll { $0.name == trimmed }
        savedFilters.append(SavedOverviewFilter(name: trimmed, filter: filter))
        savedFilters.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        OverviewSavedFilters.save(savedFilters)
        activeSavedFilter = trimmed
    }

    func deleteSavedFilter(_ name: String) {
        savedFilters.removeAll { $0.name == name }
        OverviewSavedFilters.save(savedFilters)
        if activeSavedFilter == name { activeSavedFilter = nil }
    }

    // MARK: Export

    /// The export being previewed: the document the daemon produced and
    /// the markdown rendering of it, before any destination is chosen.
    var exportPreview: (document: JSONValue, markdown: String)?

    /// Fetch the export for preview (S7.4: preview, then destination).
    /// The same bytes the sheet shows are what Save writes — the preview
    /// is the artifact, not a sketch of one.
    func prepareExport() async {
        do {
            let json = try await core.exportAudit(scope: "all", format: "json")
            let markdown = try await core.exportAudit(scope: "all", format: "markdown")
            exportPreview = (json.document, markdown.text ?? "")
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Write the previewed document to the user-picked URL. Writing the
    /// already-generated bytes keeps preview and artifact identical.
    func saveExport(to url: URL, markdown: Bool) throws {
        guard let preview = exportPreview else { return }
        let data: Data
        if markdown {
            data = Data(preview.markdown.utf8)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(preview.document)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Timeline

    /// The selected session's transcript items, newest page loaded.
    /// `timelineSessionID` pins which row the buffer belongs to so a
    /// late reply cannot write another selection's page into view.
    var timeline: [CoreTimelineItem] = []
    var timelinePage: CoreTimelinePage?
    var timelineLoading = false
    var timelineSessionID: String?

    /// Load the newest page for the given roster row id.
    func loadTimeline(for id: String) async {
        guard timelineSessionID != id || timelinePage == nil else { return }
        timelineSessionID = id
        timeline = []
        timelinePage = nil
        timelineLoading = true
        defer { timelineLoading = false }
        do {
            let page = try await core.sessionTimeline(id: id)
            guard timelineSessionID == id else { return }
            timeline = page.events
            timelinePage = page
        } catch {
            guard timelineSessionID == id else { return }
            timelinePage = CoreTimelinePage(gaps: [Self.describe(error)])
        }
    }

    /// The next older page, prepended — transcript reads are bounded so
    /// "Load earlier" is the only way deep history enters the window.
    func loadEarlierTimeline() async {
        guard let id = timelineSessionID,
              let page = timelinePage, page.hasMore,
              let before = page.nextBefore, !timelineLoading else { return }
        timelineLoading = true
        defer { timelineLoading = false }
        do {
            let older = try await core.sessionTimeline(id: id, before: before)
            guard timelineSessionID == id else { return }
            timeline = older.events + timeline
            timelinePage = CoreTimelinePage(
                events: timeline, hasMore: older.hasMore,
                nextBefore: older.nextBefore, total: older.total,
                provider: page.provider, file: page.file, gaps: page.gaps)
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Search

    /// Titles, project labels, tool and event names, and the row's own
    /// message — the retained evidence the daemon already surfaced, never
    /// a repository crawl (S7.1).
    static func matchesSearch(_ entry: CoreRosterEntry, _ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let session = entry.session
        let haystacks: [String?] = [
            session.label, session.shortId, session.cwd,
            OverviewFilter.projectName(of: session.cwd),
            session.tool, session.event, session.message,
            session.origin?.label, session.provider,
        ]
        return haystacks.contains { $0?.lowercased().contains(needle) == true }
    }

    static func describe(_ error: Error) -> String {
        (error as? CoreReplyError)?.message ?? error.localizedDescription
    }
}

extension CoreRosterEntry {
    /// The default sort: attention first, then the panel's own order —
    /// same precedence the panel rows use, so the table and the shelf
    /// tell one story.
    var sortRankKey: Int {
        if pinned || session.ask != nil { return 0 }
        return SessionActivity.reduce(session).sortRank + 1
    }

    // Table sort keys — each column's comparator maps to one stable value
    // so clicking a header re-orders the whole filtered set deterministically.
    var labelSortKey: String { session.label ?? session.shortId ?? "" }
    var projectSortKey: String { OverviewFilter.projectName(of: session.cwd) ?? "" }
    var stateSortKey: Int { sortRankKey }
    /// No model data exists on the wire; a constant key keeps the column
    /// sortable without pretending an order it does not have.
    var modelSortKey: String { "" }
    var activitySortKey: String { session.event ?? session.tool ?? "" }
    var elapsedSortKey: Double { -(session.since ?? 0) } // longest-running first
    var freshnessSortKey: String { axes?.freshness ?? (session.stale ? "stale" : "live") }
    var attentionSortKey: Int { (pinned || session.ask != nil) ? 0 : 1 }
}
