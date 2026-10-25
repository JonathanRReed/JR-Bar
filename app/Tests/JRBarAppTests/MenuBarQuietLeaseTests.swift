import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Automatic Quiet lease acknowledgements", .serialized, .timeLimit(.minutes(2)))
struct MenuBarQuietLeaseTests {
    @Test("a stopped rule releases a late acquisition by its own ID")
    func lateAcquisitionIsReleased() async throws {
        try await withLease { fixture, lease in
            lease.setHolding(true)
            let acquire = try await request(fixture)
            #expect(acquire["action"]?.stringValue == "acquire")
            #expect(acquire["expected_revision"]?.stringValue == "revision-0")
            lease.setHolding(false)
            try await fixture.pending(1)
            try await fixture.release(result: receipt("acquired", "revision-1"))
            let release = try await request(fixture)
            #expect(release["action"]?.stringValue == "release")
            #expect(release["lease_id"] == acquire["lease_id"])
            #expect(release["expected_revision"] == nil)
            try await fixture.release(result: receipt("released", "revision-2"))
            try #require(await lease.waitUntilIdle())
        }
    }

    @Test("a new activation waits for the old cycle's release")
    func newCycleWaits() async throws {
        try await withLease { fixture, lease in
            lease.setHolding(true)
            let first = try await request(fixture)
            lease.setHolding(false)
            lease.setHolding(true)
            try await fixture.release(result: receipt("acquired", "revision-1"))
            let release = try await request(fixture)
            #expect(release["action"]?.stringValue == "release")
            #expect(release["lease_id"] == first["lease_id"])
            try await fixture.release(result: receipt("released", "revision-2"))
            let next = try await request(fixture)
            #expect(next["action"]?.stringValue == "acquire")
            #expect(next["lease_id"] != first["lease_id"])
            #expect(next["expected_revision"]?.stringValue == "revision-2")
            try await fixture.release(result: receipt("acquired", "revision-3"))
            try #require(await lease.waitUntilIdle())
        }
    }

    @Test("renewal uses the accepted revision while the state echo is old")
    func renewalUsesReceipt() async throws {
        try await withLease { fixture, lease in
            lease.setHolding(true)
            let first = try await request(fixture)
            try await fixture.release(result: receipt("acquired", "revision-1"))
            try #require(await lease.waitUntilIdle())
            #expect(fixture.core.state?.focus?.overrideRevision == "revision-0")
            lease.renew()
            let next = try await request(fixture)
            #expect(next["lease_id"] == first["lease_id"])
            #expect(next["expected_revision"]?.stringValue == "revision-1")
            try await fixture.release(result: receipt("acquired", "revision-2"))
            try #require(await lease.waitUntilIdle())
        }
    }

    @Test("a refused acquisition yields until a later rule activation", arguments: ["conflict", "refused"])
    func refusalYields(_ error: String) async throws {
        try await withLease { fixture, lease in
            lease.setHolding(true)
            _ = try await request(fixture)
            try await fixture.release(error: error)
            try #require(await lease.waitUntilIdle())
            lease.renew()
            lease.resume()
            try await fixture.pending(0)
            if error == "conflict" {
                lease.setHolding(false)
                try await fixture.pending(0)
            }
        }
    }

    @Test("a deferred lease preserves its original precondition and owns no release")
    func deferredHasNoOwnership() async throws {
        try await withLease { fixture, lease in
            lease.setHolding(true)
            _ = try await request(fixture)
            try await fixture.release(result: receipt("deferred", "revision-0"))
            try #require(await lease.waitUntilIdle())
            applyRevision("new-manual", fixture)
            lease.renew()
            let next = try await request(fixture)
            #expect(next["expected_revision"]?.stringValue == "revision-0")
            try await fixture.release(error: "conflict")
            try #require(await lease.waitUntilIdle())
            lease.setHolding(false)
            try await fixture.pending(0)
        }
    }

