import AppKit
import JRBarUI

/// The geometry helpers moved to JRBarUI so their pure halves are
/// unit-tested (`ScreenBarGeometryTests`); the aliases keep every call
/// site — including Toys, which imports only JRBarCore — unqualified.
typealias ScreenBarDesign = JRBarUI.ScreenBarDesign
typealias ScreenBarGeometry = JRBarUI.ScreenBarGeometry
typealias ScreenBarWingGeometry = JRBarUI.ScreenBarWingGeometry
typealias ScreenBarWingSide = JRBarUI.ScreenBarWingSide
typealias NotchProfile = JRBarUI.NotchProfile

extension ScreenBarGeometry {
    /// The notch island's live frame in screen coordinates while it is
    /// ours and on screen — the same answer `NotchToy.islandScreenRect`
    /// gives, read off the window itself so a morph's in-flight frame is
    /// what the band couples to. nil while the island is parked, ordered
    /// out, or another provider owns the notch — the standalone band.
    @MainActor static var islandScreenRect: NSRect? {
        for window in NSApp.windows where window is NotchIslandWindow {
            guard window.isVisible else { continue }
            return window.frame
        }
        return nil
    }
}
