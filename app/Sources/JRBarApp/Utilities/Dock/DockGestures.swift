import AppKit
import SwiftUI

/// What a scroll or swipe over a dock tile means — the interpreter's
/// output, which the panel maps onto the model.
enum DockGestureAction: Equatable {
    /// Step the hovered app's windows — next or previous.
    case cycleWindows(forward: Bool)
    /// Open the hovered app's window-preview panel.
    case showPreviews
}

/// Pointer position → tile index. The magnifier publishes the icons'
/// row-axis centres; a gesture over the bar asks which tile it's
/// really over. Pure — the tests pin the hit radius behaviour.
enum DockGestureMath {
    /// The nearest centre within `hitRadius` points, or nil — gaps,
    /// separators and past-the-end positions answer nil rather than
    /// grabbing the edge tile.
    static func itemIndex(at position: Double, centers: [Double],
                          hitRadius: Double) -> Int? {
        var best: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let distance = abs(center - position)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        guard let best, bestDistance <= hitRadius else { return nil }
        return best
    }
}

/// Scroll-wheel / trackpad input → `DockGestureAction`, pure so the
/// mapping is testable without an `NSEvent` (P4, "scroll-to-switch"
/// and "swipe up for previews"):
///
/// - **Mouse wheel** (non-precise deltas): each vertical notch steps
///   the hovered app's windows — wheel down is next, up is previous.
/// - **Trackpad** (precise deltas inside a phased gesture): a
///   horizontal pan steps per `horizontalStep` points of travel
///   (fingers left = next), a downward pan steps forward per
///   `verticalStep`, and an upward pan past `previewThreshold` opens
///   the window previews — once per gesture. The threshold is high
///   on purpose: a casual upward scroll must never surprise into a
///   panel.
struct DockScrollInterpreter {
    private var x = 0.0
    private var y = 0.0
    private var live = false
    private var previewFired = false

    /// Horizontal finger travel per window step.
    static let horizontalStep: Double = 44
    /// Downward finger travel per window step.
    static let verticalStep: Double = 36
    /// Upward travel that commits to the preview panel.
    static let previewThreshold: Double = 120

    /// A mouse-wheel notch: one discrete action, or nil for a
    /// horizontal-dominant wheel move.
    mutating func noteWheel(deltaY: Double) -> DockGestureAction? {
        guard deltaY != 0 else { return nil }
        // Wheel down (negative delta) scrolls forward through windows.
        return .cycleWindows(forward: deltaY < 0)
    }

    /// A trackpad scroll event. `dx`/`dy` arrive finger-normalized —
    /// the caller has applied `isDirectionInvertedFromDevice` — and
    /// `began`/`ended` bracket the gesture; momentum events (empty
    /// phase) never reach here, the caller drops them.
    mutating func notePan(dx: Double, dy: Double,
                          began: Bool, ended: Bool) -> DockGestureAction? {
        if began {
            x = 0
            y = 0
            previewFired = false
            live = true
        }
        if ended {
            live = false
            x = 0
            y = 0
            return nil
        }
        guard live else { return nil }
        x += dx
        y += dy
        if !previewFired, y >= Self.previewThreshold, y > abs(x) {
            previewFired = true
            return .showPreviews
        }
        if abs(x) >= Self.horizontalStep, abs(x) > abs(y) {
            let forward = x < 0   // fingers left = next window
            x = 0
            return .cycleWindows(forward: forward)
        }
        if y <= -Self.verticalStep, -y > abs(x) {
            y = 0
            return .cycleWindows(forward: true)
        }
        return nil
    }

    /// The pointer wandered to another tile mid-gesture — forget the
    /// accumulated travel so the next tile starts clean.
    mutating func reset() {
        x = 0
        y = 0
        live = false
        previewFired = false
    }
}

/// The bar's hosting view, subclassed for `scrollWheel`/`swipe` —
/// SwiftUI has no scroll gesture surface, and the gestures need the
/// row's coordinate space anyway, so the events land here and the
/// panel interprets them (`DockPanel.handleScroll`/`handleSwipe`).
final class DockHostingView: NSHostingView<DockView> {
    /// Every scroll event over the bar, still in `NSEvent` terms —
    /// the panel owns the location math and the interpreter.
    var onScrollWheel: (NSEvent) -> Void = { _ in }
    /// A trackpad `.swipe` gesture — delivered only when the system's
    /// gesture recognizer isn't claiming the motion (three-finger
    /// swipes, or two-finger ones when page-swiping is off), so the
    /// scroll interpreter's upward-pan path is the primary trigger.
    var onSwipe: (NSEvent) -> Void = { _ in }

    override func scrollWheel(with event: NSEvent) { onScrollWheel(event) }
    override func swipe(with event: NSEvent) { onSwipe(event) }
}
