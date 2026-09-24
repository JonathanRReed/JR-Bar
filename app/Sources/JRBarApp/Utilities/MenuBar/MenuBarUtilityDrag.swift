import AppKit
import CoreGraphics
import JRBarCore

/// One ⌘-press on the menu bar, held from the press to its release.
struct MenuBarDragInFlight {
    /// Where the press landed, in Quartz points.
    var start: CGPoint
    var pressedAt: Date
    /// The item under the press — nil when the press took hold of none.
    var grabbed: MenuBarItem?
    /// The icon's span on x as the person saw it at the press.
    var icon: ClosedRange<CGFloat>?
    /// The row the press landed on.
    var row: CGRect
    /// The listing at the press, before the drag moved anything.
    var listing: [MenuBarItem] = []
    /// The apps the live assertion concealed at the press — their nodes
    /// are ghosts, in both reads.
    var concealed: Set<String> = []
    /// The press landed on another display's bar.
    var otherDisplay = false
    /// "Reveal while dragging" brought the hidden run in for this drag.
    var revealedHidden = false
}

/// ⌘-drag across the icon hides or shows (Bartender, Ice and Hidden Bar
/// parity) under the macOS 27 concealer. The click bridge's tap — or,
/// with it down, the reveal's own monitor — reports the person's ⌘-press
/// and its release; nothing is posted and the pointer never moves. At
/// the press the utility notes the item under it and freezes the icon
/// where it stands. At the release it reads which side of that icon the
/// drop landed on, waits for the agent to persist the move, confirms it
/// with a fresh listing, and writes exactly one section through the same
/// path the card's picker takes. A listing that changes on its own —
/// a reflow, the recording indicator, a relaunch — never writes.
extension MenuBarUtility {
    /// Whether a drag holds the icon and the hover reveal right now.
    var dragFrozen: Bool { dragFrozenMaxX != nil }

    /// Every display's menu bar row, the one the icon stands on first.
    func dragBarRows() -> [CGRect] {
        if let dragRows { return dragRows() }
        let primary = mirrorPlacement()?.row ?? Self.primaryRow()
        return [primary] + MenuBarItemLister.menuBarRows().filter { $0 != primary }
    }

    /// The icon's span on x as the person sees it: the mirror while it
    /// stands, else the ear's ‹ that stands in for it.
    func currentIconSpan() -> ClosedRange<CGFloat>? {
        if let dragIconSpan { return dragIconSpan() }
        if iconMirrored, let frame = standingMirrorFrame { return frame.minX...frame.maxX }
        if let handle = ScreenBarGeometry.menuHandleScreenRect { return handle.minX...handle.maxX }
        return nil
    }

