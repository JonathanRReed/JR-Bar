import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@Suite struct T3CodeRowTests {
    @Test("automatic detection ignores the legacy switch")
    func automaticDetection() throws {
        for enabled in [false, true] {
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(
                "{\"present\":true,\"enabled\":\(enabled),\"running\":true}".utf8))
            let status = try #require(T3CodeStatus.parse(json))
            #expect(status.line == "Detected")
            #expect(status.isSettling)
            var stopped = status
            stopped.running = false
            #expect(stopped.line == "Not running")
            #expect(!stopped.isSettling)
        }
        #expect(T3CodeStatus.parse(nil) == nil)
    }
}
