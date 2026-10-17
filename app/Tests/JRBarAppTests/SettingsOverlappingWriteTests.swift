import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Settings overlapping writes")
struct SettingsOverlappingWriteTests {
    private let ambient = "auto_dim.ambient"
    private let floor = "auto_dim.ambient.min_fraction"

    private func curve(_ fraction: Double) -> JSONValue {
        .object(["min_fraction": .number(fraction), "lux_floor": .number(10), "lux_ceiling": .number(100)])
    }

    private func store() -> SettingsStore {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-overlap-\(UUID().uuidString).sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["auto_dim": .object(["ambient": curve(0.2)])]))))
        return SettingsStore(core: core)
    }

    @MainActor
    private final class Replies {
        var requests: [(SettingsPath, JSONValue)] = []
        private var pending: [Int: CheckedContinuation<CoreReply, any Error>] = [:]
        private var closed = false

        func write(_ path: SettingsPath, _ value: JSONValue) async throws -> CoreReply {
            guard !closed else { throw CoreClientError.stopped }
            requests.append((path, value))
            let index = requests.count
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }

        func waitFor(_ count: Int) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while requests.count < count, clock.now < deadline { await Task.yield() }
            return requests.count >= count
        }

        func answer(_ index: Int, ok: Bool = true) {
            pending.removeValue(forKey: index)?.resume(returning: CoreReply(
                id: "synthetic-\(index)", ok: ok,
                result: ok ? .object(["value": requests[index - 1].1]) : nil,
                error: ok ? nil : CoreReplyError(code: "busy", message: "Old write refused")))
        }

        func close() {
            closed = true
            let outstanding = Array(pending.values)
            pending.removeAll()
            for reply in outstanding { reply.resume(throwing: CoreClientError.stopped) }
        }
    }

    @Test("an ambient child merges into its pending curve and keeps siblings")
    func parentThenChild() async throws {
        let store = store()
        var writes: [(String, JSONValue)] = []
        store.settingWriter = { path, value in
            writes.append((path.description, value))
            return CoreReply(id: "write", ok: true, result: .object(["value": value]))
        }
        store.set(ambient, curve(0.3), throttled: true)
        store.set(floor, .number(0.7), throttled: true)
        #expect(store.values.double(SettingsPath(floor)) == 0.7)
        #expect(store.values.double("auto_dim.ambient.lux_floor") == 10)
        #expect(store.flush(floor) == nil)
        let task = try #require(store.flush(ambient))
        await task.value
        #expect(writes.count == 1)
        #expect(writes[0].0 == ambient)
        #expect(SettingsDocument(writes[0].1).double("min_fraction") == 0.7)
        #expect(SettingsDocument(writes[0].1).double("lux_ceiling") == 100)
    }

    @Test("a newer whole curve cancels an older throttled child")
    func childThenParent() async throws {
        let store = store()
        var paths: [String] = []
        store.settingWriter = { path, value in
            paths.append(path.description)
            return CoreReply(id: "write", ok: true, result: .object(["value": value]))
        }
        store.set(floor, .number(0.7), throttled: true)
        store.set(ambient, curve(0.4), throttled: true)
        #expect(store.flush(floor) == nil)
        #expect(store.values.double(SettingsPath(floor)) == 0.4)
        let task = try #require(store.flush(ambient))
        await task.value
        #expect(paths == [ambient])
    }

    @Test("a queued obsolete child skips the writer before it starts")
    func obsoleteTaskDoesNotSend() async throws {
        let store = store()
        var paths: [String] = []
        store.settingWriter = { path, value in
            paths.append(path.description)
            return CoreReply(id: "write", ok: true, result: .object(["value": value]))
        }
        store.set(floor, .number(0.7), throttled: true)
        let old = try #require(store.flush(floor))
        store.set(ambient, curve(0.4), throttled: true)
        let current = try #require(store.flush(ambient))
        await old.value
        await current.value
        #expect(paths == [ambient])
        #expect(store.pendingWrites == 0)
    }

    @Test("a started overlapping child settles before the newer parent sends",
          arguments: [true, false])
    func startedChildOrdersParent(oldOK: Bool) async throws {
        let store = store()
        let replies = Replies()
        defer { replies.close() }
        store.settingWriter = { try await replies.write($0, $1) }
        store.set(floor, .number(0.7), throttled: true)
        let old = try #require(store.flush(floor))
        let firstArrived = await replies.waitFor(1)
        try #require(firstArrived)
        store.set(ambient, curve(0.4), throttled: true)
        let current = try #require(store.flush(ambient))
        #expect(replies.requests.count == 1)
        replies.answer(1, ok: oldOK)
        await old.value
        let nextArrived = await replies.waitFor(2)
        try #require(nextArrived)
        #expect(replies.requests.map { $0.0.description } == [floor, ambient])
        #expect(store.lastError == nil)
        #expect(store.values.double(SettingsPath(floor)) == 0.4)
        replies.answer(2)
        await current.value
        #expect(store.pendingWrites == 0)
    }

    @Test("array-index edits merge siblings and invalid indexes are reported")
    func arrayMergeAndInvalidIndex() async throws {
        let store = store()
        var sent: JSONValue?
        store.settingWriter = { _, value in
            sent = value
            return CoreReply(id: "write", ok: true, result: .object(["value": value]))
        }
        store.set("devices", .array([.object(["brightness": .number(0.2), "id": .string("fixture")])]), throttled: true)
        store.set("devices.0.brightness", .number(0.8), throttled: true)
        #expect(store.values.double("devices.0.brightness") == 0.8)
        #expect(store.values.string("devices.0.id") == "fixture")
        store.set("devices.4.brightness", .number(0.9), throttled: true)
        #expect(store.lastError?.contains("not present") == true)
        #expect(store.values.double("devices.0.brightness") == 0.8)
        let task = try #require(store.flush("devices"))
        await task.value
        #expect(SettingsDocument(sent ?? .null).double("0.brightness") == 0.8)
    }

    @Test("a child merged into a started parent waits before resending the parent")
    func startedParentOrdersMergedChild() async throws {
        let store = store()
        let replies = Replies()
        defer { replies.close() }
        store.settingWriter = { try await replies.write($0, $1) }
        store.set(ambient, curve(0.3), throttled: true)
        let old = try #require(store.flush(ambient))
        let firstArrived = await replies.waitFor(1)
        try #require(firstArrived)
        store.set(floor, .number(0.8), throttled: true)
        let current = try #require(store.flush(ambient))
        #expect(replies.requests.count == 1)
        replies.answer(1, ok: false)
        await old.value
        let nextArrived = await replies.waitFor(2)
        try #require(nextArrived)
        #expect(replies.requests.map { $0.0.description } == [ambient, ambient])
        #expect(SettingsDocument(replies.requests[1].1).double("min_fraction") == 0.8)
        #expect(store.lastError == nil)
        replies.answer(2)
        await current.value
    }
}
