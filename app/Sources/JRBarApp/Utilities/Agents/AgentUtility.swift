import AppKit
import JRBarCore
import Observation
import SwiftUI

/// The Agent Overview utility (docs/UTILITIES.md): the management seat
/// for the agent roster on the Utilities page. The Overview window is
/// the canvas — this card is the compact list, the counts by state,
/// and the session actions the panel already owns (`open_session`,
/// `answer_ask`, `dismiss_session`, `clear_completed`, `undo_clear`,
/// `snooze`), plus the organizer settings that decide what the list
/// shows. It tracks nothing itself: `CoreModel`'s `state.sessions` is
/// the roster and `SessionActivity.reduce` is the vocabulary — one
/// source, never a second projection that could disagree with the
/// panel.
@MainActor
@Observable
final class AgentUtility: Toy {
    /// The daemon model — the roster and the command channel.
    let core: CoreModel
    /// Live read of the persisted organizer settings — the store wires
    /// it to `state.agents`, so the card's observation of the store's
    /// `state` still registers through the closure.
    @ObservationIgnored var settings: @MainActor () -> AgentOrganizerSettings = { AgentOrganizerSettings() }
    /// The card's write path: a mutated copy lands in the store's
    /// `state`, whose `didSet` persists it.
    @ObservationIgnored var onSettingsChange: (@MainActor (AgentOrganizerSettings) -> Void)?
    /// The "Open full overview" row's target — the delegate wires it to
    /// `OverviewWindowController.show()`. Left unset the row hides, so
    /// the utility stands alone.
    @ObservationIgnored var onOpenOverview: (@MainActor () -> Void)?

    /// Asks with an `answer_ask` still on the wire, keyed by ask id —
    /// while one is in flight the row's buttons disable so a second
    /// click cannot post a second answer (`PanelStore.pendingAnswers`).
    private(set) var pendingAnswers: Set<String> = []
    /// The last action's one-line result ("Cleared 2 · Undo below"), the
    /// card-local stand-in for the panel's toast; auto-clears.
    private(set) var notice: String?
    @ObservationIgnored private var noticeClear: DispatchWorkItem?

    init(core: CoreModel) { self.core = core }

    // MARK: Toy

    let id = "agents"
    let name = "Agent Overview"
    let blurb = "The roster, organized — who's working, waiting on you, done — with the session actions the panel owns."
    let symbol = "person.2"

    var isOn: Bool {
        get { settings().enabled }
        set { update { $0.enabled = newValue } }
    }

    var status: ToyStatus {
        guard isOn else { return .off }
        return core.isLive ? .on : .paused("Monitor not connected")
    }

    var controls: AnyView { AnyView(AgentUtilityControls(utility: self)) }

    // MARK: Settings writes

    /// A card edit: mutate a copy of the persisted settings and hand it
    /// to the store, whose `state` write persists it — the same shape
    /// `MenuBarUtility` uses.
    func update(_ mutate: (inout AgentOrganizerSettings) -> Void) {
        var draft = settings()
        mutate(&draft)
        onSettingsChange?(draft)
    }

