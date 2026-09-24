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

    /// Seed our own items' preferred positions — the system stores them
    /// in our defaults under this key, so the first run lands the
    /// controls near the row's middle rather than wherever the system
    /// happened to drop them. Only ever seeds an absent key: a slot
    /// the person ⌘-dragged to is theirs.
    static func seedPreferredPosition(_ position: Double, autosaveName: String) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(position, forKey: key)
            // The item registers a beat later — without the sync the
            // write can sit in the in-memory cache and cfprefsd hands
            // the registrar nothing.
            UserDefaults.standard.synchronize()
        }
    }

    /// The boundary: the host's spacer — the app's own status item, one
    /// of ours on the row — and, under the concealer, the mirror's ‹.
    /// No host, no boundary: JR-Bar never registers a second item to
    /// stand in (a registered one, even hidden, still read frames into
    /// the hot zones, the cover blockers and the ear limits). Safe to
    /// call any time.
    func installBoundary() {
        // Under the agent the hider never sizes the control — and no
        // affordance is claimed: the width pushed our slot into the
        // notch dead zone and parked the item. Under the spacer engine
        // the plan's own writes floor the mark; this only makes it
        // immediate.
        host?.setBoundarySpacer(concealer == nil ? Self.boundaryAffordance : 0)
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
        ScreenBarGeometry.earItemLimitLeft = nil
        ScreenBarGeometry.earItemLimitRight = nil
    }

    /// A spacer item's click: left toggles the hidden run; right-click
    /// (or ⌥-click) opens the Item Bar.
    func spacerClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            bar.toggle()
        } else {
            toggleHiddenSection()
        }
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
        // is nothing on the bar a click could hide. Under the concealer
        // position teaches nothing — the picker is the way in; under the
        // spacer the mark is the separator.
        if !menu.items.contains(where: { $0.action == #selector(MenuBarMenuActions.menuHideApp(_:))
                                          || $0.submenu != nil }) {
            let hint = NSMenuItem(
                title: concealer != nil
                    ? "Pick apps to hide in Settings › Utilities › Menu Bar"
                    : "⌘-drag an item left of the ‹ mark to hide it",
                action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.insertItem(hint, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        // Anchor at the click itself — the ‹ lives in the host's spacer
        // and the › in the island; the ear's clicks arrive off the
        // monitor where no currentEvent exists, so screen coords it is.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 4),
                   in: nil)
    }

    /// The ear's ‹ handle — the hidden run's affordance while the agent
    /// conceals and the real item is the icon: non-nil (the glyph's
    /// direction) while it should stand. The screen bar reads it through
    /// `menuHandleProvider`. While the mirror carries the icon its own ‹
    /// is the handle, and a second one on the ear ~165 pt away would
    /// only split the job — the right ear keeps just its provider mark.
    var menuHandleRevealed: Bool? {
        // The concealer's presence, not its instant assertion — a
        // reveal lifts it for seconds, and the handle is exactly the ‹
        // rehide affordance while the run is out. Seeded keeps it off a
        // map-less fresh bar.
        guard concealer != nil, settings().concealSeeded, !iconMirrored else { return nil }
        return hider.revealed.contains(.hidden)
    }

    /// The island handle's click — the same toggle the chevron answers.
    func toggleMenuHandle() {
        MenuBarCombinedItem.log.notice("menu handle click: hidden=\(self.lastPlan.hidden.count) revealed=\(self.hider.revealed.contains(.hidden))")
        toggleHiddenSection()
    }

    /// The faces follow the run's state: the host takes the counts and
    /// draws its own hint, and the ear's ‹ turns with the run.
    func refreshBoundary() {
        let revealed = hider.revealed.contains(.hidden)
        if let host {
            host.hiddenCount = lastPlan.hidden.count + lastPlan.alwaysHidden.count
            host.hiddenRevealed = revealed
        }
        // The ear's ‹ turns to › with the run: say so while it can stand.
        if revealed != handleRevealedSeen {
            handleRevealedSeen = revealed
            if concealer != nil { menuHandleChanged() }
        }
    }

    /// The hider's length write. For the hidden run the host takes
    /// everything past its own glyph as spacer (a length at or under
    /// the glyph folds it).
    func setControlLength(_ section: MenuBarItemSection, length: CGFloat) {
        if concealer != nil {
            // The agent hides; nothing of ours ever grows — the
            // affordance floor would push our slot into the notch dead
            // zone and park the item.
            host?.setBoundarySpacer(0)
            return
        }
        switch section {
        case .hidden:
            guard let host else { return }
            host.setBoundarySpacer(max(Self.boundaryAffordance,
                                     length - host.boundaryGlyphLength))
        case .alwaysHidden, .shown:
            return
        }
    }

    /// The live control frame for the hider: the host's item, with the
    /// boundary's glyph share — none without a host.
    func controlFrames() -> MenuBarControlFrames {
        // Under the concealer there is no boundary once the map is
        // seeded: no positional sections, no spacer, no « to read.
        if concealer != nil, settings().concealSeeded { return MenuBarControlFrames() }
        return MenuBarControlFrames(
            hidden: host?.boundaryFrame,
            hiddenGlyph: host?.boundaryGlyphLength ?? MenuBarControlFrames.glyphLength)
    }

    /// The nearest on-row item edge on each notch flank — the x each ear
    /// stops short of, so a drawn wing never paves a real item (the « a
    /// hidden run keeps beside the notch, whatever macOS parks in the
    /// flank). Item bounds and the island share the
    /// x axis across the Quartz/AppKit flip — only x limits are read.
    /// nil per side while the flank is free.
    func publishEarAvoidance(_ plan: MenuBarHidePlan) {
        guard let island = ScreenBarGeometry.islandScreenRect else {
            ScreenBarGeometry.earItemLimitLeft = nil
            ScreenBarGeometry.earItemLimitRight = nil
            return
        }
        let s = liveSettings()
        let (left, right) = Self.earLimits(
            items: plan.shown + plan.hidden + plan.alwaysHidden,
            island: island, row: MenuBarItemLister.menuBarRow(),
            concealedApps: s.concealedApps, sections: s.sections,
            revealed: hider.revealed,
            ourPID: ProcessInfo.processInfo.processIdentifier)
        if ScreenBarGeometry.earItemLimitLeft != left {
            ScreenBarGeometry.earItemLimitLeft = left
        }
        if ScreenBarGeometry.earItemLimitRight != right {
            ScreenBarGeometry.earItemLimitRight = right
        }
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
    /// Items our own process owns never earn a limit. Under the
    /// concealer none of them is drawn: macOS hides our own item under
    /// our own assertion, so the real item is slim and blank, and the
    /// icon is the mirror, our own surface right of the band. An
    /// undrawn slot of ours clamping an ear only took the ear off empty
    /// bar — the blank-face bug: the slim item beside the notch's edge,
    /// the ear yielding to it, and nothing visible where the icon sat.
    nonisolated static func earLimits(
        items: [MenuBarItem], island: CGRect, row: CGRect,
        concealedApps: [String: MenuBarItemSection],
        sections: [String: MenuBarItemSection],
        revealed: Set<MenuBarItemSection>,
        ourPID: pid_t
    ) -> (left: CGFloat?, right: CGFloat?) {
        var left: CGFloat? = nil
        var right: CGFloat? = nil
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

    /// The stretch a hover or an empty-space click reveals: from the
    /// region's edge to the boundary glyph's right edge, in AppKit
    /// screen coordinates. nil while no boundary stands.
    func revealZone() -> NSRect? {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        if concealer != nil {
            // Under the concealer the zone is the blank run the hidden
            // apps leave left of the icon — from where nothing covers the
            // row (the notch, the band and its ears, the front app's
            // menus) to the mirror's left edge, on the row the mirror
            // stands on. A notch-less bar also keeps only its right half:
            // the menu edge is missing while the front app does not
            // answer AX, and a hover over the File menu must never pop
            // the run.
            let row = Self.primaryRow()
            var start = mirrorClearOf()
            if NSScreen.screens.first?.auxiliaryTopRightArea == nil { start = max(start, row.midX) }
            let mirrorMinX = iconMirrored ? standingMirrorFrame?.minX : nil
            let shown = lastPlan.shown.filter {
                $0.bounds.intersects(row) && Self.isForeignOwner($0.ownerName)
                    && !$0.isNativeOverflowControl
            }.map(\.bounds.minX)
            guard let span = Self.concealedRevealSpan(start: start, mirrorMinX: mirrorMinX,
                                                      shownMinXs: shown) else {
                // No computable stretch: the hot frames alone answer
                // the gesture — the whole row must never pop the run.
                return NSRect.zero
            }
            return NSRect(x: span.lowerBound, y: height - row.maxY,
                          width: span.upperBound - span.lowerBound, height: row.height)
        }
        let row = MenuBarItemLister.menuBarRow()
        let frames = controlFrames()
        guard let boundary = frames.hidden, boundary.intersects(row) else { return nil }
        // The blank stretch starts where the spacer may land, less the
        // room the « takes — a gesture on the « is a gesture on the run.
        let edge = (hider.fitEdge ?? boundary.minX) - 30
        let minX = min(edge, boundary.minX)
        return NSRect(x: minX, y: height - row.maxY,
                      width: max(0, boundary.maxX - minX), height: row.height)
    }

    /// The concealer's reveal span on x: from `start` to the mirror's
    /// left edge — or, while no mirror stands, the leftmost foreign
    /// shown item right of `start`. Our own items never bound it (the
    /// slim real item sits wherever macOS keeps it), and the icon itself
    /// is never inside it. nil when there is no stretch. Pure so a test
    /// pins it.
    nonisolated static func concealedRevealSpan(start: CGFloat, mirrorMinX: CGFloat?,
                                                shownMinXs: [CGFloat]) -> ClosedRange<CGFloat>? {
        guard let end = mirrorMinX ?? shownMinXs.filter({ $0 > start }).min(),
              end > start else { return nil }
        return start...end
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
        let reveal = Self.updateReveal(
            changed: changed,
            watch: Set(settings().curation.updateWatch),
            concealing: concealer != nil)
        let seconds = settings().rehideSeconds
        // Under the concealer the changed app stands alone for the clock
        // — one item joins the row, not the whole run.
        for app in reveal.lifts {
            lift(app, until: Date().addingTimeInterval(seconds))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                self?.syncConcealer()
            }
        }
        guard !reveal.sections.isEmpty else { return }
        hider.reveal(reveal.sections)
        updateHideTask?.cancel()
        updateHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            self?.hider.hide()
        }
    }

    /// The combined popover's agents line: the feed's combined state,
    /// its detail, its tint.
    func combinedAgentLine() -> MenuBarSystemModel.AgentLine {
        let read = agentState()
        return MenuBarSystemModel.AgentLine(label: "Agents — \(read.state.label)",
                                            detail: read.detail, tintHex: read.state.tintHex)
    }

    /// The owner key "show for updates" watches an item by: its bundle,
    /// or its own id for a helper without one.
    nonisolated static func updateWatchKey(_ item: MenuBarItem) -> String {
        item.bundleID ?? item.id
    }

    /// What one show-for-updates pass acts on: the changed hidden items
    /// the watch list lets through (all of them while it is empty). An
    /// app the concealer takes is lifted alone; anything else — a covered
    /// extra, any item under the spacer engine — reveals its section.
    /// Pure so a test pins it.
    nonisolated static func updateReveal(changed: [(MenuBarItem, MenuBarItemSection)],
                                         watch: Set<String>,
                                         concealing: Bool) -> (lifts: Set<String>, sections: Set<MenuBarItemSection>) {
        var lifts = Set<String>()
        var sections = Set<MenuBarItemSection>()
        for (item, section) in changed where watch.isEmpty || watch.contains(updateWatchKey(item)) {
            if concealing, let app = item.bundleID, MenuBarConcealPlan.canConcealApp(app) {
                lifts.insert(app)
            } else {
                sections.insert(section)
            }
        }
        return (lifts, sections)
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

    /// A control's live frame in Quartz coordinates (top-left origin),
    /// off its button's window; nil when the control is not installed
    /// or has no window yet.
    static func quartzFrame(of item: NSStatusItem?) -> CGRect? {
        guard let frame = item?.button?.window?.frame else { return nil }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: frame.minX, y: height - frame.maxY,
                      width: frame.width, height: frame.height)
    }
}

