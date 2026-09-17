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
    /// The innermost occupied edge on each notch flank, in screen x —
    /// the nearest status item's edge on that side (the « a hidden run
    /// keeps beside the notch, our own chevron, whatever macOS parks in
    /// the flank). Each ear stops short of its side's limit: a drawn
    /// wing paving a real item hides it and swallows its clicks. nil
    /// while the flank is free. Written by `MenuBarUtility` on every
    /// reconcile, read by `ScreenBarController`'s reposition.
    @MainActor static var earItemLimitLeft: CGFloat?
    @MainActor static var earItemLimitRight: CGFloat?

    /// The island ‹ handle's live frame in screen coordinates while the
    /// concealer runs — the hidden run's affordance drawn on our own
    /// surface. `MenuBarReveal` adds it to its hot frames so hovering the
    /// glyph reveals the run exactly like Bartender's chevron. nil while
    /// the handle is not drawn. Written by `ScreenBarController`.
    @MainActor static var menuHandleScreenRect: NSRect?

    /// The notch island's live frame in screen coordinates while it is
    /// ours and on screen — the same answer `NotchToy.islandScreenRect`
    /// gives, read off the window itself so a morph's in-flight frame is
    /// what the band couples to. nil while the island is parked, ordered
    /// out, or another provider owns the notch — the standalone band.
    @MainActor static var islandScreenRect: NSRect? {
        // NSApp is nil in a test process — optional-chained, not unwrapped.
        for window in NSApp?.windows ?? [] where window is NotchIslandWindow {
            guard window.isVisible else { continue }
            return window.frame
        }
        return nil
    }
}
