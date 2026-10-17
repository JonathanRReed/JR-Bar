import Testing
@testable import JRBarApp
@testable import JRBarCore

/// A new ask is spoken to VoiceOver once, and only an ask that still needs
/// the person.
@MainActor
@Suite("Ask announcements")
struct AskAnnouncerTests {
    private func ask(_ request: String, session: String = "claude:a", summary: String? = "Run npm test",
                     stale: Bool = false, decided: Bool = false) -> CoreAsk {
        var ask = CoreAsk(session: session, summary: summary, request: request)
        ask.isStale = stale
        if decided { ask.decision = CoreAskDecision(decided: true) }
        return ask
    }

    private func announcer() -> (AskAnnouncer, () -> [String]) {
        let announcer = AskAnnouncer()
        var spoken: [String] = []
        announcer.post = { spoken.append($0) }
        return (announcer, { spoken })
    }

    @Test("a new ask is spoken once, however often the same state arrives")
    func once() {
        let (announcer, spoken) = announcer()
        announcer.note([ask("r1")])
        announcer.note([ask("r1")])
        announcer.note([ask("r1"), ask("r2", session: "codex:b", summary: "Edit main.swift")])
        #expect(spoken() == ["Claude needs you: Run npm test", "Codex needs you: Edit main.swift"])
    }

    @Test("several arriving together are one line, not a pile")
    func together() {
        let (announcer, spoken) = announcer()
        announcer.note([ask("r1"), ask("r2"), ask("r3")])
        #expect(spoken() == ["3 agents need you"])
    }

    @Test("an answered or stale ask is not news, and is not spoken later either")
    func quietKinds() {
        let (announcer, spoken) = announcer()
        announcer.note([ask("r1", decided: true), ask("r2", stale: true)])
        announcer.note([ask("r1"), ask("r2")])
        #expect(spoken().isEmpty)
    }

    @Test("a long summary is clipped, and a missing one still says who is waiting")
    func wording() {
        #expect(AskAnnouncer.line(for: ask("r1", summary: nil)) == "Claude needs you")
        let long = String(repeating: "x", count: 300)
        let line = AskAnnouncer.line(for: ask("r1", summary: long))
        #expect(line.count < 160)
        #expect(line.hasSuffix("…"))
        #expect(AskAnnouncer.line(for: ask("r1", session: "")) == "An agent needs you: Run npm test")
    }
}
