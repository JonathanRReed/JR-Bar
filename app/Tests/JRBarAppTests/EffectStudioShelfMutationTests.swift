import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Effect Studio shelf mutations", .serialized)
struct EffectStudioShelfMutationTests {
    @Test("rapid saves retain both programs before settings echoes")
    func rapidSaves() async throws {
        try await withModel { fixture, model, outcomes in
            model.text = "#FF0000"
            model.saveToShelf(named: "First")
            model.text = "#00FF00"
            model.saveToShelf(named: "Second")
            let first = try await request(fixture)
            #expect(names(first) == ["First"])
            try await acknowledge(fixture, first, generation: 2)
            try #require(await fixture.until { outcomes.count == 1 })
            let second = try await request(fixture)
            #expect(names(second) == ["First", "Second"])
            try await acknowledge(fixture, second, generation: 3)
            try #require(await fixture.until { outcomes.count == 2 })
            model.text = "#0000FF"
            model.saveToShelf(named: "Third")
            let third = try await request(fixture)
            #expect(names(third) == ["First", "Second", "Third"])
            try await acknowledge(fixture, third, generation: 4)
            try #require(await fixture.until { outcomes.count == 3 })
        }
    }

    @Test("rapid removals cannot restore an earlier removed program")
    func rapidRemovals() async throws {
        try await withModel(initial: [["First", "#FF0000"], ["Second", "#00FF00"]]) { fixture, model, outcomes in
            model.removeFromShelf(named: "First")
            model.removeFromShelf(named: "Second")
            let first = try await request(fixture)
            #expect(names(first) == ["Second"])
            try await acknowledge(fixture, first, generation: 2)
            try #require(await fixture.until { outcomes.count == 1 })
            let second = try await request(fixture)
            #expect(names(second).isEmpty)
            try await acknowledge(fixture, second, generation: 3)
            try #require(await fixture.until { outcomes.count == 2 })
        }
    }

    @Test("a refused save is excluded from later successful shelf writes")
    func refusedSave() async throws {
        try await withModel { fixture, model, outcomes in
            model.text = "#FF0000"
            model.saveToShelf(named: "Refused")
            model.text = "#00FF00"
            model.saveToShelf(named: "Kept")
            _ = try await request(fixture)
            try await fixture.release(error: "refused")
            try #require(await fixture.until { outcomes.count == 1 })
            let second = try await request(fixture)
            #expect(names(second) == ["Kept"])
            try await acknowledge(fixture, second, generation: 2)
            try #require(await fixture.until { outcomes.count == 2 })
            model.saveToShelf(named: "Last")
            let third = try await request(fixture)
            #expect(names(third) == ["Kept", "Last"])
            try await acknowledge(fixture, third, generation: 3)
            try #require(await fixture.until { outcomes.count == 3 })
        }
    }

    @Test("older settings echoes cannot replace confirmation and newer external settings win")
    func settingsEchoOrder() async throws {
        try await withModel { fixture, model, outcomes in
            model.text = "#FF0000"
            model.saveToShelf(named: "Saved")
            let first = try await request(fixture)
            try await acknowledge(fixture, first, generation: 3)
            try #require(await fixture.until { outcomes.count == 1 })
            settings(fixture, generation: 2, rows: [["Old", "#0000FF"]])
            #expect(model.shelf.map(\.name) == ["Saved"])
            settings(fixture, generation: 4, rows: [["External", "#0000FF"]])
            #expect(model.shelf.map(\.name) == ["External"])
            model.saveToShelf(named: "Next")
            let next = try await request(fixture)
            #expect(names(next) == ["External", "Next"])
            try await acknowledge(fixture, next, generation: 5)
            try #require(await fixture.until { outcomes.count == 2 })
        }
    }

    @Test("an incomplete acknowledgement stops queued writes until newer settings arrive")
    func incompleteAcknowledgement() async throws {
        try await withModel { fixture, model, outcomes in
            model.text = "#FF0000"
            model.saveToShelf(named: "Uncertain")
            model.saveToShelf(named: "Discarded")
            _ = try await request(fixture)
            try await fixture.release(result: ["generation": .number(2)])
            try #require(await fixture.until { outcomes.count == 1 })
            model.saveToShelf(named: "Blocked")
            #expect(outcomes.count == 2)
            let pending = try await fixture.core.send("fixture_pending")
            #expect(pending.result?["count"]?.intValue == 0)
            settings(fixture, generation: 2, rows: [["Accepted", "#0000FF"]])
            model.saveToShelf(named: "Retry")
            let retry = try await request(fixture)
            #expect(names(retry) == ["Accepted", "Retry"])
            try await acknowledge(fixture, retry, generation: 3)
            try #require(await fixture.until { outcomes.count == 3 })
        }
    }

