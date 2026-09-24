import AppKit
import SwiftUI

/// How a titled JR-Bar window holds its SwiftUI content: attached while
/// the window is open, released when it closes. The AppKit shell stays —
/// its frame autosave, toolbar and delegate survive to the next open —
/// but the graph does not. A closed window that kept it went on
/// evaluating its timelines and laying itself out for nobody: Effect
/// Studio's 30 fps LED previews and a min-size pass on every frame held
/// the app at 45–97% of a core after its windows were closed.
///
/// The stores keep what should survive a close (a selection, a filter);
/// view-local state, such as a scroll position, starts over on reopen.
@MainActor
enum WindowContentLifecycle {
    /// Installs the controller `make` builds as `window`'s content, unless
    /// content is already attached, and returns what is attached. The
    /// window's frame and size limits come through unchanged, and the
    /// title and subtitle are reapplied: replacing the content controller
    /// clears the unified titlebar's subtitle.
    ///
    /// The new view is sized to the window's content before it goes in.
    /// A window takes the size of the view it is handed, and a hosting
    /// view that owns no size is zero by zero: the window used to fold to
    /// a 1-point sliver for that moment, squeezing the toolbar's title
    /// into conflicting constraints, before its frame was put back.
    @discardableResult
    static func attach(to window: NSWindow, title: String, subtitle: String = "",
                       make: () -> NSViewController) -> NSViewController {
        if let existing = window.contentViewController { return existing }
        let geometry = Geometry(of: window)
        let controller = make()
        controller.view.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = controller
        geometry.restore(to: window)
        window.title = title
        window.subtitle = subtitle
        return controller
    }

    /// Releases `window`'s content, keeping its frame and size limits.
    static func detach(from window: NSWindow) {
        let geometry = Geometry(of: window)
        let oldBounds = window.contentView?.bounds ?? .zero
        window.contentViewController = nil
        // AppKit may leave a detached controller's view installed as the
        // window content. Replace it so the NSHostingView and ViewGraph are
        // released too, not only their controller wrapper.
        window.contentView = NSView(frame: oldBounds)
        geometry.restore(to: window)
    }

    /// A hosting controller for a window that owns its geometry. The
    /// default sizing options rewrite the window's min/max limits from
    /// the SwiftUI root each time content is attached, and re-measure the
    /// whole scroll content for them on every animation frame; the
    /// window's explicit `minSize` is the limit instead.
    static func hosting<Content: View>(_ rootView: Content) -> NSHostingController<Content> {
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = []
        return hosting
    }

    /// The floating glass card Setup and What's New are: the window's
    /// content IS the plate, with the hosting view inside. The window
    /// supplies its own rounding, so the plate's corner radius stays
    /// square to it. `JRBAR_PLAIN_MATERIAL` swaps in a plain effect view,
    /// as the other glass surfaces do. The plate is a controller of its
    /// own so a closing window drops the whole card, hosting view and all.
    static func glassPlate(around hosting: NSViewController, size: NSSize) -> NSViewController {
        let plate = NSViewController()
        if ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] == nil {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.style = .regular
            glass.cornerRadius = 0
            glass.contentView = hosting.view
            plate.view = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            effect.material = .windowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            plate.view = effect
        }
        plate.addChild(hosting)
        return plate
    }

    /// Back to a pure menu-bar process once the last titled window goes
    /// away. Runs after the close has finished, and only in the accessory
    /// app itself.
    static func retractWhenLastWindowCloses() {
        DispatchQueue.main.async {
            guard let app = NSApp, app.activationPolicy() == .accessory else { return }
            if app.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel }) {
                app.hide(nil)
                app.unhide(nil)
            }
        }
    }

    /// The window's frame and content size limits, captured before its
    /// content changes and put back after.
    @MainActor
    private struct Geometry {
        let frame: NSRect
        let contentMinSize: NSSize
        let contentMaxSize: NSSize

        init(of window: NSWindow) {
            frame = window.frame
            contentMinSize = window.contentMinSize
            contentMaxSize = window.contentMaxSize
        }

        func restore(to window: NSWindow) {
            // Setting the frame can make AppKit derive size limits again
            // from a newly installed controller. Restore the explicit
            // limits last.
            window.setFrame(frame, display: false)
            window.contentMaxSize = contentMaxSize
            window.contentMinSize = contentMinSize
        }
    }
}
