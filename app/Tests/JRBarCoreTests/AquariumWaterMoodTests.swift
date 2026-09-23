import Foundation
import Testing
@testable import JRBarCore

/// The water reading the fleet: the tightest quota window cools the
/// column, an unreviewed failure hazes it, a reset lands a fading shaft.
@Suite("Aquarium water mood")
struct AquariumWaterMoodTests {
    private static func state(used: [Double?] = [], sessions: [CoreSession] = []) -> CoreState {
        CoreState(generation: 1, sessions: sessions, usage: CoreUsage(providers: used.enumerated().map {
            CoreProviderUsage(id: "p\($0.offset)", windows: [
                CoreUsageWindow(key: "five-hour", name: "5h", usedPct: $0.element, resetsAt: 9_000_000),
            ])
        }))
    }

    @Test("calm until the tightest window passes 70%, fully cool by 95%")
    func low() {
        #expect(AquariumWaterMood.base(nil) == .calm)
        #expect(AquariumWaterMood.base(Self.state()) == .calm)
        #expect(AquariumWaterMood.base(Self.state(used: [40, 70])).low == 0)
        #expect(AquariumWaterMood.base(Self.state(used: [82.5, 10])).low == 0.5)
        #expect(AquariumWaterMood.base(Self.state(used: [99])).low == 1)
        #expect(AquariumWaterMood.base(Self.state(used: [nil])).low == 0, "no reading is not a low one")
    }

    @Test("a creeping window moves the mood in twentieths, not every tenth of a percent")
    func quantized() {
        let a = AquariumWaterMood.base(Self.state(used: [80.0]))
        let b = AquariumWaterMood.base(Self.state(used: [80.4]))
        #expect(a == b)
    }

    @Test("an unreviewed failure hazes the water; a reviewed one doesn't")
    func cloud() {
        let failed = CoreSession(id: "x", provider: "claude", lifecycle: "failed")
        #expect(AquariumWaterMood.base(Self.state(sessions: [failed])).cloud == 1)
        var reviewed = failed
        reviewed.axes = CoreSessionAxes(review: "reviewed")
        #expect(AquariumWaterMood.base(Self.state(sessions: [reviewed])).cloud == 0)
        let working = CoreSession(id: "w", provider: "claude", mode: "tool_running")
        #expect(AquariumWaterMood.base(Self.state(sessions: [working])).cloud == 0)
    }

    @Test("a reset's shaft lands full and eases out over five minutes")
    func shaft() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let calm = AquariumWaterMood.calm
        #expect(calm.with(resetAt: nil, now: reset).shaft == 0)
        #expect(calm.with(resetAt: reset, now: reset).shaft == 1)
        let half = calm.with(resetAt: reset, now: reset.addingTimeInterval(150)).shaft
        #expect(abs(half - 0.5) < 0.001)
        #expect(calm.with(resetAt: reset, now: reset.addingTimeInterval(300)).shaft == 0)
        #expect(calm.with(resetAt: reset, now: reset.addingTimeInterval(-5)).shaft == 0,
                "a reset from the future is a clock hiccup")
        let low = AquariumWaterMood(low: 0.5, cloud: 1)
        #expect(low.with(resetAt: reset, now: reset).low == 0.5, "the shaft adds, it doesn't replace")
    }
}
