import AppKit

/// Rounds a glass window's shadow along with its glass.
///
/// A borderless, clear window takes its shadow from its content's
/// alpha, and an `NSGlassEffectView` hosted as the content view hands
/// the window server its whole rectangle: every glass panel cast a
/// square shadow whose dark outline showed past the rounded corners
/// (measured 2026-09-22 with a scratch panel — the same glass inside a
/// rounded, clipped container casts a rounded shadow, with or without
/// `invalidateShadow`). Windows host the container; the backdrop fills
/// it and follows every resize.
@MainActor
enum GlassBackdrop {
    static func rounded(_ backdrop: NSView, cornerRadius: CGFloat) -> NSView {
        let container = NSView(frame: backdrop.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)
        return container
    }
}
