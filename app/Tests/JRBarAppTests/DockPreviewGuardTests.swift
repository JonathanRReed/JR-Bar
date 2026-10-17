import Testing
@testable import JRBarApp

@MainActor
struct DockPreviewGuardTests {
    private func confirm(_ key: String, now: Double, guardState: inout DockAgentGuard,
                         content: DockPreviewContent) -> Bool {
        content.confirmGuard(key, guarded: true, now: now, guardState: &guardState)
    }

    @Test("a replacement close keeps its warning when the old timer fires")
    func replacementClose() {
        let content = DockPreviewContent()
        var guardState = DockAgentGuard()
        _ = confirm("close:1", now: 0, guardState: &guardState, content: content)
        content.armedWindowID = 1
        content.armedNote = "Close one again"
        _ = confirm("close:2", now: 1, guardState: &guardState, content: content)
        #expect(content.armedWindowID == nil)
        #expect(content.armedNote == nil)
        content.armedWindowID = 2
        content.armedNote = "Close two again"
        if guardState.expire("close:1", now: 2.1) { content.clearGuardNote("close:1") }
        #expect(content.armedWindowID == 2)
        #expect(content.armedNote == "Close two again")
        if guardState.expire("close:2", now: 3.1) { content.clearGuardNote("close:2") }
        #expect(content.armedWindowID == nil)
        #expect(content.armedNote == nil)
    }

    @Test("close and quit replace each other's guard notes")
    func crossVerb() {
        let content = DockPreviewContent()
        var guardState = DockAgentGuard()
        _ = confirm("close:1", now: 0, guardState: &guardState, content: content)
        content.armedWindowID = 1
        content.armedNote = "Close again"
        _ = confirm("quit:7", now: 1, guardState: &guardState, content: content)
        content.armQuitNote("Quit again")
        #expect(content.armedWindowID == nil)
        #expect(content.armedNote == nil)
        _ = confirm("close:1", now: 1.5, guardState: &guardState, content: content)
        content.armedWindowID = 1
        content.armedNote = "Close again"
        #expect(content.headerNote == nil)
        _ = confirm("quickquit:7", now: 1.6, guardState: &guardState, content: content)
        #expect(content.armedWindowID == nil)
        #expect(content.armedNote == nil)
    }

    @Test("same-key rearming keeps its warning until the new deadline")
    func rearming() {
        let content = DockPreviewContent()
        var guardState = DockAgentGuard()
        _ = confirm("quit:7", now: 0, guardState: &guardState, content: content)
        content.armQuitNote("Quit again")
        _ = confirm("quit:7", now: 2.1, guardState: &guardState, content: content)
        if guardState.expire("quit:7", now: 2.2) { content.clearGuardNote("quit:7") }
        #expect(content.headerNote == "Quit again")
        if guardState.expire("quit:7", now: 4.2) { content.clearGuardNote("quit:7") }
        #expect(content.headerNote == nil)
    }

    @Test("guard cleanup preserves ordinary header status")
    func statusNotes() {
        for status in ["Quitting…", "Still running", "Kept an agent window"] {
            let content = DockPreviewContent()
            var guardState = DockAgentGuard()
            _ = confirm("quit:7", now: 0, guardState: &guardState, content: content)
            content.armQuitNote("Quit again")
            content.headerNote = status
            _ = confirm("quit:7", now: 1, guardState: &guardState, content: content)
            #expect(content.headerNote == status)
            if guardState.expire("quit:7", now: 2.1) { content.clearGuardNote("quit:7") }
            #expect(content.headerNote == status)
            _ = confirm("quit:7", now: 3, guardState: &guardState, content: content)
            content.armQuitNote("Quit again")
            content.headerNote = status
            if guardState.expire("quit:7", now: 5.1) { content.clearGuardNote("quit:7") }
            #expect(content.headerNote == status)
        }
    }
}
