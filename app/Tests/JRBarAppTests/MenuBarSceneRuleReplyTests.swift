import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Automatic scene reply ownership", .serialized)
struct MenuBarSceneRuleReplyTests {
    @Test("a stopped rule releases a late acquisition without writing the selected scene")
    func lateAcquisitionCannotOutliveRule() async throws {
        try await withLease { fixture, lease in
            let runner = MenuBarStateRunner()
            runner.sceneLease.connect(to: fixture.core)
            runner.rules = { [MenuBarStateRule(condition: .microphoneLive, effects: [.ledScene(scene: "focus")])] }
            runner.absorb(.micInUse(true))
            let first = try await request(fixture)
            runner.stop()
            try await fixture.release(result: receipt("acquired"))
            let release = try await request(fixture)
            #expect(release["action"]?.stringValue == "release")
            #expect(release["lease_id"] == first["lease_id"])
            try await fixture.release(result: receipt("released", scene: "calm", until: nil))
            try #require(await fixture.until { !runner.sceneLease.isChanging })
            #expect(fixture.core.settings?.document["active_scene"]?.stringValue == "calm")
            #expect(!lease.isChanging)
        }
    }

    @Test("a manual same-scene selection supersedes the held rule")
    func identicalManualChoiceWins() async throws {
        try await withLease { fixture, lease in
            lease.setDesiredScene("focus")
            _ = try await request(fixture)
            try await fixture.release(result: receipt("acquired"))
            try #require(await fixture.until { !lease.isChanging })
            apply(fixture, revision: "manual-1", selected: "focus")
            lease.renew()
            let release = try await request(fixture)
            #expect(release["action"]?.stringValue == "release")
            try await fixture.release(result: receipt("released", revision: "manual-1", scene: "focus", until: nil))
            try #require(await fixture.until { !lease.isChanging })
            lease.setDesiredScene(nil)
            try await fixture.pending(0)
            #expect(fixture.core.settings?.document["active_scene"]?.stringValue == "focus")
        }
    }

    @Test("a changed revision still releases the activation's owned overlay")
    func changedRevisionKeepsCleanupOwnership() async throws {
        try await withLease { fixture, lease in
            lease.setDesiredScene("focus")
            let first = try await request(fixture)
            try await fixture.release(result: receipt("acquired"))
            try #require(await fixture.until { !lease.isChanging })
            apply(fixture, revision: "bounded-eviction", effective: "focus", ownerID: first["lease_id"]?.stringValue)
            lease.resume()
            let release = try await request(fixture)
            #expect(release["action"]?.stringValue == "release" && release["lease_id"] == first["lease_id"])
            lease.setDesiredScene(nil)
            try await fixture.release(result: receipt("released", revision: "bounded-eviction", scene: "calm", until: nil))
            try #require(await fixture.until { !lease.isChanging })
            try await fixture.pending(0)
        }
    }

    @Test("a replacement scene waits for the prior activation to release")
    func replacementWaits() async throws {
        try await withLease { fixture, lease in
            lease.setDesiredScene("focus")
            let first = try await request(fixture)
            lease.setDesiredScene("night")
            try await fixture.release(result: receipt("acquired"))
            let release = try await request(fixture)
            #expect(release["action"]?.stringValue == "release" && release["lease_id"] == first["lease_id"])
            try await fixture.release(result: receipt("released", scene: "calm", until: nil))
            let next = try await request(fixture)
            #expect(next["action"]?.stringValue == "acquire" && next["scene"]?.stringValue == "night")
            #expect(next["lease_id"] != first["lease_id"])
            #expect(next["expected_revision"]?.stringValue == "manual-0")
            try await fixture.release(result: receipt("acquired", scene: "night"))
            try #require(await fixture.until { !lease.isChanging })
        }
    }

    @Test("failed release stays owned and retries on the next resume")
    func failedReleaseIsRetained() async throws {
        try await withLease { fixture, lease in
            lease.setDesiredScene("focus")
            let first = try await request(fixture)
            try await fixture.release(result: receipt("acquired"))
            try #require(await fixture.until { !lease.isChanging })
            lease.setDesiredScene(nil)
            _ = try await request(fixture)
            try await fixture.release(error: "refused")
            try #require(await fixture.until { !lease.isChanging })
            try await fixture.pending(0)
            lease.resume()
            let retry = try await request(fixture)
            #expect(retry["action"]?.stringValue == "release" && retry["lease_id"] == first["lease_id"])
            try await fixture.release(result: receipt("released", scene: "calm", until: nil))
            try #require(await fixture.until { !lease.isChanging })
        }
    }

