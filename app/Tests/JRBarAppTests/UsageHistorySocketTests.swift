import JRBarTestSupport
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Usage history native socket", .temporaryDirectory, .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["JRBAR_HISTORY_RPC_PROBE"] == "1"))
struct UsageHistorySocketTests {
    private func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        try #require(predicate(), "Native history round trip did not reach the expected state")
    }

    @Test("background failure, explicit retry and cached refresh cross the socket without automatic work")
    func backgroundFailureRoundTrip() async throws {
        let python = try #require(ProcessInfo.processInfo.environment["JRBAR_HISTORY_RPC_PYTHON"])
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let temporary = TestTemporaryDirectory.currentURL
            .appendingPathComponent("jrbar-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let log = temporary.appendingPathComponent("fixture.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        let socket = temporary.appendingPathComponent("s")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [app.appendingPathComponent("scripts/usage-history-rpc-fixture.py").path,
                             "--socket", socket.path]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": temporary.path,
            "TMPDIR": temporary.path, "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": app.deletingLastPathComponent().appendingPathComponent("src").path,
            "XDG_STATE_HOME": temporary.appendingPathComponent("state").path,
            "XDG_CONFIG_HOME": temporary.appendingPathComponent("config").path,
            "XDG_DATA_HOME": temporary.appendingPathComponent("data").path,
            "CODEX_HOME": temporary.appendingPathComponent("codex").path,
            "CLAUDE_CONFIG_DIR": temporary.appendingPathComponent("claude").path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try await until { FileManager.default.fileExists(atPath: socket.path) || !process.isRunning }
        try #require(process.isRunning, "Synthetic history fixture exited before serving")
        let core = CoreModel(socketPath: socket.path)
        core.start()
        defer { core.stop() }
        try await until { core.isLive }
        let store = UsageCenterStore(core: core)
        let provider = try #require(store.providers.first)
        store.readProviderRows = { [] }
        var retries: [@MainActor () -> Void] = []
        store.scheduleColdRetry = { retries.append($0) }
        store.windowDidOpen()
        defer { store.windowDidClose() }
        try await until { store.isScanning(provider) }
        let released = try await core.send("fixture_release_failure")
        #expect(released.ok)
        let message = "Local history could not be refreshed. Try again."
        try await until { store.error(for: provider) == message && !store.isLoading(provider) }
        #expect(!store.isScanning(provider))
        #expect(!store.hasNoLocalRecords(provider))
        let failedCounts = try await core.send("fixture_counts")
        #expect(failedCounts.result?["reads"]?.intValue == 1)
        #expect(failedCounts.result?["observations"]?.intValue == 1)
        #expect(failedCounts.result?["scans"]?.intValue == 1)
        let allowed = try await core.send("fixture_allow_success")
        #expect(allowed.ok)
        let retry = try #require(store.load(provider: provider, force: true))
        await retry.value
        try await until { store.history(for: provider)?.totalTokens == 120 && store.error(for: provider) == nil }
        let recoveredCounts = try await core.send("fixture_counts")
        #expect(recoveredCounts.result?["scans"]?.intValue == 2)
        #expect(recoveredCounts.result?["observations"]?.intValue == 1)
        #expect(!store.isScanning(provider))
        #expect(store.history(for: provider)?.stale == false)
        let retryCount = retries.count
        let prepared = try await core.send("fixture_prepare_refresh")
        #expect(prepared.ok)
        let refresh = try #require(store.load(provider: provider, force: true))
        await refresh.value
        let retained = try #require(store.history(for: provider))
        #expect(retained.totalTokens == 120 && retained.stale && !retained.partial)
        #expect(retained.readingFiles == 0)
        #expect(!store.isScanning(provider) && !store.isLoading(provider))
        #expect(retries.count == retryCount)
        let completed = try await core.send("fixture_release_failure")
        #expect(completed.ok)
        try await until { store.history(for: provider)?.stale == false && !store.isLoading(provider) }
        #expect(store.history(for: provider)?.totalTokens == 120)
        #expect(store.error(for: provider) == nil && !store.isScanning(provider))
        #expect(retries.count == retryCount)
        let completedCounts = try await core.send("fixture_counts")
        #expect(completedCounts.result?["scans"]?.intValue == 3)
        store.windowDidClose()
        core.stop()
        process.terminate()
        try await until { !process.isRunning }
    }
}
