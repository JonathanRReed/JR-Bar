import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The grown card's reveal: the header is there from the first frame,
/// and the rows under it count their stagger over the rows actually
/// drawn, so the foot never waits on a row that is not there.
@Suite("Notch card reveal")
@MainActor
struct NotchCardRevealTests {
    @Test("steps are dense over the drawn rows of the Now page, the foot last")
    func denseNowPage() {
        let steps = NotchCardRevealSteps(hint: false, page: .now, sessions: 2, more: false, meters: 1,
                                         privacy: false, media: true, battery: false,
                                         tray: true, timers: true, calendar: true)
        #expect(steps.sessions == 0)
        #expect(steps.meters == 2)
        #expect(steps.media == 3)
        #expect(steps.pageBar == 4, "two sessions, a meter and the media before it")
        #expect(NotchMotion.rowRevealDelay(step: steps.pageBar) == 4 * NotchMotion.rowStagger)
    }

    @Test("an empty card's foot comes straight after the header")
    func emptyCard() {
        let steps = NotchCardRevealSteps(hint: false, page: .now, sessions: 0, more: false, meters: 0,
                                         privacy: false, media: false, battery: false,
                                         tray: true, timers: true, calendar: true)
        #expect(steps.pageBar == 0)
    }

    @Test("a full card's later rows share the last step")
    func fullCardIsCapped() {
        let steps = NotchCardRevealSteps(hint: true, page: .now, sessions: 5, more: true, meters: 3,
                                         privacy: true, media: true, battery: true,
                                         tray: true, timers: true, calendar: true)
        #expect(steps.hint == 0)
        #expect(steps.sessions == 1)
        #expect(steps.pageBar == 13)
        let last = NotchMotion.rowRevealDelay(step: steps.pageBar) + NotchMotion.rowFade
        #expect(abs(last - NotchMotion.revealSpan) < 1e-9, "the foot is opaque 0.24 s after the reveal")
        #expect(NotchMotion.rowRevealDelay(step: steps.battery) == NotchMotion.rowRevealDelay(step: steps.pageBar))
    }

    @Test("the shelf page counts its rows from its first")
    func shelfPage() {
        let steps = NotchCardRevealSteps(hint: false, page: .shelf, sessions: 3, more: false, meters: 2,
                                         privacy: false, media: true, battery: true,
                                         tray: true, timers: true, calendar: true)
        #expect(steps.shelfTray == 0)
        #expect(steps.shelfToggles == 6)
        #expect(steps.pageBar == 7)
    }

    @Test("a sparse shelf page keeps its steps dense — no row waits on one that is not drawn")
    func sparseShelfPage() {
        let steps = NotchCardRevealSteps(hint: false, page: .shelf, sessions: 0, more: false, meters: 0,
                                         privacy: false, media: false, battery: false,
                                         tray: false, timers: false, calendar: false)
        #expect(steps.shelfWeather == 0)
        #expect(steps.shelfReminders == 1)
        #expect(steps.shelfMirror == 2)
        #expect(steps.shelfToggles == 3, "the last drawn row, not a phantom seventh slot")
        #expect(steps.pageBar == 4)
    }

    @Test("the model's steps follow what the card holds")
    func stepsFromTheModel() {
        let model = makeTestCardModel()
        model.rows = [NotchIslandRow(id: "claude:1", label: "fix-tests", provider: "claude", activity: .working)]
        model.meters = [NotchIslandMeter(id: "claude", provider: "claude", window: "5h", percent: 40)]
        let steps = NotchCardRevealSteps(model: model)
        #expect(steps.sessions == 0)
        #expect(steps.meters == 1)
        #expect(steps.pageBar >= 2)
    }

    @Test("the probe warmed before the pin measures the grown card exactly")
    func prewarmedProbeMeasuresTheGrownCard() {
        let model = makeTestCardModel()
        model.rows = [
            NotchIslandRow(id: "claude:1", label: "fix-tests", provider: "claude", activity: .working),
            NotchIslandRow(id: "codex:1", label: "ship-it", provider: "codex", activity: .working),
        ]
        model.meters = [NotchIslandMeter(id: "claude", provider: "claude", window: "5h", percent: 40)]
        let warm = NSHostingView(rootView: NotchCardView(model: model, style: .island, width: 320,
                                                         pinnedLayout: true))
        warm.layoutSubtreeIfNeeded()
        let warmHeight = warm.fittingSize.height
        model.pinned = true
        let pinned = NSHostingView(rootView: NotchCardView(model: model, style: .island, width: 320))
        pinned.layoutSubtreeIfNeeded()
        #expect(warmHeight > 60, "the grown card, not the peek")
        #expect(abs(warmHeight - pinned.fittingSize.height) < 0.5)
        // The warmed probe re-rooted as the pinned card keeps its size.
        warm.rootView = NotchCardView(model: model, style: .island, width: 320)
        warm.layoutSubtreeIfNeeded()
        #expect(abs(warm.fittingSize.height - pinned.fittingSize.height) < 0.5)
        model.pinned = false
    }
}
