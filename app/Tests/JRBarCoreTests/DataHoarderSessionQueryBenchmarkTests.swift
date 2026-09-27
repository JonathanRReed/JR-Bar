import Foundation
import Testing
@testable import JRBarCore

/// Opt-in scale receipt for the session-id index. Run with
/// `JRBAR_ARCHIVE_BENCHMARK=1 swift test --filter DataHoarderSessionQueryBenchmarkTests`.
/// The fixed result size keeps the measured operation the same at every scale.
@Suite("Data Hoarder session query benchmark", .serialized)
struct DataHoarderSessionQueryBenchmarkTests {
    @Test("session lookup at 1k, 10k and 100k records returns the same eight rows")
    func fixedKScales() throws {
        guard ProcessInfo.processInfo.environment["JRBAR_ARCHIVE_BENCHMARK"] == "1" else { return }
        for count in [1_000, 10_000, 100_000] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try DataHoarderCatalog(url: root.appending(path: "catalog.sqlite3"), create: true)
            let target = "session-target"
            try catalog.transaction {
                for index in 0..<count {
                    let selected = index < 8
                    let id = String(format: "%064x", index + 1)
                    try catalog.insert(ArchiveRecord(
                        id: id, name: String(format: "record-%06d", index), sourcePath: "/tmp/fixture",
                        byteCount: 0, importedAt: Date(timeIntervalSinceReferenceDate: Double(index)),
                        sourceModifiedAt: nil,
                        provider: "claude", sessionID: selected ? target : "session-\(index)",
                        segmentCount: 0, captureState: .live))
                }
            }
            let baselineStarted = ContinuousClock.now
            let baseline = try catalog.records().filter { $0.sessionID == target }
            let baselineElapsed = baselineStarted.duration(to: ContinuousClock.now)
            let started = ContinuousClock.now
            let rows = try catalog.records(sessionID: target)
            let elapsed = started.duration(to: ContinuousClock.now)
            #expect(rows.count == 8)
            #expect(rows == baseline)
            #expect(rows.map(\.name) == (0..<8).reversed().map { String(format: "record-%06d", $0) })
            let excluding = try catalog.records(sessionID: target, excluding: rows[0].id)
            #expect(excluding.count == 7)
            print("session query records=\(count) k=8 scan=\(baselineElapsed) indexed=\(elapsed)")
        }
    }
}
