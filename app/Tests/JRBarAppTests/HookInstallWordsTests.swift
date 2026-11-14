import Testing
@testable import JRBarApp

@Suite("Hook install words")
struct HookInstallWordsTests {
    @Test("a successful install says so, and passes on the monitor's note when the agent needs a new session")
    func installed() {
        #expect(HookInstallWords.installed(note: nil) == "Hooks installed")
        #expect(HookInstallWords.installed(note: "") == "Hooks installed")
        #expect(HookInstallWords.installed(note: "Start a new Codex session to use them.")
                == "Hooks installed. Start a new Codex session to use them.")
    }
}
