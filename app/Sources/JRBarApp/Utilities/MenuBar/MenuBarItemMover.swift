import AppKit
import JRBarCore

/// The bar's physical layout, in Quartz x: the extras region is
/// bounded on the left by the notch's right edge (`regionMin`) and
/// divided by the utility's two control items —
///
///     [always-hidden items][always-hidden control][hidden items][chevron][shown items][system]
///
/// so an item's section is where its center sits. The boundaries move
/// as the system reflows the bar — the zones are re-measured off the
/// controls' live frames every reconcile, never remembered.
struct MenuBarZones: Equatable, Sendable {
    /// The extras region's left edge — the notch's right edge where
    /// the hardware carves one, else the leftmost known item.
    var regionMin: CGFloat
    /// The always-hidden control's frame (its x/width; the row's y).
    var alwaysHiddenControl: CGRect
    /// The hidden control's — the chevron's — frame.
    var hiddenControl: CGRect
    /// The display's right edge.
    var regionMax: CGFloat

    /// The section a center-x sits in. Anything between the controls,
    /// or overlapping the always-hidden control itself, is the hidden
    /// run; left of the always-hidden control is the deeper section.
    nonisolated func section(atCenterX x: CGFloat) -> MenuBarItemSection {
        if x < alwaysHiddenControl.minX { return .alwaysHidden }
        if x < hiddenControl.minX { return .hidden }
        return .shown
    }

    /// The x a ⌘-drag should drop at to land an item in `section`.
    /// Drops go to the zone's near edge — just past the boundary — and
    /// the system's reflow finds the nearest slot, pushing whatever
    /// sits there over. A zone too narrow to have a midpoint still
    /// takes drops at its edge: the pushed-aside controls are what
    /// grow it.
    nonisolated func dropX(for section: MenuBarItemSection) -> CGFloat {
        switch section {
        case .alwaysHidden:
            return regionMin + 14
        case .hidden:
            let gap = hiddenControl.minX - alwaysHiddenControl.maxX
            return gap > 36 ? alwaysHiddenControl.maxX + gap / 2 : hiddenControl.minX - 14
        case .shown:
            return min(hiddenControl.maxX + 16, regionMax - 16)
        }
    }
}

/// A single ⌘-drag: press the item's center, drop at `to`.
struct MenuBarMoveStep: Equatable, Sendable {
    let itemID: String
    let from: CGPoint
    let to: CGPoint
}

/// Moves foreign menu bar items between sections the only way macOS
/// allows: synthetic ⌘-drags, the same gesture a person uses to
/// rearrange the bar. Confirmed working on macOS 26 (notched MBP):
/// a command-flagged press/drag/release at the item's Quartz-space
/// center reorders the item; the system clamps the drop to the
/// nearest open slot and persists the new preferred position.
///
/// ⚠️ **A posted drag moves the person's real cursor.** `perform` and
/// `postCommandDrag` may only ever be invoked from
/// `MenuBarArrangeCoordinator`'s `arrange(to:)` run — the explicit,
/// user-initiated arrange gesture that shows the "hands off" banner,
/// watches for foreign input, and warps the cursor home after every
/// drag. Never from a timer, a reconcile pass, a settings write, a
/// trigger, or any other background path — that is exactly how a
/// background timer once drove the user's cursor, and it must never
/// happen again. The hiding mechanism itself (`MenuBarItemHider`)
/// stays mouse-free; this file exists for the arrange phase only.
///
/// Every event the mover posts carries `eventMarker` in its
/// `eventSourceUserData`, so the coordinator's abort watcher can tell
/// one of our presses from the person's hand.
///
/// The gesture needs Accessibility for the *event posting*; the item
/// positions come from the AX listing.
enum MenuBarItemMover {
    /// Pause between events inside one drag — the system needs the
    /// press to land before the drags start moving the item.
    nonisolated static let dragStepDelay: useconds_t = 40_000
    /// Pause between two items' drags — the bar reflows after a drop.
    nonisolated static let betweenDragsDelay: useconds_t = 180_000
    /// The `eventSourceUserData` stamp on every event this file posts —
    /// `MenuBarArrangeEventWatcher` reads it to let our own synthetic
    /// drags pass while any real input aborts the run. An arbitrary
    /// constant far outside anything a human input source writes.
    nonisolated static let eventMarker: Int64 = 0x4A52_4241_5252 // "JRBARR"

