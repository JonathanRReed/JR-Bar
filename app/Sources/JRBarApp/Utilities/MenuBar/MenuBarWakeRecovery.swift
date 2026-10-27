import CoreGraphics
import Foundation

/// What the divider does when something re-forms the bar under it: the Mac
/// wakes, the displays wake, the session comes back, a display is attached
/// or removed, a Space changes. macOS rebuilds the status row at those
/// moments and apps put their items back one by one, so for a few seconds
/// every frame JR-Bar reads is a frame mid-move.
///
/// The rule, in three beats:
///
///  1. **Quiet.** For `quiet` seconds after the last event JR-Bar learns
///     nothing (no parked-cap lesson, no fit-edge lesson) and writes no
///     spacer, so the bar is not nudged while it is forming. Events that
///     keep arriving (the Mac wakes, then its displays, then the session)
///     extend the quiet, but never past `longest` from the first.
///  2. **Re-measure.** When it ends, what was learned is forgotten once
///     and the next reading starts clean.
///  3. **Check, re-seat once, stop.** On two fresh listings in a row the
///     icon must be on the row, wear the width that was written, and not
///     overlap another app's item. If not, the spacer is re-seated once
///     (folded and written again, which makes macOS sort the row afresh)
///     and the bar is checked again. If it is still wrong JR-Bar stops and
///     says so; it never tries a third time for the same event.
///
/// Pure over an injected clock: nothing here sleeps or schedules.
struct MenuBarWakeRecovery: Equatable, Sendable {
    /// How long after the last event the bar is left alone.
    nonisolated static let quiet: TimeInterval = 2.5
    /// The most events can stretch the quiet, counted from the first.
    nonisolated static let longest: TimeInterval = 10
    /// How long the bar is left alone after a re-seat, before it is checked.
    nonisolated static let reseatSettle: TimeInterval = 2.0
    /// An episode that never gets a fresh listing to judge by is dropped
    /// after this long, unverified.
    nonisolated static let giveUp: TimeInterval = 30
    /// Fresh listings in a row that must show the same trouble.
    nonisolated static let strikesNeeded = 2
    /// How far another item may reach into the icon before it counts.
    nonisolated static let overlapSlack: CGFloat = 6
    /// How far the icon's width may differ from what was written.
    nonisolated static let widthSlack: CGFloat = 3

    /// What is wrong with the icon's seat.
    enum Trouble: Equatable, Sendable {
        /// macOS left the icon off the row.
        case offRow
        /// Other apps' items stand over the icon (their names).
        case overlapped([String])
        /// The icon is not the width JR-Bar wrote.
        case spacerNotStanding
    }

    /// Where the episode stands, for "What JR-Bar sees".
    enum Verdict: Equatable, Sendable {
        /// No check has started yet.
        case idle
        /// An event was heard; waiting out the quiet and for a fresh read.
        case settling
        /// Checked: the icon stands clear.
        case clear
        /// Re-seated once; the next fresh read decides.
        case reseated(Trouble)
        /// Re-seated once and the icon stands clear now.
        case recovered(Trouble)
        /// Re-seated once and it is still wrong. JR-Bar stopped there.
        case stuck(Trouble)
        /// No fresh listing ever came to judge by.
        case unverified
    }

    /// What one fresh look at the icon found.
    struct Health: Equatable, Sendable {
        var onRow = true
        var spacerStands = true
        var overlapping: [String] = []

        var trouble: Trouble? {
            if !onRow { return .offRow }
            if !overlapping.isEmpty { return .overlapped(overlapping.sorted()) }
            if !spacerStands { return .spacerNotStanding }
            return nil
        }
    }

    enum Action: Equatable, Sendable {
        case none
        /// Fold the spacer and write it again, once.
        case reseat
    }

    private(set) var verdict: Verdict = .idle
    private var armed = false
    private var firstEventAt: TimeInterval = 0
    private var quietUntil: TimeInterval = 0
    private var remeasureDue = false
    private var reseats = 0
    private var strikes = 0
    private var firstTrouble: Trouble?
    private var lastGeneration = -1
    /// Only a Space changed: if the bar was never in a state to judge
    /// (a full-screen app hid it), the episode ends without a word.
    private var light = true

    nonisolated init() {}

    /// Whether an episode is open (an event was heard and not yet judged).
    nonisolated var isOpen: Bool { armed }

    /// An event that re-forms the bar (`light`: a Space change, which moves
    /// nothing itself). A second one inside an open episode
    /// extends the quiet; one after the episode closed opens a new episode
    /// with a fresh single re-seat.
    nonisolated mutating func noteEvent(now: TimeInterval, light: Bool = false) {
        if !armed {
            self.light = true
            armed = true
            firstEventAt = now
            quietUntil = now
            reseats = 0
            strikes = 0
            firstTrouble = nil
            lastGeneration = -1
        }
        if !light { self.light = false }
        remeasureDue = true
        if case .reseated = verdict {
            // A new event over an unfinished re-seat starts over.
            reseats = 0
        }
        verdict = .settling
        quietUntil = max(quietUntil, min(now + Self.quiet, firstEventAt + Self.longest))
    }

