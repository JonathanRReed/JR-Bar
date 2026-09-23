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
    /// Rows a slower source found for the current query — the front
    /// app's menu items, the archive's full-text hits. Listed after the
    /// ranked results, each source under its own heading.
    private(set) var searchResults: [PaletteItem] = []
    /// The query the search results belong to; a late answer for an
    /// older query is dropped rather than shown under the wrong words.
    private(set) var searchedQuery = ""
    /// A slower source is still working on the current query.
    private(set) var searching = false
    var usage = PaletteUsage()
    var now = Date()
    /// The rows a query spells with an argument ("quiet 45m"), asked on
    /// every refilter — the controller points it at its sources.
    var typedRows: @MainActor (String) -> [PaletteItem] = { _ in [] }

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

    // MARK: A verb's words (PaletteInput)

    /// The row and verb whose field is open, by id — the row may be
    /// re-ranked or re-gathered underneath without losing its place.
    struct InputTarget: Equatable {
        let rowID: String
        let actionID: String
    }

    private(set) var inputTarget: InputTarget?
    /// What has been typed into the verb's field.
    var inputText = ""
    var inputActive: Bool { inputTarget != nil }

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
        endInput()
        query = ""
        refilter(keepSelection: false)
    }

    /// Fresh rows from the same sources while the palette stays up — an
    /// ask that lands mid-search appears under Needs You, a toggle's
    /// read-back settles its tag. The query, the archive's hits, the
    /// selection and an open action panel all stay where they were; the
    /// panel folds only if its row went away, and so does a verb's
    /// field — an ask answered in its own window takes its Reply with it.
    func reload(items: [PaletteItem]) {
        self.items = items
        let previous = selectedID
        refilter(keepSelection: true)
        if actionsOpen, selectedID != previous { closeActions() }
        if inputActive, inputAction == nil { endInput() }
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
        let trimmedQuery = Self.trimmed(query)
        let typed = trimmedQuery.isEmpty ? [] : typedRows(trimmedQuery)
        var arranged = PaletteRanking.arrange(items, typed: typed, query: query, usage: usage, now: now)
        if !Self.trimmed(query).isEmpty, !searchResults.isEmpty {
            // Each slower source's hits under its own heading — the
            // frontmost app's menus, then the archive — in source order.
            var order: [PaletteSection] = []
            var groups: [PaletteSection: [PaletteItem]] = [:]
            for item in searchResults {
                if groups[item.section] == nil { order.append(item.section) }
                groups[item.section, default: []].append(item)
            }
            arranged += order.map { PaletteListSection(section: $0, items: groups[$0] ?? []) }
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

    // MARK: A verb's field

    /// Open `action`'s field on `item`: the action panel folds, the
    /// field starts from the verb's draft, and the query waits
    /// untouched for ⎋. False for a verb that takes no words.
    @discardableResult
    func beginInput(_ action: PaletteAction, of item: PaletteItem) -> Bool {
        guard let input = action.input else { return false }
        closeActions()
        inputTarget = InputTarget(rowID: item.id, actionID: action.id)
        inputText = input.initial()
        selectedID = item.id
        return true
    }

    func endInput() {
        inputTarget = nil
        inputText = ""
    }

    /// The row the open field belongs to, found wherever it lives now —
    /// ranked, re-gathered or a slower source's hit.
    var inputItem: PaletteItem? {
        guard let target = inputTarget else { return nil }
        return rows.first { $0.id == target.rowID }
            ?? items.first { $0.id == target.rowID }
            ?? searchResults.first { $0.id == target.rowID }
    }

    var inputAction: PaletteAction? {
        guard let target = inputTarget else { return nil }
        return inputItem?.actions.first { $0.id == target.actionID && $0.input != nil }
    }

    // MARK: Helpers

    nonisolated static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }
}
