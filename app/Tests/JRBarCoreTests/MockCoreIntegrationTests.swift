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

    /// Giving up takes one more poll past the deadline: the model's
    /// updates land on the main actor, and a main thread held longer than
    /// the deadline wakes this poll ahead of the update that arrived
    /// meanwhile. The last sleep queues behind it.
    @MainActor
    static func wait(timeout: TimeInterval = 10, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(20))
        return condition()
    }

    /// What the client handed the model, in order — the four documents
    /// outlive the socket here, where the model rightly lets them go.
    @MainActor
    final class FrameLog {
        var messages: [CoreMessage] = []

        var hello: CoreHello? {
            for case .hello(let value) in messages { return value }
            return nil
        }

        var state: CoreState? {
            for case .state(let value) in messages { return value }
            return nil
        }

        var lights: CoreLights? {
            for case .lights(let value) in messages { return value }
            return nil
        }

        var settings: CoreSettings? {
            for case .settings(let value) in messages { return value }
            return nil
        }
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

        // The model's own client, with every frame noted on its way in:
        // --once drops the socket straight after the four documents, and
        // a dropped socket clears the facts it carried.
        let model = CoreModel(socketPath: socket)
        let frames = FrameLog()
        var events: [CoreEvent] = []
        model.onEvent = { events.append($0) }
        let client = CoreClient(socketPath: socket) { event in
            Task { @MainActor in
                if case .message(let message) = event { frames.messages.append(message) }
                model.handle(event)
            }
        }
        client.start()
        defer { client.stop() }

        let populated = await Self.wait {
            frames.hello != nil && frames.state != nil && frames.lights != nil && frames.settings != nil
        }
        #expect(populated, "hello, state, lights and settings should all arrive")

        let hello = try #require(frames.hello)
        #expect(hello.coreVersion == "0.8.0-mock")
        #expect(hello.capabilities.contains("lights"))
        let state = try #require(frames.state)
        #expect(state.generation > 0)
        #expect(state.aggregate.mode == "idle")
        #expect(state.sessions.count == 4)
        #expect(state.mainSessions.count == 3, "workers roll up under their parent")
        #expect(state.mainSessions.map(\.provider).sorted() == ["claude", "codex", "gemini"])
        #expect(state.devices.map(\.kind).sorted() == ["dot", "pro", "screen_bar"])
        let usage = state.usage?.providers ?? []
        #expect(usage.count == 5)
        #expect(usage.first { $0.id == "claude" }?.windows.first?.usedPct == 42.0)
        #expect(usage.first { $0.id == "codex" }?.isDerived == true)
        let lights = try #require(frames.lights)
        let bar = try #require(lights.screenBar)
        #expect(bar.program.contains("repeat"))
        #expect(bar.ledCount == 8)
        #expect(bar.anchor != nil)
        #expect(lights.linked == true)
        let settings = try #require(frames.settings)
        #expect(settings.schema == 3)
        #expect(settings.document["virtual_status_device_enabled"]?.boolValue == true)
        #expect(settings.document["colors"]?["blend_mode"]?.stringValue == "color_blend")
        #expect(events.isEmpty)
        #expect(model.lastDecodeFailure == nil)

        // --once closes the socket after the four documents: the client must
        // report that and go back to reconnecting, and the model must drop
        // the facts the closed socket carried — the next daemon's are its
        // own — while the settings document and the hello stay.
        let dropped = await Self.wait {
            if case .disconnected = model.connection { return true }
            if case .connecting = model.connection { return true }
            return false
        }
        #expect(dropped, "the client should notice the socket closing")
        #expect(model.state == nil)
        #expect(model.lights == nil)
        #expect(model.settings?.schema == 3)
        #expect(model.hello?.coreVersion == "0.8.0-mock")
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

        // A forgotten send the daemon refuses still leaves a line.
        model.post("open_session", args: ["session": "nope"])
        #expect(await Self.wait { model.lastDecodeFailure?.hasPrefix("open_session") == true })
        #expect(model.logTail.contains { $0.message?.hasPrefix("open_session refused") == true && $0.level == "warn" })

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
        // Step 6 is "codex completed": the world starts with one finished session.
        let mock = try Self.launchMock(socket: socket, extraArguments: ["--step", "60", "--start-at", "6"])
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
