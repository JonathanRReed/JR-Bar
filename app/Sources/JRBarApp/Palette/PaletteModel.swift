import Foundation
import JRBarCore
import Observation

/// The palette's live state: the rows the sources gave at open, the
/// query, the arranged list, the selection, and the ⌘K action panel.
/// Plain and main-actor — the controller drives it, the view reads it,
/// and every rule here runs in a test without a window.
///
/// `@Observable` rather than view `@State`: the CLT toolchain lacks the
/// SwiftUIMacros plugin, so the model — not the view — owns the query.
@MainActor
@Observable
final class PaletteModel {
    /// Every row the sources offered at open.
    private(set) var items: [PaletteItem] = []
    /// Rows a slower source found for the current query — the archive's
    /// full-text hits. Listed after the ranked results.
    private(set) var searchResults: [PaletteItem] = []
    /// The query the search results belong to; a late answer for an
    /// older query is dropped rather than shown under the wrong words.
    private(set) var searchedQuery = ""
    /// A slower source is still working on the current query.
    private(set) var searching = false
    var usage = PaletteUsage()
    var now = Date()

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            closeActions()
            if Self.trimmed(query) != Self.trimmed(searchedQuery) { searchResults = [] }
            refilter(keepSelection: false)
        }
    }

    /// The list as drawn, section by section.
    private(set) var sections: [PaletteListSection] = []
    /// The same rows flattened in drawn order — what ↑/↓ walk.
    private(set) var rows: [PaletteItem] = []
    private(set) var selectedID: String?

    // MARK: Action panel (⌘K)

    private(set) var actionsOpen = false
    var actionQuery = "" {
        didSet { actionSelection = 0 }
    }
    private(set) var actionSelection = 0

    // MARK: Loading

    func load(items: [PaletteItem], usage: PaletteUsage, now: Date = Date()) {
        self.items = items
        self.usage = usage
        self.now = now
        searchResults = []
        searchedQuery = ""
        searching = false
        actionsOpen = false
        actionQuery = ""
        query = ""
        refilter(keepSelection: false)
    }

    /// A slower source's answer. Kept only while the query still reads
    /// the same; the selection stays on the row it was on, so a hit
    /// landing mid-arrow never yanks the highlight.
    func setSearchResults(_ results: [PaletteItem], for query: String) {
        guard Self.trimmed(query) == Self.trimmed(self.query) else { return }
        searchResults = results
        searchedQuery = query
        searching = false
        refilter(keepSelection: true)
    }

    func noteSearching(_ on: Bool) { searching = on }

    func refilter(keepSelection: Bool) {
        let previous = selectedID
        var arranged = PaletteRanking.arrange(items, query: query, usage: usage, now: now)
        if !Self.trimmed(query).isEmpty, !searchResults.isEmpty {
            arranged.append(PaletteListSection(section: .archive, items: searchResults))
        }
        sections = arranged
        rows = arranged.flatMap(\.items)
        if keepSelection, let previous, rows.contains(where: { $0.id == previous }) {
            selectedID = previous
        } else {
            selectedID = rows.first?.id
        }
    }

    // MARK: Selection

    var selected: PaletteItem? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return rows.firstIndex { $0.id == selectedID }
    }

    /// ↑/↓ — wrapping, the way the old command bar did, so ↑ from the
    /// top lands on the last row.
    func move(_ delta: Int) {
        guard !rows.isEmpty else { selectedID = nil; return }
        let current = selectedIndex ?? (delta > 0 ? -1 : 0)
        let next = ((current + delta) % rows.count + rows.count) % rows.count
        selectedID = rows[next].id
    }

    /// Page ↑/↓ — clamped, not wrapped: paging past the end stops there.
    func page(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let current = selectedIndex ?? 0
        selectedID = rows[min(rows.count - 1, max(0, current + delta))].id
    }

    func select(id: String) {
        guard rows.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    // MARK: Action panel

    /// ⌘K: open the panel on the selected row. False when there is no
    /// row or nothing to list.
    @discardableResult
    func openActions() -> Bool {
        guard let selected, !selected.actions.isEmpty else { return false }
        actionQuery = ""
        actionSelection = 0
        actionsOpen = true
        return true
    }

    func closeActions() {
        actionsOpen = false
        actionQuery = ""
        actionSelection = 0
    }

    var visibleActions: [PaletteAction] {
        guard let selected else { return [] }
        return PaletteRanking.filterActions(selected.actions, query: actionQuery)
    }

    func moveAction(_ delta: Int) {
        let count = visibleActions.count
        guard count > 0 else { actionSelection = 0; return }
        actionSelection = ((actionSelection + delta) % count + count) % count
    }

    func selectAction(at index: Int) {
        guard visibleActions.indices.contains(index) else { return }
        actionSelection = index
    }

    var selectedAction: PaletteAction? {
        let visible = visibleActions
        return visible.indices.contains(actionSelection) ? visible[actionSelection] : nil
    }

    // MARK: Helpers

    nonisolated static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }
}
