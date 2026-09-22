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
/// then Suggestions (the frecency top, each row listed once), then
/// every section in its fixed order. With a query it is Raycast's one
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

    static func arrange(_ items: [PaletteItem], query: String, usage: PaletteUsage,
                        now: Date = Date()) -> [PaletteListSection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return home(items, usage: usage, now: now) }
        let ranked = rank(items, query: trimmed, usage: usage, now: now)
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
        // Ask for more than the limit: a frecent key whose row is not
        // on offer right now (an ended session, a deleted rule) is
        // skipped, not a hole.
        let suggested = usage.top(suggestionLimit * 4, at: now)
            .compactMap { byID[$0] }
            .prefix(suggestionLimit)
        let suggestedIDs = Set(suggested.map(\.id))
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
        items.enumerated()
            .compactMap { offset, item -> (item: PaletteItem, score: Int, offset: Int)? in
                guard let match = match(item, query: query) else { return nil }
                var total = match.score + boost(usage.score(for: item.id, at: now))
                if item.urgent { total += urgencyBonus }
                return (promoting(match.verbID, in: item), total, offset)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.item)
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
        let floor = 3 * query.filter { !$0.isWhitespace }.count
        var best: Match?
        func consider(_ value: Int?, verb: String? = nil) {
            guard let value, value >= floor else { return }
            if value > (best?.score ?? .min) { best = Match(score: value, verbID: verb) }
        }
        consider(MenuBarCommands.score(query, item.title))
        // A verb phrase counts only when the query reaches past the
        // verb into the row's own name: "d" alone must never turn Deny
        // into Return, but "deny fix" means it.
        for action in item.actions where MenuBarCommands.score(query, action.title) == nil {
            consider(MenuBarCommands.score(query, "\(action.title) \(item.title)").map { $0 - 1 },
                     verb: action.id)
        }
        for keyword in item.keywords {
            consider(MenuBarCommands.score(query, keyword).map { $0 * 4 / 5 })
        }
        if let subtitle = item.subtitle {
            consider(MenuBarCommands.score(query, subtitle).map { $0 / 2 })
        }
        consider(MenuBarCommands.score(query, item.kind).map { $0 / 2 })
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
    static func promoting(_ verbID: String?, in item: PaletteItem) -> PaletteItem {
        guard let verbID, let index = item.actions.firstIndex(where: { $0.id == verbID }) else {
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
        return actions.enumerated()
            .compactMap { offset, action in
                MenuBarCommands.score(trimmed, action.title).map { (action, $0, offset) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }
}