    /// A point from AppKit's screen space (the reveal's monitor) in
    /// Quartz's, where the bridge and the listing measure.
    static func quartzPoint(_ point: NSPoint) -> CGPoint {
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: point.x, y: top - point.y)
    }

    // MARK: The press

    /// A ⌘-press somewhere on the Mac. On the icon's bar it may be the
    /// start of a drag: the item under it is noted and the icon, the
    /// hover reveal and the rehide clock freeze until the drop is
    /// settled. Only while the concealer runs and `dragToHide` is on.
    func commandPressed(at point: CGPoint) {
        guard concealer != nil, settings().curation.dragToHide else { return }
        let rows = dragBarRows()
        guard let main = rows.first,
              let row = rows.first(where: { $0.insetBy(dx: 0, dy: -MenuBarDragLearn.slack).contains(point) })
        else { return }
        guard row == main else {
            // The mirror stands only on the main bar: the drop gets its
            // note there, and nothing is written.
            dragInFlight = MenuBarDragInFlight(start: point, pressedAt: Date(), row: row, otherDisplay: true)
            return
        }
        // A relaunch's first seconds: the listing is still the last
        // run's, and the icon has not settled.
        guard Date().timeIntervalSince(concealerStartedAt) >= Self.adoptionGrace else {
            MenuBarAssessmentBackend.log.debug("drag: ignored — the engine is still starting")
            return
        }
        guard let icon = currentIconSpan() else {
            MenuBarAssessmentBackend.log.debug("drag: ignored — no icon stands to drag across")
            return
        }
        let listing = dragListing()
        let concealed = concealer?.concealedApps ?? []
        let grabbed = MenuBarDragLearn.grabbed(at: point, items: listing, concealed: concealed,
                                               ourPID: ProcessInfo.processInfo.processIdentifier, row: row)
        var drag = MenuBarDragInFlight(start: point, pressedAt: Date(), grabbed: grabbed, icon: icon,
                                       row: row, listing: listing, concealed: concealed)
        guard grabbed != nil else {
            dragInFlight = drag
            return
        }
        freezeForDrag(maxX: standingMirrorFrame?.maxX ?? icon.upperBound)
        if settings().curation.revealWhileDragging, hider.revealed.isEmpty {
            // Ice's "show hidden items while ⌘-dragging": the run comes
            // in beside the icon, and the ‹ turns to a divider.
            drag.revealedHidden = true
            hider.reveal([.hidden])
        }
        dragInFlight = drag
        if drag.revealedHidden { faceChanged() }
        watchForLostRelease(pressedAt: drag.pressedAt)
    }

    /// A release the tap never delivered (it was disabled mid-drag, say)
    /// must not leave the icon and the hover reveal frozen: past
    /// `staleDrag` the press is forgotten and everything thaws.
    private func watchForLostRelease(pressedAt: Date) {
        dragUnfreezeTask?.cancel()
        dragUnfreezeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MenuBarDragLearn.staleDrag * 1e9))
            guard !Task.isCancelled, let self, let drag = self.dragInFlight,
                  drag.pressedAt == pressedAt else { return }
            MenuBarAssessmentBackend.log.notice("drag: no release heard — let go")
            self.dragInFlight = nil
            self.endDrag(drag, after: 0)
        }
    }

    // MARK: The release

    /// The release that ends a ⌘-press. A drop across the icon, or on
    /// either side of it, asks for a section; the agent's move is
    /// confirmed after it settles, and then one write lands. Every drop
    /// that asked for something and got nothing says why under the icon.
    func commandReleased(at point: CGPoint, option: Bool) {
        guard let drag = dragInFlight else { return }
        dragInFlight = nil
        guard Date().timeIntervalSince(drag.pressedAt) < MenuBarDragLearn.staleDrag else {
            endDrag(drag, after: 0)
            return
        }
        let travel = hypot(point.x - drag.start.x, point.y - drag.start.y)
        if drag.otherDisplay {
            if travel >= MenuBarDragLearn.minTravel {
                MenuBarAssessmentBackend.log.notice("drag: dropped on another display's bar — nothing written")
                showDropNote(.otherDisplay)
            }
            return
        }
        guard let grabbed = drag.grabbed, let icon = drag.icon else { return }
        let intent = MenuBarDragLearn.intent(from: drag.start, to: point, icon: icon,
                                             row: drag.row, option: option)
        let kind = dragKind(of: grabbed)
        let current = kind == .system ? MenuBarItemSection.shown : effectiveSection(for: grabbed)
        let appItems = grabbed.bundleID.map { id in
            drag.listing.filter { $0.bundleID == id && !$0.isNativeOverflowControl }.count
        } ?? 1
        let outcome = MenuBarDragLearn.outcome(intent: intent, current: current, grabbed: kind,
                                               appName: grabbed.ownerName, appItemCount: appItems)
        let key = Self.dragKey(grabbed)
        guard let section = outcome.section else {
            if let note = outcome.note {
                MenuBarAssessmentBackend.log.notice("drag: \(key, privacy: .public) is macOS's own — ignored")
                showDropNote(note)
            }
            endDrag(drag, after: 0)
            return
        }
        let crossed = MenuBarDragLearn.crossed(from: drag.start, to: point, icon: icon)
        let settle = dragSettle
        let releasedAt = Date()
        dragConfirmTask = Task { @MainActor [weak self] in
            if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1e9)) }
            guard let self else { return }
            let fresh = await self.dragFreshListing(MenuBarDragLearn.confirmTimeout)
            self.settleDrop(drag, grabbed: grabbed, section: section, note: outcome.note,
                            fresh: fresh, crossed: crossed, releasedAt: releasedAt)
        }
    }

    /// The confirming read is in: write the one section if the agent
    /// really moved the item, say why not otherwise.
    private func settleDrop(_ drag: MenuBarDragInFlight, grabbed: MenuBarItem, section: MenuBarItemSection,
                            note: MenuBarDropNote?, fresh: [MenuBarItem]?, crossed: Bool, releasedAt: Date) {
        var verdict = MenuBarDragLearn.verdict(grabbed: grabbed, before: drag.listing, after: fresh,
                                               crossed: crossed, row: drag.row, concealed: drag.concealed)
        // Without Accessibility's answer, the granted layout table — read
        // after the drop — can still say where the agent put the app.
        if fresh == nil, !verdict.confirmed,
           layoutTableConfirms(grabbed, section: section, releasedAt: releasedAt) {
            verdict.confirmed = true
        }
        // A whole-bar shift (the recording indicator) holds the icon as
        // long as the shift lasts, so it never re-seats against it.
        let hold = verdict.anchorDrifted
            ? max(dragUnfreezeDelay, MenuBarItemHider.shrinkHold) : dragUnfreezeDelay
        let key = Self.dragKey(grabbed)
        let side = MenuBarDragLearn.sideWords(section)
        guard verdict.confirmed, concealer != nil else {
            let why = fresh == nil ? "Accessibility did not answer and it never crossed the icon"
                : (verdict.anchorDrifted ? "the whole bar shifted and it never crossed the icon"
                   : "macOS did not move it")
            MenuBarAssessmentBackend.log.notice("drag: \(key, privacy: .public) dropped \(side, privacy: .public)? — \(why, privacy: .public); nothing written")
            showDropNote(.notMoved)
            endDrag(drag, after: hold)
            return
        }
        guard let landed = applySection(section, to: grabbed) else {
            endDrag(drag, after: hold)
            return
        }
        MenuBarAssessmentBackend.log.notice("drag: \(key, privacy: .public) dropped \(side, privacy: .public) (\(landed, privacy: .public))")
        if let note { showDropNote(note) }
        endDrag(drag, after: hold)
    }

    /// What the press took hold of, for the write it can get.
    func dragKind(of item: MenuBarItem) -> MenuBarDragLearn.Grabbed {
        if MenuBarItemLister.isProtected(item) {
            return concealableSystemKey(item) != nil ? .systemConcealable : .system
        }
        guard let id = item.bundleID else { return .helper }
        return canConceal(id) ? .app : .appleExtra
    }

    /// The name a drop's log line gives the item.
    nonisolated static func dragKey(_ item: MenuBarItem) -> String {
        item.bundleID ?? item.identifier ?? item.id
    }

    // MARK: Freeze and thaw

    /// Hold the icon's right edge, the hover reveal and the rehide clock
    /// for the drag.
    func freezeForDrag(maxX: CGFloat) {
        dragUnfreezeTask?.cancel()
        dragUnfreezeTask = nil
        if dragFrozenMaxX == nil { dragFrozenMaxX = maxX }
    }

    /// The drag is over: fold what "reveal while dragging" brought in,
    /// and thaw after `delay`.
    func endDrag(_ drag: MenuBarDragInFlight, after delay: TimeInterval) {
        if drag.revealedHidden {
            hider.hide()
            faceChanged()
        }
        thawDrag(after: delay)
    }

    /// Let the icon re-seat and the hover reveal answer again — not while
    /// another drag is already in flight; its own release thaws.
    func thawDrag(after delay: TimeInterval) {
        dragUnfreezeTask?.cancel()
        guard delay > 0 else {
            dragUnfreezeTask = nil
            unfreezeDrag()
            return
        }
        dragUnfreezeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled else { return }
            self?.unfreezeDrag()
        }
    }

    private func unfreezeDrag() {
        guard dragInFlight == nil, dragFrozenMaxX != nil else { return }
        dragFrozenMaxX = nil
        updateIconMirror()
    }

    // MARK: The note under the icon

    /// Say `note` under the icon for `MenuBarDragLearn.noteSeconds` — the
    /// Item Bar's glass, which already hangs there; no new window.
    func showDropNote(_ note: MenuBarDropNote) {
        dropNote = note
        if let presentDropNote {
            presentDropNote(note.text)
        } else {
            bar.showNote(note.text, for: MenuBarDragLearn.noteSeconds)
        }
        dropNoteTask?.cancel()
        dropNoteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MenuBarDragLearn.noteSeconds * 1e9))
            guard !Task.isCancelled else { return }
            self?.dropNote = nil
        }
    }

    // MARK: A tile dragged out of the Item Bar

    /// An Item Bar tile dropped at `screenPoint` (AppKit): on the bar
    /// right of the icon it shows its app, left of it tucks it away. A
    /// drop anywhere else changes nothing. The drag is the Item Bar's own
    /// session — nothing is posted, the pointer is the person's.
    func tileDropped(_ item: MenuBarItem, at screenPoint: NSPoint) {
        guard let icon = currentIconSpan(), let row = dragBarRows().first else { return }
        let point = Self.quartzPoint(screenPoint)
        guard row.insetBy(dx: 0, dy: -MenuBarDragLearn.slack).contains(point) else { return }
        let intent: MenuBarDragIntent
        if point.x > icon.upperBound + MenuBarDragLearn.slack {
            intent = .show
        } else if point.x < icon.lowerBound - MenuBarDragLearn.slack {
            intent = .hide(always: false)
        } else {
            return
        }
        guard let section = MenuBarDragLearn.section(for: intent, current: effectiveSection(for: item)),
              let landed = applySection(section, to: item) else { return }
        MenuBarAssessmentBackend.log.notice("drag: \(Self.dragKey(item), privacy: .public) tile dropped \(MenuBarDragLearn.sideWords(section), privacy: .public) (\(landed, privacy: .public))")
    }
}
