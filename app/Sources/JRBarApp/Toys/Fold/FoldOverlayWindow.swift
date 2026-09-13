import AppKit
import MetalKit
import OSLog

/// The fold's stage: a borderless, click-through panel hung over the
/// built-in screen at screen-saver level. `sharingType = .none` keeps it
/// out of the screen capture, so the warped desktop never sees itself
/// (the capture filter excludes it too, belt and suspenders). It is
/// ordered out whenever the fold is 0, so at rest there is nothing.
@MainActor
final class FoldOverlayWindow: NSPanel {
    let renderer: FoldRenderer
    private let metalView: MTKView

    init(screen: NSScreen) throws {
        renderer = try FoldRenderer(pixelFormat: .bgra8Unorm)
        metalView = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size),
                            device: renderer.device)
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        metalView.colorPixelFormat = .bgra8Unorm
        // Render-target-only drawable: the TBDR path never reads it back.
        metalView.framebufferOnly = true
        // While the overlay is up the view free-runs at the display's
        // refresh — the fold's glide lives on the vsync, not on sensor
        // cadence. Ordered out it pauses: nothing to draw, nothing drawn.
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        // A 0 maximum means "unspecified", not "freeze" — clamp to a
        // real floor so the fold can't stall on an odd panel.
        metalView.preferredFramesPerSecond = min(120, max(60, Int(screen.maximumFramesPerSecond)))
        metalView.delegate = renderer
        metalView.autoresizingMask = [.width, .height]
        contentView = metalView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = .screenSaver
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Order in and start vsync-driven draws, or pause and order out.
    /// The toy calls this every heartbeat; both halves are no-ops when
    /// nothing changed.
    func setVisible(_ visible: Bool) {
        if visible {
            if !isVisible {
                FoldLog.log.notice("overlay: ordered in")
                orderFrontRegardless()
            }
            metalView.isPaused = false
        } else {
            metalView.isPaused = true
            if isVisible {
                FoldLog.log.notice("overlay: ordered out")
                orderOut(nil)
            }
        }
    }

    /// Keeps the panel matched to the built-in screen's frame after a
    /// display-parameters change.
    func reframe() {
        guard let screen = Self.builtinScreen() else { return }
        setFrame(screen.frame, display: true)
    }

    // MARK: Built-in display facts

    /// The built-in display's id, or nil on a desktop Mac and in some
    /// closed-lid states. External displays are never picked.
    static func builtinDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// The `NSScreen` sitting on the built-in display, when it has one.
    static func builtinScreen() -> NSScreen? {
        guard let id = builtinDisplayID() else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    /// Mirroring folds nothing: the overlay would lie about what the
    /// other display shows.
    static func builtinIsMirrored() -> Bool {
        guard let id = builtinDisplayID() else { return false }
        return CGDisplayIsInMirrorSet(id) != 0
    }
}
