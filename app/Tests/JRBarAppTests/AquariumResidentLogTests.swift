import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// A resident's logbook: when it swam and what its session got done,
/// from the daemon's history rows — nothing the history doesn't say.
@Suite("Aquarium resident log")
struct AquariumResidentLogTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let day0 = 1_788_000_000.0   // a UTC midday

    @Test("a session the history still has: its span and its record")
    func fromHistory() {
        let care = FishCare(stage: 2, createdAt: day0 + 600, label: "Nemo", provider: "claude")
        let rows = [
            CoreHistoryRow(at: day0, kind: "started", session: "s"),
            CoreHistoryRow(at: day0 + 3_600, kind: "completed", session: "s", duration: 840),
            CoreHistoryRow(at: day0 + 90_000, kind: "answered", session: "s"),
            CoreHistoryRow(at: day0 + 2 * 86_400, kind: "completed", session: "s", duration: 120),
            CoreHistoryRow(at: day0 + 2 * 86_400, kind: "completed", session: "other"),
            CoreHistoryRow(at: day0 + 2 * 86_400 + 60, kind: "failed", session: "s"),
        ]
        let log = AquariumResidentLog.make(sessionID: "s", care: care, rows: rows, calendar: utc)
        #expect(log.swam.hasPrefix("Swam "))
        #expect(log.swam.contains(" – "), "a span over days: \(log.swam)")
        #expect(log.record == "Finished 2 runs · 1 ask answered · 1 failed · longest run 14 min")
    }

    @Test("one day reads as one day")
    func sameDay() {
        let rows = [CoreHistoryRow(at: day0, kind: "started", session: "s"),
                    CoreHistoryRow(at: day0 + 60, kind: "completed", session: "s", duration: 30)]
        let log = AquariumResidentLog.make(sessionID: "s", care: nil, rows: rows, calendar: utc)
        #expect(!log.swam.contains(" – "))
        #expect(log.record == "Finished 1 run", "a half-minute run has no 'longest' worth saying")
    }

    @Test("a session the history has let go of: only what the tank remembers")
    func forgotten() {
        let care = FishCare(stage: 1, createdAt: day0)
        let log = AquariumResidentLog.make(sessionID: "s", care: care, rows: [], calendar: utc)
        #expect(log.swam.hasPrefix("In the tank since "))
        #expect(log.record == nil)
        #expect(AquariumResidentLog.make(sessionID: "s", care: nil, rows: []).swam == "In the tank")
    }
}
