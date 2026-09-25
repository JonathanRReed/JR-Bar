import AppKit
import JRBarCore
import SwiftUI

/// What a drag out of the shelf may do, as a pure rule. The shelf holds
/// references to your files, so the safe answer is a copy: Finder moves
/// a file dragged between folders on one volume, and a shelf that quietly
/// moved the original would lose track of it. ⌘ held as the drag starts
/// asks for the move (Yoink's grammar), and the Move setting makes that
/// the default. Inside JR-Bar — rearranging the strip, a drop on a
/// session row — every operation stays open.
enum ShelfDragOutRule {
    static func mask(policy: ShelfDragOut, commandHeld: Bool,
                     context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication else { return [.copy, .move, .generic] }
        return policy == .move || commandHeld ? .move : .copy
    }

    /// Whether a finished drag takes the chip off the shelf: only with
    /// the setting on, only a drop somewhere outside JR-Bar, and only one
    /// that was accepted.
    static func removes(operation: NSDragOperation, outside: Bool, removeAfter: Bool) -> Bool {
        removeAfter && outside && !operation.isEmpty
    }
}

/// The shelf chips' drag out, in AppKit so the drag can say copy or
/// move — SwiftUI's `onDrag` hands the receiving app every operation,
/// and Finder then moves a file on the same volume. Sits behind a chip
/// as a background that takes no clicks: a press passes through to the
/// chip's own gestures (Quick Look's double-click, ⌘- and ⇧-click
/// selection, the stack's grid), and only a press that moves past a few
/// points on this chip becomes the drag, with the files on the
/// pasteboard as plain file URLs.
struct ShelfDragSource: NSViewRepresentable {
    /// The files the drag carries, read when it starts.
    let urls: @MainActor () -> [URL]
    let policy: @MainActor () -> ShelfDragOut
    /// The drag ended: the operation the destination took, and whether
    /// it landed outside JR-Bar.
    var ended: @MainActor (NSDragOperation, _ outside: Bool) -> Void = { _, _ in }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.source = self
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.source = self
    }

    final class DragView: NSView, NSDraggingSource {
        var source: ShelfDragSource?
        /// Read by `deinit`; set and cleared on the main thread only.
        nonisolated(unsafe) private var monitor: Any?
        private var downPoint: NSPoint?
        private var downInView = false
        /// ⌘ was held when the drag began.
        private var commandHeld = false
        /// The last place AppKit asked about while the drag moved.
        private var lastContext: NSDraggingContext = .withinApplication
        /// Points of travel before a press becomes a drag.
        static let threshold: CGFloat = 4

        /// Clicks go through to the chip's own gestures.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            } else if monitor == nil {
                // Local: only presses in JR-Bar's own windows, and only
                // while this chip is on screen.
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                    guard let self else { return event }
                    return self.handle(event)
                }
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window, window != nil else { return event }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                downInView = takesPress(at: point)
                downPoint = downInView ? point : nil
                return event
            case .leftMouseDragged:
                guard downInView, let down = downPoint,
                      hypot(point.x - down.x, point.y - down.y) >= Self.threshold,
                      let source else { return event }
                downInView = false
                downPoint = nil
                let urls = source.urls()
                guard !urls.isEmpty else { return event }
                commandHeld = event.modifierFlags.contains(.command)
                lastContext = .withinApplication
                beginDraggingSession(with: items(for: urls, at: down), event: event, source: self)
                // The drag is ours now; the chip's gestures never see it.
                return nil
            default:
                downInView = false
                downPoint = nil
                return event
            }
        }

        /// Whether a press at `point` (in this view's coordinates) is on
        /// the part of the chip that shows. The island's card scrolls, and
        /// a chip scrolled out of sight keeps its bounds under whatever is
        /// drawn there now — a press on that must not drag its file. The
        /// scroll view's clip is what `visibleRect` reads; the chip's own
        /// bounds are checked too, since a view that doesn't clip itself
        /// reports the clip's whole reach.
        func takesPress(at point: NSPoint) -> Bool {
            guard !isHiddenOrHasHiddenAncestor else { return false }
            return bounds.contains(point) && visibleRect.contains(point)
        }

        /// One dragging item per file, each wearing the file's icon,
        /// fanned a few points apart under the pointer.
        private func items(for urls: [URL], at point: NSPoint) -> [NSDraggingItem] {
            urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let side: CGFloat = 32
                let offset = CGFloat(min(index, 4)) * 4
                item.setDraggingFrame(NSRect(x: point.x - side / 2 + offset, y: point.y - side / 2 - offset,
                                             width: side, height: side), contents: icon)
                return item
            }
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            lastContext = context
            return ShelfDragOutRule.mask(policy: source?.policy() ?? .copy, commandHeld: commandHeld,
                                         context: context)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            let outside = lastContext == .outsideApplication
            source?.ended(operation, outside)
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
