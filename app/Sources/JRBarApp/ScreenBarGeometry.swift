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
    @MainActor static var earItemLimitLeft: CGFloat? {
        didSet { if !updatingEarItemLimits, earItemLimitLeft != oldValue { earLimitsChanged?() } }
    }
    @MainActor static var earItemLimitRight: CGFloat? {
        didSet { if !updatingEarItemLimits, earItemLimitRight != oldValue { earLimitsChanged?() } }
    }
    @MainActor private static var updatingEarItemLimits = false

    @MainActor static func setEarItemLimits(left: CGFloat?, right: CGFloat?) {
        guard left != earItemLimitLeft || right != earItemLimitRight else { return }
        updatingEarItemLimits = true
        earItemLimitLeft = left
        earItemLimitRight = right
        updatingEarItemLimits = false
        earLimitsChanged?()
    }

    /// Called whenever either limit changes, and by `MenuBarUtility`
    /// whenever the ear's ‹ handle flips, so the band re-sizes its ears
    /// at once instead of on its slow safety poll. Set by
    /// `ScreenBarController`.
    @MainActor static var earLimitsChanged: (@MainActor () -> Void)?

    /// The notch island's live shape in screen coordinates while it is
    /// ours and on screen — the same answer `NotchToy.islandScreenRect`
    /// gives, read off the window itself so a morph's in-flight shape is
    /// what the band couples to. The shape, not the window: while a move
    /// runs the window is a stage around it (`NotchIslandWindow
    /// .presentedFrame`). nil while the island is parked, ordered
    /// out, or another provider owns the notch — the standalone band.
    @MainActor static var islandScreenRect: NSRect? {
        // NSApp is nil in a test process — optional-chained, not unwrapped.
        for window in NSApp?.windows ?? [] {
            guard let island = window as? NotchIslandWindow, island.isVisible else { continue }
            return island.presentedFrame
        }
        return nil
    }

    /// Reserve the island's fixed animation canvas while its shape moves.
    /// The light still follows `islandScreenRect`, not this outer frame.
    @MainActor static var islandStageScreenRect: NSRect? {
        guard NotchIslandWindow.stagedMotion else { return nil }
        for window in NSApp?.windows ?? [] {
            guard let island = window as? NotchIslandWindow,
                  island.isVisible, island.isAnimating else { continue }
            return island.frame
        }
        return nil
    }

    /// The Screen Bar panel's live frame — the surface whose housing,
    /// tray and ear lobes draw black over whatever of the menu-bar row
    /// it spans. Wider than the island: the wings' claims extend it past
    /// the notch's edges, so an item clear of the island can still sit
    /// under the band's face. nil while the band is ordered out.
    @MainActor static var bandScreenRect: NSRect? {
        for window in NSApp?.windows ?? [] where window is ScreenBarPanel {
            guard window.isVisible else { continue }
            return window.frame
        }
        return nil
    }
}
