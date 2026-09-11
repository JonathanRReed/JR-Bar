import AppKit
import JRBarCore
import Observation

/// The History window's state: the daemon's rows, the filter, the away
/// summary, and the undo window for the last clear.
@MainActor
@Observable
final class HistoryStore {
    let core: CoreModel

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

    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var refreshWork: DispatchWorkItem?
    @ObservationIgnored private var lastEventID: String?
    /// Without an event, rows are refreshed this often (the daemon may
    /// record things that never raise an event).
    static let refreshInterval: TimeInterval = 30

    init(core: CoreModel) {
        self.core = core
    }

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
    }

    func windowDidClose() {
        clock?.invalidate()
        clock = nil
    }

    func reload() {
        guard core.isLive else {
            error = "History needs the core. Rows appear when it connects."
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

    func open(_ row: CoreHistoryRow) {
        selectedID = row.id
        guard let session = row.session else { return }
        core.openSession(session)
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
