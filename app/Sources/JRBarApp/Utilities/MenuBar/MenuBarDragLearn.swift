import AppKit
import JRBarCore

/// What a ⌘-drag on the menu bar asked for, read off where it landed
/// against the icon the person saw when they pressed.
enum MenuBarDragIntent: Equatable, Sendable {
    /// Dropped left of the icon: tuck the app away — into Always
    /// Hidden when ⌥ was held at the drop.
    case hide(always: Bool)
    /// Dropped right of the icon: keep the app on the bar.
    case show
    /// A ⌘-click, a drop on the icon itself, or a drop off the bar.
    case none
}

/// Why a drop that asked for a hide or a show did something other
/// than the plain per-app pick — or nothing at all. Each one is said in
/// one line under the icon, so a drop is never silently ignored.
enum MenuBarDropNote: Equatable, Sendable {
    /// Wi-Fi, the clock, Control Center: macOS keeps its own items.
    case systemItem
    /// One of Apple's own extras while `concealAppleExtras` is off: it
    /// took a cover where it sits, which is a hole, not a hide.
    case appleExtraCovered
    /// A drag on another display's bar: the icon lives on the main one.
    case otherDisplay
    /// An app with several items hides and shows as one.
    case wholeApp(name: String, hidden: Bool)
    /// macOS did not take the drop, so there was nothing to follow.
    case notMoved

    /// The note's words.
    var text: String {
        switch self {
        case .systemItem:
            return "macOS keeps Wi-Fi, the clock and Control Center — hide them in System Settings › Menu Bar"
        case .appleExtraCovered:
            return "Covered: macOS won't hide Apple's own extras yet"
        case .otherDisplay:
            return "Drag on the main display's bar — the JR-Bar icon lives there"
        case .wholeApp(let name, let hidden):
            return hidden ? "Hid all of \(name)'s items" : "Showed all of \(name)'s items"
        case .notMoved:
            return "macOS didn't move it, so nothing changed"
        }
    }
}

/// The ⌘-drag rules, pure so every one is pinned by a test. The person
/// ⌘-drags an item across the JR-Bar icon and its app lands in that
/// section: one observed press and release, one write. Nothing here
/// reads a listing on its own — a reflow, a recording indicator's shift
/// or a relaunch can never teach a section, which is how the drag-learn
/// deleted in `424c08ad` hid apps nobody touched.
enum MenuBarDragLearn {
    /// Below this the press was a ⌘-click, not a drag.
    nonisolated static let minTravel: CGFloat = 8
    /// A drop this close to the icon's edge is on the icon.
    nonisolated static let slack: CGFloat = 3
    /// The agent persists a drop 0.4–0.9 s after the release (measured
    /// 2026-09-24); the confirming read waits this long first.
    nonisolated static let settle: TimeInterval = 0.6
    /// The confirming read's budget.
    nonisolated static let confirmTimeout: TimeInterval = 1.5
    /// A move smaller than this is no move.
    nonisolated static let moveThreshold: CGFloat = 4
    /// The anchor moving further than this means the whole bar shifted.
    nonisolated static let anchorDrift: CGFloat = 4
    /// The icon and the hover reveal stay frozen this long after a write.
    nonisolated static let unfreezeDelay: TimeInterval = 1.2
    /// How long a drop's note stands under the icon.
    nonisolated static let noteSeconds: TimeInterval = 4
    /// A press whose release never came this long after is forgotten,
    /// and the icon and the hover reveal it froze let go — a tap that
    /// missed the release must not hold them for good.
    nonisolated static let staleDrag: TimeInterval = 20

    /// The drop's side against the icon's span frozen at the press
    /// (Quartz x), on the icon's row. Left hides, right shows; on the
    /// icon, off the row or a ⌘-click is nothing.
    nonisolated static func intent(from start: CGPoint, to drop: CGPoint, icon: ClosedRange<CGFloat>,
                                   row: CGRect, option: Bool) -> MenuBarDragIntent {
        guard hypot(drop.x - start.x, drop.y - start.y) >= minTravel else { return .none }
        guard row.insetBy(dx: 0, dy: -slack).contains(drop) else { return .none }
        if drop.x < icon.lowerBound - slack { return .hide(always: option) }
        if drop.x > icon.upperBound + slack { return .show }
        return .none
    }

