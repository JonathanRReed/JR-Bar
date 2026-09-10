import Foundation
import Testing
@testable import JRBarCore

@Suite("Panel layout")
struct PanelLayoutTests {
    typealias L = PanelLayout
    static let tall: Double = 2000   // no screen cap in play

    @Test("a short panel is its fixed parts plus whole lists, nothing scrolls")
    func small() {
        let content = L.Content(asks: 0, sessions: 3, hasWhyRow: true, usageProviders: 2)
        let layout = L.compute(content: content, screenHeight: Self.tall)
        #expect(layout.sessionsHeight == 3 * L.sessionRowHeight + 2 * L.rowSpacing + L.listBottomPadding)
        #expect(layout.usageHeight == 2 * L.usageRowHeight + L.usageRowSpacing)
        #expect(layout.sessionsScroll == false)
        #expect(layout.usageScroll == false)
        #expect(layout.totalHeight == L.fixedHeight(content) + layout.sessionsHeight + layout.usageHeight)
        #expect(L.fixedHeight(content) == 40 + 1 + 26 + 30 + 4 + 1 + 26 + 6 + 1 + 82 + 1 + 34)
    }

    @Test("empty lists reserve their empty-state heights")
    func empty() {
        let layout = L.compute(content: L.Content(), screenHeight: Self.tall)
        #expect(layout.sessionsHeight == L.emptySessionsHeight)
        #expect(layout.usageHeight == L.emptyUsageHeight)
        #expect(layout.totalHeight == L.fixedHeight(L.Content()) + L.emptySessionsHeight + L.emptyUsageHeight)
    }

    @Test("an ask row is taller than a session row and counts as one row")
    func asks() {
        let content = L.Content(asks: 1, sessions: 2, hasWhyRow: false, usageProviders: 0)
        let layout = L.compute(content: content, screenHeight: Self.tall)
        #expect(layout.sessionsHeight == L.askRowHeight + 2 * L.sessionRowHeight + 2 * L.rowSpacing + L.listBottomPadding)
        #expect(layout.sessionsScroll == false)
    }

    @Test("more than the cap of sessions scrolls, cut half a row from the end")
    func sessionsCap() {
        let content = L.Content(asks: 0, sessions: 12, hasWhyRow: true, usageProviders: 1)
        let layout = L.compute(content: content, screenHeight: Self.tall)
        #expect(layout.sessionsScroll)
        #expect(layout.sessionsHeight == (7.5 * (L.sessionRowHeight + L.rowSpacing) - L.rowSpacing).rounded())
        #expect(layout.sessionsHeight < L.sessionsContentHeight(content))
        // Exactly the cap's row count does not scroll.
        let seven = L.compute(content: L.Content(sessions: 7, usageProviders: 1), screenHeight: Self.tall)
        #expect(seven.sessionsScroll == false)
        let eight = L.compute(content: L.Content(sessions: 8, usageProviders: 1), screenHeight: Self.tall)
        #expect(eight.sessionsScroll)
    }

    @Test("more than the cap of usage providers scrolls too")
    func usageCap() {
        let layout = L.compute(content: L.Content(sessions: 1, usageProviders: 6), screenHeight: Self.tall)
        #expect(layout.usageScroll)
        #expect(layout.usageHeight == (3.5 * (L.usageRowHeight + L.usageRowSpacing) - L.usageRowSpacing).rounded())
        let three = L.compute(content: L.Content(sessions: 1, usageProviders: 3), screenHeight: Self.tall)
        #expect(three.usageScroll == false)
        #expect(three.usageHeight == 3 * L.usageRowHeight + 2 * L.usageRowSpacing)
    }

    @Test("the panel never exceeds 70% of the screen; both lists give up rows in turn")
    func screenCap() {
        // A 14-inch MacBook Pro: 945 pt visible → 661 pt cap.
        let content = L.Content(asks: 0, sessions: 10, hasWhyRow: true, usageProviders: 6)
        let layout = L.compute(content: content, screenHeight: 945)
        #expect(layout.maxHeight == 661)
        #expect(layout.totalHeight <= 661)
        #expect(layout.sessionsScroll && layout.usageScroll)
        // Sessions kept 5.5 rows, Usage 2.5: neither was crushed to its floor.
        #expect(layout.sessionsHeight == (5.5 * (L.sessionRowHeight + L.rowSpacing) - L.rowSpacing).rounded())
        #expect(layout.usageHeight == (2.5 * (L.usageRowHeight + L.usageRowSpacing) - L.usageRowSpacing).rounded())
        #expect(layout.sessionsHeight >= (L.sessionsMinRows * (L.sessionRowHeight + L.rowSpacing) - L.rowSpacing).rounded())
        #expect(layout.usageHeight >= (L.usageMinRows * (L.usageRowHeight + L.usageRowSpacing) - L.usageRowSpacing).rounded())
    }

    @Test("a whole short list can still be cut to a half row under a tight cap")
    func tightCap() {
        let content = L.Content(asks: 0, sessions: 4, hasWhyRow: true, usageProviders: 3)
        let roomy = L.compute(content: content, screenHeight: Self.tall)
        #expect(roomy.sessionsScroll == false && roomy.usageScroll == false)
        let tight = L.compute(content: content, screenHeight: (roomy.totalHeight - 40) / L.screenFraction)
        #expect(tight.totalHeight <= tight.maxHeight)
        #expect(tight.usageScroll || tight.sessionsScroll)
    }

    @Test("floors hold on an absurdly small screen and the total is still the sum")
    func floors() {
        let content = L.Content(asks: 2, sessions: 20, hasWhyRow: true, usageProviders: 8)
        let layout = L.compute(content: content, screenHeight: 300)
        #expect(layout.sessionsHeight == (L.sessionsMinRows * (L.sessionRowHeight + L.rowSpacing) - L.rowSpacing).rounded())
        #expect(layout.usageHeight == (L.usageMinRows * (L.usageRowHeight + L.usageRowSpacing) - L.usageRowSpacing).rounded())
        #expect(layout.totalHeight == (L.fixedHeight(content) + layout.sessionsHeight + layout.usageHeight).rounded())
        #expect(layout.totalHeight > layout.maxHeight)   // the window clamps to the screen; the lists cannot go lower
    }

    @Test("the same content on the same screen always yields the same layout")
    func deterministic() {
        let content = L.Content(asks: 1, sessions: 9, hasWhyRow: true, usageProviders: 5)
        let a = L.compute(content: content, screenHeight: 945)
        let b = L.compute(content: content, screenHeight: 945)
        #expect(a == b)
        #expect(a.totalHeight == a.totalHeight.rounded())
    }
}