    /// A binding into the persisted settings.
    func bind<T>(_ keyPath: WritableKeyPath<AgentOrganizerSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings()[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    /// The store's `applySettings` reaches every utility through here.
    /// Nothing to start or stop — the roster is `CoreModel`'s and every
    /// row reads it live; the seat matches the other utilities anyway.
    func applySettings() {}

    // MARK: The list

    /// The daemon's settings document, for provider colour overrides —
    /// `PanelStore.settingsDocument`'s read.
    private var document: SettingsDocument? {
        core.settings.map { SettingsDocument($0.document) }
    }

    /// The organizer's filtered, ordered sessions — the whole cut, not
    /// the capped one the card lists.
    private var organized: [CoreSession] {
        guard isOn, core.isLive else { return [] }
        return settings().filtered(core.sessions, asks: core.asks)
    }

    /// What "Clear finished" acknowledges on this card: finished, ended
    /// and stale rows — `PanelStore.completedCount`'s gate.
    var completedCount: Int {
        organized.filter { SessionActivity.reduce($0).isClearable || $0.stale }.count
    }

    /// Asks whose session the daemon no longer lists get a leading
    /// "Needs you" section — `state.orphanAsks` counted by the header
    /// must never be the one thing the card does not show.
    var orphanRows: [SessionRow] {
        guard isOn, core.isLive else { return [] }
        return (core.state?.orphanAsks ?? []).map { SessionRow(orphanAsk: $0, document: document) }
    }

    /// Rows past the card's `rowLimit`, for the "+N more" line.
    var overflowCount: Int {
        max(0, organized.count - settings().rowLimit)
    }

    /// The card's sections: the organizer's groups over the capped list,
    /// sessions as `SessionRow`s so the card draws the panel's row.
    /// Orphan asks lead as their own "Needs you" section in every
    /// grouping — they are rank-0 rows with no session to file under.
    var groups: [(key: String, title: String, rows: [SessionRow])] {
        let capped = Array(organized.prefix(settings().rowLimit))
        var result: [(key: String, title: String, rows: [SessionRow])] = []
        let orphans = orphanRows
        if !orphans.isEmpty {
            // "__asks__" can't collide with a provider id or an activity
            // word — the ForEach ids stay unique.
            result.append(("__asks__", "Needs you", orphans))
        }
        let pinned = AgentOrganizerSettings.pinnedAsks(core.asks)
        let document = document
        result += settings().grouped(capped, asks: core.asks).map { group in
            (group.key, group.title,
             group.sessions.map { SessionRow(session: $0, pinnedAsk: pinned[$0.id], document: document) })
        }
        return result
    }

    /// "1 waiting on you · 2 working" — the organizer's counts over the
    /// filtered set plus the orphan asks as waiting, so the line and the
    /// list read the same rows.
    var countParts: [String] {
        var tally: [SessionActivity: Int] = [:]
        for entry in settings().counts(of: organized, asks: core.asks) {
            tally[entry.activity] = entry.count
        }
        let orphans = orphanRows.count
        if orphans > 0 { tally[.waiting, default: 0] += orphans }
        return SessionActivity.allCases
            .filter { (tally[$0] ?? 0) > 0 }
            .sorted { $0.sortRank < $1.sortRank }
            .map { activity in
                let count = tally[activity] ?? 0
                return "\(count) \(activity.word.lowercased())"
            }
    }

    // MARK: Actions — the panel's verbs, not new ones

    /// `open_session`, awaited so its refusal is heard — the panel's
    /// `open`: a remote row has no local window, an ended one answers
    /// `not_found`, and the notice says so either way.
    func open(_ row: SessionRow) {
        if row.isRemote {
            show(notice: row.remoteMachine.map { "Running on \($0) — open it there" }
                         ?? "A remote session — open it on the machine it runs on")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.send("open_session", args: ["session": .string(row.id)])
                if !reply.ok {
                    self.show(notice: reply.error?.message ?? "Could not open \(row.label)")
                }
            } catch {
                self.show(notice: "The monitor is not answering")
            }
        }
    }

    func approve(_ ask: CoreAsk) { answer(ask, approve: true) }
    func deny(_ ask: CoreAsk) { answer(ask, approve: false) }

    /// `answer_ask`, awaited — `PanelStore.answer`'s guards: the daemon's
    /// verdict is the notice, a remote ask is answered where it runs,
    /// and `request` pins the answer to its episode so a moved-on ask
    /// refuses `stale_request` instead of approving whatever is live.
    private func answer(_ ask: CoreAsk, approve: Bool) {
        guard let session = ask.session, !session.isEmpty else {
            show(notice: "This ask has no session left to answer")
            return
        }
        guard ask.canAnswer else {
            show(notice: "This one has to be answered in the session's window")
            return
        }
        guard !pendingAnswers.contains(ask.id) else { return }
        if CoreSession.isRemoteID(session) {
            show(notice: "Runs on \(CoreSession.remoteMachine(inID: session) ?? "another Mac") — answer it there")
            return
        }
        pendingAnswers.insert(ask.id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingAnswers.remove(ask.id) }
            do {
                let reply = try await self.core.answerAskNow(session: session, approve: approve,
                                                             request: ask.request)
                if reply.ok {
                    self.show(notice: approve ? "Approved" : "Denied")
                } else {
                    self.show(notice: "Couldn't answer: \(reply.error?.message ?? reply.error?.code ?? "refused")")
                }
            } catch {
                self.show(notice: "No answer from the monitor — the ask is still open")
            }
        }
    }