    /// Whether the press and the drop sit on opposite sides of the icon
    /// — the one drop the bar's own order cannot argue with.
    nonisolated static func crossed(from start: CGPoint, to drop: CGPoint,
                                    icon: ClosedRange<CGFloat>) -> Bool {
        (start.x > icon.upperBound && drop.x < icon.lowerBound)
            || (start.x < icon.lowerBound && drop.x > icon.upperBound)
    }

    /// The drawn item under the press on `row`: never ours, never the
    /// «, never an app the live assertion conceals — its Accessibility
    /// node is a ghost at a stale frame, drawing nothing, and must not
    /// speak for its app. A press anywhere down the row's depth counts,
    /// as it does for macOS; the nearest centre wins a tie.
    nonisolated static func grabbed(at point: CGPoint, items: [MenuBarItem], concealed: Set<String>,
                                    ourPID: pid_t, row: CGRect) -> MenuBarItem? {
        let under = items.filter { item in
            item.bounds.width > 0
                && point.x >= item.bounds.minX - 1 && point.x <= item.bounds.maxX + 1
                && item.bounds.minY < row.maxY && item.bounds.maxY > row.minY
                && item.ownerPID != ourPID
                && MenuBarUtility.isForeignOwner(item.ownerName)
                && !item.isNativeOverflowControl
                && !MenuBarUtility.isOwnFamily(item.bundleID)
                && !(item.bundleID.map(concealed.contains) ?? false)
        }
        return under.min { abs($0.bounds.midX - point.x) < abs($1.bounds.midX - point.x) }
    }

    /// The section a drop writes, or nil when there is nothing to
    /// change: a hide keeps an existing Always (⌥ asks for Always
    /// outright), a show clears both, and a drop that lands the app
    /// where it already is writes nothing — a reorder among the shown
    /// run is only a reorder.
    nonisolated static func section(for intent: MenuBarDragIntent,
                                    current: MenuBarItemSection) -> MenuBarItemSection? {
        switch intent {
        case .none:
            return nil
        case .show:
            return current == .shown ? nil : .shown
        case .hide(let always):
            if always { return current == .alwaysHidden ? nil : .alwaysHidden }
            return current == .shown ? .hidden : nil
        }
    }

    /// What kind of item the press took hold of — the write it can get.
    enum Grabbed: Equatable, Sendable {
        /// An app the agent conceals whole.
        case app
        /// One of Apple's own extras while `concealAppleExtras` is off —
        /// a cover where it sits.
        case appleExtra
        /// A bare helper with no bundle identifier — a cover too.
        case helper
        /// The clock or Control Center while `concealSystemItems` is on.
        case systemConcealable
        /// Any other of macOS's own items.
        case system
    }

    /// A drop's result before the confirming read: the section to write
    /// once the agent has moved the item, and the note it earns.
    struct Outcome: Equatable, Sendable {
        var section: MenuBarItemSection?
        var note: MenuBarDropNote?
    }

    /// The table every drop goes through. macOS's own items get the
    /// note and never a write; Apple's extras get their cover and say
    /// so; an app with several items says the whole app moved.
    nonisolated static func outcome(intent: MenuBarDragIntent, current: MenuBarItemSection,
                                    grabbed: Grabbed, appName: String, appItemCount: Int) -> Outcome {
        guard intent != .none else { return Outcome() }
        if grabbed == .system {
            // Nothing to write either way; only a hide was refused.
            if case .hide = intent { return Outcome(note: .systemItem) }
            return Outcome()
        }
        guard let section = section(for: intent, current: current) else { return Outcome() }
        switch grabbed {
        case .appleExtra:
            return Outcome(section: section, note: section == .shown ? nil : .appleExtraCovered)
        case .app where appItemCount > 1:
            return Outcome(section: section, note: .wholeApp(name: appName, hidden: section != .shown))
        default:
            return Outcome(section: section)
        }
    }

    /// The confirming read's answer.
    struct Verdict: Equatable, Sendable {
        /// The agent really moved the item — write.
        var confirmed: Bool
        /// The anchor itself moved: the whole bar shifted (macOS's
        /// recording indicator), so the icon stays frozen a while longer.
        var anchorDrifted: Bool
    }

