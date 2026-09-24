import AppKit
import SwiftUI

/// What the trackpad and wheel ask of the Graph's camera, in the view's
/// own top-left coordinates.
enum GraphPointerIntent: Equatable {
    /// Two fingers or a wheel: move the map by this much.
    case pan(CGSize)
    /// A pinch, or ⌘ with a scroll: scale by this factor about the point.
    case zoom(CGFloat, at: CGPoint)
    /// A two-finger double tap: toggle between the whole map and 100%.
    case smartZoom(at: CGPoint)

    /// The intent behind one event: a precise (trackpad) scroll pans by
    /// its own deltas, a wheel's line steps pan further, and ⌘ turns
    /// either into a zoom about the pointer.
    static func from(scrollX: CGFloat, scrollY: CGFloat, precise: Bool, command: Bool,
                     at point: CGPoint) -> GraphPointerIntent? {
        guard scrollX != 0 || scrollY != 0 else { return nil }
        if command {
            let step = precise ? scrollY * 0.01 : scrollY * 0.08
            return .zoom(exp(step), at: point)
        }
        let lines: CGFloat = precise ? 1 : 12
        return .pan(CGSize(width: scrollX * lines, height: scrollY * lines))
    }
}

/// Reads scroll, pinch and smart-zoom events over the Graph and hands
/// them to SwiftUI, which has no scroll-wheel hook of its own on macOS.
/// A local monitor scoped to this view's window and frame: an event
/// anywhere else — the sidebar, the inspector, a sheet — passes through
/// untouched. It only watches; it never posts input of its own.
struct GraphPointerReader: NSViewRepresentable {
    let onIntent: (GraphPointerIntent) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onIntent = onIntent
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onIntent = onIntent
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class ReaderView: NSView {
        var onIntent: ((GraphPointerIntent) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        /// A reader, not a control: clicks belong to the Graph above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            let intent: GraphPointerIntent?
            switch event.type {
            case .magnify:
                intent = .zoom(1 + event.magnification, at: point)
            case .smartMagnify:
                intent = .smartZoom(at: point)
            default:
                intent = .from(scrollX: event.scrollingDeltaX, scrollY: event.scrollingDeltaY,
                               precise: event.hasPreciseScrollingDeltas,
                               command: event.modifierFlags.contains(.command), at: point)
            }
            guard let intent else { return false }
            onIntent?(intent)
            return true
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
