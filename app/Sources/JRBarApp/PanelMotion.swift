import SwiftUI

/// `@State` is a macro on the macOS 26 SDK and the Command Line Tools ship
/// no `SwiftUIMacros` plugin, so the views reach the `State` property
/// wrapper through this alias, which names the struct and not the macro.
typealias ViewState<Value> = SwiftUICore.State<Value>

/// The panel's whole motion vocabulary: three springs and nothing else, so
/// every transition in the app feels like the same object moving.
///
/// * `unfold`    -- the panel itself arriving (window fade + 6 pt rise);
/// * `contents`  -- rows entering, leaving and reordering;
/// * `crossfade` -- a word or number changing in place.
///
/// With Reduce Motion on, every one collapses to a short opacity fade.
enum PanelMotion {
    static let unfoldDuration: TimeInterval = 0.26
    static let reducedDuration: TimeInterval = 0.12

    static func unfold(reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: reducedDuration) : .spring(response: 0.34, dampingFraction: 0.86)
    }

    static func contents(reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: reducedDuration) : .spring(response: 0.32, dampingFraction: 0.82)
    }

    static func crossfade(reduced: Bool) -> Animation {
        .easeInOut(duration: reduced ? reducedDuration : 0.16)
    }

    /// Rows slide in from a few points below and fade; with Reduce Motion they only fade.
    static func rowTransition(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }
}
