import Testing
@testable import JRBarCore

@MainActor
@Suite("Command fixture reply clock", .timeLimit(.minutes(10)))
struct CoreCommandReplyClockTests {
    @Test("a held reply expires only when the injected clock reaches its deadline")
    func manualReplyDeadline() async throws {
        let fixture = try CoreCommandReplyFixture()
        do {
            try await fixture.start()
            let request = Task { try await fixture.core.send("quiet") }
            try await fixture.pending(1)
            fixture.replyClock.advance(by: 9)
            #expect(fixture.core.inFlightCommands == 1)
            fixture.replyClock.advance(by: 1)
            do {
                _ = try await request.value
                Issue.record("The held reply missed its manual deadline")
            } catch let error as CoreClientError {
                #expect(error == .timeout)
            }
            #expect(fixture.core.inFlightCommands == 0)
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }
}
