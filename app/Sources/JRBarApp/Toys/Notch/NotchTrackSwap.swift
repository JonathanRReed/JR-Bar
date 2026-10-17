import AppKit
import JRBarCore
import SwiftUI

/// One track giving way to the next: the title, the byline and the
/// cover change together on one quiet crossfade instead of cutting, on
/// the same clock wherever the track is drawn (the island's strip and
/// the card's media row). Under Reduce Motion the fade is the shorter,
/// travel-free one every other face uses.
struct NotchTrackSwap: ViewModifier {
    /// What identifies the track: its words, and the cover's identity.
    let key: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(
            .easeOut(duration: reduceMotion ? NotchMotion.reduceMotionFade : NotchMotion.trackSwap),
            value: key)
    }
}

extension View {
    /// Crossfade this view's text and cover when `key` changes.
    func notchTrackSwap(key: String) -> some View {
        modifier(NotchTrackSwap(key: key))
    }
}

/// A line of a track's words (title or byline) giving way to the next:
/// the old one goes out first and the new one comes in as it leaves
/// (`NotchMotion.trackSwapLevels`), instead of both crossfading in the
/// same place, where two sets of small glyphs read as a smear for a
/// tenth of a second. Under Reduce Motion it is the same quiet fade every
/// other face uses. The line keeps its place: the old and the new share
/// one slot for the length of the swap.
struct NotchTrackLine<Content: View>: View {
    /// What identifies the words; a new key is a new line.
    let key: String
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: NotchMotion.trackSwapIn)
                .delay(NotchMotion.trackSwapInDelay)),
            removal: .opacity.animation(.easeIn(duration: NotchMotion.trackSwapOut)))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content().id(key).transition(transition)
        }
        .animation(.easeOut(duration: reduceMotion ? NotchMotion.reduceMotionFade : NotchMotion.trackSwap),
                   value: key)
    }
}

/// A cover that dissolves into the next one. The two are laid in the
/// same place for the length of the fade, so nothing around them moves.
struct NotchCoverSwap<Placeholder: View>: View {
    let image: NSImage?
    @ViewBuilder var placeholder: () -> Placeholder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                placeholder().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? NotchMotion.reduceMotionFade : NotchMotion.trackSwap),
                   value: image.map { ObjectIdentifier($0) })
    }
}
