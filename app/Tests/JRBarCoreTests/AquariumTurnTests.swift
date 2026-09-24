import Foundation
import Testing
@testable import JRBarCore

/// `AquariumTurn` is the U-turn's shape (docs/TOYS.md §Aquarium,
/// Swimming): the yaw comes round continuously, lingers a few frames
/// head-on, the head leads and the tail follows, and the tail kicks
/// out of it — the same for either facing.
@Suite("Aquarium turn")
struct AquariumTurnTests {
    /// Every frame of a turn `seconds` long at 30 fps.
    private func frames(_ seconds: Double, dir0: Double = 1, arc: Double = 1) -> [AquariumTurn.Pose] {
        let n = Int((seconds * 30).rounded())
        return (0...n).map { AquariumTurn.pose(p: Double($0) / Double(n), dir0: dir0, arc: arc) }
    }

    @Test("the side-on share is continuous and changes sign once")
    func continuous() {
        let poses = frames(0.9)
        #expect(poses.first?.c == 1)
        #expect(poses.last?.c == -1)
        for (a, b) in zip(poses, poses.dropFirst()) {
            #expect(abs(b.c - a.c) <= 0.2, "a frame jumped from \(a.c) to \(b.c)")
        }
        let flips = zip(poses, poses.dropFirst()).filter { ($0.c >= 0) != ($1.c >= 0) }
        #expect(flips.count == 1)
        // The facing only ever changes inside the head-on frame.
        for (a, b) in zip(poses, poses.dropFirst()) where a.facing != b.facing {
            #expect(a.isFront && b.isFront)
        }
    }

    @Test("a cruise turn holds the face for four or five frames")
    func headOnFrames() {
        let front = frames(0.9).filter(\.isFront).count
        #expect((4...5).contains(front), "\(front) head-on frames")
        // A lazy idle turn lingers longer; a scare flashes it.
        #expect(frames(1.2).filter(\.isFront).count > front)
        #expect(frames(0.45).filter(\.isFront).count >= 2)
    }

    @Test("the head leads into the turn and the tail follows out of it")
    func headLeads() {
        for k in 1..<100 where k != 50 {
            let p = Double(k) / 100
            let lead = AquariumTurn.pose(p: p, dir0: 1, arc: 1).lead
            if p < 0.5 { #expect(lead > 0, "p \(p)") } else { #expect(lead < 0, "p \(p)") }
        }
        #expect(AquariumTurn.pose(p: 0, dir0: 1, arc: 1).lead == 0)
        #expect(abs(AquariumTurn.pose(p: 1, dir0: 1, arc: 1).lead) < 1e-12)
    }

    @Test("the tail kicks out near the end")
    func tailKick() {
        var best = 0.0
        var at = 0.0
        for k in 0...1000 {
            let p = Double(k) / 1000
            let amp = AquariumTurn.pose(p: p, dir0: 1, arc: 1).ampMul
            if amp > best { best = amp; at = p }
        }
        #expect(abs(at - 0.82) < 0.02)
        #expect(best > 1.5)
        // The beat slows through the middle and the push-off peaks with
        // the kick.
        #expect(AquariumTurn.pose(p: 0.5, dir0: 1, arc: 1).beatMul < 0.75)
        #expect(AquariumTurn.pose(p: 0.82, dir0: 1, arc: 1).kickHz > 1.3)
    }

    @Test("a turn is the same either way round")
    func symmetric() {
        for k in 0...40 {
            let p = Double(k) / 40
            let right = AquariumTurn.pose(p: p, dir0: 1, arc: -1, climb: 0.2)
            let left = AquariumTurn.pose(p: p, dir0: -1, arc: -1, climb: 0.2)
            #expect(abs(right.c + left.c) < 1e-12)
            #expect(right.lead == left.lead)
            #expect(right.pitch == left.pitch)
            #expect(right.ampMul == left.ampMul)
        }
    }

    @Test("the turn levels the climb and bows toward its arc")
    func levelsOut() {
        let mid = AquariumTurn.pose(p: 0.5, dir0: 1, arc: 1, climb: 0.4)
        #expect(abs(mid.pitch - (0.4 * 0.15 + 0.16)) < 1e-9)
        #expect(AquariumTurn.pose(p: 0, dir0: 1, arc: 1, climb: 0.4).pitch == 0.4)
        #expect(AquariumTurn.pose(p: 0.5, dir0: 1, arc: -1).pitch < 0)
    }

    @Test("the pace table and the turn lengths")
    func paceTable() {
        #expect(SwimPace.natural.wanderRate == 0.35)
        #expect(SwimPace.calm.wanderRate < SwimPace.natural.wanderRate)
        #expect(SwimPace.lively.wanderRate > SwimPace.natural.wanderRate)
        #expect(SwimPace.calm.cooldown == 4 && SwimPace.natural.cooldown == 2.5 && SwimPace.lively.cooldown == 1.5)
        for kind in SwimTurn.Kind.allCases {
            let natural = AquariumTurn.duration(for: kind, pace: .natural)
            #expect(abs(AquariumTurn.duration(for: kind, pace: .calm) - natural * 1.2) < 1e-12)
            #expect(abs(AquariumTurn.duration(for: kind, pace: .lively) - natural * 0.8) < 1e-12)
        }
        #expect(AquariumTurn.duration(for: .cruise, pace: .natural) == 0.9)
        #expect(AquariumTurn.duration(for: .wall, pace: .natural) == 0.8)
        #expect(AquariumTurn.duration(for: .idle, pace: .natural) == 1.2)
        for pace in SwimPace.allCases { #expect(!pace.displayName.isEmpty) }
    }

    @Test("Reduce Motion only ever sees a turn's two ends")
    func reduceMotionEnds() {
        var body = SwimBody(x: 0.5, y: 0.5, dir: 1, speed: 0.04, turnRate: 2, energy: 1, homeY: 0.5)
        for k in 0...10 {
            body.turn = SwimTurn(kind: .cruise, start: 0, duration: 0.9, from: 1, arc: 1,
                                 progress: Double(k) / 10)
            let still = AquariumTurn.pose(of: body, still: true)
            #expect(abs(still.c) == 1)
            #expect(still.lead == 0)
            #expect(still.c == (k < 5 ? 1 : -1))
        }
        body.turn = nil
        #expect(AquariumTurn.pose(of: body).c == 1)
    }

    @Test("the swimming speed shortens a turn, never below its shortest")
    func tempoFloor() {
        #expect(AquariumTurn.duration(for: .cruise, pace: .natural, tempo: 1) == 0.9)
        #expect(abs(AquariumTurn.duration(for: .cruise, pace: .natural, tempo: 1.5) - 0.6) < 1e-12)
        for kind in SwimTurn.Kind.allCases {
            for pace in SwimPace.allCases {
                #expect(AquariumTurn.duration(for: kind, pace: pace, tempo: 1.6) >= AquariumTurn.shortestTurn)
            }
        }
        #expect(AquariumTurn.duration(for: .startle, pace: .lively, tempo: 1.6) == AquariumTurn.shortestTurn)
        #expect(frames(AquariumTurn.shortestTurn).filter(\.isFront).count >= 1)
    }
}
