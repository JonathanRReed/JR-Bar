import AppKit
import SwiftUI
import Testing
@testable import JRBarUI

@Suite("State dot lifecycle")
@MainActor
struct StateDotLifecycleTests {
    @Test func reduceMotionRemovesTheBreathingView() {
        let baseline = StateDot.activePulses
        let host = NSHostingView(rootView: StateDot(.working).jrbarAccessibility(reduceMotion: true))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 20, height: 20),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = NSView(); window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(StateDot.activePulses == baseline)
        host.rootView = StateDot(.working).jrbarAccessibility(reduceMotion: false)
        host.layoutSubtreeIfNeeded()
        #expect(StateDot.activePulses == baseline + 1)
        host.rootView = StateDot(.working).jrbarAccessibility(reduceMotion: true)
        host.layoutSubtreeIfNeeded()
        #expect(StateDot.activePulses == baseline)
        host.rootView = StateDot(.done).jrbarAccessibility(reduceMotion: false)
        host.layoutSubtreeIfNeeded()
        #expect(StateDot.activePulses == baseline)
    }
}
