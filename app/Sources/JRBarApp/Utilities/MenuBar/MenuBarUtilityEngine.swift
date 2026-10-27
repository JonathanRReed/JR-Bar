import AppKit
import CoreGraphics
import JRBarCore

/// The Menu Bar utility's engine: the divider (the JR-Bar icon, position
/// is the setting). This is the wiring: the bookkeeping that keeps
/// "position is the setting" true, and what the bar does while a ⌘-drag
/// moves an item. The rules are pure (`MenuBarDividerRoomWatch`,
/// `MenuBarPointerGate`, `MenuBarPositionDiff`).
extension MenuBarUtility {
    // MARK: Inputs

    /// The apps the saved list hides: the curated base map, less the apps
    /// the record does not speak for. Under the divider this is only a
    /// record (and, once, the source of the suggestions).
    func savedHiddenList() -> Set<String> {
        Set(curatedSettings().concealedApps
            .filter { $0.value != .shown && Self.recordsApp($0.key) }.keys)
    }

    /// How many things sit left of the icon by position, for the card.
    /// Apps count once however many items they have.
    var dividerHiddenCount: Int {
        Set((lastPlan.hidden + lastPlan.alwaysHidden).filter {
            !$0.isNativeOverflowControl && !MenuBarItemLister.isProtected($0)
        }.map { $0.bundleID ?? $0.id }).count
    }

    /// The divider icon's glyph in AppKit screen coordinates — where the
    /// Item Bar and a note hang under the real icon. nil without a window.
    func dividerGlyphFrame() -> NSRect? {
        guard let quartz = host?.boundaryFrame else { return nil }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        let glyph = min(host?.boundaryGlyphLength ?? quartz.width, quartz.width)
        return NSRect(x: quartz.maxX - glyph, y: height - quartz.maxY, width: glyph, height: quartz.height)
    }

    // MARK: Picks that need a hand

    /// Under the divider an app's place is where it sits, and JR-Bar never
    /// moves another app's item (a synthetic drag would move the person's
    /// real pointer). A pick to move one is answered with the one gesture
    /// that does it, and a pick to bring one back opens the reveal first so
    /// it is drawn and can be dragged.
    func guideDrag(item: MenuBarItem, to section: MenuBarItemSection) {
        let parked = Self.parkedRemainder(plan: lastPlan, rows: MenuBarItemLister.menuBarRows())
            .contains { $0.id == item.id }
        if section == .shown, !hider.revealed.contains(.hidden) {
            reveal.triggerReveal("a pick asked for \(item.ownerName) back")
        }
        let current: MenuBarItemSection =
            lastPlan.alwaysHidden.contains { $0.id == item.id } ? .alwaysHidden
            : lastPlan.hidden.contains { $0.id == item.id } ? .hidden : .shown
        guard current != section else { return }
        let text = MenuBarPositionCopy.guide(name: item.displayName, to: section, parked: parked)
        if let presentDropNote {
            presentDropNote(text)
        } else {
            bar.showNote(text, for: 7)
        }
    }

    /// A display was attached, removed or rearranged: the bar's room is a
    /// new question.
    func displaysChanged() {
        dividerRoom.reset()
        engineVersion += 1
    }

    // MARK: What the card reads

    /// The bar by position, for the diagram.
    var positionContent: MenuBarPositionContent {
        _ = engineVersion
        return MenuBarPositionContent.make(plan: lastPlan, rows: MenuBarItemLister.menuBarRows())
    }

    /// The apps the old saved list hid that the divider does not hide
    /// yet, each with where it sits — offered as suggestions, never acted
    /// on. nil once the hint is closed, or nothing is left to suggest.
    var suggestionsContent: MenuBarSuggestionsContent? {
        _ = engineVersion
        guard running else { return nil }
        let curation = settings().curation
        guard !curation.dividerSuggestions.isEmpty else { return nil }
        let content = MenuBarSuggestionsContent.make(
            suggestions: curation.dividerSuggestions, plan: lastPlan) { appName(for: $0) }
        return content.rows.isEmpty ? nil : content
    }

