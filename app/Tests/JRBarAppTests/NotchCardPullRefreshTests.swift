import AppKit
import Testing
@testable import JRBarApp

@Suite("Notch card pull refresh", .serialized)
@MainActor
struct NotchCardPullRefreshTests {
    private let anchor = NSRect(x: 400, y: 700, width: 200, height: 30)

    private func panel() -> NotchCardPanel {
        let panel = NotchCardPanel(model: makeTestCardModel())
        panel.presentationEnabled = false
        panel.setPinned(true)
        panel.present(under: anchor)
        return panel
    }

    private func pull(_ panel: NotchCardPanel, travel: CGFloat = 12) {
        panel.hosting.beginPull(at: NSPoint(x: 0, y: 0), time: 1)
        panel.hosting.movePull(to: NSPoint(x: 0, y: travel), time: 1.2)
    }

    @Test("a live refresh leaves the gesture and its displayed frame alone")
    func refreshKeepsPull() {
        let panel = panel()
        pull(panel)
        let pulled = panel.frame
        for shift in [10.0, 20, 30] {
            panel.present(under: anchor.offsetBy(dx: shift, dy: -shift))
            #expect(panel.hosting.isPulling)
            #expect(panel.frame == pulled)
        }
        #expect(!panel.isVisible, "fixture panels are never ordered on screen")
    }

    @Test("a retreat reanchors once to the latest geometry, including clearance")
    func retreatUsesLatestAnchor() {
        let panel = panel()
        pull(panel)
        panel.present(under: anchor.offsetBy(dx: 30, dy: -20), clearance: 5)
        let latest = anchor.offsetBy(dx: 60, dy: -40)
        panel.present(under: latest, clearance: 12)
        panel.hosting.endPull(at: 2)
        #expect(!panel.hosting.isPulling)
        #expect(panel.frame.midX == latest.midX)
        #expect(panel.frame.maxY == latest.minY - NotchCardPanel.anchorGap - 12)
        #expect(!panel.isVisible)
    }

    @Test("a committed pull dismisses without applying a deferred refresh")
    func commitDiscardsRefresh() {
        let panel = panel()
        var closes = 0
        panel.model.onClose = { closes += 1 }
        pull(panel, travel: 50)
        let pulled = panel.frame
        panel.present(under: anchor.offsetBy(dx: 80, dy: -60))
        panel.hosting.endPull(at: 2)
        #expect(closes == 1)
        #expect(!panel.hosting.isPulling)
        #expect(panel.frame == pulled)
        #expect(!panel.isVisible)
    }

    @Test("dismissal aborts a pull and cannot replay the pending presentation")
    func dismissalCancelsPendingRefresh() {
        let panel = panel()
        var closes = 0
        panel.model.onClose = { closes += 1 }
        pull(panel)
        let pulled = panel.frame
        panel.present(under: anchor.offsetBy(dx: 90, dy: -60))
        panel.dismiss()
        panel.hosting.endPull(at: 2)
        #expect(!panel.hosting.isPulling)
        #expect(panel.frame == pulled)
        #expect(closes == 0)
        #expect(!panel.isVisible)
    }

    @Test("unpinning cancels the active pull and deferred geometry")
    func unpinCancelsPendingRefresh() {
        let panel = panel()
        pull(panel)
        let pulled = panel.frame
        panel.present(under: anchor.offsetBy(dx: 90, dy: -60))
        panel.setPinned(false)
        panel.hosting.endPull(at: 2)
        #expect(!panel.hosting.isPulling)
        #expect(panel.frame == pulled)
        #expect(!panel.isPinned)
        #expect(panel.ignoresMouseEvents)
    }
}
