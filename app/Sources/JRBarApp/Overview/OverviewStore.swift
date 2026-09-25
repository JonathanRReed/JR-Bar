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
    /// The window's one-second clock. Only leaf views read it — the time
    /// cells of the table, the inspector's waiting line — so a tick
    /// re-renders those, not the window.
    var now = Date()
    /// The clock the connections strip reads: moved by the tick only when
    /// a chip's time-drawn word would change (the minute, the quiet
    /// verdict and its age), so the strip, and the window root that asks
    /// for the selected link, stay put through the other ticks.
    private(set) var linksClock = Date()
    var selectedID: String?
    /// The table's full multi-selection; `selectedID` is the primary
    /// (first in row order) the inspector follows. Two selected rows
    /// enable Compare (S7.4).
    var selectedIDs: Set<String> = []

    /// The active cut: a preset or a saved view's definition.
    var filter = OverviewFilter(preset: .needsMe)
    /// Free text over title, project, tool and event names (S7.1).
    var search = ""
    /// The default cut: the state-rank order (waiting → failed → working
    /// → done → ended → idle), so the table opens attention-first
    /// without a column click. A header click replaces this key.
    var sortOrder = [KeyPathComparator(\CoreRosterEntry.sortRankKey)]
    /// When set, only worker rows of this parent session id are listed —
    /// set by the "+N workers" affordance on a parent row, cleared by
    /// the banner's × or any sidebar pick.
    var workerFilter: String?
    /// A day the Usage pane's heatmap sent the roster to (local
    /// midnight), with the provider row it was clicked on; rows whose
    /// last activity fell on that day are listed. Cleared by the banner's
    /// × or any sidebar pick.
    var dayFilter: (day: Date, provider: String?)?
    /// Opens History on one day — the same click, one window over.
    var onOpenHistoryDay: ((Date) -> Void)?
    var savedFilters: [SavedOverviewFilter] = OverviewSavedFilters.load()
    /// The selected saved view's name while it is applied; an edit to the
    /// live filter clears the highlight without deleting the definition.
    var activeSavedFilter: String?

    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var lastEventID: String?
    /// The roster is a query surface: the daemon may retain things no
    /// event names, so absent events this is the cadence.
    static let refreshInterval: TimeInterval = 15
    /// Per-session model, tokens, cost and context. Its own store until
    /// the app delegate hands it the panel's, so the two share reads.
    var sessionUsage: SessionUsageStore
    /// How many rows, from the top of the current cut, get their usage
    /// read — the table's first screenful and then some, never the
    /// whole two-thousand-row record.
    static let usageRowBudget = 48

    init(core: CoreModel, desk: AskAnswerDesk? = nil) {
        self.core = core
        self.sessionUsage = SessionUsageStore(core: core)
        self.ownDesk = desk ?? AskAnswerDesk(core: core)
        self.fetchGraph = { [weak core] days, metric, providers in
            guard let core else { throw CoreClientError.notConnected }
            return try await core.usageGraph(days: days, metric: metric, providers: providers)
        }
    }

    /// Approve, Deny, Always allow and a held question's picks go through
    /// the panel's shared desk (one pending set, one set of picks across
    /// surfaces); this store's own only until the app delegate publishes
    /// that one.
    private let ownDesk: AskAnswerDesk
    var askDesk: AskAnswerDesk { AskAnswerDesk.shared ?? ownDesk }

    /// Reads usage for the rows the table leads with and the selection.
    func refreshSessionUsage(force: Bool = false) {
        var ids = rows.prefix(Self.usageRowBudget).map(\.id)
        ids.append(contentsOf: selectedIDs)
        sessionUsage.refresh(ids: ids, force: force)
    }

    func usage(for entry: CoreRosterEntry) -> SessionUsage? { sessionUsage.usage(for: entry.id) }

    // MARK: Git (branch and worktree)

    /// cwd → where it sits in git, for the Project column's branch and the
    /// sidebar's Branches section. Read off the main thread after each
    /// roster load; a cwd outside any repository simply has no entry.
    private(set) var gitWorkspaces: [String: GitWorkspace] = [:]
    /// Bumps when `gitWorkspaces` changes, so a branch cut re-filters.
    private(set) var gitGeneration = 0
    @ObservationIgnored private var gitLookedUp: Set<String> = []
    @ObservationIgnored private var gitSweptAt = Date.distantPast
    /// A branch can be switched under a running agent: forget the lookups
    /// this often and read HEAD again.
    static let gitRefreshInterval: TimeInterval = 60
    /// The lookup, replaceable in tests.
    @ObservationIgnored var gitResolver: @Sendable (String) -> GitWorkspace? = { GitWorkspace.resolve(cwd: $0) }

    func workspace(for entry: CoreRosterEntry) -> GitWorkspace? {
        guard !entry.session.remote, let cwd = entry.session.cwd else { return nil }
        return gitWorkspaces[cwd]
    }

    func resolveGitWorkspaces(now: Date = Date()) {
        if now.timeIntervalSince(gitSweptAt) >= Self.gitRefreshInterval {
            gitLookedUp.removeAll()
            gitSweptAt = now
        }
        let pending = Set(roster.filter { !$0.session.remote }.compactMap(\.session.cwd)).subtracting(gitLookedUp)
        guard !pending.isEmpty else { return }
        gitLookedUp.formUnion(pending)
        let resolver = gitResolver
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: GitWorkspace] = [:]
            for cwd in pending { if let workspace = resolver(cwd) { found[cwd] = workspace } }
            await self?.mergeGitWorkspaces(found, looked: pending)
        }
    }

    func mergeGitWorkspaces(_ found: [String: GitWorkspace], looked: Set<String>) {
        var next = gitWorkspaces
        for cwd in looked { next[cwd] = found[cwd] }
        guard next != gitWorkspaces else { return }
        gitWorkspaces = next
        gitGeneration &+= 1
    }

    /// The sidebar's Branches section: every "repo · branch" the roster's
    /// rows sit on, offered only when branches actually tell rows apart —
    /// one repository on two or more branches, or any linked worktree.
    var branches: [String] {
        let workspaces = roster.compactMap { workspace(for: $0) }
        var keysByRepo: [String: Set<String>] = [:]
        var linked = false
        for workspace in workspaces {
            keysByRepo[workspace.repositoryName, default: []].insert(workspace.branchKey)
            linked = linked || workspace.isLinkedWorktree
        }
        guard linked || keysByRepo.values.contains(where: { $0.count > 1 }) else { return [] }
        return keysByRepo.values.flatMap { $0 }.sorted()
    }

    // MARK: Connections

    /// The live wiring the window reports — the core link, this Mac,
    /// each reachable peer, each device, each provider — lifted off the
    /// daemon's `state` push so the strip is as fresh as the rows and
    /// can never tell a second story (S7.1).
    ///
    /// Memoized on the snapshot's inputs: the 1 s `now` tick would
    /// otherwise rebuild the whole strip every second for a "Connected
    /// for" age that only needs minute resolution (the key quantizes
    /// `now` to 60 s).
    var links: [OverviewLink] {
        var connecting = false
        var offlineReason: String?
        switch core.connection {
        case .connecting: connecting = true
        case .disconnected(let reason): offlineReason = reason
        default: break
        }
        let clock = linksClock
        let time = linksTime(at: clock)
        let key = LinksKey(
            connected: core.isLive, connecting: connecting,
            offlineReason: offlineReason,
            coreVersion: core.hello?.coreVersion, corePID: core.hello?.pid,
            inFlight: core.inFlightCommands,
            localSessions: roster.reduce(into: 0) { $0 += $1.session.remote ? 0 : 1 },
            connectedAt: core.connectedAt,
            time: time,
            peers: core.state?.peers ?? [], devices: core.devices,
            providers: core.usage,
            deck: core.deck?.device,
            hoarder: hoarderHealth
        )
        if let cached = linksCache, cached.key == key { return cached.value }
        let now = clock
        let value = OverviewLinkage.links(OverviewLinkage.Snapshot(
            connected: key.connected, connecting: key.connecting,
            offlineReason: key.offlineReason,
            coreVersion: key.coreVersion, corePID: key.corePID,
            connectedAt: key.connectedAt, inFlight: key.inFlight,
            stateAge: core.stateAge(at: now), stateStale: time.stale,
            localName: Host.current().localizedName ?? "This Mac",
            localSessions: key.localSessions, peers: key.peers,
            devices: key.devices, providers: key.providers, deck: key.deck,
            hoarder: key.hoarder
        ), now: now)
        linksCache = (key, value)
        return value
    }

    /// Everything `links` reads, in one hashable key. `minute` quantizes
    /// the clock so the strip's relative-age fact refreshes once a
    /// minute instead of once a tick.
    private struct LinksKey: Hashable {
        var connected, connecting: Bool
        var offlineReason, coreVersion: String?
        var corePID: Int?
        var inFlight, localSessions: Int
        var connectedAt: Date?
        var time: LinksTime
        var peers: [CorePeer]
        var devices: [CoreDevice]
        var providers: [CoreProviderUsage]
        var deck: DeckDevice?
        var hoarder: OverviewLinkage.HoarderHealth?
    }

    /// What the chips draw from the clock, at the precision they draw it:
    /// the minute (ages are written in minutes and up), the same
    /// staleness verdict the panel uses — the chip's "connected" must
    /// admit a quiet daemon — and, while quiet, the age it prints.
    struct LinksTime: Hashable {
        var minute: Int
        var stale: Bool
        var staleAge: String?
    }

    func linksTime(at clock: Date) -> LinksTime {
        let stale = core.stateIsStale(at: clock)
        let age = stale ? core.stateAge(at: clock).map(AgentMonitorFeed.ageText) : nil
        return LinksTime(minute: Int(clock.timeIntervalSince1970 / 60), stale: stale, staleAge: age)
    }

    /// The tick's half of `linksClock`: move it only when what the chips
    /// draw from the time would change.
    func advanceLinksClock(to clock: Date) {
        if linksTime(at: clock) != linksTime(at: linksClock) { linksClock = clock }
    }
    @ObservationIgnored private var linksCache: (key: LinksKey, value: [OverviewLink])?

    /// The connections chip the inspector focuses — session selection
    /// and link selection are exclusive over the one detail column.
    /// Stored as an id so the inspector always resolves the link's
    /// CURRENT facts off the latest state, not the chip it clicked.
    var selectedLinkID: String?
    var selectedLink: OverviewLink? { links.first { $0.id == selectedLinkID } }

    func selectLink(_ id: String?) {
        selectedLinkID = id
        if id != nil { selectedID = nil; selectedIDs = [] }
    }

    // MARK: Derived

    /// The filtered+sorted rows and the strip's counts, computed in ONE
    /// pass and cached on the inputs — the 1 s `now` tick only refreshes
    /// relative-time strings and must not re-sort the roster. `derived`
    /// recomputes when (roster, filter, search, sortOrder, workerFilter)
    /// changes; `derivedComputations` counts recomputes so tests can
    /// prove the cache holds.
    struct DerivedResult {
        var rows: [CoreRosterEntry] = []
        var stripCounts = StripCounts()
        /// Working rows across the whole roster, whatever the cut.
        var workingOverall = 0
    }
    /// The summary strip's counts — computed over the SAME filtered rows
    /// the table shows (S7.1: the strip and the list never disagree).
    struct StripCounts: Equatable {
        var live = 0, attention = 0, failed = 0, unreviewed = 0, hidden = 0
    }
    private struct DerivedKey: Hashable {
        var roster: [CoreRosterEntry]
        var filter: OverviewFilter
        var search: String
        var sortDescription: String
        var workerFilter: String?
        /// The Model and Cost columns sort on usage read after the rows
        /// arrived; a new reading re-sorts.
        var usageGeneration: Int
        /// A branch cut filters on git lookups that land after the rows.
        var gitGeneration: Int
        var day: Date?
        var dayProvider: String?
    }
    @ObservationIgnored private var derivedCache: (key: DerivedKey, value: DerivedResult)?
    /// Recompute count — a test hook proving the memo holds across
    /// repeated reads and invalidates on input change.
    @ObservationIgnored var derivedComputations = 0

    private var derived: DerivedResult {
        let key = DerivedKey(
            roster: roster, filter: filter, search: search,
            sortDescription: sortOrder.map { "\($0.keyPath)|\($0.order)" }.joined(separator: ";"),
            workerFilter: workerFilter,
            usageGeneration: sortsByUsage ? sessionUsage.generation : 0,
            gitGeneration: filter.preset == .thisBranch ? gitGeneration : 0,
            day: dayFilter?.day, dayProvider: dayFilter?.provider
        )
        if let cached = derivedCache, cached.key == key { return cached.value }
        var result = DerivedResult()
        let workspaces = gitWorkspaces
        let branchKey: (String?) -> String? = { cwd in cwd.flatMap { workspaces[$0]?.branchKey } }
        let day = dayFilter
        result.rows = roster.filter { row in
            (day.map { Self.activeOn($0.day, provider: $0.provider, row) } ?? true)
                && filter.matches(row, branchKey: branchKey)
                && (workerFilter == nil || row.session.parent == workerFilter)
                && (search.isEmpty || OverviewStore.matchesSearch(row, search))
        }
        // The user's comparators tie constantly (every working row shares
        // a rank); without a unique tail key a reload can permute tied
        // rows and the table visibly jitters. `id` decides last.
        result.rows.sort(using: sortOrder + [KeyPathComparator(\.id)])
        for entry in result.rows {
            // The daemon's own outcome axis decides finished-vs-live — one
            // vocabulary, no second lifecycle table to drift out of sync.
            if !Self.terminalOutcomes.contains(entry.axes?.outcome ?? "") { result.stripCounts.live += 1 }
            if entry.pinned || entry.session.ask != nil { result.stripCounts.attention += 1 }
            if entry.axes?.outcome == "failed" { result.stripCounts.failed += 1 }
            if entry.axes?.review == "unreviewed" { result.stripCounts.unreviewed += 1 }
            if entry.visibility == "hidden" { result.stripCounts.hidden += 1 }
        }
        result.workingOverall = roster.reduce(0) { $0 + (OverviewPreset.working.matches($1) ? 1 : 0) }
        derivedComputations += 1
        derivedCache = (key, result)
        return result
    }

    /// The rows the active cut keeps, after search and sorting. The sort
    /// applies to the whole filtered set so a column click never lies
    /// about the order the daemon sent.
    var rows: [CoreRosterEntry] { derived.rows }

    /// Working rows across the whole roster, whatever the view shows.
    var workingOverall: Int { derived.workingOverall }

    /// The whole roster's word beside a strip the view has cut down —
    /// "2 working overall · 14 outside this view" — so "0 live" under
    /// Needs me never reads as nothing running. nil when every row shows.
    var wholeRosterPhrase: String? {
        let outside = roster.count - rows.count
        guard outside > 0 else { return nil }
        return (workingOverall > 0 ? "\(workingOverall) working overall · " : "") + "\(outside) outside this view"
    }

    /// Needs me with nothing waiting — the quiet state, not a filter that
    /// matched nothing: no search, worker or day cut narrows it.
    var nobodyWaiting: Bool {
        rows.isEmpty && !roster.isEmpty && filter.preset == .needsMe && activeSavedFilter == nil
            && search.isEmpty && workerFilter == nil && dayFilter == nil
    }

    /// "Show 2 working", from the quiet Needs me view.
    func showWorking() {
        pane = .roster
        workerFilter = nil
        dayFilter = nil
        activeSavedFilter = nil
        search = ""
        filter = OverviewFilter(preset: .working)
    }

    /// A Model or Cost column click: those orders move when a reading
    /// lands, every other order does not.
    private var sortsByUsage: Bool {
        let usageKeys: [AnyKeyPath] = [\CoreRosterEntry.modelSortKey, \CoreRosterEntry.costSortKey]
        return sortOrder.contains { comparator in usageKeys.contains { $0 == comparator.keyPath as AnyKeyPath } }
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

    /// The outcome words that mean a run is over — the vocabulary the
    /// strip's live count uses.
    static let terminalOutcomes: Set<String> = ["succeeded", "failed", "unreported"]

    /// The summary strip's counts — the same filtered rows the table
    /// shows, in the same pass (S7.1: the strip and the list never
    /// disagree).
    var stripCounts: StripCounts { derived.stripCounts }

    var isLive: Bool { core.isLive }

    /// The inspector's session. The Graph draws the whole roster rather
    /// than the table's cut, so a node picked there resolves against it.
    var selected: CoreRosterEntry? {
        pane == .graph ? roster.first { $0.id == selectedID } : rows.first { $0.id == selectedID }
    }

    // MARK: Lifecycle

    /// Whether the window is on screen — the Graph animates only then.
    private(set) var windowOpen = false

    func windowDidOpen() {
        windowOpen = true
        now = Date()
        linksClock = now
        selectedLinkID = nil
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
        windowOpen = false
        clock?.invalidate()
        clock = nil
        loadWork?.cancel()
        loadWork = nil
    }

    @ObservationIgnored private var loadWork: DispatchWorkItem?

    private func tick() {
        now = Date()
        advanceLinksClock(to: now)
        probeHoarderIfDue()
        guard core.isLive else { return }
        // Per id at most every `SessionUsageStore.freshFor`.
        refreshSessionUsage()
        // The roster is a query surface: rows move with each collector
        // snapshot, not just named events — reload on events and every
        // `refreshInterval` regardless.
        let eventID = core.lastEvent?.id
        let stale = loadedAt.map { now.timeIntervalSince($0) > Self.refreshInterval } ?? true
        if eventID != lastEventID {
            lastEventID = eventID
            scheduleLoad()
            // A fresh event naming the selected session refreshes its
            // newest timeline page — the inspector stays current without
            // a manual reload.
            if let session = core.lastEvent?.session, session == timelineSessionID {
                Task { await refreshTimeline() }
            }
        } else if stale {
            scheduleLoad()
        }
    }

    /// Event bursts coalesce into one fetch: a 300 ms trailing debounce
    /// so a state push that lands as several events triggers one
    /// `list_roster`, not one per event.
    func scheduleLoad() {
        loadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in await self?.load() }
        }
        loadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// `userInitiated` marks a deliberate refresh (toolbar, ⌘R): only it
    /// and the first populate earn the spinner — the 15 s tick and event
    /// bursts reloading under a populated table would pulse it forever.
    func load(userInitiated: Bool = false) async {
        loadWork?.cancel()
        loadWork = nil
        let showSpinner = userInitiated || roster.isEmpty
        if showSpinner { loading = true }
        defer { if showSpinner { loading = false } }
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
            resolveGitWorkspaces()
            if let pending = pendingReveal, roster.contains(where: { $0.id == pending }) {
                select(pending)
            }
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Live tail

    /// A working run's present moment for the timeline's last row — the
    /// panel's own hook fact ("running Bash", "compacting"); nil while it
    /// is not working or the hook has said nothing honest.
    nonisolated static func liveTail(for entry: CoreRosterEntry) -> String? {
        let activity = SessionActivity.reduce(entry.session)
        guard activity == .working, !entry.session.isRemote else { return nil }
        return SessionRow.activityFact(session: entry.session, activity: activity)
    }

    // MARK: Archive capture health

    /// The Data Hoarder's capture health for the connections strip — set
    /// by the app delegate; answers nil while the utility is off, which
    /// draws no archive chip.
    var hoarderProbe: (() async -> OverviewLinkage.HoarderHealth?)?
    private(set) var hoarderHealth: OverviewLinkage.HoarderHealth?
    @ObservationIgnored private var hoarderProbedAt = Date.distantPast
    @ObservationIgnored private var hoarderProbing = false
    /// A capture is slow-moving; the strip asks this often.
    static let hoarderProbeInterval: TimeInterval = 30

    func probeHoarderIfDue(force: Bool = false) {
        guard let hoarderProbe, !hoarderProbing,
              force || now.timeIntervalSince(hoarderProbedAt) >= Self.hoarderProbeInterval else { return }
        hoarderProbing = true
        hoarderProbedAt = now
        Task { [weak self] in
            let health = await hoarderProbe()
            guard let self else { return }
            self.hoarderProbing = false
            if self.hoarderHealth != health { self.hoarderHealth = health }
        }
    }

    // MARK: A day from the heatmap

    /// The heatmap's cell click: every row whose last activity fell on
    /// that day (and, from a provider's row, that provider's), in the
    /// roster pane.
    func showDay(_ iso: String, provider: String?) {
        guard let day = HistoryDayParse.date(iso) else { return }
        pane = .roster
        workerFilter = nil
        activeSavedFilter = nil
        filter = OverviewFilter(preset: .all)
        search = ""
        dayFilter = (day, provider == "all" ? nil : provider)
    }

    /// A row's last activity (`since`, the roster's last-event stamp)
    /// fell on `day`, for `provider` when one is named.
    nonisolated static func activeOn(_ day: Date, provider: String?, _ entry: CoreRosterEntry,
                                     calendar: Calendar = .current) -> Bool {
        guard let since = entry.session.since else { return false }
        if let provider, entry.session.provider != provider { return false }
        return calendar.isDate(Date(timeIntervalSince1970: since), inSameDayAs: day)
    }

    // MARK: Reveal

    /// A session another window pointed at; selected as soon as the
    /// roster that holds it has loaded.
    @ObservationIgnored private var pendingReveal: String?

    /// Show every row and select `id` — now if the roster already holds
    /// it, else when the next load lands.
    func reveal(_ id: String) {
        pane = .roster
        workerFilter = nil
        dayFilter = nil
        activeSavedFilter = nil
        filter = OverviewFilter(preset: .all)
        search = ""
        selectedLinkID = nil
        if roster.contains(where: { $0.id == id }) {
            select(id)
        } else {
            pendingReveal = id
        }
    }

    private func select(_ id: String) {
        pendingReveal = nil
        selectedID = id
        selectedIDs = [id]
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
        selectedLinkID = nil
    }

    /// ⌘↑/⌘↓: jump straight to the first or last visible row — the same
    /// discipline as `moveSelection`, staying inside the filtered set.
    func selectEdge(first: Bool) {
        guard let target = first ? rows.first : rows.last else { return }
        selectedID = target.id
        selectedIDs = [target.id]
        selectedLinkID = nil
    }

    /// The table reports its selection set; `selectedID` follows the
    /// first selected row in table order so the inspector stays stable.
    func selectionChanged(to ids: Set<String>) {
        selectedIDs = ids
        selectedID = rows.first { ids.contains($0.id) }?.id
        if !ids.isEmpty { selectedLinkID = nil }
    }

    // MARK: Compare

    /// The `compare_sessions` document for the two-row selection, shown
    /// in a sheet; nil hides it. `comparing` marks the fetch in flight.
    var comparison: CoreRunComparison?
    var comparing = false

    /// Two rows selected AND both still in the filtered set — a ghost
    /// selection (rows aged out or filtered away) must not enable a
    /// Compare that then silently no-ops.
    var canCompare: Bool {
        selectedIDs.count == 2 && rows.filter { selectedIDs.contains($0.id) }.count == 2
    }

    func compareSelected() {
        guard canCompare else { return }
        let pair = rows.filter { selectedIDs.contains($0.id) }.map(\.id)
        guard pair.count == 2 else { return }
        compare(pair[0], pair[1])
    }

    private func compare(_ a: String, _ b: String) {
        // The sheet's Model/Tokens/Cost rows read both sides' usage; ask
        // now so they fill while the comparison is computed.
        sessionUsage.refresh(ids: [a, b], force: true)
        comparing = true
        Task {
            defer { comparing = false }
            do {
                comparison = try await core.compareRuns(a, b)
            } catch {
                self.error = Self.describe(error)
            }
        }
    }

    /// The run the common question compares against: the newest run in
    /// the same folder that had already finished (done, ended or failed)
    /// before this one last spoke — "was this attempt better than the
    /// last one here?" without hunting for two rows.
    func previousRun(for entry: CoreRosterEntry) -> CoreRosterEntry? {
        guard !entry.session.remote, let cwd = entry.session.cwd, !cwd.isEmpty else { return nil }
        let before = entry.session.since ?? .greatestFiniteMagnitude
        return roster
            .filter { candidate in
                guard candidate.id != entry.id, !candidate.session.remote, candidate.session.kind == entry.session.kind,
                      candidate.session.cwd == cwd else { return false }
                let activity = SessionActivity.reduce(candidate.session)
                return (activity == .done || activity == .ended || activity == .failed)
                    && (candidate.session.since ?? 0) < before
            }
            .max { ($0.session.since ?? 0) < ($1.session.since ?? 0) }
    }

    func compareWithPreviousRun(_ entry: CoreRosterEntry) {
        guard let previous = previousRun(for: entry) else { return }
        compare(entry.id, previous.id)
    }

    // MARK: Actions on rows

    /// A transient status line for action outcomes — a receipt ("Opened
    /// fix-ci") or the refusal in the daemon's own words, never a guessed
    /// success. Cleared by the next action or the next roster load.
    var actionStatus: String?
    var actionIsError = false

    private func report(_ text: String, isError: Bool = false) {
        actionStatus = text
        actionIsError = isError
    }

    /// A remote row cannot be opened from this Mac — the inspector,
    /// the context menu and Return all gate on this.
    func canOpen(_ entry: CoreRosterEntry) -> Bool { !entry.session.remote }

    /// Open the selected session's terminal or app so the outcome reaches
    /// the user: "Opened {name}" once it is in front, the refusal on
    /// failure — never a silent `post`.
    func openSelected() {
        guard let entry = selected, canOpen(entry) else { return }
        let id = entry.id
        Task { await openSession(id) }
    }

    /// Through `SessionOpener`: the daemon, then the Dock's window
    /// locator for a running session the daemon could not find.
    func openSession(_ id: String) async {
        if let refusal = await opener(id) {
            report(refusal, isError: true)
        } else {
            report("Opened \(roster.first { $0.id == id }?.session.displayLabel ?? "the session")")
        }
    }

    /// Opening a session: `SessionOpener` in production; tests stage it.
    @ObservationIgnored var opener: @MainActor (_ session: String) async -> String? = { await SessionOpener.open($0) }

    // MARK: New session here

    /// The agents `new_session` can start: their CLIs, in the owner's
    /// own terminal.
    static let newSessionProviders: Set<String> = ["claude", "codex", "devin", "grok", "cursor", "hermes"]

    /// "New session here": a local row with a directory, of an agent
    /// whose CLI the daemon can start.
    func canStartHere(_ entry: CoreRosterEntry) -> Bool {
        !entry.session.remote && entry.session.cwd?.isEmpty == false
            && Self.newSessionProviders.contains(entry.session.provider)
    }

    /// `new_session {provider, cwd}` — explicit only: a new tab (or
    /// window) in the owner's terminal at the row's directory with the
    /// agent's CLI started; the first prompt is still theirs to type.
    /// The daemon's receipt, or its refusal, lands on the status line.
    func startSessionHere(_ entry: CoreRosterEntry) async {
        guard canStartHere(entry), let cwd = entry.session.cwd else {
            report("A new session needs a local row with a folder", isError: true)
            return
        }
        do {
            let reply = try await core.send("new_session", args: [
                "provider": .string(entry.session.provider), "cwd": .string(cwd)])
            if reply.ok {
                report(Self.startedText(reply.result, provider: entry.session.provider, cwd: cwd))
            } else {
                report(reply.error?.message ?? "New session refused", isError: true)
            }
        } catch {
            report(Self.describe(error), isError: true)
        }
    }

    /// "Started Claude in a new Ghostty tab at JR-Bar/app".
    nonisolated static func startedText(_ result: JSONValue?, provider: String, cwd: String) -> String {
        let name = ProviderStyle.style(for: provider).name
        let place = SessionRow.tail(of: cwd)
        let app = result?["app"]?.stringValue
        switch result?["raised"]?.stringValue {
        case "new_tab": return "Started \(name) in a new \(app ?? "terminal") tab at \(place)"
        case "new_window": return "Started \(name) in a new \(app ?? "terminal") window at \(place)"
        default: return "Started \(name) at \(place)"
        }
    }

    // MARK: The desk's verbs

    /// The row's ask as the desk answers it: its session filled in.
    func deskAsk(for entry: CoreRosterEntry) -> CoreAsk? {
        guard var ask = entry.session.ask else { return nil }
        if ask.session == nil { ask.session = entry.id }
        return ask
    }

    /// Always allow, from its own button — only while the agent's hook
    /// holds an ask that offers a rule to remember.
    func alwaysAllow(entry: CoreRosterEntry) async {
        guard askAction(for: entry) == .actionable, let ask = deskAsk(for: entry) else {
            report(askDisabledReason(for: entry) ?? "This ask can no longer be answered", isError: true)
            return
        }
        await answerThroughDesk(ask, .always)
    }

    /// One of a held question's options: the answer itself for a single
    /// pick, one more pick otherwise.
    func pick(_ label: String, in choice: CoreAskChoice, entry: CoreRosterEntry) async {
        guard let ask = deskAsk(for: entry), !entry.session.remote else { return }
        if let verdict = AskChoicePicks.oneClick(label, choices: ask.decision?.choices ?? []) {
            await answerThroughDesk(ask, verdict)
        } else {
            askDesk.toggle(label, in: choice, of: ask)
        }
    }

    /// Deny on a held question: the hook declines it the way Esc does,
    /// whatever hosts the session — the keystroke path's answerability
    /// does not come into it.
    func declineQuestion(entry: CoreRosterEntry) async {
        guard let ask = deskAsk(for: entry), !entry.session.remote else { return }
        await answerThroughDesk(ask, .deny)
    }

    /// Send Answers for a question with several parts.
    func sendPicks(entry: CoreRosterEntry) async {
        guard let ask = deskAsk(for: entry), let choices = ask.decision?.choices,
              let answers = askDesk.picks(for: ask).answers(choices) else {
            report("Pick an answer for every question first", isError: true)
            return
        }
        await answerThroughDesk(ask, .choose(answers))
    }

    private func answerThroughDesk(_ ask: CoreAsk, _ verdict: AskVerdict) async {
        let outcome = await askDesk.answer(ask, verdict)
        report(outcome.line, isError: !outcome.ok)
        if outcome.ok { await load() }
    }

    /// What the ask-action buttons may claim on this row. `remote` and
    /// `canAnswer == false` disable with a named reason — the UI shows
    /// the reason as a tooltip, never silently greying out (T07/T08).
    enum AskAction: Equatable {
        case actionable           // approve/deny (and reply if wantsTextReply)
        case noAsk                // nothing to answer
        case remote               // a peer's ask — answer it there
        case notAnswerable        // the daemon says this ask can't be typed
    }

    func askAction(for entry: CoreRosterEntry) -> AskAction {
        guard let ask = entry.session.ask else { return .noAsk }
        if entry.session.remote { return .remote }
        if !ask.canAnswer { return .notAnswerable }
        return .actionable
    }

    /// The disable reason a button's tooltip shows; nil when enabled.
    func askDisabledReason(for entry: CoreRosterEntry) -> String? {
        switch askAction(for: entry) {
        case .actionable: return nil
        case .noAsk: return "No open ask on this session"
        case .remote: return "A remote session — answer it on \(entry.session.origin?.label ?? "the machine it runs on")"
        case .notAnswerable: return "The monitor reports this ask cannot be answered from here"
        }
    }

    /// Whether the Reply… button is offered: the ask must accept free
    /// text AND be actionable.
    func canReply(_ entry: CoreRosterEntry) -> Bool {
        askAction(for: entry) == .actionable && entry.session.ask?.wantsTextReply == true
    }

    /// Approve or Deny, from an explicit button, through the desk: the
    /// ask's `request` pinned so a stale card can never approve its
    /// replacement, one pending set with every other surface, and the
    /// daemon's refusal (`stale_request`, `not_frontmost`, …) on the
    /// status line — never a guessed success.
    func answerAsk(entry: CoreRosterEntry, approve: Bool) async {
        guard askAction(for: entry) == .actionable, let ask = deskAsk(for: entry) else {
            report(askDisabledReason(for: entry) ?? "This ask can no longer be answered", isError: true)
            return
        }
        await answerThroughDesk(ask, approve ? .approve : .deny)
    }

    /// A typed reply to a `replyable` ask: `answer_ask` with `reply_text`,
    /// awaited, the request pinned — the one answer the desk has no
    /// verdict for yet. The daemon's refusal is surfaced verbatim.
    func reply(entry: CoreRosterEntry, text: String) async {
        // A silent early-return leaves actionIsError false, and the reply
        // sheet reads that as "sent" — dismissing and dropping the draft.
        // A stale ask must refuse loudly instead.
        guard canReply(entry) else {
            report(askDisabledReason(for: entry) ?? "This ask no longer takes a reply", isError: true)
            return
        }
        do {
            let reply = try await core.answerAskNow(
                session: entry.id, approve: true,
                replyText: text, request: entry.session.ask?.request)
            if reply.ok {
                report(AskAnswerLine.replied(reply))
                await load()
            } else {
                report(reply.error?.message ?? "Reply refused", isError: true)
            }
        } catch {
            report(Self.describe(error), isError: true)
        }
    }

    /// `dismiss_session`: acknowledge a live-but-going-nowhere row until
    /// it next speaks — the "mark reviewed" affordance. The daemon
    /// refuses rows pinned by an open ask and remote rows; the refusal
    /// string is shown verbatim.
    func markReviewed(entry: CoreRosterEntry) async {
        do {
            let reply = try await core.dismissSession(entry.id)
            if reply.ok {
                report("Marked reviewed — returns if the session speaks again")
                await load()
            } else {
                report(reply.error?.message ?? "Dismiss refused", isError: true)
            }
        } catch {
            report(Self.describe(error), isError: true)
        }
    }

    /// `snooze {session, seconds}` — `CoreModel.snooze` is `post`-only
    /// (no reply), so this goes through `send` to surface the refusal.
    func snooze(entry: CoreRosterEntry, seconds: Int = 3600) async {
        do {
            let reply = try await core.send("snooze", args: [
                "session": .string(entry.id), "seconds": .number(Double(seconds))])
            if reply.ok {
                let until = reply.result?["until"]?.doubleValue
                report(until.map { "Snoozed until \(Self.clockTime(Date(timeIntervalSince1970: $0)))" }
                       ?? "Snoozed 1 hour")
                await load()
            } else {
                report(reply.error?.message ?? "Snooze refused", isError: true)
            }
        } catch {
            report(Self.describe(error), isError: true)
        }
    }

    /// `clear_completed` + its undo window — toolbar actions whose
    /// receipts ("cleared N", "restored N", or the refusal) land on the
    /// status line.
    func clearCompleted() async {
        do {
            let reply = try await core.clearCompletedNow()
            if reply.ok {
                let cleared = reply.result?["cleared"]?.arrayValue?.count ?? 0
                report(cleared > 0 ? "Cleared \(cleared) completed — undo available"
                                   : "Nothing to clear")
                await load()
            } else {
                report(reply.error?.message ?? "Clear refused", isError: true)
            }
        } catch {
            report(Self.describe(error), isError: true)
        }
    }

    func undoClear() async {
        do {
            guard let reply = try await core.undoClear() else {
                report("Nothing to undo — the undo window has passed", isError: true)
                return
            }
            if reply.ok {
                let restored = reply.result?["restored"]?.arrayValue?.count ?? 0
                report("Restored \(restored) sessions")
                await load()
            } else {
                report(reply.error?.message ?? "Undo refused", isError: true)
            }
        } catch {
            report(Self.describe(error), isError: true)
        }
    }

    // MARK: Row honesty helpers

    /// "waiting 23m" — the age of the row's open ask (`ask.openedAt`),
    /// the one duration that matters on a waiting row. nil without ask.
    static func waitingText(_ entry: CoreRosterEntry, now: Date) -> String? {
        guard let openedAt = entry.session.ask?.openedAt else { return nil }
        let seconds = max(0, now.timeIntervalSince1970 - openedAt)
        return "waiting \(AgentMonitorFeed.ageText(seconds))"
    }

    /// The family mailbox's snooze still covers this session.
    static func isSnoozed(_ entry: CoreRosterEntry, now: Date) -> Bool {
        guard let until = entry.session.snoozedUntil else { return false }
        return until > now.timeIntervalSince1970
    }

    /// "Snoozed until 2:30 PM" for the snoozed chip's tooltip.
    static func snoozeWakeText(_ entry: CoreRosterEntry) -> String? {
        entry.session.snoozedUntil.map { "Snoozed until \(clockTime(Date(timeIntervalSince1970: $0)))" }
    }

    /// The time of day in the reader's own 12- or 24-hour clock.
    static func clockTime(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
    }

    /// `state.unseen_completions`: ids of rows that finished since the
    /// user last looked — the same dot the panel gives them (PanelStore).
    var unseenCompletionIDs: Set<String> {
        guard core.isLive else { return [] }
        return Set(core.state?.unseenCompletions ?? [])
    }

    /// The unseen dot belongs on finished rows only — same rule as the
    /// panel (`row.activity == .done`).
    func showsUnseenDot(_ entry: CoreRosterEntry) -> Bool {
        SessionActivity.reduce(entry.session) == .done
            && unseenCompletionIDs.contains(entry.id)
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
    ///
    /// By default the bundle is what the window shows: two or more
    /// selected rows export as themselves, otherwise the rows the current
    /// cut keeps (preset or saved view, project, workers, search). The
    /// daemon narrows its roster and activity to those ids and names the
    /// slice in the bundle's gaps. `everything` is the old whole-fleet
    /// export, still one menu item away.
    func prepareExport(everything: Bool = false) async {
        let args = everything ? Self.exportArgs(ids: nil, view: nil) : exportScope.args
        do {
            let json = try await exportAudit(args: args, format: "json")
            let markdown = try await exportAudit(args: args, format: "markdown")
            exportPreview = (json.document, markdown.text ?? "")
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// The ids and the view's name an on-screen export carries.
    var exportScope: (args: [String: JSONValue], label: String) {
        let selected = rows.filter { selectedIDs.contains($0.id) }
        let slice = selected.count >= 2 ? selected : rows
        let label = selected.count >= 2 ? "\(selected.count) selected rows of \(viewLabel)" : viewLabel
        return (Self.exportArgs(ids: slice.map(\.id), view: label), label)
    }

    /// "Failed · JR-Bar/app · search “auth”" — the cut, in the sidebar's
    /// words, for the export's scope line.
    var viewLabel: String {
        var parts: [String] = []
        if let saved = activeSavedFilter {
            parts.append("saved view “\(saved)”")
        } else if filter.preset == .thisProject, let project = filter.project {
            parts.append("project \(project)")
        } else if filter.preset == .thisBranch, let branch = filter.branch {
            parts.append("branch \(branch)")
        } else {
            parts.append(filter.preset.label)
        }
        if let parent = workerFilter {
            let name = roster.first { $0.id == parent }.map { $0.session.label ?? $0.session.shortId ?? parent } ?? parent
            parts.append("workers of \(name)")
        }
        if let day = dayFilter {
            parts.append("active \(HistoryDayParse.title(day.day))" + (day.provider.map { " · \(SessionLabel.providerName($0))" } ?? ""))
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { parts.append("search “\(query)”") }
        return parts.joined(separator: " · ")
    }

    nonisolated static func exportArgs(ids: [String]?, view: String?) -> [String: JSONValue] {
        var args: [String: JSONValue] = ["scope": .string("all")]
        if let ids { args["ids"] = .array(ids.map(JSONValue.string)) }
        if let view { args["view"] = .string(view) }
        return args
    }

    private func exportAudit(args: [String: JSONValue], format: String) async throws -> (document: JSONValue, text: String?) {
        var args = args
        args["format"] = .string(format)
        let reply = try await core.send("audit_export", args: args)
        guard reply.ok else { throw reply.error ?? CoreReplyError(code: "error", message: "audit_export failed") }
        guard let result = reply.result else {
            throw CoreReplyError(code: "bad_reply", message: "audit_export: missing result")
        }
        return (result["document"] ?? .object([:]), result["text"]?.stringValue)
    }

    // MARK: Export this run

    /// One run's Markdown, previewed before a destination is chosen: the
    /// roster's and the transcript's facts over the timeline the
    /// inspector shows (the archived copy when the live one is gone).
    var runExportPreview: (name: String, markdown: String)?

    func prepareRunExport(_ entry: CoreRosterEntry, generatedAt: Date = Date()) {
        guard let markdown = runMarkdown(for: entry, generatedAt: generatedAt) else { return }
        let base = (entry.session.label ?? entry.session.shortId ?? "session")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .joined(separator: "-").lowercased()
        runExportPreview = ((base.isEmpty ? "session" : String(base.prefix(60))) + ".md", markdown)
    }

    /// The Markdown for a row whose timeline is loaded; nil otherwise.
    func runMarkdown(for entry: CoreRosterEntry, generatedAt: Date = Date()) -> String? {
        guard timelineSessionID == entry.id, let page = timelinePage, !entry.session.remote else { return nil }
        let session = entry.session
        let reconstruction: SessionReconstruction
        var notes: [String] = []
        if let archived = archivedTimeline, archived.id == entry.id {
            reconstruction = archived.reconstruction
            notes.append("From the Data Hoarder's archived copy (\(archived.record.name)); the live transcript is gone.")
        } else {
            reconstruction = timelineReconstruction
            if page.hasMore {
                notes.append("Only the rows loaded in the inspector are here; Load earlier there to include older ones.")
            }
        }
        let when = DateFormatter()
        when.dateFormat = "yyyy-MM-dd HH:mm"
        var facts: [SessionMarkdown.Fact] = [.init("Provider", SessionLabel.providerName(session.provider))]
        facts.append(.init("State", SessionActivity.reduce(session).word))
        if let cwd = session.cwd { facts.append(.init("Folder", cwd)) }
        if let head = workspace(for: entry)?.headLabel { facts.append(.init("Branch", head)) }
        if let since = session.since { facts.append(.init("Last activity", when.string(from: Date(timeIntervalSince1970: since)))) }
        if let usage = usage(for: entry) {
            if let model = usage.modelName { facts.append(.init("Model", model)) }
            if usage.tokens.total > 0 {
                facts.append(.init("Tokens", "\(UsageFormat.tokens(usage.tokens.total)) in \(usage.turns) turn\(usage.turns == 1 ? "" : "s")"))
            }
            if let cost = usage.costText {
                facts.append(.init("Cost", cost + " (API-equivalent estimate\(usage.costEstimated ? ", stand-in rate" : ""))"))
            }
            if let context = usage.contextText { facts.append(.init("Context", context)) }
        } else if let model = transcriptModel {
            facts.append(.init("Model", ModelName.display(model) ?? model))
        }
        facts.append(.init("Session", entry.id))
        return SessionMarkdown.render(
            title: SessionLabel.display(label: session.label, shortId: session.shortId, id: entry.id, provider: session.provider),
            facts: facts, reconstruction: reconstruction, notes: notes, generatedAt: generatedAt)
    }

    func saveRunExport(to url: URL) throws {
        guard let preview = runExportPreview else { return }
        try Data(preview.markdown.utf8).write(to: url, options: .atomic)
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
    /// The last load ended in the error path — reselecting retries.
    var timelineFailed = false

    /// Load the newest page for the given roster row id.
    func loadTimeline(for id: String) async {
        // A failed load leaves a gaps-only page — reselecting the row
        // must retry rather than trusting the error artifact forever.
        guard timelineSessionID != id || timelinePage == nil || timelineFailed else { return }
        timelineSessionID = id
        timeline = []
        timelinePage = nil
        timelineFailed = false
        timelineLoading = true
        defer { timelineLoading = false }
        let fallback = timelineFallback(for: id)
        archivedTimeline = nil
        do {
            let page = try await core.sessionTimeline(
                id: id, provider: fallback.provider,
                session: fallback.session, cwd: fallback.cwd)
            guard timelineSessionID == id else { return }
            timeline = page.events
            timelinePage = page
            if page.gaps.contains("transcript_not_found") {
                await loadArchivedTimeline(for: id)
            } else {
                await loadProxyEvidence(for: id)
            }
        } catch {
            guard timelineSessionID == id else { return }
            timelinePage = CoreTimelinePage(gaps: [Self.describe(error)])
            timelineFailed = true
        }
    }

    /// The `session`/`provider`/`cwd` the daemon needs to resolve a
    /// transcript once the roster row is gone — `provider:session:<id>`
    /// agent ids carry the session id as the `:` tail (same convention
    /// `archiveSearchTerm` uses); other shapes send no session guess.
    private func timelineFallback(for id: String) -> (provider: String?, session: String?, cwd: String?) {
        guard let entry = rows.first(where: { $0.id == id }) else {
            return (nil, nil, nil)
        }
        let parts = id.split(separator: ":")
        let session = parts.count >= 3 ? String(parts.last!) : nil
        return (entry.session.provider, session, entry.session.cwd)
    }

    /// The next older page, prepended — transcript reads are bounded so
    /// "Load earlier" is the only way deep history enters the window.
    /// The merged page keeps BOTH pages' gaps: the older page's gaps
    /// describe the region just read, the newest page's the region
    /// already shown — dropping either would hide a named gap.
    func loadEarlierTimeline() async {
        guard let id = timelineSessionID,
              let page = timelinePage, page.hasMore,
              let before = page.nextBefore, !timelineLoading else { return }
        timelineLoading = true
        defer { timelineLoading = false }
        let fallback = timelineFallback(for: id)
        do {
            let older = try await core.sessionTimeline(
                id: id, before: before, provider: fallback.provider,
                session: fallback.session, cwd: fallback.cwd)
            guard timelineSessionID == id else { return }
            // A re-sequenced or overlapping page must not double a seq —
            // the list's ForEach ids on seq and duplicate ids corrupt it.
            let known = Set(timeline.map(\.seq))
            timeline = older.events.filter { !known.contains($0.seq) } + timeline
            timelinePage = Self.mergeTimelinePage(older: older, into: page, events: timeline)
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// The merged page after an older page is prepended: the older
    /// page's continuation cursor, both pages' gaps (newest page's
    /// first, no duplicates), the newest page's source identity.
    /// `events` keeps ONLY the newest page's slice — refreshTimeline
    /// derives the older-prefix length as `timeline.count - events.count`,
    /// so storing the merged array would zero that delta and drop the
    /// pages the user already pulled.
    static func mergeTimelinePage(older: CoreTimelinePage, into page: CoreTimelinePage,
                                  events: [CoreTimelineItem]) -> CoreTimelinePage {
        CoreTimelinePage(
            events: page.events, hasMore: older.hasMore,
            nextBefore: older.nextBefore, total: older.total,
            provider: page.provider, file: page.file,
            gaps: page.gaps + older.gaps.filter { !page.gaps.contains($0) })
    }

    /// Re-reads the newest page in place: older pages the user already
    /// pulled stay put (they occupy the front of `timeline`), the tail
    /// slice that was the newest page is swapped for the fresh events.
    /// Same `timelineSessionID` guard as the other loads.
    func refreshTimeline() async {
        guard let id = timelineSessionID, let page = timelinePage, !timelineLoading else { return }
        timelineLoading = true
        defer { timelineLoading = false }
        let fallback = timelineFallback(for: id)
        do {
            let fresh = try await core.sessionTimeline(
                id: id, provider: fallback.provider,
                session: fallback.session, cwd: fallback.cwd)
            guard timelineSessionID == id else { return }
            let olderCount = max(0, timeline.count - page.events.count)
            // Dedupe the join: a transcript that grew since the older page
            // was pulled can push its items onto the fresh page — the same
            // seq would land in both halves and ForEach ids must be unique.
            let freshSeqs = Set(fresh.events.map(\.seq))
            let kept = Array(timeline.prefix(olderCount)).filter { !freshSeqs.contains($0.seq) }
            timeline = kept + fresh.events
            // The stored page keeps ONLY the fresh slice — the next refresh
            // derives the older-prefix length from `timeline.count -
            // page.events.count`, so storing the merged array would zero
            // that delta and silently drop the pulled pages.
            timelinePage = CoreTimelinePage(
                events: fresh.events, hasMore: fresh.hasMore,
                nextBefore: fresh.nextBefore, total: fresh.total,
                provider: fresh.provider ?? page.provider,
                file: fresh.file ?? page.file,
                gaps: fresh.gaps + page.gaps.filter { !fresh.gaps.contains($0) })
        } catch {
            guard timelineSessionID == id else { return }
            self.error = Self.describe(error)
        }
    }

    // MARK: Timeline view + facts

    /// The inspector timeline's kind chips and gap disclosure — the
    /// shared timeline view's state, owned here so it survives redraws.
    let timelineViewState = ReconstructedTimelineViewState()

    /// The loaded transcript as the shared timeline view draws it. A
    /// running session's last row is mid-turn by definition, so its story
    /// never calls that a death. Memoized on what it is built from.
    var timelineReconstruction: SessionReconstruction {
        let running = selected.map { entry -> Bool in
            let activity = SessionActivity.reduce(entry.session)
            return activity == .working || activity == .waiting || activity == .idle
        } ?? false
        let requests = proxyEvidence?.id == timelineSessionID ? proxyEvidence?.requests ?? [] : []
        let key = TimelineReconstructionKey(
            session: timelineSessionID, count: timeline.count, first: timeline.first?.seq,
            last: timeline.last?.seq, gaps: timelinePage?.gaps ?? [], running: running,
            requests: requests.count)
        if let cached = timelineReconstructionCache, cached.key == key { return cached.value }
        let value = SessionReconstructor.reconstruction(from: timeline, gaps: key.gaps, running: running)
            .withProxyRequests(requests)
        timelineReconstructionCache = (key, value)
        return value
    }
    private struct TimelineReconstructionKey: Equatable {
        var session: String?
        var count: Int
        var first, last: Int?
        var gaps: [String]
        var running: Bool
        var requests: Int
    }
    @ObservationIgnored private var timelineReconstructionCache: (key: TimelineReconstructionKey, value: SessionReconstruction)?

    /// The transcript's last stated model — surfaced in the inspector as
    /// "Model (transcript)" so the source is named honestly.
    var transcriptModel: String? { timeline.last { $0.model != nil }?.model }

    // MARK: Archive (Data Hoarder) honesty

    /// Probes whether a transcript path is covered by the local Data
    /// Hoarder archive. Set by the app delegate to the hoarder's
    /// `archive.captureState(path:)`; nil → the inspector hides the
    /// archive facts rather than claim a status it cannot know.
    var archiveProbe: ((String) async -> CaptureStateRow?)?
    /// Opens the Data Hoarder window seeded with a search term.
    var onOpenArchive: ((String) -> Void)?
    /// Probe results per path — one lookup per transcript, not per render.
    var archiveStates: [String: CaptureStateRow?] = [:]

    func probeArchive(file: String) async {
        guard archiveStates[file] == nil, let archiveProbe else { return }
        archiveStates[file] = await archiveProbe(file)
    }

    /// Rebuilds a session's archived transcript by its uuid — set by the
    /// app delegate to the Data Hoarder's reader; nil hides the fallback.
    var archiveTimeline: ((String) async -> (SessionReconstruction, ArchiveRecord)?)?
    /// The CLIProxyAPI requests the archive holds under a session uuid —
    /// set by the app delegate; nil leaves the live timeline as it is.
    var archiveProxyEvidence: ((String) async -> [CLIProxyRequest])?
    /// The proxy evidence for the timeline on screen, keyed by row id.
    private(set) var proxyEvidence: (id: String, requests: [CLIProxyRequest])?

    /// The proxy's side of the selected run, when the archive kept it:
    /// the live timeline interleaves those requests between its turns.
    func loadProxyEvidence(for id: String) async {
        guard let archiveProxyEvidence,
              let entry = rows.first(where: { $0.id == id }) ?? roster.first(where: { $0.id == id }) else { return }
        let requests = await archiveProxyEvidence(Self.archiveSearchTerm(for: entry))
        guard timelineSessionID == id else { return }
        proxyEvidence = (id, requests)
    }
    /// The archived copy standing in for a transcript that is gone: the
    /// row it belongs to, the rebuilt timeline and the record it came from.
    private(set) var archivedTimeline: (id: String, reconstruction: SessionReconstruction, record: ArchiveRecord)?

    /// An ended session whose transcript was cleaned up or moved still has
    /// a story when the Data Hoarder kept it: rebuild that copy and show it
    /// in the same timeline view, labelled as the archive's.
    func loadArchivedTimeline(for id: String) async {
        guard let archiveTimeline,
              let entry = rows.first(where: { $0.id == id }) ?? roster.first(where: { $0.id == id }) else { return }
        let sessionID = Self.archiveSearchTerm(for: entry)
        guard let found = await archiveTimeline(sessionID), timelineSessionID == id else { return }
        archivedTimeline = (id, found.0, found.1)
    }

    /// The term "Search archive for this session" seeds the hoarder
    /// with: the session's uuid tail — transcripts are filed under it,
    /// so a path/name/content search finds the same session's records.
    static func archiveSearchTerm(for entry: CoreRosterEntry) -> String {
        let id = entry.id
        return id.split(separator: ":").last.map(String.init) ?? id
    }

    // MARK: Observed tools

    /// The tools and MCP servers the selected run called, from its loaded
    /// transcript — the Overview's relationship lens.
    var observedTools: ObservedToolMap { ObservedToolMap.build(from: timeline) }

    // MARK: Usage pane

    /// Which workspace the content column shows — the roster table or
    /// the Usage graph. Sidebar rows pick it; `filter`/`saved` only
    /// apply to the roster.
    enum Pane: String, Hashable {
        case roster, usage, graph
    }
    var pane: Pane = .roster

    // MARK: Graph pane

    /// What the Graph draws: what is happening now, or every row on record.
    enum GraphScope: String, CaseIterable, Identifiable {
        case active = "Active"
        case everything = "Everything"
        var id: String { rawValue }
    }
    var graphScope: GraphScope = .active
    /// How long a finished run stays on the Active graph.
    static let graphFinishedWindow: TimeInterval = 3_600

    /// The sidebar's Graph row. The selection carries over when the
    /// session is on record, so the inspector keeps what it showed.
    func showGraph() {
        pane = .graph
        if let id = selectedID, !roster.contains(where: { $0.id == id }) {
            selectedID = nil
            selectedIDs = []
        }
    }

    /// The Graph's sessions. Active keeps everything live — working,
    /// asking, failed, idle — plus runs that finished in the last hour,
    /// and the parent of any worker it keeps, so a family never floats
    /// loose. Everything is the whole record, rows the panel's aging
    /// hides included. The sidebar's search applies to both.
    var graphNodes: [OverviewGraphNode] {
        // Only Active's one-hour horizon needs the clock. Everything must
        // not read it, or the whole record would lay out again each second.
        let clock = graphScope == .active ? now : .distantFuture
        return Self.graphEntries(roster, scope: graphScope, search: search, now: clock).map(OverviewGraphNode.init)
    }

    static func graphEntries(_ roster: [CoreRosterEntry], scope: GraphScope, search: String,
                             now: Date) -> [CoreRosterEntry] {
        let searched = roster.filter { search.isEmpty || matchesSearch($0, search) }
        guard scope == .active else { return searched }
        let horizon = now.timeIntervalSince1970 - graphFinishedWindow
        var kept = Set(searched.filter { entry in
            guard entry.visibility != "hidden" else { return false }
            switch SessionActivity.reduce(entry.session) {
            case .working, .waiting, .failed, .idle: return true
            case .done, .ended: return (entry.session.updatedAt ?? entry.session.since ?? 0) >= horizon
            }
        }.map(\.id))
        let byID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in kept {
            var parent = byID[id]?.session.parent
            var hops = 0
            while let next = parent, hops < 8, let entry = byID[next] {
                kept.insert(next)
                parent = entry.session.parent
                hops += 1
            }
        }
        return roster.filter { kept.contains($0.id) }
    }

    /// One click on a node: it becomes the inspector's session.
    func selectInGraph(_ id: String?) {
        selectedID = id
        selectedIDs = id.map { [$0] } ?? []
        if id != nil { selectedLinkID = nil }
    }

    /// A node's "Show in Roster": the table, cut to everything on record,
    /// with that row selected.
    func showInRoster(_ id: String) {
        pane = .roster
        workerFilter = nil
        dayFilter = nil
        activeSavedFilter = nil
        filter = OverviewFilter(preset: .all)
        search = ""
        selectionChanged(to: [id])
    }

    /// The `usage_graph` document — the shared-axis multi-provider
    /// chart the daemon computes from local transcripts. The pane asks
    /// per-request: a pick here never rewrites the stored settings.
    var graph: CoreUsageGraphDocument?
    var graphLoading = false
    var graphError: String?
    /// When the current document was fetched — the usage pane re-asks
    /// once it's stale rather than showing yesterday's chart as fresh.
    var graphLoadedAt: Date?
    /// The doc cache answers an unchanged corpus in well under a second,
    /// so staleness can be cheaply re-checked on every pane entry.
    static let graphStalenessHorizon: TimeInterval = 60
    /// Which request `graph` belongs to — a stale reply cannot
    /// overwrite a newer pick's document (same discipline as
    /// `timelineSessionID`).
    var graphRequestKey: String?
    /// One `usage_graph` at a time. The daemon runs this client's
    /// commands in order, so every extra scan queues ahead of each
    /// Approve; a pick made mid-scan only marks `graphFollowUp`, and the
    /// running load asks once more, with the latest picks, when it lands.
    @ObservationIgnored private(set) var graphInFlight = false
    @ObservationIgnored private var graphFollowUp = false
    /// The `usage_graph` round trip, replaceable in tests.
    @ObservationIgnored var fetchGraph: @MainActor (_ days: Int, _ metric: String, _ providers: [String]?)
        async throws -> CoreUsageGraphDocument
    var graphDays = 30
    /// `tokens` | `cost` | `sessions` | `percent`.
    var graphMetric = "tokens"
    /// nil = the daemon's stored provider set; once the user toggles,
    /// the explicit set is what gets asked for.
    var graphProviders: [String]?
    /// Chartable provider ids for the picker — the daemon's registry
    /// plus any series-only source (t3code) a reply names.
    var graphProviderOptions: [String] = []
    var graphProvidersLoaded = false

    /// The sidebar's Usage row.
    func showUsage() {
        pane = .usage
        Task { await loadGraphProvidersIfNeeded() }
        let stale = graphLoadedAt.map { Date().timeIntervalSince($0) > Self.graphStalenessHorizon } ?? true
        if graph == nil || stale { Task { await loadGraph() } }
    }

    /// The request key for the current picks.
    var graphPickKey: String {
        "\(graphDays)|\(graphMetric)|\((graphProviders ?? []).joined(separator: ","))"
    }

    /// Fetch the chart for the current picks. Slow on a cold transcript
    /// cache (~30s) — the view shows its scanning state meanwhile. A call
    /// while one is out returns at once: the running load asks again
    /// with the newest picks when its reply lands, so any number of
    /// picker clicks during a scan cost one more scan, not one each.
    func loadGraph() async {
        graphRequestKey = graphPickKey
        graphLoading = true
        guard !graphInFlight else {
            graphFollowUp = true
            return
        }
        graphInFlight = true
        defer {
            graphInFlight = false
            graphLoading = false
        }
        repeat {
            graphFollowUp = false
            let days = graphDays, metric = graphMetric, providers = graphProviders
            let key = graphPickKey
            graphRequestKey = key
            let outcome: Result<CoreUsageGraphDocument, Error>
            do {
                outcome = .success(try await fetchGraph(days, metric, providers))
            } catch {
                outcome = .failure(error)
            }
            // Picks that moved and came back leave this reply current.
            if graphFollowUp, graphPickKey == key { graphFollowUp = false }
            if graphFollowUp { continue }
            switch outcome {
            case .success(let document):
                graph = document
                graphLoadedAt = Date()
                graphError = nil
                // A reply can name a source the registry did not (t3code
                // appears only when its T3 coverage exists).
                for id in document.graph.providers + document.graph.series.map(\.providerId)
                where !graphProviderOptions.contains(id) {
                    graphProviderOptions.append(id)
                }
            case .failure(let error):
                graphError = Self.describe(error)
            }
        } while graphFollowUp
    }

    /// The provider picker's option set — the daemon's registry, so an
    /// unchecked-but-chartable provider is still offered.
    func loadGraphProvidersIfNeeded() async {
        guard !graphProvidersLoaded else { return }
        do {
            let rows = try await core.listProviders()
            var seen = Set<String>()
            graphProviderOptions = rows.map(\.id).filter { seen.insert($0).inserted }
            graphProvidersLoaded = true
        } catch {
            // The picker falls back to the ids the graph itself names.
            // Keep the stale options on failure — wiping them on a
            // transient error discards ids (t3code) no registry lists.
            graphProvidersLoaded = false
        }
    }

    /// The provider set the checkmarks show: the explicit pick, else
    /// the resolved set the last reply charted, else every option.
    var graphCheckedProviders: Set<String> {
        if let graphProviders { return Set(graphProviders) }
        if let graph, !graph.graph.providers.isEmpty { return Set(graph.graph.providers) }
        return Set(graphProviderOptions)
    }

    func setGraphDays(_ days: Int) {
        guard graphDays != days else { return }
        graphDays = days
        Task { await loadGraph() }
    }

    func setGraphMetric(_ metric: String) {
        guard graphMetric != metric else { return }
        graphMetric = metric
        Task { await loadGraph() }
    }

    /// Toggling the first time pins the effective set explicitly — the
    /// stored default stays untouched daemon-side.
    func toggleGraphProvider(_ id: String) {
        var checked = graphCheckedProviders
        if checked.contains(id) {
            // An empty set is not a request the daemon will honour —
            // keep the last provider checked rather than chart nothing.
            guard checked.count > 1 else { return }
            checked.remove(id)
        } else {
            checked.insert(id)
        }
        // Registry order so the picker's chips and the request agree.
        let ordered = graphProviderOptions.filter { checked.contains($0) }
            + checked.subtracting(graphProviderOptions).sorted()
        graphProviders = ordered
        Task { await loadGraph() }
    }

    // MARK: Search

    /// Titles, project labels, tool and event names, the row's own
    /// message, the open ask's summary, the record axes' words
    /// ("failed", "unreviewed"), the session kind, and the parent
    /// session's id — the retained evidence the daemon already
    /// surfaced, never a repository crawl (S7.1).
    static func matchesSearch(_ entry: CoreRosterEntry, _ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let session = entry.session
        let haystacks: [String?] = [
            session.id, session.label, session.shortId, session.cwd,
            OverviewFilter.projectName(of: session.cwd),
            session.tool, session.event, session.message,
            session.origin?.label, session.provider,
            session.ask?.summary, session.kind, session.parent,
            entry.axes?.outcome, entry.axes?.review, entry.axes?.freshness,
            entry.visibility,
        ]
        return haystacks.contains { $0?.lowercased().contains(needle) == true }
    }

    static func describe(_ error: Error) -> String {
        (error as? CoreReplyError)?.message ?? error.localizedDescription
    }
}

extension CoreRosterEntry {
    /// The default sort: a live ask pins the row to the top (0), then
    /// the session's own state rank — waiting, failed, working, done,
    /// ended, idle — so the table opens attention-first, failures
    /// second, without a column click. The panel's rows use the same
    /// precedence, so the table and the shelf tell one story.
    var sortRankKey: Int {
        if pinned || session.ask != nil { return 0 }
        return SessionActivity.reduce(session).sortRank + 1
    }

    // Table sort keys — each column's comparator maps to one stable value
    // so clicking a header re-orders the whole filtered set deterministically.
    var labelSortKey: String { session.label ?? session.shortId ?? "" }
    var projectSortKey: String { OverviewFilter.projectName(of: session.cwd) ?? "" }
    var stateSortKey: Int { sortRankKey }
    /// The model `session_usage` read from the run's transcript ("Opus
    /// 4.5"); a row nobody has read sorts first, as "".
    var modelSortKey: String { SessionUsageIndex.shared.model(for: id) ?? "" }
    /// The run's cost estimate; unread or unpriced sorts below any price.
    var costSortKey: Double { SessionUsageIndex.shared.cost(for: id) ?? -1 }
    var activitySortKey: String { session.event ?? session.tool ?? "" }
    /// `since` is the row's last-event stamp (updated_at), not a start
    /// time — the column is "Quiet": how long since the session last
    /// spoke. Negated so ascending puts the most recently heard-from
    /// first (quietest last), matching how a stale row should sink.
    var elapsedSortKey: Double { -(session.since ?? 0) }
    var freshnessSortKey: String { axes?.freshness ?? (session.stale ? "stale" : "live") }
    var attentionSortKey: Int { (pinned || session.ask != nil) ? 0 : 1 }
}