    /// Whether the one-line "hold ⌘ and drag" hint is up: the divider is
    /// the engine and the person has not closed it.
    var dividerHintShown: Bool {
        _ = engineVersion
        return running && !settings().curation.dividerHintDismissed
    }

    /// The person closed the hint.
    func dismissDividerHint() {
        update { $0.curation.dividerHintDismissed = true }
        engineVersion += 1
    }

    /// The person took an app off the suggestions (they do not want it
    /// hidden, or it is gone). It is not hidden or shown by this.
    func forgetSuggestion(_ bundleID: String) {
        update { $0.curation.dividerSuggestions.removeAll { $0 == bundleID } }
        engineVersion += 1
    }

    /// Running apps already have display names; saved picks resolve in
    /// the background, including apps that are installed but not running.
    func appName(for bundleID: String) -> String {
        if let name = RunningApps.shared.apps.first(where: { $0.bundleID == bundleID })?.name,
           !name.isEmpty { return MenuBarAppNames.displayName(name) }
        return MenuBarAppNames.shared.name(for: bundleID)
    }

    /// Whether the divider's icon is the leftmost thing the bar draws of
    /// anyone's, with apps standing right of it: then nothing can be left of
    /// it yet and the first gesture is to drag the icon itself. Pure on the
    /// plan and the icon's frame, so a test pins it.
    var dividerIconLeftmost: Bool {
        guard let icon = host?.boundaryFrame else { return false }
        return Self.iconIsLeftmost(icon: icon, plan: lastPlan, row: hider.rowRect())
    }

    nonisolated static func iconIsLeftmost(icon: CGRect, plan: MenuBarHidePlan, row: CGRect) -> Bool {
        let drawn = (plan.shown + plan.hidden + plan.alwaysHidden).filter {
            !$0.isNativeOverflowControl && !MenuBarItemLister.isProtected($0)
                && isForeignOwner($0.ownerName) && $0.bounds.intersects(row)
        }
        guard icon.intersects(row), drawn.contains(where: { $0.bounds.minX >= icon.maxX - 2 }) else { return false }
        return !drawn.contains { $0.bounds.maxX <= icon.minX + 2 }
    }

    // MARK: A bar too crowded for the icon

