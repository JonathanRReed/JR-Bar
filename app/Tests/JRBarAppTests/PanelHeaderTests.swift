import Testing
@testable import JRBarApp

/// The panel header's count line: the header word is said once.
@Suite("Panel header")
struct PanelHeaderTests {
    @Test("a lone count that repeats the header word counts sessions instead")
    func sayTheWordOnce() {
        #expect(PanelStore.countLine(parts: ["2 working"], headerWord: "Working") == "2 sessions")
        #expect(PanelStore.countLine(parts: ["1 working"], headerWord: "Working") == "1 session")
        #expect(PanelStore.countLine(parts: ["3 need you"], headerWord: "Needs you") == "3 sessions")
        #expect(PanelStore.countLine(parts: ["1 needs you"], headerWord: "Needs you") == "1 session")
        #expect(PanelStore.countLine(parts: ["1 failed"], headerWord: "Failed") == "1 session")
    }

    @Test("counts that say something the word does not are left as they are")
    func otherCountsStand() {
        #expect(PanelStore.countLine(parts: ["2 ready"], headerWord: "Done") == "2 ready")
        #expect(PanelStore.countLine(parts: ["1 needs you", "2 working"], headerWord: "Needs you")
                == "1 needs you · 2 working")
        #expect(PanelStore.countLine(parts: ["2 working"], headerWord: "Needs you") == "2 working")
    }
}
