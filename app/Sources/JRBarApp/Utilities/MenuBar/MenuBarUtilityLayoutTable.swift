import AppKit
import JRBarCore

/// The Menu Bar utility's reach past the bar itself: macOS's layout
/// table, read-only, once granted.
extension MenuBarUtility {
    // MARK: The layout table

    /// Read the table while the utility is on and a grant exists; let it
    /// go otherwise.
    func syncLayoutTable() {
        let s = settings()
        if s.enabled, s.provider == .jrbar, let bookmark = s.curation.layoutTableBookmark {
            layoutTableReader.start(bookmark: bookmark)
        } else if layoutTableReader.isActive {
            layoutTableReader.stop()
            layoutTableVersion += 1
        }
    }

    /// The card's "Grant access…": the open panel on the one file, and a
    /// read-only bookmark kept in the settings.
    func grantLayoutTable() {
        guard let bookmark = MenuBarLayoutTableReader.requestGrant() else { return }
        update { $0.curation.layoutTableBookmark = MenuBarCuration.clampedBookmark(bookmark) }
    }

    /// The card's "Forget": the grant goes, and nothing is read again.
    func forgetLayoutTable() {
        update { $0.curation.layoutTableBookmark = nil }
    }

    /// The table as last read, while granted.
    var layoutTable: MenuBarLayoutTable.Table? {
        _ = layoutTableVersion
        return layoutTableReader.table
    }

    /// Every app the bar has shown this run that the agent can take —
    /// the names a table key can resolve to.
    func layoutTableApps() -> Set<String> {
        var apps = Set(knownItems.keys)
        apps.formUnion(listedItems.compactMap(\.bundleID))
        return apps.filter { canConceal($0) && !Self.isOwnFamily($0) }
    }

    /// The agent's order for these apps, from the table; empty without it.
    func layoutTableRanks(apps: Set<String>) -> [String: Int] {
        guard let table = layoutTableReader.table else { return [:] }
        return MenuBarLayoutTable.ranks(apps: apps, table: table)
    }

    /// Apps whose section and place disagree, for the card.
    var layoutTableMismatches: [MenuBarLayoutTable.Mismatch] {
        guard let table = layoutTable, let ours = Bundle.main.bundleIdentifier else { return [] }
        return MenuBarLayoutTable.mismatches(table: table, sections: curatedSettings().concealedApps,
                                             apps: layoutTableApps(), ours: ours)
    }

    /// The one-click fix: the section the app's place says — a pick,
    /// never a move.
    func fixLayoutMismatch(_ mismatch: MenuBarLayoutTable.Mismatch) {
        let item = listedItems.first { $0.bundleID == mismatch.app }
            ?? knownItems[mismatch.app]?.first
        guard let item else { return }
        applySection(mismatch.fix, to: item)
    }

    /// Whether the table, read after `releasedAt`, backs a drop's section
    /// — the confirm's fallback when Accessibility did not answer.
    func layoutTableConfirms(_ item: MenuBarItem, section: MenuBarItemSection, releasedAt: Date) -> Bool {
        guard let app = item.bundleID, let ours = Bundle.main.bundleIdentifier,
              let table = layoutTableReader.table, let readAt = layoutTableReader.readAt,
              readAt > releasedAt else { return false }
        return MenuBarLayoutTable.confirms(app: app, section: section, ours: ours, table: table,
                                          known: layoutTableApps().union([app]))
    }
}
