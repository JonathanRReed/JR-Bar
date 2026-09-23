import AppKit
import JRBarCore

/// The "Hidden Menu Bar Items" submenu on JR-Bar's own status item,
/// modeled as plain entries so a test pins the list without an
/// `NSMenu`. It carries the hidden run's reveal/hide toggle, the Item
/// Bar, and the hidden items themselves with activate actions.
struct MenuBarMenuEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Reveal or re-hide the hidden run — title follows the state.
        case toggleHidden(revealed: Bool)
        /// Open the Item Bar (the click already does this; the menu
        /// states it for discoverability).
        case openBar
        case separator
        /// A covered item — activating it presses through AX, the same
        /// as an Item Bar tile's click.
        case item(id: String, section: MenuBarItemSection)
        /// The cap marker when the run is longer than the menu lists.
        case more(count: Int)
    }
    var kind: Kind
    var title: String
}

enum MenuBarCombinedMenu {
    /// How many covered items the menu lists before the "+N more" row —
    /// a menu is not the Item Bar.
    nonisolated static let maxListedItems = 20

    /// One item's menu title: the owner's name plus its title, with the
    /// deeper section marked.
    nonisolated static func title(for item: MenuBarItem,
                                  section: MenuBarItemSection) -> String {
        var title = item.title.map { "\(item.ownerName) · \($0)" } ?? item.ownerName
        if section == .alwaysHidden { title += " — always hidden" }
        return title
    }

    /// The menu's rows for the current plan: the hidden-run toggle and
    /// the Item Bar up top, then every covered item, hidden first.
    nonisolated static func entries(plan: MenuBarHidePlan,
                                    hiddenRevealed: Bool) -> [MenuBarMenuEntry] {
        var entries: [MenuBarMenuEntry] = [
            MenuBarMenuEntry(kind: .toggleHidden(revealed: hiddenRevealed),
                             title: hiddenRevealed ? "Hide Items Again"
                                                   : "Reveal Hidden Items"),
            MenuBarMenuEntry(kind: .openBar, title: "Open Item Bar"),
        ]
        let covered = plan.hidden + plan.alwaysHidden
        guard !covered.isEmpty else { return entries }
        entries.append(MenuBarMenuEntry(kind: .separator, title: ""))
        for item in covered.prefix(maxListedItems) {
            let section: MenuBarItemSection = plan.alwaysHidden.contains(item)
                ? .alwaysHidden : .hidden
            entries.append(MenuBarMenuEntry(kind: .item(id: item.id, section: section),
                                            title: title(for: item, section: section)))
        }
        let rest = covered.count - min(covered.count, maxListedItems)
        if rest > 0 {
            entries.append(MenuBarMenuEntry(kind: .more(count: rest),
                                            title: "… and \(rest) more"))
        }
        return entries
    }

    /// One row of the menu's "hide an app" list: the app's first shown
    /// item stands for it — under the concealer the pick lands on the
    /// whole bundle, under the spacer engine on that item.
    struct HideRow: Equatable, Sendable {
        var itemID: String
        var title: String
    }

    /// The apps a click could hide right now: one row per app among
    /// `shown` (the caller passes only items it may hide — never ours,
    /// never a protected system item), named for its owner, in
    /// alphabetical order, capped like the hidden list. An app with two
    /// items appears once; two items with no bundle stay apart, named
    /// by their titles.
    nonisolated static func hideRows(shown: [MenuBarItem]) -> [HideRow] {
        var seen = Set<String>()
        var rows: [HideRow] = []
        for item in shown {
            let key = item.bundleID ?? "item:" + item.id
            guard seen.insert(key).inserted else { continue }
            let title = item.bundleID == nil
                ? MenuBarCombinedMenu.title(for: item, section: .hidden)
                : item.ownerName
            rows.append(HideRow(itemID: item.id, title: title))
        }
        return Array(rows.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }.prefix(maxListedItems))
    }

    /// One row of the menu's profile list.
    struct ProfileRow: Equatable, Sendable {
        var id: String
        var title: String
        var active: Bool
    }

    /// The profile rows the menu carries under the hidden items — the
    /// built-in "None" first, a checkmark on the active one. Empty while
    /// there are no saved profiles: a lone "None" says nothing.
    nonisolated static func profileRows(profiles: [MenuBarSettings.Profile],
                                        activeID: String?) -> [ProfileRow] {
        guard !profiles.isEmpty else { return [] }
        let active = activeID.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            ?? MenuBarProfiles.noneID
        return [ProfileRow(id: MenuBarProfiles.noneID, title: MenuBarProfiles.noneName,
                           active: active == MenuBarProfiles.noneID)]
            + profiles.map { ProfileRow(id: $0.id, title: $0.name, active: $0.id == active) }
    }
}
