import Foundation
import Testing
@testable import JRBarCore

/// CLIProxyAPI 7.3 names request logs with an 8-hex request counter and,
/// when two collide, an `_N` sequence suffix (`…T120000_1-00000000.log`).
/// The archive picks logs by extension and reads them by content, so the
/// new names change nothing; this holds it to that.
@Suite("CLIProxyAPI log names")
struct CLIProxyLogNameTests {
    static let log = """
    === REQUEST INFO ===
    Version: 7.3.16
    URL: /v1/messages
    Method: POST
    Timestamp: 2026-09-23T12:00:00-05:00

    === RESPONSE ===
    Status: 200
    """

    @Test func theNewCounterAndSequenceNamesAreStillLogs() throws {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let source = try #require(ArchiveSource.defaults(home: home, environment: [:]).first { $0.id == ArchiveSource.cliProxyAPILogs })
        for name in ["v1-messages-2026-09-23T120000_1-00000000.log",
                     "v1-messages-2026-09-23T120000-0000002a.log",
                     "error-v1-messages-2026-08-05T194258.log"] {
            let url = source.root.appendingPathComponent(name)
            #expect(source.extensions.contains(url.pathExtension), "\(name) is not picked up")
        }
        let request = try #require(CLIProxyLogParser.parse(Data(Self.log.utf8)))
        #expect(request.status == 200)
        #expect(request.method == "POST")
    }

    @Test func theNoteAppearsOnlyWhileRequestLoggingIsOff() {
        #expect(CLIProxyLogParser.requestLogNote(config: nil) == nil)
        #expect(CLIProxyLogParser.requestLogNote(config: "port: 8317\nrequest-log: true\n") == nil)
        #expect(CLIProxyLogParser.requestLogNote(config: "request-log: \"true\" # on\n") == nil)
        #expect(CLIProxyLogParser.requestLogNote(config: "port: 8317\nlogging-to-file: false\n") != nil)
        #expect(CLIProxyLogParser.requestLogNote(config: "request-log: false\n") != nil)
        // An indented key belongs to another block.
        #expect(CLIProxyLogParser.requestLogNote(config: "plugins:\n  request-log: true\n") != nil)
    }
}
