import Testing
@testable import JRBarApp

@Suite("Coming soon provider navigation")
struct ProviderComingSoonTests {
    @Test("every Settings search reveal clears the previous filter and expands the list")
    func repeatedReveal() {
        var state = ProviderComingSoonState(expanded: false, query: "DeepSeek")
        state.reveal()
        #expect(state.expanded && state.query.isEmpty)
        state.expanded = false
        state.query = "Copilot"
        state.reveal()
        #expect(state.expanded && state.query.isEmpty)
    }
}
