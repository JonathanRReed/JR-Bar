import Foundation
import JRBarCore
import JRBarLEDS
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Reliability and latency")
@MainActor
struct ReliabilityLatencyTests {
    @Test func stateColorDoesNotWaitForTheEntranceFade() throws {
        let program = try LEDSProgram.parse("#ff0000 2s linear\nrepeat", ledCount: 8)
        let previous = Array(repeating: RGB8(r: 0, g: 255, b: 0), count: 8)
        let sampler = LEDSSampler(program: program, initialCodes: previous)
        #expect(sampler.codes(atMilliseconds: 0) == previous)
        let immediate = ScreenBarController.immediateStateCodes(program: program, initial: previous)
        #expect(immediate == Array(repeating: RGB8(r: 255, g: 0, b: 0), count: 8))
    }

    @Test func layoutDiagnosticsNameTheTypeAndProposedSizeOnce() {
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var values: [String] = []
            func append(_ value: String) { lock.withLock { values.append(value) } }
        }
        let lines = Lines()
        LayoutDiagnostics.sink = { lines.append($0) }
        defer { LayoutDiagnostics.sink = nil }
        LayoutDiagnostics.check(CGSize(width: -4, height: 24), viewType: "SyntheticShelf", phase: "proposal")
        LayoutDiagnostics.check(CGSize(width: -4, height: 24), viewType: "SyntheticShelf", phase: "proposal")
        LayoutDiagnostics.check(CGSize(width: 24, height: 24), viewType: "HealthyShelf", phase: "proposal")
        #expect(lines.values.count == 1)
        #expect(lines.values[0].contains("SyntheticShelf") && lines.values[0].contains("-4.0x24.0"))
    }

    @Test func bannerWaitsForStateOrOneDeadlineWithoutPolling() {
        let core = CoreModel()
        let coordinator = EventCoordinator(core: core, hudAnchor: { nil })
        var deadlines: [@MainActor () -> Void] = []
        var banners: [EventDelivery.Notification] = []
        coordinator.scheduleAskBannerDeadline = { deadlines.append($0); return Task {} }
        coordinator.bannerSink = { banners.append($0); _ = $1 }
        let notice = EventDelivery.Notification(identifier: "fixture-ask", title: "Fixture", body: "Needs you",
                                                 category: .ask, session: "fixture")
        coordinator.deliverAskBanner(notice, session: "fixture", request: "request-1")
        #expect(banners.isEmpty && deadlines.count == 1)
        let ask = CoreAsk(session: "fixture", kind: "permission", answerable: true, request: "request-1")
        core.apply(.state(CoreState(asks: [ask])))
        coordinator.deliverReadyAskBanners()
        #expect(banners.map(\.category) == [.ask])
        deadlines[0]()
        #expect(banners.count == 1)
        coordinator.deliverAskBanner(notice, session: "missing", request: "request-2")
        deadlines[1]()
        #expect(banners.map(\.category) == [.ask, .plain])
    }
}