    @Test("a failed acquisition retries the same ID and original manual revision")
    func acquisitionRetryKeepsPrecondition() async throws {
        try await withLease { fixture, lease in
            lease.setDesiredScene("focus")
            let first = try await request(fixture)
            try await fixture.release(error: "refused")
            try #require(await fixture.until { !lease.isChanging })
            try await fixture.pending(0)
            lease.renew()
            let retry = try await request(fixture)
            #expect(retry == first)
            try await fixture.release(result: receipt("acquired"))
            try #require(await fixture.until { !lease.isChanging })
        }
    }

    @Test("expiry can reacquire without adopting a newer manual choice")
    func expiryKeepsManualPrecondition() async throws {
        try await withLease { fixture, lease in
            lease.setDesiredScene("focus")
            let first = try await request(fixture)
            try await fixture.release(result: receipt("acquired"))
            try #require(await fixture.until { !lease.isChanging })
            apply(fixture)
            lease.renew()
            let retry = try await request(fixture)
            #expect(retry == first)
            try await fixture.release(error: "conflict")
            try #require(await fixture.until { !lease.isChanging })
            lease.renew()
            try await fixture.pending(0)
        }
    }

    @Test("a rule waits for a settings frame belonging to the current daemon")
    func missingStateWaits() async throws {
        try await withLease { fixture, lease in
            fixture.core.apply(.hello(CoreHello(stream: "new-peer")))
            lease.setDesiredScene("focus")
            try await fixture.pending(0)
            apply(fixture, stream: "new-peer", revision: "new-manual")
            lease.resume()
            let acquire = try await request(fixture)
            #expect(acquire["expected_revision"]?.stringValue == "new-manual")
            try await fixture.release(result: receipt("acquired", revision: "new-manual"))
            try #require(await fixture.until { !lease.isChanging })
        }
    }

    @Test("a newer manual revision is not borrowed after a retired release")
    func replacementKeepsCapturedManualRevision() async throws {
        try await withLease { fixture, lease in
            lease.setDesiredScene("focus")
            _ = try await request(fixture)
            lease.setDesiredScene("night")
            try await fixture.release(result: receipt("acquired"))
            _ = try await request(fixture)
            apply(fixture, revision: "manual-1", selected: "travel")
            try await fixture.release(result: receipt("released", revision: "manual-1", scene: "travel", until: nil))
            try #require(await fixture.until { !lease.isChanging })
            try await fixture.pending(0)
        }
    }

    @Test("incomplete receipts do not cause an immediate retry loop", arguments: [JSONValue.null, .bool(true), .string("later")])
    func malformedReceiptWaits(_ until: JSONValue) async throws {
        try await withLease { fixture, lease in
            lease.setDesiredScene("focus")
            _ = try await request(fixture)
            var result = receipt("acquired")
            result["until"] = until
            try await fixture.release(result: result)
            try #require(await fixture.until { !lease.isChanging })
            try await fixture.pending(0)
        }
    }

    private func request(_ fixture: CoreCommandReplyFixture) async throws -> [String: JSONValue] {
        try await fixture.pending(1)
        let reply = try await fixture.core.send("fixture_pending")
        let requests = try #require(reply.result?["requests"]?.arrayValue)
        let request = try #require(requests.first?.objectValue)
        #expect(request["name"]?.stringValue == "scene_lease")
        return try #require(request["args"]?.objectValue)
    }

    private func receipt(_ status: String, revision: String = "manual-0", scene: String = "focus", until: Double? = 12345) -> [String: JSONValue] {
        ["status": .string(status), "revision": .string(revision), "scene": .string(scene),
         "until": until.map(JSONValue.number) ?? .null]
    }

    private func apply(_ fixture: CoreCommandReplyFixture, stream: String = "scene-peer", revision: String = "manual-0", selected: String = "calm", effective: String? = nil, ownerID: String? = nil) {
        fixture.core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["active_scene": .string(selected), "scene_state": .object([
                "revision": .string(revision), "selected_scene": .string(selected),
                "effective_scene": .string(effective ?? selected), "lease_id": ownerID.map(JSONValue.string) ?? .null,
                "until": ownerID == nil ? .null : .number(12345),
            ])]))))
    }

    private func withLease(_ body: (CoreCommandReplyFixture, MenuBarSceneLease) async throws -> Void) async throws {
        let fixture = try CoreCommandReplyFixture()
        let lease = MenuBarSceneLease()
        do {
            try await fixture.start()
            fixture.core.apply(.hello(CoreHello(stream: "scene-peer")))
            apply(fixture)
            lease.connect(to: fixture.core)
            try await body(fixture, lease)
            lease.setDesiredScene(nil)
            await fixture.stop()
        } catch {
            lease.setDesiredScene(nil)
            await fixture.stop()
            throw error
        }
    }
}