    /// `dismiss_session {session}` for a stuck or quiet row — the
    /// daemon hides it until it next speaks. `SessionRow.isDismissible`
    /// is the gate, the same one the panel's menu uses.
    func dismiss(_ row: SessionRow) {
        guard row.isDismissible else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.dismissSession(row.id)
                self.show(notice: reply.ok
                          ? "Dismissed \(row.label) — it returns when it next speaks"
                          : (reply.error?.message ?? "Could not dismiss \(row.label)"))
            } catch {
                self.show(notice: "The monitor is not answering")
            }
        }
    }

    /// `snooze {session, seconds}` — the family mailbox; `seconds: 0`
    /// lifts it. `snoozeUntilMorning` is the panel's "Snooze until
    /// tomorrow" preset.
    func snooze(_ row: SessionRow, seconds: Int) {
        core.snooze(session: row.id, seconds: seconds)
        if seconds > 0 {
            let until = Date().addingTimeInterval(TimeInterval(seconds))
            show(notice: "Snoozed \(row.label) until \(PanelStore.clockTime(until))")
        } else {
            show(notice: "Unsnoozed \(row.label)")
        }
    }

    func snoozeUntilMorning(_ row: SessionRow) {
        snooze(row, seconds: PanelStore.secondsUntilMorning())
    }

    /// `clear_completed` — the footer's "Clear finished" (nil sessions)
    /// and a row's own "Clear" share this; the reply's batch is
    /// `CoreModel.lastClear`, which the Undo row reads.
    private func runClear(sessions: [String]?, expected: Int? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.clearCompletedNow(sessions: sessions)
                guard reply.ok else {
                    self.show(notice: "Clear failed: \(reply.error?.message ?? reply.error?.code ?? "refused")")
                    return
                }
                let cleared = reply.result?["cleared"]?.arrayValue?.count ?? expected ?? sessions?.count ?? 0
                self.show(notice: cleared == 1 ? "Cleared 1 · Undo below" : "Cleared \(cleared) · Undo below")
            } catch {
                self.show(notice: "Clear failed: the monitor is not answering")
            }
        }
    }

    func clear(_ row: SessionRow) {
        guard row.activity.isClearable || row.stale else { return }
        runClear(sessions: [row.id])
    }

    /// Exactly the rows this card counted — the organizer's cut, not
    /// every finished session the monitor holds: with "Ended sessions"
    /// off the button used to read as clearing two and clear nine.
    func clearFinished() {
        let ids = organized
            .filter { SessionActivity.reduce($0).isClearable || $0.stale }
            .map(\.id)
        guard !ids.isEmpty else { show(notice: "Nothing to clear"); return }
        runClear(sessions: ids, expected: ids.count)
    }

    /// `undo_clear` for `CoreModel.lastClear`, while it still stands.
    func undoClear() {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let reply = try await self.core.undoClear() {
                    self.show(notice: reply.ok ? "Clear undone" : (reply.error?.message ?? "Undo failed"))
                }
            } catch {
                self.show(notice: "Undo failed: the monitor is not answering")
            }
        }
    }

    /// The full working directory, on the pasteboard.
    func copyPath(_ row: SessionRow) {
        guard let cwd = row.cwd, !cwd.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cwd, forType: .string)
        show(notice: "Copied \(cwd)")
    }

    /// The working directory selected in a Finder window.
    func reveal(_ row: SessionRow) {
        guard let cwd = row.cwd, !cwd.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    /// The "Open full overview" row — the delegate's Overview window.
    func openFullOverview() { onOpenOverview?() }

    // MARK: Notice

    /// The card-local toast: one line under the list, cleared on a
    /// timer the way the panel's is.
    private func show(notice text: String) {
        notice = text
        noticeClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.notice = nil }
        }
        noticeClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}
