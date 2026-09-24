import Foundation
import Testing
@testable import JRBarApp

/// The snail and the hermit crab never pop: stepped at 1/30 s through a
/// whole loop and a turn to chase a pearl, the drawn x never moves more
/// than its speed allows and the body never flips in a single frame.
@Suite("Aquarium sand pets")
struct AquariumSandPetsTests {
    static let width = 1200.0
    static let dt = 1.0 / 30

    /// Checks a sampled run: x in points and the x-scale per frame.
    private static func checkNoPop(_ frames: [(x: Double, facing: Double)], speed: Double,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        let bound = 1.5 * speed * width * dt + 2
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(abs(b.x - a.x) <= bound, "moved \(b.x - a.x) pt in a frame",
                    sourceLocation: sourceLocation)
            let flipped = (a.facing > 0) != (b.facing > 0)
            #expect(!(flipped && abs(a.facing) > 0.3 && abs(b.facing) > 0.3),
                    "flipped from \(a.facing) to \(b.facing) in one frame", sourceLocation: sourceLocation)
        }
    }

    @Test("the creeping snail crosses end to end and turns without a pop")
    func snailCreep() {
        var snail = SnailSim(x: 0.5)
        var frames: [(x: Double, facing: Double)] = []
        var turns = 0
        var lastSign = snail.facing > 0
        // Long enough for two crossings and a nap.
        for _ in 0..<Int(600 / Self.dt) {
            snail.step(dt: Self.dt, pearl: nil)
            frames.append((snail.x * Self.width, snail.facing))
            if (snail.facing > 0) != lastSign { turns += 1; lastSign = snail.facing > 0 }
        }
        Self.checkNoPop(frames, speed: SnailSim.hustleSpeed)
        #expect(turns >= 1, "it reached an end and turned")
        #expect(frames.allSatisfy { $0.x >= 0.05 * Self.width && $0.x <= 0.95 * Self.width })
    }

    @Test("a pearl behind the snail: it turns through zero, hustles over and reaches it")
    func snailChase() {
        var snail = SnailSim(x: 0.7)
        snail.facing = 1
        var frames: [(x: Double, facing: Double)] = []
        var reached = false
        for _ in 0..<Int(10 / Self.dt) {
            if snail.step(dt: Self.dt, pearl: 0.3) { reached = true; break }
            frames.append((snail.x * Self.width, snail.facing))
        }
        #expect(reached)
        Self.checkNoPop(frames, speed: SnailSim.hustleSpeed)
        #expect(frames.contains { abs($0.facing) < 0.3 }, "the turn passes through a squash")
        #expect(snail.sinceMeal == 0)
    }

    @Test("an hour with no pearl warms the shell; a nap comes after quiet creeping")
    func snailMood() {
        var snail = SnailSim()
        #expect(snail.huff == 0)
        var napped = false
        for _ in 0..<Int((SnailSim.huffAfter + SnailSim.huffRamp) / 0.25) {
            snail.step(dt: 0.25, pearl: nil)
            if snail.napping { napped = true }
        }
        #expect(napped)
        #expect(snail.huff == 1)
        snail.step(dt: 0.25, pearl: snail.x)
        #expect(snail.huff == 0, "a pearl cheers it right up")
    }

    @Test("Reduce Motion: the snail is simply at the pearl")
    func snailStill() {
        var snail = SnailSim(x: 0.2)
        let there = snail.step(dt: 1, pearl: 0.8, still: true)
        #expect(there)
        #expect(snail.x == 0.8)
    }

    @Test("the hermit crab walks there and back over a full loop without a pop or a flip")
    func crabRounds() {
        let start = 1_800_000_000.0
        var frames: [(x: Double, facing: Double)] = []
        var sawLeft = false, sawRight = false
        for i in 0..<Int(2 * HermitCrabRounds.leg / Self.dt) + 60 {
            let pose = HermitCrabRounds.pose(at: start + Double(i) * Self.dt)
            frames.append((pose.x * Self.width, pose.facing))
            if pose.facing < -0.99 { sawLeft = true }
            if pose.facing > 0.99 { sawRight = true }
        }
        // Its fastest walk: the eased leg's peak speed, 1.5× the mean.
        let peak = 1.5 * (HermitCrabRounds.ends.1 - HermitCrabRounds.ends.0)
            / (HermitCrabRounds.leg * HermitCrabRounds.walkShare)
        Self.checkNoPop(frames, speed: peak)
        #expect(sawLeft && sawRight, "it walked both ways")
    }
}