/// The boundary's host: what the Menu Bar utility needs from the app's
/// own status item to make it the hidden run's edge — its frame, its
/// icon's width, a spacer write, the reveal click, the hidden-items
/// submenu, and the counts it draws its hint from — and, under the
/// concealer, what the mirror needs to stand in for it.
@MainActor
protocol MenuBarBoundaryHost: AnyObject {
    /// The icon's frame in Quartz coordinates — the mirror's face while
    /// it carries the icon; nil before the item has a window.
    var boundaryFrame: CGRect? { get }
    /// The icon's own width — the part that is not spacer.
    var boundaryGlyphLength: CGFloat { get }
    /// Claim `length` points of blank bar left of the icon (0 folds).
    func setBoundarySpacer(_ length: CGFloat)
    /// Whether the configured style draws an icon at all — every style
    /// but `.hidden`. Only a drawn icon gets a mirror.
    var anchorWantsVisibleSeat: Bool { get }
    /// Hand the icon to the mirror (true) or take it back. While
    /// mirrored the real item wears nothing and keeps a slim slot — the
    /// single owner of both, so no other path can un-blank it.
    func setFaceMirrored(_ mirrored: Bool)
    /// The mirror's face frame in AppKit screen coordinates while it
    /// carries the icon — the panel anchors on it. The utility writes it
    /// on every move and nils it when the mirror goes down.
    var mirroredFaceFrame: NSRect? { get set }
    /// What the icon wears, for the mirror.
    var face: MenuBarIconFace { get }
    /// Fires whenever `face` changes — the mirror is pushed, never polls.
    var onFaceChange: (@MainActor () -> Void)? { get set }
    /// The icon's ordinary click — the panel toggle.
    func faceClicked()
    /// The icon's right/Option click — the item's full menu, popped
    /// under `view`.
    func popUpMenu(in view: NSView)
    var onBoundaryClick: (@MainActor () -> Void)? { get set }
    var hiddenItemsMenu: (@MainActor () -> NSMenu?)? { get set }
    var hiddenCount: Int { get set }
    var hiddenRevealed: Bool { get set }
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
