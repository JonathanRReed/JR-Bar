import AppKit
import SwiftUI
import Testing
@testable import JRBarApp

/// The unseen dot is systemBlue at five points, whatever accent colour
/// the Mac has picked.
@Suite("Unseen dot")
@MainActor
struct UnseenDotTests {
    @Test("the dot is a fixed system blue, not the accent colour")
    func fixedBlue() {
        #expect(UnseenDot.fill == NSColor.systemBlue)
        #expect(UnseenDot.fill != NSColor.controlAccentColor)
    }

    @Test("the dot lays out at its five-point diameter")
    func size() {
        let host = NSHostingView(rootView: UnseenDot())
        #expect(host.fittingSize == CGSize(width: UnseenDot.diameter, height: UnseenDot.diameter))
        #expect(UnseenDot.diameter == 5)
    }
}
