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
    let ask: CoreAsk?
    let stale: Bool

    init(session: CoreSession, pinnedAsk: CoreAsk?, document: SettingsDocument? = nil) {
        id = session.id
        style = ProviderStyle.style(for: session.provider, document: document)
        label = session.displayLabel
        cwd = session.cwd
        cwdTail = session.cwd.map { Self.tail(of: $0) }
        terminalApp = session.terminal?.app
        snoozedUntil = session.snoozedUntil
        activity = SessionActivity.reduce(session)
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
        let provider = String(session.split(separator: ":").first ?? "")
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
    }

    /// The row's whole tooltip: the full working directory, the snooze
    /// while one is in effect, and why a stale row is still listed.
    func help(now: Date) -> String? {
        var parts: [String] = []
        if let cwd, !cwd.isEmpty { parts.append(cwd) }
        if isSnoozed(now: now), let until = snoozedUntil {
            parts.append("Snoozed until \(PanelStore.clockTime(Date(timeIntervalSince1970: until)))")
        }
        if stale { parts.append("No signal in a while — the session may have ended without a goodbye") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
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

    // Fallback (file feeds) and app-owned state.
    var fallbackState: AgentAggregateState = .idle
    var fallbackDetail: String = "No agent monitor state"
    var feedDescription: String = "resolving"
    var screenBarShown = true

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
    /// The visible height of the screen the panel opens on; the layout caps
    /// the panel at a fraction of it.
    var screenHeight: Double = 900

    // Wiring back to AppKit.
    var onToggleScreenBar: (@MainActor (Bool) -> Void)?
    var onQuit: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?
    var onOpenSettings: (@MainActor (SettingsStore.Page?) -> Void)?
    var onOpenHistory: (@MainActor () -> Void)?
    /// The provider a usage row was clicked for, when it was.
    var onOpenUsageCenter: (@MainActor (String?) -> Void)?
    var onOpenEffects: (@MainActor () -> Void)?
    var onOpenControlCenter: (@MainActor () -> Void)?
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

    init(core: CoreModel) {
        self.core = core
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
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
            Task { @MainActor [weak self] in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        refreshSparklines()
    }

    func panelDidClose() {
        isOpen = false
        animationsArmed = false
        selectedID = nil
        selectionByKeyboard = false
        clock?.invalidate()
        clock = nil
    }

    // MARK: Derived: layout

    /// What the panel shows, counted for `PanelLayout`.
    var layoutContent: PanelLayout.Content {
        PanelLayout.Content(asks: askRows.count, sessions: plainRows.count, hasWhyRow: lightExplanation != nil,
                            usageProviders: usage.count, hasHiddenFooter: hiddenCount > 0)
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
        if case .crashed(let failures) = supervisorState { return "Core crashed \(failures)× in 2 min" }
        return "Core crashed"
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
            return "Core exited (\(failures)×); restarting in \(String(format: "%.1f", delay)) s"
        }
        if coreCrashed { return "\(coreCrashDetail). Restart it from the header." }
        switch core.connection {
        case .connected where core.state != nil:
            let version = core.hello?.coreVersion ?? "?"
            return "Core \(version) connected"
        case .connected: return "Connected, waiting for state"
        case .connecting(let attempt): return attempt <= 1 ? "Connecting to core…" : "Reconnecting to core (try \(attempt))…"
        case .disconnected(let reason): return "Core disconnected: \(reason)"
        case .idle: return "Core client idle"
        }
    }

    var aggregate: AgentAggregateState {
        if core.isLive, let state = core.state { return AgentAggregateState.from(aggregate: state.aggregate) }
        return fallbackState
    }

    var headerWord: String { aggregate.label }

    /// "2 working · 1 needs you · 1 ready", or the file-feed detail line.
    var headerCounts: String {
        guard core.isLive, let state = core.state else { return fallbackDetail }
        var parts: [String] = []
        let aggregate = state.aggregate
        if aggregate.active > 0 { parts.append("\(aggregate.active) working") }
        if aggregate.needsYou > 0 { parts.append(aggregate.needsYou == 1 ? "1 needs you" : "\(aggregate.needsYou) need you") }
        if aggregate.ready > 0 { parts.append("\(aggregate.ready) ready") }
        if parts.isEmpty {
            let total = state.mainSessions.count
            return total == 0 ? "No sessions" : (total == 1 ? "1 session, quiet" : "\(total) sessions, quiet")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Derived: sessions

    /// The daemon's settings document, for provider colour overrides.
    var settingsDocument: SettingsDocument? {
        core.settings.map { SettingsDocument($0.document) }
    }

    /// Asks first (newest ask last, as the daemon lists them), then the
    /// rest: waiting, working, done, idle; ties by most recent change.
    var rows: [SessionRow] {
        guard core.isLive else { return [] }
        let document = settingsDocument
        let pinned = Dictionary(core.asks.compactMap { ask in ask.session.map { ($0, ask) } }, uniquingKeysWith: { first, _ in first })
        // An ask whose session the daemon no longer lists still needs an
        // answer: it is counted in the header and it is what the light is
        // about, so it gets a row of its own rather than disappearing.
        let orphans = (core.state?.orphanAsks ?? []).map { SessionRow(orphanAsk: $0, document: document) }
        let rows = core.sessions.map { SessionRow(session: $0, pinnedAsk: pinned[$0.id], document: document) } + orphans
        func rank(_ row: SessionRow) -> Int {
            if row.ask != nil { return 0 }
            switch row.activity {
            case .waiting: return 1
            case .failed: return 2
            case .working: return 3
            case .done: return 4
            // An ended run is over and nobody is waiting on it: it sits
            // under the finished ones, above the merely idle.
            case .ended: return 5
            case .idle: return 6
            }
        }
        return rows.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return (a.since ?? .distantPast) > (b.since ?? .distantPast)
        }
    }

    /// What the Screen Bar's tooltip names: a live ask first, then a failure,
    /// then whoever is working, then an unseen completion; with nothing live
    /// the aggregate word. The click target is stricter: an ask's session or
    /// the working one, else nothing.
    var screenBarFocus: ScreenBarFocus {
        let rows = rows
        let pick = rows.first { $0.ask != nil }
            ?? rows.first { $0.activity == .failed }
            ?? rows.first { $0.activity == .working }
            ?? rows.first { $0.activity == .done }
        let clickable = rows.first { $0.ask != nil } ?? rows.first { $0.activity == .working }
        if let pick {
            let word = pick.ask != nil ? "Needs you" : pick.activity.word
            return ScreenBarFocus(style: pick.style, label: pick.label, word: word, clickSession: clickable?.id, explanation: lightExplanation?.headline)
        }
        let word = core.isLive ? aggregate.label : (fallbackState == .idle ? "Idle" : fallbackState.label)
        return ScreenBarFocus(style: nil, label: "JR-Bar", word: word, clickSession: nil, explanation: lightExplanation?.headline)
    }

    var askRows: [SessionRow] { rows.filter { $0.ask != nil } }
    var plainRows: [SessionRow] { rows.filter { $0.ask == nil } }
    /// What "Clear done" acknowledges: finished runs, ended ones and
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
    var lightExplanation: LightExplanation? {
        guard core.isLive else { return nil }
        let settings = core.settings.map { SettingsDocument($0.document) }
        return LightExplainer.explain(lights: core.lights, state: core.state, settings: settings, now: now)
    }

    func whyHover(_ hovering: Bool, frame: CGRect) {
        onWhyHover?(hovering, frame)
    }

    func openExplainedSession() {
        guard let session = lightExplanation?.session else { return }
        core.openSession(session)
        onClose?()
    }

    // MARK: Derived: usage and devices

    /// Providers with at least one window; signed-out ones are the Usage Center's business.
    var usage: [CoreProviderUsage] { core.isLive ? core.usage.filter { !$0.windows.isEmpty } : [] }
    var devices: [CoreDevice] { core.isLive ? core.devices : [] }

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

    /// Asks the daemon for `usage_graph_days` of history — week or month,
    /// see `sparklineRange` — for every provider the panel shows, unless
    /// it asked recently. Failures are silent: a row without a sparkline
    /// simply has none. `force` is for the `usage_history_ready` event,
    /// which means the rows just changed.
    func refreshSparklines(force: Bool = false) {
        guard core.isLive else { return }
        let now = Date()
        let range = sparklineRange
        for provider in usage {
            let id = provider.id
            if !force, let at = sparklineFetchedAt[id], now.timeIntervalSince(at) < Self.sparklineInterval { continue }
            sparklineFetchedAt[id] = now
            Task { [weak self] in
                guard let self else { return }
                do {
                    let history = try await self.core.usageHistory(provider: id, range: range)
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

    /// The two windows a usage row draws: the 5 h window (else the first)
    /// and the 7 d window (else the next one).
    static func windows(of usage: CoreProviderUsage) -> (primary: CoreUsageWindow?, secondary: CoreUsageWindow?) {
        let primary = usage.windows.first { $0.shortName == "5h" } ?? usage.windows.first
        let secondary = usage.windows.first { $0.shortName == "7d" && $0.id != primary?.id }
            ?? usage.windows.first { $0.id != primary?.id }
        return (primary, secondary)
    }

    /// The slider's value: a local drag wins, else the Pro's brightness, else the lights document's.
    var brightness: Double {
        if let localBrightness { return localBrightness }
        if let pro = devices.first(where: { $0.kind == "pro" }), let value = pro.brightnessFraction { return value }
        if let any = devices.compactMap(\.brightnessFraction).first { return any }
        return core.lights?.hardware?.brightness ?? 0.8
    }

    var hasHardware: Bool { devices.contains { $0.kind == "pro" || $0.kind == "dot" } }

    // MARK: Actions

    func approve(_ ask: CoreAsk) {
        guard let session = ask.session else { return }
        core.answerAsk(session: session, approve: true)
        show(toast: "Approved · typed into the session's terminal")
    }

    func deny(_ ask: CoreAsk) {
        guard let session = ask.session else { return }
        core.answerAsk(session: session, approve: false)
        show(toast: "Denied")
    }

    func open(_ row: SessionRow) {
        selectedID = row.id
        selectionByKeyboard = false
        core.openSession(row.id)
        onClose?()
    }

    /// The batch the daemon's last `clear_completed` reply named, and when
    /// it landed: while it is inside `EventPolicy.undoWindow` the footer
    /// offers Undo in place of "Clear done".
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
                self.show(toast: "Clear failed: the core is not answering")
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
                self.show(toast: "Undo failed: the core is not answering")
            }
        }
    }

    /// The ask ⌘↩ / ⌘D answer: the keyboard-selected card when it is an
    /// ask, else the first one. With two or more asks open, the selected
    /// card is the target — the shortcuts never answer a card the user
    /// is not looking at.
    var selectedAsk: SessionRow? {
        askRows.first { $0.id == selectedID }
    }

    var keyboardAsk: SessionRow? { selectedAsk ?? askRows.first }

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
    /// row. Same reply handling as "Clear done": the batch is the undo
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

    func restartCore() {
        onRestartCore?()
        show(toast: "Restarting the core…")
    }

    func quit() { onQuit?() }

    func show(toast text: String) {
        toast = text
        toastClear?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.toast = nil } }
        toastClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        selectionByKeyboard = true
        let current = rows.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : rows.count)
        let next = min(rows.count - 1, max(0, current + delta))
        selectedID = rows[next].id
    }

    func activateSelection() {
        guard let row = rows.first(where: { $0.id == selectedID }) else { return }
        open(row)
    }

    // MARK: Formatting

    static func elapsed(since date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%dh %02dm", hours, minutes % 60) }
        return "\(hours / 24)d \(hours % 24)h"
    }

    static func countdown(to epoch: Double?, now: Date) -> String? {
        guard let epoch else { return nil }
        let seconds = Int(epoch - now.timeIntervalSince1970)
        if seconds <= 0 { return "resets now" }
        let minutes = (seconds + 30) / 60
        if minutes < 60 { return "resets in \(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "resets in %dh %02dm", hours, minutes % 60) }
        return "resets in \(hours / 24)d \(hours % 24)h"
    }

    static func paceHint(_ pace: String?) -> String? {
        switch pace?.lowercased() {
        case "ahead": return "ahead of pace"
        case "behind", "under": return "under pace"
        case "on", "on_pace", "on-pace", "onpace", "steady": return "on pace"
        case "exhausted": return "used up"
        case nil, "": return nil
        case let other?: return other.replacingOccurrences(of: "_", with: " ")
        }
    }
}

extension AgentAggregateState {
    /// `state.aggregate.mode` → the status item's five words.
    static func from(aggregate: CoreAggregate) -> AgentAggregateState {
        let mode = aggregate.mode.lowercased()
        if aggregate.needsYou > 0 || mode.contains("need") || mode.contains("ask") || mode.contains("wait") { return .needsInput }
        if mode.contains("fail") || mode.contains("error") || mode.contains("block") { return .failed }
        if mode.contains("work") || mode.contains("active") || mode.contains("run") || aggregate.active > 0 { return .working }
        if mode.contains("done") || mode.contains("complet") || mode.contains("ready") || aggregate.ready > 0 { return .completed }
        return .idle
    }
}
