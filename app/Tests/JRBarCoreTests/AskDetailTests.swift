import Foundation
import Testing
@testable import JRBarCore

/// `ask.detail` (docs/CORE-PROTOCOL.md): what an ask adds when the person
/// expands it, and the words every surface uses for it.
@Suite("Ask detail")
struct AskDetailTests {
    private func ask(_ json: String) throws -> CoreAsk {
        try JSONDecoder().decode(CoreAsk.self, from: Data(json.utf8))
    }

    @Test("a command's detail decodes and is not a plan")
    func commandDetail() throws {
        let decoded = try ask("""
        {"session":"claude:session:a","kind":"permission","summary":"Bash","answerable":true,
         "preview":"set -e npm ci npm test","detail":{"command":"set -e\\nnpm ci\\nnpm test","truncated":false}}
        """)
        #expect(decoded.hasDetail)
        #expect(!decoded.isPlanApproval)
        #expect(decoded.detail?.command == "set -e\nnpm ci\nnpm test")
        #expect(AskDetailCopy.body(try #require(decoded.detail)) == "set -e\nnpm ci\nnpm test")
        #expect(AskDetailCopy.footnote(try #require(decoded.detail)) == nil)
    }

    @Test("a plan approval is a plan, with the session as its action")
    func planDetail() throws {
        let decoded = try ask("""
        {"session":"claude:session:a","kind":"approval","summary":"ExitPlanMode","answerable":false,
         "detail":{"plan":"1. Read\\n2. Change","truncated":true}}
        """)
        #expect(decoded.isPlanApproval)
        let detail = try #require(decoded.detail)
        #expect(AskDetailCopy.noun(detail) == "plan")
        #expect(AskDetailCopy.toggleTitle(detail, expanded: false) == "Show plan")
        #expect(AskDetailCopy.toggleTitle(detail, expanded: true) == "Hide plan")
        #expect(AskDetailCopy.footnote(detail) == "Showing the first 2,000 characters")
        #expect(AskDetailCopy.sessionActionTitle == "Answer in the session")
    }

    @Test("an edit says how many files and lines, in the words the card uses")
    func editDetail() throws {
        let decoded = try ask("""
        {"session":"s","detail":{"edit":{"verb":"edit","files":2,"added":14,"removed":3,
         "paths":["/src/a.py","/src/b.py"]},"truncated":false}}
        """)
        let detail = try #require(decoded.detail)
        #expect(detail.edit?.summary == "edit: 2 files, +14/-3")
        #expect(AskDetailCopy.noun(detail) == "edit summary")
        #expect(AskDetailCopy.body(detail) == nil)
        #expect(AskDetailCopy.pathLines(try #require(detail.edit)) == ["/src/a.py", "/src/b.py"])

        let one = CoreAskEdit(verb: "edit", files: 1, added: 2, removed: 0)
        #expect(one.summary == "edit: 1 file, +2/-0")
        let write = CoreAskEdit(verb: "write", files: 1, added: 40, removed: 0)
        #expect(write.summary == "write: 1 file, +40")
        let patch = CoreAskEdit(verb: "patch", files: 7, added: 3, removed: 2,
                                paths: ["a", "b", "c", "d", "e"])
        #expect(AskDetailCopy.pathLines(patch) == ["a", "b", "c", "d", "e", "+2 more"])
    }

    @Test("no detail, an empty one or an odd one leaves the card as it was")
    func absentDetail() throws {
        #expect(try ask(#"{"session":"s","preview":"npm test"}"#).detail == nil)
        #expect(try ask(#"{"session":"s","detail":null}"#).detail == nil)
        #expect(try ask(#"{"session":"s","detail":{}}"#).detail == nil)
        #expect(try ask(#"{"session":"s","detail":{"command":"","plan":""}}"#).hasDetail == false)
        #expect(try ask(#"{"session":"s","detail":"soon"}"#).hasDetail == false)
        // A bad edit is dropped, a good command beside it kept.
        let mixed = try ask(#"{"session":"s","detail":{"command":"a\nb","edit":"nope"}}"#)
        #expect(mixed.detail?.command == "a\nb" && mixed.detail?.edit == nil)
    }

    @Test("the spoken label carries the text, so the monospaced well is not skipped")
    func spoken() {
        #expect(AskDetailCopy.bodyLabel(CoreAskDetail(command: "ls\nrm x")) == "Full command: ls\nrm x")
        #expect(AskDetailCopy.bodyLabel(CoreAskDetail(plan: "step")) == "Plan: step")
        #expect(AskDetailCopy.toggleHint(expanded: false).contains("Nothing is answered"))
    }
}

@Suite("Panel layout with an expanded ask")
struct AskDetailPanelLayoutTests {
    typealias L = PanelLayout

    @Test("an expanded ask adds one fixed well, and never more than there are asks")
    func expandedAsks() {
        let plain = L.Content(asks: 2, sessions: 1)
        let open = L.Content(asks: 2, sessions: 1, expandedAsks: 1)
        #expect(L.sessionsContentHeight(open) == L.sessionsContentHeight(plain) + L.askDetailHeight)
        let over = L.Content(asks: 1, sessions: 0, expandedAsks: 5)
        #expect(over.expandedAsks == 1)
        #expect(L.Content(asks: 0, sessions: 2, expandedAsks: 3).expandedAsks == 0)
    }

    @Test("the window grows by the well and still obeys the screen's cap")
    func windowGrows() {
        let plain = L.compute(content: L.Content(asks: 1, sessions: 1), screenHeight: 2000)
        let open = L.compute(content: L.Content(asks: 1, sessions: 1, expandedAsks: 1), screenHeight: 2000)
        #expect(open.totalHeight == plain.totalHeight + L.askDetailHeight)
        let tight = L.compute(content: L.Content(asks: 3, sessions: 6, usageProviders: 3, expandedAsks: 3),
                              screenHeight: 900)
        #expect(tight.totalHeight <= tight.maxHeight)
        #expect(tight.sessionsScroll)
    }

    @Test("a cut list keeps the opened ask whole in view")
    func openedAskStaysInView() {
        let content = L.Content(asks: 4, sessions: 6, usageProviders: 2, expandedAsks: 1)
        let layout = L.compute(content: content, screenHeight: 1000)
        #expect(layout.sessionsScroll)
        #expect(layout.sessionsHeight >= L.askRowHeight + L.askDetailHeight)
    }
}
