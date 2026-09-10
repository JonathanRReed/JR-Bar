import Foundation
import Testing
@testable import JRBarCore

@Suite("Usage history")
struct UsageHistoryTests {
    static func fixture() throws -> UsageHistory {
        try JSONDecoder().decode(UsageHistory.self, from: CoreFixtures.data("usage_history.json"))
    }

    @Test("usage_history decodes days, hours, pricing and account")
    func decodes() throws {
        let history = try Self.fixture()
        #expect(history.provider == "claude")
        #expect(history.range == "7d")
        #expect(history.days.count == 7)
        #expect(history.hours.count == 168)
        #expect(!history.isEmpty)
        let last = try #require(history.days.last)
        #expect(last.date.count == 10)
        #expect(last.day != nil)
        #expect(last.totalTokens == last.tokensIn + last.tokensOut + last.cacheRead)
        #expect(last.costUsd > 0)
        let hour = try #require(history.hours.first)
        #expect(hour.at != nil)
        #expect(hour.date != nil)
        #expect(hour.hour.contains("T"))
        let pricing = try #require(history.pricing)
        #expect(pricing.inputPerMillion == 3.0)
        #expect(pricing.cacheReadPerMillion == 0.30)
        #expect(pricing.approximate)
        #expect(pricing.currency == "USD")
        #expect(pricing.asOf == "2026-09-01")
        let account = try #require(history.account)
        #expect(account.plan == "Max 20×")
        #expect(account.fidelity == "official")
    }

    @Test("totals, cache share and savings")
    func totals() throws {
        let history = try Self.fixture()
        #expect(history.totalTokens == history.days.reduce(0) { $0 + $1.totalTokens })
        #expect(abs(history.totalCost - history.days.reduce(0) { $0 + $1.costUsd }) < 0.0001)
        let share = try #require(history.cacheShare)
        #expect(share > 0 && share < 1)
        let savings = try #require(history.cacheSavings)
        // Cache reads at $0.30 instead of $3.00 per million.
        let expected = Double(history.totalCacheRead) / 1_000_000 * 2.7
        #expect(abs(savings - expected) < 0.0001)
        #expect(history.peakDayTokens == history.days.map(\.totalTokens).max())
    }

