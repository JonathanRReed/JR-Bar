import Foundation
import Testing
@testable import JRBarCore

/// A row whose ask JR-Bar cannot answer says where to answer it, in plain
/// words, and offers to open that app when the daemon named one.
@Suite("Ask answer host")
struct AskAnswerHostTests {
    private func session(_ json: String) throws -> CoreSession {
        try JSONDecoder().decode(CoreSession.self, from: Data(json.utf8))
    }

    @Test("the terminal the daemon found is the app to answer in")
    func terminalWins() throws {
        let row = try session(#"{"id":"gemini:s1","provider":"gemini","terminal":{"app":"Ghostty","bundle_id":"com.mitchellh.ghostty"},"origin":{"kind":"ide","label":"VS Code","bundle_id":"com.microsoft.VSCode"}}"#)
        #expect(AskAnswerHost.app(of: row) == "Ghostty")
        #expect(AskAnswerHost.line(host: "Ghostty") == "Answer this in Ghostty")
        #expect(AskAnswerHost.buttonTitle(host: "Ghostty") == "Open Ghostty")
    }

    @Test("an app or IDE the hook named by bundle id stands in when there is no terminal")
    func originStandsIn() throws {
        let row = try session(#"{"id":"devin:s1","provider":"devin","origin":{"kind":"ide","label":"VS Code","bundle_id":"com.microsoft.VSCode"}}"#)
        #expect(AskAnswerHost.app(of: row) == "VS Code")
    }

    @Test("an origin label with no app behind it is not an app to open")
    func originWithoutAnApp() throws {
        let row = try session(#"{"id":"grok:s1","provider":"grok","origin":{"kind":"cloud","label":"cloud ingest"}}"#)
        #expect(AskAnswerHost.app(of: row) == nil)
    }

    @Test("an unknown host is said plainly and never invented")
    func unknownHost() throws {
        let row = try session(#"{"id":"grok:s2","provider":"grok","terminal":{"app":"  "}}"#)
        #expect(AskAnswerHost.app(of: row) == nil)
        #expect(AskAnswerHost.line(host: nil) == "Answer this in its own window")
        #expect(AskAnswerHost.line(host: "") == "Answer this in its own window")
        #expect(AskAnswerHost.buttonTitle(host: nil) == "Open session")
    }
}