    /// What the card and the icon's menu say when the divider has no room:
    /// how many items sit in macOS's overflow and how few would have to
    /// leave the bar to seat the icon. nil while the icon holds a place.
    var dividerRoomHelp: String? {
        _ = engineVersion
        guard running, dividerRoom.room == .noRoom else { return nil }
        return Self.roomHelp(plan: lastPlan, rows: MenuBarItemLister.menuBarRows(),
                             glyph: host?.boundaryGlyphLength ?? MenuBarControlFrames.glyphLength,
                             ourPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// The gap macOS keeps between two items, with room to spare.
    nonisolated static let roomGap: CGFloat = 8

    /// Pure: the help line for a plan on `rows`. The items that could
    /// leave are the ones drawn on the row now (not ours, not the native
    /// « control).
    nonisolated static func roomHelp(plan: MenuBarHidePlan, rows: [CGRect], glyph: CGFloat,
                                     ourPID: pid_t) -> String {
        let widths = plan.shown.filter {
            !$0.isNativeOverflowControl && $0.ownerPID != ourPID
                && rows.contains(where: $0.bounds.intersects)
        }.map(\.bounds.width)
        let remove = MenuBarRoomHelp.itemsToFree(widths: widths, need: glyph + roomGap)
        return MenuBarRoomHelp.line(parked: parkedRemainder(plan: plan, rows: rows).count, remove: remove)
    }

    // MARK: What JR-Bar sees

    /// The lines under "What JR-Bar sees": the engine, the icon, the
    /// spacer, the two sides and the last change a drop made.
    var dividerReadout: MenuBarDividerReadout {
        _ = engineVersion
        let row = hider.rowRect()
        let icon = host?.boundaryFrame.flatMap { $0.intersects(row) ? $0 : nil }
        let parked = Self.parkedRemainder(plan: lastPlan, rows: MenuBarItemLister.menuBarRows()).count
        let apps = { (items: [MenuBarItem]) in
            Set(items.filter {
                !$0.isNativeOverflowControl && !MenuBarItemLister.isProtected($0)
                    && Self.isForeignOwner($0.ownerName)
            }.map { $0.bundleID ?? $0.id }).count
        }
        return MenuBarDividerReadout.make(.init(
            standing: host != nil,
            iconFrame: icon,
            spacer: hider.assignedLengths[.hidden],
            fitEdge: hider.fitEdge,
            fitEdgeLearned: hider.fitEdgeLearned,
            spacerShortBy: lastPlan.spacerShortBy,
            wake: hider.wake.verdict,
            revealed: hider.revealed.contains(.hidden),
            holding: pointerGate.pressing || dividerDropPending,
            hidden: apps(lastPlan.hidden + lastPlan.alwaysHidden),
            shown: apps(lastPlan.shown),
            parked: parked,
            room: dividerRoom.room,
            lastChange: lastPositionChange))
    }

    // MARK: Migration

    /// A file from before the position model keeps every pick. What moves:
    /// the reveal draws hidden items on the bar (Ice) instead of opening
    /// the Item Bar (model 1), and the apps the saved list hid are kept
    /// as suggestions the divider offers and never acts on (model 2).
    /// Nothing is cleared, shown or hidden here.
    func migratePositionModel() {
        let current = settings()
        guard current.curation.positionModel < MenuBarCuration.currentPositionModel else { return }
        let listed = savedHiddenList().sorted()
        update { draft in
            if draft.curation.positionModel < 1, draft.revealStyle == .bar { draft.revealStyle = .inline }
            draft.curation.positionModel = MenuBarCuration.currentPositionModel
            if draft.curation.dividerSuggestions.isEmpty { draft.curation.dividerSuggestions = listed }
        }
    }

    // MARK: What a pass learns

    /// Called with each raw plan: the divider's room, a drop's result,
    /// and the positional record.
    func notePositions(in raw: MenuBarHidePlan) {
        feedDividerRoom()
        noteDividerDrop(raw)
        syncPositionalList(raw)
    }

    /// One look at whether the divider's icon holds its place.
    private func feedDividerRoom() {
        guard Date() >= startSettleUntil,
              let frame = host?.boundaryFrame else { return }
        let row = hider.rowRect()
        let glyph = MenuBarControlFrames.glyphLength
        let spacer = hider.assignedLengths[.hidden] ?? glyph
        let minimal = spacer <= glyph + 1 || !hider.revealed.isEmpty
        let before = dividerRoom.room
        dividerRoom.note(iconOnRow: frame.intersects(row), spacerIsMinimal: minimal,
                         now: engineClock())
        if dividerRoom.room != before { engineVersion += 1 }
    }

    // MARK: A ⌘-drag under the divider

    /// Whether the bar is held still for a drag, or for the beat after
    /// one (`MenuBarPointerGate`). The hider, the hover reveal, the
    /// rehide clock and the positional record all stand down while it is.
    func pointerHolds() -> Bool {
        pointerGate.holding(buttonDown: leftButtonDown(), now: engineClock())
    }

    /// A ⌘-press on a bar while the divider is the engine. macOS moves
    /// the item; JR-Bar writes nothing and only holds still, then reads
    /// where the item landed (`noteDividerDrop`).
    func dividerDragPressed(at point: CGPoint) {
        guard settings().enabled,
              dragBarRows().contains(where: { $0.insetBy(dx: 0, dy: -MenuBarDragRules.slack).contains(point) })
        else { return }
        // A ⌘-click on an app's menu title is no drag. With no listing to
        // judge by (no Accessibility) any press on the bar counts.
        let items = listedItems
        let ours = host?.boundaryFrame
        guard items.isEmpty || ours?.insetBy(dx: -2, dy: -2).contains(point) == true
                || items.contains(where: { $0.bounds.insetBy(dx: -2, dy: -2).contains(point) })
        else { return }
        pointerGate.press(now: engineClock())
        dividerDragBefore = lastPlan
        dividerDropPending = false
        MenuBarUtility.log.notice("drag: ⌘-press on the bar — JR-Bar holds still until the drop settles")
        engineVersion += 1
    }

    /// The release that ends it: one reconcile follows the settle beat.
    func dividerDragReleased() {
        guard pointerGate.pressing else { return }
        pointerGate.release(now: engineClock())
        hider.noteBarReformed("a menu bar item was placed")
        dividerDropPending = true
        engineVersion += 1
        // Held for the settle beat, then run once.
        hider.reconcile()
    }

    /// The reconcile after a drop: say what moved. Observes only.
    private func noteDividerDrop(_ plan: MenuBarHidePlan) {
        guard dividerDropPending, !pointerGate.pressing, let before = dividerDragBefore else { return }
        dividerDropPending = false
        dividerDragBefore = nil
        let changes = MenuBarPositionDiff.changes(before: before, after: plan)
        engineVersion += 1
        guard !changes.isEmpty else {
            MenuBarUtility.log.notice("drag: dropped — no item changed sides")
            return
        }
        for change in changes {
            MenuBarUtility.log.notice("drag: \(change.sentence, privacy: .public)")
        }
        let text = changes.prefix(2).map(\.sentence).joined(separator: "; ")
        lastPositionChange = text
        if let presentDropNote {
            presentDropNote(text + ".")
        } else {
            bar.showNote(text + ".", for: MenuBarDragRules.noteSeconds)
        }
    }

    // MARK: The positional record

    /// How long and how many passes the positions must agree before the
    /// record is written.
    nonisolated static let recordPasses = 3
    nonisolated static let recordSeconds: TimeInterval = 3

    /// Under the divider the saved list follows what the bar shows: an
    /// app whose items all stand in the hidden run is on it, one with an
    /// item on the shown side is off it, and an app not on the bar right
    /// now keeps what it had. It is a record only; nothing here hides
    /// anything. Written only after the same answer holds for
    /// `recordPasses` passes over `recordSeconds`, and never while a
    /// reveal, an overlay or a drag moves things.
    private func syncPositionalList(_ raw: MenuBarHidePlan) {
        guard hider.revealed.isEmpty, activeOverlay == nil,
              !pointerGate.pressing, !dividerDropPending,
              Date() >= startSettleUntil else {
            pendingPositionalList = nil
            return
        }
        let current = settings().concealedApps
        let next = Self.positionalRecord(current: current, raw: raw)
        guard next != current else {
            pendingPositionalList = nil
            return
        }
        let now = engineClock()
        if let pending = pendingPositionalList, pending.list == next {
            pendingPositionalList = (next, pending.seen + 1, pending.since)
        } else {
            pendingPositionalList = (next, 1, now)
        }
        guard let pending = pendingPositionalList, pending.seen >= Self.recordPasses,
              now - pending.since >= Self.recordSeconds else { return }
        pendingPositionalList = nil
        let hiddenNow = next.values.filter { $0 != .shown }.count
        MenuBarUtility.log.notice("record: the bar's positions now hide \(hiddenNow, privacy: .public) app(s)")
        update { $0.concealedApps = next }
    }

    /// The list after reading the bar: pure so a test pins it.
    nonisolated static func positionalRecord(current: [String: MenuBarItemSection],
                                             raw: MenuBarHidePlan) -> [String: MenuBarItemSection] {
        let onBar = Set((raw.shown + raw.hidden + raw.alwaysHidden).compactMap(\.bundleID))
            .filter { recordsApp($0) && !isOwnFamily($0) }
        let hiddenByPosition = positionalList(plan: raw)
        var next = current
        for app in onBar {
            if let section = hiddenByPosition[app] {
                next[app] = section
            } else {
                next[app] = nil
            }
        }
        return next
    }

    /// The list a bar's positions spell out: every app whose items are all
    /// in the plan's hidden run (none shown), keyed by bundle identifier.
    nonisolated static func positionalList(plan: MenuBarHidePlan) -> [String: MenuBarItemSection] {
        var shownApps = Set<String>()
        for item in plan.shown { if let id = item.bundleID { shownApps.insert(id) } }
        var list: [String: MenuBarItemSection] = [:]
        for (items, section) in [(plan.hidden, MenuBarItemSection.hidden),
                                 (plan.alwaysHidden, MenuBarItemSection.alwaysHidden)] {
            for item in items {
                guard let id = item.bundleID, recordsApp(id), !isOwnFamily(id), !shownApps.contains(id),
                      !item.isNativeOverflowControl else { continue }
                // Always hidden outranks hidden for an app with items in both.
                if list[id] == .alwaysHidden { continue }
                list[id] = section
            }
        }
        return list
    }

    // MARK: A reveal that leaves hidden items parked

    /// The hidden items a reveal could not draw: macOS parked them in its
    /// own overflow because the run right of the notch holds only so many.
    /// They are not lost — the Item Bar reaches them — and a reveal that
    /// leaves some says so by opening it. Pure so a test pins it.
    nonisolated static func parkedRemainder(plan: MenuBarHidePlan, rows: [CGRect]) -> [MenuBarItem] {
        (plan.hidden + plan.alwaysHidden).filter { item in
            !item.isNativeOverflowControl
                && !MenuBarItemLister.isProtected(item)
                && !rows.contains { $0.intersects(item.bounds) }
        }
    }

    /// How long a reveal is left to reflow before the bar is read again.
    nonisolated static let remainderSettle: TimeInterval = 0.9

    /// The plan with the hidden items' frames replaced by a fresh listing's,
    /// by id: after a reveal the plan's own frames can be the last scan's,
    /// from before the bar reflowed. An item the fresh listing does not
    /// name keeps its frame. Pure so a test pins it.
    nonisolated static func refreshed(_ plan: MenuBarHidePlan, with fresh: [MenuBarItem]) -> MenuBarHidePlan {
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = plan
        out.hidden = plan.hidden.map { byID[$0.id] ?? $0 }
        out.alwaysHidden = plan.alwaysHidden.map { byID[$0.id] ?? $0 }
        return out
    }

    /// After an inline reveal: once the bar has reflowed, read it fresh and
    /// open the Item Bar if hidden items are still parked. Without
    /// Accessibility there is no fresh reading to trust, so nothing opens by
    /// itself; the icon's ‹ and the hotkey still do.
    func openBarForRemainder() {
        remainderTask?.cancel()
        remainderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.remainderSettle * 1e9))
            guard !Task.isCancelled, let self, self.running,
                  self.hider.revealed.contains(.hidden), !self.bar.isOpen,
                  self.settings().revealStyle == .inline,
                  let fresh = await MenuBarItemLister.freshAXItems() else { return }
            guard !Task.isCancelled, self.hider.revealed.contains(.hidden), !self.bar.isOpen else { return }
            let plan = Self.refreshed(self.lastPlan, with: fresh)
            let left = Self.parkedRemainder(plan: plan, rows: MenuBarItemLister.menuBarRows())
            guard !left.isEmpty else { return }
            MenuBarUtility.log.notice("reveal: \(left.count, privacy: .public) hidden item(s) did not fit — opening the Item Bar")
            self.bar.open(keyboard: false)
        }
    }
}
