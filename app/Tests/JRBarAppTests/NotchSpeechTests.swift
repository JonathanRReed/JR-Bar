import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// What the island says aloud when a notice drops: the line is a picture
/// to a VoiceOver user, so it is also spoken, once, as it arrives.
@Suite("Notch speech")
@MainActor
struct NotchSpeechTests {
    private func makeToy() -> (NotchToy, ToysStore) {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    @Test("a finished session is spoken as its title and what happened")
    func line() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let notice = AlcoveNotice(id: "c", kind: .completed, title: "Claude", subtitle: "rename-the-fish finished",
                                  key: "completed:c")
        #expect(toy.spokenText(for: notice) == "Claude. rename-the-fish finished")
        let bare = AlcoveNotice(id: "d", kind: .device, title: "AirPods Pro", subtitle: "", key: "d")
        #expect(toy.spokenText(for: bare) == "AirPods Pro")
    }

    @Test("an ask says it needs you, then what it asks")
    func ask() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let ask = CoreAsk(session: "claude:ask", openedAt: 0, summary: "Run the migration?",
                          answerable: true, request: "r1", preview: nil)
        let notice = AlcoveNotice(id: "a", kind: .ask, title: "Claude · rename-the-fish", subtitle: "needs you",
                                  provider: "claude", session: "claude:ask", key: "ask:1", ask: ask)
        #expect(toy.spokenText(for: notice) == "Claude · rename-the-fish needs you. Run the migration?")
    }

    @Test("a level or Caps Lock is the Mac's own to say")
    func feedbackStaysQuiet() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let level = AlcoveNotice(id: "v", kind: .level, title: "Volume", subtitle: "", key: "v",
                                 glyph: "speaker.wave.3.fill", fraction: 0.5)
        #expect(toy.spokenText(for: level) == nil)
        #expect(toy.spokenText(for: NotchAnnouncements.capsLockNotice(on: true)) == nil)
    }

    @Test("a notice is spoken once, as it is drawn")
    func spokenOnArrival() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        let timers = ManualTimers.driving(toy)
        var heard: [String] = []
        toy.speak = { heard.append($0) }
        toy.offer(AlcoveNotice(id: "c", kind: .completed, title: "Claude", subtitle: "done", key: "completed:c"))
        var guardRail = 0
        while heard.isEmpty, guardRail < 8, timers.fireNext() { guardRail += 1 }
        #expect(heard == ["Claude. done"])
    }
}
