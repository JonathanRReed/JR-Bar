import Foundation
import Testing
@testable import JRBarCore

@Suite("Finish banner")
struct FinishBannerTests {
    @Test("a run's length is said the way a person says it")
    func durations() {
        #expect(FinishBanner.durationWords(nil) == nil)
        #expect(FinishBanner.durationWords(0.4) == nil)
        #expect(FinishBanner.durationWords(.nan) == nil)
        #expect(FinishBanner.durationWords(-3) == nil)
        #expect(FinishBanner.durationWords(1) == "1s")
        #expect(FinishBanner.durationWords(45.2) == "45s")
        #expect(FinishBanner.durationWords(60) == "1m")
        #expect(FinishBanner.durationWords(252.4) == "4m 12s")
        #expect(FinishBanner.durationWords(3600) == "1h")
        #expect(FinishBanner.durationWords(3900) == "1h 5m")
        #expect(FinishBanner.durationWords(90_000) == "1d 1h")
        #expect(FinishBanner.durationWords(1e12) == nil)
    }

    @Test("the headline names the run and how long it took, when that is known")
    func titles() {
        #expect(FinishBanner.title(label: "jr-bar", duration: 252) == "jr-bar finished in 4m 12s")
        #expect(FinishBanner.title(label: "jr-bar", duration: nil) == "jr-bar finished")
    }

    @Test("the summary is one capped line, or nothing")
    func summaries() {
        #expect(FinishBanner.summary(nil) == nil)
        #expect(FinishBanner.summary("  \n \n") == nil)
        #expect(FinishBanner.summary("\n  All tests pass.  \nSecond line") == "All tests pass.")
        let long = FinishBanner.summary(String(repeating: "word ", count: 100))
        #expect(long != nil)
        #expect((long?.count ?? 999) <= FinishBanner.summaryLimit)
        #expect(long?.hasSuffix("…") == true)
    }

    private static let state = CoreState(sessions: [CoreSession(id: "codex:1", provider: "codex", label: "sidepulse-core")])
    private static let on = SettingsDocument(.object(["completion_notification_enabled": .bool(true)]))

    @Test("the banner says how long it ran and quotes the agent's last line")
    func bannerWords() {
        let event = CoreEvent(id: "1", kind: "completed", session: "codex:1", label: "sidepulse-core", notify: true,
                              detail: "Fix the login flow", duration: 252.4, summary: "Fixed the login redirect.")
        let delivery = EventPolicy.delivery(for: event, state: Self.state, settings: Self.on)
        #expect(delivery.notification?.title == "sidepulse-core finished in 4m 12s")
        #expect(delivery.notification?.body == "Fixed the login redirect.")
    }

    @Test("without a summary the body falls back to the session's name, then to the plain line")
    func bannerFallbacks() {
        let named = CoreEvent(id: "1", kind: "completed", session: "codex:1", label: "sidepulse-core", notify: true, detail: "Fix the login flow")
        #expect(EventPolicy.delivery(for: named, state: Self.state, settings: Self.on).notification?.body == "Fix the login flow")
        let bare = CoreEvent(id: "2", kind: "completed", session: "codex:1", label: "sidepulse-core", notify: true)
        let delivery = EventPolicy.delivery(for: bare, state: Self.state, settings: Self.on)
        #expect(delivery.notification?.title == "sidepulse-core finished")
        #expect(delivery.notification?.body.hasSuffix("is done. Click to open the session.") == true)
    }

    @Test("a terminal already in front gets the sound but no banner")
    func watchedTerminalSkipsTheBanner() {
        let event = CoreEvent(id: "1", kind: "completed", session: "codex:1", label: "sidepulse-core", sound: "glass", notify: true,
                              duration: 30, summary: "Done.")
        let watched = EventPolicy.delivery(for: event, state: Self.state, settings: Self.on, askingFrontmost: true)
        #expect(watched.notification == nil)
        #expect(watched.sound == "Glass")
        let away = EventPolicy.delivery(for: event, state: Self.state, settings: Self.on, askingFrontmost: false)
        #expect(away.notification != nil)
    }

    @Test("the summary decodes from the wire and is absent when the daemon sends none")
    func decoding() throws {
        let with = try JSONDecoder().decode(CoreEvent.self, from: Data(#"{"id":"e1","kind":"completed","duration":12,"summary":"Shipped."}"#.utf8))
        #expect(with.summary == "Shipped.")
        #expect(with.duration == 12)
        let without = try JSONDecoder().decode(CoreEvent.self, from: Data(#"{"id":"e2","kind":"completed"}"#.utf8))
        #expect(without.summary == nil)
    }
}
