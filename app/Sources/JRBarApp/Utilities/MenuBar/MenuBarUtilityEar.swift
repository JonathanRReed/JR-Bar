import AppKit
import ApplicationServices
import CoreGraphics
import JRBarCore
import Observation
import SwiftUI

/// The Menu Bar utility on the Screen Bar's right ear: the feed, and the
/// newcomers and changes it nudges about.
extension MenuBarUtility {
    // MARK: The Screen Bar's right ear

    /// Re-read the feed: on every plan pass, and whenever a photograph
    /// lands or the engine moves.
    func refreshEarFeed() {
        guard running, settings().provider == .jrbar else {
            if earFeed != nil { earFeed = nil }
            return
        }
        let nudge = earNudge.flatMap { pending -> MenuBarEarFeed.Nudge? in
            // An app that quit mid-nudge takes its mark with it; the
            // nudge itself lapses on its own clock.
            guard let item = listedItems.first(where: { $0.id == pending.itemID }) else { return nil }
            return MenuBarEarFeed.Nudge(
                id: pending.id, kind: pending.kind,
                tile: MenuBarEarFeed.Tile(item: item, face: glyphFace(for: item)),
                icon: pending.icon, detail: pending.detail,
                section: effectiveSection(for: item))
        }
        let feed = MenuBarEarFeed(
            hidden: MenuBarEarFeed.tiles(barItems(), face: { self.glyphFace(for: $0) },
                                         changed: bar.updatedIDs),
            failure: MenuBarEarFeed.failure(
                for: engineHealth,
                osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            nudge: nudge)
        if feed != earFeed { earFeed = feed }
    }

    /// A glyph clicked in the ear's peek: the Item Bar's own tile press —
    /// the app alone lifts, the press lands, the full target returns.
    func openFromEar(itemID: String) {
        guard let item = (barItems() + listedItems).first(where: { $0.id == itemID }) else { return }
        trigger(item)
    }

    // MARK: Newcomers and changes, on the ear

    /// How long a nudge's choices stay on offer in the peek; the ear's
    /// mark itself is the Screen Bar's shorter beat. Past it the nudge
    /// goes with nothing changed.
    nonisolated static let earNudgeLife: TimeInterval = 120

    /// How many nudges may wait behind the one standing; past it an
    /// arrival is only remembered.
    nonisolated static let earNudgeQueue = 3

    /// The newcomer pass, once per plan: an app whose item is on the bar
    /// for the first time gets a nudge on the ear — once, ever. It never
    /// hides anything on its own, and without the ear an arrival is only
    /// remembered: the bar never moves for it.
    func noticeNewcomers() {
        guard let memory = newcomerMemory else { return }
        let items = listedItems
        let candidates = MenuBarNewcomers.candidates(items, ownBundleID: Bundle.main.bundleIdentifier)
        let mapped = Set(settings().concealedApps.keys).union(curatedSettings().concealedApps.keys)
        let step = MenuBarNewcomers.step(candidates: candidates, seen: memory.seen, mapped: mapped,
                                         settling: Date() < startSettleUntil)
        if let remember = step.remember { memory.remember(remember) }
        // "New menu bar items": straight to a section, no question asked
        // — the person already answered it in the card.
        if let section = Self.newcomerSection(settings().curation.newItems) {
            for app in step.arrivals {
                guard let item = items.first(where: { $0.bundleID == app }),
                      applySection(section, to: item) != nil else { continue }
                MenuBarAssessmentBackend.log.notice("newcomer: \(app, privacy: .public) → \(section.rawValue, privacy: .public)")
            }
            return
        }
        guard !step.arrivals.isEmpty, earAvailable() else { return }
        let rows = MenuBarItemLister.menuBarRows()
        for app in step.arrivals {
            guard let item = items.first(where: { $0.bundleID == app }) else { continue }
            raiseEarNudge(.newcomer, item: item, detail: nil)
            // Its glyph for the mark: the item is on the row right now,
            // and a new item joining just moved the bar anyway.
            if Self.photographable(item, among: items, rows: rows,
                                   concealed: concealer?.concealedApps ?? []) {
                photograph([item])
            }
        }
    }

    /// The first changed item a show-for-updates pass lets through — the
    /// watch list's (all of them while it is empty). Pure so a test pins
    /// it.
    nonisolated static func earUpdate(changed: [MenuBarItem], watch: Set<String>) -> MenuBarItem? {
        changed.first { watch.isEmpty || watch.contains(updateWatchKey($0)) }
    }

    /// A photographed hidden item whose picture changed — a sync badge,
    /// a VPN's glyph — while show for updates is on and the ear is up.
    func noticePictureChange(_ item: MenuBarItem) {
        guard running, settings().showForUpdates, earAvailable() else { return }
        // The engine's first photographs — the pre-photograph before its
        // first assertion — settle as the run's do, wherever in the run
        // the engine came up.
        let now = Date()
        let settling = now < startSettleUntil
            || now.timeIntervalSince(concealerStartedAt) < Self.startSettle
        guard Self.pictureChangeNudges(
            settling: settling,
            revealed: !hider.revealed.isEmpty,
            barOpen: bar.isOpen,
            lifted: item.bundleID.map { lifts[$0] != nil } ?? false,
            hidden: barItems().contains(where: { $0.id == item.id }),
            watched: Self.earUpdate(changed: [item], watch: Set(settings().curation.updateWatch)) != nil)
        else { return }
        raiseEarNudge(.update, item: item, detail: nil)
    }

    /// Whether a changed picture is news for the ear — pure so a test
    /// pins it. Never while settling: the first photographs of a run
    /// (or of an engine coming up) are held against the last run's, so
    /// a battery level or a weather glyph that moved since then is only
    /// time gone by — the title path seeds in silence for the same
    /// reason. Never while the person is looking at the item already: a
    /// reveal, a tile's lift, the Item Bar open. Only an item still
    /// tucked away, and only one the watch list lets through.
    nonisolated static func pictureChangeNudges(settling: Bool, revealed: Bool, barOpen: Bool,
                                                lifted: Bool, hidden: Bool, watched: Bool) -> Bool {
        !settling && !revealed && !barOpen && !lifted && hidden && watched
    }

    /// Stand a nudge on the ear, or queue it behind the one standing. A
    /// second word about the item already standing only freshens it.
    func raiseEarNudge(_ kind: MenuBarEarFeed.Nudge.Kind, item: MenuBarItem, detail: String?) {
        if var standing = earNudge, standing.itemID == item.id, standing.kind == kind {
            standing.detail = detail ?? standing.detail
            earNudge = standing
            refreshEarFeed()
            return
        }
        earNudgeSerial += 1
        let nudge = PendingNudge(id: "\(kind)-\(earNudgeSerial)-\(item.id)", kind: kind, itemID: item.id,
                                 detail: detail, icon: item.owner?.icon)
        if earNudge == nil {
            standEarNudge(nudge)
        } else if queuedNudges.count < Self.earNudgeQueue,
                  !queuedNudges.contains(where: { $0.itemID == item.id && $0.kind == kind }) {
            queuedNudges.append(nudge)
        }
    }

    private func standEarNudge(_ nudge: PendingNudge) {
        earNudge = nudge
        earNudgeExpiry?.cancel()
        earNudgeExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.earNudgeLife * 1e9))
            guard !Task.isCancelled, let self, self.earNudge?.id == nudge.id else { return }
            self.finishEarNudge()
        }
        refreshEarFeed()
    }

    /// The standing nudge is answered or lapsed: the next one stands.
    private func finishEarNudge() {
        earNudgeExpiry?.cancel()
        earNudgeExpiry = nil
        earNudge = nil
        if !queuedNudges.isEmpty {
            standEarNudge(queuedNudges.removeFirst())
        } else {
            refreshEarFeed()
        }
    }

    /// A nudge's answer from the peek: the item goes to that section —
    /// the same write the card's picker makes — and the next nudge
    /// stands. Only an explicit click lands here; a nudge that lapses
    /// changes nothing.
    func chooseFromEar(_ choice: MenuBarEarChoice, nudgeID: String) {
        guard let nudge = earNudge, nudge.id == nudgeID else { return }
        if listedItems.contains(where: { $0.id == nudge.itemID }) {
            setSection(choice.section, for: nudge.itemID)
        }
        finishEarNudge()
    }
}
