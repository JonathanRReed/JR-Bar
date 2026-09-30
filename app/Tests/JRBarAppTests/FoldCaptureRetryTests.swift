import Foundation
import Testing
@testable import JRBarApp

/// When a failed Fold capture start may try again. Pure: the clock is an
/// argument and nothing here starts a stream, so no Screen Recording
/// permission, timer or FoldToy is involved.
@Suite("Fold capture retry")
struct FoldCaptureRetryTests {
    @Test("a fresh retry may start")
    func freshMayStart() {
        let retry = FoldCaptureRetry()
        #expect(retry.mayStart(.capture, at: 100))
        #expect(retry.mayStart(.wallpaper, at: 100))
    }

    @Test("the first failure retries at once: a one-off error or the handoff to the wallpaper costs nothing")
    func firstRetryIsImmediate() {
        var retry = FoldCaptureRetry()
        retry.noteFailure(.capture, at: 100)
        #expect(retry.mayStart(.capture, at: 100))
    }

    @Test("two consecutive failures wait a second")
    func secondFailureWaits() {
        var retry = FoldCaptureRetry()
        retry.noteFailure(.capture, at: 100)
        retry.noteFailure(.capture, at: 100.5)
        #expect(!retry.mayStart(.capture, at: 100.5 + 1 - 0.01))
        #expect(retry.mayStart(.capture, at: 100.5 + 1))
    }

    @Test("the waits run 0, 1, 2, 4, 8, 16, 30 and hold at 30")
    func delaySequence() {
        var retry = FoldCaptureRetry()
        var t = 100.0
        for wait in [0.0, 1, 2, 4, 8, 16, 30, 30, 30] {
            retry.noteFailure(.capture, at: t)
            if wait > 0 {
                #expect(!retry.mayStart(.capture, at: t + wait - 0.01), "\(wait) s not yet up")
            }
            #expect(retry.mayStart(.capture, at: t + wait), "\(wait) s up")
            t += wait
        }
    }

    @Test("a failure more than a minute after the last starts the count over; a minute exactly does not")
    func decay() {
        var retry = FoldCaptureRetry()
        for _ in 0..<4 { retry.noteFailure(.capture, at: 100) }
        #expect(!retry.mayStart(.capture, at: 100 + 4 - 0.01), "the fourth failure waits 4 s")
        retry.noteFailure(.capture, at: 100 + FoldCaptureRetry.decayAfter + 1)
        #expect(retry.mayStart(.capture, at: 100 + FoldCaptureRetry.decayAfter + 1),
                "a long quiet spell: the next failure is a first again")

        var steady = FoldCaptureRetry()
        for _ in 0..<3 { steady.noteFailure(.capture, at: 100) }
        steady.noteFailure(.capture, at: 100 + FoldCaptureRetry.decayAfter)
        let fourth = 100 + FoldCaptureRetry.decayAfter
        #expect(!steady.mayStart(.capture, at: fourth + 4 - 0.01), "60 s exactly is not a spell")
        #expect(steady.mayStart(.capture, at: fourth + 4))
    }

    @Test("a stream that delivers a frame and then dies stays throttled")
    func frameThenDieStaysThrottled() {
        // Time, not a delivered frame, decays the count: dying again
        // soon after a start is the same streak.
        var retry = FoldCaptureRetry()
        var t = 100.0
        var waits: [Double] = []
        for _ in 0..<5 {
            retry.noteFailure(.capture, at: t)
            var wait = 0.0
            while !retry.mayStart(.capture, at: t + wait) { wait += 0.5 }
            waits.append(wait)
            t += wait + 0.25
        }
        #expect(waits == [0, 1, 2, 4, 8], "each early death waits longer, never a fresh start")
    }

    @Test("reset clears the wait")
    func resetClears() {
        var retry = FoldCaptureRetry()
        for _ in 0..<4 { retry.noteFailure(.capture, at: 100) }
        #expect(!retry.mayStart(.capture, at: 100))
        retry.reset()
        #expect(retry.mayStart(.capture, at: 100))
        retry.noteFailure(.capture, at: 100)
        #expect(retry.mayStart(.capture, at: 100), "and the count began again")
    }

    @Test("a failed capture never holds back the wallpaper, and the reverse")
    func otherSourceBypasses() {
        var retry = FoldCaptureRetry()
        for _ in 0..<3 { retry.noteFailure(.capture, at: 100) }
        #expect(!retry.mayStart(.capture, at: 100))
        #expect(retry.mayStart(.wallpaper, at: 100), "a revoked grant moves to the wallpaper at once")
        // The wallpaper failing is its own streak.
        retry.noteFailure(.wallpaper, at: 100)
        #expect(retry.mayStart(.wallpaper, at: 100), "the wallpaper's first failure retries at once")
        retry.noteFailure(.wallpaper, at: 100)
        #expect(!retry.mayStart(.wallpaper, at: 100))
        #expect(retry.mayStart(.capture, at: 100))
    }

    @Test("a clock that ran backwards may start")
    func clockBackwards() {
        var retry = FoldCaptureRetry()
        for _ in 0..<3 { retry.noteFailure(.capture, at: 100) }
        #expect(!retry.mayStart(.capture, at: 100.5))
        #expect(retry.mayStart(.capture, at: 50))
    }
}
