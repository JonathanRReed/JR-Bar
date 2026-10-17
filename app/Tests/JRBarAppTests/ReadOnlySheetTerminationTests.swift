import AppKit
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Read-only sheet termination", .serialized)
struct ReadOnlySheetTerminationTests {
    static func comparison() throws -> CoreRunComparison {
        let json = #"{"a":{"id":"synthetic-a","label":"First run","provider":"codex","lifecycle":"ended"},"b":{"id":"synthetic-b","label":"Second run","provider":"claude","lifecycle":"ended"},"shared":{"provider":false,"workspace":false},"warnings":["not_a_controlled_benchmark"]}"#
        return try JSONDecoder().decode(CoreRunComparison.self, from: Data(json.utf8))
    }

    @Test("informational sheets permit quit and restore their window policy", arguments: [false, true])
    func permitsQuit(comparing: Bool) throws {
        let content: AnyView
        if comparing {
            content = AnyView(CompareRunsSheet(comparison: try Self.comparison(), dismiss: {}, usage: SessionUsageStore(core: CoreModel())))
        } else {
            content = AnyView(DoctorSheet(report: .object(["ok": .bool(true), "checks": .array([])]), dismiss: {}))
        }
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 700, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.preventsApplicationTerminationWhenModal = true
        defer { window.contentView = nil; window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        #expect(!window.preventsApplicationTerminationWhenModal,
                "A read-only report must not veto application termination")
        window.contentView = nil
        #expect(window.preventsApplicationTerminationWhenModal)
    }

    @Test("comparison dismissal control", .enabled(if: WindowsRenderProofTests.enabled))
    func comparisonDismissalControl() throws {
        let comparison = try Self.comparison()
        let usage = SessionUsageStore(core: CoreModel())
        try WindowsRenderProofTests.write("compare-runs-dismiss", size: CGSize(width: 720, height: 640)) {
            CompareRunsSheet(comparison: comparison, dismiss: {}, usage: usage)
        }
    }
}
