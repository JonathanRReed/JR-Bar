import AppKit
import JRBarUI

/// The visible face of our status item while the concealer runs.
///
/// The agent never draws an item that shares the asserting process's
/// signing identity — measured 2026-09-22: our item, allowlisted and
/// adopted on the row, composites nothing once our own assertion lands
/// (the 2026-09-21 "foreign holder" note holds; the helper shares our
/// Developer ID, and the agent exempts by identity, not by process).
/// macOS's own overflow hides it too whenever the extras run is full.
///
/// So under the concealer the real item keeps its anchor slot wherever
/// the agent seats it — slim, under the band — and this window carries
/// the pixels: the item's own image, mirrored onto a small panel parked
/// at the band's right edge — the left end of the visible run, the
/// Bartender seat: hidden run behind the face, shown run to its right.
/// A click here drives the same handlers the real button would.
final class MenuBarIconMirror: NSPanel {
    /// The item's current face — read off its button each refresh so
    /// the mirror shows whatever style is configured, live.
    var iconSource: (() -> NSImage?)?
    /// Ordinary click — the panel toggle the item's left-click performs.
    var onPrimaryClick: (() -> Void)?
    /// Right/Option click — the hidden-items menu the item's own
    /// secondary click presents.
    var onSecondaryClick: (() -> NSMenu?)?

    private let iconView = NSImageView()
    private var tracker: Timer?

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        contentView = iconView
        // `acceptsMouseMovedEvents` stays off — this window exists to be
        // seen and clicked, never to hover over the run it mirrors.
    }

    /// Show at the visible seat: the slot just right of the band's
    /// covering edge, inside the menu-bar row. `bandRight` is the band
    /// window's maxX in Quartz screen coordinates; `row` the menu-bar
    /// strip the item would stand in. The timer re-reads both the icon
    /// and the seat so a morphing band carries the mirror with it.
    func show(bandRight: @escaping () -> CGFloat?, row: @escaping () -> CGRect?,
              screen: @escaping () -> NSScreen?) {
        seat = { bandRight() }
        rowRect = { row() }
        hostScreen = { screen() }
        place()
        orderFrontRegardless()
        tracker?.invalidate()
        tracker = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.place()
        }
    }

    func hide() {
        tracker?.invalidate()
        tracker = nil
        orderOut(nil)
    }

    private var seat: (() -> CGFloat?)?
    private var rowRect: (() -> CGRect?)?
    private var hostScreen: (() -> NSScreen?)?

    private func place() {
        guard let bandRight = seat?(), let row = rowRect?(),
              let screen = hostScreen?() else { hide(); return }
        let image = iconSource?()
        iconView.image = image
        // The slot wears the icon's natural aspect — a meters strip
        // reads at its drawn width, a glyph at a square — like a real
        // item's variable length, capped so a wide style never eats
        // the run it opens.
        let height = Self.height
        let aspect = image.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 } ?? 1
        let width = min(Self.maxWidth, max(Self.minWidth, height * aspect))
        let quartzX = bandRight + 6
        let quartzY = row.midY - NSStatusBar.system.thickness / 2 + 1
        // Quartz (top-left origin) → AppKit (bottom-left origin).
        let appY = screen.frame.maxY - quartzY - height + 2
        setFrame(NSRect(x: quartzX, y: appY, width: width, height: height), display: true)
        iconView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), let menu = onSecondaryClick?() {
            present(menu, event: event)
        } else {
            onPrimaryClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = onSecondaryClick?() else { return }
        present(menu, event: event)
    }

    /// The item's own secondary click pops the menu under the button;
    /// the mirror is that button — same call, same look.
    private func present(_ menu: NSMenu, event: NSEvent) {
        menu.popUp(positioning: nil, at: NSPoint(x: 2, y: Self.height - 2), in: contentView)
    }

    /// The slot's footprint: menu-bar height, and a width between a
    /// glyph's square and a wide meters strip.
    static let height: CGFloat = 26
    static let minWidth: CGFloat = 30
    static let maxWidth: CGFloat = 72
}
