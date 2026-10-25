import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Calibration submission")
@MainActor
struct CalibrationSubmissionTests {
    @Test("a second Apply cannot send while the first save is pending", .timeLimit(.minutes(10)))
    func duplicateApply() async throws {
        let submission = CalibrationSubmission()
        var sends = 0
        var replyGate: CheckedContinuation<CoreReply, Never>?
        let first = Task {
            await submission.apply {
                sends += 1
                return await withCheckedContinuation { replyGate = $0 }
            }
        }
        var turns = 0
        while replyGate == nil, turns < 1_000 {
            await Task.yield()
            turns += 1
        }
        let gate = try #require(replyGate)
        #expect(submission.isApplying)
        let secondSaved = await submission.apply {
            sends += 1
            return CoreReply(id: "duplicate", ok: true)
        }
        #expect(!secondSaved)
        #expect(sends == 1)
        gate.resume(returning: CoreReply(id: "first", ok: true))
        #expect(await first.value)
        #expect(!submission.isApplying)
        #expect(submission.error == nil)
    }

    @Test("a refused save stays visible and a successful retry clears it")
    func refusedSaveThenRetry() async {
        let submission = CalibrationSubmission()
        let refused = await submission.apply {
            CoreReply(id: "refused", ok: false,
                      error: CoreReplyError(code: "not_found", message: "The synthetic device disconnected"))
        }
        #expect(!refused)
        #expect(!submission.isApplying)
        #expect(submission.error == "The synthetic device disconnected")
        let retried = await submission.apply { CoreReply(id: "retry", ok: true) }
        #expect(retried)
        #expect(submission.error == nil)
    }

    @Test("a disconnected save permits a retry without claiming success")
    func failedSave() async {
        let submission = CalibrationSubmission()
        let saved = await submission.apply { throw CoreClientError.notConnected }
        #expect(!saved)
        #expect(!submission.isApplying)
        #expect(submission.error?.hasPrefix("Apply failed:") == true)
    }
}
