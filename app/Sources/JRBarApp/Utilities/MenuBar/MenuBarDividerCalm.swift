import CoreGraphics
import Foundation
import JRBarCore

/// Holds the bar still while a ⌘-drag moves an item across the divider,
/// and for a beat after the drop. macOS reflows the whole row under the
/// person's hand while a status item is dragged; anything JR-Bar writes
/// in that time (a longer or shorter spacer, a reveal, a rehide) reflows
/// it a second time and the bar flickers, disappears and settles in the
/// wrong place. While the gate holds, the hider does not reconcile, the
/// hover reveal and the rehide clock stand down, and nothing is recorded.
/// After the release exactly one reconcile follows. Pure over an injected
/// clock.
struct MenuBarPointerGate: Equatable, Sendable {
    /// How long after the release the bar still holds, so macOS finishes
    /// placing the item before JR-Bar reads or writes anything.
    nonisolated static let settle: TimeInterval = 0.9
    /// A press whose release was never heard is forgotten after this.
    nonisolated static let stale: TimeInterval = 20
    /// The first moments of a press, when the live button state may not
    /// yet say it is down.
    nonisolated static let pressGrace: TimeInterval = 0.2

    private(set) var pressedAt: TimeInterval?
    private(set) var releasedAt: TimeInterval?

    nonisolated init() {}

    /// A ⌘-press on the bar: a drag may begin.
    nonisolated mutating func press(now: TimeInterval) {
        pressedAt = now
        releasedAt = nil
    }

    /// The release that ends it.
    nonisolated mutating func release(now: TimeInterval) {
        guard pressedAt != nil else { return }
        pressedAt = nil
        releasedAt = now
    }

    /// Whether the bar should hold still now. `buttonDown` is the live
    /// state of the left button: it ends a press whose release was lost.
    nonisolated mutating func holding(buttonDown: Bool, now: TimeInterval) -> Bool {
        if let pressed = pressedAt {
            let lost = now - pressed > Self.stale
                || (!buttonDown && now - pressed > Self.pressGrace)
            if !lost { return true }
            release(now: now)
        }
        guard let releasedAt else { return false }
        if now - releasedAt < Self.settle { return true }
        self.releasedAt = nil
        return false
    }

    /// Whether a press is being held right now (no settle beat).
    nonisolated var pressing: Bool { pressedAt != nil }
}

/// One item that changed sides of the divider between two plans.
struct MenuBarPositionChange: Equatable, Sendable {
    var id: String
    var name: String
    var from: MenuBarItemSection
    var to: MenuBarItemSection

    /// Plain words for the log and the card.
    var sentence: String {
        switch (from, to) {
        case (_, .hidden), (_, .alwaysHidden):
            return "\(name) moved left of the icon: hidden"
        case (_, .shown):
            return "\(name) moved right of the icon: shown"
        }
    }
}

/// What a ⌘-drag did, read off two plans. The drag handler under the
/// divider only observes: macOS moves the item, JR-Bar reads where it
/// landed and says so. Pure.
enum MenuBarPositionDiff {
    nonisolated static func changes(before: MenuBarHidePlan, after: MenuBarHidePlan) -> [MenuBarPositionChange] {
        func sections(_ plan: MenuBarHidePlan) -> [String: (MenuBarItemSection, String)] {
            var out: [String: (MenuBarItemSection, String)] = [:]
            for item in plan.shown { out[item.id] = (.shown, item.ownerName) }
            for item in plan.hidden { out[item.id] = (.hidden, item.ownerName) }
            for item in plan.alwaysHidden { out[item.id] = (.alwaysHidden, item.ownerName) }
            return out
        }
        let was = sections(before), now = sections(after)
        var out: [MenuBarPositionChange] = []
        for (id, entry) in now {
            guard let old = was[id], old.0 != entry.0 else { continue }
            out.append(MenuBarPositionChange(id: id, name: entry.1, from: old.0, to: entry.0))
        }
        return out.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
}

/// What JR-Bar thinks the bar looks like, for the card: the lines under
/// "What JR-Bar sees". Plain facts, none of them guesses presented as
/// facts: where the icon is, how long the spacer is and why, how many
/// items sit on each side, and the last thing a drop changed.
struct MenuBarDividerReadout: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        /// The divider is up.
        var standing = false
        /// The icon's frame while it is on the row; nil when it is not.
        var iconFrame: CGRect?
        /// The spacer's length as last written, nil before the first.
        var spacer: CGFloat?
        var fitEdge: CGFloat?
        var fitEdgeLearned = false
        /// How far a capped spacer falls short of pushing everything off.
        var spacerShortBy: CGFloat = 0
        /// What the last wake, display or Space change left (see
        /// `MenuBarWakeRecovery`).
        var wake: MenuBarWakeRecovery.Verdict = .idle
        /// The hidden run is drawn right now (a reveal).
        var revealed = false
        /// The bar is held still for a drag, or just after one.
        var holding = false
        var hidden = 0
        var shown = 0
        /// Hidden items macOS holds in its own « overflow.
        var parked = 0
        var room: MenuBarDividerRoom = .unknown
        var lastChange: String?
    }

    var lines: [String]

    nonisolated static func make(_ i: Input) -> MenuBarDividerReadout {
        var lines: [String] = []
        lines.append(i.standing
            ? "Engine: the icon is the divider. No assertion is taken."
            : "Engine: starting.")
        if let frame = i.iconFrame {
            lines.append("Icon: on the bar at \(Int(frame.minX.rounded()))–\(Int(frame.maxX.rounded())) pt.")
        } else if i.standing {
            lines.append(i.room == .noRoom
                ? "Icon: not on the bar. macOS parked it for want of room."
                : "Icon: not on the bar right now.")
        }
        if i.standing {
            if i.holding {
                lines.append("Spacer: holding still while you drag.")
            } else if i.revealed {
                lines.append("Spacer: folded, the hidden items are drawn.")
            } else if let spacer = i.spacer {
                let edge = i.fitEdge.map { ", fit edge \(Int($0.rounded())) pt\(i.fitEdgeLearned ? " (learned)" : " (guessed)")" } ?? ""
                lines.append("Spacer: \(Int(spacer.rounded())) pt\(edge).")
                if i.spacerShortBy >= MenuBarItemHider.spacerShortSlack {
                    lines.append("The spacer is held \(Int(i.spacerShortBy.rounded())) pt short of the fit edge, so the items it cannot push off the bar are covered in place.")
                }
            }
            var sides = "Left of the icon: \(i.hidden) hidden"
            if i.parked > 0 { sides += " (\(i.parked) in macOS's « overflow)" }
            sides += ". Right of it: \(i.shown) shown."
            lines.append(sides)
        }
        if let wake = MenuBarWakeRecovery.line(for: i.wake) { lines.append(wake) }
        if let change = i.lastChange { lines.append("Last change: \(change).") }
        return MenuBarDividerReadout(lines: lines)
    }
}
