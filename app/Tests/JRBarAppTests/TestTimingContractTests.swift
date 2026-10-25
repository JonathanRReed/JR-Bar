import Foundation
import Testing

@Suite("Swift test timing contract")
struct TestTimingContractTests {
    @Test("tests release owned work instead of sleeping or expiring semaphore holds")
    func noWallClockHolds() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let walker = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        let forbidden = try NSRegularExpression(
            pattern: #"\bDispatchSemaphore\b|\b(?:Task|Thread)\.sleep\s*\(|\b(?:usleep|nanosleep)\s*\(|\.wait\s*\(\s*(?:timeout|until):"#)
        var offenders: [String] = []
        while let file = walker?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let code = try presentationCode(String(contentsOf: file, encoding: .utf8))
            if forbidden.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "Use TestEvents, owned tasks or manual clocks: \(offenders)")
    }
}
