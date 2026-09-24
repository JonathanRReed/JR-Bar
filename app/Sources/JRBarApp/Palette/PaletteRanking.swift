import Foundation
import JRBarCore

/// One titled run of rows as the list draws it.
struct PaletteListSection: Identifiable {
    let section: PaletteSection
    let items: [PaletteItem]
    var id: String { section.id }
}

/// How the palette orders what its sources gave it. Pure: rows, a
/// query and the frecency table in, sections out — so "what does ⌘⇧K
/// show first" is a test, not a screenshot.
///
/// With no query the list is a home screen: open asks under Needs You,
/// the rows you pinned under Favorites, Suggestions (the frecency top),
/// then every section in its fixed order, each row listed once. With a
/// query it is Raycast's one
/// ranked Results list: the fuzzy score of the title — or, at a
/// discount, a keyword, the subtitle or the kind — plus a frecency
/// boost that breaks near-ties toward what you use, never past a
/// clearly better match.
enum PaletteRanking {
    /// How many rows Suggestions holds.
    static let suggestionLimit = 5
    /// The biggest lift frecency can give a match. A title hit on a
    /// word start is worth ~20 per letter; this is about one letter's
    /// worth, so habit settles ties without overruling the words.
    static let frecencyCeiling = 24
    /// What an open ask adds to its match — it wins a tie.
    static let urgencyBonus = 6
    /// What a favorite adds — a tie, and a little more.
    static let favoriteBonus = 8

