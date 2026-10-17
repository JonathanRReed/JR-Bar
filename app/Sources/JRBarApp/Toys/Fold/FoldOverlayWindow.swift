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
        // Black under everything: the Duo's void and the closed-lid hold
        // are the clear itself (the renderer re-picks it per draw).
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Render-target-only drawable: the TBDR path never reads it back.
        metalView.framebufferOnly = true
        // The view has no clock of its own. The toy's display-link tick
        // writes the uniforms and calls `drawFrame` in the same turn, so
        // the params and the pixels are one frame, and nothing draws when
        // nothing ticks.
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
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
        renderer.onRedrawNeeded = { [weak self] in self?.drawFrame() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Order in or out. The toy calls this every heartbeat; both halves
    /// are no-ops when nothing changed. Drawing is `drawFrame`'s.
    func setVisible(_ visible: Bool) {
        if visible {
            if !isVisible {
                FoldLog.log.notice("overlay: ordered in")
                // A window coming in has no picture on it yet.
                renderer.invalidateDrawn()
                orderFrontRegardless()
            }
        } else if isVisible {
            FoldLog.log.notice("overlay: ordered out")
            orderOut(nil)
        }
    }

    /// Draws the renderer's current params, once, if they would put
    /// something new on screen. The toy's display-link tick calls it right
    /// after writing them; an owed frame calls it when the GPU has room.
    func drawFrame() {
        guard isVisible, renderer.needsDraw else { return }
        metalView.draw()
    }

    /// The fold is parked with no stream: the renderer drops its picture
    /// and the view its drawables. Both come back with the next fold.
    /// Only ever called with the overlay ordered out.
    func releaseFrames() {
        guard !isVisible else { return }
        renderer.releaseFrames()
        metalView.releaseDrawables()
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