    /// Whether the agent moved the grabbed item, measured against a
    /// right-anchored system item (the clock, else Control Center, else
    /// the rightmost of macOS's own) read in the same pass — never by
    /// its absolute x: every ScreenCaptureKit capture lights the
    /// recording indicator and shifts every item about 56 pt, and an
    /// absolute delta would confirm a drop that never happened. A move
    /// counts only with a reorder among the items both reads list, so a
    /// shift that leaves the anchor where it was is not one either.
    /// When the anchor itself moved, or the read failed or lost the
    /// item, only a drop that crossed the frozen icon span is believed.
    nonisolated static func verdict(grabbed: MenuBarItem, before: [MenuBarItem], after: [MenuBarItem]?,
                                    crossed: Bool, row: CGRect, concealed: Set<String>) -> Verdict {
        guard let after, let moved = find(grabbed, in: after), moved.bounds.intersects(row) else {
            return Verdict(confirmed: crossed, anchorDrifted: false)
        }
        let reordered = reordered(grabbed, before: before, after: after, row: row, concealed: concealed)
        guard let anchorBefore = anchor(in: before, row: row),
              let anchorAfter = anchor(in: after, row: row, matching: anchorBefore) else {
            return Verdict(confirmed: reordered, anchorDrifted: false)
        }
        if abs(anchorAfter.bounds.minX - anchorBefore.bounds.minX) > anchorDrift {
            return Verdict(confirmed: crossed, anchorDrifted: true)
        }
        let relativeBefore = grabbed.bounds.minX - anchorBefore.bounds.minX
        let relativeAfter = moved.bounds.minX - anchorAfter.bounds.minX
        let movedEnough = abs(relativeAfter - relativeBefore) >= moveThreshold
        return Verdict(confirmed: movedEnough && reordered, anchorDrifted: false)
    }

    /// The same item in another read: its id, else its owner and
    /// identifier — an app with two items can swap ordinals on a move.
    nonisolated static func find(_ item: MenuBarItem, in listing: [MenuBarItem]) -> MenuBarItem? {
        if let same = listing.first(where: { $0.id == item.id && $0.ownerPID == item.ownerPID }) {
            return same
        }
        guard let identifier = item.identifier else { return nil }
        return listing.first { $0.ownerPID == item.ownerPID && $0.identifier == identifier }
    }

    /// The right-anchored system item the move is measured against.
    nonisolated static func anchor(in listing: [MenuBarItem], row: CGRect,
                                   matching previous: MenuBarItem? = nil) -> MenuBarItem? {
        let system = listing.filter {
            MenuBarItemLister.isProtected($0) && MenuBarUtility.isForeignOwner($0.ownerName)
                && $0.bounds.intersects(row) && !$0.isNativeOverflowControl
        }
        if let previous {
            return system.first { $0.identifier == previous.identifier && $0.id == previous.id }
        }
        for identifier in ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"] {
            if let hit = system.first(where: { $0.identifier == identifier }) { return hit }
        }
        return system.max { $0.bounds.maxX < $1.bounds.maxX }
    }

    /// Whether the grabbed item changed places among the items drawn on
    /// `row` in both reads — who stands left of it. Ghosts (concealed
    /// apps), the « and anything only one read lists sit out, so a
    /// uniform shift or an indicator appearing is never a reorder.
    nonisolated static func reordered(_ item: MenuBarItem, before: [MenuBarItem], after: [MenuBarItem],
                                      row: CGRect, concealed: Set<String>) -> Bool {
        func drawn(_ listing: [MenuBarItem]) -> [MenuBarItem] {
            listing.filter {
                $0.bounds.intersects(row) && $0.bounds.width > 0 && !$0.isNativeOverflowControl
                    && !($0.bundleID.map(concealed.contains) ?? false)
            }
        }
        let beforeDrawn = drawn(before)
        let afterDrawn = drawn(after)
        guard let itemBefore = beforeDrawn.first(where: { $0.id == item.id }),
              let itemAfter = find(item, in: afterDrawn) else { return false }
        let common = Set(beforeDrawn.map(\.id)).intersection(afterDrawn.map(\.id))
            .subtracting([item.id, itemAfter.id])
        let leftBefore = Set(beforeDrawn.filter { common.contains($0.id)
            && $0.bounds.midX < itemBefore.bounds.midX }.map(\.id))
        let leftAfter = Set(afterDrawn.filter { common.contains($0.id)
            && $0.bounds.midX < itemAfter.bounds.midX }.map(\.id))
        return leftBefore != leftAfter
    }

    /// The words the log and the note use for a section's side.
    nonisolated static func sideWords(_ section: MenuBarItemSection) -> String {
        switch section {
        case .shown: return "right of the icon → shown"
        case .hidden: return "left of the icon → hidden"
        case .alwaysHidden: return "left of the icon with ⌥ → always hidden"
        }
    }
}
