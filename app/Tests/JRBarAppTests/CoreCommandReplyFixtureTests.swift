import Testing
@testable import JRBarCore

@MainActor
@Suite("Command reply fixture thresholds", .timeLimit(.minutes(2)))
struct CoreCommandReplyFixtureTests {
    @Test("a waiter accepts a count already beyond its threshold")
    func passedThreshold() async throws {
        let fixture = try CoreCommandReplyFixture()
        try await fixture.start()
        do {
            let first = Task { try await fixture.core.send("quiet") }
            let second = Task { try await fixture.core.send("quiet") }
            try await fixture.pending(2)
            try await fixture.pending(1)
            let request = try await fixture.request(count: 1)
            #expect(request["name"]?.stringValue == "quiet")
            try await fixture.release()
            try await fixture.pending(1)
            try await fixture.release()
            #expect(try await first.value.ok)
            #expect(try await second.value.ok)
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }
}
