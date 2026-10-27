import JRBarTestSupport
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The file-feed monitor watches the state directory only while it is
/// asked to — the delegate stops it while the daemon is live — and
/// reads at once when it starts again. A scratch folder stands in for
/// the real state directory.
@Suite("Agent state monitor", .temporaryDirectory)
@MainActor
struct AgentStateMonitorTests {
    private func scratch() throws -> URL {
        let url = TestTemporaryDirectory.currentURL
            .appendingPathComponent("jrbar-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ json: String, to folder: URL) throws {
        try Data(json.utf8).write(to: folder.appendingPathComponent("latest.json"), options: .atomic)
    }

    @Test("stopped, the directory's writes are not read; started again, it reads at once")
    func stopAndRestart() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("{}", to: folder)
        var changed: (@MainActor () -> Void)?
        var scheduled: [DispatchWorkItem] = []
        var cancelled = 0
        let monitor = AgentStateMonitor(directory: folder.path, watch: { callback in
            changed = callback
            return { cancelled += 1 }
        }, schedule: { scheduled.append($0) })
        monitor.start()
        #expect(monitor.isWatching)
        await monitor.readTask?.value
        #expect(monitor.detail == "Unrecognised latest.json")

        // Queue a real debounce callback, then stop before it can run.
        changed?()
        let pending = try #require(scheduled.first)
        #expect(scheduled.count == 1)
        let stoppedRead = monitor.readTask
        monitor.stop()
        #expect(cancelled == 1)
        #expect(pending.isCancelled)
        #expect(!monitor.isWatching)
        let now = Date().timeIntervalSince1970
        try write(#"{"agents":{"lifecycle_counts":{"active":1}},"updated_at":\#(now)}"#, to: folder)
        changed?()
        #expect(scheduled.count == 1, "a stopped watcher cannot schedule another read")
        pending.perform()
        #expect(monitor.readTask == stoppedRead, "stopped events must not start another file read")
        #expect(monitor.detail == "Unrecognised latest.json", "a stopped debounce cannot start a read")

        let retiredChange = changed
        monitor.start()
        retiredChange?()
        #expect(scheduled.count == 1, "a retired watcher cannot schedule into the new lifetime")
        await monitor.readTask?.value
        #expect(monitor.state == .working)
        #expect(monitor.detail == "1 working")
        monitor.stop()
    }
}
