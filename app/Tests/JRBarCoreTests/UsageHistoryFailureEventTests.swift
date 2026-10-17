import Testing
@testable import JRBarCore

@Suite("Usage history failure events")
struct UsageHistoryFailureEventTests {
    @Test("failed scan completions decode without becoming History rows")
    func failedCompletion() throws {
        let frame = #"{"t":"event","v":1,"id":"synthetic-failure","kind":"usage_history_failed","provider":"claude","range":"7d","code":"unavailable","message":"Local history could not be refreshed. Try again.","notify":false,"at":1800000000}"#
        guard case .event(let event) = try CoreCodec.decode(line: frame) else {
            Issue.record("Expected a history failure event")
            return
        }
        #expect(event.kind == CoreEvent.usageHistoryFailedKind)
        #expect(event.provider == "claude" && event.range == "7d")
        #expect(event.code == "unavailable")
        #expect(event.message == "Local history could not be refreshed. Try again.")
        #expect(event.notify == false)
        #expect(!EventLogFilter().matches(event))
        #expect(LightLog.entries(from: [event]).isEmpty)
        #expect(EventLogFilter().matches(CoreEvent(id: "synthetic-run-failure", kind: "failed")))
    }
}
