import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// The panel's repeating animations live only in an open panel: closing
/// it takes each pulse away with the view that ran it. Counted, never
/// timed.
@Suite("Panel pulses")
@MainActor
struct PanelPulseTests {
    static func host(_ store: PanelStore) -> (NSWindow, NSHostingView<PanelView>) {
        let hosting = NSHostingView(rootView: PanelView(store: store))
        hosting.frame = NSRect(x: 0, y: 0, width: PanelView.width, height: 600)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: PanelView.width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        return (window, hosting)
    }

    @Test("a closed panel runs no pulse")
    func closedPanelIsStill() {
        let rows = [PanelRowsMemoTests.session("a", mode: "waiting"), PanelRowsMemoTests.session("b", mode: "idle")]
        let (_, store) = PanelRowsMemoTests.liveStore(rows)
        // Counted against what is running already: another suite's view
        // may still be alive in this process.
        let baseline = PanelPulses.running
        store.isOpen = true
        let (window, hosting) = Self.host(store)
        hosting.layoutSubtreeIfNeeded()
        #expect(PanelPulses.running > baseline, "an open panel's waiting row pulses")
        store.panelDidClose()
        hosting.layoutSubtreeIfNeeded()
        #expect(PanelPulses.running == baseline, "closing takes every pulse away with its view")
        window.contentView = NSView()
    }

    @Test("marks and the connection dot pulse only while open and moving")
    func pulseRules() {
        #expect(ActivityMark.pulses(.working, reduced: false, active: true))
        #expect(ActivityMark.pulses(.waiting, reduced: false, active: true))
        #expect(!ActivityMark.pulses(.working, reduced: false, active: false))
        #expect(!ActivityMark.pulses(.waiting, reduced: true, active: true))
        #expect(!ActivityMark.pulses(.done, reduced: false, active: true))
        #expect(ConnectionDot.pulses(.connecting, reduced: false, active: true))
        #expect(!ConnectionDot.pulses(.connecting, reduced: false, active: false))
        #expect(!ConnectionDot.pulses(.live, reduced: false, active: true))
    }
}
