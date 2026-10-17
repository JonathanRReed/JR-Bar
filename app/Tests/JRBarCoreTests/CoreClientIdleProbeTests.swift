import Foundation
import Testing
@testable import JRBarCore

@Suite("Core client idle probes", .serialized)
struct CoreClientIdleProbeTests {
    @Test("idle probes require a settled, current connection with no other command")
    func admission() {
        func eligible(connected: Bool = true, stopped: Bool = false, settled: Bool = true,
                      pending: Int = 0, replay: Bool = false, generation: UInt64 = 7) -> Bool {
            CoreClient.idleProbeEligible(connected: connected, stopped: stopped,
                                         authSettled: settled, pendingCount: pending,
                                         replayPending: replay, generation: generation,
                                         expectedGeneration: 7)
        }
        #expect(eligible())
        #expect(!eligible(connected: false))
        #expect(!eligible(stopped: true))
        #expect(!eligible(settled: false))
        #expect(!eligible(pending: 1))
        #expect(!eligible(replay: true))
        #expect(!eligible(generation: 8))
    }

    @Test("replay blocks probes only before its monotonic deadline")
    func replayDeadline() {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(10))
        #expect(CoreClient.replayIsBusy(replyPending: true, deadline: deadline, now: start))
        #expect(!CoreClient.replayIsBusy(replyPending: true, deadline: deadline, now: deadline))
        #expect(!CoreClient.replayIsBusy(replyPending: false, deadline: deadline, now: start))
        #expect(!CoreClient.replayIsBusy(replyPending: true, deadline: nil, now: start))
    }

    private func replayServer() -> CoreClientTests.ReplayStubCore {
        let server = CoreClientTests.ReplayStubCore(path: CoreClientTests.temporarySocketPath())
        server.hellos = [
            "{\"t\":\"hello\",\"v\":1,\"stream\":\"s1\",\"cursor\":\"s1:ev-1\",\"capabilities\":[]}",
            "{\"t\":\"hello\",\"v\":1,\"stream\":\"s1\",\"cursor\":\"s1:ev-2\",\"capabilities\":[]}",
        ]
        return server
    }

    @Test("a lost replay reply cannot suppress idle probes forever")
    func lostReplayReply() async throws {
        let server = replayServer()
        try server.start()
        defer { server.stop() }
        let events = CoreClientTests.EventLog()
        let client = CoreClient(socketPath: server.path, replyTimeout: 0.2,
                                idleProbeInterval: 0.05) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await CoreClientTests.wait {
            events.events.contains { if case .message(.hello) = $0 { return true }; return false }
        })
        server.dropClient()
        try #require(await CoreClientTests.wait {
            server.receivedCommands.count >= 2 && server.receivedCommands[1].contains("ping")
        })
        #expect(Array(server.receivedCommands[1].prefix(2)) == ["replay_events", "ping"])
        #expect(await CoreClientTests.wait { server.receivedCommands.count >= 3 })
    }

    @Test("a replay reply arriving after its busy deadline still delivers events")
    func lateReplayReply() async throws {
        let server = replayServer()
        try server.start()
        defer { server.stop() }
        let events = CoreClientTests.EventLog()
        let client = CoreClient(socketPath: server.path, replyTimeout: 0.2,
                                idleProbeInterval: 0.05) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await CoreClientTests.wait {
            events.events.contains { if case .message(.hello) = $0 { return true }; return false }
        })
        server.dropClient()
        try #require(await CoreClientTests.wait {
            server.receivedCommands.count >= 2 && server.receivedCommands[1].contains("ping")
        })
        let replayID = try #require(client.pendingReplayCommandID)
        server.pushFrame("{\"t\":\"reply\",\"v\":1,\"id\":\"\(replayID)\",\"ok\":true,\"result\":{\"events\":[{\"t\":\"event\",\"v\":1,\"id\":\"ev-2\",\"kind\":\"completed\",\"cursor\":\"s1:ev-2\"}],\"cursor\":\"s1:ev-2\",\"resync_required\":false}}")
        #expect(await CoreClientTests.wait { events.receivedEventIDs == ["ev-2"] })
        #expect(client.isConnected)
        #expect(server.receivedCommands.count == 2)
    }

    @Test("invalid idle probe intervals use the safe default")
    func intervalValidation() {
        for interval in [0, -1, TimeInterval.infinity, TimeInterval.nan] {
            let client = CoreClient(socketPath: "/tmp/jrbar-unused.sock", idleProbeInterval: interval) { _ in }
            #expect(client.idleProbeInterval == 30)
        }
        let client = CoreClient(socketPath: "/tmp/jrbar-unused.sock", idleProbeInterval: 0.05) { _ in }
        #expect(client.idleProbeInterval == 0.05)
    }

    @Test("a daemon silent after hello is probed, disconnected, and retried")
    func silentAfterHello() async throws {
        let server = CoreClientTests.ReplayStubCore(path: CoreClientTests.temporarySocketPath())
        server.hellos = ["{\"t\":\"hello\",\"v\":1,\"capabilities\":[]}"]
        try server.start()
        defer { server.stop() }
        let events = CoreClientTests.EventLog()
        let client = CoreClient(socketPath: server.path, replyTimeout: 0.15,
                                idleProbeInterval: 0.05) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await CoreClientTests.wait { !events.disconnectReasons.isEmpty })
        #expect(server.receivedCommands.first == ["ping"])
        #expect(await CoreClientTests.wait { server.receivedCommands.count >= 2 })
    }

    @Test("a quiet daemon answering idle pings stays connected")
    func quietResponsiveDaemon() async throws {
        let server = CoreClientTests.ReplayStubCore(path: CoreClientTests.temporarySocketPath())
        server.hellos = ["{\"t\":\"hello\",\"v\":1,\"capabilities\":[]}"]
        server.replyToCommands = true
        try server.start()
        defer { server.stop() }
        let events = CoreClientTests.EventLog()
        let client = CoreClient(socketPath: server.path, replyTimeout: 0.15,
                                idleProbeInterval: 0.05) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await CoreClientTests.wait { (server.receivedCommands.first?.count ?? 0) >= 3 })
        #expect(events.disconnectReasons.isEmpty)
        #expect(client.isConnected)
        #expect(server.receivedCommands.count == 1)
    }

    @Test("a command admitted during an idle probe keeps its own deadline")
    func commandDuringProbe() async throws {
        let server = CoreClientTests.ReplayStubCore(path: CoreClientTests.temporarySocketPath())
        server.hellos = ["{\"t\":\"hello\",\"v\":1,\"capabilities\":[]}"]
        try server.start()
        defer { server.stop() }
        let events = CoreClientTests.EventLog()
        let client = CoreClient(socketPath: server.path, replyTimeout: 1,
                                idleProbeInterval: 0.05) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await CoreClientTests.wait { server.receivedCommands.first == ["ping"] })
        let usage = Task { try await client.send(name: "usage_history", timeout: 10) }
        defer { usage.cancel() }
        try #require(await CoreClientTests.wait { client.pendingCommandCount == 2 })
        // The ping retired at its deadline. The usage command is still
        // waiting, and later ticks cannot admit another idle ping.
        try #require(await CoreClientTests.wait { client.pendingCommandCount == 1 })
        #expect(events.disconnectReasons.isEmpty)
        #expect(client.isConnected)
        #expect(server.receivedCommands.first == ["ping", "usage_history"])
        usage.cancel()
        _ = try? await usage.value
    }
}
