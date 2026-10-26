import AppKit
import ApplicationServices
import CoreGraphics
import JRBarCore
import Observation
import SwiftUI

/// The Menu Bar utility's boundary: JR-Bar's own status item as the
/// hidden run's edge, its hidden-items menu, the control frames, the
/// reveal zone and the watch on items' updates.
extension MenuBarUtility {
    // MARK: The boundary

    /// The boundary: the host's spacer — the app's own status item, one
    /// of ours on the row. No host, no boundary: JR-Bar never registers a
    /// second item to stand in (a registered one, even hidden, still read
    /// frames into the hot zones, the cover blockers and the ear limits).
    /// Safe to call any time.
    func installBoundary() {
        host?.setBoundarySpacer(spacerToStand())
    }

    /// The spacer the host's item should wear right now: the length the
    /// hider last wrote (the floor before it has written any), never just
    /// the floor: every settings write re-applies the utility and lands
    /// here, and a floor written over a standing spacer folded the divider
    /// while the hider still believed its length stood, so nothing wrote it
    /// again and every item left of the icon was drawn (seen live,
    /// 2026-10-08, 24 s after launch, at the first positional record).
    func spacerToStand() -> CGFloat {
        Self.standingSpacer(assigned: hider.assignedLengths[.hidden],
                            glyph: host?.boundaryGlyphLength ?? MenuBarControlFrames.glyphLength,
                            revealed: hider.effectiveRevealedSections.contains(.hidden))
    }

    /// The host's spacer for a hider length: the length less the icon's
    /// own width. The affordance uses only room inside the assigned length.
    /// Before the first write it keeps the affordance floor.
    nonisolated static func standingSpacer(assigned: CGFloat?, glyph: CGFloat, revealed: Bool = false) -> CGFloat {
        guard !revealed else { return 0 }
        guard let assigned else { return boundaryAffordance }
        return max(0, assigned - glyph).rounded(.down)
    }

    /// The status items earlier builds registered and this one never
    /// will — the always-hidden control and the fallback chevron. Their
    /// slots stay in our defaults; a stale key is harmless but says
    /// nothing true. The app's own item (`…status-item`) is never
    /// touched.
    nonisolated static let retiredItemKeys = [
        "NSStatusItem Preferred Position com.jonathanreed.jrbar.menubar-ah-control",
        "NSStatusItem Preferred Position com.jonathanreed.jrbar.menubar-chevron-v2",
        "NSStatusItem VisibleCC com.jonathanreed.jrbar.menubar-chevron-v2",
    ]

    /// Clear `retiredItemKeys` — each start, a no-op once they are gone.
    nonisolated static func forgetRetiredItems(
        _ remove: (String) -> Void = { UserDefaults.standard.removeObject(forKey: $0) }
    ) {
        for key in retiredItemKeys { remove(key) }
    }

    /// The whole teardown: the host's spacer folded, its counts cleared
    /// and the ears let go.
    func removeBoundary() {
        host?.setBoundarySpacer(0)
        host?.hiddenCount = 0
        host?.hiddenRevealed = false
        ScreenBarGeometry.setEarItemLimits(left: nil, right: nil)
    }

    /// The host's blank stretch was clicked: the hidden run toggles.
    func boundaryClicked() {
        toggleHiddenSection()
    }

