import CoreGraphics
import Foundation
import JRBarCore

/// Whether the divider has room to stand on this bar. The divider needs a
/// stretch of blank bar to fill and its own icon on the row; on a bar so
/// crowded that macOS parks the icon itself there is no room, and the
/// divider cannot hide anything. The card says so and says what to do.
enum MenuBarDividerRoom: Equatable, Sendable {
    case unknown
    case holds
    case noRoom
}

/// Watches whether the divider's icon holds a place on the row. The
/// divider hides by filling the blank bar left of its icon; a bar so
/// crowded that macOS parks the icon itself, even with no spacer, leaves
/// it nothing to stand on. Pure over an injected clock.
struct MenuBarDividerRoomWatch: Equatable, Sendable {
    /// How long the icon must be off the row, with no spacer to blame,
    /// before the bar counts as having no room.
    nonisolated static let missingGrace: TimeInterval = 8
    /// How long the icon must stand on the row to count as holding.
    nonisolated static let holdGrace: TimeInterval = 3
    /// Spacer lessons (the boundary found parked) that, inside
    /// `lessonWindow`, mean no room.
    nonisolated static let lessonLimit = 3
    nonisolated static let lessonWindow: TimeInterval = 60

    private(set) var room: MenuBarDividerRoom = .unknown
    private var missingSince: TimeInterval?
    private var onRowSince: TimeInterval?
    private var lessons: [TimeInterval] = []

    nonisolated init() {}

    /// One look at the icon. `spacerIsMinimal` is whether the spacer is at
    /// its floor, so a missing icon cannot be the spacer's doing.
    nonisolated mutating func note(iconOnRow: Bool, spacerIsMinimal: Bool, now: TimeInterval) {
        if iconOnRow {
            missingSince = nil
            let since = onRowSince ?? now
            onRowSince = since
            if now - since >= Self.holdGrace, room != .holds {
                room = .holds
                lessons.removeAll()
            }
            return
        }
        onRowSince = nil
        guard spacerIsMinimal else {
            // Parked under a long spacer: the cap and the fit edge deal
            // with it (`noteParkedLesson`), not a verdict on the bar.
            missingSince = nil
            return
        }
        let since = missingSince ?? now
        missingSince = since
        if now - since >= Self.missingGrace { room = .noRoom }
    }

    /// The boundary was found parked under a spacer and the cap lowered.
    nonisolated mutating func noteParkedLesson(now: TimeInterval) {
        lessons.append(now)
        lessons.removeAll { now - $0 > Self.lessonWindow }
        if lessons.count >= Self.lessonLimit { room = .noRoom }
    }

    /// A new geometry (another display, another front app's menus) starts
    /// the question over.
    nonisolated mutating func reset() {
        room = .unknown
        missingSince = nil
        onRowSince = nil
        lessons.removeAll()
    }
}

/// What a crowded bar costs, in items: the help the card and the icon's
/// menu give when the divider has no room. Pure over frames.
enum MenuBarRoomHelp {
    /// How many of the items now drawn right of the notch would have to
    /// leave the bar (quit, or turned off in System Settings > Control
    /// Center > Menu Bar) to seat the icon. The widest go first, so the
    /// answer is the fewest. `need` is the icon's width plus a gap; zero
    /// widths and the system's own items never count, because the person
    /// cannot take those off the bar from here.
    nonisolated static func itemsToFree(widths: [CGFloat], need: CGFloat) -> Int {
        guard need > 0 else { return 0 }
        var freed: CGFloat = 0
        var count = 0
        for width in widths.sorted(by: >) where width > 0 {
            freed += width
            count += 1
            if freed >= need { return count }
        }
        // Even every item leaving would not seat it: say all of them.
        return count
    }

    /// The help line. `parked` is how many items macOS holds in its own
    /// overflow right now; `remove` is `itemsToFree`.
    nonisolated static func line(parked: Int, remove: Int) -> String {
        let held = parked == 0 ? "" : parked == 1
            ? "macOS is holding 1 item in its « overflow. "
            : "macOS is holding \(parked) items in its « overflow. "
        let take = remove <= 1 ? "Quit or switch off at least 1 menu bar item" : "Quit or switch off at least \(remove) menu bar items"
        return held + take + " to give the JR-Bar icon a place."
    }
}
