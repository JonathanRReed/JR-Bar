import Foundation
import Testing
@testable import JRBarCore

/// Launches `scripts/mock-core.py --once` on a temporary socket, connects the
/// real client, and checks the observable model fills in.
@Suite("Mock core integration", .serialized)
struct MockCoreIntegrationTests {
    static var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JRBarCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appending(path: "scripts/mock-core.py")
    }

    /// AF_UNIX paths are capped at 104 bytes, so the socket lives in the
    /// per-user temporary directory rather than a deep scratch path.
    static func temporarySocketPath() -> String {
        let name = "jrbar-test-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    static func launchMock(socket: String, extraArguments: [String] = ["--once"]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path, "--socket", socket] + extraArguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        return process
    }

    static func waitForSocket(_ path: String, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @MainActor
    static func wait(timeout: TimeInterval = 10, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("the model populates from a --once mock, then notices the disconnect")
    @MainActor
    func populatesFromMock() async throws {
        #expect(FileManager.default.fileExists(atPath: Self.scriptURL.path), "mock-core.py is next to the package")
        let socket = Self.temporarySocketPath()
        let mock = try Self.launchMock(socket: socket)
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        #expect(await Self.waitForSocket(socket), "the mock should create its socket")

        let model = CoreModel(socketPath: socket)
        var events: [CoreEvent] = []
        model.onEvent = { events.append($0) }
        model.start()
        defer { model.stop() }

        let populated = await Self.wait {
            model.hello != nil && model.state != nil && model.lights != nil && model.settings != nil
        }
        #expect(populated, "hello, state, lights and settings should all arrive")

        #expect(model.hello?.coreVersion == "0.8.0-mock")
        #expect(model.hello?.capabilities.contains("lights") == true)
        let state = try #require(model.state)
        #expect(state.generation > 0)
        #expect(state.aggregate.mode == "idle")
        #expect(state.sessions.count == 4)
        #expect(model.sessions.count == 3, "workers roll up under their parent")
        #expect(model.sessions.map(\.provider).sorted() == ["claude", "codex", "gemini"])
        #expect(model.devices.map(\.kind).sorted() == ["dot", "pro", "screen_bar"])
        #expect(model.usage.count == 3)
        #expect(model.usage.first { $0.id == "claude" }?.windows.first?.usedPct == 42.0)
        #expect(model.usage.first { $0.id == "codex" }?.isDerived == true)
        let bar = try #require(model.lights?.screenBar)
        #expect(bar.program.contains("repeat"))
        #expect(bar.ledCount == 8)
        #expect(bar.anchor != nil)
        #expect(model.lights?.linked == true)
        #expect(model.settings?.schema == 3)
        #expect(model.settings?.document["virtual_status_device_enabled"]?.boolValue == true)
        #expect(model.settings?.document["colors"]?["blend_mode"]?.stringValue == "round_robin")
        #expect(events.isEmpty)
        #expect(model.lastDecodeFailure == nil)

        // --once closes the socket after the four documents: the client must
        // report that and go back to reconnecting, and the model must keep
        // the last facts it had.
        let dropped = await Self.wait {
            if case .connected = model.connection { return false }
            return true
        }
        #expect(dropped, "the client should notice the socket closing")
        #expect(model.state != nil)
        #expect(model.isLive == false)
        mock.waitUntilExit()
        #expect(mock.terminationStatus == 0)
    }

    @Test("commands round-trip against the timeline mock")
    @MainActor
    func commandsRoundTrip() async throws {
        let socket = Self.temporarySocketPath()
        let mock = try Self.launchMock(socket: socket, extraArguments: ["--step", "60"])
        defer {
            mock.terminate()
            mock.waitUntilExit()
            try? FileManager.default.removeItem(atPath: socket)
        }
        #expect(await Self.waitForSocket(socket))

        let model = CoreModel(socketPath: socket)
        model.start()
        defer { model.stop() }
        #expect(await Self.wait { model.isLive && model.lights != nil })

        let reply = try await model.send("set_brightness", args: ["device": "all", "value": 0.5])
        #expect(reply.ok)
        #expect(reply.result?["value"]?.doubleValue == 0.5)
        #expect(model.inFlightCommands == 0)

        let missing = try await model.send("open_session", args: ["session": "nope"])
        #expect(!missing.ok)
        #expect(missing.error?.code == "not_found")

        // The brightness write is reflected in the next state document.
        #expect(await Self.wait {
            model.devices.first { $0.kind == "pro" }?.brightnessFraction == 0.5
        })

        // The timeline's first step (Claude working) is in flight; the ask
        // opens after 1.5 steps, so with --step 60 it is not here yet.
        #expect(model.openAsks.isEmpty)
    }

    @Test("history lists rows, clear_completed hands back a batch, undo_clear restores it")
    @MainActor
    func historyAndUndo() async throws {
        let socket = Self.temporarySocketPath()
        // Step 5 is "codex completed": the world starts with one finished session.
        let mock = try Self.launchMock(socket: socket, extraArguments: ["--step", "60", "--start-at", "5"])
        defer {
            mock.terminate()
            mock.waitUntilExit()
            try? FileManager.default.removeItem(atPath: socket)
        }
        #expect(await Self.waitForSocket(socket))

        let model = CoreModel(socketPath: socket)
        var events: [CoreEvent] = []
        model.onEvent = { events.append($0) }
        model.start()
        defer { model.stop() }
        #expect(await Self.wait { model.isLive && model.settings != nil })
        #expect(await Self.wait { model.sessions.contains { $0.lifecycle == "completed" } })

        let rows = try await model.listHistory()
        #expect(rows.count >= 12, "seeded rows plus the fast-forwarded steps: \(rows.count)")
        #expect(rows.first!.at >= rows.last!.at, "newest first")
        #expect(Set(rows.map(\.kind)).isSuperset(of: ["started", "asked", "answered", "completed", "failed", "ended"]))
        #expect(rows.contains { $0.unseen }, "the seeded away rows are marked unseen")
        #expect(rows.contains { $0.kind == "answered" && $0.duration != nil })
        let summary = try #require(AwaySummary.make(from: rows), "the fast-forwarded steps ran before any client connected, so they are unseen")
        #expect((summary.counts["completed"] ?? 0) >= 1, "\(summary.counts)")
        #expect(summary.rows.count >= 5, "the seeded away rows plus the fast-forwarded steps")
        #expect(summary.text.hasPrefix("While you were away:"))

        #expect(model.lastClear == nil)
        model.clearCompleted()
        #expect(await Self.wait { model.lastClear != nil })
        #expect(model.canUndoClear)
        #expect(model.lastClear?.batch.hasPrefix("b-") == true)
        #expect(await Self.wait { !model.sessions.contains { $0.lifecycle == "completed" } })

        let reply = try await model.undoClear()
        #expect(reply?.ok == true)
        #expect(reply?.result?["restored"]?.arrayValue?.isEmpty == false)
        #expect(model.lastClear == nil)
        #expect(await Self.wait { model.sessions.contains { $0.lifecycle == "completed" } })

        let stale = try await model.send("undo_clear", args: ["batch": "b-99"])
        #expect(!stale.ok)
        #expect(stale.error?.code == "not_found")
        #expect(events.contains { $0.kind == "completed" } || events.isEmpty, "fast-forwarded events happened before we connected")
    }

    @Test("a missing socket keeps the model offline without errors")
    @MainActor
    func missingSocket() async throws {
        let model = CoreModel(socketPath: Self.temporarySocketPath())
        model.start()
        defer { model.stop() }
        #expect(await Self.wait(timeout: 3) {
            if case .connecting = model.connection { return true }
            return false
        })
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.state == nil)
        #expect(model.isLive == false)
        if case .connecting(let attempt) = model.connection {
            #expect(attempt >= 2, "should be retrying on the backoff schedule")
        } else {
            Issue.record("expected to still be connecting, got \(model.connection)")
        }
    }
}
