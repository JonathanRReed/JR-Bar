import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("History words")
struct EventLogWordsTests {
    @Test func runLengthsReadLikeThePanel() {
        #expect(HistoryStore.duration(45) == "45s")
        #expect(HistoryStore.duration(95) == "1m")
        #expect(HistoryStore.duration(25 * 60) == "25m")
        #expect(HistoryStore.duration(3600) == "1h")
        #expect(HistoryStore.duration(3900) == "1h 05m")
        #expect(HistoryStore.duration(nil) == nil)
        #expect(HistoryStore.duration(-1) == nil)
    }

    @Test func theEventsBannerCountsInPlainWords() {
        #expect(EventLogWords.banner(kept: 120, dropped: 0, incomplete: false) == "Events since the monitor started · 120 kept")
        let full = EventLogWords.banner(kept: 120, dropped: 3, incomplete: true)
        #expect(full == "Events since the monitor started · 120 kept · 3 dropped · some may be missing; Refresh reloads them")
        #expect(!full.contains("retained") && !full.contains("resync") && !full.contains("journal"))
    }

    @Test func needYouAgreesWithItsCount() {
        #expect(EventLogWords.needYou(1) == "1 needs you now")
        #expect(EventLogWords.needYou(3) == "3 need you now")
    }
}
