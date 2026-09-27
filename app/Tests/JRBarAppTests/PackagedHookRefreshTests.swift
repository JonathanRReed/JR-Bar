import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Packaged hook refresh")
struct PackagedHookRefreshTests {
    @Test("fresh setup stamps without installing providers, and an unchanged build does nothing")
    func freshAndUnchanged() {
        #expect(PackagedHookRefresh.action(previous: nil, current: "new", coreLive: true) == .stampOnly)
        #expect(PackagedHookRefresh.action(previous: "new", current: "new", coreLive: true) == .none)
    }

    @Test("an upgrade waits for a live core before asking it to refresh its own integrations")
    func upgradeWaitsForCore() {
        #expect(PackagedHookRefresh.action(previous: "old", current: "new", coreLive: false) == .wait)
        #expect(PackagedHookRefresh.action(previous: "old", current: "new", coreLive: true) == .refresh)
    }

    @Test("a build stamp requires every selected provider to succeed, including an honest empty selection")
    func batchCompletion() {
        let completed = CoreReply(id: "r", ok: true, result: .object([
            "providers": .array([.string("claude"), .string("codex")]),
            "results": .object([
                "claude": .object(["ok": .bool(true)]),
                "codex": .object(["ok": .bool(true)]),
            ]),
        ]))
        #expect(PackagedHookRefresh.completedProviders(in: completed) == ["claude", "codex"])
        let partial = CoreReply(id: "r", ok: true, result: .object([
            "providers": .array([.string("claude"), .string("codex")]),
            "results": .object(["claude": .object(["ok": .bool(true)])]),
        ]))
        #expect(PackagedHookRefresh.completedProviders(in: partial) == nil)
        let empty = CoreReply(id: "r", ok: true, result: .object([
            "providers": .array([]), "results": .object([:]),
        ]))
        #expect(PackagedHookRefresh.completedProviders(in: empty) == [])
        #expect(PackagedHookRefresh.completedProviders(in: CoreReply(id: "r", ok: false)) == nil)
        #expect(PackagedHookRefresh.completedProviders(in: CoreReply(id: "r", ok: true)) == nil)
    }
}
