import Foundation
import SwiftUI
import Testing
@testable import JRBarApp

/// The ambient motion's pause rules: the shared decorative bars stay in
/// their row and stand still in one frame, and the buddy card's treat
/// burst ticks only while the hearts fly.
@Suite("Decorative motion")
@MainActor
struct DecorativeMotionTests {
    @Test("the bars bounce inside their row, six of them, and t = 0 is the still frame")
    func barsStayInTheirRow() {
        #expect(DecorativeBars.defaultCount == 6, "the live tap's six bands: nothing jumps when it takes over")
        for index in 0..<6 {
            for t in stride(from: 0.0, through: 3.0, by: 0.05) {
                let height = DecorativeBars.barHeight(index: index, at: t, height: 10)
                #expect(height >= 3 && height <= 10)
            }
        }
        let still = (0..<6).map { DecorativeBars.barHeight(index: $0, at: 0, height: 10) }
        #expect(Set(still).count > 1, "the still frame is a stair, not a flat line")
        #expect(DecorativeBars.barHeight(index: 0, at: 0, height: 13) == 13 * 0.3)
    }

    @Test("a burst's schedule runs from the press to the end of the hearts, then rests")
    func burstEnds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(BuddyBurstSchedule.span)
        let frames = Array(BuddyBurstSchedule(end: end).entries(from: start, mode: .normal).prefix(1_000))
        #expect(frames.first == start)
        #expect(frames.last == end, "the last frame is the end itself, where nothing draws")
        #expect(frames.count < 1_000, "the schedule ends")
        #expect(abs(Double(frames.count) - BuddyBurstSchedule.span / BuddyBurstSchedule.frameInterval) <= 2)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("no burst, a finished one or Reduce Motion is one still frame")
    func noBurstIsStill() {
        let now = Date(timeIntervalSince1970: 2_000)
        #expect(Array(BuddyBurstSchedule(end: nil).entries(from: now, mode: .normal)) == [now])
        let finished = now.addingTimeInterval(-5)
        #expect(Array(BuddyBurstSchedule(end: finished).entries(from: now, mode: .normal)) == [now])
        let lowFrequency = Array(BuddyBurstSchedule(end: now.addingTimeInterval(0.9))
            .entries(from: now, mode: .lowFrequency))
        #expect(lowFrequency.count == 2, "a low-frequency pass jumps straight to the end")
    }
}