    @Test("a new connection retires pending writes and recovers without a generation bump", arguments: [false, true])
    func replacementStream(sameStream: Bool) async throws {
        try await withModel { fixture, model, outcomes in
            model.text = "#FF0000"
            model.saveToShelf(named: "Old")
            let old = try await request(fixture)
            model.saveToShelf(named: "Discarded")
            fixture.core.apply(.hello(CoreHello(stream: sameStream ? "synthetic-shelf-peer" : "replacement-shelf-peer")))
            settings(fixture, generation: 1, rows: [["External", "#0000FF"]])
            try await acknowledge(fixture, old, generation: 3)
            try #require(await fixture.until { outcomes.count == 1 })
            #expect(model.shelf.map(\.name) == ["External"])
            let pending = try await fixture.core.send("fixture_pending")
            #expect(pending.result?["count"]?.intValue == 0)
            model.saveToShelf(named: "New")
            let next = try await request(fixture)
            #expect(names(next) == ["External", "New"])
            try await acknowledge(fixture, next, generation: 3)
            try #require(await fixture.until { outcomes.count == 2 })
        }
    }

    @Test("a reconnect needs its own settings frame before a shelf write")
    func reconnectWithoutFrame() async throws {
        try await withModel { fixture, model, outcomes in
            model.text = "#FF0000"
            fixture.core.apply(.hello(CoreHello(stream: "synthetic-shelf-peer")))
            model.saveToShelf(named: "Blocked")
            #expect(outcomes.count == 1)
            let pending = try await fixture.core.send("fixture_pending")
            #expect(pending.result?["count"]?.intValue == 0)
            settings(fixture, generation: 1, rows: [["External", "#0000FF"]])
            model.saveToShelf(named: "New")
            let next = try await request(fixture)
            #expect(names(next) == ["External", "New"])
            try await acknowledge(fixture, next, generation: 2)
            try #require(await fixture.until { outcomes.count == 2 })
        }
    }

    @Test("an exact newer settings frame confirms the base after an incomplete reply")
    func frameConfirmsAmbiguousWrite() async throws {
        try await withModel { fixture, model, outcomes in
            model.text = "#FF0000"
            model.saveToShelf(named: "Accepted")
            let first = try await request(fixture)
            settings(fixture, generation: 2, rows: [["Accepted", "#FF0000"]])
            try await fixture.release(result: ["generation": .number(2)])
            try #require(await fixture.until { outcomes.count == 1 })
            model.saveToShelf(named: "Next")
            let next = try await request(fixture)
            #expect(names(first) == ["Accepted"])
            #expect(names(next) == ["Accepted", "Next"])
            try await acknowledge(fixture, next, generation: 3)
            try #require(await fixture.until { outcomes.count == 2 })
        }
    }

    private func settings(_ fixture: CoreCommandReplyFixture, generation: Int, rows: [[String]]) {
        fixture.core.apply(.settings(CoreSettings(generation: generation, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["studio_library": .array(rows.map { .array($0.map(JSONValue.string)) })]))))
    }

    private final class Outcomes { var count = 0 }

    private func names(_ request: [String: JSONValue]) -> [String] {
        LEDSStudioModel.shelf(from: request["args"]?["value"]?.arrayValue).map(\.name)
    }

    private func request(_ fixture: CoreCommandReplyFixture) async throws -> [String: JSONValue] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let reply = try await fixture.core.send("fixture_pending")
            if let first = reply.result?["requests"]?.arrayValue?.first?.objectValue {
                #expect(first["name"]?.stringValue == "set_setting")
                #expect(first["args"]?["path"]?.stringValue == "studio_library")
                return first
            }
            await Task.yield()
        }
        throw CoreClientError.timeout
    }

    private func acknowledge(_ fixture: CoreCommandReplyFixture, _ request: [String: JSONValue], generation: Int) async throws {
        let value = try #require(request["args"]?["value"])
        try await fixture.release(result: ["path": .string("studio_library"), "value": value,
                                           "generation": .number(Double(generation))])
    }

    private func withModel(initial: [[String]] = [],
                           _ body: (CoreCommandReplyFixture, LEDSStudioModel, Outcomes) async throws -> Void) async throws {
        let fixture = try CoreCommandReplyFixture()
        let model = LEDSStudioModel(core: fixture.core, defaults: nil)
        let outcomes = Outcomes()
        model.onStatus = { _ in outcomes.count += 1 }
        model.onError = { _ in outcomes.count += 1 }
        do {
            try await fixture.start()
            fixture.core.apply(.hello(CoreHello(stream: "synthetic-shelf-peer")))
            settings(fixture, generation: 1, rows: initial)
            try await body(fixture, model, outcomes)
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
    }
}