    // MARK: Position seeding (pure)

    /// The drags that would bring the layout in line with the section
    /// map. Only *explicitly assigned* items move — an unassigned item
    /// stays where the system or the person put it, and protected
    /// items are never touched. Items parked off the row can't be
    /// pressed at all (their position is a stash, not a slot), so they
    /// are skipped; the Item Bar still reaches them through `AXPress`.
    /// - Parameters:
    ///   - items: the live listing, any order.
    ///   - zones: the current control positions.
    ///   - sections: the persisted section map.
    ///   - row: the menu bar row — parked items fail its intersection.
    nonisolated static func moveSteps(items: [MenuBarItem], zones: MenuBarZones,
                                      sections: [String: MenuBarItemSection],
                                      row: CGRect) -> [MenuBarMoveStep] {
        var steps: [MenuBarMoveStep] = []
        for item in items.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            guard !MenuBarItemLister.isProtected(item),
                  let target = sections[item.id],
                  item.bounds.intersects(row) else { continue }
            let center = CGPoint(x: item.bounds.midX, y: row.midY)
            let current = zones.section(atCenterX: item.bounds.midX)
            guard current != target else { continue }
            steps.append(MenuBarMoveStep(
                itemID: item.id, from: center,
                to: CGPoint(x: zones.dropX(for: target), y: row.midY)))
        }
        // Deepest zone first: an always-hidden drop at the region's
        // left edge can never undo a hidden drop, while a later
        // left-side drop could push a just-placed item right again.
        return steps.sorted { a, b in
            rank(a.to.x, zones) < rank(b.to.x, zones)
        }
    }

    /// The zone a drop-x lands in, ranked deepest-first for sorting.
    private nonisolated static func rank(_ x: CGFloat, _ zones: MenuBarZones) -> Int {
        switch zones.section(atCenterX: x) {
        case .alwaysHidden: return 0
        case .hidden: return 1
        case .shown: return 2
        }
    }

    // MARK: Posting

    /// One ⌘-drag from `start` to `end`: command-flagged press, a
    /// short interpolated drag, release — the recipe verified live on
    /// macOS 26 to reorder a foreign item. Runs synchronously; callers
    /// keep it off the main actor. **Arrange-coordinator only** — see
    /// the file's doc comment; each event is stamped with
    /// `eventMarker` so the abort watcher can tell it from a real
    /// hand.
    nonisolated static func postCommandDrag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        func event(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
            let e = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)
            e?.flags = .maskCommand
            e?.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            return e
        }
        event(.leftMouseDown, at: start)?.post(tap: .cghidEventTap)
        usleep(dragStepDelay)
        let steps = 6
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t)
            event(.leftMouseDragged, at: p)?.post(tap: .cghidEventTap)
            usleep(dragStepDelay)
        }
        event(.leftMouseUp, at: end)?.post(tap: .cghidEventTap)
    }

    /// A batch of drags, paced so the bar can reflow between them.
    /// Blocking — run off the main actor. Retained as the low-level
    /// batch path; `MenuBarArrangeCoordinator` drives single steps
    /// itself so it can re-plan, watch for aborts, and restore the
    /// cursor between drags — prefer that over calling this.
    /// **Arrange-coordinator only**, like `postCommandDrag`.
    nonisolated static func perform(_ steps: [MenuBarMoveStep]) {
        for (index, step) in steps.enumerated() {
            postCommandDrag(from: step.from, to: step.to)
            if index < steps.count - 1 { usleep(betweenDragsDelay) }
        }
    }
}
