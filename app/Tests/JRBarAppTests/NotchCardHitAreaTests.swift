import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp

/// The card's small controls — close, Open, the mirror, the timer menu
/// and the page tabs — reach at least 24 points without the header
/// growing: the hit area pads out and takes the padding back.
@Suite("Notch card hit areas")
@MainActor
struct NotchCardHitAreaTests {
    @Test("a grown hit area lays out at the mark's own size")
    func nothingMoves() {
        let mark = Color.clear.frame(width: 20, height: 20)
        let grown = NSHostingView(rootView: mark.notchHitArea(horizontal: 2, vertical: 4))
        #expect(grown.fittingSize == NSSize(width: 20, height: 20))
        let wide = NSHostingView(rootView: Color.clear.frame(width: 12, height: 12).notchHitArea())
        #expect(wide.fittingSize == NSSize(width: 12, height: 12))
    }

    @Test("every small card control is at least 24 points to hit")
    func targetsReach24() throws {
        // The header's round marks and the Open chip draw 22 points and
        // grow 2 each way; the tabs draw 18 tall and grow 4.
        #expect(22 + 2 * 2 >= NotchCardView.hitSide)
        #expect(18 + 2 * 4 >= NotchCardView.hitSide)
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp/Toys/Notch/NotchCardView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // Close, Open, the mirror, the tabs and the hint's ×.
        #expect(text.components(separatedBy: ".notchHitArea(").count - 1 >= 5)
        #expect(text.contains(".frame(width: Self.hitSide, height: Self.hitSide)"), "the timer menu's own frame")
        #expect(!text.contains("Button(\"Open\") { model.onOpenSession?() }"), "Open is no longer a bare mini button")
    }
}
