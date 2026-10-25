import Foundation
import JRBarCore
import JRBarLEDS
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Reliability and latency")
@MainActor
struct ReliabilityLatencyTests {
    @Test func pendingPlanFollowsHardwarePhaseWithoutJumpingBack() throws {
        let controller = ScreenBarController(reduceMotionOverride: false, nativeNoticesEnabled: false)
        controller.apply(programText: "#00ff00 0ms")
        controller.apply(programText: "#ff0000 2s linear\nrepeat")
        let initial = Array(repeating: RGB8(r: 0, g: 255, b: 0), count: 8)
        let program = try LEDSProgram.parse("#ff0000 2s linear\nrepeat", ledCount: 8)
        let hardware = LEDSSampler(program: program, initialCodes: initial)
        let plan = try #require(LEDSKeyframePlan.render(sampler: hardware))
        var previousRed: UInt8 = 0
        for ms in [0, 50, 150, 299, 300, 301, 600, 2_000] {
            let fallback = controller.frameCodes(atMilliseconds: ms)
            #expect(fallback == hardware.codes(atMilliseconds: ms))
            let keyframed = plan.codes(atMilliseconds: ms)
            for (live, planned) in zip(fallback, keyframed) {
                #expect(abs(Int(live.r) - Int(planned.r)) <= LEDSKeyframePlan.defaultTolerance)
                #expect(abs(Int(live.g) - Int(planned.g)) <= LEDSKeyframePlan.defaultTolerance)
                #expect(abs(Int(live.b) - Int(planned.b)) <= LEDSKeyframePlan.defaultTolerance)
            }
            #expect(fallback[0].r >= previousRed)
            previousRed = fallback[0].r
        }
        #expect(!controller.panelOnScreen && !controller.clockRunning)
    }

    @Test func healthyLayoutNeverComputesItsTypeName() {
        var reflections = 0
        func name() -> String { reflections += 1; return "LazySyntheticShelf" }
        LayoutDiagnostics.check(CGSize(width: 10, height: 20), viewType: name(), phase: "fixture")
        #expect(reflections == 0)
        LayoutDiagnostics.check(CGSize(width: -1, height: 20), viewType: name(), phase: "fixture")
        #expect(reflections == 1)
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