    @Test("missing lease support waits for a readable revision")
    func missingRevisionWaits() async throws {
        try await withLease { fixture, lease in
            fixture.core.apply(.state(CoreState()))
            lease.setHolding(true)
            #expect(!lease.isChanging)
            try await fixture.pending(0)
            applyRevision("new-daemon", fixture)
            lease.resume()
            let next = try await request(fixture)
            #expect(next["expected_revision"]?.stringValue == "new-daemon")
            try await fixture.release(result: receipt("deferred", "new-daemon"))
            try #require(await lease.waitUntilIdle())
        }
    }

    @Test("incomplete receipts never authorize another renewal", arguments: [JSONValue.null, .bool(true), .string("later")])
    func malformedReceiptYields(_ until: JSONValue) async throws {
        try await withLease { fixture, lease in
            lease.setHolding(true)
            _ = try await request(fixture)
            try await fixture.release(result: ["status": .string("acquired"), "revision": .string("revision-1"), "until": until])
            try #require(await lease.waitUntilIdle())
            lease.renew()
            try await fixture.pending(0)
        }
    }

    @Test("disconnect settles the pending request without an unconditional retry")
    func disconnectSettles() async throws {
        try await withLease { fixture, lease in
            lease.setHolding(true)
            _ = try await request(fixture)
            fixture.core.stop()
            try #require(await lease.waitUntilIdle())
            lease.renew()
            #expect(!lease.isChanging)
            #expect(fixture.core.inFlightCommands == 0)
        }
    }

    @Test("the rule runner coalesces repeated levels and settles a late lease after stop")
    func runnerLifecycle() async throws {
        try await withLease { fixture, _ in
            let runner = MenuBarStateRunner()
            runner.quietLease.connect(to: fixture.core)
            runner.rules = { [MenuBarStateRule(condition: .agentsWorking, effects: [.quietAgents, .quietBar])] }
            runner.absorb(.agentState(.working))
            _ = try await request(fixture)
            runner.absorb(.agentState(.working))
            try await fixture.pending(1)
            runner.stop()
            #expect(runner.outcome == MenuBarStateOutcome())
            try await fixture.release(result: receipt("acquired", "revision-1"))
            let release = try await request(fixture)
            #expect(release["action"]?.stringValue == "release")
            try await fixture.release(result: receipt("released", "revision-2"))
            try #require(await runner.quietLease.waitUntilIdle())
        }
    }

    private func receipt(_ status: String, _ revision: String) -> [String: JSONValue] {
        ["status": .string(status), "revision": .string(revision),
         "until": status == "released" ? .null : .number(20_000)]
    }

    private func applyRevision(_ revision: String, _ fixture: CoreCommandReplyFixture) {
        fixture.core.apply(.state(CoreState(focus: CoreFocus(mode: "off", overrideRevision: revision))))
    }

    private func request(_ fixture: CoreCommandReplyFixture) async throws -> [String: JSONValue] {
        try await fixture.pending(1)
        let reply = try await fixture.core.send("fixture_pending")
        let request = try #require(reply.result?["requests"]?.arrayValue?.first?.objectValue)
        #expect(request["name"]?.stringValue == "quiet_lease")
        return try #require(request["args"]?.objectValue)
    }

    private func withLease(_ body: (CoreCommandReplyFixture, MenuBarQuietLease) async throws -> Void) async throws {
        let fixture = try CoreCommandReplyFixture()
        let lease = MenuBarQuietLease()
        do {
            try await fixture.start()
            applyRevision("revision-0", fixture)
            lease.connect(to: fixture.core)
            try await body(fixture, lease)
            lease.setHolding(false)
            fixture.core.stop()
            #expect(await lease.waitUntilIdle())
            await fixture.stop()
        } catch {
            lease.setHolding(false)
            fixture.core.stop()
            _ = await lease.waitUntilIdle()
            await fixture.stop()
            throw error
        }
    }
}
