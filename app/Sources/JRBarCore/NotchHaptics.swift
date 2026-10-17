import Foundation

/// The felt edges of the island: when a trackpad tap goes with a thing
/// the island does, and which tap. A tap is only felt while a finger is
/// on the trackpad, so every moment here is one a hand just did: the
/// grow (a hover, click, swipe or pinch opened it), a page turned by a
/// swipe, a card folded by a swipe, pinch or pull. Nothing the island
/// does on its own (an ask arriving, a notice, a timer) ever taps: a
/// finger that happened to rest on the trackpad would feel a message it
/// did not ask for, and a tap that fires only sometimes cannot be
/// learned. One switch (`NotchSettings.hapticTick`) turns all of them
/// off, and Reduce Motion does not: a tap is not motion, and it is the
/// one answer a person who has asked for less movement still gets.
public enum NotchHaptics {
    public enum Moment: Equatable, Sendable, CaseIterable {
        /// The card grew under a hand.
        case open
        /// A swipe turned the card's page.
        case pageTurn
        /// A swipe, pinch or pull folded the card (not a click, which
        /// already clicks, and not a hover leaving, which is no touch).
        case gestureFold
    }

    /// The strength of the tap, in the system's own vocabulary: `generic`
    /// for a thing arriving, `alignment` for a thing snapping into
    /// place. The app maps these to `NSHapticFeedbackManager`'s patterns.
    public enum Pattern: Equatable, Sendable { case generic, alignment }

    public static func pattern(for moment: Moment) -> Pattern {
        switch moment {
        case .open: return .generic
        case .pageTurn, .gestureFold: return .alignment
        }
    }

    /// Whether a moment taps: the switch is on and this is a live island
    /// (a headless one in a test has no trackpad to tap).
    public static func fires(_ moment: Moment, switchOn: Bool, live: Bool) -> Bool {
        switchOn && live
    }
}
