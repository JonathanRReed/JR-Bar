import AppKit
import Foundation
import JRBarCore
import Observation

/// What a session is doing, reduced to the five things the panel can show.
enum SessionActivity: Equatable {
    case working
    case waiting
    case done
    case failed
    case idle

    var word: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting on you"
        case .done: return "Done"
        case .failed: return "Failed"
        case .idle: return "Idle"
        }
    }

    static func reduce(_ session: CoreSession) -> SessionActivity {
        let lifecycle = session.lifecycle?.lowercased() ?? "active"
        let mode = session.mode?.lowercased() ?? ""
        if lifecycle == "failed" || mode == "failed" || mode == "error" { return .failed }
        if lifecycle == "completed" || lifecycle == "done" || mode == "completed" { return .done }
        if session.ask != nil || mode == "waiting" || mode == "ask" || session.nextActor == "user" { return .waiting }
        if ["working", "tool_running", "thinking", "running", "active"].contains(mode) { return .working }
        return .idle
    }
}

/// One line in the Sessions section.
struct SessionRow: Identifiable, Equatable {
    let id: String
    let style: ProviderStyle
    let label: String
    let cwdTail: String?
    let activity: SessionActivity
    let since: Date?
    let workers: Int
    let ask: CoreAsk?
    let stale: Bool

    init(session: CoreSession, pinnedAsk: CoreAsk?) {
        id = session.id
        style = ProviderStyle.style(for: session.provider)
        label = session.label?.isEmpty == false ? session.label! : style.name
        cwdTail = session.cwd.map { Self.tail(of: $0) }
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
    var now = Date()
    var localBrightness: Double?
    var toast: String?
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var contentSize: CGSize = .zero {
        didSet { if contentSize != oldValue { onContentSizeChange?(contentSize) } }
    }

    // Wiring back to AppKit.
    var onToggleScreenBar: (@MainActor (Bool) -> Void)?
    var onQuit: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?
    var onOpenSettings: (@MainActor () -> Void)?
    var onOpenHistory: (@MainActor () -> Void)?
    var onOpenUsageCenter: (@MainActor () -> Void)?
    var onOpenEffects: (@MainActor () -> Void)?
    var onRestartCore: (@MainActor () -> Void)?
    var onContentSizeChange: (@MainActor (CGSize) -> Void)?
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
        now = Date()
        clock?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id
        }
    }

    func panelDidClose() {
        isOpen = false
        clock?.invalidate()
        clock = nil
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

    /// Asks first (newest ask last, as the daemon lists them), then the
    /// rest: waiting, working, done, idle; ties by most recent change.
    var rows: [SessionRow] {
        guard core.isLive else { return [] }
        let pinned = Dictionary(core.asks.compactMap { ask in ask.session.map { ($0, ask) } }, uniquingKeysWith: { first, _ in first })
        let rows = core.sessions.map { SessionRow(session: $0, pinnedAsk: pinned[$0.id]) }
        func rank(_ row: SessionRow) -> Int {
            if row.ask != nil { return 0 }
            switch row.activity {
            case .waiting: return 1
            case .failed: return 2
            case .working: return 3
            case .done: return 4
            case .idle: return 5
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
    var completedCount: Int { rows.filter { $0.activity == .done }.count }

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
        core.openSession(row.id)
        onClose?()
    }

    func clearCompleted() {
        guard completedCount > 0 else { show(toast: "Nothing to clear"); return }
        core.clearCompleted()
        show(toast: "Cleared · undo within 5 min from the core")
    }

    func quiet(minutes: Int) {
        core.quiet(seconds: minutes * 60)
        show(toast: minutes >= 60 ? "Quiet for \(minutes / 60) h" : "Quiet for \(minutes) min")
    }

    func setBrightness(_ value: Double, final: Bool) {
        localBrightness = value
        brightnessFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.core.setBrightness(device: "all", value: value)
                if final {
                    // Let the daemon's next state carry the value from here.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        MainActor.assumeIsolated { self?.localBrightness = nil }
                    }
                }
            }
        }
        brightnessFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (final ? 0 : 0.12), execute: work)
    }

    func toggleScreenBar() {
        screenBarShown.toggle()
        onToggleScreenBar?(screenBarShown)
    }

    func openSettings() {
        onClose?()
        onOpenSettings?()
    }

    func openHistory() {
        onClose?()
        onOpenHistory?()
    }

    func openUsageCenter() {
        onClose?()
        onOpenUsageCenter?()
    }

    func openEffects() {
        onClose?()
        onOpenEffects?()
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
        case "behind": return "under pace"
        case "on_pace", "on-pace", "onpace", "steady": return "on pace"
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
