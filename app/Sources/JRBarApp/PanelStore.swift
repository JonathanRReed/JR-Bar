import AppKit
import Foundation
import JRBarCore
import Observation

/// One line in the Sessions section.
struct SessionRow: Identifiable, Equatable {
    let id: String
    let style: ProviderStyle
    let label: String
    /// The session's full working directory, for the tooltip and the
    /// context menu's Copy / Reveal; `cwdTail` is what the row shows.
    let cwd: String?
    let cwdTail: String?
    /// The terminal the daemon says owns the session (`terminal.app`),
    /// for "Open in Ghostty"; nil when it does not know.
    let terminalApp: String?
    /// The family mailbox's snooze expiry (`snoozed_until`), while one is
    /// in effect; the row offers Unsnooze and says when it ends.
    let snoozedUntil: Double?
    let activity: SessionActivity
    let since: Date?
    let workers: Int
    /// "10 workers", "1 worker"; nil with none.
    var workersText: String? {
        workers <= 0 ? nil : (workers == 1 ? "1 worker" : "\(workers) workers")
    }
    let ask: CoreAsk?
    let stale: Bool
    /// A peer's session mirrored onto this Mac (`remote:<machine>:…`):
    /// informational only — nothing here can raise its window or type an
    /// answer into it.
    let isRemote: Bool
    /// The machine a remote row runs on, for the "on studio-mac" line.
    let remoteMachine: String?
    /// The hook's last word about a working row, humanised ("running
    /// Bash", "compacting"); nil when there is nothing honest to say.
    let activityFact: String?
    /// What a live working row's agent is doing, for its orb; nil on
    /// every other row (`AgentActivity.forRow`).
    let agentActivity: AgentActivity?
    /// Where the session was launched from (`origin.label`: "VS Code",
    /// "cloud ingest"), shown as the subtitle's quiet "via …" tail.
    let originLabel: String?
    /// The run's model, tokens, cost and context from its own transcript
    /// (`session_usage`), once read; nil until then and for providers
    /// whose transcripts are not read.
    var usage: SessionUsage?

    init(session: CoreSession, pinnedAsk: CoreAsk?, document: SettingsDocument? = nil) {
        id = session.id
        style = ProviderStyle.style(for: session.provider, document: document)
        label = session.displayLabel
        isRemote = session.isRemote
        remoteMachine = session.remoteMachine
        // A remote path is not this Mac's filesystem: copying or revealing
        // it would lie, so remote rows carry no cwd at all.
        cwd = session.isRemote ? nil : session.cwd
        cwdTail = session.isRemote ? nil : session.cwd.map { Self.tail(of: $0) }
        terminalApp = session.terminal?.app
        snoozedUntil = session.snoozedUntil
        activity = SessionActivity.reduce(session)
        activityFact = Self.activityFact(session: session, activity: activity)
        agentActivity = AgentActivity.forRow(session: session, activity: activity)
        // A peer's origin is the peer's fact: "via VS Code" on a remote row
        // would name this Mac's apps for another machine's session.
        originLabel = session.isRemote ? nil : Self.shortFact(session.origin?.label, limit: 32)
        since = session.since.map { Date(timeIntervalSince1970: $0) }
        workers = session.workers
        ask = pinnedAsk ?? session.ask.map { ask in
            var ask = ask
            ask.session = session.id
            return ask
        }
        stale = session.stale
    }

    /// An ask the daemon reports for a session that is not in
    /// `state.sessions` — cleared, or acknowledged out from under a still
    /// open request. The header counts it and the light pulses amber for
    /// it, so it must never be the one thing the panel does not show; the
    /// id is all there is, and Approve / Deny still answer it.
    init(orphanAsk ask: CoreAsk, document: SettingsDocument? = nil) {
        let session = ask.session ?? ""
        // A remote ask's id is `remote:<machine>:<provider>:…`; taking the
        // first segment would call its provider "remote".
        let remote = CoreSession.isRemoteID(session)
        let provider = remote ? String(session.split(separator: ":").dropFirst(2).first ?? "")
                              : String(session.split(separator: ":").first ?? "")
        id = session.isEmpty ? ask.id : session
        style = ProviderStyle.style(for: provider, document: document)
        label = SessionLabel.display(label: nil, shortId: nil, id: session, provider: provider)
        cwd = nil
        cwdTail = nil
        terminalApp = nil
        snoozedUntil = nil
        activity = .waiting
        since = ask.openedAt.map { Date(timeIntervalSince1970: $0) }
        workers = 0
        self.ask = ask
        stale = false
        isRemote = remote
        remoteMachine = CoreSession.remoteMachine(inID: session)
        activityFact = nil
        agentActivity = nil
        originLabel = nil
    }

