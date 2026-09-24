import AppKit
import JRBarCore

/// The Menu Bar utility's reach past the bar itself: macOS's layout
/// table (read-only, once granted), where newcomers go, and the
/// relaunch that lets a spacing change take.
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

    /// Apps whose section and place disagree, for the card — only under
    /// the `.slot` seat, where the icon's sides are macOS's order.
    var layoutTableMismatches: [MenuBarLayoutTable.Mismatch] {
        guard let table = layoutTable, let ours = Bundle.main.bundleIdentifier else { return [] }
        return MenuBarLayoutTable.mismatches(table: table, sections: curatedSettings().concealedApps,
                                             apps: layoutTableApps(), ours: ours,
                                             seat: settings().curation.mirrorSeat)
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

    // MARK: Newcomers

    /// Where `curation.newItems` puts an app new to the menu bar: nil
    /// leaves it where macOS put it (and the ear asks).
    nonisolated static func newcomerSection(_ placement: MenuBarNewItemsPlacement) -> MenuBarItemSection? {
        switch placement {
        case .asPlaced: return nil
        case .shown: return .shown
        case .hidden: return .hidden
        }
    }

    // MARK: Relaunch for spacing

    /// The apps a spacing relaunch would quit and reopen: every app with
    /// an item on the bar that is someone else's — never Apple's own
    /// agents, never JR-Bar's family — by name. Pure so a test pins it.
    nonisolated static func relaunchCandidates(_ items: [MenuBarItem]) -> [(bundleID: String, name: String)] {
        var seen = Set<String>()
        var out: [(bundleID: String, name: String)] = []
        for item in items where !item.isNativeOverflowControl && !MenuBarItemLister.isProtected(item) {
            guard let id = item.bundleID, !id.hasPrefix("com.apple."), !isOwnFamily(id),
                  seen.insert(id).inserted else { continue }
            out.append((id, item.ownerName))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The apps the confirm sheet lists — running ones, today.
    var spacingRelaunchApps: [(bundleID: String, name: String)] {
        Self.relaunchCandidates(listedItems + knownItems.values.flatMap { $0 }).filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
    }

    /// Quit and reopen `apps` one at a time so each picks up the item
    /// spacing — only ever from the confirm sheet's button. Each app is
    /// asked to quit (never forced), given a few seconds, and reopened in
    /// the background from where it was.
    func relaunchForSpacing(_ apps: [String]) {
        guard relaunchingApps.isEmpty, !apps.isEmpty else { return }
        relaunchingApps = apps
        Task { @MainActor [weak self] in
            for id in apps {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                      let url = app.bundleURL else { continue }
                MenuBarAssessmentBackend.log.notice("spacing: relaunching \(id, privacy: .public)")
                app.terminate()
                var waited = 0
                while !app.isTerminated, waited < 50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
                guard app.isTerminated else {
                    MenuBarAssessmentBackend.log.notice("spacing: \(id, privacy: .public) did not quit — left running")
                    continue
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                self?.relaunchingApps.removeAll { $0 == id }
            }
            self?.relaunchingApps = []
        }
    }
}