    /// The bar went dark (displays asleep, session away, screen locked):
    /// nothing is left to judge until it comes back.
    nonisolated mutating func noteDark() {
        armed = false
        remeasureDue = false
        strikes = 0
        if case .settling = verdict { verdict = .idle }
    }

    /// Whether the bar is being left alone now: no lessons, no writes.
    nonisolated func isQuiet(now: TimeInterval) -> Bool {
        armed && now < quietUntil
    }

    /// True once, at the first look after the quiet ends: the caller forgets
    /// what it learned and reads on clean.
    nonisolated mutating func takeRemeasure(now: TimeInterval) -> Bool {
        guard armed, remeasureDue, now >= quietUntil else { return false }
        remeasureDue = false
        return true
    }

    /// One look. `generation` is the listing's generation, `floor` the
    /// generation at the last write (a listing from before it predates the
    /// reflow), and `judgeable` whether the bar can be judged at all (a
    /// hidden menu bar cannot). Returns the one action to take.
    nonisolated mutating func assess(now: TimeInterval, generation: Int, floor: Int,
                                     judgeable: Bool, health: Health) -> Action {
        guard armed else { return .none }
        if now - firstEventAt > Self.giveUp {
            armed = false
            verdict = light ? .idle : .unverified
            return .none
        }
        guard now >= quietUntil, judgeable, generation > floor, generation != lastGeneration else {
            return .none
        }
        lastGeneration = generation
        guard let trouble = health.trouble else {
            armed = false
            strikes = 0
            verdict = reseats > 0 ? .recovered(firstTrouble ?? .spacerNotStanding) : .clear
            return .none
        }
        strikes += 1
        guard strikes >= Self.strikesNeeded else { return .none }
        strikes = 0
        if reseats == 0 {
            reseats = 1
            firstTrouble = trouble
            verdict = .reseated(trouble)
            quietUntil = now + Self.reseatSettle
            return .reseat
        }
        armed = false
        verdict = .stuck(trouble)
        return .none
    }

    /// The items that overlap the icon: someone else's, on the row, with
    /// at least `overlapSlack` points of their width inside the icon's.
    /// Native overflow, items parked beneath it and our own items never count. Pure.
    nonisolated static func overlapping(icon: CGRect, row: CGRect, items: [MenuBarItem],
                                        ourPID: pid_t) -> [String] {
        guard icon.intersects(row) else { return [] }
        let overflowFrames = items.filter { $0.isNativeOverflowControl && $0.bounds.intersects(row) }
            .map(\.bounds)
        return items.filter { item in
            item.ownerPID != ourPID && !item.isNativeOverflowControl
                && item.bounds.intersects(row)
                && !overflowFrames.contains { $0.intersection(item.bounds).width >= 4 }
                && item.bounds.intersection(icon).width >= overlapSlack
        }.map(\.displayName)
    }

    /// Whether the icon is the width that was written: its own width now
    /// (a strip of session dots grows and shrinks) plus the spacer that was
    /// written with it. A wide icon can spend the entire spacer, so a
    /// known write has no additional affordance floor.
    nonisolated static func widthStands(frame: CGRect, written: CGFloat?, writtenGlyph: CGFloat,
                                        glyph: CGFloat) -> Bool {
        guard let written else { return true }
        let expected = glyph + max(0, written - writtenGlyph)
        return abs(frame.width - expected) <= widthSlack
    }

    /// The line "What JR-Bar sees" shows for the episode; nil when there is
    /// nothing to say (nothing happened, or all is well).
    nonisolated static func line(for verdict: Verdict) -> String? {
        switch verdict {
        case .idle, .settling, .clear:
            return nil
        case .reseated:
            return "After the bar re-formed: the icon was re-seated once; checking it."
        case .recovered:
            return "After the bar re-formed: the icon was re-seated once and stands clear."
        case .unverified:
            return "JR-Bar could not get a complete reading of the divider."
        case .stuck(let trouble):
            switch trouble {
            case .offRow:
                return "After the bar re-formed: macOS left the icon off the bar. It was re-seated once and JR-Bar stops there."
            case .overlapped(let names):
                let who = names.prefix(3).joined(separator: ", ")
                return "After the bar re-formed: the icon is overlapped by \(who). It was re-seated once and JR-Bar stops there; macOS keeps the order, so ⌘-drag the icon or that app to a clear place."
            case .spacerNotStanding:
                return "After the bar re-formed: the icon is not the width JR-Bar wrote. It was re-seated once and JR-Bar stops there."
            }
        }
    }
}