    /// The row's whole tooltip: where the session runs, the full working
    /// directory, the snooze while one is in effect, why an ended row is
    /// not a finished one, why a stale row is still listed, and how long a
    /// live-but-quiet working row has been silent.
    func help(now: Date) -> String? {
        var parts: [String] = []
        if isRemote {
            parts.append(remoteMachine.map { "Runs on \($0) — a remote session; answer it there" }
                         ?? "A remote session — answer it on the machine it runs on")
        }
        if let cwd, !cwd.isEmpty { parts.append(cwd) }
        if isSnoozed(now: now), let until = snoozedUntil {
            parts.append("Snoozed until \(PanelStore.clockTime(Date(timeIntervalSince1970: until)))")
        }
        if let activityFact {
            parts.append("Last hook event: \(activityFact)")
        }
        if let originLabel {
            parts.append("via \(originLabel)")
        }
        if let usage, usage.tokens.total > 0 {
            // The cost on hover: the row itself only has room for the
            // model name and the context hairline.
            parts.append(usage.summary)
        }
        if activity == .ended {
            parts.append("Went away without confirming it finished — the agent may have been closed or killed")
        }
        if stale { parts.append("No signal in a while — the session may have ended without a goodbye") }
        if let quiet = quietText(now: now) {
            parts.append("Listed as working and its process still vouches for it — but the last signal was \(quiet) ago")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// A working-shaped row whose last signal is older than
    /// `PanelStore.quietAfter`: the daemon only marks `stale` when no
    /// process vouches, so a live-but-silent run needs its own cue or a
    /// stuck agent reads identically to a healthy long one.
    func isQuiet(now: Date) -> Bool { quietText(now: now) != nil }

    /// "quiet 43m" / "quiet 3h" when this is a quiet working row, else nil.
    func quietText(now: Date) -> String? {
        guard activity == .working, !stale, let since else { return nil }
        let seconds = now.timeIntervalSince(since)
        guard seconds >= PanelStore.quietAfter else { return nil }
        return PanelStore.elapsed(since: since, now: now).map { "quiet \($0)" }
    }

    /// The elapsed column's text: the plain age, prefixed "quiet" once a
    /// working row has been silent past the threshold.
    func elapsedText(now: Date) -> String? {
        quietText(now: now) ?? PanelStore.elapsed(since: since, now: now)
    }

    /// `dismiss_session` hides a row until it next speaks: offered for the
    /// live-but-going-nowhere rows — idle, working, ended, stale. A row
    /// pinned by an unanswered ask stays non-dismissible (the ask is the
    /// point), and a mirrored remote row is the peer's to manage.
    var isDismissible: Bool {
        guard ask == nil, !isRemote else { return false }
        return stale || activity == .idle || activity == .working || activity == .ended
    }

    /// Type-to-find: every word of `query` appears somewhere the row
    /// shows or knows — label, provider, model, folder, the hook's last
    /// word, the ask, the launcher, the peer. Case and diacritics ignored.
    func matches(_ query: String) -> Bool {
        let haystack = [label, style.name, style.id, usage?.modelName, usage?.model, cwd, activityFact,
                        ask?.summary, ask?.kind, originLabel, remoteMachine, activity.word]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy { haystack.contains($0) }
    }

    /// How full a still-running session's context window is. A finished,
    /// ended, failed or stale run's context is history, not a warning.
    var liveContextFraction: Double? {
        guard !activity.isClearable, activity != .failed, !stale else { return nil }
        return usage?.contextFraction
    }

    /// The family mailbox's snooze still covers this session.
    func isSnoozed(now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now.timeIntervalSince1970
    }

    /// `/Users/j/Downloads/JR-Bar/src` → `JR-Bar/src`; `~` collapses the home directory.
    static func tail(of path: String) -> String {
        let home = NSHomeDirectory()
        var text = path
        if text == home { return "~" }
        if text.hasPrefix(home + "/") { text = "~" + text.dropFirst(home.count) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count <= 2 { return text }
        return parts.suffix(2).joined(separator: "/")
    }

    /// The hook's last word about a working row, in the panel's words:
    /// "running Bash", "ran Edit", "compacting". Only `.working` gets
    /// one — a finished row's last event is history, a waiting row's ask
    /// is already the fact that matters, and a stale row's event stopped
    /// being current when the feed did.
    static func activityFact(session: CoreSession, activity: SessionActivity) -> String? {
        guard activity == .working, !session.stale else { return nil }
        if let tool = shortFact(session.tool) {
            switch session.event {
            case "PostToolUse", "PostToolUseFailure": return "ran \(tool)"
            default: return "running \(tool)"
            }
        }
        switch session.event {
        case "PreCompact", "PostCompact": return "compacting"
        case "SessionStart": return "starting"
        case "Notification", "PermissionRequest":
            // `message` can carry agent prose; a bounded snippet is the
            // most the subtitle should ever show of it.
            return shortFact(session.message, limit: 48)
        default: return nil
        }
    }

    /// One line of fact text, short enough for the subtitle: whitespace
    /// collapsed, capped at `limit` characters; nil when nothing is left.
    static func shortFact(_ text: String?, limit: Int = 24) -> String? {
        guard let text else { return nil }
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The panel's state: everything the SwiftUI tree reads, and every action
/// it can take. Bridges the daemon model and the file-feed fallback so the
/// views never need to know which one is speaking.
@MainActor
@Observable
final class PanelStore {
    enum ConnectionDot: Equatable {
        case live
        case connecting
        case fileFeeds
        case crashed
    }

    let core: CoreModel
    /// Per-session model, tokens, cost and context — shared with the
    /// Overview, which the app delegate hands it to.
    let sessionUsage: SessionUsageStore
    /// Always allow and a held question's picks — the desk the notch,
    /// the Dock preview and the Rail share with the panel (the app
    /// delegate publishes it as `AskAnswerDesk.shared`).
    let askDesk: AskAnswerDesk

    // Fallback (file feeds) and app-owned state.
    var fallbackState: AgentAggregateState = .idle
    var fallbackDetail: String = "No agent monitor state"
    var feedDescription: String = "resolving"
    var screenBarShown = true {
        didSet { syncMediaReader() }
    }
    /// The media ear's source — the shared feed's last reduce. Read by
    /// `screenBarWings`, so a track starting or pausing re-lays the
    /// wings on its own. The reader lives only while the bar shows:
    /// hiding the bar lets the feed's monitor stand down.
    private(set) var media: AlcoveMedia?
    @ObservationIgnored private var mediaReader: UUID?
    @ObservationIgnored private let mediaFeed: MediaFeed

    // UI state.
    var isOpen = false
    var selectedID: String?
    /// The selection came from ↑/↓/Tab, not the pointer: the selected row
    /// gets an extra accent stroke so a keyboard pick reads as a pick.
    var selectionByKeyboard = false
    var now = Date()
    var localBrightness: Double?
    var toast: String?
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// False from the moment the panel opens until it has finished
    /// arriving: nothing inside animates before then (the first frame is
    /// the final frame). The controller arms it.
    var animationsArmed = false
    /// The rows' marks, their orbs and the connecting dot move only in an
    /// open panel that has finished arriving: the open's first frame is
    /// its final frame, and starting them is not work the open pays for.
    var marksMove: Bool { isOpen && animationsArmed }
    /// The visible height of the screen the panel opens on; the layout caps
    /// the panel at a fraction of it.
    var screenHeight: Double = 900

    // Wiring back to AppKit.
    var onToggleScreenBar: (@MainActor (Bool) -> Void)?
    var onQuit: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?
    var onOpenSettings: (@MainActor (SettingsStore.Page?) -> Void)?
    var onOpenHistory: (@MainActor () -> Void)?
    var onOpenOverview: (@MainActor () -> Void)?
    /// The provider a usage row was clicked for, when it was.
    var onOpenUsageCenter: (@MainActor (String?) -> Void)?
    var onOpenEffects: (@MainActor () -> Void)?
    var onOpenControlCenter: (@MainActor () -> Void)?
    /// History's Events tab (the journal).
    var onOpenEvents: (@MainActor () -> Void)?
    /// The ⇧⌘K palette.
    var onOpenPalette: (@MainActor () -> Void)?
    /// What's New, through the same route `jrbar://window/whats-new` takes.
    var onOpenWhatsNew: (@MainActor () -> Void)? = { AppCommandRouter.shared.perform(.window(.whatsNew)) }
    /// The overflow menu's "Check for Updates…" (Sparkle, through the delegate).
    var onCheckForUpdates: (@MainActor () -> Void)?
    var onRestartCore: (@MainActor () -> Void)?
    /// The content changed shape while open (rows came or went); the
    /// controller resizes the window to `layout`.
    var onLayoutChange: (@MainActor (PanelLayout) -> Void)?
    /// The "Why this light" row is hovered (with its frame in the hosting
    /// view's coordinates) or not; the controller shows the detail popover.
    var onWhyHover: (@MainActor (Bool, CGRect) -> Void)?

    /// The child daemon's state when the app supervises it; nil when it
    /// only connects to whatever is listening.
    var supervisorState: CoreSupervisor.State?
    /// The "Why this light" row's frame in the hosting view (for the popover).
    var whyRowFrame: CGRect = .zero

    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var brightnessFlush: DispatchWorkItem?
    @ObservationIgnored private var brightnessSentAt = Date.distantPast
    @ObservationIgnored private var toastClear: DispatchWorkItem?

    init(core: CoreModel, draftsDefaults: UserDefaults = .standard,
         mediaFeed: MediaFeed = .shared, screenBarShown: Bool = true) {
        self.core = core
        self.sessionUsage = SessionUsageStore(core: core)
        self.askDesk = AskAnswerDesk(core: core)
        self.fetchUsageHistory = { [weak core] provider, range in
            guard let core else { throw CoreClientError.notConnected }
            return try await core.usageHistory(provider: provider, range: range)
        }
        self.draftsDefaults = draftsDefaults
        self.mediaFeed = mediaFeed
        self.screenBarShown = screenBarShown
        self.replyDrafts = loadReplyDrafts()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
        syncMediaReader()
        observeEvents()
    }

    // MARK: The light log

    /// The last events the daemon published, oldest first, kept for the
    /// "Why this light" popover's log. History's Events tab has the whole
    /// journal; this is the handful that explains the light on screen.
    @ObservationIgnored private(set) var recentEvents: [CoreEvent] = []
    static let recentEventLimit = 48

    /// "How it got here" under the popover's "what it is doing now".
    var lightLog: [LightLogEntry] { LightLog.entries(from: recentEvents, limit: 4) }

    /// One observation per frame, like the Replay store's: two events in
    /// the same turn can coalesce to the last one, which a four-line log
    /// can afford — the journal in History is the complete record.
    private func observeEvents() {
        withObservationTracking {
            _ = core.lastEvent?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.noteEvent(self.core.lastEvent)
                self.observeEvents()
            }
        }
    }

    func noteEvent(_ event: CoreEvent?) {
        guard let event, recentEvents.last?.id != event.id else { return }
        recentEvents.append(event)
        if recentEvents.count > Self.recentEventLimit {
            recentEvents.removeFirst(recentEvents.count - Self.recentEventLimit)
        }
    }

    isolated deinit {
        if let mediaReader { mediaFeed.unsubscribe(mediaReader) }
        clock?.invalidate()
        brightnessFlush?.cancel()
        toastClear?.cancel()
        sparklineWork?.cancel()
    }

    /// The media ear rides the shared feed — one monitor for every
    /// reader (the island, the card, the dock's media rows), so this
    /// adds a reader, never a second helper. Subscribed while the bar
    /// shows, released when it hides.
    private func syncMediaReader() {
        if screenBarShown, mediaReader == nil {
            mediaReader = mediaFeed.subscribe { [weak self] media in
                self?.media = media
            }
            media = mediaFeed.media
        } else if !screenBarShown, let mediaReader {
            mediaFeed.unsubscribe(mediaReader)
            self.mediaReader = nil
            media = nil
        }
    }

    // MARK: Open / close bookkeeping

    func panelDidOpen() {
        isOpen = true
        animationsArmed = false
        // Nothing is selected until an arrow key says so.
        selectedID = nil
        selectionByKeyboard = false
        now = Date()
        clock?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.now = Date()
                // Throttled per id inside the store: each row is asked
                // about at most every `SessionUsageStore.freshFor`.
                self?.refreshSessionUsage()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        scheduleSparklines()
        refreshSessionUsage()
    }

    /// Reads model/tokens/cost/context for the local rows on screen.
    func refreshSessionUsage(force: Bool = false) {
        guard core.isLive else { return }
        sessionUsage.refresh(ids: core.sessions.filter { !$0.isRemote }.map(\.id), force: force)
    }

    func panelDidClose() {
        isOpen = false
        animationsArmed = false
        selectedID = nil
        selectionByKeyboard = false
        findQuery = ""
        clock?.invalidate()
        clock = nil
        sparklineWork?.cancel()
        sparklineWork = nil
    }

    // MARK: Derived: layout

    /// What the panel shows, counted for `PanelLayout`. The quiet
    /// providers share one trailing row, so they count as one.
    var layoutContent: PanelLayout.Content {
        PanelLayout.Content(asks: visibleAskRows.count, sessions: visiblePlainRows.count, hasWhyRow: lightExplanation != nil,
                            usageProviders: usage.count + (quietUsage.isEmpty ? 0 : 1), hasHiddenFooter: hiddenCount > 0)
    }

    /// `state.hidden_count`: sessions the daemon keeps out of `sessions`
    /// because they were acknowledged, which `list_history` still has.
    var hiddenCount: Int { isLive ? core.hiddenSessionCount : 0 }

    /// "3 earlier in History", the footer row's words.
    var hiddenFooterText: String {
        hiddenCount == 1 ? "1 earlier in History" : "\(hiddenCount) earlier in History"
    }

    /// The panel's geometry for the current content and screen, computed
    /// (never measured) so the window can be sized before it is shown.
    var layout: PanelLayout {
        PanelLayout.compute(content: layoutContent, screenHeight: screenHeight)
    }

    func layoutDidChange(_ layout: PanelLayout) {
        guard isOpen else { return }
        onLayoutChange?(layout)
    }

    // MARK: Derived: header

    var isLive: Bool { core.isLive }

    /// The supervised core gave up restarting; the header offers Restart.
    var coreCrashed: Bool {
        if case .crashed = supervisorState { return true }
        return false
    }

    var coreCrashDetail: String {
        if case .crashed(let failures) = supervisorState { return "Monitor crashed \(failures)× in 2 min" }
        return "Monitor crashed"
    }

    var connectionDot: ConnectionDot {
        if core.isLive { return .live }
        if case .connecting = core.connection { return .connecting }
        if case .connected = core.connection { return .connecting }
        return .fileFeeds
    }

    /// True for the first couple of connection attempts, when the daemon
    /// may still be launching; after that the honest word is "not connected".
    var coreMayBeStarting: Bool {
        if case .connecting(let attempt) = core.connection { return attempt <= 2 }
        return false
    }

    var connectionDescription: String {
        if case .backingOff(let failures, let delay) = supervisorState {
            return "Monitor exited (\(failures)×); restarting in \(String(format: "%.1f", delay)) s"
        }
        if coreCrashed { return "\(coreCrashDetail). Restart it from the header." }
        switch core.connection {
        case .connected where core.state != nil:
            let version = core.hello?.coreVersion ?? "?"
            if let stale = staleUpdateText { return "Monitor \(version) connected — quiet, \(stale)" }
            return "Monitor \(version) connected"
        case .connected: return "Connected, waiting for state"
        case .connecting(let attempt): return attempt <= 1 ? "Connecting to the monitor…" : "Reconnecting to the monitor (try \(attempt))…"
        case .disconnected(let reason): return "Monitor not connected: \(reason)"
        case .idle: return "Monitor client idle"
        }
    }

    /// The reference clock for frame-age questions: `now` while the panel
    /// is open so its one-second clock keeps the disclosure current on its
    /// own (a wedged daemon sends nothing that would flip it); the real
    /// wall clock when closed, where a `now` frozen at close time would
    /// understate the age in the status menu.
    private var stalenessReference: Date { isOpen ? now : Date() }

    /// Age of the `state` frame the panel is drawing, nil before the first one.
    var stateAge: TimeInterval? { core.stateAge(at: stalenessReference) }

    /// Connected but the frame on screen is older than
    /// `CoreModel.stateStaleAfter`. The daemon dedupes unchanged frames,
    /// so quiet happens on a healthy monitor too — this is disclosed, never
    /// treated as a disconnect: `isLive` stays true and the dot stays green.
    var stateIsStale: Bool { core.isLive && core.stateIsStale(at: stalenessReference) }

    /// "last update 3m ago" while the live frame is stale, else nil.
    var staleUpdateText: String? {
        guard stateIsStale, let age = stateAge else { return nil }
        let reference = stalenessReference
        let text = Self.elapsed(since: reference.addingTimeInterval(-age), now: reference) ?? "\(Int(age))s"
        return "last update \(text) ago"
    }

    /// "Monitor is quiet — last update 3m ago": the one-line disclosure
    /// that takes the header's count slot and the empty state's detail
    /// while the frame on screen is old.
    var staleDetail: String? { staleUpdateText.map { "Monitor is quiet — \($0)" } }

    var aggregate: AgentAggregateState {
        if core.isLive, let state = core.state { return AgentAggregateState.from(aggregate: state.aggregate) }
        return fallbackState
    }

    var headerWord: String { aggregate.label }

    /// "1 needs you · 1 failed · 2 working · 1 ready", or the file-feed
    /// detail line. The order is `CoreAggregate.countParts`' — the daemon's
    /// precedence and the status icon's label agree.
    var headerCounts: String {
        guard core.isLive, let state = core.state else { return fallbackDetail }
        // Past `stateStaleAfter` these counts are the last frame's, not
        // now's — the disclosure takes the line rather than present a
        // stale frame as current.
        if let stale = staleDetail { return stale }
        let parts = state.aggregate.countParts
        if parts.isEmpty {
            let total = state.mainSessions.count
            return total == 0 ? "No sessions" : (total == 1 ? "1 session, quiet" : "\(total) sessions, quiet")
        }
        return Self.countLine(parts: parts, headerWord: headerWord, total: state.mainSessions.count)
    }

    /// The count parts beside the header word, the word said once: a lone
    /// "2 working" under "Working" reads "2 sessions" when those are all
    /// the sessions listed, and "2 of 3 sessions" beside an idle or ended
    /// one, since the word already says what they are doing. The number
    /// never reads as the whole list when it is not.
    nonisolated static func countLine(parts: [String], headerWord: String, total: Int) -> String {
        guard parts.count == 1, let part = parts.first, let space = part.firstIndex(of: " "),
              let count = Int(part[..<space]) else { return parts.joined(separator: " · ") }
        // "2 need you" is the plural of the header's "Needs you".
        func word(_ text: some StringProtocol) -> String {
            text.lowercased().replacingOccurrences(of: "needs you", with: "need you")
        }
        guard word(part[part.index(after: space)...]) == word(headerWord) else { return part }
        // More than the list holds (two asks on one session) is not a
        // count of sessions: the daemon's own words stand.
        if count > total { return part }
        if count < total { return "\(count) of \(total) sessions" }
        return count == 1 ? "1 session" : "\(count) sessions"
    }

    // MARK: Derived: sessions

    /// The daemon's settings document, for provider colour overrides.
    var settingsDocument: SettingsDocument? {
        core.settings.map { SettingsDocument($0.document) }
    }

    /// What `rows` is made of. Reading them all on every call, answered
    /// from the memo or not, keeps SwiftUI and `withObservationTracking`
    /// subscribed to each one. Comparing is cheap: an unchanged document
    /// is the same storage, and a new frame differs in its generation.
    private struct RowsInputs: Equatable {
        let live: Bool
        let state: CoreState?
        let settings: CoreSettings?
        let usage: [String: SessionUsage]
    }

    /// One computation of `rows` and the cuts the panel takes of it, kept
    /// until an input changes. A class, so filling a cut lazily is not a
    /// change the store's observers hear.
    private final class RowsMemo {
        let inputs: RowsInputs
        let rows: [SessionRow]
        lazy var askRows: [SessionRow] = rows.filter { $0.ask != nil }
        /// The find query's cut: the rows it keeps, split for the list.
        var cut: RowCut?

        init(inputs: RowsInputs, rows: [SessionRow]) {
            self.inputs = inputs
            self.rows = rows
        }
    }

    /// The rows the panel draws for one find query.
    private struct RowCut {
        let query: String
        let visible: [SessionRow]
        let asks: [SessionRow]
        let plain: [SessionRow]
        let ids: [String]
    }

    @ObservationIgnored private var rowsMemo: RowsMemo?
    /// How many times `rows` was built — a test hook proving the memo
    /// holds across reads and lets go on an input change.
    @ObservationIgnored private(set) var rowsComputations = 0

    private var currentRows: RowsMemo {
        let inputs = RowsInputs(live: core.isLive, state: core.state, settings: core.settings,
                                usage: sessionUsage.usage)
        if let memo = rowsMemo, memo.inputs == inputs { return memo }
        let memo = RowsMemo(inputs: inputs, rows: Self.buildRows(inputs))
        rowsComputations += 1
        rowsMemo = memo
        return memo
    }

    /// Asks first, then waiting, failed, working, done, ended, idle. Among
    /// asks the longest-unanswered leads — `openedAt` ascending — so the
    /// ask that has been waiting longest is never buried under newer ones;
    /// an undated ask sorts last among them. Other ties: most recent first.
    /// Built once per change of the daemon's state, its settings, the
    /// sessions' usage or liveness, however often it is read.
    var rows: [SessionRow] { currentRows.rows }

    private static func buildRows(_ inputs: RowsInputs) -> [SessionRow] {
        guard inputs.live, let state = inputs.state else { return [] }
        let document = inputs.settings.map { SettingsDocument($0.document) }
        let pinned = Dictionary(state.asks.compactMap { ask in ask.session.map { ($0, ask) } }, uniquingKeysWith: { first, _ in first })
        // An ask whose session the daemon no longer lists still needs an
        // answer: it is counted in the header and it is what the light is
        // about, so it gets a row of its own rather than disappearing.
        let orphans = state.orphanAsks.map { SessionRow(orphanAsk: $0, document: document) }
        let usage = inputs.usage
        let rows = state.mainSessions.map { session in
            var row = SessionRow(session: session, pinnedAsk: pinned[session.id], document: document)
            row.usage = usage[session.id]
            return row
        } + orphans
        func rank(_ row: SessionRow) -> Int {
            row.ask != nil ? 0 : row.activity.sortRank
        }
        /// An ask's age: `openedAt` when the daemon sent one, the row's
        /// `since` otherwise, and the far future when neither exists so an
        /// undated ask does not pretend to be the oldest.
        func askAge(_ row: SessionRow) -> Double {
            row.ask?.openedAt ?? row.since?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
        }
        return rows.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if ra == 0 { return askAge(a) < askAge(b) }
            return (a.since ?? .distantPast) > (b.since ?? .distantPast)
        }
    }

    /// The row the Screen Bar names — a live ask first, then a failure,
    /// then whoever is working, then an unseen completion. The tooltip's
    /// words and the wing slot's tint read the same pick so they never
    /// disagree about who is on top.
    private var focusPick: SessionRow? {
        rows.first { $0.ask != nil }
            ?? rows.first { $0.activity == .failed }
            ?? rows.first { $0.activity == .working }
            ?? rows.first { $0.activity == .done }
    }

    /// What the Screen Bar's tooltip names: a live ask first, then a failure,
    /// then whoever is working, then an unseen completion; with nothing live
    /// the aggregate word. The click target is stricter: an ask's session or
    /// the working one, else nothing.
    var screenBarFocus: ScreenBarFocus {
        let rows = rows
        let pick = focusPick
        // The click opens a local terminal; a mirrored remote row has none,
        // so it can be the focus's subject but never its target.
        let clickable = rows.first { $0.ask != nil && !$0.isRemote }
            ?? rows.first { $0.activity == .working && !$0.isRemote }
        if let pick {
            let word = pick.ask != nil ? "Needs you" : pick.activity.word
            return ScreenBarFocus(style: pick.style, label: pick.label, word: word,
                                  clickSession: clickable?.id, focusSession: pick.id,
                                  explanation: lightExplanation?.reason)
        }
        let word = core.isLive ? aggregate.label : (fallbackState == .idle ? "Idle" : fallbackState.label)
        return ScreenBarFocus(style: nil, label: "JR-Bar", word: word, clickSession: nil,
                              explanation: lightExplanation?.reason)
    }

    /// The wing slots' content (`screen_bar_notch_wings`). Left is the
    /// activity slot: the top-priority session's provider tile and state
    /// word, with the open-ask count when there is more than one. Right is
    /// the ambient slot: the headline usage meter — the first provider
    /// window the daemon sent, the same pick the notch card makes. A
    /// side with nothing to say is nil and collapses rather than holding
    /// space open beside the notch.
    var screenBarWings: ScreenBarWings {
        var left: ScreenBarWingSlot? = focusPick.map {
            Self.activitySlot(for: $0, askCount: askRows.count, now: Date().timeIntervalSince1970,
                              finalSeconds: escalationFinalSeconds)
        }
        // The media wing — Alcove's grammar: album art on the left
        // ear, the live equalizer on the right. The activity slot owns
        // the left while a session runs, so media takes the left only
        // in the quiet and otherwise spills to an unmetered right.
        let mediaArt: ScreenBarWingSlot? = media?.playing == true && media?.artworkData != nil
            ? ScreenBarWingSlot(text: media?.displayLine ?? "Playing",
                                artwork: media?.artworkData.map(ScreenBarWingSlot.Artwork.init))
            : nil
        let mediaViz: ScreenBarWingSlot? = media?.playing == true
            ? ScreenBarWingSlot(text: media?.displayLine ?? "Playing", visualizer: true)
            : nil
        var mediaTookLeft = false
        if left == nil, let mediaLeft = mediaArt ?? mediaViz {
            left = mediaLeft
            mediaTookLeft = true
        }
        let right = NotchIsland.meters(core.state?.usage).first
            .map { meter in
                ScreenBarWingSlot(text: Self.meterWingText(meter, now: Date()), provider: meter.provider,
                                  meter: meter.percent.map { min(1, max(0, $0 / 100)) },
                                  tone: meter.incident ? .attention : .neutral)
            } ?? (mediaTookLeft && mediaArt == nil ? nil : mediaViz)
        return ScreenBarWings(left: left, right: right)
    }

    /// The meter ear's words: the percent, then the reset countdown (a
    /// broken source's fix once the reset is past) and a live vendor
    /// incident — the peek and VoiceOver get the detail the 16 pt ring
    /// cannot spell out.
    nonisolated static func meterWingText(_ meter: NotchIslandMeter, now: Date) -> String {
        var text = meter.percentText
        if let countdown = Self.countdown(to: meter.resetsAt, now: now, fix: meter.fix) { text += " · \(countdown)" }
        if meter.incident { text += " · incident" }
        return text
    }

    /// The left ear's activity slot for the focus pick: its provider's
    /// mark and state word, the open-ask count when there is more than
    /// one. An ask's mark rings with its age — the ring fills toward the
    /// escalation's final stage, so how long an agent has waited reads
    /// without a word; the peek's text says minutes only, so a ticking
    /// clock never re-lays the ears.
    static func activitySlot(for pick: SessionRow, askCount: Int, now: Double,
                             finalSeconds: Double) -> ScreenBarWingSlot {
        var text = pick.ask != nil ? "Needs you" : pick.activity.word
        if pick.ask != nil, askCount > 1 { text += " ·\(askCount)" }
        let opened = pick.ask.flatMap { $0.openedAt ?? pick.since?.timeIntervalSince1970 }
        if let opened, let waited = askWaitWords(opened: opened, now: now) { text += " · \(waited)" }
        return ScreenBarWingSlot(
            text: text, provider: pick.style.id,
            meter: opened.map { askAgeFraction(opened: $0, now: now, finalSeconds: finalSeconds) },
            tone: pick.activity == .failed ? .alert
                : pick.ask != nil || pick.activity == .waiting ? .attention
                : .neutral)
    }

    /// When an unanswered ask reaches the escalation's last stage
    /// (Settings › Notifications, 300 s by default) — where the ask-age
    /// ring closes.
    var escalationFinalSeconds: Double {
        let configured = settingsDocument?.double("escalation_final_seconds") ?? 300
        return configured > 0 ? configured : 300
    }

    /// When the focus pick's ask opened — the moment the left ear's ring
    /// counts from; nil while the focus has no open ask.
    var focusAskOpened: Double? {
        focusPick.flatMap { pick in pick.ask.flatMap { $0.openedAt ?? pick.since?.timeIntervalSince1970 } }
    }

    /// The epoch at which the left ear next changes on its own, for the
    /// delegate's one-shot re-push: the daemon sends no frame while only
    /// the clock moves, so without it the ring would wait for unrelated
    /// activity. Nil without an open ask in focus.
    func nextAskAgeTick(now: Double = Date().timeIntervalSince1970) -> Double? {
        Self.nextAskAgeTick(opened: focusAskOpened, now: now, finalSeconds: escalationFinalSeconds,
                            holdUntil: focusAskHoldUntil)
    }

    /// When the hook's hold on the focus pick's ask lapses — a moment the
    /// ask's verbs change with no daemon frame to mark it.
    var focusAskHoldUntil: Double? {
        focusPick?.ask.flatMap { $0.isHeldForDecision ? $0.decision?.holdUntil : nil }
    }

    /// The next boundary the ear shows: the ring's next twelfth of
    /// `finalSeconds` while it is filling, the wait's next whole minute
    /// (the peek's "· N min"), or the hold's lapse, whichever comes
    /// first. The words keep counting past an hour, so a full ring still
    /// ticks once a minute; nil only when there is no ask to count.
    nonisolated static func nextAskAgeTick(opened: Double?, now: Double, finalSeconds: Double,
                                           holdUntil: Double? = nil) -> Double? {
        guard let opened else { return nil }
        let waited = max(0, now - opened)
        let minute = opened + ((waited / 60).rounded(.down) + 1) * 60
        var next = minute
        if finalSeconds > 0, waited < finalSeconds {
            // The same arithmetic `askAgeFraction` steps on, so the tick
            // lands on the twelfth that changes the fill.
            next = min(next, opened + ((waited / finalSeconds * 12).rounded(.down) + 1) * finalSeconds / 12)
        }
        if let holdUntil, holdUntil > now { next = min(next, holdUntil) }
        return next
    }

    /// The ask-age ring's fill: the share of the way to the final stage,
    /// in twelfths — a step every 25 s at the default, so the ear moves
    /// visibly without re-laying on every lighting frame. Full from the
    /// final stage on. The delegate re-pushes the wings at each step
    /// (`nextAskAgeTick`), since no daemon frame marks one.
    nonisolated static func askAgeFraction(opened: Double, now: Double, finalSeconds: Double) -> Double {
        guard finalSeconds > 0 else { return 1 }
        let share = max(0, now - opened) / finalSeconds
        return min(1, (share * 12).rounded(.down) / 12)
    }

    /// "4 min" once an ask has waited a minute; nil before.
    nonisolated static func askWaitWords(opened: Double, now: Double) -> String? {
        let minutes = Int(max(0, now - opened) / 60)
        guard minutes >= 1 else { return nil }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: The awake hold

    /// The daemon's hold on sleep, as the footer's mark says it — why
    /// the Mac is awake and when it lets go; nil while nothing holds it.
    var awakeHold: (symbol: String, text: String)? {
        Self.awakeHold(power: core.state?.power,
                       working: rows.filter { $0.activity == .working && !$0.isRemote }.count)
    }

    /// Amphetamine's lesson: the hold is state worth a glance. A closed
    /// lid held open outranks the plain keep-awake, since it is the one
    /// that keeps a shut laptop running. It counts only while the lid
    /// really is shut, as on the Screen Bar: with the lid open the hold
    /// is only armed, and the cup tells the truth.
    nonisolated static func awakeHold(power: CorePower?, working: Int) -> (symbol: String, text: String)? {
        guard let power else { return nil }
        let agents = working == 1 ? "1 agent works" : "\(working) agents work"
        // The runway, the charger and the last release ride in the
        // mark's tooltip, a line each.
        let facts = KeepAwakeReading(power: power).facts()
        func told(_ text: String) -> String { ([text] + facts).joined(separator: "\n") }
        if let lid = power.closedLid, lid.holding == true, lid.lidClosed == true {
            return ("laptopcomputer", told(working > 0
                ? "Running with the lid closed while \(agents); it sleeps once they stop"
                : "Running with the lid closed; it sleeps once the agents stop"))
        }
        guard power.keepAwake == true else { return nil }
        // A run the battery will not outlast wears the battery, not the cup.
        let symbol = power.battery?.runway?.short == true ? "battery.25percent" : "cup.and.saucer.fill"
        return (symbol, told(working > 0
            ? "Keeping this Mac awake while \(agents); it lets go a few minutes after they stop"
            : "Keeping this Mac awake; it lets go a few minutes after the agents stop"))
    }

    var askRows: [SessionRow] { currentRows.askRows }

    // MARK: Notify when done

    /// Sessions the user asked to hear about when they end — one banner
    /// each, the long refactor pinging without turning completion banners
    /// on for every run and sub-agent. In memory: a watch is for this run
    /// of this session, and it is spent when it fires.
    private(set) var doneWatches: Set<String> = []

    func isWatchedForDone(_ row: SessionRow) -> Bool { doneWatches.contains(row.id) }

    // MARK: Reaching a peer

    /// The host a remote row's machine answers on (`state.peers`), for
    /// "Open Screen Sharing to …"; nil when the peer never named one.
    func screenSharingHost(for row: SessionRow) -> String? {
        guard row.isRemote, let machine = row.remoteMachine else { return nil }
        let peer = core.state?.peers?.first { $0.machine == machine }
        return Self.screenSharingHost(peerHost: peer?.host, machine: machine)
    }

    /// The peer's published host (its Tailscale name), else the machine
    /// name itself when it is a plausible host name; never a string with
    /// characters a `vnc://` URL would have to smuggle.
    nonisolated static func screenSharingHost(peerHost: String?, machine: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        for candidate in [peerHost, machine] {
            guard let text = candidate?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
                  text.unicodeScalars.allSatisfy(allowed.contains) else { continue }
            return text
        }
        return nil
    }

    /// Screen Sharing to the peer: macOS's own client asks for the
    /// credentials; JR-Bar sends nothing and runs nothing there.
    func openScreenSharing(host: String) {
        guard let url = URL(string: "vnc://\(host)") else { return }
        NSWorkspace.shared.open(url)
        onClose?()
    }

    func toggleDoneWatch(_ row: SessionRow) {
        guard !row.isRemote else { return }
        if doneWatches.remove(row.id) == nil {
            doneWatches.insert(row.id)
            show(toast: "Will tell you when \(row.label) is done")
        } else {
            show(toast: "Won't ping for \(row.label)")
        }
    }

    /// A run-ending event for a watched session spends the watch; true
    /// means the caller should make sure a banner lands.
    func consumeDoneWatch(for event: CoreEvent) -> Bool {
        guard AgentAlertRules.doneKinds.contains(event.kind), let session = event.session else { return false }
        return doneWatches.remove(session) != nil
    }

    // MARK: Type to find

    /// What the user typed while the panel was open — Raycast's defining
    /// gesture: start typing and the list narrows. Only the panel's own
    /// list narrows; the Screen Bar, the icon and the header counts keep
    /// reading every row.
    private(set) var findQuery = ""

    /// The rows the panel draws: every row, or the ones the query finds.
    var visibleRows: [SessionRow] { currentCut.visible }
    var visibleAskRows: [SessionRow] { currentCut.asks }
    var visiblePlainRows: [SessionRow] { currentCut.plain }
    /// The drawn rows' ids, in order — what the list animates on.
    var visibleRowIDs: [String] { currentCut.ids }

    /// The query's cut of the current rows, taken once per rows change or
    /// query change and shared by every read in between.
    private var currentCut: RowCut {
        let memo = currentRows
        let query = findQuery.trimmingCharacters(in: .whitespaces)
        if let cut = memo.cut, cut.query == query { return cut }
        let visible = query.isEmpty ? memo.rows : memo.rows.filter { $0.matches(query) }
        let cut = RowCut(query: query, visible: visible,
                         asks: visible.filter { $0.ask != nil },
                         plain: visible.filter { $0.ask == nil },
                         ids: visible.map(\.id))
        memo.cut = cut
        return cut
    }

    /// Typing lands here: the query grows, and the first match becomes the
    /// keyboard selection so Return opens it straight away.
    func find(_ query: String) {
        findQuery = String(query.prefix(64))
        selectionByKeyboard = true
        selectedID = visibleRows.first?.id
    }

    func appendFind(_ text: String) { find(findQuery + text) }

    /// ⌫ takes one character back; true when there was one to take.
    @discardableResult
    func deleteFindCharacter() -> Bool {
        guard !findQuery.isEmpty else { return false }
        find(String(findQuery.dropLast()))
        if findQuery.isEmpty { selectedID = nil }
        return true
    }

    /// Esc clears a query before it closes the panel.
    @discardableResult
    func clearFind() -> Bool {
        guard !findQuery.isEmpty else { return false }
        findQuery = ""
        selectedID = nil
        selectionByKeyboard = false
        return true
    }

    /// A key the find field takes: printable, no ⌘/⌃/⌥, and not a space
    /// opening a query (space alone is nothing to find).
    nonisolated static func isFindCharacter(_ text: String?, query: String) -> Bool {
        guard let text, text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        if scalar == " " { return !query.isEmpty }
        return CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains(scalar)
    }
    /// What "Clear finished" acknowledges: finished runs, ended ones and
    /// anything the daemon has marked stale — the same rows
    /// `clear_completed {sessions: "all"}` clears daemon-side.
    var completedCount: Int { rows.filter { $0.activity.isClearable || $0.stale }.count }

    // MARK: Derived: quiet

    /// `state.focus` while a quiet is in effect; nil when the daemon says
    /// `"off"` (or sends nothing). The footer's label and the header's
    /// moon both read this, so neither can paint quiet the daemon denies.
    struct Quiet: Equatable {
        var mode: String
        /// `override` (this menu), `schedule`, or `focus` (macOS/named).
        var source: String?
        var until: Date?
    }

    var quiet: Quiet? {
        guard let focus = core.state?.focus,
              let mode = focus.mode,
              mode != "off", mode != "normal" else { return nil }
        return Quiet(mode: mode, source: focus.source,
                     until: focus.until.map { Date(timeIntervalSince1970: $0) })
    }

    /// The footer's words: "Paused 52m", "Dimmed 1h" — the countdown
    /// drops its minutes past an hour so the longest case ("Asks only
    /// 23h") still leaves the footer's other buttons room. For a quiet
    /// with no clock on it, just the mode word.
    var quietLabel: String? {
        guard let quiet else { return nil }
        let word = Self.quietWord(quiet.mode)
        guard let until = quiet.until else { return word }
        let seconds = until.timeIntervalSince(now)
        if seconds <= 0 { return word }
        let minutes = Int((seconds + 30) / 60)
        if minutes < 60 { return "\(word) \(minutes)m" }
        if minutes < 24 * 60 { return "\(word) \((minutes + 30) / 60)h" }
        return "\(word) \((minutes + 12 * 60) / (24 * 60))d"
    }

    /// The quiet can be ended from here only when this menu put it there;
    /// a schedule's or macOS Focus's quiet is not ours to cancel, and a
    /// button that silently failed would be worse than none.
    var quietIsOurs: Bool { quiet?.source == "override" }

    /// The mode the quiet presets use: Pause hides everything, Dim stills
    /// the lights, Mute stills the sounds, Asks only lets asks through,
    /// Dark turns the hardware off. Remembered across opens.
    var quietMode: String = UserDefaults.standard.string(forKey: "quietMode") ?? "pause" {
        didSet { UserDefaults.standard.set(quietMode, forKey: "quietMode") }
    }

    /// The quiet modes the footer's Mode submenu offers, in menu order.
    nonisolated static let quietModes: [(id: String, label: String)] = [
        ("pause", "Pause"),
        ("dim", "Dim"),
        ("mute", "Mute"),
        ("asks_only", "Asks only"),
        ("dark", "Dark"),
    ]

    nonisolated static func quietWord(_ mode: String) -> String {
        switch mode {
        case "pause": return "Paused"
        case "dim": return "Dimmed"
        case "mute": return "Muted"
        case "dark": return "Dark"
        case "asks_only": return "Asks only"
        default: return "Quiet"
        }
    }

    /// How long a working-shaped row may go without a signal before the
    /// panel says so ("quiet 43m"). Shorter than the daemon's stale sweep —
    /// stale means nobody vouches; quiet means a live process just hasn't
    /// spoken in a while.
    nonisolated static let quietAfter: TimeInterval = 30 * 60

    /// `HH:mm` for "until 08:00" in the toast and the menu's preset label.
    nonisolated static func clockTime(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Seconds to the next local 08:00 that is at least an hour away:
    /// what "Until 8:00 tomorrow" means at 06:45 as well as at 23:10.
    /// Shared by the quiet preset and the rows' "Snooze until tomorrow".
    nonisolated static func secondsUntilMorning(from now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let components = DateComponents(hour: 8, minute: 0)
        var target = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(8 * 3600)
        if target.timeIntervalSince(now) < 3600 {
            target = calendar.nextDate(after: target, matching: components, matchingPolicy: .nextTime)
                ?? target.addingTimeInterval(86400)
        }
        return max(60, Int(target.timeIntervalSince(now)))
    }

    /// The wall-clock moment "Until 8:00" ends at, so the menu can name
    /// it instead of promising a guess.
    var morningTarget: Date {
        now.addingTimeInterval(TimeInterval(Self.secondsUntilMorning(from: now)))
    }

    /// "Until 08:00" when the target is today, "... tomorrow" when it is
    /// not -- before 07:00 the next 08:00 is this morning, and calling it
    /// tomorrow was a day wrong.
    nonisolated static func morningLabel(verb: String, target: Date) -> String {
        let time = clockTime(target)
        return Calendar.current.isDateInToday(target) ? "\(verb) \(time)" : "\(verb) \(time) tomorrow"
    }

    /// `state.focus.source` in the words the footer help uses.
    nonisolated static func quietSourceWord(_ source: String) -> String {
        switch source {
        case "override": return "this menu"
        case "schedule": return "the schedule"
        case "focus": return "macOS Focus"
        default: return source
        }
    }

    /// `quiet {mode, seconds}` in the mode the Mode submenu last chose.
    func quietFor(seconds: Int) {
        core.quiet(mode: quietMode, seconds: seconds)
        let until = Date().addingTimeInterval(TimeInterval(seconds))
        show(toast: "\(Self.quietWord(quietMode)) until \(Self.clockTime(until))")
    }

    /// `quiet {seconds: 0}`: end the override this menu set. Not offered
    /// for a schedule or macOS Focus quiet — see `quietIsOurs`.
    func endQuiet() {
        core.quiet(mode: quietMode, seconds: 0)
        show(toast: "Quiet ended")
    }

    // MARK: Derived: why this light

    /// "Amber pulse: Codex sidepulse-core is waiting on you (permission, 45 s)".
    /// The wait counts on `stalenessReference`: the notch card reads this
    /// line with the panel closed, where `now` stopped at the last close.
    var lightExplanation: LightExplanation? {
        guard core.isLive else { return nil }
        let settings = core.settings.map { SettingsDocument($0.document) }
        return LightExplainer.explain(lights: core.lights, state: core.state, settings: settings,
                                      now: stalenessReference)
    }

    func whyHover(_ hovering: Bool, frame: CGRect) {
        onWhyHover?(hovering, frame)
    }

    /// The light's session, through `SessionOpener` like a row's click: a
    /// peer's session is refused locally, and the panel closes only once
    /// the session is in front.
    func openExplainedSession() {
        guard let session = lightExplanation?.session else { return }
        Task { [weak self] in
            let refusal = await SessionOpener.open(session)
            guard let self else { return }
            if let refusal { self.show(toast: refusal) } else { self.onClose?() }
        }
    }

    // MARK: Derived: usage and devices

    /// Providers that earn a full row: a window with something on it,
    /// from a source that is on and found.
    var usage: [CoreProviderUsage] { core.isLive ? core.usage.filter { !Self.foldsIntoQuietRow($0) } : [] }
    /// The providers with nothing to say — every window at 0 %, no window
    /// at all, the source not found or switched off: one trailing row
    /// names them and opens the Usage Center, so they neither vanish
    /// silently nor take a 50 pt row each to say "nothing".
    var quietUsage: [CoreProviderUsage] { core.isLive ? core.usage.filter { Self.foldsIntoQuietRow($0) } : [] }
    var devices: [CoreDevice] { core.isLive ? core.devices : [] }

    /// `state.health.hooks` providers the daemon reports as `missing`: the
    /// empty state names them so "no sessions" is not mistaken for "quiet"
    /// when nothing was ever wired up to report.
    var missingHooks: [String] {
        guard core.isLive, let hooks = core.state?.health?["hooks"]?.objectValue else { return [] }
        return hooks.compactMap { provider, state in
            state.stringValue == "missing" ? provider : nil
        }.sorted()
    }

    // MARK: Derived: hook feed health and unseen completions

    /// `state.unseen_completions`: ids of rows that finished since the
    /// user last looked — the daemon intersects it with the rows it still
    /// lists, so membership is all the "new" dot has to check.
    var unseenCompletionIDs: Set<String> {
        guard core.isLive else { return [] }
        return Set(core.state?.unseenCompletions ?? [])
    }

    /// How long a provider's hook feed may be silent while it still has
    /// live rows before the panel says so. Matches the daemon's own
    /// ingest-lag bound (`DEFAULT_INGEST_LAG_SECONDS`): past it, a feed
    /// that is not delivering is a fault, not a pause between events.
    nonisolated static let sourceQuietBound: TimeInterval = 5 * 60

    /// `health.sources` providers whose hook feed stopped delivering while
    /// they still have live rows — provider id → seconds since the feed
    /// last was heard. The gate is deliberately narrow: an installed-but-
    /// silent provider with nothing running is not a fault, and a remote
    /// row says nothing about this Mac's intake.
    var quietFeeds: [String: Double] {
        guard core.isLive, let state = core.state else { return [:] }
        var result: [String: Double] = [:]
        // The panel's clock: a `heard_at` moment keeps counting while the
        // panel is open and no frame arrives.
        let clock = now.timeIntervalSince1970
        for session in core.sessions where !session.isRemote {
            let activity = SessionActivity.reduce(session)
            guard activity == .working || activity == .waiting else { continue }
            guard let source = state.sourceHealth(for: session.provider, now: clock),
                  !source.fresh,
                  let age = source.heardAgeSeconds,
                  age.isFinite, age >= Self.sourceQuietBound else { continue }
            result[session.provider] = max(result[session.provider] ?? 0, age)
        }
        return result
    }

    /// "feed quiet 15m" for the topmost live row of a provider whose hook
    /// feed stopped arriving; nil on every other row, so the marker is
    /// once per provider, on the row that proves the silence matters.
    func quietFeedText(for row: SessionRow) -> String? {
        guard let age = quietFeeds[row.style.id],
              row.activity == .working || row.activity == .waiting,
              rows.first(where: {
                  $0.style.id == row.style.id && ($0.activity == .working || $0.activity == .waiting)
              })?.id == row.id
        else { return nil }
        let elapsed = Self.elapsed(since: now.addingTimeInterval(-age), now: now) ?? "\(Int(age))s"
        return "feed quiet \(elapsed)"
    }

    // MARK: Derived: the usage sparklines

    /// Tokens per day for the last week, per provider, oldest first: what
    /// the tiny graph in each usage row draws. Filled in the background
    /// from `usage_history`, never on the way to showing the panel.
    private(set) var sparklines: [String: [Double]] = [:]
    /// One `usage_history` per provider per this long, at most. A cold
    /// scan is expensive daemon-side and nothing in the row moves faster.
    static let sparklineInterval: TimeInterval = 600
    @ObservationIgnored private var sparklineFetchedAt: [String: Date] = [:]

    func sparkline(for provider: String) -> [Double]? {
        guard let values = sparklines[provider], UsageSparkline.hasSignal(values) else { return nil }
        return values
    }

    /// `usage_graph_days` as the range the sparkline can draw: the little
    /// row graph has room for a week or a month of 5 pt bars, so a
    /// configured quarter or year reads its closest month rather than
    /// clipping mid-bar.
    var sparklineRange: UsageHistoryRange {
        let days = settingsDocument?.int("usage_graph_days") ?? 7
        return days <= 7 ? .week : .month
    }

    /// How long after the panel opens its sparklines are asked for. The
    /// daemon answers one client's commands in order, so a burst of
    /// `usage_history` sent on open queued ahead of the Approve the panel
    /// was opened to click.
    static let sparklineDelay: TimeInterval = 1.5
    /// `sparklineDelay`, shortened by the tests.
    @ObservationIgnored var sparklineWait = PanelStore.sparklineDelay
    @ObservationIgnored private var sparklineWork: Task<Void, Never>?
    /// `usage_history` for one provider — the core's in production; tests
    /// stage it.
    @ObservationIgnored var fetchUsageHistory: @MainActor (_ provider: String, _ range: UsageHistoryRange) async throws -> UsageHistory

    /// The sparklines are fetched a beat after the panel opens, if it is
    /// still open then.
    private func scheduleSparklines() {
        sparklineWork?.cancel()
        let wait = sparklineWait
        sparklineWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.isOpen else { return }
            self.sparklineWork = nil
            self.refreshSparklines()
        }
    }

    /// Whether the sparklines are worth asking for now: never while an
    /// ask is open, since every `usage_history` waits in line ahead of its
    /// answer.
    nonisolated static func wantsSparklines(live: Bool, asksOpen: Bool) -> Bool { live && !asksOpen }

    /// Asks the daemon for `usage_graph_days` of history — week or month,
    /// see `sparklineRange` — for every provider the panel shows, unless
    /// it asked recently or an ask is open. Failures are silent: a row
    /// without a sparkline simply has none. `force` is for the
    /// `usage_history_ready` event, which means the rows just changed.
    func refreshSparklines(force: Bool = false) {
        guard Self.wantsSparklines(live: core.isLive, asksOpen: !askRows.isEmpty) else { return }
        let now = Date()
        let range = sparklineRange
        for provider in usage {
            let id = provider.id
            if !force, let at = sparklineFetchedAt[id], now.timeIntervalSince(at) < Self.sparklineInterval { continue }
            sparklineFetchedAt[id] = now
            Task { [weak self] in
                guard let self else { return }
                do {
                    let history = try await self.fetchUsageHistory(id, range)
                    let values = UsageSparkline.tokensPerDay(history)
                    if UsageSparkline.hasSignal(values) {
                        self.sparklines[id] = values
                    } else {
                        self.sparklines.removeValue(forKey: id)
                    }
                    // A partial answer is worth drawing, but it should not
                    // hold the slot for the next ten minutes.
                    if history.partial { self.sparklineFetchedAt[id] = nil }
                } catch {
                    self.sparklineFetchedAt[id] = nil     // try again next time the panel opens
                }
            }
        }
    }

    /// The two windows a usage row draws: the leading window — the
    /// most-exhausted measured lane (`UsageCenterStore.primaryWindow`),
    /// so a weekly at 100 % leads red instead of hiding behind 5 h
    /// headroom — and the 7 d window (else the next one) beside it.
    static func windows(of usage: CoreProviderUsage) -> (primary: CoreUsageWindow?, secondary: CoreUsageWindow?) {
        let primary = UsageCenterStore.primaryWindow(of: usage)
        let secondary = usage.windows.first { $0.shortName == "7d" && $0.id != primary?.id }
            ?? usage.windows.first { $0.id != primary?.id }
        return (primary, secondary)
    }

    /// A provider whose row would say nothing: no window, every window at
    /// 0 %, or a source that is switched off or was never found.
    static func foldsIntoQuietRow(_ usage: CoreProviderUsage) -> Bool {
        if usage.windows.isEmpty { return true }
        if let state = usage.state?.lowercased(), state == "disabled" || state == "source_not_found" { return true }
        return usage.windows.allSatisfy { ($0.usedPct ?? 1) < 0.5 }
    }

    /// Why a provider sits in the quiet row, in the fewest words.
    static func quietWord(_ usage: CoreProviderUsage) -> String {
        switch usage.state?.lowercased() {
        case "disabled": return "off"
        case "source_not_found": return "not found"
        case "needs_sign_in": return "signed out"
        case "needs_consent": return "needs consent"
        case let state? where state != "ready" && state != "stale" && usage.windows.isEmpty:
            return state.replacingOccurrences(of: "_", with: " ")
        default: return usage.windows.isEmpty ? "no windows" : "at 0%"
        }
    }

    /// The quiet row's second line: "at 0%" for one provider, else
    /// "2 at 0% · 1 not found", in the order the providers came.
    static func quietSummary(_ providers: [CoreProviderUsage]) -> String {
        let words = providers.map(quietWord)
        guard words.count > 1 else { return words.first ?? "" }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for word in words {
            if counts[word] == nil { order.append(word) }
            counts[word, default: 0] += 1
        }
        return order.map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: " · ")
    }

    /// The one thing a usage row's tag says, worst first. Nothing when
    /// the provider is on track.
    enum UsageTag: Equatable {
        /// The reading is old — the last refresh did not land.
        case stale
        /// The leading window is at or past 100 %.
        case usedUp
        /// The forecast runs dry before the window resets.
        case runsOut(String)
        /// The vendor's status feed reports an outage.
        case incident(String)

        var text: String {
            switch self {
            case .stale: return "Stale"
            case .usedUp: return "Used up"
            case .runsOut(let when): return "Runs out \(when)"
            case .incident: return "Incident"
            }
        }
    }

    static func usageTag(for usage: CoreProviderUsage, primary: CoreUsageWindow?, heldIdle: Bool, now: Date) -> UsageTag? {
        if usage.isStale { return .stale }
        if (primary?.usedPct ?? 0) >= 100 || usage.forecast?.pace?.lowercased() == "exhausted" { return .usedUp }
        // A held-idle provider's last slope is history, and a window that
        // resets before the forecast runs dry is on track.
        if !heldIdle, let exhaustsAt = usage.forecast?.exhaustsAt, exhaustsAt > now.timeIntervalSince1970,
           primary?.resetsAt.map({ exhaustsAt < $0 }) ?? true {
            return .runsOut(UsageForecast.relative(to: exhaustsAt, now: now))
        }
        if let incident = usage.incident, !incident.isEmpty { return .incident(incident) }
        return nil
    }

    /// A stale reading's tag help: old, and the daemon's fix when it
    /// has one ("Reconnect Claude"), so the hover says what to do.
    static func staleHelp(action: String?) -> String {
        let old = "This reading is old — the last refresh did not land"
        guard let action = action?.trimmingCharacters(in: .whitespaces), !action.isEmpty else { return old }
        return "\(old). \(action) to get a new one."
    }

    /// A usage row's second line: "5h resets in 1h 02m · 7d resets in
    /// 3d 5h", plus "no room for +1" when one more agent would not fit
    /// before the reset. A stale reading with a fix-it (`action`,
    /// "Reconnect Claude", "Run grok login") leads with the fix, and a
    /// window already past its reset says nothing: the source is broken,
    /// so no new reading is on its way to wait for. With no reset to
    /// name, the fix-it beats the bare state word.
    static func usageResetLine(for usage: CoreProviderUsage, primary: CoreUsageWindow?, secondary: CoreUsageWindow?,
                               noRoomForOneMore: Bool, now: Date) -> String {
        let action = usage.action?.trimmingCharacters(in: .whitespaces) ?? ""
        let fix = usage.staleFix
        var parts: [String] = fix.map { [$0] } ?? []
        for window in [primary, secondary].compactMap({ $0 }) {
            // The fix already leads, so a past window has nothing to add.
            if fix != nil, let resetsAt = window.resetsAt, resetHasPassed(resetsAt, now: now) { continue }
            if let text = countdown(to: window.resetsAt, now: now) { parts.append("\(window.shortName) \(text)") }
        }
        // An old reading's burn is history; the question it answers is
        // for a live one.
        if noRoomForOneMore, fix == nil { parts.append("no room for +1") }
        if parts.isEmpty {
            if !action.isEmpty { return action }
            if let state = usage.state, !state.isEmpty, state != "ready" { return state.replacingOccurrences(of: "_", with: " ") }
            return "no reset time"
        }
        return parts.joined(separator: " · ")
    }

    /// The slider's value: a local drag wins; devices that disagree show
    /// the brightest of them (the slider reads "Mixed"); else the Pro's
    /// brightness, else the lights document's.
    var brightness: Double {
        if let localBrightness { return localBrightness }
        if brightnessIsMixed, let brightest = brightnessReadings.map(\.fraction).max() { return brightest }
        if let pro = devices.first(where: { $0.kind == "pro" }), let value = pro.brightnessFraction { return value }
        if let any = devices.compactMap(\.brightnessFraction).first { return any }
        return core.lights?.hardware?.brightness ?? 0.8
    }

    var hasHardware: Bool { devices.contains { $0.kind == "pro" || $0.kind == "dot" } }

    /// What each present device says its brightness is, in the daemon's
    /// order.
    var brightnessReadings: [(name: String, fraction: Double)] {
        devices.compactMap { device in
            guard device.isPresent, let fraction = device.brightnessFraction else { return nil }
            return (device.name ?? Self.deviceWord(device.kind), fraction)
        }
    }

    /// The devices disagree by at least a whole percent, and no drag is
    /// in hand: one number on the slider would be true of one of them.
    /// A drag sets them all (`set_brightness "all"`), which ends it.
    var brightnessIsMixed: Bool {
        guard localBrightness == nil else { return false }
        return Set(brightnessReadings.map { Int(($0.fraction * 100).rounded()) }).count > 1
    }

    /// "Pro 80% · Dot 40% · Screen Bar 100%".
    var brightnessBreakdown: String {
        brightnessReadings.map { "\($0.name) \(Int(($0.fraction * 100).rounded()))%" }.joined(separator: " · ")
    }

    nonisolated static func deviceWord(_ kind: String) -> String {
        switch kind {
        case "pro": return "Pro"
        case "dot": return "Dot"
        case "screen_bar": return "Screen Bar"
        default: return kind.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: Actions

    /// A half-typed reply, keyed by the ask's request id. Persisted so
    /// closing the panel — or the app — mid-draft doesn't lose the text;
    /// clearing it takes a confirmed send, not just an edit.
    private struct ReplyDraft: Codable {
        var text: String
        var editedAt: TimeInterval
    }

    /// Kept small: a draft for an ask that no longer exists is clutter.
    private static let replyDraftsKey = "jrbar.askReplyDrafts.v1"
    private static let replyDraftLimit = 50
    private let draftsDefaults: UserDefaults
    private var replyDrafts: [String: ReplyDraft] = [:]

    /// The stable key: the request id while the episode is open, the
    /// ask's own id (session|summary|openedAt) when there is none.
    private static func draftKey(for ask: CoreAsk) -> String { ask.request ?? ask.id }

    func replyDraft(for ask: CoreAsk) -> String {
        replyDrafts[Self.draftKey(for: ask)]?.text ?? ""
    }

    func setReplyDraft(_ text: String, for ask: CoreAsk) {
        let key = Self.draftKey(for: ask)
        if text.isEmpty {
            replyDrafts.removeValue(forKey: key)
        } else {
            replyDrafts[key] = ReplyDraft(text: text, editedAt: Date().timeIntervalSince1970)
            if replyDrafts.count > Self.replyDraftLimit {
                // Oldest first: a draft whose ask resolved weeks ago is
                // the first to go.
                let overflow = replyDrafts.count - Self.replyDraftLimit
                for entry in replyDrafts.sorted(by: { $0.value.editedAt < $1.value.editedAt }).prefix(overflow) {
                    replyDrafts.removeValue(forKey: entry.key)
                }
            }
        }
        saveReplyDrafts()
    }

    private func loadReplyDrafts() -> [String: ReplyDraft] {
        guard let data = draftsDefaults.data(forKey: Self.replyDraftsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ReplyDraft].self, from: data)) ?? [:]
    }

    private func saveReplyDrafts() {
        guard let data = try? JSONEncoder().encode(replyDrafts) else { return }
        draftsDefaults.set(data, forKey: Self.replyDraftsKey)
    }

    /// While an answer for the ask's session is on the wire — from here or
    /// any other surface — the card's buttons are disabled, so a second
    /// click cannot post a second answer.
    func isAnswerPending(_ ask: CoreAsk) -> Bool { askDesk.isPending(ask.session) }

    /// Approve and Deny through the shared desk: the toast reports the
    /// daemon's verdict, not a guess — a refused answer leaves the ask
    /// open and says why — and how it went: through the agent's
    /// permission hook, or typed into the terminal. `request` pins the
    /// answer to the card's episode, so a session that moved on refuses
    /// `stale_request` rather than approving whatever is live now.
    func approve(_ ask: CoreAsk) { send(ask, .approve) }
    func deny(_ ask: CoreAsk) { send(ask, .deny) }

    /// The free-text reply a `replyable` ask asks for, sent as
    /// `reply_text` on the same `answer_ask` command. A daemon that cannot
    /// take text for this ask refuses, and the refusal is the toast. The
    /// draft clears only once the send is confirmed.
    func reply(_ ask: CoreAsk, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(ask, .reply(trimmed)) { [weak self] in self?.setReplyDraft("", for: ask) }
    }

    /// Always allow, from its own button only: the agent remembers the
    /// allow rule it offered (`CoreAsk.canAlwaysAllow`).
    func alwaysAllow(_ ask: CoreAsk) { send(ask, .always) }

    /// A click on one of a held question's options: the answer itself
    /// for a single-pick question, one more pick otherwise.
    func pick(_ label: String, in choice: CoreAskChoice, of ask: CoreAsk) {
        if let verdict = AskChoicePicks.oneClick(label, choices: ask.decision?.choices ?? []) {
            send(ask, verdict)
        } else {
            askDesk.toggle(label, in: choice, of: ask)
        }
    }

    /// The picks so far for a multi-question or multi-select ask.
    func picks(for ask: CoreAsk) -> AskChoicePicks { askDesk.picks(for: ask) }

    /// Send Answers: the collected picks, every question answered.
    func sendPicks(_ ask: CoreAsk) {
        guard let choices = ask.decision?.choices,
              let answers = askDesk.picks(for: ask).answers(choices) else {
            show(toast: "Pick an answer for every question first")
            return
        }
        send(ask, .choose(answers))
    }

    /// Every verdict the panel sends goes through the shared desk, so the
    /// notch, the Dock and a banner see the same answer in flight. A
    /// refusal the desk can name before sending is the toast at once;
    /// otherwise the outcome's line is, and `landed` runs only when the
    /// daemon took the answer.
    private func send(_ ask: CoreAsk, _ verdict: AskVerdict, landed: (@MainActor () -> Void)? = nil) {
        if let line = askDesk.refusal(ask, verdict) {
            show(toast: line)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.askDesk.answer(ask, verdict)
            if outcome.ok { landed?() }
            self.showAnswer(outcome)
        }
    }

    /// The desk's line, and for the one refusal the user can fix a button
    /// into System Settings' Accessibility pane.
    private func showAnswer(_ outcome: AskAnswerDesk.Outcome) {
        guard outcome.code == "accessibility_required" else {
            show(toast: outcome.line)
            return
        }
        show(toast: outcome.line, actionTitle: "Open Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// `SessionOpener`, awaited so its refusal is heard: an ended session
    /// answers `not_found` and the panel must say so rather than closing
    /// as if a window had just been raised, and a running one the daemon
    /// cannot find is raised by the Dock's window locator. Success closes
    /// the panel as the row's click always did.
    func open(_ row: SessionRow) {
        selectedID = row.id
        selectionByKeyboard = false
        Task { [weak self] in
            let refusal = await SessionOpener.open(row.id)
            guard let self else { return }
            if let refusal { self.show(toast: refusal) } else { self.onClose?() }
        }
    }

    /// `dismiss_session {session}` for a stuck or quiet row: the daemon
    /// hides it until it next speaks. Not offered where an ask is open —
    /// `SessionRow.isDismissible` is the gate the menu and ⌘⌫ share.
    func dismiss(_ row: SessionRow) {
        guard row.isDismissible else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.dismissSession(row.id)
                if reply.ok {
                    self.show(toast: "Dismissed \(row.label) — it returns when it next speaks")
                } else {
                    self.show(toast: reply.error?.message ?? "Could not dismiss \(row.label)")
                }
            } catch {
                self.show(toast: "The monitor is not answering")
            }
        }
    }

    /// ⌘⌫ on the selected row: dismiss what can be dismissed, clear what
    /// is already finished/ended/stale. Returns false when the selection
    /// is pinned by an ask or is a remote row — nothing to take back.
    @discardableResult
    func dismissSelected() -> Bool {
        guard let row = rows.first(where: { $0.id == selectedID }) else { return false }
        if row.isDismissible {
            dismiss(row)
            return true
        }
        if row.ask == nil && !row.isRemote && (row.activity.isClearable || row.stale) {
            clear(row)
            return true
        }
        return false
    }

    /// The batch the daemon's last `clear_completed` reply named, and when
    /// it landed: while it is inside `EventPolicy.undoWindow` the footer
    /// offers Undo beside "Clear finished".
    var undoOffer: (batch: String, at: Date, cleared: Int)?

    /// True while the offer stands (the clock ticks every second the panel
    /// is open, so this goes false on its own).
    var canUndoClear: Bool {
        guard let undoOffer else { return false }
        return now.timeIntervalSince(undoOffer.at) < EventPolicy.undoWindow
    }

    /// "Undo (4:38)": how long is left to take the clear back.
    var undoCountdown: String? {
        guard let undoOffer, canUndoClear else { return nil }
        let left = Int((EventPolicy.undoWindow - now.timeIntervalSince(undoOffer.at)).rounded(.up))
        return String(format: "%d:%02d", left / 60, left % 60)
    }

    /// `clear_completed {sessions: "all"}`: the daemon acknowledges every
    /// done, ended and stale row it listed. Undo is offered inline, in the
    /// footer, for the whole 300 s window rather than in a toast that is
    /// gone in two seconds.
    func clearCompleted() {
        guard completedCount > 0 else { show(toast: "Nothing to clear"); return }
        runClear(sessions: nil, expected: completedCount)
    }

    /// One `clear_completed` for the footer's "all" and a row's own
    /// "Clear": `sessions` nil asks for every clearable row, a list asks
    /// for just those. The reply's batch becomes the footer's Undo offer.
    private func runClear(sessions: [String]?, expected: Int? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.clearCompletedNow(sessions: sessions)
                guard reply.ok else {
                    self.show(toast: "Clear failed: \(reply.error?.message ?? reply.error?.code ?? "refused")")
                    return
                }
                let cleared = reply.result?["cleared"]?.arrayValue?.count ?? expected ?? sessions?.count ?? 0
                if let batch = reply.result?["batch"]?.stringValue {
                    self.undoOffer = (batch, Date(), cleared)
                    self.show(toast: cleared == 1 ? "Cleared 1 · Undo in the footer" : "Cleared \(cleared) · Undo in the footer")
                } else {
                    self.show(toast: "Cleared \(cleared)")
                }
            } catch {
                self.show(toast: "Clear failed: the monitor is not answering")
            }
        }
    }

    /// `undo_clear {batch}` for the offer that is standing.
    func undoClear() {
        guard let offer = undoOffer, canUndoClear else { return }
        undoOffer = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.send("undo_clear", args: ["batch": .string(offer.batch)])
                if reply.ok {
                    let restored = reply.result?["restored"]?.arrayValue?.count ?? offer.cleared
                    self.show(toast: restored == 1 ? "Restored 1 session" : "Restored \(restored) sessions")
                } else {
                    self.show(toast: "Undo failed: \(reply.error?.message ?? reply.error?.code ?? "refused")")
                }
            } catch {
                self.show(toast: "Undo failed: the monitor is not answering")
            }
        }
    }

    /// The ask ⌘↩ / ⌘D answer: the keyboard-selected card when it is an
    /// ask, else the first one the daemon says can be answered from here.
    /// With two or more asks open, the selected card is the target — the
    /// shortcuts never answer a card the user is not looking at.
    var selectedAsk: SessionRow? {
        visibleAskRows.first { $0.id == selectedID }
    }

    /// Only asks the list is showing: a query that filtered a card out
    /// must not let ⌘↩ answer it unseen.
    var keyboardAsk: SessionRow? {
        if let selectedAsk { return selectedAsk }
        let askRows = visibleAskRows
        return askRows.first { $0.ask?.canAnswer == true && !($0.isRemote) } ?? askRows.first
    }

    func approveSelectedAsk() {
        guard let ask = keyboardAsk?.ask else { return }
        approve(ask)
    }

    func denySelectedAsk() {
        guard let ask = keyboardAsk?.ask else { return }
        deny(ask)
    }

    /// `snooze {session, seconds}` — the daemon resolves the session's
    /// family work key, so one snooze covers every session in the family.
    /// `seconds: 0` lifts it.
    /// A live local run that is neither asking nor finished can be quieted
    /// ("quiet this run until it needs me"): working or idle.
    nonisolated static func canQuietRun(_ row: SessionRow) -> Bool {
        !row.isRemote && row.ask == nil && (row.activity == .working || row.activity == .idle)
    }

    /// The same mailbox snooze, said the way it lands on a working run:
    /// quiet until it needs you.
    func quietRun(_ row: SessionRow, seconds: Int) {
        guard Self.canQuietRun(row), seconds > 0 else { return }
        // This run alone — a worker quieted here leaves its family's
        // other runs speaking, which the family-wide snooze did not.
        core.quietRun(session: row.id, seconds: seconds)
        let until = Date().addingTimeInterval(TimeInterval(seconds))
        show(toast: "\(row.label) is quiet until \(Self.clockTime(until)) unless it asks")
    }

    func snooze(_ row: SessionRow, seconds: Int) {
        core.snooze(session: row.id, seconds: seconds)
        if seconds > 0 {
            let until = Date().addingTimeInterval(TimeInterval(seconds))
            show(toast: "Snoozed \(row.label) until \(Self.clockTime(until))")
        } else {
            show(toast: "Unsnoozed \(row.label)")
        }
    }

    /// `clear_completed {sessions: [id]}` for one finished, ended or stale
    /// row. Same reply handling as "Clear finished": the batch is the undo
    /// offer in the footer.
    func clear(_ row: SessionRow) {
        guard row.activity.isClearable || row.stale else { return }
        runClear(sessions: [row.id])
    }

    /// The full working directory, on the pasteboard.
    func copyPath(_ row: SessionRow) {
        guard let cwd = row.cwd, !cwd.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
        show(toast: "Copied \(cwd)")
    }

    /// The working directory selected in a Finder window.
    func reveal(_ row: SessionRow) {
        guard let cwd = row.cwd, !cwd.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    /// The slider's stream of values, throttled to one `set_brightness`
    /// per `brightnessInterval` while dragging (the first change goes out
    /// at once, the latest value follows on the next tick), and flushed
    /// immediately when the drag ends.
    static let brightnessInterval: TimeInterval = 0.12

    func setBrightness(_ value: Double, final: Bool) {
        localBrightness = value
        let now = Date()
        if final || now.timeIntervalSince(brightnessSentAt) >= Self.brightnessInterval {
            brightnessFlush?.cancel()
            brightnessFlush = nil
            sendBrightness(value, final: final)
            return
        }
        guard brightnessFlush == nil else { return }   // a trailing send is already scheduled; it reads the latest value
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.brightnessFlush = nil
                if let latest = self.localBrightness { self.sendBrightness(latest, final: false) }
            }
        }
        brightnessFlush = work
        let wait = max(0, Self.brightnessInterval - now.timeIntervalSince(brightnessSentAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func sendBrightness(_ value: Double, final: Bool) {
        brightnessSentAt = Date()
        core.setBrightness(device: "all", value: value)
        if final {
            // Let the daemon's next state carry the value from here.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.localBrightness = nil }
            }
        }
    }

    func toggleScreenBar() {
        screenBarShown.toggle()
        onToggleScreenBar?(screenBarShown)
    }

    func openSettings(page: SettingsStore.Page? = nil) {
        onClose?()
        onOpenSettings?(page)
    }

    func openHistory() {
        onClose?()
        onOpenHistory?()
    }

    func openOverview() {
        onClose?()
        onOpenOverview?()
    }

    func openUsageCenter(provider: String? = nil) {
        onClose?()
        onOpenUsageCenter?(provider)
    }

    func openEffects() {
        onClose?()
        onOpenEffects?()
    }

    func openControlCenter() {
        onClose?()
        onOpenControlCenter?()
    }

    func checkForUpdates() {
        onClose?()
        onCheckForUpdates?()
    }

    func openEvents() {
        onClose?()
        onOpenEvents?()
    }

    /// ⌘K in the panel, and the first item in More: the panel folds and
    /// the palette opens in its place.
    func openCommandPalette() {
        onClose?()
        onOpenPalette?()
    }

    func openWhatsNew() {
        onClose?()
        onOpenWhatsNew?()
    }

    /// A pad the daemon knows — approved, or seen by its HID probe — or
    /// the pad switched on in its settings: then the menus list Creator
    /// Micro. A Mac that never had one never sees the word.
    var hasCreatorMicro: Bool {
        guard let deck = core.state?.deck else { return false }
        return deck.device != nil || deck.settings.enabled
    }

    /// Runs one of the menus' shared verbs (`AppMenuCatalog`).
    func perform(_ verb: AppMenuVerb) {
        switch verb {
        case .commandPalette: openCommandPalette()
        case .history: openHistory()
        case .events: openEvents()
        case .overview: openOverview()
        case .usageCenter: openUsageCenter()
        case .effects: openEffects()
        case .creatorMicro: openControlCenter()
        case .whatsNew: openWhatsNew()
        case .checkForUpdates: checkForUpdates()
        case .settings: openSettings()
        case .quit: quit()
        }
    }

    func restartCore() {
        onRestartCore?()
        show(toast: "Restarting the monitor…")
    }

    func quit() { onQuit?() }

    /// The toast's optional action (a small button inside the capsule) —
    /// set only by `show(toast:actionTitle:action:)`, cleared with the text.
    var toastAction: (title: String, run: () -> Void)?

    func show(toast text: String) {
        toastAction = nil
        present(toast: text, life: 2.2)
    }

    /// A toast with a button (the refused-answer "Open Settings"); it stays
    /// up long enough to be read and clicked.
    func show(toast text: String, actionTitle: String, action: @escaping () -> Void) {
        toastAction = (actionTitle, action)
        present(toast: text, life: 6)
    }

    /// Where a line that did not come from a panel click is said.
    enum FeedbackRoute: Equatable {
        /// The panel's toast: the panel is open, or a palette verb's
        /// ticket will hear the toast and say it in the palette's HUD.
        case toast
        /// The glass HUD on the screen under the pointer, since a closed
        /// panel's toast is seen by nobody.
        case hud
    }

    nonisolated static func feedbackRoute(panelOpen: Bool, paletteListening: Bool) -> FeedbackRoute {
        panelOpen || paletteListening ? .toast : .hud
    }

    private func present(toast text: String, life: TimeInterval) {
        toast = text
        // A palette verb's answer: the ticket it runs under hears it, so
        // the palette's HUD says this line and no other.
        PaletteVerbScope.ticket?.hear(text)
        toastClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.toast = nil; self?.toastAction = nil }
        }
        toastClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + life, execute: work)
    }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        selectionByKeyboard = true
        let current = rows.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : rows.count)
        let next = min(rows.count - 1, max(0, current + delta))
        selectedID = rows[next].id
    }

    func activateSelection() {
        guard let row = visibleRows.first(where: { $0.id == selectedID }) else { return }
        open(row)
    }

    // MARK: Formatting

    nonisolated static func elapsed(since date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%dh %02dm", hours, minutes % 60) }
        return "\(hours / 24)d \(hours % 24)h"
    }

    nonisolated static func countdown(to epoch: Double?, now: Date) -> String? {
        guard let epoch else { return nil }
        // Past the reset the number on screen is the old window's until
        // the next reading lands; "resets now" read like a promise.
        if resetHasPassed(epoch, now: now) { return "reset — waiting for a new reading" }
        let seconds = Int(epoch - now.timeIntervalSince1970)
        let minutes = (seconds + 30) / 60
        if minutes < 60 { return "resets in \(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "resets in %dh %02dm", hours, minutes % 60) }
        return "resets in \(hours / 24)d \(hours % 24)h"
    }

    /// A window's reset for a source that may be broken, the panel's
    /// rule for every usage surface: past its reset, a stale source with
    /// a fix-it (`fix`, `CoreProviderUsage.staleFix`: "Reconnect
    /// Claude", "Run grok login") names the fix, because the new reading
    /// `countdown` would wait for never comes until someone acts. A
    /// healthy source, a stale one with no fix, and a reset still ahead
    /// read exactly as `countdown` words them.
    nonisolated static func countdown(to epoch: Double?, now: Date, fix: String?) -> String? {
        if let epoch, let fix, !fix.isEmpty, resetHasPassed(epoch, now: now) { return fix }
        return countdown(to: epoch, now: now)
    }

    /// Under a second to go is past: the whole seconds `countdown`
    /// counts down have run out.
    nonisolated static func resetHasPassed(_ epoch: Double, now: Date) -> Bool {
        epoch - now.timeIntervalSince1970 < 1
    }

    /// The daemon's `forecast.pace` as the outcome it names, not the
    /// race-course word it sends: "ahead of pace" used to read as headroom
    /// when it means the window runs dry early. A window that resets
    /// before it runs out is on track and says nothing.
    nonisolated static func paceHint(_ pace: String?) -> String? {
        switch pace?.lowercased() {
        case "ahead": return "runs out early"
        case "behind", "under": return nil
        case "on", "on_pace", "on-pace", "onpace", "steady": return "on pace"
        case "exhausted": return "used up"
        // A guarded pace already explains itself through the forecast's
        // `reason`; "guarded" as a bare hint would read like a verdict.
        case "guarded": return nil
        case nil, "": return nil
        case let other?: return other.replacingOccurrences(of: "_", with: " ")
        }
    }
}