    /// `typed` are the rows the query spelled with an argument ("quiet
    /// 45m"): they lead Results unranked — the words were written for
    /// them — and stand in for any row of the same id, so a typed "quiet
    /// 1h" is the 1-hour preset's row, habit and all, said once.
    ///
    /// `folded` is `items` folded once (`FoldedItem`), in the same order
    /// — the model keeps it with its rows; nil folds them here.
    static func arrange(_ items: [PaletteItem], folded: [FoldedItem]? = nil, typed: [PaletteItem] = [],
                        query: String, usage: PaletteUsage, now: Date = Date()) -> [PaletteListSection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return home(items, usage: usage, now: now) }
        let typedIDs = Set(typed.map(\.id))
        let fields: [FoldedItem]
        if let folded, folded.count == items.count {
            fields = folded
        } else {
            fields = items.map(FoldedItem.init)
        }
        var candidates: [(item: PaletteItem, folded: FoldedItem)] = []
        for (item, fold) in zip(items, fields) where !typedIDs.contains(item.id) {
            candidates.append((item, fold))
        }
        let ranked = typed + rank(candidates, query: trimmed, usage: usage, now: now)
        return ranked.isEmpty ? [] : [PaletteListSection(section: .results, items: ranked)]
    }

    /// The empty-query list.
    static func home(_ items: [PaletteItem], usage: PaletteUsage,
                     now: Date = Date()) -> [PaletteListSection] {
        var out: [PaletteListSection] = []
        let urgent = items.filter(\.urgent)
        if !urgent.isEmpty { out.append(PaletteListSection(section: .needsYou, items: urgent)) }
        let byID = Dictionary(items.filter { !$0.urgent }.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        // Favorites in the order pinned; one not on offer right now (a
        // profile since deleted) waits, invisible, for its row.
        let favorites = usage.favorites.compactMap { byID[$0] }
        if !favorites.isEmpty {
            out.append(PaletteListSection(section: .favorites, items: favorites))
        }
        let favoriteIDs = Set(favorites.map(\.id))
        // Ask for more than the limit: a frecent key whose row is not
        // on offer right now (an ended session, a deleted rule) is
        // skipped, not a hole.
        let suggested = usage.top(suggestionLimit * 4, at: now)
            .compactMap { byID[$0] }
            .filter { !favoriteIDs.contains($0.id) }
            .prefix(suggestionLimit)
        let suggestedIDs = Set(suggested.map(\.id)).union(favoriteIDs)
        if !suggested.isEmpty {
            out.append(PaletteListSection(section: .suggestions, items: Array(suggested)))
        }
        var bySection: [PaletteSection: [PaletteItem]] = [:]
        var sectionOrder: [PaletteSection] = []
        for item in items where !item.urgent && !suggestedIDs.contains(item.id) {
            if bySection[item.section] == nil { sectionOrder.append(item.section) }
            bySection[item.section, default: []].append(item)
        }
        // Stable on `order`, then first appearance — two sources sharing
        // an order keep the order they were registered in.
        let ordered = sectionOrder.enumerated()
            .sorted { $0.element.order != $1.element.order
                ? $0.element.order < $1.element.order : $0.offset < $1.offset }
            .map(\.element)
        for section in ordered {
            out.append(PaletteListSection(section: section, items: bySection[section] ?? []))
        }
        return out
    }

    /// A query's matches, best first; ties keep source order. A row
    /// matched through one of its verbs comes back with that verb in
    /// front — see `promoting`.
    static func rank(_ items: [PaletteItem], query: String, usage: PaletteUsage,
                     now: Date = Date()) -> [PaletteItem] {
        rank(items.map { ($0, FoldedItem($0)) }, query: query, usage: usage, now: now)
    }

    /// `rank` over rows already folded: the query folds once here, and
    /// no row's fields fold at all.
    static func rank(_ candidates: [(item: PaletteItem, folded: FoldedItem)], query: String,
                     usage: PaletteUsage, now: Date = Date()) -> [PaletteItem] {
        let folded = FoldedQuery(query)
        var scored: [(item: PaletteItem, score: Int, offset: Int)] = []
        for (offset, candidate) in candidates.enumerated() {
            guard let found = match(candidate.folded, query: folded) else { continue }
            let item = candidate.item
            var total = found.score + boost(usage.score(for: item.id, at: now))
            if item.urgent { total += urgencyBonus }
            if usage.isFavorite(item.id) { total += favoriteBonus }
            scored.append((promoting(found.verbID, in: item), total, offset))
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.offset < b.offset }
        return scored.map { $0.item }
    }

    /// A row's best match, and the verb it came through when that beat
    /// every plain field.
    struct Match: Equatable {
        let score: Int
        /// The action whose "verb title" phrase matched best; nil when
        /// the row matched as itself.
        let verbID: String?
    }

    /// The row's match against `query`, or nil. The title counts in
    /// full; "verb title" phrases ("Hide 1Password", "Approve fix-ci")
    /// one point less, so a plain title hit wins a tie, and only when
    /// the query is more than the verb; a keyword at
    /// four fifths; the subtitle and the kind at half. A match must
    /// earn more than bare scattered letters — three points a letter —
    /// so "dark" never finds "Dock Auto-Hide Restarts" by picking
    /// letters out of three words.
    static func match(_ item: PaletteItem, query: String) -> Match? {
        match(FoldedItem(item), query: FoldedQuery(query))
    }

    /// A query folded once per keystroke, with the floor it sets.
    struct FoldedQuery {
        let text: MenuBarCommands.Folded
        /// Three points a letter — what bare scattered letters earn.
        let floor: Int

        init(_ query: String) {
            text = MenuBarCommands.Folded(query: query)
            floor = 3 * query.filter { !$0.isWhitespace }.count
        }
    }

    /// A row's searchable fields folded once — when the model takes its
    /// rows, not on every keystroke. The "verb title" phrases are
    /// spelled here too, so a keystroke builds no string at all.
    struct FoldedItem {
        struct Verb {
            let id: String
            let title: MenuBarCommands.Folded
            let phrase: MenuBarCommands.Folded
        }

        let title: MenuBarCommands.Folded
        let verbs: [Verb]
        let keywords: [MenuBarCommands.Folded]
        let subtitle: MenuBarCommands.Folded?
        let kind: MenuBarCommands.Folded

        init(_ item: PaletteItem) {
            title = MenuBarCommands.Folded(item.title)
            verbs = item.actions.map { action in
                Verb(id: action.id, title: MenuBarCommands.Folded(action.title),
                     phrase: MenuBarCommands.Folded(action.title + " " + item.title))
            }
            keywords = item.keywords.map { MenuBarCommands.Folded($0) }
            subtitle = item.subtitle.map { MenuBarCommands.Folded($0) }
            kind = MenuBarCommands.Folded(item.kind)
        }
    }

    /// `match` over folded fields — the same points, field for field.
    static func match(_ item: FoldedItem, query: FoldedQuery) -> Match? {
        let floor = query.floor
        var best: Match?
        func consider(_ value: Int?, verb: String? = nil) {
            guard let value, value >= floor else { return }
            if value > (best?.score ?? .min) { best = Match(score: value, verbID: verb) }
        }
        let text = query.text
        consider(MenuBarCommands.score(text, item.title))
        // A verb phrase counts only when the query reaches past the
        // verb into the row's own name: "d" alone must never turn Deny
        // into Return, but "deny fix" means it.
        for verb in item.verbs where MenuBarCommands.score(text, verb.title) == nil {
            consider(MenuBarCommands.score(text, verb.phrase).map { $0 - 1 }, verb: verb.id)
        }
        for keyword in item.keywords {
            consider(MenuBarCommands.score(text, keyword).map { $0 * 4 / 5 })
        }
        if let subtitle = item.subtitle {
            consider(MenuBarCommands.score(text, subtitle).map { $0 / 2 })
        }
        consider(MenuBarCommands.score(text, item.kind).map { $0 / 2 })
        return best
    }

    /// The row's score alone — `match` without the verb.
    static func score(_ item: PaletteItem, query: String) -> Int? {
        match(item, query: query)?.score
    }

    /// `item` with `verbID` moved to the front of its verbs, so Return
    /// does what was typed ("hide 1p" hides) and the verb that was
    /// first moves to ⌘Return. A menu-only row (`opensActions`) runs a
    /// typed verb straight away rather than opening its panel.
    ///
    /// A destructive verb (Deny, Clear, Dismiss) is never promoted: a
    /// query finds the row through it — "deny fix" still lists fix-ci's
    /// ask first — but Return keeps its safe first verb, and the
    /// destructive one stays on its own chord. Words typed in a hurry
    /// must never turn Return into a no. Nor into a lasting yes: a verb
    /// marked not `promotable` (Always Allow) runs only when picked by
    /// name, so "allow fix" meaning once never remembers a rule.
    static func promoting(_ verbID: String?, in item: PaletteItem) -> PaletteItem {
        guard let verbID, let index = item.actions.firstIndex(where: { $0.id == verbID }),
              !item.actions[index].isDestructive, item.actions[index].promotable else {
            return item
        }
        var promoted = item
        if index > 0 {
            let verb = promoted.actions.remove(at: index)
            promoted.actions.insert(verb, at: 0)
        }
        promoted.opensActions = false
        return promoted
    }

    /// Frecency's lift: logarithmic, so the tenth run of something adds
    /// less than the second did, and capped.
    static func boost(_ frecency: Double) -> Int {
        guard frecency > 0 else { return 0 }
        return min(frecencyCeiling, Int((log2(1 + frecency) * 6).rounded()))
    }

    /// The action panel's filter: its own small fuzzy list, panel order
    /// on an empty query.
    static func filterActions(_ actions: [PaletteAction], query: String) -> [PaletteAction] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return actions }
        // Typed and spelled out: the one-line tuple chain cost the type
        // checker seconds and times out on a slower runner.
        var scored: [(action: PaletteAction, score: Int, offset: Int)] = []
        for (offset, action) in actions.enumerated() {
            if let points = MenuBarCommands.score(trimmed, action.title) {
                scored.append((action, points, offset))
            }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.offset < b.offset }
        return scored.map { $0.action }
    }
}
