import Foundation

/// How a page of the grown card turns, and how it says "no more pages".
///
/// The card has two pages and a sideways swipe moves between them. The
/// swipe used to swap the rows in one frame while the shape caught up
/// with the new height, which read as a flicker rather than a turn. Now
/// the page that arrives comes in from the side the fingers were
/// travelling toward, in focus, on the `NotchMotion.pageTurn` spring,
/// and the page that left is already gone (two sets of rows are never on
/// the card together, so the card never has to be taller than the
/// page it shows). All of it is a pure function of the spring's `level`
/// (0 at the start of the turn, 1 when it has landed), so a test or a
/// render proof can read any moment without a clock.
public enum NotchPageTurn {
    /// Which way the new page arrives from. A swipe toward the left
    /// (fingers travelling left) brings the next page in from the right.
    public enum Direction: Int, Equatable, Sendable {
        case fromRight = 1
        case fromLeft = -1

        /// The direction for a move between two page positions: forward
        /// (a higher index) arrives from the right.
        public init(from old: Int, to new: Int) {
            self = new >= old ? .fromRight : .fromLeft
        }
    }

    /// How far the arriving page starts from its place, in points. Short
    /// on purpose: the page is 320 wide and a slide across all of it
    /// would be the whole card moving on a frequent gesture.
    public static let travel: CGFloat = 18
    /// The blur the arriving page clears.
    public static let blur: CGFloat = 3
    /// The page is fully opaque by this much of the spring's travel, so
    /// the rows are readable before they have stopped moving.
    public static let opaqueBy: CGFloat = 0.6

    /// The arriving page's opacity at `level`.
    public static func opacity(level: CGFloat) -> CGFloat {
        let t = min(1, max(0, level / opaqueBy))
        return t * t * (3 - 2 * t)
    }

    /// The arriving page's horizontal offset at `level`, signed: the
    /// start is `travel` toward the side it comes from.
    public static func offset(level: CGFloat, direction: Direction) -> CGFloat {
        CGFloat(direction.rawValue) * travel * (1 - min(1, max(0, level)))
    }

    /// The arriving page's blur radius at `level`.
    public static func blurRadius(level: CGFloat) -> CGFloat {
        blur * (1 - min(1, max(0, level)))
    }

    /// Reduce Motion's page turn: the same arrival with no travel and
    /// no blur, a plain fade.
    public static func reducedOpacity(level: CGFloat) -> CGFloat {
        min(1, max(0, level))
    }

    // MARK: The edge

    /// A swipe toward a page that does not exist (left on the last page,
    /// right on the first) pushes the card's content this far that way
    /// and lets it back: friction instead of a wall. Small enough to be
    /// a nudge under a finger, large enough to be seen on a 320-wide card.
    public static let edgePeak: CGFloat = 6
    /// Out to the peak quickly (the finger is still going), then back
    /// slowly: the asymmetry is what reads as friction. Total 0.31 s, and
    /// never past the peak, never on the other side of rest.
    public static let edgeOut: TimeInterval = 0.07
    public static let edgeBack: TimeInterval = 0.24
    public static var edgeDuration: TimeInterval { edgeOut + edgeBack }
}
