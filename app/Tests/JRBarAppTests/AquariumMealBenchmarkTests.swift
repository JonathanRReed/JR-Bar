import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Opt-in comparison of the former two meal builds per frame with the
/// returned-meal path. Run with
/// `JRBAR_AQUARIUM_BENCHMARK=1 swift test --filter AquariumMealBenchmarkTests`.
@Suite("Aquarium meal benchmark", .serialized)
@MainActor
struct AquariumMealBenchmarkTests {
    private let size = CGSize(width: 900, height: 560)
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func fixture(fishCount: Int, leaverCount: Int) -> (AquariumView, [Fish]) {
        let roster = (0..<fishCount).map { index in
            Fish(id: "fish-\(index)", label: "fish", providerID: index.isMultiple(of: 2) ? "claude" : "codex",
                 state: index < leaverCount ? .leaving : .swimming,
                 lane: 0.15 + Double(index % 7) * 0.1, speed: 0.08,
                 direction: index.isMultiple(of: 2) ? 1 : -1,
                 stateSince: now.addingTimeInterval(index < leaverCount ? -1 : -100),
                 enteredAt: .distantPast, species: .clownfish)
        }
        let view = AquariumView(fixture: .init(fish: roster, paused: true, night: 0))
        for (index, fish) in roster.enumerated() {
            view.motion.bodies[fish.id] = SwimBody(
                x: 0.1 + Double(index % 10) * 0.08,
                y: 0.2 + Double(index % 6) * 0.1,
                dir: fish.direction, speed: fish.speed,
                turnRate: 1, energy: 1, homeY: fish.lane)
        }
        return (view, roster)
    }

    @Test("6, 24 and 100 fish compare duplicate meal construction with frame reuse")
    func scales() {
        guard ProcessInfo.processInfo.environment["JRBAR_AQUARIUM_BENCHMARK"] == "1" else { return }
        for fishCount in [6, 24, 100] {
            for leaverCount in [0, 1, min(8, fishCount)] {
                let (view, roster) = fixture(fishCount: fishCount, leaverCount: leaverCount)
                let iterations = 1_000
                var duplicateRows = 0
                let duplicateStart = ContinuousClock.now
                for _ in 0..<iterations {
                    duplicateRows += view.completionMeals(in: size, now: now, roster: roster).count
                    duplicateRows += view.completionMeals(in: size, now: now, roster: roster).count
                }
                let duplicateTime = duplicateStart.duration(to: ContinuousClock.now)

                var reusedRows = 0
                let reuseStart = ContinuousClock.now
                for _ in 0..<iterations {
                    reusedRows += view.completionMeals(in: size, now: now, roster: roster).count
                }
                let reuseTime = reuseStart.duration(to: ContinuousClock.now)
                #expect(duplicateRows == reusedRows * 2)
                print("aquarium-meals fish=\(fishCount) leavers=\(leaverCount) iterations=\(iterations) duplicate=\(duplicateTime) reuse=\(reuseTime)")
            }
        }
    }
}
