import Foundation
import JRBarCore

/// What your agents did, searchable from ⌘⇧K: the daemon's
/// `list_history` rows matched by the History window's own filter —
/// label, detail, provider, session and kind — so a hit here is a hit
/// there. The rows are read once per open, on the first query that
/// needs them, and filtered in place on every query after.

struct HistoryPaletteVerbs {
    /// Raise the History window on this row, filtered by `query`.
    var show: @MainActor (CoreHistoryRow, String) -> Void
    /// Raise the History window filtered by `query`.
    var search: @MainActor (String) -> Void
    /// Whether the row's session is still live — History's own rule for
    /// what can be opened.
    var isLive: @MainActor (String?) -> Bool
    var openSession: @MainActor (String) -> Void
}

enum HistoryPaletteRows {
    /// History answers from three typed characters on, as the archive
    /// does — shorter queries match half of everything.
    static let minimumQuery = 3
    static let limit = 5

    /// The newest matches, then "Search History for …" to carry the
    /// query into the window.
    @MainActor
    static func items(query: String, rows: [CoreHistoryRow], now: Date,
                      verbs: HistoryPaletteVerbs) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minimumQuery else { return [] }
        let hits = HistoryFilter(text: trimmed).apply(rows).sorted { $0.at > $1.at }.prefix(limit)
        var items = hits.map { row in
            var actions = [PaletteAction(id: "show", title: "Show in History", symbol: "clock.arrow.circlepath") {
                verbs.show(row, trimmed)
                return nil
            }]
            if let session = row.session, verbs.isLive(session) {
                actions.append(PaletteAction(id: "session", title: "Open Session", symbol: "macwindow") {
                    verbs.openSession(session)
                    return nil
                })
            }
            return PaletteItem(
                id: "history.\(row.id)", title: row.displayTitle,
                subtitle: row.detailIsTitle ? nil : row.detail,
                icon: row.provider.map { PaletteIcon.provider($0) } ?? .symbol("clock.arrow.circlepath", .orange),
                tags: [PaletteTag(text: row.kindWord, tone: tone(for: row.kind))]
                    + (PanelStore.elapsed(since: row.date, now: now).map { [PaletteTag(text: "\($0) ago")] } ?? []),
                kind: "History", section: .history, actions: actions)
        }
        items.append(PaletteItem(
            id: "history.search", title: "Search History for “\(trimmed)”",
            subtitle: "Every run, ask and failure, newest first",
            icon: .symbol("clock.arrow.circlepath", .orange), kind: "History", section: .history,
            actions: [PaletteAction(id: "search", title: "Search History", symbol: "magnifyingglass") {
                verbs.search(trimmed)
                return nil
            }]))
        return items
    }

    static func tone(for kind: String) -> PaletteTag.Tone {
        switch kind {
        case "failed": return .alert
        case "asked": return .attention
        case "completed", "answered": return .positive
        default: return .neutral
        }
    }
}

/// The source: a query-only list over rows fetched once per open.
@MainActor
final class HistoryPaletteSource: PaletteSource {
    /// `list_history`; nil while the monitor is away — then History has
    /// nothing to say, not even its search row.
    var load: @MainActor () async -> [CoreHistoryRow]?
    var verbs: HistoryPaletteVerbs
    private var cached: [CoreHistoryRow]?
    private var pending: Task<[CoreHistoryRow]?, Never>?

    init(load: @escaping @MainActor () async -> [CoreHistoryRow]?, verbs: HistoryPaletteVerbs) {
        self.load = load
        self.verbs = verbs
    }

    /// A new open reads afresh.
    func prepare() {
        cached = nil
        pending = nil
    }

    func items() -> [PaletteItem] { [] }

    func results(for query: String) async -> [PaletteItem] {
        guard query.trimmingCharacters(in: .whitespaces).count >= HistoryPaletteRows.minimumQuery,
              let rows = await rowsOnce() else { return [] }
        return HistoryPaletteRows.items(query: query, rows: rows, now: Date(), verbs: verbs)
    }

    /// One fetch per open, shared by queries typed while it is in flight.
    private func rowsOnce() async -> [CoreHistoryRow]? {
        if let cached { return cached }
        if let pending { return await pending.value }
        let load = self.load
        let task = Task { await load() }
        pending = task
        let rows = await task.value
        if pending == task { cached = rows }
        return rows
    }
}
