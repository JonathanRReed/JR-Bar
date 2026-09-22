import AppKit
import SwiftUI

/// Reports whether the hosting window is on screen at all — its
/// occlusion state, re-read whenever AppKit says it changed. A panel
/// fully under a fullscreen Space or a window reports false, and the
/// buddy's timeline pauses rather than drawing frames nobody can see.
/// No window (an offscreen host, a test) reads as visible: pausing on a
/// guess would freeze a buddy that is actually showing.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { report(true); return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.readWindow() }
            }
            readWindow()
        }

        private func readWindow() {
            report(window?.occlusionState.contains(.visible) ?? true)
        }

        /// Only edges reach SwiftUI — a state write per notification
        /// would re-render for nothing.
        private func report(_ visible: Bool) {
            guard visible != last else { return }
            last = visible
            let onChange = onChange
            // Out of the layout pass that moved the view.
            DispatchQueue.main.async { onChange?(visible) }
        }

        /// A probe, not a control: clicks belong to the buddy above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
