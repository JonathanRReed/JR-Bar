import Foundation
import Testing
@testable import JRBarCore

/// An unanswered ask stays an ask on every surface; past the daemon's "may
/// be stale" mark it says so with its age in words and offers Dismiss.
/// These pin the wire fields, the one sentence every surface shares, and
/// the History word for an ask that expired unanswered.
@Suite("An ask that may be stale")
struct AskMayBeStaleTests {
    private static let opened = 1_800_000_000.0

    private static func decode(_ json: String) throws -> CoreAsk {
        try JSONDecoder().decode(CoreAsk.self, from: Data(json.utf8))
    }

    @Test("the daemon's fields decode")
    func decodes() throws {
        let ask = try Self.decode("""
        {"kind":"permission","opened_at":1800000000,"last_activity_at":1800000100,
         "stale":true,"dismissible":true,"summary":"Run the tests","answerable":true}
        """)
        #expect(ask.isStale)
        #expect(ask.isDismissible)
        #expect(ask.lastActivityAt == 1_800_000_100)
        #expect(ask.canAnswer, "stale or not, it is answerable where it was")
    }

    @Test("an older daemon says nothing, and nothing is stale")
    func olderDaemon() throws {
        let ask = try Self.decode(#"{"kind":"permission","opened_at":1800000000,"summary":"x"}"#)
        #expect(!ask.isStale)
        #expect(!ask.isDismissible)
        #expect(ask.lastActivityAt == nil)
        #expect(ask.staleLine(now: Date(timeIntervalSince1970: Self.opened + 99_999)) == nil)
    }

    @Test("a field of the wrong type is not said, and the ask still decodes")
    func wrongTypes() throws {
        let ask = try Self.decode(#"{"kind":"permission","stale":"yes","dismissible":3,"last_activity_at":"soon"}"#)
        #expect(!ask.isStale && !ask.isDismissible && ask.lastActivityAt == nil)
    }

    @Test("a stale ask says may be stale with its age in words")
    func staleLine() {
        let ask = CoreAsk(session: "claude:session:a", kind: "permission", openedAt: Self.opened, isStale: true)
        func line(after seconds: Double) -> String? {
            ask.staleLine(now: Date(timeIntervalSince1970: Self.opened + seconds))
        }
        #expect(line(after: 6 * 3600 + 60) == "may be stale · asked 6 hours ago")
        #expect(line(after: 9 * 3600) == "may be stale · asked 9 hours ago")
        #expect(line(after: 3 * 86_400) == "may be stale · asked 3 days ago")
        #expect(line(after: 5 * 86_400) == "may be stale · asked 5 days ago")
        // An ask the daemon never dated still says it may be stale.
        let undated = CoreAsk(session: "claude:session:a", isStale: true)
        #expect(undated.staleLine(now: Date()) == "may be stale")
    }

    @Test("a current ask has no line, so no surface adds a caveat")
    func currentAsk() {
        let ask = CoreAsk(session: "claude:session:a", openedAt: Self.opened, isStale: false)
        #expect(ask.staleLine(now: Date(timeIntervalSince1970: Self.opened + 3600)) == nil)
    }

    @Test("ages are said the way the daemon says them")
    func ageWords() {
        #expect(CoreAsk.ageWords(5) == "under a minute")
        #expect(CoreAsk.ageWords(60) == "1 minute")
        #expect(CoreAsk.ageWords(45 * 60) == "45 minutes")
        #expect(CoreAsk.ageWords(3600) == "1 hour")
        #expect(CoreAsk.ageWords(47 * 3600) == "47 hours")
        #expect(CoreAsk.ageWords(3 * 86_400) == "3 days")
        #expect(CoreAsk.ageWords(49 * 3600) == "2 days")
        #expect(CoreAsk.ageWords(-1) == "a while")
        #expect(CoreAsk.ageWords(.nan) == "a while")
    }

    @Test("a stale ask is the same ask: the identity does not move")
    func identityStaysPut() {
        let fresh = CoreAsk(session: "claude:session:a", openedAt: Self.opened, request: "r-1")
        var stale = fresh
        stale.isStale = true
        #expect(fresh.id == stale.id)
    }

    @Test("History names an ask that expired unanswered")
    func historyWord() {
        let row = CoreHistoryRow(at: Self.opened, kind: "ask_expired")
        #expect(row.kindWord == "Ask expired unanswered")
        #expect(CoreHistoryRow.kinds.contains("ask_expired"))
    }

    @Test("the two clocks are settings the Agents page can write")
    func settingsKeys() {
        let stale = SettingsKey.all.first { $0.path == "ask_stale_after_hours" }
        let expire = SettingsKey.all.first { $0.path == "ask_expire_after_days" }
        #expect(stale?.page == .agents && stale?.kind == .number)
        #expect(expire?.page == .agents && expire?.kind == .number)
    }
}
