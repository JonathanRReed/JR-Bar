import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Synthetic Usage Center activation cost", .temporaryDirectory, .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["JRBAR_USAGE_ACTIVATION_PROBE"] == "1"))
struct UsageCenterActivationCostTests {
    private struct Sample: Encodable {
        let days: Int
        let cache: String
        let iteration: Int
        let configuration: String
        let dataNanoseconds: Int64
        let renderNanoseconds: Int64
        let totalNanoseconds: Int64
        let requests: Int
        let scans: Int
        let records: Int
        let tokens: Int
        let checksum: UInt64
    }

    private func until(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        try #require(predicate(), "Synthetic activation did not reach its expected state")
    }

    @Test(arguments: [7, 365])
    func socketToRenderedWindow(days: Int) async throws {
        let python = try #require(ProcessInfo.processInfo.environment["JRBAR_HISTORY_RPC_PYTHON"])
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let temporary = TestTemporaryDirectory.currentURL.appendingPathComponent("activation", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        let log = temporary.appendingPathComponent("fixture.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let socket = temporary.appendingPathComponent("s")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [app.appendingPathComponent("scripts/usage-center-activation-fixture.py").path,
                             "--socket", socket.path, "--days", String(days)]
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
        try #require(process.isRunning, "Synthetic activation server exited")
        let core = CoreModel(socketPath: socket.path)
        core.start()
        defer { core.stop() }
        try await until { core.isLive && core.settings != nil }
        let provider = try #require(core.usage.first)
        for iteration in -1..<5 {
            let order = iteration.isMultiple(of: 2) ? [false, true] : [true, false]
            for warm in order {
                let reset = try await core.send("fixture_reset_cache")
                try #require(reset.ok)
                if warm {
                    let warmed = try await core.send("fixture_warm")
                    try #require(warmed.ok && warmed.result?["ready"]?.boolValue == true)
                }
                let before = try await core.send("fixture_counts")
                let oldReads = try #require(before.result?["reads"]?.intValue)
                let oldScans = try #require(before.result?["scans"]?.intValue)
                let store = UsageCenterStore(core: core)
                store.readProviderRows = { [] }
                store.scheduleColdRetry = { _ in }
                let clock = ContinuousClock()
                let started = clock.now
                store.windowDidOpen()
                defer { store.windowDidClose() }
                try await until {
                    guard let history = store.history(for: provider) else { return false }
                    return !history.partial && !store.isLoading(provider)
                }
                let dataReady = clock.now
                store.windowDidClose()
                let bitmap = try ProofRender.render(
                    UsageCenterView(store: store).frame(width: 900, height: 1000),
                    size: CGSize(width: 900, height: 1000), dark: false, scale: 1, settle: 0)
                let painted = clock.now
                let history = try #require(store.history(for: provider))
                try #require(store.error(for: provider) == nil)
                try #require(history.records == days && history.days.count == days)
                try #require(history.totalTokens == days * 120)
                try #require(bitmap.pixelsWide == 900 && bitmap.pixelsHigh == 1000)
                let pixels = try #require(bitmap.bitmapData)
                var checksum: UInt64 = 14_695_981_039_346_656_037
                for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
                    checksum = (checksum ^ UInt64(pixels[index])) &* 1_099_511_628_211
                }
                let after = try await core.send("fixture_counts")
                let reads = try #require(after.result?["reads"]?.intValue) - oldReads
                let scans = try #require(after.result?["scans"]?.intValue) - oldScans
                try #require(reads >= 1 && reads <= 2)
                try #require(scans == (warm ? 0 : 1))
                if iteration == -1 {
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: ProofRender.directory.appendingPathComponent(
                        "usage-activation-\(days)-\(warm ? "warm" : "cold").png"))
                }
                #if DEBUG
                let configuration = "debug"
                #else
                let configuration = "release"
                #endif
                let sample = Sample(days: days, cache: warm ? "warm" : "cold", iteration: iteration,
                                    configuration: configuration,
                                    dataNanoseconds: nanoseconds(started.duration(to: dataReady)),
                                    renderNanoseconds: nanoseconds(dataReady.duration(to: painted)),
                                    totalNanoseconds: nanoseconds(started.duration(to: painted)),
                                    requests: reads, scans: scans, records: history.records ?? 0,
                                    tokens: history.totalTokens, checksum: checksum)
                var line = try JSONEncoder().encode(sample)
                line.append(0x0A)
                FileHandle.standardOutput.write(line)
            }
        }
        core.stop()
        process.terminate()
        try await until { !process.isRunning }
    }

    private func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }
}