    @Test("missing fields decode to zero and the empty shape is empty")
    func tolerant() throws {
        let json = #"{"provider":"codex","days":[{"date":"2026-09-01"}],"hours":[{"hour":"2026-09-01T09:00"}]}"#
        let history = try JSONDecoder().decode(UsageHistory.self, from: Data(json.utf8))
        #expect(history.range == "")
        #expect(history.days[0].totalTokens == 0)
        #expect(history.days[0].costUsd == 0)
        #expect(history.hours[0].at == nil)
        #expect(history.hours[0].date != nil)
        #expect(history.pricing == nil)
        #expect(history.cacheSavings == nil)
        #expect(history.cacheShare == nil)
        let empty = try JSONDecoder().decode(UsageHistory.self, from: Data(#"{"provider":"cursor","range":"7d","days":[],"hours":[]}"#.utf8))
        #expect(empty.isEmpty)
        #expect(empty.totalCost == 0)
        // Pricing without a cache price means no savings claim.
        let noCache = UsageHistory(provider: "x", range: "7d", days: [UsageHistoryDay(date: "2026-09-01", cacheRead: 1_000_000)],
                                   pricing: UsagePricing(inputPerMillion: 3))
        #expect(noCache.cacheSavings == nil)
    }

    @Test("ranges and formatting")
    func formatting() {
        #expect(UsageHistoryRange.allCases.map(\.days) == [7, 30, 90, 365])
        #expect(UsageHistoryRange(rawValue: "90d") == .quarter)
        #expect(UsageFormat.tokens(999) == "999")
        #expect(UsageFormat.tokens(1_234) == "1.2k")
        #expect(UsageFormat.tokens(45_600) == "46k")
        #expect(UsageFormat.tokens(4_560_000) == "4.6M")
        #expect(UsageFormat.tokens(12_000_000) == "12M")
        #expect(UsageFormat.tokens(2_500_000_000) == "2.5B")
        #expect(UsageFormat.cost(14.6989) == "$14.70")
        #expect(UsageFormat.cost(0.004) == "<$0.01")
        #expect(UsageFormat.cost(0) == "$0.00")
        // Past a thousand the cents go and the digits are grouped, so
        // "$253,305" is a number rather than a smear.
        #expect(UsageFormat.cost(1234.6) == "$1,235")
        #expect(UsageFormat.cost(253_305) == "$253,305")
        #expect(UsageFormat.grouped(999) == "999")
        #expect(UsageFormat.cost(2, currency: "EUR") == "€2.00")
    }

    @Test("state usage carries the account block and a signed-out state")
    func providerAccount() throws {
        let json = #"{"id":"cursor","windows":[],"fidelity":"manual","state":"not_signed_in","account":{"plan":null,"label":null,"fidelity":null}}"#
        let provider = try JSONDecoder().decode(CoreProviderUsage.self, from: Data(json.utf8))
        #expect(provider.isSignedOut)
        #expect(provider.windows.isEmpty)
        #expect(provider.account != nil)
        let ok = try JSONDecoder().decode(CoreProviderUsage.self, from: Data(#"{"id":"claude","state":"ok","account":{"plan":"Max","fidelity":"official"}}"#.utf8))
        #expect(!ok.isSignedOut)
        #expect(ok.account?.plan == "Max")
    }
}

@Suite("Usage history verdicts")
struct UsageHistoryVerdictTests {
    static func zeroDays(_ count: Int) -> [UsageHistoryDay] {
        (0..<count).map { UsageHistoryDay(date: String(format: "2026-09-%02d", $0 + 1)) }
    }

    @Test("records 0 means this Mac has nothing local, padded rows or not")
    func noLocalRecords() {
        // The daemon answers with a row per day whether or not it read
        // anything, so an all-zero month with no records is the verdict.
        let padded = UsageHistory(provider: "devin", range: "30d", days: Self.zeroDays(30), records: 0)
        #expect(padded.hasNoLocalRecords)
        #expect(!padded.isEmpty, "the rows are there; they are just all zero")
        let bare = UsageHistory(provider: "devin", range: "30d", records: 0)
        #expect(bare.hasNoLocalRecords)
    }

    @Test("a scan still running is never a verdict, and a real quiet month is not one either")
    func notAVerdict() {
        let pending = UsageHistory(provider: "claude", range: "30d", records: 0, partial: true)
        #expect(!pending.hasNoLocalRecords, "the scan has not finished")
        let quiet = UsageHistory(provider: "claude", range: "30d", days: UsageHistoryVerdictTests.zeroDays(30), records: 4_120)
        #expect(!quiet.hasNoLocalRecords, "records were read; this range is simply empty")
        let busy = UsageHistory(provider: "claude", range: "7d",
                                days: [UsageHistoryDay(date: "2026-09-10", tokensIn: 10)], records: 2)
        #expect(!busy.hasNoLocalRecords)
        #expect(UsageHistory(provider: "claude", range: "7d").hasNoLocalRecords == false, "no count at all is not a zero count")
    }
}

@Suite("Usage provider hints")
struct UsageProviderHintTests {
    @Test("action and reason decode from the daemon's state and are optional")
    func actionReason() throws {
        guard case .state(let state) = try CoreFixtures.message("real_state.json") else { Issue.record("not a state"); return }
        let providers = try #require(state.usage?.providers)
        let claude = try #require(providers.first { $0.id == "claude" })
        #expect(claude.state == "stale" && claude.action == "Reconnect Claude" && claude.reason == "authentication_required")
        #expect(claude.account == nil && claude.windows.count == 3)
        let codex = try #require(providers.first { $0.id == "codex" })
        #expect(codex.action == nil && codex.reason == nil && codex.state == "ready")
        #expect(codex.windows.first?.usedPct == 100)
        let cursor = try #require(providers.first { $0.id == "cursor" })
        #expect(cursor.state == "source_not_found" && cursor.action == "Import Cursor browser session" && cursor.windows.isEmpty)
    }
}
