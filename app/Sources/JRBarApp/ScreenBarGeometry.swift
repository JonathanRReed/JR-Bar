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
    /// The frame macOS's own « overflow control occupies, in screen
    /// coordinates, while the Menu Bar utility is hiding a run beside
    /// it — the Screen Bar's right ear stops short of it so the two
    /// never overlap, and the utility's cover can take the whole «.
    /// nil while nothing is hidden. Written by `MenuBarUtility`, read
    /// by `ScreenBarController`'s reposition.
    @MainActor static var earAvoidScreenRect: NSRect?

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
