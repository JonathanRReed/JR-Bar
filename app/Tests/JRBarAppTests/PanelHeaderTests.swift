import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

/// The panel header's count line: the header word is said once, and the
/// number never reads as the whole list when it is not.
@Suite("Panel header")
struct PanelHeaderTests {
    @Test("a lone count that repeats the header word counts sessions instead")
    func sayTheWordOnce() {
        #expect(PanelStore.countLine(parts: ["2 working"], headerWord: "Working", total: 2) == "2 sessions")
        #expect(PanelStore.countLine(parts: ["1 working"], headerWord: "Working", total: 1) == "1 session")
        #expect(PanelStore.countLine(parts: ["3 need you"], headerWord: "Needs you", total: 3) == "3 sessions")
        #expect(PanelStore.countLine(parts: ["1 needs you"], headerWord: "Needs you", total: 1) == "1 session")
        #expect(PanelStore.countLine(parts: ["1 failed"], headerWord: "Failed", total: 1) == "1 session")
    }

    @Test("beside an idle or ended session the count says how many of the list it is")
    func partOfTheList() {
        #expect(PanelStore.countLine(parts: ["2 working"], headerWord: "Working", total: 3) == "2 of 3 sessions")
        #expect(PanelStore.countLine(parts: ["1 needs you"], headerWord: "Needs you", total: 4) == "1 of 4 sessions")
        #expect(PanelStore.countLine(parts: ["1 failed"], headerWord: "Failed", total: 2) == "1 of 2 sessions")
    }

    @Test("more asks than sessions is not a count of sessions")
    func asksOutnumberSessions() {
        #expect(PanelStore.countLine(parts: ["2 need you"], headerWord: "Needs you", total: 1) == "2 need you")
    }

    @Test("counts that say something the word does not are left as they are")
    func otherCountsStand() {
        #expect(PanelStore.countLine(parts: ["2 ready"], headerWord: "Done", total: 2) == "2 ready")
        #expect(PanelStore.countLine(parts: ["1 needs you", "2 working"], headerWord: "Needs you", total: 3)
                == "1 needs you · 2 working")
        #expect(PanelStore.countLine(parts: ["2 working"], headerWord: "Needs you", total: 2) == "2 working")
    }

    @Test("two working sessions and an idle one: the header counts two of three")
    @MainActor
    func idleSessionIsNotCountedAsWorking() {
        let t = Date().timeIntervalSince1970
        let sessions = [
            CoreSession(id: "claude:a", provider: "claude", label: "a", cwd: "/tmp/a", mode: "working", since: t - 60),
            CoreSession(id: "codex:b", provider: "codex", label: "b", cwd: "/tmp/b", mode: "working", since: t - 60),
            CoreSession(id: "gemini:c", provider: "gemini", label: "c", cwd: "/tmp/c", mode: "idle", since: t - 600),
        ]
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(CoreState(now: t, aggregate: CoreAggregate(mode: "working", active: 2), sessions: sessions)))
        let store = PanelStore(core: core, draftsDefaults: UserDefaults(suiteName: "jrbar.tests.\(UUID())")!,
                               screenBarShown: false)
        store.now = Date(timeIntervalSince1970: t)
        #expect(store.headerWord == "Working")
        #expect(store.headerCounts == "2 of 3 sessions")
        #expect(store.rows.count == 3)
    }
}
