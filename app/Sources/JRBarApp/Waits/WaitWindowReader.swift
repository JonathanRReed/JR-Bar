import AppKit
import SwiftUI

/// Reports whether the window hosting a wait's orb or beam is on screen
/// (its occlusion state, re-read whenever AppKit says it changed), so a
/// window kept alive but ordered out — the Dock's preview, the Data
/// Hoarder after its close — runs no clock for it.
///
/// Unlike `WindowVisibilityReader`, a probe that leaves its window says
/// nothing. SwiftUI replaces the probe as the orb it rides on redraws
/// (measured on macOS 26: a new probe joins the window, then the old one
/// leaves), so a leaving probe's "no window, so visible" arrived last and
/// set the orb running again in a hidden window. Only a probe in a window
/// reports, and it reports that window's state; with no window at all (an
/// offscreen host, a test) nothing is reported and the host's default —
/// on screen — stands.
struct WaitWindowReader: NSViewRepresentable {
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
        private var last: Bool?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard let window else { return }
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                      object: window)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                                   name: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window)
            readWindow()
        }

        @objc private func occlusionChanged(_ note: Notification) { readWindow() }

        private func readWindow() {
            guard let window else { return }
            report(window.occlusionState.contains(.visible))
        }

        /// Only edges reach SwiftUI, and out of the layout pass that
        /// moved the view.
        private func report(_ visible: Bool) {
            guard visible != last else { return }
            last = visible
            let onChange = onChange
            DispatchQueue.main.async { onChange?(visible) }
        }

        /// A probe, not a control.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
