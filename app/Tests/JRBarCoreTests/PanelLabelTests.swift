import Foundation
import Testing
@testable import JRBarCore

@Suite("Usage window labels")
struct UsageWindowLabelTests {
    @Test("the daemon's window ids map to the short names")
    func ids() {
        #expect(UsageWindowLabel.short(id: "five_hour", name: nil) == "5h")
        #expect(UsageWindowLabel.short(id: "5-hour", name: nil) == "5h")
        #expect(UsageWindowLabel.short(id: "five-hour", name: "Five hour window") == "5h")
        #expect(UsageWindowLabel.short(id: "seven_day", name: nil) == "7d")
        #expect(UsageWindowLabel.short(id: "weekly", name: "Weekly") == "7d")
        #expect(UsageWindowLabel.short(id: "daily", name: "Daily") == "Daily")
        #expect(UsageWindowLabel.short(id: "monthly", name: nil) == "Monthly")
        #expect(UsageWindowLabel.short(id: "credits", name: "Credits") == "Credits")
    }

    @Test("today's short names pass through and long names are cut to six characters")
    func names() {
        #expect(UsageWindowLabel.short(id: nil, name: "5h") == "5h")
        #expect(UsageWindowLabel.short(id: nil, name: "7d") == "7d")
        #expect(UsageWindowLabel.short(id: nil, name: "Weekly") == "7d")
        #expect(UsageWindowLabel.short(id: nil, name: "Antigravity CLI") == "Antigr")
        #expect(UsageWindowLabel.short(id: "github", name: "Github-Copilot Quota") == "Github")
        #expect(UsageWindowLabel.short(id: nil, name: nil) == "?")
        #expect(UsageWindowLabel.short(id: "", name: "") == "")
    }

    @Test("a few daemon keys read better than their first six characters")
    func extras() {
        #expect(UsageWindowLabel.short(id: "cli", name: "Antigravity CLI") == "CLI")
        #expect(UsageWindowLabel.short(id: "free-tier", name: "Github-Copilot Quota") == "Free")
        #expect(UsageWindowLabel.short(id: "fable-only", name: "7d Fable") == "Fable")
    }

    @Test("the decoded window carries the daemon id and its short name")
    func decoded() throws {
        let json = #"{"id":"five-hour","name":"5h","used_pct":44,"resets_at":1789014600}"#
        let window = try JSONDecoder().decode(CoreUsageWindow.self, from: Data(json.utf8))
        #expect(window.key == "five-hour")
        #expect(window.id == "five-hour")
        #expect(window.shortName == "5h")
        let old = try JSONDecoder().decode(CoreUsageWindow.self, from: Data(#"{"name":"7d","used_pct":29}"#.utf8))
        #expect(old.key == nil && old.id == "7d" && old.shortName == "7d")
    }
}

@Suite("Session labels")
struct SessionLabelTests {
    @Test("a human label passes through")
    func plain() {
        #expect(SessionLabel.display(label: "jr-bar-67", shortId: "fca1eb06", id: "claude:session:fca1eb06-f6d1-413e-aa5f-dd19d8e05973", provider: "claude") == "jr-bar-67")
        #expect(SessionLabel.display(label: "jr-bar-67 worker a764be9b", shortId: "a764be9b", id: "claude:agent:a764be9bccedce76b", provider: "claude") == "jr-bar-67 worker a764be9b")
    }

    @Test("a leading provider name is dropped so callers can add their own")
    func providerPrefix() {
        #expect(SessionLabel.display(label: "Codex 01a08b62", shortId: "01a08b62", id: "codex:session:01a08b62-8dbd-7410-babc-ab603738f9d8", provider: "codex") == "01a08b62")
        #expect(SessionLabel.display(label: "OpenCode jrbar-in", shortId: "jrbar-in", id: "opencode:session:jrbar-install-probe", provider: "opencode") == "jrbar-in")
        #expect(SessionLabel.display(label: "Claude", shortId: "fca1eb06", id: "claude:session:x", provider: "claude") == "fca1eb06")
    }

    @Test("a UUID label becomes the short id, or its first eight characters")
    func uuids() {
        let uuid = "fca1eb06-f6d1-413e-aa5f-dd19d8e05973"
        #expect(SessionLabel.display(label: "Claude \(uuid)", shortId: "fca1eb06", id: "claude:session:\(uuid)", provider: "claude") == "fca1eb06")
        #expect(SessionLabel.display(label: uuid, shortId: nil, id: "claude:session:\(uuid)", provider: "claude") == "fca1eb06")
        #expect(SessionLabel.display(label: nil, shortId: nil, id: "claude:session:\(uuid)", provider: "claude") == "fca1eb06")
        #expect(SessionLabel.display(label: "", shortId: nil, id: "codex:agent:a764be9bccedce76b", provider: "codex") == "a764be9b")
        #expect(SessionLabel.display(label: "run \(uuid) again", shortId: nil, id: "x", provider: "codex") == "run fca1eb06 again")
        #expect(SessionLabel.looksLikeUUID(uuid))
        #expect(SessionLabel.looksLikeUUID("a764be9bccedce76b"))
        #expect(!SessionLabel.looksLikeUUID("jr-bar-67"))
        #expect(!SessionLabel.looksLikeUUID("01a08b62"))
    }

    @Test("CoreSession.displayLabel and the decoded short_id agree")
    func session() throws {
        let json = #"{"id":"claude:session:fca1eb06-f6d1-413e-aa5f-dd19d8e05973","provider":"claude","label":"Claude fca1eb06-f6d1-413e-aa5f-dd19d8e05973","short_id":"fca1eb06","kind":"main"}"#
        let session = try JSONDecoder().decode(CoreSession.self, from: Data(json.utf8))
        #expect(session.shortId == "fca1eb06")
        #expect(session.displayLabel == "fca1eb06")
        #expect("\(session.providerName) \(session.displayLabel)" == "Claude fca1eb06")
    }
}

@Suite("Remote sessions")
struct RemoteSessionTests {
    @Test("a remote:<machine>:<source> id is remote, and names its machine")
    func remoteIDs() {
        let remote = CoreSession(id: "remote:studio-mac:claude:session:fca1eb06", provider: "claude", kind: "main")
        #expect(remote.isRemote)
        #expect(remote.remoteMachine == "studio-mac")
        #expect(CoreSession.isRemoteID("remote:studio-mac:claude:session:x"))
        #expect(CoreSession.remoteMachine(inID: "remote:studio-mac:claude:session:x") == "studio-mac")
    }

    @Test("a local id is never remote, and degenerate remote ids name no machine")
    func localAndDegenerate() {
        let local = CoreSession(id: "claude:session:fca1eb06", provider: "claude", kind: "main")
        #expect(!local.isRemote)
        #expect(local.remoteMachine == nil)
        #expect(!CoreSession.isRemoteID("claude:session:x"))
        #expect(CoreSession.remoteMachine(inID: "claude:session:x") == nil)
        // "remote:" with nothing after it is still remote but machineless.
        #expect(CoreSession.isRemoteID("remote:"))
        #expect(CoreSession.remoteMachine(inID: "remote:") == nil)
        #expect(CoreSession.remoteMachine(inID: "remote::claude:session:x") == nil)
    }
}
