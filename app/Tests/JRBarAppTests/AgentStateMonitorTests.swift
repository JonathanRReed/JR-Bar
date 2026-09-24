import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// The file-feed monitor watches the state directory only while it is
/// asked to — the delegate stops it while the daemon is live — and
/// reads at once when it starts again. A scratch folder stands in for
/// the real state directory.
@Suite("Agent state monitor")
@MainActor
struct AgentStateMonitorTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ json: String, to folder: URL) throws {
        try Data(json.utf8).write(to: folder.appendingPathComponent("latest.json"), options: .atomic)
    }

    /// Polls until `until` holds. The deadline is generous because the
    /// read runs at utility priority and a full parallel run can starve it
    /// for seconds; a passing wait returns as soon as the condition does.
    private func settle(within seconds: TimeInterval = 30, _ until: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !until(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("stopped, the directory's writes are not read; started again, it reads at once")
    func stopAndRestart() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("{}", to: folder)
        let monitor = AgentStateMonitor(directory: folder.path)
        monitor.start()
        #expect(monitor.isWatching)
        await settle { monitor.detail == "Unrecognised latest.json" }
        #expect(monitor.detail == "Unrecognised latest.json")

        monitor.stop()
        #expect(!monitor.isWatching)
        let now = Date().timeIntervalSince1970
        try write(#"{"agents":{"lifecycle_counts":{"active":1}},"updated_at":\#(now)}"#, to: folder)
        try await Task.sleep(for: .milliseconds(400))
        #expect(monitor.detail == "Unrecognised latest.json", "a stopped monitor reads nothing")

        monitor.start()
        await settle { monitor.state == .working }
        #expect(monitor.state == .working)
        #expect(monitor.detail == "1 working")
        monitor.stop()
    }
}
