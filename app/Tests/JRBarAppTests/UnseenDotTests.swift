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

    @Test("History, the Overview and the timeline's live tail draw the dot, not an accent circle",
          arguments: ["HistoryView.swift", "Overview/OverviewView.swift",
                      "Utilities/DataHoarder/ReconstructedTimelineView.swift"])
    func adopted(file: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JRBarApp/\(file)")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("UnseenDot()"))
        #expect(!source.contains("Circle().fill(Color.accentColor)"))
    }
}