    /// The "Hidden Menu Bar Items" submenu the host's menu carries: the
    /// reveal/hide toggle, the Item Bar, then every hidden item with an
    /// activate action. nil while the utility is parked, so the menu
    /// row disappears with it.
    func hiddenItemsMenu() -> NSMenu? {
        guard running else { return nil }
        let menu = NSMenu()
        // A bar too full for the icon says so first, with what to do.
        if let help = dividerRoomHelp {
            let note = NSMenuItem(title: "The bar is too full for the JR-Bar icon", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            let detail = NSMenuItem(title: help, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
            menu.addItem(.separator())
        }
        for entry in MenuBarCombinedMenu.entries(
            plan: lastPlan, hiddenRevealed: hider.revealed.contains(.hidden)) {
            switch entry.kind {
            case .separator:
                menu.addItem(.separator())
            case .toggleHidden:
                let menuItem = NSMenuItem(
                    title: entry.title,
                    action: #selector(MenuBarMenuActions.menuToggleHidden(_:)),
                    keyEquivalent: "")
                menuItem.target = menuActions
                menu.addItem(menuItem)
            case .openBar:
                let menuItem = NSMenuItem(
                    title: entry.title,
                    action: #selector(MenuBarMenuActions.menuOpenBar(_:)),
                    keyEquivalent: "")
                menuItem.target = menuActions
                // The row names the toggle hotkey when it is on — the
                // keyboard's own way to the same bar.
                if settings().revealStyle == .bar,
                   let hotkey = resolvedHotkeyBindings().first(where: { $0.action == .toggleReveal && $0.enabled }),
                   let key = Self.menuKeyEquivalent(for: hotkey) {
                    menuItem.keyEquivalent = key
                    menuItem.keyEquivalentModifierMask = MenuBarHotkeyBinding.eventModifiers(hotkey.modifiers)
                }
                menu.addItem(menuItem)
            case .item(let id, _):
                let menuItem = NSMenuItem(
                    title: entry.title,
                    action: #selector(MenuBarMenuActions.menuItemClicked(_:)),
                    keyEquivalent: "")
                menuItem.target = menuActions
                menuItem.representedObject = id
                if let listed = (lastPlan.hidden + lastPlan.alwaysHidden)
                    .first(where: { $0.id == id }) {
                    let icon = listed.owner?.icon
                    icon?.size = NSSize(width: 16, height: 16)
                    menuItem.image = icon
                }
                menu.addItem(menuItem)
            case .more:
                let menuItem = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = false
                menu.addItem(menuItem)
            }
        }
        // The menu that acts: the apps standing on the bar, each a click
        // from hidden. While nothing hides yet they lead as the teaching
        // list; once something does they wait in a submenu.
        if let (inline, hideRows) = Self.hideMenu(
            shown: lastPlan.shown, hiddenCount: lastPlan.hidden.count + lastPlan.alwaysHidden.count) {
            let target: NSMenu
            menu.addItem(.separator())
            if inline {
                let header = NSMenuItem(title: "Hide in the Menu Bar", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                target = menu
            } else {
                let parent = NSMenuItem(title: "Hide Another App", action: nil, keyEquivalent: "")
                target = NSMenu()
                parent.submenu = target
                menu.addItem(parent)
            }
            for row in hideRows {
                let menuItem = NSMenuItem(title: row.title,
                                          action: #selector(MenuBarMenuActions.menuHideApp(_:)),
                                          keyEquivalent: "")
                menuItem.target = menuActions
                menuItem.representedObject = row.itemID
                if let listed = lastPlan.shown.first(where: { $0.id == row.itemID }) {
                    let icon = listed.owner?.icon.flatMap { $0.copy() as? NSImage }
                    icon?.size = NSSize(width: 16, height: 16)
                    menuItem.image = icon
                }
                target.addItem(menuItem)
            }
        }
        // Which profile is laid over the bar, and a click away from the
        // others — no trip to Settings to see or switch.
        let rows = MenuBarCombinedMenu.profileRows(profiles: settings().profiles,
                                                   activeID: settings().curation.activeProfileID)
        if !rows.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for row in rows {
                let menuItem = NSMenuItem(title: row.title,
                                          action: #selector(MenuBarMenuActions.menuApplyProfile(_:)),
                                          keyEquivalent: "")
                menuItem.target = menuActions
                menuItem.representedObject = row.id
                menuItem.state = row.active ? .on : .off
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    /// The menu's profile rows land here.
    fileprivate func menuProfileActivated(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        applyProfile(id: id)
    }

    /// The icon menu's hide list for a bar: the rows a click could hide
    /// (someone else's, never a protected system item), inline while
    /// nothing hides yet, else behind a submenu — nil when there is
    /// nothing to offer. Pure so a test pins it.
    nonisolated static func hideMenu(shown: [MenuBarItem],
                                     hiddenCount: Int) -> (inline: Bool, rows: [MenuBarCombinedMenu.HideRow])? {
        let rows = MenuBarCombinedMenu.hideRows(shown: hideAllTargets(shown))
        return rows.isEmpty ? nil : (hiddenCount == 0, rows)
    }

    /// The menu's hide rows land here: the same pick the card's picker
    /// makes, so a profile that speaks for the app takes it.
    fileprivate func menuHideActivated(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setSection(.hidden, for: id)
    }

    /// The menu's hidden-item rows land here: activate the item the
    /// same way a tile click does.
    fileprivate func menuItemActivated(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = (lastPlan.hidden + lastPlan.alwaysHidden)
                .first(where: { $0.id == id }) else { return }
        trigger(item)
    }

    /// The menu's toggle row lands here.
    fileprivate func menuToggleHiddenActivated() {
        toggleHiddenSection()
    }

    /// The deliberate reveal: collapse the spacer and start the rehide
    /// clock, or stand it back up when the run is already out. Hide and
    /// reveal are mutually exclusive — a manual hide cancels the rehide
    /// clock outright rather than leaving it armed to fire a second
    /// `onHide` after the spacer already stands.
    func toggleHiddenSection(fromKeyboard: Bool = false) {
        let now = Date()
        guard now.timeIntervalSince(lastChevronToggleAt) > 0.3 else { return }
        lastChevronToggleAt = now
        // The click's state is the Item Bar's, not the run's: a hover
        // can leave the run revealed with no surface up, and keying the
        // toggle on `revealed` then folds it back — the click that
        // "does nothing". Gating on the bar means every click answers:
        // the run's surface opens, or it closes.
        if bar.isOpen {
            reveal.cancelReveal()
            hider.hide()
            bar.close()
        } else if !hider.revealed.isEmpty {
            // The run is out on a hover reveal with no surface up: the
            // click puts it back — this is "Hide Items Again".
            hider.hide()
        } else if (lastPlan.hidden + lastPlan.alwaysHidden).isEmpty {
            // A dead click is the bug report it reads as: nothing is
            // parked, so the menu carries how the run earns items and
            // where they would list.
            popHiddenItemsMenu()
        } else {
            // `.inline` reflows the run onto the row (Ice, Hidden Bar);
            // `.bar` leaves it parked and answers with the Item Bar
            // alone (Bartender). One surface per style — an inline
            // reveal empties the run, so the panel would open blank.
            switch settings().revealStyle {
            case .inline:
                hider.reveal([.hidden])
                openBarForRemainder()
            case .bar:
                bar.open(keyboard: fromKeyboard)
            }
            reveal.rearm()
        }
        refreshBoundary()
    }

    /// The "Hidden Menu Bar Items" menu popped at the control that was
    /// clicked — with a teach row when the run is empty, so a dead run
    /// still answers the click with how to fill it. The toggle row is
    /// stripped here: "Reveal Hidden Items" with nothing hidden would
    /// just pop this same menu again.
    private func popHiddenItemsMenu() {
        guard let menu = hiddenItemsMenu() else { return }
        // entries() emits [toggle, openBar, items…]; drop the toggle.
        if let toggle = menu.items.first(where: {
            $0.action == #selector(MenuBarMenuActions.menuToggleHidden(_:)) }) {
            menu.removeItem(toggle)
        }
        // The hide rows teach by acting; the hint speaks only when there
        // is nothing on the bar a click could hide.
        if !menu.items.contains(where: { $0.action == #selector(MenuBarMenuActions.menuHideApp(_:))
                                          || $0.submenu != nil }) {
            let hint = NSMenuItem(title: Self.emptyRunHint, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.insertItem(hint, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        // Anchor at the click itself — the ‹ lives in the host's spacer
        // and the › in the island; the ear's clicks arrive off the
        // monitor where no currentEvent exists, so screen coords it is.
        WindowPresenter.automatic.perform {
            _ = menu.popUp(positioning: nil,
                           at: NSPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 4),
                           in: nil)
        }
    }

    /// The empty run's teach row: how an item gets hidden. Pure so a test
    /// pins the copy.
    nonisolated static let emptyRunHint = "Hold ⌘ and drag an item left of the JR-Bar icon to hide it"

    /// The faces follow the run's state: the host takes the counts and
    /// draws its own hint.
    func refreshBoundary() {
        guard let host else { return }
        host.hiddenCount = lastPlan.hidden.count + lastPlan.alwaysHidden.count
        host.hiddenRevealed = hider.revealed.contains(.hidden)
    }

    /// The hider's length write. For the hidden run the host takes
    /// everything past its own glyph as spacer (a length at or under
    /// the glyph folds it).
    func setControlLength(_ section: MenuBarItemSection, length: CGFloat) {
        switch section {
        case .hidden:
            guard let host else { return }
            host.setBoundarySpacer(Self.standingSpacer(assigned: length, glyph: host.boundaryGlyphLength,
                revealed: hider.effectiveRevealedSections.contains(.hidden)))
        case .alwaysHidden, .shown:
            return
        }
    }

    /// The live control frame for the hider: the host's item, with the
    /// boundary's glyph share — none without a host.
    func controlFrames() -> MenuBarControlFrames {
        MenuBarControlFrames(hidden: host?.boundaryFrame,
            hiddenGlyph: host?.boundaryGlyphLength ?? MenuBarControlFrames.glyphLength)
    }

    /// The nearest on-row item edge on each notch flank — the x each ear
    /// stops short of, so a drawn wing never paves a real item (the « a
    /// hidden run keeps beside the notch, whatever macOS parks in the
    /// flank). Item bounds and the island share the
    /// x axis across the Quartz/AppKit flip — only x limits are read.
    /// nil per side while the flank is free.
    func publishEarAvoidance(_ plan: MenuBarHidePlan) {
        // The plan can contain positions read before this pass moved the
        // divider. Keep the last clearance until a new AX listing lands.
        guard hider.hasFreshControlListing else { return }
        guard let island = ScreenBarGeometry.islandScreenRect else {
            ScreenBarGeometry.setEarItemLimits(left: nil, right: nil)
            return
        }
        let s = liveSettings()
        let (left, right) = Self.earLimits(
            items: plan.shown + plan.hidden + plan.alwaysHidden,
            island: island, row: MenuBarItemLister.menuBarRow(),
            concealedApps: [:], sections: Self.earSections(plan: plan, configured: s.sections),
            revealed: hider.effectiveRevealedSections,
            ourPID: ProcessInfo.processInfo.processIdentifier,
            divider: host?.boundaryOccupiedFrame)
        ScreenBarGeometry.setEarItemLimits(left: left, right: right)
    }

    nonisolated static func earSections(plan: MenuBarHidePlan,
                                       configured: [String: MenuBarItemSection]) -> [String: MenuBarItemSection] {
        var sections = configured
        for item in plan.shown { sections[item.id] = .shown }
        for item in plan.hidden { sections[item.id] = .hidden }
        for item in plan.alwaysHidden { sections[item.id] = .alwaysHidden }
        return sections
    }

    /// The ear-limit classifier — pure so tests drive it without a notch
    /// window. The nearest on-row item edge on each flank is the limit;
    /// side is decided by centre, not edge clearance, because an item
    /// that merely straddles the island's edge — our own boundary icon
    /// seats that close — used to fail both tests and earn no limit at
    /// all, so the wing drew straight over it. A limit inside the
    /// island's span just suppresses the ear, which is the honest answer
    /// when the flank is already taken.
    ///
    /// Items our own process owns never earn a limit on their listed
    /// frames. `divider` is its painted icon and chevron, not the blank
    /// reservation used to park the hidden run. Moving blank space must
    /// not shrink the Notch or retire its hover region.
    nonisolated static func earLimits(
        items: [MenuBarItem], island: CGRect, row: CGRect,
        concealedApps: [String: MenuBarItemSection],
        sections: [String: MenuBarItemSection],
        revealed: Set<MenuBarItemSection>,
        ourPID: pid_t,
        divider: CGRect? = nil
    ) -> (left: CGFloat?, right: CGFloat?) {
        var left: CGFloat? = nil
        var right: CGFloat? = nil
        if let divider, divider.intersects(row) {
            if divider.midX <= island.midX {
                left = divider.maxX
            } else {
                right = divider.minX
            }
        }
        for item in items {
            if item.ownerPID == ourPID { continue }
            let f = item.bounds
            guard f.intersects(row) else { continue }
            // A parked or covered item is already invisible — the wing
            // may stand on its slot without paving anything the person
            // can see. A revealed run stands for real and still counts.
            let section = item.bundleID.flatMap { concealedApps[$0] } ?? sections[item.id]
            if let section, section != .shown, !revealed.contains(section) { continue }
            if f.midX <= island.midX {
                left = max(left ?? -.infinity, f.maxX)
            } else {
                right = min(right ?? .infinity, f.minX)
            }
        }
        return (left, right)
    }

    /// The hidden stretch ends strictly before the chevron beside JR-Bar's icon.
    func revealZone() -> NSRect? {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        let quartzRow = MenuBarItemLister.menuBarRow()
        let row = NSRect(x: quartzRow.minX, y: height - quartzRow.maxY,
                         width: quartzRow.width, height: quartzRow.height)
        let boundary = controlFrames().hidden.map {
            NSRect(x: $0.minX, y: height - $0.maxY, width: $0.width, height: $0.height)
        }
        return Self.revealZone(row: row, boundary: boundary,
                               hoverFrame: host?.boundaryHoverFrame, fitEdge: hider.fitEdge)
    }

    nonisolated static func revealZone(row: NSRect, boundary: NSRect?,
                                      hoverFrame: NSRect?, fitEdge: CGFloat?) -> NSRect? {
        // Missing native geometry must not widen hover to the whole menu bar.
        guard let boundary, boundary.intersects(row) else {
            return NSRect(x: row.minX, y: row.minY, width: 0, height: row.height)
        }
        // An empty seat must stay empty. nil would make the gesture use the whole row.
        guard let hoverFrame, hoverFrame.width > 0 else {
            return NSRect(x: boundary.minX, y: row.minY, width: 0, height: row.height)
        }
        let edge = (fitEdge ?? boundary.minX) - 30
        let minX = min(edge, boundary.minX)
        let maxX = min(hoverFrame.maxX, boundary.maxX)
        return NSRect(x: minX, y: row.minY, width: max(0, maxX - minX), height: row.height)
    }

    /// Bartender's "show for updates": a hidden item that rewrote its
    /// title — a clock's minute, a VPN's "Connected" — reveals its run
    /// for the re-hide interval so the change is seen, then parks
    /// again; with the Screen Bar's ears up it nudges from the right ear
    /// instead and the bar stays put. Seeded silently on the first plan
    /// and skipped while a reveal is open, so the feature never
    /// announces its own motion.
    func noticeUpdates(in plan: MenuBarHidePlan) {
        guard settings().showForUpdates else {
            updateSignatures = [:]
            updateHideTask?.cancel()
            updateHideTask = nil
            return
        }
        let result = MenuBarItemHider.updatedHidden(
            previous: updateSignatures,
            hidden: plan.hidden,
            alwaysHidden: plan.alwaysHidden)
        let seeded = !updateSignatures.isEmpty
        let previous = updateSignatures
        updateSignatures = result.signatures
        guard seeded, !result.sections.isEmpty, hider.revealed.isEmpty else { return }
        let changed = (plan.hidden.map { ($0, MenuBarItemSection.hidden) }
            + plan.alwaysHidden.map { ($0, MenuBarItemSection.alwaysHidden) })
            .filter { item, _ in
                previous[item.id].map { $0 != result.signatures[item.id] } ?? false
            }
        // With the Screen Bar's ears up the change goes to the right ear
        // instead: its glyph for a beat, its new title in the peek — the
        // bar never moves. Without them the run reveals as it always did.
        if earAvailable() {
            if let item = Self.earUpdate(changed: changed.map(\.0),
                                         watch: Set(settings().curation.updateWatch)) {
                bar.updatedIDs.insert(item.id)
                raiseEarNudge(.update, item: item, detail: item.title)
            }
            return
        }
        let sections = Self.updateReveal(changed: changed,
                                         watch: Set(settings().curation.updateWatch))
        guard !sections.isEmpty else { return }
        let seconds = settings().rehideSeconds
        hider.reveal(sections)
        updateHideTask?.cancel()
        updateHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            self?.hider.hide()
        }
    }

    /// The owner key "show for updates" watches an item by: its bundle,
    /// or its own id for a helper without one.
    nonisolated static func updateWatchKey(_ item: MenuBarItem) -> String {
        item.bundleID ?? item.id
    }

    /// What one show-for-updates pass reveals: the sections of the changed
    /// hidden items the watch list lets through (all of them while it is
    /// empty). Pure so a test pins it.
    nonisolated static func updateReveal(changed: [(MenuBarItem, MenuBarItemSection)],
                                         watch: Set<String>) -> Set<MenuBarItemSection> {
        Set(changed.filter { item, _ in watch.isEmpty || watch.contains(updateWatchKey(item)) }
            .map(\.1))
    }

    /// Whether "show for updates" watches `item` by name — false while
    /// the watch list is empty (then it watches everything).
    func watchesUpdates(of item: MenuBarItem) -> Bool {
        settings().curation.updateWatch.contains(Self.updateWatchKey(item))
    }

    /// Mark or unmark an item's owner for "show for updates".
    func setWatchesUpdates(_ on: Bool, for item: MenuBarItem) {
        let key = Self.updateWatchKey(item)
        update { draft in
            draft.curation.updateWatch.removeAll { $0 == key }
            if on { draft.curation.updateWatch.append(key) }
        }
    }

}

/// The boundary's host: what the Menu Bar utility needs from the app's
/// own status item to make it the hidden run's edge — its frame, its
/// icon's width, a spacer write, the reveal click, the hidden-items
/// submenu, and the counts it draws its hint from.
@MainActor
protocol MenuBarBoundaryHost: AnyObject {
    /// The icon's frame in Quartz coordinates; nil before the item has a
    /// window.
    var boundaryFrame: CGRect? { get }
    /// Revealable blank space before the chevron, in AppKit screen coordinates.
    var boundaryHoverFrame: NSRect? { get }
    /// Painted controls that the Notch must avoid, excluding blank reservation.
    var boundaryOccupiedFrame: CGRect? { get }
    /// The icon's own width — the part that is not spacer.
    var boundaryGlyphLength: CGFloat { get }
    /// Claim `length` points of blank bar left of the icon (0 folds).
    func setBoundarySpacer(_ length: CGFloat)
    /// The menu bar's appearance, read off the real button: a template
    /// glyph resolves to the bar's label colour, not the app's.
    var barAppearance: NSAppearance? { get }
    var onBoundaryClick: (@MainActor () -> Void)? { get set }
    var onBoundaryWidthChange: (@MainActor () -> Void)? { get set }
    var hiddenItemsMenu: (@MainActor () -> NSMenu?)? { get set }
    var hiddenCount: Int { get set }
    var hiddenRevealed: Bool { get set }
}

extension MenuBarBoundaryHost {
    var onBoundaryWidthChange: (@MainActor () -> Void)? {
        get { nil }
        set {}
    }
    var boundaryHoverFrame: NSRect? {
        guard let frame = boundaryFrame else { return nil }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        let bounds = StatusItemController.boundaryRevealBounds(
            NSRect(origin: .zero, size: frame.size),
            spacer: max(0, frame.width - boundaryGlyphLength), glyphWidth: boundaryGlyphLength)
        return bounds.offsetBy(dx: frame.minX, dy: height - frame.maxY)
    }
    var boundaryOccupiedFrame: CGRect? { boundaryFrame }
}

/// The hidden-items submenu's target: an `NSObject` shim so `MenuBarUtility`
/// stays a plain `@Observable` class (the `BuddyMenuActions` pattern).
/// The button's action only ever fires on the main thread.
@MainActor
final class MenuBarMenuActions: NSObject {
    weak var utility: MenuBarUtility?

    @objc func menuToggleHidden(_ sender: NSMenuItem) {
        utility?.menuToggleHiddenActivated()
    }

    @objc func menuOpenBar(_ sender: NSMenuItem) {
        utility?.bar.toggle()
    }

    @objc func menuItemClicked(_ sender: NSMenuItem) {
        utility?.menuItemActivated(sender)
    }

    @objc func menuApplyProfile(_ sender: NSMenuItem) {
        utility?.menuProfileActivated(sender)
    }

    @objc func menuHideApp(_ sender: NSMenuItem) {
        utility?.menuHideActivated(sender)
    }
}
