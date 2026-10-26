import SwiftUI
import JRBarUI

/// `@State` is a macro on the macOS 26 SDK and the Command Line Tools ship
/// no `SwiftUIMacros` plugin, so the views reach the `State` property
/// wrapper through this alias, which names the struct and not the macro.
typealias ViewState<Value> = SwiftUICore.State<Value>

/// The panel's whole motion vocabulary, so every transition in the app
/// feels like the same object moving.
///
/// * `unfoldDuration` -- the panel itself arriving (the controller's
///   window fade and 98% scale);
/// * `contents`  -- rows entering, leaving and reordering;
/// * `crossfade` -- a word or number changing in place.
///
/// With Reduce Motion on, every one collapses to a short opacity fade.
/// Until the panel has finished arriving (`armed`), nothing inside it
/// animates at all: the first frame is the final frame.
enum PanelMotion {
    static let unfoldDuration: TimeInterval = JRBarTokens.Motion.panelEntrance.duration
    static let reducedDuration: TimeInterval = JRBarTokens.Motion.reduced.duration

    static func contents(reduced: Bool, armed: Bool = true) -> Animation? {
        guard armed else { return nil }
        return reduced ? nil : JRBarTokens.Motion.rowChange.animation
    }

    static func crossfade(reduced: Bool, armed: Bool = true) -> Animation? {
        guard armed else { return nil }
        return JRBarTokens.Motion.rowChange.animation(reduceMotion: reduced)
    }

    /// Inserted rows fade and settle without a bounce. Reduce Motion only fades.
    static func rowTransition(reduced: Bool) -> AnyTransition {
        JRBarTokens.Motion.transition(reduceMotion: reduced)
    }
}
